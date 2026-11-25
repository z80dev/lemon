defmodule LemonRouter.CoalescerLifecycleTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Event, SessionKey}
  alias LemonCore.Bus.Delivery
  alias LemonRouter.{CoalescerIngress, StreamCoalescer, SurfaceManager, ToolStatusCoalescer}

  defmodule Dispatcher do
    @moduledoc false

    def dispatch(intent) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil),
        do: send(pid, {:intent, intent})

      :ok
    end
  end

  @grace_ms 50
  @supervisors [LemonRouter.CoalescerSupervisor, LemonRouter.ToolStatusSupervisor]
  @registries [LemonRouter.CoalescerRegistry, LemonRouter.ToolStatusRegistry]

  setup do
    previous_dispatcher = Application.fetch_env(:lemon_router, :dispatcher)
    previous_grace = Application.fetch_env(:lemon_router, :coalescer_retire_after_ms)
    Application.put_env(:lemon_router, :dispatcher, Dispatcher)
    Application.put_env(:lemon_router, :coalescer_retire_after_ms, @grace_ms)
    :persistent_term.put({Dispatcher, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({Dispatcher, :test_pid})
      restore(:dispatcher, previous_dispatcher)
      restore(:coalescer_retire_after_ms, previous_grace)
    end)

    id = System.unique_integer([:positive])

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "lifecycle",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "lifecycle-#{id}"
      })

    {:ok, session_key: session_key}
  end

  test "after finalize plus the grace window a conversation's coalescers stop", ctx do
    # A longer grace so all three surfaces are observed before they retire.
    Application.put_env(:lemon_router, :coalescer_retire_after_ms, 500)
    run_once(ctx.session_key, "finalized")

    pids = conversation_coalescers(ctx.session_key)
    assert length(pids) == 3, "answer, status and task surfaces: #{inspect(pids)}"
    refs = Map.new(pids, &{Process.monitor(&1), &1})

    for {ref, pid} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    assert conversation_coalescers(ctx.session_key) == []
    children = Enum.flat_map(@supervisors, &supervisor_children/1)
    assert Enum.all?(pids, &(&1 not in children))
  end

  test "a run that never streamed starts no coalescer", ctx do
    run_id = "never-streamed-#{System.unique_integer([:positive])}"
    state = run_state(ctx.session_key, run_id)
    completed = completed_event(state, "the only answer")

    # The RunProcess completion sequence for a run without deltas or actions.
    assert :ok = SurfaceManager.finalize_status(state, completed)
    assert :ok = SurfaceManager.flush_status(state)
    assert :ok = SurfaceManager.finalize_answer(state, completed, %{})
    assert :ok = SurfaceManager.fanout_final_answer(state, completed)

    assert_receive {:intent,
                    %{
                      run_id: ^run_id,
                      kind: :stream_finalize,
                      body: %{text: "the only answer", seq: 0},
                      meta: %{surface: :answer, terminal_answer: true}
                    }}

    refute_receive {:intent, _}, 100
    assert conversation_coalescers(ctx.session_key) == []
  end

  test "status actions are capped, compacted and evicted ones reported as omitted", ctx do
    run_id = "capped-#{System.unique_integer([:positive])}"
    owner = start_run_owner(run_id)

    for n <- 1..100 do
      event = %{
        action_event("tool-#{n}", "tool", "step #{n}", %{
          args: %{content: String.duplicate("a", 4_096)},
          partial_result: String.duplicate("b", 4_096),
          result: String.duplicate("c", 4_096),
          result_meta: %{error_type: "boom", output: String.duplicate("d", 4_096)}
        })
        | phase: :completed
      }

      event = Map.put(event, :ok, false)
      ToolStatusCoalescer.ingest_action(ctx.session_key, "telegram", run_id, event)
    end

    [pid] = conversation_coalescers(ctx.session_key)
    state = :sys.get_state(pid)
    assert length(state.order) == 64
    assert map_size(state.actions) == 64
    assert state.omitted_actions == 36
    assert hd(state.order) == "tool-37"

    detail = state.actions["tool-100"].detail
    assert Map.keys(detail) |> Enum.sort() == [:result_meta, :result_preview]
    assert String.length(detail.result_preview) == 1_024
    assert detail.result_meta == %{error_type: "boom"}
    assert :erlang.external_size(state.actions) < 200_000

    assert :ok = ToolStatusCoalescer.flush(ctx.session_key, "telegram")
    :sys.get_state(pid)

    text = last_status_text(nil)
    assert text =~ "step 100"
    assert text =~ "(96 tools omitted)"
    assert text =~ "✗ step 100"
    send(owner, :stop)
  end

  defp last_status_text(last) do
    receive do
      {:intent, %{kind: :tool_status_snapshot, body: %{text: text}}} -> last_status_text(text)
    after
      0 -> last
    end
  end

  test "an async task surface stays while its subscriber is alive", ctx do
    run_id = "parent-#{System.unique_integer([:positive])}"
    surface = {:status_task, "task-root-#{System.unique_integer([:positive])}"}
    subscriber = start_task_subscriber(run_id, surface)

    ToolStatusCoalescer.ingest_projected_child_action(
      ctx.session_key,
      "telegram",
      run_id,
      surface,
      action_event("child-1", "tool", "child step", %{parent_tool_use_id: "task-root"})
    )

    [pid] = conversation_coalescers(ctx.session_key)
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, _, _, _}, @grace_ms * 6

    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "an unfinalized coalescer stays while its run is alive and retires after", ctx do
    run_id = "live-run-#{System.unique_integer([:positive])}"
    owner = start_run_owner(run_id)

    assert :ok = StreamCoalescer.ingest_delta(ctx.session_key, "telegram", run_id, 1, "partial")
    [pid] = conversation_coalescers(ctx.session_key)
    ref = Process.monitor(pid)

    refute_receive {:DOWN, ^ref, _, _, _}, @grace_ms * 6
    assert StreamCoalescer.current_text(ctx.session_key, "telegram", run_id) == "partial"

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "retirement yields to messages already queued and later work starts afresh", ctx do
    # The run has no live producer, so only the queued delta keeps it alive.
    Application.put_env(:lemon_router, :coalescer_retire_after_ms, 500)
    run_id = "queued-#{System.unique_integer([:positive])}"
    assert :ok = StreamCoalescer.ingest_delta(ctx.session_key, "telegram", run_id, 1, "one")
    [pid] = conversation_coalescers(ctx.session_key)

    :ok = :sys.suspend(pid)
    :sys.replace_state(pid, &%{&1 | last_activity_ms: &1.last_activity_ms - 10_000})
    send(pid, :retire_check)
    assert :ok = StreamCoalescer.ingest_delta(ctx.session_key, "telegram", run_id, 2, " two")
    :ok = :sys.resume(pid)

    assert StreamCoalescer.current_text(ctx.session_key, "telegram", run_id) == "one two"
    assert conversation_coalescers(ctx.session_key) == [pid]

    assert :ok = StreamCoalescer.finalize_run(ctx.session_key, "telegram", run_id)
    assert_receive {:intent, %{run_id: ^run_id, kind: :stream_finalize}}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    next_run = "after-retire-#{System.unique_integer([:positive])}"
    assert :ok = StreamCoalescer.ingest_delta(ctx.session_key, "telegram", next_run, 1, "fresh")
    assert StreamCoalescer.current_text(ctx.session_key, "telegram", next_run) == "fresh"
    assert [next_pid] = conversation_coalescers(ctx.session_key)
    assert next_pid != pid
  end

  test "work admitted during the retirement handshake is kept on a new generation" do
    registry = :"retire_handshake_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    test = self()

    owner =
      spawn_link(fn ->
        {:ok, _} = Registry.register(registry, :surface, nil)
        delivery = CoalescerIngress.register(registry, :surface, [])

        state = %{
          delivery: delivery,
          retire_after_ms: 10,
          last_activity_ms: System.monotonic_time(:millisecond) - 1_000
        }

        # A producer is admitted after the empty-mailbox check, mid-handshake.
        retirable? = fn state ->
          :ok = Delivery.send(state.delivery, {:delta, "late"})
          true
        end

        result = CoalescerIngress.retire_check(state, registry, :surface, retirable?)
        send(test, {:result, delivery, result, Registry.lookup(registry, :surface)})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:result, old, {:keep, state, [{:delta, "late"}]},
                    [{_pid, %{delivery: current, retiring: false}}]}

    assert current == state.delivery
    assert Delivery.closed?(old)
    refute Delivery.closed?(current)
    send(owner, :done)
  end

  @tag timeout: 300_000
  test "500 sequential runs in one conversation leave a constant footprint", ctx do
    :persistent_term.erase({Dispatcher, :test_pid})
    baseline = footprint()

    samples =
      for batch <- 1..5 do
        for n <- 1..100, do: run_once(ctx.session_key, "#{batch}-#{n}")

        retired? = eventually(fn -> conversation_coalescers(ctx.session_key) == [] end)
        {batch * 100, retired?, footprint()}
      end

    if System.get_env("COALESCER_SOAK_REPORT"),
      do: IO.puts("baseline=#{inspect(baseline)}\nsamples=#{inspect(samples)}")

    for {runs, retired?, sample} <- samples do
      assert retired?,
             "coalescers still alive after #{runs} runs: #{inspect(sample)} (baseline #{inspect(baseline)})"

      assert sample.children <= baseline.children
      assert sample.registered <= baseline.registered
    end
  end

  defp run_once(session_key, label) do
    run_id = "lifecycle-#{label}-#{System.unique_integer([:positive])}"
    state = run_state(session_key, run_id)

    :ok =
      SurfaceManager.ingest_answer_delta(state, %{seq: 1, text: String.duplicate("answer ", 40)})

    state = %{state | saw_delta: true}

    for action <- [
          action_event("tool-#{label}", "tool", "read file", %{args: %{path: "lib/a.ex"}}),
          action_event("task-#{label}", "subagent", "task: review", %{
            name: "task",
            args: %{prompt: String.duplicate("context ", 200)}
          })
        ],
        reduce: state do
      state ->
        {state, surface, _capture?} = SurfaceManager.prepare_status_action(state, action)
        :ok = SurfaceManager.ingest_status_action(state, action, surface)
        state
    end
    |> then(fn state ->
      completed = completed_event(state, "final answer #{label}")
      :ok = SurfaceManager.finalize_status(state, completed)
      :ok = SurfaceManager.finalize_answer(state, completed, %{})
    end)
  end

  defp run_state(session_key, run_id) do
    %{
      run_id: run_id,
      session_key: session_key,
      saw_delta: false,
      execution_request: %LemonCore.ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        prompt: "lifecycle",
        meta: %{}
      },
      task_status_surfaces: %{},
      task_status_refs: %{}
    }
  end

  defp action_event(id, kind, title, detail) do
    %{
      engine: "lemon",
      phase: :started,
      action: %{id: id, kind: kind, title: title, detail: detail}
    }
  end

  defp start_task_subscriber(run_id, surface) do
    test = self()
    child_run_id = "child-#{System.unique_integer([:positive])}"

    subscriber =
      spawn(fn ->
        {:ok, _} =
          Registry.register(LemonRouter.AsyncTaskSurfaceRegistry, child_run_id, %{
            child_run_id: child_run_id,
            parent_run_id: run_id,
            surface: surface
          })

        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^subscriber}
    subscriber
  end

  defp completed_event(state, answer) do
    Event.new(:run_completed, %{completed: %{ok: true, answer: answer}}, %{
      run_id: state.run_id,
      session_key: state.session_key
    })
  end

  defp start_run_owner(run_id) do
    test = self()

    owner =
      spawn(fn ->
        {:ok, _} = Registry.register(LemonRouter.RunRegistry, run_id, %{})
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^owner}
    owner
  end

  defp conversation_coalescers(session_key) do
    answer =
      Registry.select(LemonRouter.CoalescerRegistry, [
        {{{:"$1", :_}, :"$2", :_}, [{:==, :"$1", session_key}], [:"$2"]}
      ])

    status =
      Registry.select(LemonRouter.ToolStatusRegistry, [
        {{{:"$1", :_}, :"$2", :_}, [{:==, :"$1", session_key}], [:"$2"]},
        {{{:"$1", :_, :_}, :"$2", :_}, [{:==, :"$1", session_key}], [:"$2"]}
      ])

    Enum.filter(answer ++ status, &Process.alive?/1)
  end

  defp footprint do
    children = Enum.flat_map(@supervisors, &supervisor_children/1)

    %{
      children: length(children),
      registered: Enum.sum(Enum.map(@registries, &Registry.count/1)),
      memory_bytes:
        Enum.sum(
          Enum.map(children, fn pid ->
            case Process.info(pid, :memory) do
              {:memory, bytes} -> bytes
              nil -> 0
            end
          end)
        )
    }
  end

  defp supervisor_children(supervisor) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor), is_pid(pid), do: pid
  end

  defp eventually(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:lemon_router, key, value)
  defp restore(key, :error), do: Application.delete_env(:lemon_router, key)
end
