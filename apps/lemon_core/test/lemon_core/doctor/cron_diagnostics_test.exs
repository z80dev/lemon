defmodule LemonCore.Doctor.CronDiagnosticsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.CronDiagnostics
  alias LemonCore.Store

  test "summarizes cron jobs and runs without raw prompt, output, or identifiers" do
    token = System.unique_integer([:positive, :monotonic])
    job_id = "cron_diag_job_#{token}"
    run_id = "cron_diag_run_#{token}"
    audit_id = "cron_diag_audit_#{token}"
    router_run_id = "router_run_#{token}"
    private_prompt = "private scheduled prompt #{token}"
    private_command = "echo private command #{token}"
    private_output = "private cron output #{token}"
    private_error = "private cron error #{token}"
    private_session = "agent:private-#{token}:main"
    private_memory_path = "/private/cron-memory-#{token}.md"

    on_exit(fn ->
      Store.delete(:cron_jobs, job_id)
      Store.delete(:cron_runs, run_id)
      Store.delete(:cron_audit_events, audit_id)
    end)

    Store.put(:cron_jobs, job_id, %{
      id: job_id,
      name: "private cron job #{token}",
      schedule: "*/5 * * * *",
      enabled: true,
      agent_id: "agent-private-#{token}",
      session_key: private_session,
      prompt: private_prompt,
      command: private_command,
      cwd: "/private/cron-cwd-#{token}",
      env: %{"PRIVATE_TOKEN" => "secret #{token}"},
      memory_file: private_memory_path,
      timezone: "UTC",
      jitter_sec: 3,
      timeout_ms: 123_000,
      max_retries: 2,
      retry_backoff_ms: 5_000,
      created_at_ms: 1_000,
      updated_at_ms: 2_000,
      last_run_at_ms: 3_000,
      next_run_at_ms: 4_000,
      meta: %{private_key: "private meta value"}
    })

    Store.put(:cron_runs, run_id, %{
      id: run_id,
      job_id: job_id,
      run_id: router_run_id,
      status: :failed,
      started_at_ms: 5_000,
      completed_at_ms: 6_000,
      duration_ms: 1_000,
      triggered_by: :manual,
      output: private_output,
      error: private_error,
      suppressed: false,
      meta: %{
        agent_id: "agent-private-#{token}",
        session_key: private_session,
        retry_attempt: 1,
        retry_of: "private retry parent #{token}",
        retry_root_id: "private retry root #{token}"
      }
    })

    Store.put(:cron_audit_events, audit_id, %{
      id: audit_id,
      action: "run_aborted",
      ts_ms: 7_000,
      job_id: job_id,
      run_id: run_id,
      router_run_id: router_run_id,
      source: "cron_manager",
      status: "aborted",
      triggered_by: "manual",
      reason: private_error,
      changed_fields: ["enabled"]
    })

    status = CronDiagnostics.status(limit: 50)

    assert status.job_count >= 1
    assert status.run_count >= 1
    assert status.failed_run_count >= 1
    assert status.status_counts["failed"] >= 1
    assert status.trigger_counts["manual"] >= 1
    assert status.audit_event_count >= 1
    assert status.audit_action_counts["run_aborted"] >= 1

    job = Enum.find(status.recent_jobs, &(&1.id_hash == short_hash(job_id)))
    run = Enum.find(status.recent_runs, &(&1.id_hash == short_hash(run_id)))
    audit = Enum.find(status.recent_audit_events, &(&1.id_hash == short_hash(audit_id)))

    assert job.prompt_hash == short_hash(private_prompt)
    assert job.prompt_chars == String.length(private_prompt)
    assert job.mode == "command"
    assert job.command_hash == short_hash(private_command)
    assert job.command_chars == String.length(private_command)
    assert job.env_keys == ["PRIVATE_TOKEN"]
    assert job.max_retries == 2
    assert job.retry_backoff_ms == 5_000
    assert job.session_key_hash == short_hash(private_session)
    assert job.memory_file_hash == short_hash(private_memory_path)
    assert job.meta_keys == ["private_key"]
    assert run.output_hash == short_hash(private_output)
    assert run.output_chars == String.length(private_output)
    assert run.error_hash == short_hash(private_error)
    assert run.router_run_id_hash == short_hash(router_run_id)
    assert run.retry_attempt == 1
    assert run.retry_of_hash == short_hash("private retry parent #{token}")
    assert run.retry_root_id_hash == short_hash("private retry root #{token}")
    assert audit.action == "run_aborted"
    assert audit.status == "aborted"
    assert audit.job_id_hash == short_hash(job_id)
    assert audit.run_id_hash == short_hash(run_id)
    assert audit.router_run_id_hash == short_hash(router_run_id)
    assert audit.reason_hash == short_hash(private_error)
    assert audit.reason_chars == String.length(private_error)
    assert audit.changed_fields == ["enabled"]

    assert status.cleanup.includes_prompts == false
    assert status.cleanup.includes_commands == false
    assert status.cleanup.includes_outputs == false
    assert status.cleanup.includes_errors == false
    assert status.cleanup.includes_raw_session_ids == false
    assert status.cleanup.includes_raw_agent_ids == false
    assert status.cleanup.includes_raw_memory_paths == false
    assert status.cleanup.includes_meta_values == false
    assert status.cleanup.includes_raw_audit_ids == false

    rendered = inspect(status)
    refute rendered =~ private_prompt
    refute rendered =~ private_command
    refute rendered =~ "secret #{token}"
    refute rendered =~ private_output
    refute rendered =~ private_error
    refute rendered =~ private_session
    refute rendered =~ private_memory_path
    refute rendered =~ "private meta value"
    refute rendered =~ audit_id
  end

  test "classifies aborted runs as aborted, not unknown" do
    token = System.unique_integer([:positive, :monotonic])
    job_id = "cron_diag_aborted_job_#{token}"
    run_id = "cron_diag_aborted_run_#{token}"

    on_exit(fn ->
      Store.delete(:cron_runs, run_id)
    end)

    Store.put(:cron_runs, run_id, %{
      id: run_id,
      job_id: job_id,
      status: :aborted,
      started_at_ms: 1_000,
      completed_at_ms: 2_000,
      triggered_by: :manual
    })

    status = CronDiagnostics.status(limit: 50)
    run = Enum.find(status.recent_runs, &(&1.id_hash == short_hash(run_id)))

    assert status.status_counts["aborted"] >= 1
    assert run.status == "aborted"
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
