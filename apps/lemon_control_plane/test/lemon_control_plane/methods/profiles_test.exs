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

  def submit_with_receipt(request) do
    case submit(request) do
      {:ok, _} -> {:ok, %{run_id: request.run_id, session_key: request.session_key,
                         state: :accepted, effective_mode: :new_run, target_run_id: request.run_id}}
      error -> error
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonAi.Types.ImageContent
  alias LemonControlPlane.Protocol.Schemas

  @png_data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

  alias LemonControlPlane.Methods.{
    ProfileChat,
    ProfilesClone,
    ProfilesCreate,
    ProfilesDelete,
    ProfilesExport,
    ProfilesGet,
    ProfilesList,
    ProfilesRename,
    ProfilesRoster,
    ProfilesUpdate
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

  test "profiles update reloads placement while every management result redacts MCP headers" do
    server = %{"name" => "lemon-bot", "url" => "https://bot.example/mcp",
               "headers" => %{"Authorization" => "Bearer execution-secret"}}

    assert :ok = Schemas.validate("profiles.create", %{"id" => "placed", "mcpServers" => [server]})
    assert {:ok, created} = ProfilesCreate.handle(%{"id" => "placed", "mcpServers" => [server]}, %{})
    refute inspect(created) =~ "execution-secret"
    assert :ok = Schemas.validate("profiles.update", %{"id" => "placed", "node" => "worker"})
    assert {:ok, updated} = ProfilesUpdate.handle(%{
      "id" => "placed", "node" => "worker", "systemPrompt" => "Be precise",
      "model" => "openai:gpt-5", "name" => "Placed Bot"
    }, %{})
    assert updated["profile"]["node"] == "worker"
    assert updated["profile"]["name"] == "Placed Bot"
    assert updated["profile"]["mcpServers"] == [Map.delete(server, "headers")]

    assert {:ok, fetched} = ProfilesGet.handle(%{"id" => "placed"}, %{})
    assert {:ok, listed} = ProfilesList.handle(%{}, %{})
    refute inspect(fetched) =~ "execution-secret"
    refute inspect(listed) =~ "execution-secret"
    assert {:ok, receipt} = ProfileChat.handle(%{"id" => "placed", "prompt" => "Investigate"}, %{})
    assert receipt["node"] == "worker"
    assert_receive {:profile_request, request}
    assert request.cwd == nil
    assert request.meta.remote_cwd_explicit == false
    assert request.meta.system_prompt == "Be precise"
    assert request.meta.mcp_servers == [server]
    assert request.model == "openai:gpt-5"
    if Process.whereis(LemonRouter.AgentProfiles) do
      assert LemonRouter.AgentProfiles.get("placed").system_prompt == "Be precise"
    end
    assert {:error, {:not_found, _}} = ProfilesUpdate.handle(%{"id" => "missing", "name" => "x"}, %{})
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
                   %{
                     "id" => "uncertain",
                     "runId" => "profile-uncertain-fixed",
                     "prompt" => "do not echo #{secret}",
                     "images" => [image()]
                   },
                   %{}
                 )

        assert details == %{
                 "code" => "SUBMISSION_OUTCOME_UNKNOWN",
                 "runId" => details["runId"],
                 "profileId" => "uncertain",
                 "sessionKey" => "agent:uncertain:main",
                 "retrySafe" => false
               }

        assert details["runId"] == "profile-uncertain-fixed"
        assert_receive {:profile_request, request}
        assert request.run_id == details["runId"]
        assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
        refute inspect(details) =~ @png_data
        refute_receive {:profile_request, _request}, 50
      end)

    assert result =~ "failure_class=exception"
    refute result =~ secret
    refute result =~ private_path
    refute result =~ @png_data
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

        assert {:error, {:internal_error, _message}} = result
        refute inspect(result) =~ secret
      end)

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
             ProfileChat.handle(%{"id" => "operator", "prompt" => "work the queue",
                                  "runId" => "profile-fixed"}, %{})

    assert chat["runId"] == "profile-fixed"
    assert chat["effectiveMode"] == "new_run"
    assert chat["targetRunId"] == "profile-fixed"
    assert chat["sessionKey"] == "agent:operator:main"
    refute inspect(chat) =~ "work the queue"

    assert_receive {:profile_request, request}
    assert is_binary(request.run_id)
    assert request.meta.profile_id == "operator"
    assert request.cwd == created["paths"]["workspace"]
    assert request.images == []

    destination = Path.join(root, "operator-export.json")

    assert {:ok, %{"export" => %{"profileId" => "operator"}}} =
             ProfilesExport.handle(%{"id" => "operator", "path" => destination}, %{})

    assert {:error, {:invalid_request, message}} =
             ProfilesDelete.handle(%{"id" => "operator", "confirm" => "wrong"}, %{})

    assert message =~ "confirmation_required"

    assert {:ok, %{"deleted" => %{"id" => "operator"}}} =
             ProfilesDelete.handle(%{"id" => "operator", "confirm" => "operator"}, %{})
  end

  test "canonical profile images preserve server-owned workspace node session and model" do
    assert {:ok, %{"profile" => profile}} =
             ProfilesCreate.handle(
               %{"id" => "image-profile", "name" => "Image Profile", "model" => "openai:gpt-5"},
               %{}
             )

    assert {:ok, result} =
             ProfileChat.handle(
               %{
                 "id" => "image-profile",
                 "prompt" => "describe the image",
                 "images" => [Map.put(image(), "privateMetadata", "not forwarded")],
                 "cwd" => "/caller/controlled",
                 "node" => "caller-node",
                 "sessionKey" => "agent:caller:main",
                 "agentId" => "caller"
               },
               %{}
             )

    assert_receive {:profile_request, request}
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    assert request.prompt == "describe the image"
    assert request.cwd == profile["paths"]["workspace"]
    assert request.session_key == profile["canonicalSessionKey"]
    assert request.agent_id == "image-profile"
    assert request.model == "openai:gpt-5"
    assert request.meta.profile_id == "image-profile"
    assert request.meta.node == "local"
    assert is_binary(request.run_id)
    assert result["node"] == "local"
    refute inspect(result) =~ @png_data
    refute inspect(result) =~ "privateMetadata"
  end

  test "image-only profile chat keeps the empty prompt and canonical request" do
    assert {:ok, %{"profile" => profile}} =
             ProfilesCreate.handle(%{"id" => "image-only", "name" => "Image Only"}, %{})

    assert {:ok, result} =
             ProfileChat.handle(
               %{"id" => "image-only", "prompt" => "", "images" => [image()]},
               %{}
             )

    assert_receive {:profile_request, request}
    assert request.prompt == ""
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    assert request.cwd == profile["paths"]["workspace"]
    assert request.session_key == profile["canonicalSessionKey"]
    assert result["summary"]["promptBytes"] == 0
    refute inspect(result) =~ @png_data
  end

  test "empty profile prompt without images remains invalid" do
    assert {:ok, _} =
             ProfilesCreate.handle(%{"id" => "empty-image", "name" => "Empty Image"}, %{})

    for params <- [
          %{"id" => "empty-image", "prompt" => ""},
          %{"id" => "empty-image", "prompt" => "", "images" => []}
        ] do
      assert {:error, {:invalid_request, "Profile field is invalid"}} =
               ProfileChat.handle(params, %{})

      refute_received {:profile_request, _}
    end
  end

  test "invalid images are rejected before profile refresh and router submission" do
    if Process.whereis(LemonRouter.AgentProfiles) == nil do
      start_supervised!(LemonRouter.AgentProfiles)
    end

    assert {:ok, _} =
             ProfilesCreate.handle(%{"id" => "invalid-image", "name" => "Invalid Image"}, %{})

    _ = LemonRouter.AgentProfiles.list()
    pid = Process.whereis(LemonRouter.AgentProfiles)
    :erlang.trace(pid, true, [:receive])

    try do
      for images <- [
            nil,
            %{},
            "PRIVATE_IMAGE_PAYLOAD",
            [Map.put(image(), "data", "PRIVATE_IMAGE_PAYLOAD")],
            [Map.put(image(), "mime_type", "text/plain")],
            List.duplicate(image(), 6)
          ] do
        assert {:error, {:invalid_request, message, nil}} =
                 ProfileChat.handle(
                   %{"id" => "invalid-image", "prompt" => "valid prompt", "images" => images},
                   %{}
                 )

        assert byte_size(message) < 256
        refute message =~ "PRIVATE_IMAGE_PAYLOAD"
        refute message =~ @png_data
        refute_received {:profile_request, _}
      end

      _ = LemonRouter.AgentProfiles.list()
      refute_receive {:trace, ^pid, :receive, {:"$gen_cast", :reload}}, 100
    after
      :erlang.trace(pid, false, [:receive])
    end
  end

  test "JSON image arrays pass the canonical profile request validation boundary" do
    assert :ok = Schemas.validate("profile.chat", %{"id" => "profile", "prompt" => "hello"})

    assert :ok =
             Schemas.validate("profile.chat", %{
               "id" => "profile",
               "prompt" => "",
               "images" => [image()]
             })

    assert {:error, _} =
             Schemas.validate("profile.chat", %{
               "id" => "profile",
               "prompt" => "hello",
               "images" => %{}
             })
  end

  test "schemas exist for every profile method" do
    for method <- ~w(
          profiles.list profiles.get profiles.create profiles.clone profiles.rename
          profiles.export profiles.delete profiles.roster profile.chat
        ) do
      assert is_map(LemonControlPlane.Protocol.Schemas.get(method)), method
    end
  end

  defp image do
    %{"type" => "image", "mime_type" => "image/png", "data" => @png_data}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
