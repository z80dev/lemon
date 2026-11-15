defmodule CodingAgent.AbortWaitersTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{JoinAwait, TaskStore}
  alias CodingAgent.Tools.Task.Control
  alias LemonAgent.AbortSignal

  test "idle control does not schedule a signal sweep" do
    parent = self()

    pid =
      spawn(fn ->
        assert {:ok, %{}} = Control.init([])
        send(parent, {:initialized, self()})

        receive do
          message -> send(parent, {:unexpected_control_timer, message})
        after
          120 -> send(parent, :idle_without_timer)
        end
      end)

    assert_receive {:initialized, ^pid}
    assert_receive :idle_without_timer, 500
    refute_received {:unexpected_control_timer, _}
  end

  test "parent abort is delivered to control without a sweep" do
    {:ok, server} = GenServer.start_link(Control, [])
    signal = AbortSignal.new()
    parent_signal = AbortSignal.new()
    id = TaskStore.new_task(%{prompt: "abort regression"})

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      TaskStore.delete_task(id)
    end)

    assert :ok =
             GenServer.call(
               server,
               {:register, id, signal, parent_signal, nil, fn _ -> :ok end, nil}
             )

    assert [{^server, _}] = Registry.lookup(LemonAgent.AbortSignal.Registry, parent_signal)
    AbortSignal.abort(parent_signal)
    assert :sys.get_state(server)[id].cancelled
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
