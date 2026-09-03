defmodule LemonControlPlane.ProfilesTestRouter do
  def submit(request) do
    send(
      Application.fetch_env!(:lemon_control_plane, :profiles_test_pid),
      {:profile_request, request}
    )

    case Application.fetch_env!(:lemon_control_plane, :profiles_test_submit_result) do
      {:raise, message} -> raise message
      result -> result
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonControlPlane.Methods.{
    ProfileChat,
    ProfilesClone,
    ProfilesCreate,
    ProfilesDelete,
    ProfilesExport,
    ProfilesGet,
    ProfilesList,
    ProfilesRename,
    ProfilesRoster
  }

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-profiles-cp-#{System.unique_integer([:positive])}")
    state = Path.join(root, "state")
    config = Path.join(state, "config.toml")
    File.mkdir_p!(state)

    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: config)
    Application.put_env(:lemon_control_plane, :profiles_test_pid, self())

    Application.put_env(
      :lemon_control_plane,
      :profiles_test_submit_result,
      {:ok, "run-profile-control-plane"}
    )

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonControlPlane.ProfilesTestRouter,
        router: previous_bridge && previous_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      Application.delete_env(:lemon_control_plane, :profiles_test_pid)
      Application.delete_env(:lemon_control_plane, :profiles_test_submit_result)

      if Process.whereis(LemonRouter.AgentProfiles) do
        LemonRouter.AgentProfiles.reload()
        _ = LemonRouter.AgentProfiles.list()
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "profile chat returns a bounded reconciliation receipt for outcome-unknown submission" do
    assert {:ok, %{"profile" => _profile}} =
             ProfilesCreate.handle(%{"id" => "uncertain", "name" => "Uncertain"}, %{})

    secret = "PROFILE_SUBMIT_SECRET_#{System.unique_integer([:positive])}"
    private_path = "/private/profile/#{secret}"

    Application.put_env(
      :lemon_control_plane,
      :profiles_test_submit_result,
      {:raise, "post-submit failure #{secret} at #{private_path}"}
    )

    result =
      capture_log(fn ->
        assert {:error, {:unavailable, "Profile chat submission outcome is unknown", details}} =
                 ProfileChat.handle(
                   %{"id" => "uncertain", "prompt" => "do not echo #{secret}"},
                   %{}
                 )

        assert details == %{
                 "code" => "SUBMISSION_OUTCOME_UNKNOWN",
                 "runId" => details["runId"],
                 "profileId" => "uncertain",
                 "sessionKey" => "agent:uncertain:main",
                 "retrySafe" => false
               }

        assert is_binary(details["runId"])
        assert_receive {:profile_request, request}
        assert request.run_id == details["runId"]
        refute_receive {:profile_request, _request}, 50
      end)

    assert result =~ "failure_class=exception"
    refute result =~ secret
    refute result =~ private_path
  end

  test "profile operation errors do not expose raw router reasons" do
    assert {:ok, %{"profile" => _profile}} =
             ProfilesCreate.handle(%{"id" => "sanitized", "name" => "Sanitized"}, %{})

    secret = "PROFILE_REASON_SECRET_#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_control_plane,
      :profiles_test_submit_result,
      {:error, {:router_rejected, %{credential: secret, path: "/private/#{secret}"}}}
    )

    log =
      capture_log(fn ->
        result =
          ProfileChat.handle(%{"id" => "sanitized", "prompt" => "safe prompt"}, %{})

        assert result == {:error, {:internal_error, "Profile operation failed"}}
        refute inspect(result) =~ secret
      end)

    assert log =~ "class=tuple"
    refute log =~ secret
  end

  test "lifecycle, roster, export, and canonical chat share one profile record", %{root: root} do
    assert {:ok, %{"profile" => created}} =
             ProfilesCreate.handle(
               %{
                 "id" => "operator",
                 "name" => "Operator",
                 "model" => "openai:gpt-5"
               },
               %{}
             )

    assert created["canonicalSessionKey"] == "agent:operator:main"
    assert {:ok, %{"profiles" => [%{"id" => "operator"}]}} = ProfilesList.handle(%{}, %{})

    assert {:ok, %{"profile" => %{"id" => "operator"}}} =
             ProfilesGet.handle(%{"id" => "operator"}, %{})

    assert {:ok, %{"profile" => %{"id" => "operator-copy"}}} =
             ProfilesClone.handle(
               %{"sourceId" => "operator", "id" => "operator-copy", "name" => "Copy"},
               %{}
             )

    assert {:ok, %{"profile" => renamed}} =
             ProfilesRename.handle(%{"id" => "operator", "name" => "Operator Prime"}, %{})

    assert renamed["canonicalSessionKey"] == "agent:operator:main"

    assert {:ok, %{"profiles" => roster}} = ProfilesRoster.handle(%{}, %{})
    assert Enum.any?(roster, &match?(%{"id" => "operator", "availability" => "local"}, &1))

    assert {:ok, chat} =
             ProfileChat.handle(%{"id" => "operator", "prompt" => "work the queue"}, %{})

    assert chat["runId"] == "run-profile-control-plane"
    assert chat["sessionKey"] == "agent:operator:main"
    refute inspect(chat) =~ "work the queue"

    assert_receive {:profile_request, request}
    assert is_binary(request.run_id)
    assert request.meta.profile_id == "operator"
    assert request.cwd == created["paths"]["workspace"]

    destination = Path.join(root, "operator-export.json")

    assert {:ok, %{"export" => %{"profileId" => "operator"}}} =
             ProfilesExport.handle(%{"id" => "operator", "path" => destination}, %{})

    assert {:error, {:invalid_request, message}} =
             ProfilesDelete.handle(%{"id" => "operator", "confirm" => "wrong"}, %{})

    assert message =~ "confirmation_required"

    assert {:ok, %{"deleted" => %{"id" => "operator"}}} =
             ProfilesDelete.handle(%{"id" => "operator", "confirm" => "operator"}, %{})
  end

  test "schemas exist for every profile method" do
    for method <- ~w(
          profiles.list profiles.get profiles.create profiles.clone profiles.rename
          profiles.export profiles.delete profiles.roster profile.chat
        ) do
      assert is_map(LemonControlPlane.Protocol.Schemas.get(method)), method
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
