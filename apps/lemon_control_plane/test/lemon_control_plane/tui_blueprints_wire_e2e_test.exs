defmodule LemonControlPlane.TuiBlueprintsWireE2ETest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronStore}
  alias LemonCore.ProfileStore

  @operator_token "tui-blueprint-wire-operator-token"

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    marker = "PLANTED_TUI_BLUEPRINT_#{suffix}"
    root = Path.join(System.tmp_dir!(), "lemon-tui-blueprint-wire-#{suffix}")
    state = Path.join(root, "state")
    profile_opts = [home_state_dir: state, config_path: Path.join(state, "config.toml")]
    catalog = Path.join(state, "bundles")
    profile_id = "tui-blueprint-profile-#{suffix}"
    bundle_id = "tui-blueprint-bundle-#{suffix}"
    automation_id = "tui-blueprint-job-#{suffix}"
    File.mkdir_p!(catalog)

    assert {:ok, profile} = ProfileStore.create(%{id: profile_id}, profile_opts)
    bundle = write_bundle(catalog, bundle_id, automation_id, marker)

    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    previous_blueprint_opts = Application.get_env(:lemon_control_plane, :blueprint_opts)

    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    Application.put_env(:lemon_control_plane, :blueprint_opts,
      profile_opts: profile_opts,
      refresh_fun: fn _ -> :ok end
    )

    on_exit(fn ->
      CronManager.list()
      |> Enum.filter(&(get_in(&1.meta, ["blueprint", "bundleId"]) == bundle_id))
      |> Enum.each(&CronManager.remove(&1.id))

      restore_env(:operator_token, previous_token)
      restore_env(:allow_unauthenticated_loopback_operator, previous_loopback)
      restore_env(:blueprint_opts, previous_blueprint_opts)
      File.rm_rf!(root)
    end)

    {:ok,
     suffix: suffix,
     marker: marker,
     root: root,
     profile: profile,
     profile_id: profile_id,
     bundle: bundle,
     bundle_id: bundle_id}
  end

  test "the production TUI crosses authenticated Bandit for guarded blueprint activation", ctx do
    bun = System.find_executable("bun") || flunk("bun is required for the TUI wire proof")

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:tui_blueprints_wire_bandit, ctx.suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    repo_root = Path.expand("../../../..", __DIR__)
    proof_client = Path.join(repo_root, "clients/tui/scripts/blueprints-wire-proof.ts")
    skill_path = Path.join(ctx.profile["paths"]["skills"], "safe-note/SKILL.md")
    refute File.exists?(skill_path)
    assert matching_jobs(ctx.bundle_id) == []

    {output, status} =
      System.cmd(
        bun,
        [
          proof_client,
          "ws://127.0.0.1:#{port}/ws",
          @operator_token,
          ctx.bundle_id,
          ctx.profile_id,
          ctx.marker,
          ctx.root
        ],
        cd: repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, proof} = Jason.decode(String.trim(output))
    assert proof["ok"] == true
    assert proof["created"] == true
    assert proof["replay"] == "unchanged"
    assert length(proof["checks"]) == 7
    refute output =~ ctx.marker
    refute output =~ ctx.root
    refute output =~ @operator_token

    assert File.regular?(skill_path)
    assert File.read!(skill_path) =~ ctx.marker
    assert [job] = matching_jobs(ctx.bundle_id)
    assert CronStore.get_job(job.id).prompt =~ ctx.marker
  end

  defp matching_jobs(bundle_id) do
    CronManager.list()
    |> Enum.filter(&(get_in(&1.meta, ["blueprint", "bundleId"]) == bundle_id))
  end

  defp write_bundle(root, bundle_id, automation_id, marker) do
    bundle = Path.join(root, bundle_id)
    skill = Path.join([bundle, "skills", "safe-note"])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      """
      ---
      name: safe-note
      description: Harmless TUI blueprint wire proof
      ---

      # Safe note

      #{marker} planted skill body must stay out of terminal state.
      Summarize completed work without external changes.
      """
    )

    manifest = %{
      "format" => "lemon-skill-automation-bundle",
      "version" => 1,
      "id" => bundle_id,
      "name" => "#{marker} planted private blueprint name",
      "description" => "#{marker} planted private blueprint description",
      "skills" => [%{"key" => "safe-note", "path" => "skills/safe-note"}],
      "automations" => [
        %{
          "id" => automation_id,
          "kind" => "cron",
          "name" => "#{marker} planted private automation name",
          "schedule" => "0 0 1 1 *",
          "prompt" => "#{marker} planted prompt must stay out of terminal state.",
          "enabled" => false,
          "timezone" => "UTC"
        }
      ]
    }

    File.write!(Path.join(bundle, "bundle.json"), Jason.encode!(manifest, pretty: true))
    bundle
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_control_plane, key, value)
end
