defmodule CodingAgent.ParallelTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Parallel
  alias CodingAgent.Parallel.Semaphore

  describe "Semaphore" do
    test "acquire succeeds immediately when slots are available" do
      {:ok, sem} = Semaphore.start_link(2)

      assert :ok = Semaphore.acquire(sem)
      assert :ok = Semaphore.acquire(sem)

      GenServer.stop(sem)
    end

    test "available returns remaining slots" do
      {:ok, sem} = Semaphore.start_link(3)

      assert Semaphore.available(sem) == 3
      Semaphore.acquire(sem)
      assert Semaphore.available(sem) == 2
      Semaphore.acquire(sem)
      assert Semaphore.available(sem) == 1
      Semaphore.acquire(sem)
      assert Semaphore.available(sem) == 0

      GenServer.stop(sem)
    end

    test "release frees a slot" do
      {:ok, sem} = Semaphore.start_link(1)

      Semaphore.acquire(sem)
      assert Semaphore.available(sem) == 0

      Semaphore.release(sem)
      # Give the cast time to process
      Process.sleep(10)
      assert Semaphore.available(sem) == 1

      GenServer.stop(sem)
    end

    test "acquire blocks when no slots available and unblocks on release" do
      {:ok, sem} = Semaphore.start_link(1)

      # Take the only slot
      Semaphore.acquire(sem)

      # Spawn a task that tries to acquire - should block
      test_pid = self()

      task =
        Task.async(fn ->
          send(test_pid, :waiting)
          Semaphore.acquire(sem)
          send(test_pid, :acquired)
          :ok
        end)

      # Wait for the task to start waiting
      assert_receive :waiting, 1000

      # The task should NOT have acquired yet
      refute_receive :acquired, 50

      # Release the slot
      Semaphore.release(sem)

      # Now the task should acquire
      assert_receive :acquired, 1000

      Task.await(task)
      GenServer.stop(sem)
    end

    test "multiple waiters are served in FIFO order" do
      {:ok, sem} = Semaphore.start_link(1)
      Semaphore.acquire(sem)

      test_pid = self()

      # Spawn two waiting tasks
      task1 =
        Task.async(fn ->
          Semaphore.acquire(sem)
          send(test_pid, {:acquired, 1})
          Process.sleep(10)
          Semaphore.release(sem)
          1
        end)

      # Small delay to ensure ordering
      Process.sleep(10)

      task2 =
        Task.async(fn ->
          Semaphore.acquire(sem)
          send(test_pid, {:acquired, 2})
          Semaphore.release(sem)
          2
        end)

      # Neither should have acquired yet
      refute_receive {:acquired, _}, 50

      # Release - task1 should get the slot first
      Semaphore.release(sem)

      assert_receive {:acquired, 1}, 1000
      assert_receive {:acquired, 2}, 1000

      assert Task.await(task1) == 1
      assert Task.await(task2) == 2

      GenServer.stop(sem)
    end

    test "start_link with keyword opts and name" do
      {:ok, sem} = Semaphore.start_link(max: 2, name: :test_named_semaphore)

      assert :ok = Semaphore.acquire(:test_named_semaphore)
      assert Semaphore.available(:test_named_semaphore) == 1

      GenServer.stop(sem)
    end

    test "release does not go below zero" do
      {:ok, sem} = Semaphore.start_link(2)

      # Release without prior acquire
      Semaphore.release(sem)
      Process.sleep(10)

      # Available should still be 2 (not 3)
      assert Semaphore.available(sem) == 2

      GenServer.stop(sem)
    end
  end

  describe "map_with_concurrency_limit/4" do
    test "returns results in same order as input" do
      results = Parallel.map_with_concurrency_limit([3, 1, 2], 2, &(&1 * 10))
      assert results == [30, 10, 20]
    end

    test "handles empty list" do
      results = Parallel.map_with_concurrency_limit([], 2, &(&1 * 10))
      assert results == []
    end

    test "handles single item" do
      results = Parallel.map_with_concurrency_limit([42], 1, &(&1 + 1))
      assert results == [43]
    end

    test "limits concurrency to max_concurrency" do
      # Use an agent to track the max concurrent count
      {:ok, counter} = Agent.start_link(fn -> %{current: 0, max_seen: 0} end)

      Parallel.map_with_concurrency_limit(1..10, 3, fn item ->
        Agent.update(counter, fn state ->
          current = state.current + 1
          %{current: current, max_seen: max(state.max_seen, current)}
        end)

        # Simulate work
        Process.sleep(50)

        Agent.update(counter, fn state ->
          %{state | current: state.current - 1}
        end)

        item * 2
      end)

      %{max_seen: max_seen} = Agent.get(counter, & &1)
      Agent.stop(counter)

      # Max concurrent should not exceed our limit of 3
      assert max_seen <= 3
      # But should be more than 1 (parallelism is actually happening)
      assert max_seen > 1
    end

    test "all items are processed even with concurrency limit" do
      results = Parallel.map_with_concurrency_limit(1..20, 4, fn item ->
        Process.sleep(10)
        item
      end)

      assert results == Enum.to_list(1..20)
    end

    test "propagates function errors" do
      Process.flag(:trap_exit, true)

      assert catch_exit(
               Parallel.map_with_concurrency_limit([1, 2, 3], 2, fn
                 2 -> raise "boom"
                 x -> x
               end)
             )
    end

    test "works with max_concurrency of 1 (sequential)" do
      {:ok, counter} = Agent.start_link(fn -> %{current: 0, max_seen: 0} end)

      results =
        Parallel.map_with_concurrency_limit(1..5, 1, fn item ->
          Agent.update(counter, fn state ->
            current = state.current + 1
            %{current: current, max_seen: max(state.max_seen, current)}
          end)

          Process.sleep(10)

          Agent.update(counter, fn state ->
            %{state | current: state.current - 1}
          end)

          item
        end)

      %{max_seen: max_seen} = Agent.get(counter, & &1)
      Agent.stop(counter)

      assert results == [1, 2, 3, 4, 5]
      assert max_seen == 1
    end

    test "works with max_concurrency greater than item count" do
      results = Parallel.map_with_concurrency_limit([1, 2, 3], 100, &(&1 * 2))
      assert results == [2, 4, 6]
    end

    test "accepts task_supervisor option" do
      {:ok, sup} = Task.Supervisor.start_link()

      results =
        Parallel.map_with_concurrency_limit([1, 2, 3], 2, &(&1 + 1), task_supervisor: sup)

      assert results == [2, 3, 4]

      Supervisor.stop(sup)
    end
  end

  describe "default_max_concurrency/0" do
    test "returns a positive integer" do
      max = Parallel.default_max_concurrency()
      assert is_integer(max)
      assert max > 0
    end

    test "matches System.schedulers_online" do
      assert Parallel.default_max_concurrency() == System.schedulers_online()
    end
  end
end
