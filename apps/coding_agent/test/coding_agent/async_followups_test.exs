defmodule CodingAgent.AsyncFollowupsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{AsyncFollowups, Messages, TaskStore}
  alias CodingAgent.Session.State
  alias CodingAgent.Tools.Task.Followup

  defmodule SessionSpy do
    def handle_async_followup(owner, message) do
      send(owner, {:delivery, self(), {:live, State.build_async_followup_message(message)}})
      :ok
    end
  end

  defmodule RejectingSession do
    def handle_async_followup(owner, _message) do
      send(owner, :live_rejected)
      {:error, :unavailable}
    end
  end

  defmodule BlockingSession do
    def handle_async_followup(owner, message) do
      send(owner, {:blocked_delivery, self(), message})

      receive do
        :release -> :ok
      end
    end
  end

  defmodule RouterSpy do
    def submit(request) do
      send(request.meta.test_owner, {:delivery, self(), {:router, request}})
      {:ok, request.run_id}
    end
  end

  setup do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    server =
      start_supervised!(
        {AsyncFollowups,
         name: nil,
         task_supervisor: supervisor,
         schedule_flush: fn destination, message, delay ->
           send(owner, {:scheduled, destination, message, delay})
           make_ref()
         end}
      )

    context = %{
      parent_session_key: "agent:main:main",
      parent_agent_id: "main",
      session_pid: owner,
      session_module: SessionSpy,
      run_orchestrator: RouterSpy,
      meta: %{test_owner: owner},
      async_followup_server: server
    }

    %{server: server, context: context}
  end

  @tag :tmp_dir
  test "one batch starts exactly one model turn in an idle parent session", ctx do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})
    session_file = Path.join(ctx.tmp_dir, "parent.jsonl")

    :ok =
      CodingAgent.SessionManager.save_to_file(
        session_file,
        CodingAgent.SessionManager.new(ctx.tmp_dir)
      )

    respond =
      LemonAgent.Test.Mocks.mock_stream_fn_single(
        LemonAgent.Test.Mocks.assistant_message("batch received")
      )

    session =
      start_supervised!(
        {CodingAgent.Session,
         cwd: ctx.tmp_dir,
         workspace_dir: Path.join(ctx.tmp_dir, "workspace"),
         session_file: session_file,
         tools: [],
         mcp_tools: [],
         extension_inventory: {[], []},
         model: LemonAgent.Test.Mocks.mock_model(),
         stream_fn: fn model, context, options ->
           count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
           send(owner, {:parent_model_call, count, context})
           respond.(model, context, options)
         end}
      )

    session_id = CodingAgent.Session.get_stats(session).session_id
    _unsubscribe = CodingAgent.Session.subscribe(session)
    context = %{ctx.context | session_module: CodingAgent.Session, session_pid: session}

    for n <- 1..8 do
      enqueue(ctx.server, context, entry("model_task_#{n}"))
    end

    flush_batch(ctx.server)
    assert_receive {:parent_model_call, 1, model_context}, 5_000
    assert_receive {:session_event, ^session_id, {:agent_end, _}, _}, 5_000
    state = CodingAgent.Session.get_state(session)
    refute state.is_streaming
    assert :queue.is_empty(state.follow_up_queue)
    assert Agent.get(counter, & &1) == 1
    refute_receive {:parent_model_call, _, _}, 0

    rendered = inspect(model_context.messages, limit: :infinity, printable_limit: :infinity)

    for n <- 1..8 do
      assert rendered =~ "answer model_task_#{n}"
    end

    # Every child completion reaches the model inside its own untrusted envelope.
    assert length(
             Regex.scan(~r/<<<EXTERNAL_UNTRUSTED_CONTENT id=\\"[0-9a-f]{16}\\">>>/, rendered)
           ) ==
             8
  end

  test "N native completions in the fixed window deliver one parent followup", ctx do
    for n <- 1..8 do
      assert :ok =
               Followup.maybe_send_async_followup(
                 ctx.context,
                 "batch_task_#{n}",
                 "batch_run_#{n}",
                 {:ok, "answer #{n}"}
               )
    end

    assert map_size(:sys.get_state(ctx.server).batches) == 1
    refute_receive {:delivery, _, _}, 0
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    refute_receive {:scheduled, _, _, _}, 0
    refute_receive {:delivery, _, _}, 0

    assert Enum.map(message.details.async_followups, & &1.task_id) ==
             Enum.map(1..8, &"batch_task_#{&1}")

    assert Enum.all?(message.details.async_followups, &(&1.delivery == :followup))

    [llm_message] = Messages.to_llm([message])
    assert llm_message.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"

    for n <- 1..8 do
      assert message.content =~ "Task batch_task_#{n} completed.\n\nanswer #{n}"
      assert llm_message.content =~ "batch_run_#{n}"
    end
  end

  test "native and delegated completions share one router request with every provenance entry",
       ctx do
    context = Map.put(ctx.context, :session_pid, nil)
    task = entry("native")

    agent =
      Map.merge(entry("delegate"), %{source: :agent, agent_id: "oracle", session_key: "child"})

    enqueue(ctx.server, context, task)
    enqueue(ctx.server, context, agent)
    flush_batch(ctx.server)
    assert {:router, request} = receive_delivery()

    assert request.queue_mode == :followup
    assert request.session_key == context.parent_session_key
    assert request.meta.task_auto_followup
    assert request.meta.delegated_auto_followup
    refute Map.has_key?(request.meta, :task_id)
    refute Map.has_key?(request.meta, :delegated_task_id)

    assert request.meta["async_followups"] ==
             Enum.map([task, agent], &Map.put(&1, :delivery, :followup))

    refute_receive {:scheduled, _, _, _}, 0
    refute_receive {:delivery, _, _}, 0
  end

  test "the deadline is fixed and stale timers cannot flush the next window", ctx do
    enqueue(ctx.server, ctx.context, entry("first"))
    first_timer = flush_batch(ctx.server)
    assert {:live, _message} = receive_delivery()

    enqueue(ctx.server, ctx.context, entry("second"))
    send(ctx.server, first_timer)
    assert map_size(:sys.get_state(ctx.server).batches) == 1
    refute_receive {:delivery, _, _}, 0
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    assert [%{task_id: "second"}] = message.details.async_followups
    refute_receive {:delivery, _, _}, 0
  end

  test "a join started during the window suppresses only its wait_any winner", ctx do
    winner = TaskStore.new_task(%{description: "winner"})
    other = TaskStore.new_task(%{description: "other"})
    on_exit(fn -> Enum.each([winner, other], &TaskStore.delete_task/1) end)
    enqueue(ctx.server, ctx.context, entry(winner))
    enqueue(ctx.server, ctx.context, entry(other))

    token = make_ref()
    :ok = TaskStore.begin_auto_followup_join([winner, other], token)
    flush_batch(ctx.server)
    assert map_size(:sys.get_state(ctx.server).deferred) == 2
    refute_receive {:delivery, _, _}, 0

    :ok = TaskStore.finish_auto_followup_join([winner, other], [winner], token)
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    assert [%{task_id: ^other}] = message.details.async_followups
    refute message.content =~ winner
    assert :sys.get_state(ctx.server).deferred == %{}
    refute_receive {:delivery, _, _}, 0
  end

  test "permanent suppression at flush removes the completion from the entire payload", ctx do
    joined = TaskStore.new_task(%{description: "joined"})
    on_exit(fn -> TaskStore.delete_task(joined) end)
    enqueue(ctx.server, ctx.context, entry(joined))
    enqueue(ctx.server, ctx.context, entry("unjoined"))
    :ok = TaskStore.suppress_auto_followup(joined)
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    assert [%{task_id: "unjoined"}] = message.details.async_followups
    refute message.content =~ joined
  end

  test "a fully joined batch starts no parent continuation", ctx do
    task_id = TaskStore.new_task(%{description: "fully joined"})
    on_exit(fn -> TaskStore.delete_task(task_id) end)
    enqueue(ctx.server, ctx.context, entry(task_id))
    :ok = TaskStore.suppress_auto_followup(task_id)
    flush_batch(ctx.server)
    assert :sys.get_state(ctx.server).batches == %{}
    refute_receive {:delivery, _, _}, 0
  end

  test "a crashed joiner releases a completion held before its window starts", ctx do
    task_id = TaskStore.new_task(%{description: "orphaned reservation"})
    on_exit(fn -> TaskStore.delete_task(task_id) end)
    owner = self()

    {joiner, ref} =
      spawn_monitor(fn ->
        :ok = TaskStore.begin_auto_followup_join([task_id], make_ref())
        send(owner, :join_reserved)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :join_reserved
    enqueue(ctx.server, ctx.context, entry(task_id))
    assert map_size(:sys.get_state(ctx.server).deferred) == 1
    refute_receive {:scheduled, _, _, _}, 0
    send(joiner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^joiner, :normal}
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    assert [%{task_id: ^task_id}] = message.details.async_followups
  end

  test "delivery rechecks parent liveness after the window", ctx do
    {parent, ref} =
      spawn_monitor(fn ->
        receive do
          :stop -> :ok
        end
      end)

    context = Map.put(ctx.context, :session_pid, parent)
    enqueue(ctx.server, context, entry("one"))
    enqueue(ctx.server, context, entry("two"))
    send(parent, :stop)
    assert_receive {:DOWN, ^ref, :process, ^parent, :normal}
    flush_batch(ctx.server)
    assert {:router, request} = receive_delivery()
    assert length(request.meta["async_followups"]) == 2
    refute_receive {:delivery, _, _}, 0
  end

  test "a live rejection falls back once with the complete batch", ctx do
    context = Map.put(ctx.context, :session_module, RejectingSession)
    enqueue(ctx.server, context, entry("one"))
    enqueue(ctx.server, context, entry("two"))
    flush_batch(ctx.server)
    assert_receive :live_rejected
    assert {:router, request} = receive_delivery()
    assert length(request.meta["async_followups"]) == 2
    refute_receive {:delivery, _, _}, 0
  end

  test "different parent or authority contexts never merge", ctx do
    contexts = [
      ctx.context,
      Map.put(ctx.context, :parent_session_key, "agent:other:main"),
      Map.put(ctx.context, :invocation_context_key, "different-authority"),
      Map.put(ctx.context, :tool_policy, %{allow: ["read"]})
    ]

    for {context, n} <- Enum.with_index(contexts) do
      enqueue(ctx.server, context, entry("task#{n}"))
    end

    assert map_size(:sys.get_state(ctx.server).batches) == 4

    for _ <- contexts do
      flush_batch(ctx.server)
      assert {:live, message} = receive_delivery()
      assert length(message.details.async_followups) == 1
    end
  end

  test "legacy steer hints coalesce as non-preempting followups but interrupt stays routed",
       ctx do
    for mode <- [:steer, :steer_backlog, :followup] do
      enqueue(ctx.server, Map.put(ctx.context, :queue_mode, mode), entry(to_string(mode)))
    end

    enqueue(ctx.server, Map.put(ctx.context, :queue_mode, :interrupt), entry("interrupt"))
    assert map_size(:sys.get_state(ctx.server).batches) == 2
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    assert length(message.details.async_followups) == 3
    flush_batch(ctx.server)
    assert {:router, %{queue_mode: :interrupt}} = receive_delivery()
  end

  test "managed completions remain collected through the native authority seam", ctx do
    owner = self()

    context =
      Map.merge(ctx.context, %{
        native_managed_context: true,
        native_lineage_run_id: "parent-run",
        native_lineage_handle: "parent-handle",
        native_followup_submit: fn source, request ->
          send(owner, {:delivery, self(), {:managed, source, request}})
          {:ok, request.run_id}
        end
      })

    enqueue(ctx.server, context, entry("one"))
    enqueue(ctx.server, context, entry("two"))
    flush_batch(ctx.server)
    assert {:managed, source, request} = receive_delivery()
    assert source == %{run_id: "parent-run", lineage_handle: "parent-handle"}
    assert request.queue_mode == :collect
    assert length(request.meta["async_followups"]) == 2
    refute_receive {:delivery, _, _}, 0
  end

  test "a blocked parent does not block enqueue or delivery for another parent", ctx do
    enqueue(ctx.server, Map.put(ctx.context, :session_module, BlockingSession), entry("slow"))
    flush_batch(ctx.server)
    assert_receive {:blocked_delivery, worker, _message}
    ref = Process.monitor(worker)

    enqueue(ctx.server, ctx.context, entry("fast"))
    flush_batch(ctx.server)
    assert {:live, message} = receive_delivery()
    assert [%{task_id: "fast"}] = message.details.async_followups
    send(worker, :release)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
  end

  defp entry(task_id), do: %{source: :task, task_id: task_id, run_id: "run_#{task_id}"}

  defp enqueue(server, context, entry) do
    assert :ok = AsyncFollowups.enqueue(context, "answer #{entry.task_id}", entry, server)
  end

  defp flush_batch(server) do
    assert_receive {:scheduled, ^server, {:flush, _context, _token} = message, 50}, 1_000
    send(server, message)
    :sys.get_state(server)
    message
  end

  defp receive_delivery do
    assert_receive {:delivery, worker, payload}, 1_000
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, reason}, 1_000
    assert reason in [:normal, :noproc]
    payload
  end
end
