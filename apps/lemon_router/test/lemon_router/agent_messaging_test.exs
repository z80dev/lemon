defmodule LemonRouter.AgentMessagingTest do
  use ExUnit.Case, async: false

  alias LemonCore.{
    AgentIdentity,
    ChatStateStore,
    Event,
    ExecutionCommand,
    MapHelpers,
    ResumeToken,
    RunRequest,
    RunStore,
    Store
  }

  alias LemonRouter.{AgentMessaging, AgentMessagingSessions, ResumeResolver, RunCompletion}

  # This deterministic execution boundary runs the real router/orchestrator,
  # coordinator, fixed-ID admission and RunProcess. Tests finalize actual queued
  # commands rather than replacing AgentMessaging or echoing tool arguments.
  defmodule ControlledRuntime do
    @behaviour LemonCore.EngineRuntime
    def available?, do: true
    def run_pid(_), do: nil
    def cancel_by_run_id(_, _), do: :ok

    def submit_execution(command) do
      send(Application.fetch_env!(:lemon_router, :named_agent_test_pid), {:execution, command})
      :ok
    end
  end

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    scope = "bot:named-router-#{suffix}:owner"
    previous_runtime = Application.get_env(:lemon_router, :engine_runtime)
    previous_pid = Application.get_env(:lemon_router, :named_agent_test_pid)
    Application.put_env(:lemon_router, :engine_runtime, ControlledRuntime)
    Application.put_env(:lemon_router, :named_agent_test_pid, self())

    on_exit(fn ->
      restore_env(:engine_runtime, previous_runtime)
      restore_env(:named_agent_test_pid, previous_pid)

      case AgentIdentity.list(scope) do
        {:ok, entries} -> Enum.each(entries, &AgentIdentity.remove(scope, &1.id))
        _ -> :ok
      end

      case Store.fetch_all(:agent_message_receipts) do
        {:ok, rows} ->
          Enum.each(rows, fn {id, row} ->
            if row.scope == scope or String.ends_with?(id, "-#{suffix}"),
              do: Store.delete(:agent_message_receipts, id)
          end)

        _ ->
          :ok
      end
    end)

    %{suffix: suffix, scope: scope}
  end

  test "busy named native target keeps its context and returns exactly one correlated asynchronous answer",
       %{suffix: suffix} do
    source_key = "agent:default:main:sub:named-source-#{suffix}"
    target_key = "agent:default:tui:local:main:named-target-#{suffix}"
    source_cwd = Path.expand(System.tmp_dir!())
    target_cwd = File.cwd!()

    source_mcp = [
      %{"name" => "ordinary-test", "headers" => %{"Authorization" => "ephemeral-test-secret"}}
    ]

    source =
      seed_native(source_key, source_cwd, "source-model", "source-#{suffix}", %{
        mcp_servers: source_mcp,
        native_managed_context: false
      })

    target = seed_native(target_key, target_cwd, "target-model", "target-#{suffix}")
    source_id = "session://" <> source_key
    target_id = "session://" <> target_key
    handle = "bob_#{suffix}"

    # Naming an exact persisted conversation works without a roster/list call.
    assert {:ok, %{id: ^target_id, name: ^handle}} =
             AgentMessaging.rename("operator", target_id, handle)

    assert {:ok, busy_id} =
             LemonRouter.submit(%RunRequest{
               session_key: target_key,
               agent_id: "default",
               prompt: "unrelated active work",
               cwd: target_cwd,
               model: "target-model"
             })

    assert_receive {:execution, %ExecutionCommand{run_id: ^busy_id} = busy}, 2_000

    message_id = "native-#{suffix}"

    send_opts = [
      message_id: message_id,
      source_context: %{
        session_key: source_key,
        run_id: source.run_id,
        cwd: source_cwd,
        tool_policy: source.tool_policy,
        session_pid: self(),
        task_child: false,
        native_managed_context: false,
        invocation_mcp_servers: source_mcp
      }
    ]

    assert {:ok, %{status: :accepted, run_id: peer_run_id, target_id: ^target_id}} =
             AgentMessaging.send(
               "operator",
               source_id,
               "@" <> handle,
               "What did you find?",
               send_opts
             )

    refute_receive {:execution, %ExecutionCommand{run_id: ^peer_run_id}}, 50

    finish(busy, "unrelated work done")
    assert_receive {:execution, %ExecutionCommand{run_id: ^peer_run_id} = peer}, 2_000
    assert peer.session_key == target_key
    assert peer.cwd == target_cwd
    assert peer.resume == target.resume
    assert peer.meta.model == "target-model"
    assert peer.meta.named_agent_message == true

    assert [%{direction: "request", source_id: ^source_id, target_id: ^target_id}] =
             MapHelpers.get_key(peer.meta, :async_followups)

    assert Jason.decode!(String.split(peer.prompt, "\n", parts: 2) |> List.last())["text"] ==
             "What did you find?"

    finish(peer, "The visible target answer")
    assert_receive {:execution, %ExecutionCommand{session_key: ^source_key} = reply}, 2_000
    assert reply.cwd == source_cwd
    assert reply.resume == source.resume
    assert reply.meta.model == "source-model"
    assert reply.meta.mcp_servers == source_mcp
    assert reply.meta.named_agent_reply == true
    assert reply.meta.named_agent_message == false
    refute Map.has_key?(reply.meta, :agent_inbox_message)

    assert [%{direction: "result", message_id: ^message_id}] =
             MapHelpers.get_key(reply.meta, :async_followups)

    assert reply.prompt =~ "The visible target answer"
    finish(reply, "Received peer result")

    assert {:ok, completed} = AgentMessaging.get("operator", source_id, message_id)
    assert completed.status == :completed
    assert completed.response == "The visible target answer"
    assert {:ok, private_row} = Store.fetch(:agent_message_receipts, message_id)
    refute Map.has_key?(private_row.source_context, :session_pid)
    refute Map.has_key?(private_row.source_context, :invocation_mcp_servers)
    refute Map.has_key?(private_row.source_context.meta, :mcp_servers)
    assert private_row.source_context.runtime_context_required

    assert {:ok, ^completed} =
             AgentMessaging.send(
               "operator",
               source_id,
               "@" <> handle,
               "What did you find?",
               send_opts
             )

    refute_receive {:execution, _}, 50

    restart_messaging()
    assert {:ok, ^completed} = AgentMessaging.get("operator", source_id, message_id)
    refute_receive {:execution, _}, 50
  end

  test "external transport is sender-bound, targeted, scoped and replay-safe", %{
    scope: scope,
    suffix: suffix
  } do
    source_pid = connection(:source)
    target_pid = connection(:target)
    outsider_pid = connection(:outsider)
    source = register_bot(scope, "source-#{suffix}", source_pid)
    target = register_bot(scope, "target-#{suffix}", target_pid)
    id = "external-#{suffix}"

    assert {:error, :forbidden} =
             AgentMessaging.send(scope, source.id, target.id, "private question",
               message_id: id,
               conn_pid: outsider_pid
             )

    assert {:ok, accepted} =
             AgentMessaging.send(scope, source.id, target.id, "private question",
               message_id: id,
               conn_pid: source_pid
             )

    assert accepted.status == :accepted
    assert_receive {:connection, :target, {:named_agent_event, "agent.message.request", request}}

    assert request == %{
             "messageId" => id,
             "sourceId" => source.id,
             "targetId" => target.id,
             "text" => "private question"
           }

    refute_receive {:connection, :source, {:named_agent_event, "agent.message.request", _}}, 20
    refute_receive {:connection, :outsider, _}, 20
    refute_receive {:named_agent_event, _, _}, 20

    assert {:ok, ^accepted} =
             AgentMessaging.send(scope, source.id, target.id, "private question",
               message_id: id,
               conn_pid: source_pid
             )

    refute_receive {:connection, :target, _}, 20

    assert {:error, :message_id_conflict} =
             AgentMessaging.send(scope, source.id, target.id, "changed question",
               message_id: id,
               conn_pid: source_pid
             )

    assert {:error, :not_found} = AgentMessaging.get("operator", source.id, id)
    assert {:error, :not_found} = AgentMessaging.get(scope, target.id, id)

    assert {:error, :forbidden} =
             AgentMessaging.complete_external(outsider_pid, id, %{
               status: :completed,
               response: "spoofed"
             })

    assert {:error, :invalid_completion} =
             AgentMessaging.complete_external(target_pid, id, %{
               status: :completed,
               response: "spoofed",
               source_id: target.id
             })

    completion = %{status: :completed, run_id: "product-run", response: "Visible peer response"}
    assert {:ok, completed} = AgentMessaging.complete_external(target_pid, id, completion)
    assert_receive {:connection, :source, {:named_agent_event, "agent.message.result", result}}
    assert result["messageId"] == id
    assert result["response"] == "Visible peer response"
    assert result["status"] == "completed"
    assert {:ok, ^completed} = AgentMessaging.complete_external(target_pid, id, completion)

    assert {:error, :completion_conflict} =
             AgentMessaging.complete_external(target_pid, id, %{
               completion
               | response: "different answer"
             })

    refute_receive {:connection, _, {:named_agent_event, "agent.message.request", _}}, 20
    refute_receive {:connection, :source, {:named_agent_event, "agent.message.result", _}}, 20
  end

  test "disconnect does not replay unknown requests and current same-target transport can reconcile",
       %{scope: scope, suffix: suffix} do
    source_pid = connection(:source)
    old_target_pid = connection(:old_target)
    source = register_bot(scope, "source-#{suffix}", source_pid)
    target = register_bot(scope, "target-#{suffix}", old_target_pid)
    id = "reconnect-#{suffix}"

    assert {:ok, _} =
             AgentMessaging.send(scope, source.id, target.id, "one invocation",
               message_id: id,
               conn_pid: source_pid
             )

    assert_receive {:connection, :old_target, {:named_agent_event, "agent.message.request", _}}

    assert {:ok, _} =
             AgentMessaging.complete_external(old_target_pid, id, %{
               status: :accepted,
               run_id: "fixed-product-run"
             })

    Process.exit(old_target_pid, :kill)

    wait_until(fn ->
      case AgentMessaging.get(scope, source.id, id) do
        {:ok, %{status: :outcome_unknown}} -> true
        _ -> false
      end
    end)

    assert {:error, :offline} =
             AgentMessaging.send(scope, source.id, target.id, "offline new invocation",
               message_id: "offline-#{suffix}",
               conn_pid: source_pid
             )

    current_pid = connection(:current_target)
    register_bot(scope, "target-#{suffix}", current_pid)

    assert {:ok, %{status: :outcome_unknown}} =
             AgentMessaging.send(scope, source.id, target.id, "one invocation",
               message_id: id,
               conn_pid: source_pid
             )

    refute_receive {:connection, :current_target,
                    {:named_agent_event, "agent.message.request", _}},
                   20

    assert {:error, :forbidden} =
             AgentMessaging.complete_external(old_target_pid, id, %{status: :completed})

    assert {:error, :completion_conflict} =
             AgentMessaging.complete_external(current_pid, id, %{
               status: :completed,
               run_id: "different-run",
               response: "wrong"
             })

    assert {:ok, %{status: :completed}} =
             AgentMessaging.complete_external(current_pid, id, %{
               status: :completed,
               run_id: "fixed-product-run",
               response: "authoritative late answer"
             })

    assert_receive {:connection, :source,
                    {:named_agent_event, "agent.message.result",
                     %{"response" => "authoritative late answer"}}}
  end

  test "offline source recovers a terminal result after rebind, but never receives it twice", %{
    scope: scope,
    suffix: suffix
  } do
    source_pid = connection(:source)
    target_pid = connection(:target)
    source = register_bot(scope, "source-#{suffix}", source_pid)
    target = register_bot(scope, "target-#{suffix}", target_pid)
    id = "offline-source-#{suffix}"

    assert {:ok, _} =
             AgentMessaging.send(scope, source.id, target.id, "question",
               message_id: id,
               conn_pid: source_pid
             )

    assert_receive {:connection, :target, {:named_agent_event, "agent.message.request", _}}
    Process.exit(source_pid, :kill)

    assert {:ok, %{status: :completed}} =
             AgentMessaging.complete_external(target_pid, id, %{
               status: :completed,
               response: "retained result"
             })

    assert {:ok, %{response: "retained result"}} = AgentMessaging.get(scope, source.id, id)

    restarted_pid = connection(:restarted_source)
    register_bot(scope, "source-#{suffix}", restarted_pid)

    assert_receive {:connection, :restarted_source,
                    {:named_agent_event, "agent.message.result", _}}

    restart_messaging()
    register_bot(scope, "source-#{suffix}", restarted_pid)
    register_bot(scope, "target-#{suffix}", target_pid)
    assert {:ok, %{status: :completed}} = AgentMessaging.get(scope, source.id, id)

    refute_receive {:connection, :restarted_source,
                    {:named_agent_event, "agent.message.result", _}},
                   20

    refute_receive {:connection, :target, {:named_agent_event, "agent.message.request", _}}, 20
  end

  test "native identity boundaries exclude managed, actual children, remote and external-channel contexts",
       %{suffix: suffix} do
    ordinary =
      seed_native(
        "agent:default:main:sub:ordinary-#{suffix}",
        System.tmp_dir!(),
        "ordinary-model",
        "ordinary-#{suffix}"
      )

    fork =
      seed_native(
        "agent:default:fork:local:main:fork-#{suffix}",
        System.tmp_dir!(),
        "fork-model",
        "fork-#{suffix}"
      )

    id = "session://" <> ordinary.session_key

    assert {:error, :self_send} =
             AgentMessaging.send("operator", id, id, "no loop", message_id: "self-#{suffix}")

    assert {:error, :not_found} =
             AgentMessaging.send("operator", id, "@missing_#{suffix}", "unknown",
               message_id: "unknown-#{suffix}"
             )

    assert {:error, :forbidden} =
             AgentMessaging.send("operator", id, "@missing_#{suffix}", "spoof",
               message_id: "spoof-#{suffix}",
               source_context: %{session_key: "agent:default:main", native_managed_context: false}
             )

    for {label, meta, key} <- [
          {"managed", %{invocation_proof_verified: true},
           "agent:default:main:sub:managed-#{suffix}"},
          {"child", %{task_child: true}, "agent:default:main:sub:child-#{suffix}"},
          {"remote", %{node: "remote-node"}, "agent:default:main:sub:remote-#{suffix}"},
          {"channel", %{}, "agent:default:telegram:account:dm:external-#{suffix}"}
        ] do
      command = %ExecutionCommand{
        run_id: "#{label}-#{suffix}",
        session_key: key,
        prompt: "private",
        cwd: System.tmp_dir!(),
        tool_policy: %{},
        meta: Map.put(meta, :agent_id, "default")
      }

      :ok = RunStore.create_session_index(key, "default", :control_plane)
      :ok = AgentMessagingSessions.capture(command)
      on_exit(fn -> cleanup_native(key) end)

      assert {:error, :forbidden} =
               AgentMessaging.rename(
                 "operator",
                 "session://" <> key,
                 "private_#{label}_#{suffix}"
               )
    end

    assert {:ok, entries} = AgentMessaging.list("operator", query: suffix, limit: 200)
    assert Enum.any?(entries, &(&1.id == id))
    assert Enum.any?(entries, &(&1.id == "session://" <> fork.session_key))
    refute Enum.any?(entries, &String.contains?(&1.id, "managed-#{suffix}"))
    refute Enum.any?(entries, &String.contains?(&1.id, "child-#{suffix}"))
    refute Enum.any?(entries, &String.contains?(&1.id, "remote-#{suffix}"))
    refute Enum.any?(entries, &String.contains?(&1.id, "external-#{suffix}"))

    refute Enum.any?(
             entries,
             &(Map.has_key?(&1, :cwd) or Map.has_key?(&1, :prompt) or Map.has_key?(&1, :response))
           )

    assert {:ok, []} = AgentMessaging.list("bot:private-#{suffix}:member")
  end

  test "a definite native admission failure is durable and is not retried after configuration repair",
       %{suffix: suffix} do
    source =
      seed_native(
        "agent:default:main:sub:failure-source-#{suffix}",
        System.tmp_dir!(),
        "source-model",
        "failure-source-#{suffix}"
      )

    target =
      seed_native(
        "agent:default:main:sub:failure-target-#{suffix}",
        System.tmp_dir!(),
        "target-model",
        "failure-target-#{suffix}"
      )

    source_id = "session://" <> source.session_key
    target_id = "session://" <> target.session_key
    id = "failure-#{suffix}"
    :ok = LemonCore.PolicyStore.put_session(target.session_key, "malformed persisted policy")
    on_exit(fn -> LemonCore.PolicyStore.delete_session(target.session_key) end)

    assert {:error, :submission_failed} =
             AgentMessaging.send("operator", source_id, target_id, "do not silently retry",
               message_id: id
             )

    assert {:ok, %{status: :failed, error: "submission_failed"} = failed} =
             AgentMessaging.get("operator", source_id, id)

    :ok = LemonCore.PolicyStore.delete_session(target.session_key)

    assert {:ok, ^failed} =
             AgentMessaging.send("operator", source_id, target_id, "do not silently retry",
               message_id: id
             )

    refute_receive {:execution, _}, 50
  end

  test "text and visible responses are bounded before any external mutation", %{
    scope: scope,
    suffix: suffix
  } do
    source_pid = connection(:source)
    target_pid = connection(:target)
    source = register_bot(scope, "source-#{suffix}", source_pid)
    target = register_bot(scope, "target-#{suffix}", target_pid)
    id = "bounds-#{suffix}"

    assert {:error, :invalid_arguments} =
             AgentMessaging.send(scope, source.id, target.id, String.duplicate("é", 16_385),
               message_id: id,
               conn_pid: source_pid
             )

    assert {:error, :not_found} = AgentMessaging.get(scope, source.id, id)
    refute_receive {:connection, :target, _}, 20

    assert {:ok, _} =
             AgentMessaging.send(scope, source.id, target.id, "bounded",
               message_id: id,
               conn_pid: source_pid
             )

    assert_receive {:connection, :target, {:named_agent_event, "agent.message.request", _}}

    assert {:error, :invalid_completion} =
             AgentMessaging.complete_external(target_pid, id, %{
               status: :completed,
               response: String.duplicate("x", 32_769)
             })

    assert {:error, :invalid_completion} =
             AgentMessaging.complete_external(target_pid, id, %{
               status: :completed,
               response: <<255>>
             })

    assert {:ok, %{status: :accepted, response: nil}} = AgentMessaging.get(scope, source.id, id)
  end

  test "filtered discovery fails closed on an unrelated malformed session and recovers after removal",
       %{suffix: suffix} do
    query = "discovery-#{suffix}"

    source =
      seed_native(
        "agent:default:main:sub:#{query}",
        System.tmp_dir!(),
        "query-model",
        query
      )

    id = "session://" <> source.session_key
    malformed_key = "agent:malformed_#{suffix}:main"
    on_exit(fn -> Store.delete(:sessions_index, malformed_key) end)

    # A low-level Store/cache fixture may use arbitrary maps. If it leaks into
    # the shared session index, filtering must not hide the corrupt owner row.
    assert :ok =
             Store.put(:sessions_index, malformed_key, %{
               agent_id: "malformed_#{suffix}",
               updated_at_ms: System.system_time(:millisecond)
             })

    assert {:error, :unavailable} = AgentMessaging.list("operator", query: query, limit: 200)
    assert :ok = Store.delete(:sessions_index, malformed_key)
    assert {:ok, entries} = AgentMessaging.list("operator", query: query, limit: 200)
    assert Enum.any?(entries, &(&1.id == id))
  end

  test "an unavailable native owner query is unknown, never an invented idle status", %{
    suffix: suffix
  } do
    source =
      seed_native(
        "agent:default:main:sub:query-#{suffix}",
        System.tmp_dir!(),
        "query-model",
        "query-#{suffix}"
      )

    id = "session://" <> source.session_key
    :ok = Supervisor.terminate_child(LemonRouter.Supervisor, LemonRouter.RunOrchestrator)

    try do
      assert {:ok, entries} = AgentMessaging.list("operator", query: suffix, limit: 200)
      assert %{status: :unknown} = Enum.find(entries, &(&1.id == id))
    after
      assert {:ok, _} =
               Supervisor.restart_child(LemonRouter.Supervisor, LemonRouter.RunOrchestrator)
    end
  end

  test "durable message receipts survive reopening without replaying a delivered request", %{
    scope: scope,
    suffix: suffix
  } do
    path = Path.join(System.tmp_dir!(), "named_message_durable_#{suffix}")
    previous = :sys.get_state(Store)
    assert {:ok, backend_state} = LemonCore.Store.JsonlBackend.init(path: path)
    :ok = Supervisor.terminate_child(LemonRouter.Supervisor, AgentMessaging)

    :sys.replace_state(Store, fn state ->
      %{state | backend: LemonCore.Store.JsonlBackend, backend_state: backend_state}
    end)

    try do
      assert {:ok, _} = Supervisor.restart_child(LemonRouter.Supervisor, AgentMessaging)
      source_pid = connection(:durable_source)
      target_pid = connection(:durable_target)
      source = register_bot(scope, "source-#{suffix}", source_pid)
      target = register_bot(scope, "target-#{suffix}", target_pid)
      assert {:ok, _} = AgentMessaging.rename(scope, target.id, "durable_bob")
      message_id = "durable-#{suffix}"
      options = [message_id: message_id, conn_pid: source_pid]

      assert {:ok, %{status: :accepted}} =
               AgentMessaging.send(
                 scope,
                 source.id,
                 "@durable_bob",
                 "retain this request",
                 options
               )

      assert_receive {:connection, :durable_target,
                      {:named_agent_event, "agent.message.request", %{"messageId" => ^message_id}}}

      assert {:ok, %{status: :completed, response: "durable answer"} = completed} =
               AgentMessaging.complete_external(target_pid, message_id, %{
                 status: :completed,
                 response: "durable answer"
               })

      assert_receive {:connection, :durable_source,
                      {:named_agent_event, "agent.message.result",
                       %{"response" => "durable answer"}}}

      assert {:ok, _} = AgentMessaging.rename(scope, target.id, "durable_robert")
      assert :ok = Store.sync()
      :ok = Supervisor.terminate_child(LemonRouter.Supervisor, AgentMessaging)
      assert {:ok, reopened} = LemonCore.Store.JsonlBackend.init(path: path)
      :sys.replace_state(Store, fn state -> %{state | backend_state: reopened} end)
      assert {:ok, _} = Supervisor.restart_child(LemonRouter.Supervisor, AgentMessaging)
      register_bot(scope, "source-#{suffix}", source_pid)
      register_bot(scope, "target-#{suffix}", target_pid)

      assert {:ok, ^completed} = AgentMessaging.get(scope, source.id, message_id)

      assert {:ok, ^completed} =
               AgentMessaging.send(
                 scope,
                 source.id,
                 "@durable_bob",
                 "retain this request",
                 options
               )

      assert {:ok, %{id: target_id}} = AgentIdentity.resolve(scope, "@durable_robert")
      assert target_id == target.id

      refute_receive {:connection, :durable_target,
                      {:named_agent_event, "agent.message.request", _}},
                     50

      refute_receive {:connection, :durable_source,
                      {:named_agent_event, "agent.message.result", _}},
                     50
    after
      :ok = Supervisor.terminate_child(LemonRouter.Supervisor, AgentMessaging)
      :sys.replace_state(Store, fn _state -> previous end)
      assert {:ok, _} = Supervisor.restart_child(LemonRouter.Supervisor, AgentMessaging)
      File.rm_rf!(path)
    end
  end

  defp seed_native(key, cwd, model, label, meta \\ %{}) do
    assert {:ok, run_id} =
             LemonRouter.submit(%RunRequest{
               session_key: key,
               agent_id: "default",
               prompt: "existing #{label}",
               cwd: cwd,
               model: model,
               meta: meta
             })

    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    resume = %ResumeToken{engine: "lemon", value: "resume-#{label}"}
    :ok = ResumeResolver.bind(resume, command)
    :ok = ChatStateStore.put(key, %{last_engine: "lemon", last_resume_token: resume.value})
    finish(command, "existing context #{label}")
    on_exit(fn -> cleanup_native(key) end)
    %{session_key: key, resume: resume, run_id: run_id, tool_policy: command.tool_policy}
  end

  defp finish(command, answer) do
    completed = LemonCore.Events.Completion.new(%{engine: "lemon", ok: true, answer: answer})

    event =
      Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{completed: completed, duration_ms: 1}),
        %{run_id: command.run_id, session_key: command.session_key}
      )

    :ok = RunCompletion.publish(command, event)
  end

  defp cleanup_native(key) do
    LemonRouter.abort(key)
    AgentIdentity.remove("operator", "session://" <> key)
    RunStore.delete_session(key)
    Store.delete(:agent_messaging_sessions, key)
    ChatStateStore.delete(key)
  end

  defp register_bot(scope, name, pid) do
    assert {:ok, entry} =
             AgentMessaging.register_external(
               scope,
               %{
                 id: "bot://named-router/#{name}",
                 kind: :bot,
                 label: name,
                 metadata: %{instance_id: "named-router", bot_id: name}
               },
               pid
             )

    entry
  end

  defp connection(label) do
    owner = self()
    pid = spawn(fn -> connection_loop(owner, label) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp connection_loop(owner, label) do
    receive do
      event ->
        send(owner, {:connection, label, event})
        connection_loop(owner, label)
    end
  end

  defp restart_messaging do
    :ok = Supervisor.terminate_child(LemonRouter.Supervisor, AgentMessaging)
    assert {:ok, _} = Supervisor.restart_child(LemonRouter.Supervisor, AgentMessaging)
  end

  defp wait_until(fun, remaining \\ 100)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_until(fun, remaining - 1)
        )
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_router, key, value)
end
