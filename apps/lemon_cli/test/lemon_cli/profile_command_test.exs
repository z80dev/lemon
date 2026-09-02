defmodule LemonCli.ProfileCommandTestRouter do
  def submit(request) do
    send(
      Application.fetch_env!(:lemon_cli, :profile_command_test_pid),
      {:profile_request, request}
    )

    case Application.get_env(
           :lemon_cli,
           :profile_command_test_submit_result,
           {:ok, "run-profile-cli"}
         ) do
      {:raise, message} -> raise message
      result -> result
    end
  end
end

defmodule LemonCli.ProfileCommandTestControlPlane do
  def request(method, params) do
    send(
      Application.fetch_env!(:lemon_cli, :profile_command_test_pid),
      {:profile_control_plane_request, method, params}
    )

    Application.get_env(
      :lemon_cli,
      :profile_command_test_control_plane_result,
      {:ok,
       %{
         "runId" => "run-profile-control-plane",
         "sessionKey" => "agent:remote-proof:main",
         "node" => "newphy"
       }}
    )
  end
end

defmodule LemonCli.ProfileCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias LemonCli.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-profile-cli-#{System.unique_integer([:positive])}")
    state = Path.join(root, "state")
    config = Path.join(state, "config.toml")
    File.mkdir_p!(state)

    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_control_plane_client = Application.get_env(:lemon_cli, :control_plane_client)

    previous_submit_result =
      Application.get_env(:lemon_cli, :profile_command_test_submit_result)

    previous_control_plane_result =
      Application.get_env(:lemon_cli, :profile_command_test_control_plane_result)

    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: config)
    Application.put_env(:lemon_cli, :profile_command_test_pid, self())

    Application.put_env(
      :lemon_cli,
      :profile_command_test_submit_result,
      {:ok, "run-profile-cli"}
    )

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonCli.ProfileCommandTestRouter,
        router: previous_bridge && previous_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      restore_env(:lemon_cli, :control_plane_client, previous_control_plane_client)
      restore_env(:lemon_cli, :profile_command_test_submit_result, previous_submit_result)

      restore_env(
        :lemon_cli,
        :profile_command_test_control_plane_result,
        previous_control_plane_result
      )

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

  test "profile chat reports an ambiguous submission once with a reconciliation run id" do
    secret = "profile-router-secret-#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.ProfileCommandTestControlPlane
    )

    Application.put_env(
      :lemon_cli,
      :profile_command_test_submit_result,
      {:raise, secret}
    )

    capture_io(fn -> assert CLI.run(["profile", "create", "ambiguous"]) == 0 end)

    log =
      capture_log(fn ->
        error =
          capture_io(:stderr, fn ->
            assert CLI.run(["profile", "chat", "ambiguous", "run", "once"]) == 1
          end)

        send(self(), {:profile_chat_stderr, error})
      end)

    assert_receive {:profile_request, request}
    assert is_binary(request.run_id) and request.run_id != ""
    assert_receive {:profile_chat_stderr, error}
    assert error =~ request.run_id
    assert error =~ "could not be confirmed"
    assert String.downcase(error) =~ "do not retry automatically"
    refute error =~ secret
    refute log =~ secret
    refute_receive {:profile_request, _request}
    refute_receive {:profile_control_plane_request, _method, _params}
  end

  test "profile chat sanitizes explicit router rejection terms" do
    secret = "profile-rejection-secret-#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_cli,
      :profile_command_test_submit_result,
      {:error, {:rejected_with_secret, secret}}
    )

    capture_io(fn -> assert CLI.run(["profile", "create", "rejected"]) == 0 end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["profile", "chat", "rejected", "run", "once"]) == 1
      end)

    assert_receive {:profile_request, request}
    assert is_binary(request.run_id) and request.run_id != ""
    assert error =~ "rejected before acceptance"
    refute error =~ secret
    refute_receive {:profile_request, _request}
  end

  test "profile chat treats a malformed control-plane acknowledgement as outcome unknown" do
    secret = "profile-control-plane-secret-#{System.unique_integer([:positive])}"
    :ok = LemonCore.RouterBridge.configure(run_orchestrator: nil)

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.ProfileCommandTestControlPlane
    )

    Application.put_env(
      :lemon_cli,
      :profile_command_test_control_plane_result,
      {:ok, %{"runId" => 123, "diagnostic" => secret}}
    )

    capture_io(fn -> assert CLI.run(["profile", "create", "malformed-ack"]) == 0 end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["profile", "chat", "malformed-ack", "run", "once"]) == 1
      end)

    assert error =~ "could not be confirmed"
    assert String.downcase(error) =~ "do not retry automatically"
    refute error =~ secret
    assert_receive {:profile_control_plane_request, "profile.chat", _params}
    refute_receive {:profile_control_plane_request, _method, _params}
  end

  test "profile chat distinguishes a sanitized explicit control-plane rejection" do
    secret = "profile-rpc-rejection-secret-#{System.unique_integer([:positive])}"
    :ok = LemonCore.RouterBridge.configure(run_orchestrator: nil)

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.ProfileCommandTestControlPlane
    )

    Application.put_env(
      :lemon_cli,
      :profile_command_test_control_plane_result,
      {:error,
       {:control_plane,
        %{
          "code" => "INVALID_REQUEST",
          "message" => "definite rejection #{secret}"
        }}}
    )

    capture_io(fn -> assert CLI.run(["profile", "create", "rpc-rejected"]) == 0 end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["profile", "chat", "rpc-rejected", "run", "once"]) == 1
      end)

    assert error =~ "rejected before acceptance"
    refute error =~ secret
    assert_receive {:profile_control_plane_request, "profile.chat", _params}
    refute_receive {:profile_control_plane_request, _method, _params}
  end

  test "profile chat preserves an explicit server-side unknown outcome" do
    secret = "profile-rpc-unknown-secret-#{System.unique_integer([:positive])}"
    :ok = LemonCore.RouterBridge.configure(run_orchestrator: nil)

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.ProfileCommandTestControlPlane
    )

    Application.put_env(
      :lemon_cli,
      :profile_command_test_control_plane_result,
      {:error,
       {:control_plane,
        %{
          "code" => "INVALID_REQUEST",
          "message" => "Profile operation failed: :outcome_unknown",
          "details" => secret
        }}}
    )

    capture_io(fn -> assert CLI.run(["profile", "create", "rpc-unknown"]) == 0 end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["profile", "chat", "rpc-unknown", "run", "once"]) == 1
      end)

    assert error =~ "could not be confirmed"
    assert String.downcase(error) =~ "do not retry automatically"
    refute error =~ secret
    assert_receive {:profile_control_plane_request, "profile.chat", _params}
    refute_receive {:profile_control_plane_request, _method, _params}
  end

  test "profile chat reports pre-request control-plane unavailability as not submitted" do
    secret = "profile-connect-secret-#{System.unique_integer([:positive])}"
    :ok = LemonCore.RouterBridge.configure(run_orchestrator: nil)

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.ProfileCommandTestControlPlane
    )

    Application.put_env(
      :lemon_cli,
      :profile_command_test_control_plane_result,
      {:error, {:control_plane_unavailable, {:econnrefused, secret}}}
    )

    capture_io(fn -> assert CLI.run(["profile", "create", "rpc-unavailable"]) == 0 end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["profile", "chat", "rpc-unavailable", "run", "once"]) == 1
      end)

    assert error =~ "nothing was submitted"
    refute error =~ secret
    assert_receive {:profile_control_plane_request, "profile.chat", _params}
    refute_receive {:profile_control_plane_request, _method, _params}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
