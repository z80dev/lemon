defmodule CodingAgent.AbortWaitersTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{JoinAwait, TaskRuntime, TaskRuntimeHelpers, TaskStore}
  alias LemonAgent.AbortSignal

  test "an idle task owner schedules no timer" do
    id = TaskStore.new_task(%{prompt: "idle owner"})
    :ok = TaskRuntimeHelpers.register(id, nil)

    on_exit(fn ->
      TaskRuntimeHelpers.stop(id)
      TaskStore.delete_task(id)
    end)

    {:status, _, _, [_, _, _, _, status]} = :sys.get_status(TaskRuntime.whereis(id))
    assert [{0, []}] = for({:data, fields} <- status, {~c"Time-outs", value} <- fields, do: value)
  end

  test "parent abort is delivered to the child's owner without a sweep" do
    signal = AbortSignal.new()
    parent_signal = AbortSignal.new()
    id = TaskStore.new_task(%{prompt: "abort regression"})

    on_exit(fn ->
      TaskRuntimeHelpers.stop(id)
      TaskStore.delete_task(id)
    end)

    assert :ok =
             TaskRuntimeHelpers.register(id, nil, signal: signal, parent_signal: parent_signal)

    owner = TaskRuntime.whereis(id)
    assert [{^owner, _}] = Registry.lookup(LemonAgent.AbortSignal.Registry, parent_signal)
    AbortSignal.abort(parent_signal)
    assert {:cancelling, %{phase: :cancelling}} = :sys.get_state(owner)
    assert AbortSignal.aborted?(signal)
  end

  test "join subscribes before checking an already aborted signal and unregisters" do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)
    assert {:error, :aborted} = JoinAwait.await([], [], :wait_all, signal)
    assert Registry.lookup(LemonAgent.AbortSignal.Registry, signal) == []
  end

  test "a waiting join receives cancellation and drops its subscription" do
    signal = AbortSignal.new()
    run_id = CodingAgent.RunGraph.new_run()
    parent = self()

    waiter =
      Task.async(fn ->
        JoinAwait.await([run_id], [], :wait_all, signal,
          interrupted?: fn ->
            send(parent, {:join_ready, self()})

            receive do
              :continue -> false
            end
          end
        )
      end)

    assert_receive {:join_ready, pid}
    assert [{^pid, _}] = Registry.lookup(LemonAgent.AbortSignal.Registry, signal)
    AbortSignal.abort(signal)
    send(pid, :continue)
    assert Task.await(waiter) == {:error, :aborted}
    assert Registry.lookup(LemonAgent.AbortSignal.Registry, signal) == []
    CodingAgent.RunGraph.finish(run_id, :test_finished)
  end
end
