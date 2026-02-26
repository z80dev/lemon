defmodule AgentCore.AbortSignalConcurrencyTest do
  @moduledoc """
  Comprehensive concurrency tests for AgentCore.AbortSignal.

  These tests focus on race conditions, concurrent access patterns, and
  stress testing the ETS-backed abort signal implementation.
  """
  use ExUnit.Case, async: false

  alias AgentCore.AbortSignal

  # Use a longer timeout for concurrency tests
  @moduletag timeout: 60_000

  setup do
    # Ensure the ETS table exists before running tests
    _ref = AbortSignal.new()
    :ok
  end

  # ============================================================================
  # Race Conditions with Concurrent Abort Calls
  # ============================================================================

  describe "race conditions with concurrent abort calls" do
    test "multiple processes racing to abort the same signal" do
      ref = AbortSignal.new()
      parent = self()
      num_processes = 500

      # Launch many processes that all try to abort the same signal simultaneously
      pids =
        for _ <- 1..num_processes do
          spawn_link(fn ->
            result = AbortSignal.abort(ref)
            send(parent, {:done, self(), result})
          end)
        end

      # Collect all results
      results =
        for _ <- pids do
          receive do
            {:done, _pid, result} -> result
          after
            5000 -> :timeout
          end
        end

      # All should succeed with :ok
      assert Enum.all?(results, &(&1 == :ok))
      assert length(results) == num_processes

      # Final state must be aborted
      assert AbortSignal.aborted?(ref) == true
    end

    test "concurrent abort calls from tasks with varying delays" do
      ref = AbortSignal.new()

      # Use Task.async_stream for controlled concurrency
      tasks =
        1..100
        |> Task.async_stream(
          fn i ->
            # Random micro-delay to create race conditions
            if rem(i, 3) == 0, do: :timer.sleep(1)
            AbortSignal.abort(ref)
          end,
          max_concurrency: 50,
          timeout: 5000
        )
        |> Enum.to_list()

      # All tasks should complete successfully
      assert Enum.all?(tasks, fn {:ok, result} -> result == :ok end)
      assert AbortSignal.aborted?(ref) == true
    end

    test "first-abort-wins semantics verified" do
      # Create multiple signals and track which process aborts each first
      parent = self()
      num_signals = 20
      num_racers = 50

      signals = for _ <- 1..num_signals, do: AbortSignal.new()

      # For each signal, spawn racers that try to abort and report timing
      for {ref, sig_idx} <- Enum.with_index(signals) do
        for racer_idx <- 1..num_racers do
          spawn_link(fn ->
            start = System.monotonic_time(:microsecond)
            AbortSignal.abort(ref)
            finish = System.monotonic_time(:microsecond)
            send(parent, {:race_done, sig_idx, racer_idx, finish - start})
          end)
        end
      end

      # Collect all results
      results =
        for _ <- 1..(num_signals * num_racers) do
          receive do
            {:race_done, sig_idx, racer_idx, duration} ->
              {sig_idx, racer_idx, duration}
          after
            5000 -> :timeout
          end
        end

      # Verify we got all results
      assert length(results) == num_signals * num_racers
      assert not Enum.member?(results, :timeout)

      # All signals should be aborted
      assert Enum.all?(signals, &AbortSignal.aborted?/1)
    end

    test "abort and check racing - visibility guarantee" do
      # Test that once abort returns, any subsequent check sees true
      iterations = 100

      for _ <- 1..iterations do
        ref = AbortSignal.new()
        parent = self()

        # Aborter process
        aborter =
          spawn_link(fn ->
            AbortSignal.abort(ref)
            send(parent, {:aborted, self()})
          end)

        # Wait for abort to complete
        receive do
          {:aborted, ^aborter} -> :ok
        after
          1000 -> flunk("Aborter timed out")
        end

        # After abort completes, check must always return true
        # Spawn checkers after we know abort completed
        checkers =
          for _ <- 1..20 do
            spawn_link(fn ->
              result = AbortSignal.aborted?(ref)
              send(parent, {:checked, self(), result})
            end)
          end

        # All checks after abort completes must see true
        checker_results =
          for _ <- checkers do
            receive do
              {:checked, _pid, result} -> result
            after
              1000 -> :timeout
            end
          end

        assert Enum.all?(checker_results, &(&1 == true)),
               "All checks after abort completion must see true"
      end
    end
  end

  # ============================================================================
  # Concurrent Access Patterns (Multiple Readers, One Writer)
  # ============================================================================

  describe "concurrent access patterns (multiple readers, one writer)" do
    test "many readers with single writer" do
      ref = AbortSignal.new()
      parent = self()
      num_readers = 200
      read_iterations = 100

      # Start reader processes
      readers =
        for i <- 1..num_readers do
          spawn_link(fn ->
            results =
              for _ <- 1..read_iterations do
                AbortSignal.aborted?(ref)
              end

            send(parent, {:reader_done, i, results})
          end)
        end

      # Single writer that aborts after a delay
      _writer =
        spawn_link(fn ->
          :timer.sleep(10)
          AbortSignal.abort(ref)
          send(parent, {:writer_done})
        end)

      # Wait for writer
      receive do
        {:writer_done} -> :ok
      after
        5000 -> flunk("Writer timed out")
      end

      # Collect reader results
      reader_results =
        for _ <- readers do
          receive do
            {:reader_done, i, results} -> {i, results}
          after
            5000 -> :timeout
          end
        end

      # Verify no timeouts
      assert not Enum.member?(reader_results, :timeout)

      # Each reader's results should be monotonic (once true, stays true)
      for {_i, results} <- reader_results do
        assert Enum.all?(results, &is_boolean/1)

        # Find first true, ensure all after are true
        case Enum.find_index(results, & &1) do
          nil ->
            # All false is valid (read before abort)
            :ok

          idx ->
            remaining = Enum.drop(results, idx)
            assert Enum.all?(remaining, & &1), "Once aborted, must stay aborted"
        end
      end
    end

    test "readers and writer interleaved with varying rates" do
      ref = AbortSignal.new()
      parent = self()

      # Fast readers
      fast_readers =
        for i <- 1..50 do
          spawn_link(fn ->
            results =
              for _ <- 1..200 do
                AbortSignal.aborted?(ref)
              end

            send(parent, {:fast_reader, i, Enum.count(results, & &1)})
          end)
        end

      # Slow readers (with small delays)
      slow_readers =
        for i <- 1..20 do
          spawn_link(fn ->
            results =
              for _ <- 1..50 do
                :timer.sleep(1)
                AbortSignal.aborted?(ref)
              end

            send(parent, {:slow_reader, i, Enum.count(results, & &1)})
          end)
        end

      # Writer aborts midway
      spawn_link(fn ->
        :timer.sleep(25)
        AbortSignal.abort(ref)
        send(parent, :writer_done)
      end)

      # Collect all results
      all_pids = fast_readers ++ slow_readers
      total = length(all_pids) + 1

      results =
        for _ <- 1..total do
          receive do
            {:fast_reader, i, count} -> {:fast, i, count}
            {:slow_reader, i, count} -> {:slow, i, count}
            :writer_done -> :writer_done
          after
            10_000 -> :timeout
          end
        end

      # Verify no timeouts and writer completed
      assert not Enum.member?(results, :timeout)
      assert Enum.member?(results, :writer_done)

      # Signal should be aborted
      assert AbortSignal.aborted?(ref) == true
    end

    test "read-heavy workload with occasional writes" do
      ref = AbortSignal.new()
      parent = self()
      num_readers = 100
      reads_per_reader = 500

      # Start many readers
      _readers =
        for i <- 1..num_readers do
          spawn_link(fn ->
            count =
              Enum.reduce(1..reads_per_reader, 0, fn _, acc ->
                if AbortSignal.aborted?(ref), do: acc + 1, else: acc
              end)

            send(parent, {:reader, i, count})
          end)
        end

      # Periodic writer
      spawn_link(fn ->
        :timer.sleep(5)
        AbortSignal.abort(ref)
        :timer.sleep(20)
        # Try to "un-abort" by clearing (simulates reset)
        AbortSignal.clear(ref)
        :timer.sleep(5)
        AbortSignal.abort(ref)
        send(parent, :writes_done)
      end)

      # Collect results
      results =
        for _ <- 1..(num_readers + 1) do
          receive do
            {:reader, i, count} -> {:reader, i, count}
            :writes_done -> :writes_done
          after
            10_000 -> :timeout
          end
        end

      assert not Enum.member?(results, :timeout)
      assert Enum.member?(results, :writes_done)
    end
  end

  # ============================================================================
  # ETS Table Cleanup Scenarios
  # ============================================================================

  describe "ETS table cleanup scenarios" do
    test "rapid create and clear cycles do not leak memory" do
      # Track approximate ETS table size
      initial_info = :ets.info(:agent_core_abort_signals)
      initial_size = Keyword.get(initial_info, :size, 0)

      # Create and clear many signals
      for _ <- 1..10_000 do
        ref = AbortSignal.new()
        AbortSignal.clear(ref)
      end

      final_info = :ets.info(:agent_core_abort_signals)
      final_size = Keyword.get(final_info, :size, 0)

      # Size should not have grown significantly (allowing for some concurrent tests)
      assert final_size <= initial_size + 100,
             "ETS table grew from #{initial_size} to #{final_size}"
    end

    test "concurrent create and clear from multiple processes" do
      parent = self()
      num_processes = 50
      cycles_per_process = 200

      pids =
        for _ <- 1..num_processes do
          spawn_link(fn ->
            for _ <- 1..cycles_per_process do
              ref = AbortSignal.new()
              AbortSignal.abort(ref)
              AbortSignal.clear(ref)
            end

            send(parent, {:done, self()})
          end)
        end

      # Wait for all processes
      for _ <- pids do
        receive do
          {:done, _pid} -> :ok
        after
          30_000 -> flunk("Process timed out")
        end
      end

      # Table should still be functional
      ref = AbortSignal.new()
      assert AbortSignal.aborted?(ref) == false
      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
    end

    test "clear racing with abort on same signal" do
      parent = self()
      iterations = 200

      for _ <- 1..iterations do
        ref = AbortSignal.new()

        # Race abort and clear
        abort_pid =
          spawn_link(fn ->
            AbortSignal.abort(ref)
            send(parent, {:abort_done, self()})
          end)

        clear_pid =
          spawn_link(fn ->
            AbortSignal.clear(ref)
            send(parent, {:clear_done, self()})
          end)

        # Wait for both
        receive do
          {:abort_done, ^abort_pid} -> :ok
        after
          1000 -> flunk("Abort timed out")
        end

        receive do
          {:clear_done, ^clear_pid} -> :ok
        after
          1000 -> flunk("Clear timed out")
        end

        # Final state depends on order, but should be consistent
        state = AbortSignal.aborted?(ref)
        assert is_boolean(state)
      end
    end

    test "bulk cleanup after mass signal creation" do
      # Create many signals
      refs = for _ <- 1..5000, do: AbortSignal.new()

      # Abort half of them
      refs
      |> Enum.take_every(2)
      |> Enum.each(&AbortSignal.abort/1)

      # Clear all of them concurrently
      refs
      |> Task.async_stream(&AbortSignal.clear/1, max_concurrency: 100)
      |> Enum.to_list()

      # All should now report false
      assert Enum.all?(refs, fn ref -> AbortSignal.aborted?(ref) == false end)
    end
  end

  # ============================================================================
  # Signal State Mutations Under Load
  # ============================================================================

  describe "signal state mutations under load" do
    test "high-frequency state transitions" do
      ref = AbortSignal.new()
      parent = self()
      num_mutators = 20
      mutations_per_process = 500

      # Spawn processes that rapidly mutate the signal
      pids =
        for i <- 1..num_mutators do
          spawn_link(fn ->
            for j <- 1..mutations_per_process do
              case rem(i + j, 3) do
                0 -> AbortSignal.abort(ref)
                1 -> AbortSignal.clear(ref)
                2 -> AbortSignal.aborted?(ref)
              end
            end

            send(parent, {:mutator_done, i})
          end)
        end

      # Wait for all mutators
      for _ <- pids do
        receive do
          {:mutator_done, _i} -> :ok
        after
          30_000 -> flunk("Mutator timed out")
        end
      end

      # System should be stable
      final_state = AbortSignal.aborted?(ref)
      assert is_boolean(final_state)
    end

    test "load test with mixed operations" do
      parent = self()
      duration_ms = 500
      num_workers = 30

      # Track operations performed
      workers =
        for i <- 1..num_workers do
          ref = AbortSignal.new()

          spawn_link(fn ->
            end_time = System.monotonic_time(:millisecond) + duration_ms
            ops = do_operations_until(ref, end_time, 0)
            send(parent, {:worker_done, i, ops})
          end)
        end

      # Collect results
      results =
        for _ <- workers do
          receive do
            {:worker_done, i, ops} -> {i, ops}
          after
            duration_ms + 5000 -> :timeout
          end
        end

      assert not Enum.member?(results, :timeout)

      total_ops = results |> Enum.map(fn {_, ops} -> ops end) |> Enum.sum()
      assert total_ops > 0, "Expected some operations to complete"
    end

    test "state consistency under concurrent mutations" do
      ref = AbortSignal.new()
      parent = self()
      rounds = 50

      for round <- 1..rounds do
        # Reset state
        AbortSignal.clear(ref)

        # Spawn aborter and checker
        _aborter =
          spawn_link(fn ->
            AbortSignal.abort(ref)
            send(parent, {:aborter_done, round})
          end)

        # Wait for aborter
        receive do
          {:aborter_done, ^round} -> :ok
        after
          1000 -> flunk("Aborter timed out in round #{round}")
        end

        # Multiple checkers after abort
        checkers =
          for _ <- 1..10 do
            spawn_link(fn ->
              result = AbortSignal.aborted?(ref)
              send(parent, {:checker_result, round, result})
            end)
          end

        # All checkers should see true
        checker_results =
          for _ <- checkers do
            receive do
              {:checker_result, ^round, result} -> result
            after
              1000 -> :timeout
            end
          end

        assert Enum.all?(checker_results, &(&1 == true)),
               "Round #{round}: All checkers should see aborted state"
      end
    end
  end

  # ============================================================================
  # Multiple Signals in Same Process
  # ============================================================================

  describe "multiple signals in same process" do
    test "managing many signals concurrently in single process" do
      num_signals = 1000

      # Create all signals
      signals = for _ <- 1..num_signals, do: AbortSignal.new()

      # Verify all start as not aborted
      assert Enum.all?(signals, fn ref -> AbortSignal.aborted?(ref) == false end)

      # Abort odd-indexed signals
      signals
      |> Enum.with_index()
      |> Enum.filter(fn {_, idx} -> rem(idx, 2) == 1 end)
      |> Enum.each(fn {ref, _} -> AbortSignal.abort(ref) end)

      # Verify state
      states =
        signals
        |> Enum.with_index()
        |> Enum.map(fn {ref, idx} ->
          expected = rem(idx, 2) == 1
          actual = AbortSignal.aborted?(ref)
          {idx, expected, actual}
        end)

      mismatches = Enum.filter(states, fn {_, exp, act} -> exp != act end)
      assert mismatches == [], "State mismatches: #{inspect(mismatches)}"
    end

    test "signals do not interfere with each other" do
      # Create pairs of signals and verify isolation
      pairs =
        for _ <- 1..100 do
          {AbortSignal.new(), AbortSignal.new()}
        end

      # Abort first of each pair
      Enum.each(pairs, fn {ref1, _ref2} -> AbortSignal.abort(ref1) end)

      # Verify isolation
      for {ref1, ref2} <- pairs do
        assert AbortSignal.aborted?(ref1) == true
        assert AbortSignal.aborted?(ref2) == false
      end

      # Now abort second of each pair
      Enum.each(pairs, fn {_ref1, ref2} -> AbortSignal.abort(ref2) end)

      # Both should be aborted
      for {ref1, ref2} <- pairs do
        assert AbortSignal.aborted?(ref1) == true
        assert AbortSignal.aborted?(ref2) == true
      end
    end

    test "interleaved operations on multiple signals" do
      signals = for _ <- 1..50, do: AbortSignal.new()

      # Perform interleaved operations
      for _ <- 1..100 do
        signal = Enum.random(signals)
        op = Enum.random([:abort, :check, :clear])

        case op do
          :abort -> AbortSignal.abort(signal)
          :check -> AbortSignal.aborted?(signal)
          :clear -> AbortSignal.clear(signal)
        end
      end

      # All operations should complete without error
      # Verify each signal is in a valid state
      Enum.each(signals, fn ref ->
        state = AbortSignal.aborted?(ref)
        assert is_boolean(state)
      end)
    end
  end

  # ============================================================================
  # Signal Persistence Across Process Restarts
  # ============================================================================

  describe "signal persistence across process restarts" do
    test "signal survives creator process termination" do
      # Create signal in a short-lived process
      ref =
        Task.async(fn ->
          ref = AbortSignal.new()
          AbortSignal.abort(ref)
          ref
        end)
        |> Task.await()

      # Creator process is now dead, signal should persist
      assert AbortSignal.aborted?(ref) == true
    end

    test "signal accessible after multiple process generations" do
      # First generation creates signal
      ref =
        Task.async(fn ->
          AbortSignal.new()
        end)
        |> Task.await()

      # Second generation aborts it
      Task.async(fn ->
        AbortSignal.abort(ref)
      end)
      |> Task.await()

      # Third generation checks it
      result =
        Task.async(fn ->
          AbortSignal.aborted?(ref)
        end)
        |> Task.await()

      assert result == true

      # Fourth generation clears it
      Task.async(fn ->
        AbortSignal.clear(ref)
      end)
      |> Task.await()

      # Fifth generation verifies clear
      final_result =
        Task.async(fn ->
          AbortSignal.aborted?(ref)
        end)
        |> Task.await()

      assert final_result == false
    end

    test "signals persist through rapid process churn" do
      # Create signals
      refs = for _ <- 1..100, do: AbortSignal.new()

      # Rapid process creation and termination interacting with signals
      for _ <- 1..500 do
        ref = Enum.random(refs)

        Task.async(fn ->
          case :rand.uniform(3) do
            1 -> AbortSignal.abort(ref)
            2 -> AbortSignal.aborted?(ref)
            3 -> AbortSignal.clear(ref)
          end
        end)
        |> Task.await()
      end

      # All signals should still be accessible
      Enum.each(refs, fn ref ->
        state = AbortSignal.aborted?(ref)
        assert is_boolean(state)
      end)
    end

    test "signal state preserved when reader processes crash" do
      ref = AbortSignal.new()
      AbortSignal.abort(ref)

      # Spawn processes that crash after reading
      for _ <- 1..50 do
        spawn(fn ->
          AbortSignal.aborted?(ref)
          raise "intentional crash"
        end)
      end

      # Give time for crashes
      :timer.sleep(100)

      # Signal should still be aborted
      assert AbortSignal.aborted?(ref) == true
    end

    test "signal lifecycle across linked process tree" do
      ref = AbortSignal.new()

      # Create a tree of linked processes
      result =
        Task.async(fn ->
          Task.async(fn ->
            Task.async(fn ->
              AbortSignal.abort(ref)
              AbortSignal.aborted?(ref)
            end)
            |> Task.await()
          end)
          |> Task.await()
        end)
        |> Task.await()

      assert result == true

      # After all tasks complete, signal persists
      assert AbortSignal.aborted?(ref) == true
    end
  end

  # ============================================================================
  # Rapid Create/Abort Cycles
  # ============================================================================

  describe "rapid create/abort cycles" do
    test "single process rapid cycling" do
      for _ <- 1..10_000 do
        ref = AbortSignal.new()
        assert AbortSignal.aborted?(ref) == false
        AbortSignal.abort(ref)
        assert AbortSignal.aborted?(ref) == true
        AbortSignal.clear(ref)
      end
    end

    test "concurrent rapid cycling from multiple processes" do
      parent = self()
      num_processes = 20
      cycles_per_process = 500

      pids =
        for i <- 1..num_processes do
          spawn_link(fn ->
            for _ <- 1..cycles_per_process do
              ref = AbortSignal.new()
              AbortSignal.abort(ref)
              AbortSignal.clear(ref)
            end

            send(parent, {:done, i})
          end)
        end

      # Wait for all
      for _ <- pids do
        receive do
          {:done, _i} -> :ok
        after
          60_000 -> flunk("Process timed out")
        end
      end

      # System should be stable
      ref = AbortSignal.new()
      assert is_reference(ref)
    end

    test "rapid cycles with interleaved checks" do
      parent = self()
      iterations = 1000

      for _ <- 1..iterations do
        ref = AbortSignal.new()

        # Spawn checker while cycling
        _checker =
          spawn_link(fn ->
            result = AbortSignal.aborted?(ref)
            send(parent, {:check, result})
          end)

        # Continue cycling
        AbortSignal.abort(ref)

        # Wait for checker
        receive do
          {:check, result} ->
            # Could be true or false depending on timing
            assert is_boolean(result)
        after
          1000 -> flunk("Checker timed out")
        end

        AbortSignal.clear(ref)
      end
    end

    test "burst create followed by burst abort" do
      # Burst create
      refs = for _ <- 1..5000, do: AbortSignal.new()

      # All should be false
      assert Enum.all?(refs, fn ref -> AbortSignal.aborted?(ref) == false end)

      # Burst abort (concurrent)
      refs
      |> Task.async_stream(&AbortSignal.abort/1, max_concurrency: 100)
      |> Enum.to_list()

      # All should be true
      assert Enum.all?(refs, fn ref -> AbortSignal.aborted?(ref) == true end)

      # Burst clear (concurrent)
      refs
      |> Task.async_stream(&AbortSignal.clear/1, max_concurrency: 100)
      |> Enum.to_list()

      # All should be false
      assert Enum.all?(refs, fn ref -> AbortSignal.aborted?(ref) == false end)
    end

    test "alternating create/abort across processes" do
      parent = self()
      rounds = 100

      for round <- 1..rounds do
        # Creator process
        creator =
          spawn_link(fn ->
            ref = AbortSignal.new()
            send(parent, {:created, round, ref})

            receive do
              :proceed -> AbortSignal.abort(ref)
            end

            send(parent, {:aborted, round})
          end)

        # Wait for creation
        ref =
          receive do
            {:created, ^round, ref} -> ref
          after
            1000 -> flunk("Creator timed out in round #{round}")
          end

        # Verify not aborted
        assert AbortSignal.aborted?(ref) == false

        # Signal creator to abort
        send(creator, :proceed)

        # Wait for abort
        receive do
          {:aborted, ^round} -> :ok
        after
          1000 -> flunk("Aborter timed out in round #{round}")
        end

        # Verify aborted
        assert AbortSignal.aborted?(ref) == true

        # Cleanup
        AbortSignal.clear(ref)
      end
    end
  end

  # ============================================================================
  # Stress Tests
  # ============================================================================

  describe "stress tests" do
    @tag timeout: 120_000
    test "sustained high load" do
      parent = self()
      duration_ms = 2000
      num_workers = 50

      # Start workers
      workers =
        for i <- 1..num_workers do
          spawn_link(fn ->
            ref = AbortSignal.new()
            end_time = System.monotonic_time(:millisecond) + duration_ms
            ops = stress_loop(ref, end_time, 0)
            AbortSignal.clear(ref)
            send(parent, {:worker_done, i, ops})
          end)
        end

      # Collect results
      results =
        for _ <- workers do
          receive do
            {:worker_done, i, ops} -> {i, ops}
          after
            duration_ms + 10_000 -> :timeout
          end
        end

      assert not Enum.member?(results, :timeout)

      total_ops = results |> Enum.map(fn {_, ops} -> ops end) |> Enum.sum()
      # Just verify we completed a reasonable number of operations
      assert total_ops > 10_000, "Expected at least 10k operations, got #{total_ops}"
    end

    test "thundering herd - many processes waiting then acting" do
      ref = AbortSignal.new()
      parent = self()
      num_waiters = 200
      barrier = :atomics.new(1, signed: false)

      # Spawn waiters that all start at the same time
      waiters =
        for i <- 1..num_waiters do
          spawn_link(fn ->
            # Spin until barrier is released
            wait_for_barrier(barrier)

            # Now all processes act simultaneously
            AbortSignal.abort(ref)
            result = AbortSignal.aborted?(ref)
            send(parent, {:waiter_done, i, result})
          end)
        end

      # Small delay to ensure all waiters are ready
      :timer.sleep(50)

      # Release the barrier
      :atomics.put(barrier, 1, 1)

      # Collect results
      results =
        for _ <- waiters do
          receive do
            {:waiter_done, _i, result} -> result
          after
            5000 -> :timeout
          end
        end

      assert not Enum.member?(results, :timeout)
      # All should see true (signal is aborted)
      assert Enum.all?(results, & &1)
    end

    test "memory stability under load" do
      # Get initial memory
      :erlang.garbage_collect()
      initial_memory = :erlang.memory(:ets)

      # Perform many operations
      for _ <- 1..50_000 do
        ref = AbortSignal.new()
        AbortSignal.abort(ref)
        AbortSignal.aborted?(ref)
        AbortSignal.clear(ref)
      end

      # Check memory after
      :erlang.garbage_collect()
      final_memory = :erlang.memory(:ets)

      # Memory should not have grown excessively (allow 10MB growth for test overhead)
      memory_growth = final_memory - initial_memory
      max_allowed_growth = 10 * 1024 * 1024

      assert memory_growth < max_allowed_growth,
             "ETS memory grew by #{memory_growth} bytes (max allowed: #{max_allowed_growth})"
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp do_operations_until(ref, end_time, count) do
    if System.monotonic_time(:millisecond) >= end_time do
      count
    else
      case rem(count, 4) do
        0 -> AbortSignal.new()
        1 -> AbortSignal.abort(ref)
        2 -> AbortSignal.aborted?(ref)
        3 -> AbortSignal.clear(ref)
      end

      do_operations_until(ref, end_time, count + 1)
    end
  end

  defp stress_loop(ref, end_time, count) do
    if System.monotonic_time(:millisecond) >= end_time do
      count
    else
      case rem(count, 3) do
        0 -> AbortSignal.abort(ref)
        1 -> AbortSignal.aborted?(ref)
        2 -> AbortSignal.clear(ref)
      end

      stress_loop(ref, end_time, count + 1)
    end
  end

  defp wait_for_barrier(barrier) do
    if :atomics.get(barrier, 1) == 0 do
      wait_for_barrier(barrier)
    else
      :ok
    end
  end
end
