defmodule LemonControlPlane.Methods.IntrospectionMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    ChatHistory,
    IntrospectionSnapshot,
    RunGraphGet,
    RunIntrospectionList,
    SessionDetail,
    SessionsActive,
    SessionsList,
    SessionsPreview,
    SessionsActiveList,
    TransportsStatus
  }

  alias LemonCore.SessionKey

  defmodule RouterBridgeStub do
    @active_sessions_key {__MODULE__, :active_sessions}

    def set_active_sessions(entries) when is_list(entries) do
      :persistent_term.put(@active_sessions_key, entries)
    end

    def clear_active_sessions do
      :persistent_term.erase(@active_sessions_key)
    end

    def active_run(session_key) do
      case Enum.find(active_sessions(), &(&1.session_key == session_key)) do
        %{run_id: run_id} -> {:ok, run_id}
        _ -> :none
      end
    end

    def list_active_sessions do
      active_sessions()
    end

    defp active_sessions do
      :persistent_term.get(@active_sessions_key, [])
    end
  end

  defmodule SessionCoordinatorStub do
    @active_sessions_key {__MODULE__, :active_sessions}

    def set_active_sessions(entries) when is_list(entries) do
      :persistent_term.put(@active_sessions_key, entries)
    end

    def clear_active_sessions do
      :persistent_term.erase(@active_sessions_key)
    end

    def active_run_for_session(session_key) do
      case Enum.find(active_sessions(), &(&1.session_key == session_key)) do
        %{run_id: run_id} -> {:ok, run_id}
        _ -> :none
      end
    end

    def busy?(session_key), do: active_run_for_session(session_key) != :none

    def list_active_sessions do
      active_sessions()
    end

    defp active_sessions do
      :persistent_term.get(@active_sessions_key, [])
    end
  end

  defmodule TransportRegistryStub do
    use GenServer

    def start_link(state) do
      GenServer.start(__MODULE__, state, name: __MODULE__)
    end

    def list_transports, do: GenServer.call(__MODULE__, :list_transports)
    def enabled_transports, do: GenServer.call(__MODULE__, :enabled_transports)
    def get_transport(id), do: GenServer.call(__MODULE__, {:get_transport, id})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:list_transports, _from, state) do
      {:reply, Map.keys(state.transports), state}
    end

    def handle_call(:enabled_transports, _from, state) do
      enabled =
        state.transports
        |> Enum.filter(fn {id, _mod} -> id in state.enabled end)
        |> Enum.into([])

      {:reply, enabled, state}
    end

    def handle_call({:get_transport, id}, _from, state) do
      {:reply, Map.get(state.transports, id), state}
    end
  end

  defmodule TransportRegistryMissingApiStub do
    use GenServer

    def start_link(state) do
      GenServer.start(__MODULE__, state, name: __MODULE__)
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule TransportRegistryCrashingStub do
    use GenServer

    def start_link(state) do
      GenServer.start(__MODULE__, state, name: __MODULE__)
    end

    def list_transports, do: GenServer.call(__MODULE__, :list_transports)
    def enabled_transports, do: GenServer.call(__MODULE__, :enabled_transports)
    def get_transport(_id), do: raise("registry API failure")

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:list_transports, _from, state), do: {:reply, ["email"], state}
    def handle_call(:enabled_transports, _from, state), do: {:reply, [], state}
  end

  setup do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_introspection_#{token}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: agent_id,
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(1_000_000 + token)
      })

    run_id = "run_cp_introspection_#{token}"
    requirements_cwd = Path.join(System.tmp_dir!(), "cp_introspection_requirements_#{token}")
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_session_coordinator = Application.get_env(:lemon_router, :session_coordinator)

    File.mkdir_p!(requirements_cwd)

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    :ok =
      CodingAgent.Tools.FeatureRequirements.save_requirements(
        %{
          project_name: "Control Plane Harness Projection",
          original_prompt: "Track long-running task progress",
          created_at: now,
          version: "1.0",
          features: [
            %{
              id: "feature-001",
              description: "Expose harness data",
              status: :completed,
              dependencies: [],
              priority: :high,
              acceptance_criteria: ["harness appears in sessions.active.list"],
              notes: "",
              created_at: now,
              updated_at: now
            },
            %{
              id: "feature-002",
              description: "Validate requirements progress",
              status: :pending,
              dependencies: ["feature-001"],
              priority: :medium,
              acceptance_criteria: ["requirements section is included"],
              notes: "",
              created_at: now,
              updated_at: nil
            }
          ]
        },
        requirements_cwd
      )

    LemonCore.RouterBridge.configure(router: RouterBridgeStub)
    RouterBridgeStub.set_active_sessions([%{session_key: session_key, run_id: run_id}])
    Application.put_env(:lemon_router, :session_coordinator, SessionCoordinatorStub)
    SessionCoordinatorStub.set_active_sessions([%{session_key: session_key, run_id: run_id}])

    LemonCore.Store.put(:runs, run_id, %{started_at: System.system_time(:millisecond)})

    :ok =
      LemonCore.Introspection.record(
        :session_started,
        %{cwd: requirements_cwd},
        run_id: run_id,
        session_key: session_key,
        agent_id: agent_id
      )

    CodingAgent.Tools.TodoStore.put(session_key, [
      %{
        "id" => "todo-introspection-1",
        "content" => "verify harness projection",
        "status" => "pending"
      }
    ])

    {:ok, checkpoint} =
      CodingAgent.Checkpoint.create(session_key,
        todos: [%{"id" => "todo-introspection-1", "content" => "verify harness projection"}],
        metadata: %{source: "introspection-methods-test"}
      )

    on_exit(fn ->
      RouterBridgeStub.clear_active_sessions()
      SessionCoordinatorStub.clear_active_sessions()
      restore_router_bridge(old_router_bridge)
      restore_session_coordinator(old_session_coordinator)
      LemonCore.Store.delete(:runs, run_id)
      CodingAgent.Tools.TodoStore.delete(session_key)
      CodingAgent.Checkpoint.delete(checkpoint.id)
      File.rm_rf(requirements_cwd)
    end)

    {:ok,
     %{
       agent_id: agent_id,
       session_key: session_key,
       run_id: run_id,
       requirements_cwd: requirements_cwd
     }}
  end

  describe "sessions.active.list" do
    test "returns one active run with cleanup summary", %{
      session_key: session_key,
      run_id: run_id
    } do
      assert SessionsActive.name() == "sessions.active"
      assert SessionsActive.scopes() == [:read]

      {:ok, result} = SessionsActive.handle(%{"sessionKey" => session_key}, %{})

      assert result["sessionKey"] == session_key
      assert result["runId"] == run_id
      assert result["summary"]["action"] == "sessions.active"
      assert result["summary"]["active"] == true
      assert result["summary"]["sessionKeyReturned"] == true
      assert result["summary"]["runIdReturned"] == true
      assert result["summary"]["cleanup"]["includesRunRecord"] == false
      assert result["summary"]["cleanup"]["includesRunEvents"] == false
      assert result["summary"]["cleanup"]["includesMessageText"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns inactive summary when no run is active" do
      {:ok, result} = SessionsActive.handle(%{"sessionKey" => "agent:none:main"}, %{})

      assert result["runId"] == nil
      assert result["summary"]["active"] == false
      assert result["summary"]["sessionKeyReturned"] == true
      assert result["summary"]["runIdReturned"] == false
    end

    test "lists active sessions with filters", %{
      agent_id: agent_id,
      session_key: session_key,
      requirements_cwd: requirements_cwd
    } do
      assert SessionsActiveList.name() == "sessions.active.list"
      assert SessionsActiveList.scopes() == [:read]

      {:ok, result} =
        SessionsActiveList.handle(
          %{
            "agentId" => agent_id,
            "limit" => 20,
            "route" => %{"channelId" => "telegram"}
          },
          %{}
        )

      assert is_list(result["sessions"])
      assert is_integer(result["total"])
      assert result["total"] == length(result["sessions"])
      assert result["filters"]["agentId"] == agent_id
      assert result["filters"]["route"]["channelId"] == "telegram"
      assert result["summary"]["count"] == result["total"]
      assert result["summary"]["activeCount"] == result["total"]
      assert result["summary"]["agentCount"] >= 1
      assert result["summary"]["channelCounts"]["telegram"] >= 1
      assert result["summary"]["harnessCount"] >= 1
      assert result["summary"]["filtersApplied"] == ["agentId", "route"]
      assert result["summary"]["cleanup"]["includesHarnessSnapshots"] == true
      assert result["summary"]["cleanup"]["includesRunEvents"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      assert Enum.any?(result["sessions"], &(&1["sessionKey"] == session_key))

      assert session = Enum.find(result["sessions"], &(&1["sessionKey"] == session_key))
      assert is_map(session["harness"])
      assert session["harness"]["todos"]["total"] == 1
      assert session["harness"]["checkpoints"]["count"] >= 1

      assert session["harness"]["requirements"]["project_name"] ==
               "Control Plane Harness Projection"

      assert session["harness"]["requirements"]["percentage"] == 50
      assert session["harness"]["requirements"]["cwd"] == requirements_cwd
    end
  end

  describe "sessions.list and session.detail" do
    test "return summaries and keep full prompt/answer text behind includeFullText" do
      token = System.unique_integer([:positive, :monotonic])
      agent_id = "cp_session_detail_#{token}"
      session_key = "agent:#{agent_id}:telegram:default:dm:#{token}"
      run_id = "run_cp_session_detail_#{token}"
      prompt_secret = "PROMPT_SECRET_#{token}"
      answer_secret = "ANSWER_SECRET_#{token}"
      tool_secret = "TOOL_TOKEN_#{token}"
      prompt_inline_secret = "PROMPT_INLINE_TOKEN_#{token}"
      answer_inline_secret = "ANSWER_INLINE_BEARER_#{token}"
      prompt = "token=#{prompt_inline_secret} " <> String.duplicate("p", 2_100) <> prompt_secret
      answer = "Bearer #{answer_inline_secret} " <> String.duplicate("a", 4_100) <> answer_secret

      on_exit(fn ->
        LemonCore.Store.delete(:runs, run_id)
        LemonCore.RunStore.delete_session(session_key)
      end)

      assert :ok =
               LemonCore.RunStore.append_event(run_id, %{
                 __event__: :action_event,
                 action: %{title: "read", kind: :tool, detail: "token=#{tool_secret}"},
                 api_key: tool_secret,
                 ok: true
               })

      assert :ok =
               LemonCore.RunStore.finalize(run_id, %{
                 session_key: session_key,
                 agent_id: agent_id,
                 origin: :telegram,
                 prompt: prompt,
                 engine: "codex",
                 duration_ms: 123,
                 completed: %{
                   ok: true,
                   answer: answer,
                   usage: %{input: 1, output: 2, total_tokens: 3}
                 }
               })

      LemonCore.Store.put(:sessions_index, session_key, %{
        session_key: session_key,
        agent_id: agent_id,
        origin: :telegram,
        created_at_ms: System.system_time(:millisecond),
        updated_at_ms: System.system_time(:millisecond),
        run_count: 1
      })

      assert eventually(fn -> LemonCore.RunStore.history(session_key, limit: 5) != [] end)

      assert eventually(fn ->
               {:ok, listed} = SessionsList.handle(%{"agentId" => agent_id, "limit" => 10}, %{})
               listed["summary"]["count"] >= 1
             end)

      {:ok, listed} = SessionsList.handle(%{"agentId" => agent_id, "limit" => 10}, %{})

      assert listed["summary"]["count"] >= 1
      assert listed["summary"]["agentCount"] >= 1
      assert listed["summary"]["originCounts"]["telegram"] >= 1
      assert listed["summary"]["filtersApplied"] == ["agentId"]
      assert listed["summary"]["cleanup"]["includesMessages"] == false
      assert listed["summary"]["cleanup"]["includesSecretValues"] == false

      {:ok, detail} = SessionDetail.handle(%{"sessionKey" => session_key}, %{})

      assert detail["summary"]["count"] == 1
      assert detail["summary"]["okCount"] == 1
      assert detail["summary"]["toolCallCount"] == 1
      assert detail["summary"]["tokenTotals"]["total"] == 3
      assert detail["summary"]["cleanup"]["includesFullText"] == false
      assert detail["summary"]["cleanup"]["includesRawEvents"] == false
      assert detail["summary"]["cleanup"]["includesRunRecords"] == false
      assert detail["summary"]["cleanup"]["redactsSensitiveRunInternals"] == true

      [run] = detail["runs"]
      refute Map.has_key?(run, "promptFull")
      refute Map.has_key?(run, "answerFull")
      refute inspect(detail) =~ prompt_secret
      refute inspect(detail) =~ answer_secret
      refute inspect(detail) =~ tool_secret
      refute inspect(detail) =~ prompt_inline_secret
      refute inspect(detail) =~ answer_inline_secret
      assert inspect(run["toolCalls"]) =~ "[REDACTED]"

      {:ok, full_detail} =
        SessionDetail.handle(%{"sessionKey" => session_key, "includeFullText" => true}, %{})

      assert full_detail["summary"]["cleanup"]["includesFullText"] == true
      [full_run] = full_detail["runs"]
      assert full_run["promptFull"] =~ prompt_secret
      assert full_run["answerFull"] =~ answer_secret
      assert full_run["promptFull"] =~ prompt_inline_secret
      assert full_run["answerFull"] =~ answer_inline_secret
      refute inspect(full_run["toolCalls"]) =~ tool_secret

      {:ok, raw_detail} =
        SessionDetail.handle(
          %{
            "sessionKey" => session_key,
            "includeRawEvents" => true,
            "includeRunRecord" => true
          },
          %{}
        )

      refute inspect(raw_detail) =~ tool_secret
      assert inspect(raw_detail) =~ "[REDACTED]"

      {:ok, preview} = SessionsPreview.handle(%{"sessionKey" => session_key, "limit" => "5"}, %{})

      assert preview["summary"]["count"] == 1
      assert preview["summary"]["truncatedCount"] == 1
      assert preview["summary"]["cleanup"]["includesFullText"] == false
      assert preview["summary"]["cleanup"]["redactsSensitivePreviews"] == true
      refute inspect(preview) =~ prompt_secret
      refute inspect(preview) =~ answer_secret
      refute inspect(preview) =~ prompt_inline_secret
      refute inspect(preview) =~ answer_inline_secret

      {:ok, chat} =
        ChatHistory.handle(
          %{"sessionKey" => session_key, "includeFullText" => false, "limit" => 10},
          %{}
        )

      assert chat["summary"]["count"] == 2
      assert chat["summary"]["roleCounts"]["user"] == 1
      assert chat["summary"]["roleCounts"]["assistant"] == 1
      assert chat["summary"]["truncatedCount"] == 2
      assert chat["summary"]["cleanup"]["includesMessageBodies"] == true
      assert chat["summary"]["cleanup"]["includesFullText"] == false
      assert chat["summary"]["cleanup"]["redactsSensitivePreviews"] == true
      refute inspect(chat) =~ prompt_secret
      refute inspect(chat) =~ answer_secret
      refute inspect(chat) =~ prompt_inline_secret
      refute inspect(chat) =~ answer_inline_secret

      {:ok, after_user} =
        ChatHistory.handle(
          %{
            "sessionKey" => session_key,
            "beforeId" => "#{run_id}_user",
            "includeFullText" => false
          },
          %{}
        )

      assert [%{"id" => assistant_message_id}] = after_user["messages"]
      assert assistant_message_id == "#{run_id}_assistant"
      assert after_user["summary"]["beforeId"] == "#{run_id}_user"
    end
  end

  describe "run introspection and graph internals" do
    test "redacts sensitive payload values from run.introspection.list", %{
      agent_id: agent_id,
      session_key: session_key,
      run_id: run_id
    } do
      token = System.unique_integer([:positive, :monotonic])
      payload_secret = "introspection-api-key-#{token}"
      bearer_secret = "introspection-bearer-#{token}"
      run_event_secret = "run-event-api-key-#{token}"
      error_secret = "run-error-token-#{token}"

      on_exit(fn ->
        LemonCore.RunStore.delete_session(session_key)
      end)

      LemonCore.Store.delete(:runs, run_id)

      :ok =
        LemonCore.Introspection.record(
          :tool_finished,
          %{
            api_key: payload_secret,
            message: "Authorization: Bearer #{bearer_secret}",
            nested: %{password: "nested-password-#{token}"},
            visible: "kept"
          },
          run_id: run_id,
          session_key: session_key,
          agent_id: agent_id
        )

      assert :ok =
               LemonCore.RunStore.append_event(run_id, %{
                 __event__: :action_event,
                 action: %{title: "fetch", detail: "api_key=#{run_event_secret}"},
                 api_key: run_event_secret
               })

      assert :ok =
               LemonCore.RunStore.finalize(run_id, %{
                 session_key: session_key,
                 agent_id: agent_id,
                 origin: :telegram,
                 prompt: "inspect run",
                 engine: "codex",
                 duration_ms: 10,
                 completed: %{
                   ok: false,
                   error: "token=#{error_secret}"
                 }
               })

      {:ok, result} =
        RunIntrospectionList.handle(
          %{"runId" => run_id, "includeRunRecord" => true, "includeRunEvents" => true},
          %{}
        )

      result_text = inspect(result)
      refute result_text =~ payload_secret
      refute result_text =~ bearer_secret
      refute result_text =~ run_event_secret
      refute result_text =~ error_secret

      assert result_text =~ "[REDACTED]"
      assert result["summary"]["cleanup"]["redactsSensitivePayloadValues"] == true
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      assert Enum.any?(get_in(result, ["runRecord", "events"]), fn event ->
               event["api_key"] == %{
                 "redacted" => true,
                 "kind" => "secret"
               }
             end)
    end

    test "redacts sensitive payload values from run.graph.get", %{
      agent_id: agent_id,
      session_key: session_key,
      run_id: run_id
    } do
      token = System.unique_integer([:positive, :monotonic])
      graph_secret = "graph-api-key-#{token}"
      graph_result_secret = "graph-result-token-#{token}"
      introspection_secret = "graph-introspection-secret-#{token}"
      run_event_secret = "graph-run-event-secret-#{token}"

      on_exit(fn ->
        CodingAgent.RunGraph.delete_run(run_id)
        LemonCore.RunStore.delete_session(session_key)
      end)

      LemonCore.Store.delete(:runs, run_id)

      assert :ok =
               CodingAgent.RunGraph.insert_record(run_id, %{
                 id: run_id,
                 status: :completed,
                 session_key: session_key,
                 started_at: System.system_time(:second),
                 completed_at: System.system_time(:second),
                 result: %{token: graph_result_secret, visible: "kept"},
                 api_key: graph_secret,
                 children: []
               })

      :ok =
        LemonCore.Introspection.record(
          :tool_started,
          %{
            secret: introspection_secret,
            message: "Bearer #{introspection_secret}"
          },
          run_id: run_id,
          session_key: session_key,
          agent_id: agent_id
        )

      assert :ok =
               LemonCore.RunStore.append_event(run_id, %{
                 __event__: :action_event,
                 action: %{title: "fetch", detail: "secret=#{run_event_secret}"},
                 credential: run_event_secret
               })

      assert :ok =
               LemonCore.RunStore.finalize(run_id, %{
                 session_key: session_key,
                 agent_id: agent_id,
                 origin: :telegram,
                 prompt: "inspect graph",
                 engine: "codex",
                 duration_ms: 10,
                 completed: %{
                   ok: true,
                   answer: "ok",
                   usage: %{input: 1, output: 1, total_tokens: 2}
                 }
               })

      {:ok, result} =
        RunGraphGet.handle(
          %{
            "runId" => run_id,
            "includeRunRecord" => true,
            "includeRunEvents" => true,
            "includeIntrospection" => true
          },
          %{}
        )

      result_text = inspect(result)
      refute result_text =~ graph_secret
      refute result_text =~ graph_result_secret
      refute result_text =~ introspection_secret
      refute result_text =~ run_event_secret

      assert result_text =~ "[REDACTED]"
      assert result["summary"]["cleanup"]["redactsSensitivePayloadValues"] == true
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      assert get_in(result, ["graph", "runRecord", "events"]) |> is_list()
    end
  end

  describe "transports.status" do
    setup do
      old_registry_module = Application.get_env(:lemon_control_plane, :transport_registry_module)

      on_exit(fn ->
        restore_transport_registry_module(old_registry_module)
      end)

      :ok
    end

    test "returns transport visibility snapshot" do
      assert TransportsStatus.name() == "transports.status"
      assert TransportsStatus.scopes() == [:read]

      {:ok, result} = TransportsStatus.handle(%{}, %{})

      assert is_boolean(result["registryRunning"])
      assert is_list(result["transports"])
      assert is_integer(result["total"])
      assert is_integer(result["enabled"])
      assert is_integer(result["disabled"])
      assert result["total"] == length(result["transports"])
      assert result["enabled"] <= result["total"]
      assert result["summary"]["configuredCount"] == result["total"]
      assert result["summary"]["enabledCount"] == result["enabled"]
      assert result["summary"]["disabledCount"] == result["disabled"]
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesRawConfig"] == false

      Enum.each(result["transports"], fn transport ->
        assert is_binary(transport["transportId"])
        assert is_boolean(transport["enabled"])
        assert transport["status"] in ["enabled", "disabled"]
      end)
    end

    test "returns empty snapshot when the gateway registry module is not loaded" do
      Application.put_env(
        :lemon_control_plane,
        :transport_registry_module,
        :"Elixir.LemonControlPlane.MissingTransportRegistryForTest"
      )

      {:ok, result} = TransportsStatus.handle(%{}, %{})

      assert result["registryRunning"] == false
      assert result["registryLoaded"] == false
      assert result["transports"] == []
      assert result["total"] == 0
      assert result["enabled"] == 0
      assert result["disabled"] == 0
      assert result["summary"]["status"] == "registry_stopped"
    end

    test "returns empty snapshot when the gateway registry module is loaded but stopped" do
      Application.put_env(:lemon_control_plane, :transport_registry_module, TransportRegistryStub)

      {:ok, result} = TransportsStatus.handle(%{}, %{})

      assert result["registryRunning"] == false
      assert result["registryLoaded"] == true
      assert result["transports"] == []
      assert result["summary"]["status"] == "registry_stopped"
    end

    test "returns configured and enabled transports when the legacy registry is running" do
      Application.put_env(:lemon_control_plane, :transport_registry_module, TransportRegistryStub)

      {:ok, pid} =
        TransportRegistryStub.start_link(%{
          transports: %{"email" => Example.EmailTransport, "webhook" => Example.WebhookTransport},
          enabled: ["webhook"]
        })

      try do
        {:ok, result} = TransportsStatus.handle(%{}, %{})

        assert result["registryRunning"] == true
        assert result["total"] == 2
        assert result["enabled"] == 1
        assert result["disabled"] == 1
        assert result["summary"]["status"] == "enabled"
        assert result["summary"]["moduleLoadedCount"] == 2
        assert result["summary"]["moduleMissingCount"] == 0

        assert result["transports"] == [
                 %{
                   "transportId" => "email",
                   "module" => "Elixir.Example.EmailTransport",
                   "enabled" => false,
                   "status" => "disabled"
                 },
                 %{
                   "transportId" => "webhook",
                   "module" => "Elixir.Example.WebhookTransport",
                   "enabled" => true,
                   "status" => "enabled"
                 }
               ]
      after
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end

    test "degrades safely when the registry API is missing or fails" do
      Application.put_env(
        :lemon_control_plane,
        :transport_registry_module,
        TransportRegistryMissingApiStub
      )

      {:ok, missing_api_pid} = TransportRegistryMissingApiStub.start_link(%{})

      try do
        {:ok, result} = TransportsStatus.handle(%{}, %{})
        assert result["registryRunning"] == true
        assert result["transports"] == []
        assert result["summary"]["status"] == "empty"
      after
        Process.unlink(missing_api_pid)
        Process.exit(missing_api_pid, :kill)
      end

      Application.put_env(
        :lemon_control_plane,
        :transport_registry_module,
        TransportRegistryCrashingStub
      )

      {:ok, crashing_pid} = TransportRegistryCrashingStub.start_link(%{})

      try do
        {:ok, result} = TransportsStatus.handle(%{}, %{})

        assert result["registryRunning"] == true
        assert result["summary"]["moduleMissingCount"] == 1

        assert result["transports"] == [
                 %{
                   "transportId" => "email",
                   "module" => nil,
                   "enabled" => false,
                   "status" => "disabled"
                 }
               ]
      after
        Process.unlink(crashing_pid)
        Process.exit(crashing_pid, :kill)
      end
    end
  end

  describe "introspection.snapshot" do
    test "returns a consolidated introspection payload", %{
      agent_id: agent_id,
      session_key: session_key,
      requirements_cwd: requirements_cwd
    } do
      assert IntrospectionSnapshot.name() == "introspection.snapshot"
      assert IntrospectionSnapshot.scopes() == [:read]

      {:ok, result} =
        IntrospectionSnapshot.handle(
          %{
            "agentId" => agent_id,
            "route" => %{"channelId" => "telegram"},
            "includeAgents" => true,
            "includeSessions" => true,
            "includeActiveSessions" => true,
            "includeChannels" => true,
            "includeTransports" => true
          },
          %{}
        )

      assert is_integer(result["generatedAtMs"])
      assert is_map(result["includes"])
      assert is_map(result["filters"])
      assert is_list(result["agents"])
      assert is_list(result["sessions"])
      assert is_list(result["activeSessions"])
      assert is_list(result["channels"])
      assert is_list(result["transports"])
      assert is_map(result["runs"])
      assert is_map(result["counts"])
      assert is_list(result["errors"])

      assert result["filters"]["agentId"] == agent_id
      assert result["filters"]["route"]["channelId"] == "telegram"
      assert result["counts"]["sessions"] == length(result["sessions"])
      assert result["counts"]["activeSessions"] == length(result["activeSessions"])
      assert result["counts"]["transports"] == length(result["transports"])
      assert result["summary"]["action"] == "introspection.snapshot"
      assert result["summary"]["includes"] == result["includes"]
      assert result["summary"]["counts"] == result["counts"]
      assert result["summary"]["runs"] == result["runs"]
      assert result["summary"]["filtersApplied"] == ["agentId", "route"]
      assert result["summary"]["errorCount"] == length(result["errors"])
      assert result["summary"]["harnessCount"] >= 1
      assert result["summary"]["cleanup"]["includesAgentRecords"] == true
      assert result["summary"]["cleanup"]["includesSessionRecords"] == true
      assert result["summary"]["cleanup"]["includesActiveSessionRecords"] == true
      assert result["summary"]["cleanup"]["includesHarnessSnapshots"] == true
      assert result["summary"]["cleanup"]["includesChannelStatus"] == true
      assert result["summary"]["cleanup"]["includesTransportStatus"] == true
      assert result["summary"]["cleanup"]["includesMessageText"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      assert Enum.any?(result["activeSessions"], &(&1["sessionKey"] == session_key))

      assert session = Enum.find(result["activeSessions"], &(&1["sessionKey"] == session_key))
      assert is_map(session["harness"])
      assert session["harness"]["todos"]["total"] == 1

      assert session["harness"]["requirements"]["project_name"] ==
               "Control Plane Harness Projection"

      assert session["harness"]["requirements"]["cwd"] == requirements_cwd
    end

    test "honors include toggles" do
      {:ok, result} =
        IntrospectionSnapshot.handle(
          %{
            "includeAgents" => false,
            "includeSessions" => false,
            "includeActiveSessions" => false,
            "includeChannels" => false,
            "includeTransports" => false
          },
          %{}
        )

      assert result["agents"] == []
      assert result["sessions"] == []
      assert result["activeSessions"] == []
      assert result["channels"] == []
      assert result["transports"] == []
      assert result["summary"]["counts"]["agents"] == 0
      assert result["summary"]["cleanup"]["includesAgentRecords"] == false
      assert result["summary"]["cleanup"]["includesSessionRecords"] == false
      assert result["summary"]["cleanup"]["includesActiveSessionRecords"] == false
      assert result["summary"]["cleanup"]["includesChannelStatus"] == false
      assert result["summary"]["cleanup"]["includesTransportStatus"] == false
    end
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

  defp restore_session_coordinator(nil),
    do: Application.delete_env(:lemon_router, :session_coordinator)

  defp restore_session_coordinator(config) do
    Application.put_env(:lemon_router, :session_coordinator, config)
  end

  defp restore_transport_registry_module(nil) do
    Application.delete_env(:lemon_control_plane, :transport_registry_module)
  end

  defp restore_transport_registry_module(config) do
    Application.put_env(:lemon_control_plane, :transport_registry_module, config)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
