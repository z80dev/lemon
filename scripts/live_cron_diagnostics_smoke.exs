Application.ensure_all_started(:lemon_core)

defmodule LemonScripts.LiveCronDiagnosticsSmoke do
  alias LemonCore.Doctor.{Check, CronDiagnostics, Report, SupportBundle}
  alias LemonCore.Store

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    out =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "cron-diagnostics-latest.json"])

    token = System.unique_integer([:positive, :monotonic])
    fixture = fixture(token)

    proof =
      try do
        seed_fixture(fixture)
        run_checks(fixture)
      rescue
        exception ->
          proof(:failed, [
            check("cron_diagnostics_smoke", "failed", exception.__struct__ |> inspect())
          ])
      after
        cleanup_fixture(fixture)
      end

    write_json!(out, proof)
    write_json!(archive_path(out), proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run_checks(fixture) do
    diagnostics = CronDiagnostics.status(limit: 100)

    checks = [
      diagnostics_counts_check(diagnostics),
      diagnostics_retry_check(diagnostics, fixture),
      diagnostics_redaction_check(diagnostics, fixture),
      support_bundle_check(fixture)
    ]

    status =
      if Enum.all?(checks, &(&1.status == "completed")), do: :completed, else: :failed

    proof(status, checks)
  end

  defp diagnostics_counts_check(diagnostics) do
    ok? =
      diagnostics.job_count >= 1 and diagnostics.run_count >= 1 and
        diagnostics.failed_run_count >= 1 and get_in(diagnostics, [:status_counts, "failed"])

    if ok? do
      check("cron_diagnostics_counts", "completed")
    else
      check("cron_diagnostics_counts", "failed", "missing seeded cron job/run counts")
    end
  end

  defp diagnostics_retry_check(diagnostics, fixture) do
    job =
      Enum.find(diagnostics.recent_jobs, fn job ->
        job.id_hash == short_hash(fixture.job_id)
      end)

    run =
      Enum.find(diagnostics.recent_runs, fn run ->
        run.id_hash == short_hash(fixture.run_id)
      end)

    ok? =
      match?(%{max_retries: 2, retry_backoff_ms: 5_000}, job) and
        match?(%{retry_attempt: 1}, run) and
        run.retry_of_hash == short_hash(fixture.retry_of) and
        run.retry_root_id_hash == short_hash(fixture.retry_root_id)

    if ok? do
      check("cron_diagnostics_retry_policy", "completed")
    else
      check("cron_diagnostics_retry_policy", "failed", "missing redacted retry policy/lineage")
    end
  end

  defp diagnostics_redaction_check(diagnostics, fixture) do
    rendered = inspect(diagnostics)

    leaks? =
      Enum.any?(
        [
          fixture.prompt,
          fixture.output,
          fixture.error,
          fixture.session_key,
          fixture.memory_file,
          fixture.meta_value,
          fixture.retry_of,
          fixture.retry_root_id
        ],
        &String.contains?(rendered, &1)
      )

    redaction_ok? =
      diagnostics.cleanup.includes_prompts == false and
        diagnostics.cleanup.includes_outputs == false and
        diagnostics.cleanup.includes_errors == false and
        diagnostics.cleanup.includes_raw_session_ids == false and
        diagnostics.cleanup.includes_raw_agent_ids == false and
        diagnostics.cleanup.includes_raw_memory_paths == false and
        diagnostics.cleanup.includes_meta_values == false

    if not leaks? and redaction_ok? do
      check("cron_diagnostics_redaction", "completed")
    else
      check("cron_diagnostics_redaction", "failed", "cron diagnostics leaked raw private fields")
    end
  end

  defp support_bundle_check(fixture) do
    dir = Path.join(System.tmp_dir!(), "lemon-cron-diagnostics-smoke-#{fixture.token}")
    bundle_path = Path.join(dir, "support.zip")

    try do
      File.mkdir_p!(dir)

      {:ok, ^bundle_path} =
        SupportBundle.write(
          Report.from_checks([Check.pass("runtime.boot", "ok")]),
          bundle_path: bundle_path,
          project_dir: File.cwd!()
        )

      {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])
      names = Enum.map(entries, fn {name, _} -> List.to_string(name) end)
      {_, cron_json} = Enum.find(entries, fn {name, _} -> name == ~c"cron_diagnostics.json" end)
      rendered = IO.iodata_to_binary(cron_json)

      cond do
        "cron_diagnostics.json" not in names ->
          check("cron_support_bundle_entry", "failed", "missing cron_diagnostics.json")

        String.contains?(rendered, fixture.prompt) or String.contains?(rendered, fixture.output) or
            String.contains?(rendered, fixture.error) ->
          check("cron_support_bundle_entry", "failed", "support bundle leaked cron private text")

        true ->
          check("cron_support_bundle_entry", "completed")
      end
    after
      File.rm_rf(dir)
    end
  end

  defp proof(status, checks) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: Atom.to_string(status),
      proof_object: "lemon.cron_diagnostics_smoke",
      proof_scope: "cron_diagnostics",
      checks: checks,
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      failed_count: Enum.count(checks, &(&1.status == "failed")),
      skipped_count: Enum.count(checks, &(&1.status == "skipped")),
      cleanup: %{
        includes_prompts: false,
        includes_outputs: false,
        includes_errors: false,
        includes_raw_session_ids: false,
        includes_raw_agent_ids: false,
        includes_raw_memory_paths: false,
        includes_meta_values: false,
        temporary_bundle_removed: true
      }
    }
  end

  defp check(name, status, reason \\ nil) do
    %{name: name, status: status}
    |> maybe_put(:reason_kind, reason)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fixture(token) do
    %{
      token: token,
      job_id: "cron_diag_smoke_job_#{token}",
      run_id: "cron_diag_smoke_run_#{token}",
      router_run_id: "cron_diag_router_run_#{token}",
      prompt: "private cron diagnostics prompt #{token}",
      output: "private cron diagnostics output #{token}",
      error: "private cron diagnostics error #{token}",
      session_key: "agent:cron-diagnostics-#{token}:main",
      memory_file: "/private/cron-diagnostics-#{token}.md",
      meta_value: "private cron diagnostics meta #{token}",
      retry_of: "private cron retry parent #{token}",
      retry_root_id: "private cron retry root #{token}"
    }
  end

  defp seed_fixture(fixture) do
    Store.put(:cron_jobs, fixture.job_id, %{
      id: fixture.job_id,
      name: "cron diagnostics smoke #{fixture.token}",
      schedule: "*/5 * * * *",
      enabled: true,
      agent_id: "cron-diagnostics-agent-#{fixture.token}",
      session_key: fixture.session_key,
      prompt: fixture.prompt,
      memory_file: fixture.memory_file,
      timezone: "UTC",
      jitter_sec: 1,
      timeout_ms: 60_000,
      max_retries: 2,
      retry_backoff_ms: 5_000,
      created_at_ms: 1_000,
      updated_at_ms: 2_000,
      last_run_at_ms: 3_000,
      next_run_at_ms: 4_000,
      meta: %{private_key: fixture.meta_value}
    })

    Store.put(:cron_runs, fixture.run_id, %{
      id: fixture.run_id,
      job_id: fixture.job_id,
      run_id: fixture.router_run_id,
      status: :failed,
      started_at_ms: 5_000,
      completed_at_ms: 6_000,
      duration_ms: 1_000,
      triggered_by: :manual,
      output: fixture.output,
      error: fixture.error,
      suppressed: false,
      meta: %{
        agent_id: "cron-diagnostics-agent-#{fixture.token}",
        session_key: fixture.session_key,
        retry_attempt: 1,
        retry_of: fixture.retry_of,
        retry_root_id: fixture.retry_root_id
      }
    })
  end

  defp cleanup_fixture(fixture) do
    Store.delete(:cron_jobs, fixture.job_id)
    Store.delete(:cron_runs, fixture.run_id)
  end

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp archive_path(path) do
    ext = Path.extname(path)
    root = String.trim_trailing(path, ext)
    "#{root}-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")}#{ext}"
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

LemonScripts.LiveCronDiagnosticsSmoke.main(System.argv())
