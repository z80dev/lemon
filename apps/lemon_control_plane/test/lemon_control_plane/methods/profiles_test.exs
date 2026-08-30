defmodule LemonControlPlane.ProfilesTestRouter do
  def submit(request) do
    send(
      Application.fetch_env!(:lemon_control_plane, :profiles_test_pid),
      {:profile_request, request}
    )

    {:ok, "run-profile-control-plane"}
  end
end

defmodule LemonControlPlane.Methods.ProfilesTest do
  use ExUnit.Case, async: false

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

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonControlPlane.ProfilesTestRouter,
        router: previous_bridge && previous_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      Application.delete_env(:lemon_control_plane, :profiles_test_pid)

      if Process.whereis(LemonRouter.AgentProfiles) do
        LemonRouter.AgentProfiles.reload()
        _ = LemonRouter.AgentProfiles.list()
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
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
