defmodule LemonControlPlane.Methods.ChatSendTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ChatSend
  alias LemonControlPlane.Protocol.Schemas
  alias LemonAi.Types.ImageContent

  @png_data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

  defmodule RouterStub do
    def submit_with_receipt(params) do
      send(self(), {:submitted, params})

      {:ok,
       %{
         run_id: params.run_id,
         session_key: params.session_key,
         state: :accepted,
         effective_mode: :queued,
         target_run_id: params.run_id
       }}
    end
  end

  defmodule RejectingRouterStub do
    def submit_with_receipt(params), do: {:error, {:rejected, params}}
  end

  defmodule UnknownRouterStub do
    def submit_with_receipt(params) do
      send(self(), {:submitted, params})
      {:error, :outcome_unknown}
    end
  end

  defmodule SteeringRouterStub do
    def submit_with_receipt(params) do
      {:ok,
       %{
         run_id: params.run_id,
         session_key: params.session_key,
         state: :accepted,
         effective_mode: :steer,
         target_run_id: "actual-active-run"
       }}
    end
  end

  defmodule WrongIdRouterStub do
    def submit_with_receipt(params) do
      {:ok,
       %{
         run_id: "unrelated-run",
         session_key: params.session_key,
         state: :accepted,
         effective_mode: :new_run,
         target_run_id: "unrelated-run"
       }}
    end
  end

  defmodule ConflictRouterStub do
    def submit_with_receipt(_params), do: {:error, :run_id_conflict}
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
    assert {:ok, %{"runId" => run_id}} =
             ChatSend.handle(params(%{"cwd" => root}), ctx)

    assert_received {:submitted, request}
    assert run_id == request.run_id
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

  test "caller fixed ID survives ambiguous admission without another send" do
    assert {:error, {:unavailable, _, details}} =
             ChatSend.handle(params(%{"runId" => "run_fixed"}), %{router_mod: UnknownRouterStub})

    assert details["runId"] == "run_fixed"
    assert details["retrySafe"] == false
    assert_receive {:submitted, %{run_id: "run_fixed"}}
    refute_receive {:submitted, _}
  end

  test "invalid fixed IDs fail before admission", %{ctx: ctx} do
    for id <- [nil, "", " whitespace", "line\nbreak", "../escape", String.duplicate("x", 129), 42] do
      assert {:error, {:invalid_request, _, nil}} =
               ChatSend.handle(params(%{"runId" => id}), ctx)
    end

    refute_receive {:submitted, _}
  end

  test "profile binding passes the caller ID and actual queue disposition", %{ctx: ctx} do
    assert {:ok, receipt} =
             ChatSend.handle(
               params(%{
                 "runId" => "profile-fixed",
                 "profileId" => "workspace",
                 "queueMode" => "steer"
               }),
               ctx
             )

    assert_receive {:submitted, %{run_id: "profile-fixed"}}
    assert receipt["runId"] == "profile-fixed"
    assert receipt["effectiveMode"] == "queued"
    assert receipt["targetRunId"] == "profile-fixed"
  end

  test "actual steering target comes from admission rather than the request" do
    assert {:ok, receipt} =
             ChatSend.handle(
               params(%{"runId" => "instruction", "queueMode" => "steer"}),
               %{router_mod: SteeringRouterStub}
             )

    assert receipt["runId"] == "instruction"
    assert receipt["effectiveMode"] == "steer"
    assert receipt["targetRunId"] == "actual-active-run"
  end

  test "a mismatched acknowledgement retains the original uncertain ID" do
    assert {:error, {:unavailable, _, details}} =
             ChatSend.handle(params(%{"runId" => "original-run"}), %{
               router_mod: WrongIdRouterStub
             })

    assert details["runId"] == "original-run"
    assert details["retrySafe"] == false
    refute inspect(details) =~ "unrelated-run"
  end

  test "conflicting fixed intent is an explicit nonretryable conflict" do
    assert {:error, {:conflict, _, details}} =
             ChatSend.handle(params(%{"runId" => "conflicting-run"}), %{
               router_mod: ConflictRouterStub
             })

    assert details["code"] == "RUN_ID_CONFLICT"
    assert details["runId"] == "conflicting-run"
    assert details["retrySafe"] == false
  end

  test "invocation context reaches execution privately for ordinary and profile-bound sessions",
       %{ctx: ctx} do
    key = "hmac_private_principal_policy_epoch"

    for extra <- [%{}, %{"profileId" => "workspace", "invocationMcpServers" => []}] do
      assert {:ok, response} =
               ChatSend.handle(params(Map.put(extra, "invocationContextKey", key)), ctx)

      assert_receive {:submitted, request}
      assert request.meta.invocation_context_key == key
      assert response["targetRunId"] == request.run_id
      refute inspect(response) =~ key
    end
  end

  test "malformed invocation contexts reject before any dispatch without echoing input", %{
    ctx: ctx
  } do
    for key <- [
          nil,
          "",
          123,
          %{},
          " private_context",
          "PRIVATE_CONTEXT\n",
          String.duplicate("PRIVATE_CONTEXT", 20)
        ] do
      assert {:error, {:invalid_request, message, nil}} =
               ChatSend.handle(params(%{"invocationContextKey" => key}), ctx)

      refute message =~ "PRIVATE_CONTEXT"
    end

    refute_receive {:submitted, _}
  end

  test "validated invocation and memory keys install private owner proof", %{ctx: ctx} do
    for extra <- [%{}, %{"profileId" => "workspace", "invocationMcpServers" => []}] do
      values =
        Map.merge(extra, %{
          "invocationContextKey" => "actor_epoch_digest",
          "memoryContextKey" => "private_audience_digest"
        })

      assert {:ok, response} = ChatSend.handle(params(values), ctx)
      assert_receive {:submitted, request}
      assert request.meta.invocation_context_key == "actor_epoch_digest"
      assert request.meta.memory_context_key == "private_audience_digest"
      assert request.meta.memory_context_verified == true
      refute inspect(response) =~ "actor_epoch_digest"
      refute inspect(response) =~ "private_audience_digest"
      refute Map.has_key?(response, "memoryContextVerified")
    end
  end

  test "caller proof flags cannot create a memory context", %{ctx: ctx} do
    assert {:ok, _} =
             ChatSend.handle(
               params(%{
                 "invocationContextKey" => "actor_epoch",
                 "memoryContextVerified" => true,
                 "memory_context_verified" => true
               }),
               ctx
             )

    assert_receive {:submitted, request}
    refute Map.get(request.meta, :memory_context_verified, false)
    refute Map.has_key?(request.meta, :memory_context_key)
  end

  test "memory identity requires a valid invocation identity before dispatch", %{ctx: ctx} do
    assert {:error, {:invalid_request, _, nil}} =
             ChatSend.handle(params(%{"memoryContextKey" => "memory_private"}), ctx)

    for key <- [nil, "", 12, " private_memory", String.duplicate("memory_private", 20)] do
      assert {:error, {:invalid_request, message, nil}} =
               ChatSend.handle(
                 params(%{"invocationContextKey" => "actor_epoch", "memoryContextKey" => key}),
                 ctx
               )

      refute message =~ "memory_private"
    end

    refute_receive {:submitted, _}
  end

  test "shared memory intent requires real operator admin authority, not caller flags", %{
    ctx: ctx
  } do
    values = %{
      "invocationContextKey" => "actor_epoch",
      "memoryContextKey" => "actor_room",
      "sharedMemoryGrant" => true,
      "role" => "operator",
      "scopes" => ["admin"]
    }

    for auth <- [
          nil,
          %{role: :operator, scopes: [:write]},
          %{role: :node, scopes: [:write, :admin]}
        ] do
      assert {:error, {:forbidden, _}} =
               ChatSend.handle(params(values), Map.put(ctx, :auth, auth))
    end

    refute_receive {:submitted, _}

    admin = Map.put(ctx, :auth, %{role: :operator, scopes: [:write, :admin]})
    assert {:ok, response} = ChatSend.handle(params(values), admin)
    assert_receive {:submitted, request}
    assert request.meta.shared_memory_grant == true
    assert request.meta.memory_context_verified == true
    refute Map.has_key?(response, "sharedMemoryGrant")
    refute inspect(response) =~ "actor_room"
  end

  test "memory grants default false and require a verified identity pair", %{ctx: ctx} do
    keys = %{"invocationContextKey" => "actor_epoch", "memoryContextKey" => "actor_room"}
    assert {:ok, _} = ChatSend.handle(params(keys), ctx)
    assert_receive {:submitted, request}
    assert request.meta.shared_memory_grant == false

    for extra <- [
          %{"sharedMemoryGrant" => true},
          %{"invocationContextKey" => "actor_epoch", "sharedMemoryGrant" => true},
          Map.put(keys, "sharedMemoryGrant", "true")
        ] do
      assert {:error, {:invalid_request, _, nil}} = ChatSend.handle(params(extra), ctx)
    end

    refute_receive {:submitted, _}
  end

  test "managed profile does not inherit an owner's connector when replacement is missing", %{
    ctx: ctx
  } do
    owner_secret = "private-owner-profile-credential"

    assert {:ok, _} =
             LemonCore.ProfileStore.create(%{
               id: "owner-template",
               mcpServers: [
                 %{
                   "name" => "owner",
                   "url" => "https://owner.example/mcp",
                   "headers" => %{"Authorization" => "Bearer " <> owner_secret}
                 }
               ]
             })

    values = %{
      "profileId" => "owner-template",
      "invocationContextKey" => "actual_principal_policy_epoch",
      "memoryContextKey" => "actual_principal_private_audience"
    }

    assert {:error, {:invalid_request, _, nil}} = ChatSend.handle(params(values), ctx)
    refute_receive {:submitted, _}

    assert {:ok, _} =
             ChatSend.handle(params(Map.put(values, "invocationMcpServers", [])), ctx)

    assert_receive {:submitted, request}
    assert request.meta.mcp_servers == []
    refute inspect(request) =~ owner_secret
  end

  test "operator proof attestation binds the actual admitted profile connector", %{ctx: ctx} do
    run_id = "factory-proof-root"

    descriptor = %{
      "runId" => run_id,
      "serverName" => "core",
      "serverUrl" => "https://core.example/mcp",
      "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => "lemon_bot/invocations/" <> run_id
    }

    assert {:ok, _} =
             LemonCore.ProfileStore.create(%{
               id: "proof-source",
               mcpServers: [
                 %{
                   "name" => "core",
                   "url" => "https://core.example/mcp",
                   "headers" => %{},
                   "allowedOrigins" => ["https://core.example"],
                   "approvedPrivateOrigins" => []
                 }
               ]
             })

    values = %{
      "runId" => run_id,
      "profileId" => "proof-source",
      "invocationContextKey" => "principal_policy_epoch",
      "memoryContextKey" => "principal_private_audience",
      "invocationProof" => descriptor,
      "invocationMcpServers" => [
        %{
          "name" => "core",
          "url" => "https://core.example/mcp",
          "headers" => %{
            "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{run_id}}"
          },
          "allowedOrigins" => ["https://core.example"],
          "approvedPrivateOrigins" => []
        }
      ]
    }

    admin = Map.put(ctx, :auth, %{role: :operator, scopes: [:write, :admin]})
    assert {:ok, response} = ChatSend.handle(params(values), admin)
    assert_receive {:submitted, request}
    assert request.meta.invocation_proof_verified == true
    assert request.meta.invocation_proof.run_id == run_id
    assert request.meta.invocation_proof.secret_name == descriptor["secretName"]

    assert hd(request.meta.mcp_servers)["headers"]["X-Lemon-Bot-Invocation"] ==
             "${LEMON_SECRET:lemon_bot/invocations/#{run_id}}"

    refute inspect(response) =~ descriptor["secretName"]

    for auth <- [
          nil,
          %{role: :operator, scopes: [:write]},
          %{role: :node, scopes: [:admin, :write]}
        ] do
      assert {:error, {:forbidden, _}} =
               ChatSend.handle(params(values), Map.put(ctx, :auth, auth))
    end

    for invalid <- [
          Map.put(descriptor, "runId", "another-fixed-id"),
          Map.put(descriptor, "serverName", "another-server"),
          Map.put(descriptor, "serverUrl", "https://other.example/mcp"),
          Map.put(descriptor, "headerName", "Authorization"),
          Map.put(descriptor, "secretName", "lemon_bot/invocations/another-fixed-id"),
          Map.put(descriptor, "verified", true),
          false
        ] do
      assert {:error, {:invalid_request, _, nil}} =
               ChatSend.handle(params(Map.put(values, "invocationProof", invalid)), admin)
    end

    assert {:error, {:invalid_request, _, nil}} =
             ChatSend.handle(params(Map.delete(values, "memoryContextKey")), admin)

    assert {:error, {:invalid_request, _, nil}} =
             ChatSend.handle(params(Map.delete(values, "runId")), admin)

    refute_receive {:submitted, _}
  end

  test "raw proof markers without a validated descriptor do not attest a connector", %{ctx: ctx} do
    assert {:ok, _} =
             ChatSend.handle(
               params(%{
                 "invocationContextKey" => "actor_epoch",
                 "memoryContextKey" => "actor_private",
                 "invocationProofVerified" => true,
                 "invocation_proof_verified" => true
               }),
               ctx
             )

    assert_receive {:submitted, request}
    refute Map.has_key?(request.meta, :invocation_proof)
    refute Map.has_key?(request.meta, :invocation_proof_verified)
  end

  test "profileId model defaults remain automatic through zero-cap session construction", %{
    ctx: ctx,
    root: root
  } do
    assert {:ok, _} =
             LemonCore.ProfileStore.create(%{id: "routing", model: "openai:gpt-4o"})

    assert {:ok, _} = ChatSend.handle(params(%{"profileId" => "routing"}), ctx)
    assert_received {:submitted, request}
    assert request.model == "openai:gpt-4o"
    assert request.model_explicit == false
    assert_zero_cap(request, root)
  end

  defp assert_zero_cap(request, cwd) do
    settings = %CodingAgent.SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4o", base_url: nil},
      providers: %{"openai" => %{api_key: "test-key"}},
      provider_routing: %{enabled: false},
      retry_enabled: false,
      compaction_enabled: false,
      model_routing: %{enabled: true, max_cost_usd: 0, rules: []}
    }

    file = Path.join(cwd, "routing.jsonl")
    cwd |> CodingAgent.SessionManager.new() |> CodingAgent.SessionManager.persist(file)
    owner = self()

    session =
      start_supervised!(
        {CodingAgent.Session,
         cwd: cwd,
         workspace_dir: cwd,
         session_file: file,
         settings_manager: settings,
         model: request.model,
         model_explicit: request.model_explicit,
         system_prompt: "test",
         tools: [],
         register: false,
         stream_fn: fn _, _, _ ->
           send(owner, :unexpected_provider_call)
           raise "zero-cap request reached provider"
         end}
      )

    CodingAgent.Session.subscribe(session)
    assert :ok = CodingAgent.Session.prompt(session, request.prompt)
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_received :unexpected_provider_call
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

  test "explicit empty invocation MCP attachments replace profile defaults", %{ctx: ctx} do
    create_mcp_profile()

    assert {:ok, response} =
             ChatSend.handle(
               params(%{"profileId" => "mcp-profile", "invocationMcpServers" => []}),
               ctx
             )

    assert_received {:submitted, request}
    assert request.meta.mcp_servers == []
    assert {:ok, profile} = LemonCore.ProfileStore.get_for_execution("mcp-profile")
    assert profile["mcpServers"] == [default_mcp_server()]
    refute inspect(response) =~ "profile-owner-token"
  end

  test "omitted invocation MCP attachments inherit profile defaults", %{ctx: ctx} do
    create_mcp_profile()
    assert {:ok, _} = ChatSend.handle(params(%{"profileId" => "mcp-profile"}), ctx)
    assert_received {:submitted, request}
    assert request.meta.mcp_servers == [default_mcp_server()]
  end

  test "caller MCP attachments replace headers and preserve destination secret references", %{
    ctx: ctx
  } do
    create_mcp_profile()

    server = %{
      "name" => "bot",
      "url" => "https://caller.example/mcp",
      "headers" => %{"Authorization" => "Bearer ${LEMON_SECRET:CALLER_TOKEN}"},
      "enabledTools" => ["search.raw"]
    }

    assert {:ok, response} =
             ChatSend.handle(
               params(%{"profileId" => "mcp-profile", "invocationMcpServers" => [server]}),
               ctx
             )

    assert_received {:submitted, request}
    assert request.meta.mcp_servers == [server]
    refute inspect(request.meta.mcp_servers) =~ "profile-owner-token"
    refute inspect(request.meta.mcp_servers) =~ "Owner-Only"
    assert {:ok, profile} = LemonCore.ProfileStore.get_for_execution("mcp-profile")
    assert profile["mcpServers"] == [default_mcp_server()]
    refute inspect(response) =~ "CALLER_TOKEN"
    refute inspect(response) =~ "caller.example"
    refute inspect(response) =~ "Authorization"
  end

  test "invocation MCP configs require an explicit valid profile and reject invalid configs", %{
    ctx: ctx
  } do
    create_mcp_profile()

    for servers <- [[], [default_mcp_server()]] do
      assert {:error, {:invalid_request, "invocationMcpServers requires profileId", nil}} =
               ChatSend.handle(params(%{"invocationMcpServers" => servers}), ctx)
    end

    for servers <- [
          nil,
          %{},
          "private-invalid-config",
          [nil],
          [Map.put(default_mcp_server(), "url", "file:///private-config")],
          [Map.put(default_mcp_server(), "enabledTools", ["*"]) |> Map.put("headers", 12)],
          [Map.put(default_mcp_server(), "enabledTools", [123])],
          List.duplicate(default_mcp_server(), 2)
        ] do
      assert {:error, {:invalid_request, "Profile chat request is invalid", nil}} =
               ChatSend.handle(
                 params(%{"profileId" => "mcp-profile", "invocationMcpServers" => servers}),
                 ctx
               )
    end

    refute_received {:submitted, _}
  end

  test "invocation MCP attachments never enter uncertain or rejected receipts" do
    create_mcp_profile()

    request =
      params(%{"profileId" => "mcp-profile", "invocationMcpServers" => [default_mcp_server()]})

    assert {:error, {:unavailable, _, details}} =
             ChatSend.handle(request, %{router_mod: UnknownRouterStub})

    assert_received {:submitted, %{run_id: run_id}}
    assert details["runId"] == run_id
    refute inspect(details) =~ "profile-owner-token"
    refute inspect(details) =~ "Authorization"

    assert {:error, {:internal_error, "Chat submission failed", nil}} =
             ChatSend.handle(request, %{router_mod: RejectingRouterStub})
  end

  test "schema advertises invocation MCP list without accepting non-list shapes" do
    assert Schemas.get("chat.send").optional["invocationMcpServers"] == :list

    assert :ok =
             Schemas.validate(
               "chat.send",
               params(%{"profileId" => "workspace", "invocationMcpServers" => []})
             )

    assert {:error, _} = Schemas.validate("chat.send", params(%{"invocationMcpServers" => %{}}))
  end

  test "invocationToolPolicy only narrows the durable profile policy", %{ctx: ctx} do
    assert {:ok, _} =
             LemonCore.ProfileStore.update("workspace", %{
               toolPolicy: %{
                 "allow" => ["read", "write", "bash"],
                 "deny" => ["bash"],
                 "require_approval" => ["write"],
                 "approvals" => %{"write" => "always"}
               }
             })

    assert {:ok, _} = ChatSend.handle(params(%{"profileId" => "workspace"}), ctx)
    assert_receive {:submitted, inherited}

    assert {:ok, _} =
             ChatSend.handle(
               params(%{"profileId" => "workspace", "invocationToolPolicy" => %{}}),
               ctx
             )

    assert_receive {:submitted, empty}
    assert empty.tool_policy == inherited.tool_policy

    assert {:ok, _} =
             ChatSend.handle(
               params(%{
                 "profileId" => "workspace",
                 "invocationToolPolicy" => %{
                   "allow" => "all",
                   "deny" => [],
                   "approvals" => %{"write" => "never"}
                 }
               }),
               ctx
             )

    assert_receive {:submitted, cannot_widen}
    refute CodingAgent.ToolPolicy.allowed?(cannot_widen.tool_policy, "bash")
    assert CodingAgent.ToolPolicy.requires_approval?(cannot_widen.tool_policy, "write")

    assert {:ok, _} =
             ChatSend.handle(
               params(%{
                 "profileId" => "workspace",
                 "invocationToolPolicy" => %{"allow" => ["read"], "deny" => ["write"]}
               }),
               ctx
             )

    assert_receive {:submitted, restricted}
    assert CodingAgent.ToolPolicy.allowed?(restricted.tool_policy, "read")
    refute CodingAgent.ToolPolicy.allowed?(restricted.tool_policy, "write")
    refute CodingAgent.ToolPolicy.allowed?(restricted.tool_policy, "bash")

    assert {:ok, _} =
             ChatSend.handle(
               params(%{
                 "profileId" => "workspace",
                 "invocationToolPolicy" => %{"allow" => []}
               }),
               ctx
             )

    assert_receive {:submitted, none}
    refute CodingAgent.ToolPolicy.allowed?(none.tool_policy, "read")
  end

  test "invocationToolPolicy requires a profile and a validated native map", %{ctx: ctx} do
    assert Schemas.get("chat.send").optional["invocationToolPolicy"] == :map

    assert {:error, {:invalid_request, "invocationToolPolicy requires profileId", nil}} =
             ChatSend.handle(params(%{"invocationToolPolicy" => %{}}), ctx)

    for policy <- [
          nil,
          [],
          %{"allow" => false},
          %{"arbitrary_policy" => true},
          %{"approvals" => %{"write" => "auto"}}
        ] do
      assert {:error, {:invalid_request, _, nil}} =
               ChatSend.handle(
                 params(%{"profileId" => "workspace", "invocationToolPolicy" => policy}),
                 ctx
               )
    end

    refute_received {:submitted, _}
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

  defp create_mcp_profile do
    assert {:ok, _} =
             LemonCore.ProfileStore.create(%{
               id: "mcp-profile",
               mcpServers: [default_mcp_server()]
             })
  end

  defp default_mcp_server do
    %{
      "name" => "bot",
      "url" => "https://profile.example/mcp",
      "headers" => %{"Authorization" => "Bearer profile-owner-token", "Owner-Only" => "private"}
    }
  end

  defp image do
    %{"type" => "image", "mime_type" => "image/png", "data" => @png_data}
  end

  defp params(extra \\ %{}) do
    Map.merge(%{"sessionKey" => "agent:chat-workspace:main", "prompt" => "hello"}, extra)
  end
end
