defmodule LemonControlPlane.TuiProfilesWireRouter do
  def submit(request) do
    send(
      Application.fetch_env!(:lemon_control_plane, :tui_profiles_wire_test_pid),
      {:tui_profile_wire_request, request}
    )

    {:ok, "run-tui-profile-wire"}
  end
end

defmodule LemonControlPlane.TuiProfilesWireE2ETest do
  use ExUnit.Case, async: false

  @operator_token "tui-profile-wire-operator-token"

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "lemon-tui-profile-wire-#{suffix}")
    state = Path.join(root, "state")
    config = Path.join(state, "config.toml")
    File.mkdir_p!(state)

    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: config)
    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    Application.put_env(:lemon_control_plane, :tui_profiles_wire_test_pid, self())

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonControlPlane.TuiProfilesWireRouter,
        router: previous_bridge && previous_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      restore_env(:lemon_control_plane, :operator_token, previous_token)

      restore_env(
        :lemon_control_plane,
        :allow_unauthenticated_loopback_operator,
        previous_loopback
      )

      Application.delete_env(:lemon_control_plane, :tui_profiles_wire_test_pid)

      if Process.whereis(LemonRouter.AgentProfiles) do
        LemonRouter.AgentProfiles.reload()
        _ = LemonRouter.AgentProfiles.list()
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root, suffix: suffix}
  end

  test "the typed Bun TUI client crosses authenticated Bandit for profile lifecycle and chat", %{
    root: root,
    suffix: suffix
  } do
    bun = System.find_executable("bun") || flunk("bun is required for the TUI wire proof")

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:tui_profiles_wire_bandit, suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    export_path = Path.join(root, "tui-wire-export.json")
    repo_root = Path.expand("../../../..", __DIR__)
    proof_client = Path.join(repo_root, "clients/tui/scripts/profiles-wire-proof.ts")

    {output, status} =
      System.cmd(
        bun,
        [
          proof_client,
          "ws://127.0.0.1:#{port}/ws",
          @operator_token,
          export_path
        ],
        cd: repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, proof} = Jason.decode(String.trim(output))
    assert proof["ok"] == true
    assert proof["sessionKey"] == "agent:tui-wire:main"
    assert proof["node"] == "wire-node"
    assert File.regular?(export_path)

    assert_receive {:tui_profile_wire_request, request}, 3_000
    assert request.session_key == "agent:tui-wire:main"
    assert request.agent_id == "tui-wire"
    assert request.queue_mode == :steer
    assert request.meta.profile_id == "tui-wire"
    assert request.meta.node == "wire-node"
    assert request.cwd == nil
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
