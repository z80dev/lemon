defmodule LemonControlPlane.Methods.ChatSendTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ChatSend
  alias LemonControlPlane.Protocol.Schemas
  alias LemonAi.Types.ImageContent

  @png_data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

  defmodule RouterStub do
    def submit(params) do
      send(self(), {:submitted, params})
      {:ok, "run_chat_cwd"}
    end
  end

  defmodule RejectingRouterStub do
    def submit(params), do: {:error, {:rejected, params}}
  end

  defmodule UnknownRouterStub do
    def submit(params) do
      send(self(), {:submitted, params})
      {:error, :outcome_unknown}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "chat-send-cwd-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    config = Path.join(root, "config.toml")
    File.write!(config, "[profiles.workspace]\nname = \"Workspace\"\n")
    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      (previous_paths || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root)
    )

    on_exit(fn ->
      if is_nil(previous_paths) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous_paths)
      end

      File.rm_rf!(root)
    end)

    %{root: root, ctx: %{router_mod: RouterStub}}
  end

  test "valid absolute cwd reaches the router request unchanged", %{root: root, ctx: ctx} do
    assert {:ok, %{"runId" => "run_chat_cwd"}} =
             ChatSend.handle(params(%{"cwd" => root}), ctx)

    assert_received {:submitted, request}
    assert request.cwd == root
    assert request.session_key == "agent:chat-workspace:main"
    assert request.prompt == "hello"
  end

  test "omission does not add a cwd override", %{ctx: ctx} do
    assert {:ok, _} = ChatSend.handle(params(), ctx)
    assert_received {:submitted, request}
    refute Map.has_key?(request, :cwd)
    assert request.images == []
  end

  test "invalid cwd is rejected before submission", %{root: root, ctx: ctx} do
    file = Path.join(root, "file.txt")
    File.write!(file, "not a directory")

    for cwd <- ["relative", "", nil, 123, %{}, [], Path.join(root, "missing"), file] do
      assert {:error, {:invalid_request, _, nil}} =
               ChatSend.handle(params(%{"cwd" => cwd}), ctx)

      refute_received {:submitted, _}
    end
  end

  test "canonical profile session rejects caller cwd", %{root: root, ctx: ctx} do
    assert {:ok, profile} = LemonCore.ProfileStore.get("workspace")

    assert {:error, {:invalid_request, "cwd cannot override a canonical profile session", nil}} =
             ChatSend.handle(
               params(%{"sessionKey" => profile["canonicalSessionKey"], "cwd" => root}),
               ctx
             )

    refute_received {:submitted, _}
  end

  test "canonical profile session without cwd retains existing submission", %{ctx: ctx} do
    assert {:ok, profile} = LemonCore.ProfileStore.get("workspace")

    assert {:ok, _} =
             ChatSend.handle(params(%{"sessionKey" => profile["canonicalSessionKey"]}), ctx)

    assert_received {:submitted, request}
    refute Map.has_key?(request, :cwd)
  end

  test "noncanonical session for a profile can use caller cwd", %{root: root, ctx: ctx} do
    assert {:ok, _} =
             ChatSend.handle(
               params(%{"sessionKey" => "agent:workspace:thread:workspace-test", "cwd" => root}),
               ctx
             )

    assert_received {:submitted, %{cwd: ^root}}
  end

  test "real image content is normalized and forwarded without extra fields", %{ctx: ctx} do
    image = Map.put(image(), "privateMetadata", "not forwarded")

    assert {:ok, result} = ChatSend.handle(params(%{"images" => [image]}), ctx)
    assert_received {:submitted, request}
    assert request.prompt == "hello"
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    assert result["summary"]["promptBytes"] == 5
    refute inspect(result) =~ @png_data
    refute inspect(result) =~ "privateMetadata"
  end

  test "image-only submission preserves the empty prompt", %{ctx: ctx} do
    assert {:ok, result} =
             ChatSend.handle(params(%{"prompt" => "", "images" => [image()]}), ctx)

    assert_received {:submitted, request}
    assert request.prompt == ""
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    assert result["summary"]["promptBytes"] == 0
  end

  test "empty prompt without images retains ordinary submission behavior", %{ctx: ctx} do
    assert {:ok, _} = ChatSend.handle(params(%{"prompt" => ""}), ctx)
    assert_received {:submitted, %{prompt: "", images: []}}
  end

  test "invalid images fail before router submission with bounded errors", %{ctx: ctx} do
    for images <- [
          nil,
          %{},
          "PRIVATE_IMAGE_PAYLOAD",
          [Map.put(image(), "data", "PRIVATE_IMAGE_PAYLOAD")],
          [Map.put(image(), "mime_type", "text/plain")],
          List.duplicate(image(), 6)
        ] do
      assert {:error, {:invalid_request, message, nil}} =
               ChatSend.handle(params(%{"images" => images}), ctx)

      assert byte_size(message) < 256
      refute message =~ "PRIVATE_IMAGE_PAYLOAD"
      refute message =~ @png_data
      refute_received {:submitted, _}
    end
  end

  test "router rejection cannot echo forwarded image data" do
    result =
      ChatSend.handle(params(%{"images" => [image()]}), %{router_mod: RejectingRouterStub})

    assert result == {:error, {:internal_error, "Chat submission failed", nil}}
    refute inspect(result) =~ @png_data
  end

  test "uncertain mutation acknowledgement retains the fixed run identity" do
    assert {:error, {:unavailable, "Chat submission outcome is unknown", details}} =
             ChatSend.handle(params(%{"images" => [image()]}), %{router_mod: UnknownRouterStub})

    assert_receive {:submitted, %{run_id: id}}
    assert details["code"] == "SUBMISSION_OUTCOME_UNKNOWN"
    assert details["runId"] == id
    assert details["retrySafe"] == false
    refute inspect(details) =~ @png_data
  end

  test "profileId inherits placement and persona for a noncanonical session", %{ctx: ctx} do
    assert {:ok, profile} =
             LemonCore.ProfileStore.create(%{
               id: "remote",
               node: "worker-one",
               model: "profile-model",
               systemPrompt: "Be a careful teammate.",
               mcpServers: [
                 %{
                   "name" => "bot",
                   "url" => "https://example.com/mcp",
                   "headers" => %{"Authorization" => "Bearer private-profile-token"}
                 }
               ]
             })

    File.write!(Path.join(profile["paths"]["workspace"], "SOUL.md"), "Prefer evidence.")
    session_key = "agent:remote:task-placement"

    assert {:ok, response} =
             ChatSend.handle(
               params(%{
                 "profileId" => "remote",
                 "sessionKey" => session_key,
                 "agentId" => "ignored",
                 "queueMode" => "followup",
                 "images" => [image()]
               }),
               ctx
             )

    assert_received {:submitted, request}
    assert request.agent_id == "remote"
    assert request.session_key == session_key
    assert request.model == "profile-model"
    assert request.meta.node == "worker-one"
    assert request.meta.system_prompt == "Be a careful teammate."
    assert request.meta.profile_instructions["SOUL.md"] == "Prefer evidence."
    assert request.meta.mcp_servers |> hd() |> Map.get("headers") ==
             %{"Authorization" => "Bearer private-profile-token"}
    assert request.meta.remote_cwd_explicit == false
    assert request.cwd == nil
    assert request.queue_mode == :followup
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    refute inspect(response) =~ "private-profile-token"
    refute inspect(response) =~ "Be a careful teammate."
  end

  test "profileId retains the profile workspace locally", %{ctx: ctx} do
    assert {:ok, profile} = LemonCore.ProfileStore.get("workspace")
    assert {:ok, _} = ChatSend.handle(params(%{"profileId" => "workspace"}), ctx)
    assert_received {:submitted, request}
    assert request.agent_id == "workspace"
    assert request.cwd == profile["paths"]["workspace"]
  end

  test "unknown or invalid profileId never submits", %{ctx: ctx} do
    assert {:error, {:not_found, "Unknown profile", _}} =
             ChatSend.handle(params(%{"profileId" => "missing"}), ctx)

    for id <- [nil, "", 123, %{}] do
      assert {:error, {:invalid_request, _, nil}} =
               ChatSend.handle(params(%{"profileId" => id}), ctx)
    end

    refute_received {:submitted, _}
  end

  test "profileId cannot override its workspace", %{root: root, ctx: ctx} do
    assert {:error, {:invalid_request, "cwd cannot override a profile workspace", nil}} =
             ChatSend.handle(params(%{"profileId" => "workspace", "cwd" => root}), ctx)

    refute_received {:submitted, _}
  end

  test "JSON image arrays pass the chat request validation boundary" do
    assert :ok = Schemas.validate("chat.send", params(%{"images" => [image()]}))
    assert :ok = Schemas.validate("chat.send", params(%{"images" => []}))
    assert :ok = Schemas.validate("chat.send", params(%{"prompt" => "", "images" => [image()]}))
    assert {:error, _} = Schemas.validate("chat.send", params(%{"images" => %{}}))
  end

  test "schema advertises optional string cwd" do
    assert Schemas.get("chat.send").optional["cwd"] == :string
    assert :ok = Schemas.validate("chat.send", params())
    assert :ok = Schemas.validate("chat.send", params(%{"cwd" => "/workspace"}))
    assert {:error, _} = Schemas.validate("chat.send", params(%{"cwd" => 123}))
  end

  defp image do
    %{"type" => "image", "mime_type" => "image/png", "data" => @png_data}
  end

  defp params(extra \\ %{}) do
    Map.merge(%{"sessionKey" => "agent:chat-workspace:main", "prompt" => "hello"}, extra)
  end
end
