defmodule CodingAgent.ParallelTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Parallel
  alias CodingAgent.Parallel.Semaphore

  import CodingAgent.AsyncHelpers

  defp await_waiters(sem, count) do
    assert_eventually(fn -> :queue.len(:sys.get_state(sem).waiters) == count end,
      message: "expected #{count} queued waiters"
    )
  end

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

      # Wait until task1 is queued so the ordering is deterministic
      await_waiters(sem, 1)

      task2 =
        Task.async(fn ->
          Semaphore.acquire(sem)
          send(test_pid, {:acquired, 2})
          Semaphore.release(sem)
          2
        end)

      # Neither should have acquired yet
      await_waiters(sem, 2)
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
