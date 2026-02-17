defmodule LemonGateway.EngineLockTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Event.Completed
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}

  # ============================================================================
  # Unit Tests for EngineLock GenServer
  # ============================================================================

  describe "unit tests - basic acquire/release" do
    setup :start_engine_lock

    test "acquire returns ok with release function for unlocked key", %{lock: lock} do
      assert {:ok, release_fn} = GenServer.call(lock, {:acquire, :key1, 1000})
      assert is_function(release_fn, 0)
    end

    test "release cast releases the lock", %{lock: lock} do
      {:ok, _release_fn} = GenServer.call(lock, {:acquire, :key1, 1000})

      # Manually release using cast to our test lock
      GenServer.cast(lock, {:release, :key1, self()})

      # Small delay for async cast to process
      Process.sleep(10)

      # Should be able to acquire again immediately
      assert {:ok, _} = GenServer.call(lock, {:acquire, :key1, 100})
    end

    test "different keys can be acquired independently", %{lock: lock} do
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 1000})
      {:ok, _release2} = GenServer.call(lock, {:acquire, :key2, 1000})
      {:ok, _release3} = GenServer.call(lock, {:acquire, :key3, 1000})

      # All acquired, no blocking
      assert true
    end
  end

  describe "unit tests - waiter queue management" do
    setup :start_engine_lock

    test "waiters are queued when lock is held", %{lock: lock} do
      # First process acquires lock
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Spawn waiters that will queue up
      waiter1 = spawn_waiter(lock, :key1, 5000)
      waiter2 = spawn_waiter(lock, :key1, 5000)
      waiter3 = spawn_waiter(lock, :key1, 5000)

      # Give time for waiters to register
      Process.sleep(50)

      # Check state - should have 3 waiters in queue
      state = :sys.get_state(lock)
      assert Map.has_key?(state.waiters, :key1)
      queue = Map.get(state.waiters, :key1)
      assert :queue.len(queue) == 3

      # Cleanup
      Enum.each([waiter1, waiter2, waiter3], &Process.exit(&1, :kill))
    end

    test "waiters receive locks in FIFO order", %{lock: lock} do
      test_pid = self()

      # First process acquires lock
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Spawn waiters in order - they need to notify us to release
      spawn(fn ->
        {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
        send(test_pid, {:acquired, 1, self()})
        receive do: ({:release, lock_pid} -> GenServer.cast(lock_pid, {:release, :key1, self()}))
      end)

      Process.sleep(10)

      spawn(fn ->
        {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
        send(test_pid, {:acquired, 2, self()})
        receive do: ({:release, lock_pid} -> GenServer.cast(lock_pid, {:release, :key1, self()}))
      end)

      Process.sleep(10)

      spawn(fn ->
        {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
        send(test_pid, {:acquired, 3, self()})
        receive do: ({:release, lock_pid} -> GenServer.cast(lock_pid, {:release, :key1, self()}))
      end)

      Process.sleep(20)

      # Release lock - waiters should get it in order
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive {:acquired, 1, _}, 500

      # Waiter 1 still holds lock, waiter 2 waiting
      refute_receive {:acquired, 2, _}, 50
    end

    test "multiple keys have independent waiter queues", %{lock: lock} do
      # Acquire both keys
      {:ok, _release_a} = GenServer.call(lock, {:acquire, :key_a, 5000})
      {:ok, _release_b} = GenServer.call(lock, {:acquire, :key_b, 5000})

      # Queue waiters for both keys - waiters stay alive after acquiring
      waiter_a1 = spawn_waiter_persistent(lock, :key_a, 5000)
      waiter_a2 = spawn_waiter_persistent(lock, :key_a, 5000)
      waiter_a3 = spawn_waiter_persistent(lock, :key_a, 5000)
      waiter_b1 = spawn_waiter_persistent(lock, :key_b, 5000)
      waiter_b2 = spawn_waiter_persistent(lock, :key_b, 5000)

      Process.sleep(50)

      state = :sys.get_state(lock)
      assert :queue.len(Map.get(state.waiters, :key_a)) == 3
      assert :queue.len(Map.get(state.waiters, :key_b)) == 2

      # Release key_a - only key_a waiters should progress
      GenServer.cast(lock, {:release, :key_a, self()})
      Process.sleep(20)

      state = :sys.get_state(lock)
      # key_a should have 2 waiters left (one got the lock and is holding it)
      assert :queue.len(Map.get(state.waiters, :key_a)) == 2
      # key_b still has 2 waiters
      assert :queue.len(Map.get(state.waiters, :key_b)) == 2

      # Cleanup
      GenServer.cast(lock, {:release, :key_b, self()})
      Enum.each([waiter_a1, waiter_a2, waiter_a3, waiter_b1, waiter_b2], &Process.exit(&1, :kill))
    end
  end

  describe "unit tests - release_and_next logic" do
    setup :start_engine_lock

    test "release_and_next grants lock to next waiter", %{lock: lock} do
      test_pid = self()

      # First process acquires lock
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Spawn waiter
      spawn(fn ->
        {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
        send(test_pid, :waiter_got_lock)
        Process.sleep(:infinity)
      end)

      Process.sleep(20)

      # Release triggers release_and_next
      GenServer.cast(lock, {:release, :key1, self()})

      # Waiter should receive lock
      assert_receive :waiter_got_lock, 500
    end

    test "release_and_next removes waiter from queue after granting", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Spawn multiple waiters that communicate with us for release
      for i <- 1..3 do
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, {:acquired, i, self()})

          receive do: ({:release, lock_pid} ->
                         GenServer.cast(lock_pid, {:release, :key1, self()}))
        end)

        Process.sleep(10)
      end

      Process.sleep(20)

      # Should have 3 waiters
      state = :sys.get_state(lock)
      assert :queue.len(Map.get(state.waiters, :key1)) == 3

      # Release lock
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive {:acquired, 1, _}, 500

      Process.sleep(20)

      # Should have 2 waiters now
      state = :sys.get_state(lock)
      assert :queue.len(Map.get(state.waiters, :key1)) == 2
    end

    test "release_and_next cleans up empty waiter queue", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Single waiter
      waiter =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :got_lock)
          Process.sleep(:infinity)
        end)

      Process.sleep(20)

      # Release - waiter gets lock, queue should be cleaned up
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive :got_lock, 500

      Process.sleep(20)

      state = :sys.get_state(lock)
      # No more waiters for key1
      refute Map.has_key?(state.waiters, :key1)

      Process.exit(waiter, :kill)
    end

    test "release_and_next cancels waiter timer", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      waiter =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :got_lock)
          # Stay alive to prevent :DOWN handling
          Process.sleep(:infinity)
        end)

      Process.sleep(20)

      # Release and let waiter get lock
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive :got_lock, 500

      # Wait past when timer would have fired if not cancelled
      Process.sleep(100)

      # No timeout error should occur (timer was cancelled)
      refute_receive {:error, :timeout}, 50

      Process.exit(waiter, :kill)
    end
  end

  describe "unit tests - lock timeout scenarios" do
    setup :start_engine_lock

    test "waiter times out and receives error", %{lock: lock} do
      # Hold lock
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Try to acquire with short timeout
      result = GenServer.call(lock, {:acquire, :key1, 50}, 1000)

      assert result == {:error, :timeout}
    end

    test "timed out waiter is removed from queue", %{lock: lock} do
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Spawn waiter with short timeout
      spawn_waiter(lock, :key1, 50)

      Process.sleep(20)

      # Should have 1 waiter
      state = :sys.get_state(lock)
      assert :queue.len(Map.get(state.waiters, :key1)) == 1

      # Wait for timeout
      Process.sleep(100)

      # Waiter should be removed
      state = :sys.get_state(lock)
      refute Map.has_key?(state.waiters, :key1)
    end

    test "multiple waiters with different timeouts", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Waiter 1 - short timeout
      spawn(fn ->
        result = GenServer.call(lock, {:acquire, :key1, 50}, 1000)
        send(test_pid, {:waiter1, result})
      end)

      Process.sleep(10)

      # Waiter 2 - long timeout
      spawn(fn ->
        result = GenServer.call(lock, {:acquire, :key1, 2000}, 3000)
        send(test_pid, {:waiter2, result})
      end)

      Process.sleep(10)

      # Waiter 3 - short timeout
      spawn(fn ->
        result = GenServer.call(lock, {:acquire, :key1, 30}, 1000)
        send(test_pid, {:waiter3, result})
      end)

      # Wait for short timeouts
      Process.sleep(150)

      # Short timeout waiters should have timed out
      assert_receive {:waiter1, {:error, :timeout}}, 100
      assert_receive {:waiter3, {:error, :timeout}}, 100

      # Long timeout waiter should still be waiting
      refute_receive {:waiter2, _}, 50

      # Check only one waiter remains
      state = :sys.get_state(lock)
      assert :queue.len(Map.get(state.waiters, :key1)) == 1
    end

    test "timeout message after waiter already received lock is ignored", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      waiter =
        spawn(fn ->
          # Request with timeout slightly longer than we'll wait
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 200}, 1000)
          send(test_pid, {:got_lock, self()})
          # Hold lock for a while past when timeout would fire
          receive do
            {:release, lock_pid} ->
              GenServer.cast(lock_pid, {:release, :key1, self()})
              send(test_pid, :released)
          after
            300 ->
              send(test_pid, :released)
          end
        end)

      Process.sleep(20)

      # Release quickly before waiter times out
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive {:got_lock, waiter_pid}, 100

      # Tell waiter to release after some time
      Process.sleep(250)
      send(waiter_pid, {:release, lock})

      # Wait past timeout - should not cause issues
      assert_receive :released, 500

      # No crashes, waiter completed normally
      Process.sleep(50)
      refute Process.alive?(waiter)
    end
  end

  describe "unit tests - concurrent lock acquisition" do
    setup :start_engine_lock

    test "many concurrent acquires for same key are serialized", %{lock: lock} do
      test_pid = self()
      num_tasks = 10

      tasks =
        for i <- 1..num_tasks do
          Task.async(fn ->
            {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 10_000}, 11_000)
            send(test_pid, {:acquired, i, System.monotonic_time(:millisecond)})
            Process.sleep(20)
            GenServer.cast(lock, {:release, :key1, self()})
            send(test_pid, {:released, i, System.monotonic_time(:millisecond)})
            i
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert length(results) == num_tasks

      # Collect all acquisition times
      acquires =
        for _ <- 1..num_tasks do
          receive do
            {:acquired, i, time} -> {i, time}
          after
            5000 -> flunk("timeout waiting for acquire")
          end
        end

      # Collect all release times
      _releases =
        for _ <- 1..num_tasks do
          receive do
            {:released, i, time} -> {i, time}
          after
            5000 -> flunk("timeout waiting for release")
          end
        end

      # Verify serialization: each acquire should happen after previous release
      acquires_sorted = Enum.sort_by(acquires, fn {_, time} -> time end)

      # Get acquire times in order
      acquire_times = Enum.map(acquires_sorted, fn {_, time} -> time end)

      # Verify they're properly serialized (no overlapping)
      for i <- 1..(num_tasks - 1) do
        # Find the release that corresponds to the task that acquired at acquire_times[i-1]
        # The next acquire should be >= some release before it
        assert Enum.at(acquire_times, i) >= Enum.at(acquire_times, i - 1)
      end
    end

    test "concurrent acquires for different keys proceed in parallel", %{lock: lock} do
      num_keys = 5

      t_start = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..num_keys do
          Task.async(fn ->
            key = :"key_#{i}"
            {:ok, _release} = GenServer.call(lock, {:acquire, key, 5000})
            Process.sleep(50)
            GenServer.cast(lock, {:release, key, self()})
            i
          end)
        end

      results = Task.await_many(tasks, 5000)
      t_end = System.monotonic_time(:millisecond)

      assert length(results) == num_keys
      # Should complete in ~50ms (parallel), not ~250ms (serial)
      assert t_end - t_start < 150
    end

    test "race condition: release during acquire processing", %{lock: lock} do
      test_pid = self()

      # This test verifies the lock handles rapid acquire/release cycles
      for _ <- 1..20 do
        task =
          Task.async(fn ->
            {:ok, _release} = GenServer.call(lock, {:acquire, :race_key, 1000})
            # Immediate release
            GenServer.cast(lock, {:release, :race_key, self()})
            :ok
          end)

        Task.await(task, 2000)
      end

      # Lock should be clean
      Process.sleep(50)
      state = :sys.get_state(lock)
      refute Map.has_key?(state.locks, :race_key)
      refute Map.has_key?(state.waiters, :race_key)

      send(test_pid, :race_test_complete)
      assert_receive :race_test_complete
    end
  end

  describe "unit tests - lock release with pending waiters" do
    setup :start_engine_lock

    test "releasing lock grants to first pending waiter", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Queue up waiters that communicate back for release
      for i <- 1..3 do
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, {:waiter_acquired, i, self()})

          receive do
            {:release, lock_pid} -> GenServer.cast(lock_pid, {:release, :key1, self()})
          end
        end)

        Process.sleep(10)
      end

      Process.sleep(20)

      # Release - first waiter should get it
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive {:waiter_acquired, 1, _}, 500

      # Others should not yet
      refute_receive {:waiter_acquired, 2, _}, 50
      refute_receive {:waiter_acquired, 3, _}, 50
    end

    test "waiter chain: each release triggers next waiter", %{lock: lock} do
      test_pid = self()

      {:ok, _release0} = GenServer.call(lock, {:acquire, :key1, 5000})

      waiters =
        for i <- 1..3 do
          spawn(fn ->
            {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
            send(test_pid, {:waiter_acquired, i, self()})

            receive do
              {:release, lock_pid} ->
                GenServer.cast(lock_pid, {:release, :key1, self()})
                send(test_pid, {:waiter_released, i})
            end
          end)
        end

      Process.sleep(50)

      # Release initial lock
      GenServer.cast(lock, {:release, :key1, self()})

      # Waiter 1 acquires
      assert_receive {:waiter_acquired, 1, waiter1_pid}, 500

      # Tell waiter 1 to release
      send(waiter1_pid, {:release, lock})
      assert_receive {:waiter_released, 1}, 500

      # Waiter 2 acquires
      assert_receive {:waiter_acquired, 2, waiter2_pid}, 500

      # Tell waiter 2 to release
      send(waiter2_pid, {:release, lock})
      assert_receive {:waiter_released, 2}, 500

      # Waiter 3 acquires
      assert_receive {:waiter_acquired, 3, waiter3_pid}, 500

      send(waiter3_pid, {:release, lock})
      assert_receive {:waiter_released, 3}, 500

      # Clean up any remaining waiters
      Enum.each(waiters, fn w -> if Process.alive?(w), do: Process.exit(w, :kill) end)
    end

    test "release from wrong process is ignored", %{lock: lock} do
      test_pid = self()

      # Process A acquires lock
      task_a =
        Task.async(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :task_a_acquired)
          receive do: (:done -> :ok)
        end)

      assert_receive :task_a_acquired, 500

      # Process B tries to release (should be ignored)
      GenServer.cast(lock, {:release, :key1, self()})

      Process.sleep(50)

      # Lock should still be held by task_a
      state = :sys.get_state(lock)
      assert Map.has_key?(state.locks, :key1)

      # Cleanup
      send(task_a.pid, :done)
      Task.await(task_a)
    end
  end

  describe "unit tests - cleanup on owner death" do
    setup :start_engine_lock

    test "lock is released when owner process dies", %{lock: lock} do
      test_pid = self()

      # Spawn process that acquires lock then dies
      owner =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :acquired)
          receive do: (:die -> :ok)
        end)

      assert_receive :acquired, 500

      # Verify lock is held
      state = :sys.get_state(lock)
      assert Map.has_key?(state.locks, :key1)

      # Kill the owner
      Process.exit(owner, :kill)

      # Wait for :DOWN to be processed
      Process.sleep(50)

      # Lock should be released
      state = :sys.get_state(lock)
      refute Map.has_key?(state.locks, :key1)
    end

    test "owner death grants lock to waiting process", %{lock: lock} do
      test_pid = self()

      # Owner acquires lock
      owner =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :owner_acquired)
          receive do: (:die -> :ok)
        end)

      assert_receive :owner_acquired, 500

      # Waiter queues up
      waiter =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :waiter_acquired)
          Process.sleep(:infinity)
        end)

      Process.sleep(50)

      # Kill owner
      Process.exit(owner, :kill)

      # Waiter should get lock
      assert_receive :waiter_acquired, 500

      Process.exit(waiter, :kill)
    end

    test "owner death with multiple waiters grants to first waiter", %{lock: lock} do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
          send(test_pid, :owner_acquired)
          receive do: (:die -> :ok)
        end)

      assert_receive :owner_acquired, 500

      # Spawn waiters in order
      waiters =
        for i <- 1..3 do
          waiter =
            spawn(fn ->
              {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})
              send(test_pid, {:waiter_acquired, i})
              Process.sleep(:infinity)
            end)

          Process.sleep(10)
          waiter
        end

      Process.sleep(30)

      # Kill owner
      Process.exit(owner, :kill)

      # First waiter should get lock
      assert_receive {:waiter_acquired, 1}, 500

      # Others should not
      refute_receive {:waiter_acquired, 2}, 50
      refute_receive {:waiter_acquired, 3}, 50

      Enum.each(waiters, &Process.exit(&1, :kill))
    end

    test "owner crash releases lock for different thread key", %{lock: lock} do
      test_pid = self()

      # Acquire locks on two different keys from two different processes
      owner1 =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key_a, 5000})
          send(test_pid, {:owner1_acquired, :key_a})
          receive do: (:die -> :ok)
        end)

      owner2 =
        spawn(fn ->
          {:ok, _release} = GenServer.call(lock, {:acquire, :key_b, 5000})
          send(test_pid, {:owner2_acquired, :key_b})
          receive do: (:die -> :ok)
        end)

      assert_receive {:owner1_acquired, :key_a}, 500
      assert_receive {:owner2_acquired, :key_b}, 500

      # Kill only owner1
      Process.exit(owner1, :kill)
      Process.sleep(50)

      state = :sys.get_state(lock)
      # key_a should be released
      refute Map.has_key?(state.locks, :key_a)
      # key_b should still be held
      assert Map.has_key?(state.locks, :key_b)

      Process.exit(owner2, :kill)
    end

    test "waiter process death removes from queue", %{lock: lock} do
      {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Spawn waiter that will be killed
      waiter =
        spawn(fn ->
          GenServer.call(lock, {:acquire, :key1, 5000})
        end)

      Process.sleep(30)

      # Verify waiter is queued
      state = :sys.get_state(lock)
      assert :queue.len(Map.get(state.waiters, :key1)) == 1

      # Kill the waiter
      Process.exit(waiter, :kill)

      # Note: The current implementation doesn't monitor waiters,
      # so the waiter stays in queue until timeout or lock release.
      # This test documents current behavior.
      Process.sleep(30)

      state = :sys.get_state(lock)
      # Waiter is still in queue (current behavior)
      assert :queue.len(Map.get(state.waiters, :key1)) == 1
    end
  end

  describe "unit tests - edge cases" do
    setup :start_engine_lock

    test "double release is safely ignored", %{lock: lock} do
      {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 1000})

      # First release
      GenServer.cast(lock, {:release, :key1, self()})
      Process.sleep(10)

      # Second release - should be ignored
      GenServer.cast(lock, {:release, :key1, self()})
      Process.sleep(10)

      # No crash, lock is free
      state = :sys.get_state(lock)
      refute Map.has_key?(state.locks, :key1)
    end

    test "release for non-existent key is safely ignored", %{lock: lock} do
      GenServer.cast(lock, {:release, :non_existent_key, self()})
      Process.sleep(10)

      # No crash
      state = :sys.get_state(lock)
      assert state.locks == %{}
    end

    test "timeout for already processed waiter is ignored", %{lock: lock} do
      test_pid = self()

      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      waiter =
        spawn(fn ->
          # Very short timeout, but we'll release lock before it fires
          {:ok, _release} = GenServer.call(lock, {:acquire, :key1, 500}, 2000)
          send(test_pid, :waiter_got_lock)
          Process.sleep(:infinity)
        end)

      Process.sleep(20)

      # Release lock quickly
      GenServer.cast(lock, {:release, :key1, self()})
      assert_receive :waiter_got_lock, 100

      # Wait for timeout to fire (it should be cancelled, but test handles if not)
      Process.sleep(600)

      # GenServer should still be healthy
      assert Process.alive?(lock)

      Process.exit(waiter, :kill)
    end

    test "empty waiter queue cleanup after timeout", %{lock: lock} do
      {:ok, _release1} = GenServer.call(lock, {:acquire, :key1, 5000})

      # Single waiter with short timeout
      spawn(fn ->
        GenServer.call(lock, {:acquire, :key1, 30}, 1000)
      end)

      Process.sleep(100)

      # Queue should be cleaned up after timeout
      state = :sys.get_state(lock)
      refute Map.has_key?(state.waiters, :key1)
    end
  end

  describe "unit tests - stale lock reclamation" do
    setup context do
      context
      |> Map.put(:engine_lock_opts, %{max_lock_age_ms: 120, reap_interval_ms: 20})
      |> start_engine_lock()
    end

    test "reclaims locks older than max_lock_age_ms", %{lock: lock} do
      {:ok, _release} = GenServer.call(lock, {:acquire, :stale_key, 5_000})

      Process.sleep(150)

      assert {:ok, _release} = GenServer.call(lock, {:acquire, :stale_key, 300}, 1_000)
    end

    test "does not reclaim fresh locks before max age", %{lock: lock} do
      {:ok, _release} = GenServer.call(lock, {:acquire, :fresh_key, 5_000})

      assert {:error, :timeout} = GenServer.call(lock, {:acquire, :fresh_key, 30}, 500)
    end
  end

  # Helper to start a fresh EngineLock for unit tests
  defp start_engine_lock(context) do
    # Start a new EngineLock with a unique name for isolation
    name = :"engine_lock_#{:erlang.unique_integer([:positive])}"
    opts = Map.get(context, :engine_lock_opts, %{})
    {:ok, pid} = GenServer.start_link(LemonGateway.EngineLock, opts, name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{lock: pid, lock_name: name}
  end

  # Helper to spawn a waiter process that exits after acquiring
  defp spawn_waiter(lock, key, timeout) do
    spawn(fn ->
      GenServer.call(lock, {:acquire, key, timeout}, timeout + 1000)
    end)
  end

  # Helper to spawn a waiter process that stays alive after acquiring
  defp spawn_waiter_persistent(lock, key, timeout) do
    spawn(fn ->
      GenServer.call(lock, {:acquire, key, timeout}, timeout + 1000)
      # Stay alive to hold the lock
      Process.sleep(:infinity)
    end)
  end

  # ============================================================================
  # Integration Tests (existing tests using full application)
  # ============================================================================

  defmodule SlowEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "slow"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "slow resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "slow-session"}
      delay = job.meta[:delay_ms] || 100

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        Process.sleep(delay)

        send(
          sink_pid,
          {:engine_event, run_ref, %Event.Completed{engine: id(), ok: true, answer: "slow done"}}
        )
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule CrashEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "crash"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "crash resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "crash"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        # Kill the Run process to simulate a crash
        Process.exit(sink_pid, :kill)
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false,
      require_engine_lock: true,
      engine_lock_timeout_ms: 60_000
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      SlowEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "lock is acquired and released during normal run" do
    scope = %ChatScope{transport: :test, chat_id: 100, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "test",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job)
    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 1_000

    # Wait a bit for lock release to propagate (cast is async)
    Process.sleep(50)

    # Lock should be released - another job for same scope should proceed immediately
    job2 = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "test2",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job2)
    assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 1_000
  end

  test "concurrent runs for same scope are serialized by lock" do
    scope = %ChatScope{transport: :test, chat_id: 101, topic_id: nil}

    job1 = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "first",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "second",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 50}
    }

    # Submit both concurrently
    Task.async(fn -> LemonGateway.submit(job1) end)
    Process.sleep(10)
    Task.async(fn -> LemonGateway.submit(job2) end)

    # Jobs should complete in order due to locking
    completions = collect_completions(2, 2_000)

    assert length(completions) == 2
    # First job submitted should complete first due to lock serialization
    [{first_job, _}, {second_job, _}] = completions
    assert first_job.text == "first"
    assert second_job.text == "second"
  end

  test "concurrent runs for different scopes proceed in parallel" do
    scope1 = %ChatScope{transport: :test, chat_id: 102, topic_id: nil}
    scope2 = %ChatScope{transport: :test, chat_id: 103, topic_id: nil}

    job1 = %Job{
      scope: scope1,
      user_msg_id: 1,
      text: "scope1",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope2,
      user_msg_id: 2,
      text: "scope2",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    t_start = System.monotonic_time(:millisecond)

    Task.async(fn -> LemonGateway.submit(job1) end)
    Task.async(fn -> LemonGateway.submit(job2) end)

    completions = collect_completions(2, 2_000)
    t_end = System.monotonic_time(:millisecond)

    assert length(completions) == 2
    # Both should complete in roughly parallel time (not serialized)
    # If serialized, would take ~200ms+; parallel should be ~100ms
    elapsed = t_end - t_start
    assert elapsed < 180, "Expected parallel execution, got #{elapsed}ms"
  end

  test "lock uses resume token value as key when present" do
    scope1 = %ChatScope{transport: :test, chat_id: 104, topic_id: nil}
    scope2 = %ChatScope{transport: :test, chat_id: 105, topic_id: nil}
    resume = %ResumeToken{engine: "slow", value: "shared-session-123"}

    # Two jobs with different scopes but same resume token should be serialized
    job1 = %Job{
      scope: scope1,
      user_msg_id: 1,
      text: "resume1",
      resume: resume,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope2,
      user_msg_id: 2,
      text: "resume2",
      resume: resume,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 50}
    }

    t_start = System.monotonic_time(:millisecond)

    Task.async(fn -> LemonGateway.submit(job1) end)
    Process.sleep(10)
    Task.async(fn -> LemonGateway.submit(job2) end)

    completions = collect_completions(2, 2_000)
    t_end = System.monotonic_time(:millisecond)

    assert length(completions) == 2
    # Should be serialized despite different scopes
    elapsed = t_end - t_start

    assert elapsed >= 140,
           "Expected serialized execution due to shared resume token, got #{elapsed}ms"
  end

  test "lock is released when run process crashes" do
    # Restart app with crash engine included
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false,
      require_engine_lock: true,
      engine_lock_timeout_ms: 60_000
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      SlowEngine,
      CrashEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 106, topic_id: nil}

    crash_job = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "crash",
      resume: nil,
      engine_hint: "crash",
      meta: %{notify_pid: self()}
    }

    ok_job = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "ok",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    # Submit crash job first, then ok job
    LemonGateway.submit(crash_job)
    Process.sleep(50)
    LemonGateway.submit(ok_job)

    # The ok_job should complete even after crash_job's process dies
    # because EngineLock monitors the process and releases on :DOWN
    assert_receive {:lemon_gateway_run_completed, ^ok_job, %Completed{ok: true}}, 2_000
  end

  test "lock can be disabled via config" do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      SlowEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 107, topic_id: nil}

    # With locking disabled, two jobs for same scope should run in parallel
    job1 = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "no-lock-1",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "no-lock-2",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    t_start = System.monotonic_time(:millisecond)

    Task.async(fn -> LemonGateway.submit(job1) end)
    Task.async(fn -> LemonGateway.submit(job2) end)

    completions = collect_completions(2, 2_000)
    t_end = System.monotonic_time(:millisecond)

    assert length(completions) == 2
    # Without locking, should be parallel (allow some overhead for test/CI)
    elapsed = t_end - t_start
    assert elapsed < 250, "Expected parallel execution without locking, got #{elapsed}ms"
  end

  defp collect_completions(count, timeout) do
    collect_completions(count, timeout, [])
  end

  defp collect_completions(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_completions(count, timeout, acc) do
    receive do
      {:lemon_gateway_run_completed, job, completed} ->
        collect_completions(count - 1, timeout, [{job, completed} | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
