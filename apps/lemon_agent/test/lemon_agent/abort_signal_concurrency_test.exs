defmodule LemonAgent.AbortSignalConcurrencyTest do
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal

  @registry LemonAgent.AbortSignal.Registry

  test "abort wakes every subscribed waiter without receive timeouts or polling" do
    signal = AbortSignal.new()
    parent = self()

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          AbortSignal.subscribe(signal)
          refute AbortSignal.aborted?(signal)
          send(parent, {:waiting, self()})

          receive do
            {:lemon_abort, ^signal, :abort} ->
              assert AbortSignal.aborted?(signal)
              AbortSignal.unsubscribe(signal)
              :awakened
          end
        end)
      end

    for %{pid: pid} <- tasks, do: assert_receive({:waiting, ^pid}, 1_000)
    assert :ok = AbortSignal.abort(signal)
    for task <- tasks, do: assert(Task.await(task) == :awakened)
  end

  test "subscribe before check closes both sides of the check-to-wait race" do
    for phase <- [:before_subscribe, :before_check, :after_check] do
      signal = AbortSignal.new()
      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:before_subscribe, self()})

          receive do
            :subscribe -> :ok
          end

          AbortSignal.subscribe(signal)
          send(parent, {:before_check, self()})

          receive do
            :check -> :ok
          end

          result =
            if AbortSignal.aborted?(signal) do
              :level
            else
              send(parent, {:after_check, self()})

              receive do
                {:lemon_abort, ^signal, :abort} -> :message
              end
            end

          AbortSignal.unsubscribe(signal)
          result
        end)

      pid = task.pid
      assert_receive {:before_subscribe, ^pid}, 1_000
      if phase == :before_subscribe, do: AbortSignal.abort(signal)
      send(pid, :subscribe)
      assert_receive {:before_check, ^pid}, 1_000
      if phase == :before_check, do: AbortSignal.abort(signal)
      send(pid, :check)

      if phase == :after_check do
        assert_receive {:after_check, ^pid}, 1_000
        AbortSignal.abort(signal)
      end

      expected = if phase == :after_check, do: :message, else: :level
      assert Task.await(task) == expected
    end
  end

  test "killing a subscription owner removes Registry entries without resetting the signal" do
    signal = AbortSignal.new()
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        AbortSignal.subscribe(signal)
        send(parent, {:subscribed, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:subscribed, ^pid}, 1_000
    assert Registry.lookup(@registry, signal) == [{pid, nil}]
    AbortSignal.abort(signal)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    # Drain partition mailboxes after the owner's exit, not a timed sleep.
    for {_, partition, _, _} <- Supervisor.which_children(@registry) do
      :sys.get_state(partition)
    end

    assert Registry.lookup(@registry, signal) == []
    assert AbortSignal.aborted?(signal)
  end

  test "concurrent aborters publish a level visible to later readers" do
    signal = AbortSignal.new()
    parent = self()

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :abort -> AbortSignal.abort(signal)
          end
        end)
      end

    for %{pid: pid} <- tasks, do: assert_receive({:ready, ^pid}, 1_000)
    for %{pid: pid} <- tasks, do: send(pid, :abort)
    for task <- tasks, do: assert(Task.await(task) == :ok)
    readers = for _ <- 1..32, do: Task.async(fn -> AbortSignal.aborted?(signal) end)
    for reader <- readers, do: assert(Task.await(reader))
  end
end
