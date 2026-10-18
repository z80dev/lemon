defmodule LemonControlPlane.Methods.IntrospectionMethodsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.FeatureRequirements
  alias CodingAgent.Tools.TodoStore
  alias CodingAgent.Tools.TodoWrite
  alias LemonAi.Types.{Model, ModelCost}

  alias LemonControlPlane.Methods.{
    ChatHistory,
    CronRuns,
    SessionDetail,
    SessionsActive,
    SessionsActiveList,
    SessionsList,
    SessionsPreview
  }

  alias LemonControlPlane.Protocol.Frames
  alias LemonCore.SessionKey

  defmodule IntrospectionFailureBackend do
    @behaviour LemonCore.Store.Backend

    def init(opts), do: {:ok, {Keyword.fetch!(opts, :backend), Keyword.fetch!(opts, :state)}}
    def put(state, table, key, value), do: forward(state, :put, [table, key, value])
    def put_new(state, table, key, value), do: forward(state, :put_new, [table, key, value])
    def get(state, table, key), do: forward(state, :get, [table, key])
    def delete(state, table, key), do: forward(state, :delete, [table, key])

    def list(_state, :introspection_log),
      do: {:error, {:sqlite_busy, "private-backend-detail"}}

    def list(state, table), do: forward(state, :list, [table])

    defp forward({backend, backend_state}, operation, args) do
      case apply(backend, operation, [backend_state | args]) do
        {:ok, value, next_state} -> {:ok, value, {backend, next_state}}
        {:ok, next_state} -> {:ok, {backend, next_state}}
        {:exists, next_state} -> {:exists, {backend, next_state}}
        other -> other
      end
    end
  end

  defp with_introspection_failure(fun) do
    original = :sys.get_state(LemonCore.Store)

    :sys.replace_state(LemonCore.Store, fn state ->
      %{
        state
        | backend: IntrospectionFailureBackend,
          backend_state: {state.backend, state.backend_state}
      }
    end)

    try do
      fun.()
    after
      :sys.replace_state(LemonCore.Store, fn _ -> original end)
    end
  end

  test "active session details fail explicitly when workspace history is unavailable", %{
    agent_id: agent_id
  } do
    params = %{"agentId" => agent_id}

    with_introspection_failure(fn ->
      assert SessionsActiveList.handle(params, %{}) ==
               {:error, {:unavailable, "Active session details are unavailable", nil}}
    end)

    assert {:ok, %{"sessions" => [%{"harness" => harness}]}} =
             SessionsActiveList.handle(params, %{})

    assert is_map(harness["requirements"])
  end

  test "cron timelines fail explicitly without breaking history-only reads", %{run_id: run_id} do
    job_id = "cron_introspection_#{System.unique_integer([:positive])}"

    run =
      job_id
      |> LemonAutomation.CronRun.new(:manual)
      |> LemonAutomation.CronRun.start(run_id)
      |> LemonAutomation.CronRun.complete("done")

    LemonAutomation.CronStore.put_run(run)
    on_exit(fn -> LemonAutomation.CronStore.delete_run(run.id) end)

    with_introspection_failure(fn ->
      assert {:ok, %{"runs" => [%{"id" => id}]}} =
               CronRuns.handle(%{"id" => job_id}, %{})

      assert id == run.id

      assert CronRuns.handle(
               %{"id" => job_id, "includeIntrospection" => true},
               %{}
             ) == {:error, {:unavailable, "Introspection events are unavailable", nil}}
    end)

    assert {:ok, %{"runs" => [%{"introspection" => events}]}} =
             CronRuns.handle(
               %{"id" => job_id, "includeIntrospection" => true},
               %{}
             )

    assert Enum.any?(events, &(&1["eventType"] == "session_started"))
  end

  defmodule RouterBridgeStub do
    use LemonCore.RouterBridge.Router

    @active_sessions_key {__MODULE__, :active_sessions}
    @active_run_result_key {__MODULE__, :active_run_result}

    def set_active_sessions(entries) when is_list(entries) do
      :persistent_term.put(@active_sessions_key, entries)
    end

    def clear_active_sessions do
      :persistent_term.erase(@active_sessions_key)
      :persistent_term.erase(@active_run_result_key)
    end

    def set_active_run_result(result), do: :persistent_term.put(@active_run_result_key, result)

    def active_run(session_key) do
      case :persistent_term.get(@active_run_result_key, :from_active_sessions) do
        :from_active_sessions ->
          case Enum.find(active_sessions(), &(&1.session_key == session_key)) do
            %{run_id: run_id} -> {:ok, run_id}
            _ -> :none
          end

        {:raise, message} ->
          raise message

        result ->
          result
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

    def set_active_sessions_result(result), do: :persistent_term.put(@active_sessions_key, result)

    def active_run_for_session(session_key) do
      case active_sessions() do
        sessions when is_list(sessions) ->
          case Enum.find(sessions, &(&1.session_key == session_key)) do
            %{run_id: run_id} -> {:ok, run_id}
            _ -> :none
          end

        error ->
          error
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
      FeatureRequirements.save_requirements(
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

    :ok = LemonCore.RouterBridge.configure(router: RouterBridgeStub)
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

    assert {:ok, native} =
             CodingAgent.ControlPlaneProvider.session_create(session_key, requirements_cwd)

    native_path =
      CodingAgent.SessionManager.session_file_path(requirements_cwd, native["sessionId"])

    session =
      start_supervised!(
        {CodingAgent.Session,
         cwd: requirements_cwd,
         workspace_dir: Path.join(requirements_cwd, "workspace"),
         session_file: native_path,
         session_key: session_key,
         model: fixture_model(),
         tools: []}
      )

    assert %LemonAgent.Types.AgentToolResult{} =
             TodoWrite.execute(
               "todo",
               %{
                 "todos" => [
                   %{"id" => "todo-introspection-1", "content" => "verify harness projection"}
                 ]
               },
               nil,
               nil,
               session
             )

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
      TodoStore.delete(native["sessionId"])
      LemonCore.ChatStateStore.delete(session_key)
      LemonCore.RunStore.delete_session(session_key)
      File.rm_rf!(CodingAgent.Config.sessions_dir(requirements_cwd))
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

  defp fixture_model do
    %Model{
      id: "introspection-projection",
      name: "Introspection projection",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4_096
    }
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

    test "returns bounded errors without exposing router exceptions, paths, or secrets" do
      secret = "SESSIONS_ACTIVE_SECRET_#{System.unique_integer([:positive])}"
      private_path = "/private/control-plane/#{secret}"

      for router_result <- [
            {:error, {:router_bug, %{credential: secret, path: private_path}}},
            {:raise, "router exception #{secret} at #{private_path}"}
          ] do
        RouterBridgeStub.set_active_run_result(router_result)

        result = SessionsActive.handle(%{"sessionKey" => "agent:secret:main"}, %{})
        assert {:error, {:internal_error, "Unable to read active session state", nil}} = result

        wire = Frames.encode_response("sessions-active-secret", result)
        assert Jason.decode!(wire)["error"]["code"] == "INTERNAL_ERROR"
        refute wire =~ secret
        refute wire =~ private_path
        refute wire =~ "router_bug"
      end

      RouterBridgeStub.set_active_run_result({:error, :unavailable})

      unavailable = SessionsActive.handle(%{"sessionKey" => "agent:offline:main"}, %{})

      assert {:error, {:unavailable, "Run activity is temporarily unavailable", nil}} =
               unavailable

      unavailable_wire = Frames.encode_response("sessions-active-offline", unavailable)
      assert Jason.decode!(unavailable_wire)["error"]["code"] == "UNAVAILABLE"
      refute unavailable_wire =~ secret
      refute unavailable_wire =~ private_path
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

    test "list and detail return bounded unavailable errors when routing state is down" do
      SessionCoordinatorStub.set_active_sessions_result({:error, :unavailable})

      assert {:error, {:unavailable, "Active sessions are unavailable", nil}} =
               SessionsActiveList.handle(%{}, %{})

      assert {:error, {:unavailable, "Session directory is unavailable", nil}} =
               SessionDetail.handle(%{"sessionKey" => "agent:offline:main"}, %{})
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
      assert run["tokens"] == %{"input" => 1, "output" => 2, "total" => 3, "costUsd" => nil}
      refute Map.has_key?(run, "promptFull")
      refute Map.has_key?(run, "answerFull")
      refute inspect(detail) =~ prompt_secret
      refute inspect(detail) =~ answer_secret
      refute inspect(detail) =~ tool_secret
      refute inspect(detail) =~ prompt_inline_secret
      refute inspect(detail) =~ answer_inline_secret

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

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

  defp restore_session_coordinator(nil),
    do: Application.delete_env(:lemon_router, :session_coordinator)

  defp restore_session_coordinator(config) do
    Application.put_env(:lemon_router, :session_coordinator, config)
  end

  defp eventually(fun, attempts \\ 300)

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
