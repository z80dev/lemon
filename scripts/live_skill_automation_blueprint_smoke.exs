smoke_boot_dir =
  Path.join(
    System.tmp_dir!(),
    "lemon-blueprint-runtime-#{System.unique_integer([:positive, :monotonic])}"
  )

Application.put_env(:lemon_control_plane, :blueprint_smoke_boot_dir, smoke_boot_dir)
Application.put_env(:lemon_control_plane, :port, 0)
Application.put_env(:lemon_router, :health_port, 0)
Application.put_env(:lemon_gateway, :health_port, 0)
Application.put_env(:lemon_channels, :adapters, [])
Application.put_env(:lemon_skills, :seed_builtin_skills, false)
Application.put_env(:lemon_automation, :skill_curator, enabled: false)
Application.put_env(:lemon_automation, :synthesis_runner, enabled: false)
Application.put_env(:lemon_core, :paths, home_state_dir: Path.join(smoke_boot_dir, "state"))

Application.put_env(
  :lemon_core,
  LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []
)

Application.put_env(
  :lemon_core,
  LemonCore.RunHistoryStore,
  path: Path.join(smoke_boot_dir, "run-history")
)

Application.put_env(
  :lemon_memory,
  LemonMemory.Store,
  path: Path.join(smoke_boot_dir, "memory")
)

Application.put_env(
  :lemon_router,
  LemonRouter.RoutingFeedbackStore,
  path: Path.join(smoke_boot_dir, "routing-feedback")
)

{:ok, _} = Application.ensure_all_started(:lemon_control_plane)

defmodule LemonScripts.LiveSkillAutomationBlueprintSmoke do
  alias LemonAutomation.{CronManager, CronStore}
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.Registry
  alias LemonCore.ProfileStore

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    proof_path =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "skill-automation-blueprint-latest.json"])

    fixture = fixture()
    old_blueprint_opts = Application.get_env(:lemon_control_plane, :blueprint_opts)

    Application.put_env(
      :lemon_control_plane,
      :blueprint_opts,
      profile_opts: fixture.profile_opts
    )

    proof =
      try do
        run(fixture)
      rescue
        exception ->
          build_proof([
            check("skill_automation_blueprint_smoke", false, %{
              reason_kind: exception.__struct__ |> inspect()
            })
          ])
      end

    cleanup = cleanup(fixture, old_blueprint_opts)
    proof = Map.put(proof, :cleanup, cleanup)

    write_json!(proof_path, proof)
    write_json!(archive_path(proof_path), proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0 or not Enum.all?(Map.values(cleanup)), do: System.halt(1)
  end

  defp run(fixture) do
    {:ok, profile} =
      ProfileStore.create(
        %{id: fixture.profile_id, name: "Blueprint Smoke"},
        fixture.profile_opts
      )

    File.mkdir_p!(fixture.catalog)
    {:ok, _} = File.cp_r(fixture.example_bundle, fixture.catalog_bundle)

    list = rpc!("blueprints.list", %{})
    inspected = rpc!("blueprints.inspect", %{"bundleId" => fixture.bundle_id})
    validated = rpc!("blueprints.validate", %{"bundleId" => fixture.bundle_id})

    preview =
      rpc!("blueprints.preview", %{
        "bundleId" => fixture.bundle_id,
        "profileId" => fixture.profile_id
      })

    activated =
      rpc!("blueprints.activate", %{
        "bundleId" => fixture.bundle_id,
        "profileId" => fixture.profile_id,
        "confirmationDigest" => preview["confirmationDigest"]
      })

    job_id = activated["automation"]["id"]
    job = CronStore.get_job(job_id)

    replay_preview =
      rpc!("blueprints.preview", %{
        "bundleId" => fixture.bundle_id,
        "profileId" => fixture.profile_id
      })

    replayed =
      rpc!("blueprints.activate", %{
        "bundleId" => fixture.bundle_id,
        "profileId" => fixture.profile_id,
        "confirmationDigest" => replay_preview["confirmationDigest"]
      })

    wire = Jason.encode!([list, inspected, validated, preview, activated, replayed])

    checks = [
      check(
        "booted_control_plane_catalog",
        Enum.any?(list["bundles"], &(&1["id"] == fixture.bundle_id)),
        %{bundle_count: list["summary"]["bundleCount"]}
      ),
      check(
        "content_free_inspect_and_validation",
        inspected["validation"]["valid"] and validated["validation"]["valid"] and
          not String.contains?(wire, fixture.example_bundle) and
          not String.contains?(wire, profile["paths"]["workspace"]) and
          not String.contains?(wire, job.prompt),
        %{manifest_digest: inspected["manifestDigest"]}
      ),
      check(
        "exact_confirmed_activation",
        preview["canActivate"] and activated["automation"]["status"] == "created" and
          is_binary(preview["confirmationDigest"]) and
          byte_size(preview["confirmationDigest"]) == 64,
        %{
          confirmation_digest: preview["confirmationDigest"],
          job_id_sha256: sha256(job_id)
        }
      ),
      check(
        "profile_local_skill_enabled",
        match?({:ok, _}, LemonSkills.get("daily-note", cwd: profile["paths"]["workspace"])) and
          File.regular?(Path.join([profile["paths"]["skills"], "daily-note", "SKILL.md"])),
        %{profile_id_sha256: sha256(fixture.profile_id)}
      ),
      check(
        "cron_manager_provenance",
        job.enabled == false and job.command == nil and
          get_in(job.meta, ["blueprint", "bundleId"]) == fixture.bundle_id and
          get_in(job.meta, ["blueprint", "manifestDigest"]) == preview["manifestDigest"] and
          get_in(job.meta, ["blueprint", "definitionDigest"]) == preview["definitionDigest"],
        %{enabled: job.enabled, trust_level: get_in(job.meta, ["blueprint", "trustLevel"])}
      ),
      check(
        "duplicate_safe_replay",
        replay_preview["automation"]["action"] == "unchanged" and
          replayed["automation"]["status"] == "unchanged" and
          Enum.count(CronManager.list(), &(&1.id == job_id)) == 1,
        %{matching_job_count: Enum.count(CronManager.list(), &(&1.id == job_id))}
      )
    ]

    build_proof(checks)
  end

  defp rpc!(method, params) do
    context = %{
      conn_id: "skill-automation-blueprint-smoke",
      conn_pid: self(),
      auth: Authorize.default_operator()
    }

    case Registry.dispatch(method, params, context) do
      {:ok, result} -> result
      {:error, _reason} -> raise "blueprint RPC failed"
    end
  end

  defp cleanup(fixture, old_blueprint_opts) do
    matching_jobs =
      CronManager.list()
      |> Enum.filter(fn job ->
        job.agent_id == fixture.profile_id and
          get_in(job.meta, ["blueprint", "bundleId"]) == fixture.bundle_id
      end)

    Enum.each(matching_jobs, &CronManager.remove(&1.id))

    if old_blueprint_opts do
      Application.put_env(:lemon_control_plane, :blueprint_opts, old_blueprint_opts)
    else
      Application.delete_env(:lemon_control_plane, :blueprint_opts)
    end

    _ = File.rm_rf(fixture.temp_dir)
    boot_dir = Application.fetch_env!(:lemon_control_plane, :blueprint_smoke_boot_dir)
    _ = File.rm_rf(boot_dir)

    %{
      automation_removed:
        not Enum.any?(CronManager.list(), fn job -> job.agent_id == fixture.profile_id end),
      isolated_profile_removed: not File.exists?(fixture.temp_dir),
      isolated_runtime_state_removed: not File.exists?(boot_dir),
      prior_control_plane_config_restored:
        Application.get_env(:lemon_control_plane, :blueprint_opts) == old_blueprint_opts,
      no_secret_values_written: true
    }
  end

  defp fixture do
    suffix = System.unique_integer([:positive, :monotonic])
    temp_dir = Path.join(System.tmp_dir!(), "lemon-blueprint-smoke-#{suffix}")
    state_dir = Path.join(temp_dir, "state")
    profile_id = "blueprint-smoke-#{suffix}"

    %{
      bundle_id: "daily-note",
      profile_id: profile_id,
      temp_dir: temp_dir,
      catalog: Path.join(state_dir, "bundles"),
      catalog_bundle: Path.join([state_dir, "bundles", "daily-note"]),
      example_bundle:
        Path.join([File.cwd!(), "examples", "skill-automation-bundles", "daily-note"]),
      profile_opts: [
        home_state_dir: state_dir,
        config_path: Path.join(state_dir, "config.toml")
      ]
    }
  end

  defp build_proof(checks) do
    failed_count = Enum.count(checks, &(&1.status == "failed"))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      proof_object: "lemon.skill_automation_blueprint_smoke",
      runtime: "booted_umbrella_control_plane",
      status: if(failed_count == 0, do: "completed", else: "failed"),
      checks: checks,
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      failed_count: failed_count
    }
  end

  defp check(name, passed?, details) do
    %{name: name, status: if(passed?, do: "completed", else: "failed"), details: details}
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp archive_path(path) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(Path.dirname(path), "skill-automation-blueprint-#{timestamp}.json")
  end
end

LemonScripts.LiveSkillAutomationBlueprintSmoke.main(System.argv())
