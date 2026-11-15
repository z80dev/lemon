defmodule CodingAgent.MutationLockBoundedTest do
  use ExUnit.Case, async: false

  alias CodingAgent.MutationLock

  setup do
    if Process.whereis(MutationLock) == nil, do: start_supervised!(MutationLock)
    :ok
  end

  test "dead queued waiter is removed on DOWN while holder remains" do
    key = {:bounded_test, make_ref()}
    parent = self()

    MutationLock.with_lock(key, fn ->
      waiter =
        spawn(fn ->
          request = make_ref()
          deadline = System.monotonic_time(:millisecond) + 30_000
          :gen_server.send_request(MutationLock, {:acquire, key, self(), request, deadline})
          # This owner round trip is ordered after this process's acquire request.
          state = :sys.get_state(MutationLock)
          send(parent, {:queued, self(), state.locks[key].waiters})

          receive do
            :finish -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(waiter), do: Process.exit(waiter, :kill) end)

      assert_receive {:queued, ^waiter, queue}
      assert :queue.len(queue) == 1
      [entry] = :queue.to_list(queue)
      monitor = Process.monitor(waiter)
      Process.exit(waiter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}
      # Inject the actual monitored event before a same-sender owner barrier;
      # the VM's duplicate DOWN is harmless and must not release the holder.
      send(MutationLock, {:DOWN, entry.ref, :process, waiter, :killed})
      state = :sys.get_state(MutationLock)
      assert :queue.is_empty(state.locks[key].waiters)
      assert state.locks[key].holder == self()
      refute Map.has_key?(state.monitors, entry.ref)
    end)
  end

  test "bounded acquire returns error and never executes callback" do
    key = {:bounded_test, make_ref()}
    parent = self()

    MutationLock.with_lock(key, fn ->
      task =
        Task.async(fn ->
          MutationLock.with_lock(key, fn -> send(parent, :unexpected_callback) end, 50)
        end)

      assert Task.await(task) == {:error, :lock_timeout}
      assert :queue.is_empty(:sys.get_state(MutationLock).locks[key].waiters)
    end)

    assert MutationLock.with_lock(key, fn -> :recovered end) == :recovered
    refute_receive :unexpected_callback
  end

  test "reentrant locks and sorted multi-key acquisition preserve ownership" do
    first = {:bounded_test, make_ref()}
    second = {:bounded_test, make_ref()}

    assert MutationLock.with_locks([second, first, second], fn ->
             assert Enum.sort(MutationLock.held()) == Enum.sort([first, second])

             MutationLock.with_lock(first, fn ->
               assert :sys.get_state(MutationLock).locks[first].count == 2
               :nested
             end)
           end) == :nested

    assert MutationLock.held() == []
    state = :sys.get_state(MutationLock)
    refute Map.has_key?(state.locks, first)
    refute Map.has_key?(state.locks, second)
  end

  test "multi-key timeout releases keys already acquired" do
    keys = Enum.sort([{:bounded_test, make_ref()}, {:bounded_test, make_ref()}])
    [first, second] = keys

    MutationLock.with_lock(second, fn ->
      task =
        Task.async(fn ->
          result = MutationLock.with_locks(keys, fn -> flunk("locked") end, 50)
          :sys.get_state(MutationLock)
          result
        end)

      assert Task.await(task) == {:error, :lock_timeout}
      refute Map.has_key?(:sys.get_state(MutationLock).locks, first)
    end)
  end
end
