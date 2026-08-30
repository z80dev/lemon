defmodule LemonCli.ProfileCommandTestRouter do
  def submit(request) do
    send(
      Application.fetch_env!(:lemon_cli, :profile_command_test_pid),
      {:profile_request, request}
    )

    {:ok, "run-profile-cli"}
  end
end

defmodule LemonCli.ProfileCommandTestControlPlane do
  def request(method, params) do
    send(
      Application.fetch_env!(:lemon_cli, :profile_command_test_pid),
      {:profile_control_plane_request, method, params}
    )

    {:ok,
     %{
       "runId" => "run-profile-control-plane",
       "sessionKey" => "agent:remote-proof:main",
       "node" => "newphy"
     }}
  end
end

defmodule LemonCli.ProfileCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-profile-cli-#{System.unique_integer([:positive])}")
    state = Path.join(root, "state")
    config = Path.join(state, "config.toml")
    File.mkdir_p!(state)

    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_control_plane_client = Application.get_env(:lemon_cli, :control_plane_client)
    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: config)
    Application.put_env(:lemon_cli, :profile_command_test_pid, self())

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonCli.ProfileCommandTestRouter,
        router: previous_bridge && previous_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      restore_env(:lemon_cli, :control_plane_client, previous_control_plane_client)
      Application.delete_env(:lemon_cli, :profile_command_test_pid)

      if Process.whereis(LemonRouter.AgentProfiles) do
        LemonRouter.AgentProfiles.reload()
        _ = LemonRouter.AgentProfiles.list()
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root, state: state, config: config}
  end

  test "packaged profile lifecycle preserves a stable canonical chat", %{root: root} do
    create =
      capture_io(fn ->
        assert CLI.run([
                 "profile",
                 "create",
                 "research",
                 "--name",
                 "Research",
                 "--model",
                 "openai:gpt-5",
                 "--json"
               ]) == 0
      end)

    assert Jason.decode!(create)["canonicalSessionKey"] == "agent:research:main"

    list = capture_io(fn -> assert CLI.run(["profile", "list", "--json"]) == 0 end)
    assert [%{"id" => "research"}] = Jason.decode!(list) |> Enum.map(&Map.take(&1, ["id"]))

    renamed =
      capture_io(fn ->
        assert CLI.run(["profile", "rename", "research", "Research Prime", "--json"]) == 0
      end)

    assert Jason.decode!(renamed)["name"] == "Research Prime"

    roster = capture_io(fn -> assert CLI.run(["profile", "roster", "--json"]) == 0 end)

    assert %{"profiles" => [%{"availability" => "local", "id" => "research"}]} =
             Jason.decode!(roster)

    chat =
      capture_io(fn ->
        assert CLI.run(["profile", "chat", "--json", "research", "hello", "profile"]) == 0
      end)

    assert %{
             "profileId" => "research",
             "runId" => "run-profile-cli",
             "sessionKey" => "agent:research:main"
           } = Jason.decode!(chat)

    assert_receive {:profile_request, request}
    assert request.agent_id == "research"
    assert request.session_key == "agent:research:main"
    assert request.prompt == "hello profile"
    assert request.meta.profile_id == "research"
    assert request.meta.node == "local"
    assert request.cwd == Path.join([root, "state", "profiles", "research", "workspace"])

    exported = Path.join(root, "research.json")

    export_output =
      capture_io(fn ->
        assert CLI.run(["profile", "export", "research", exported, "--json"]) == 0
      end)

    assert Jason.decode!(export_output)["path"] == exported
    assert File.regular?(exported)

    delete =
      capture_io(fn ->
        assert CLI.run([
                 "profile",
                 "delete",
                 "research",
                 "--confirm",
                 "research",
                 "--json"
               ]) == 0
      end)

    assert Jason.decode!(delete)["id"] == "research"
  end

  test "delete requires exact confirmation" do
    capture_io(fn -> assert CLI.run(["profile", "create", "guarded"]) == 0 end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["profile", "delete", "guarded", "--confirm", "wrong"]) == 1
      end)

    assert error =~ "confirmation_required"
  end

  test "one-shot profile chat falls back to the running control plane without cwd override" do
    :ok = LemonCore.RouterBridge.configure(run_orchestrator: nil)

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.ProfileCommandTestControlPlane
    )

    capture_io(fn ->
      assert CLI.run(["profile", "create", "remote-proof", "--node", "newphy"]) == 0
    end)

    chat =
      capture_io(fn ->
        assert CLI.run(["profile", "chat", "--json", "remote-proof", "route", "there"]) == 0
      end)

    assert %{
             "node" => "newphy",
             "profileId" => "remote-proof",
             "runId" => "run-profile-control-plane",
             "sessionKey" => "agent:remote-proof:main"
           } = Jason.decode!(chat)

    assert_receive {:profile_control_plane_request, "profile.chat", params}

    assert params == %{
             "id" => "remote-proof",
             "prompt" => "route there",
             "queueMode" => "collect"
           }

    refute Map.has_key?(params, "cwd")
    refute Map.has_key?(params, "node")
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
