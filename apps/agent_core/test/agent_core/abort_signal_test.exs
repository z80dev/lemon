defmodule AgentCore.AbortSignalTest do
  use ExUnit.Case, async: true

  alias AgentCore.AbortSignal

  # Ensure the ETS table is initialized before running tests
  # This prevents race conditions when multiple async tests try to
  # create the table simultaneously
  setup do
    # Create a signal to ensure the table exists
    _ref = AbortSignal.new()
    :ok
  end

  # ============================================================================
  # Signal Creation and Initial State
  # ============================================================================

  describe "new/0" do
    test "returns a reference" do
      ref = AbortSignal.new()
      assert is_reference(ref)
    end

    test "returns unique references on each call" do
      ref1 = AbortSignal.new()
      ref2 = AbortSignal.new()
      ref3 = AbortSignal.new()

      assert ref1 != ref2
      assert ref2 != ref3
      assert ref1 != ref3
    end

    test "creates signal in non-aborted state" do
      ref = AbortSignal.new()
      assert AbortSignal.aborted?(ref) == false
    end

    test "can create many signals without error" do
      refs = for _ <- 1..1000, do: AbortSignal.new()
      assert length(refs) == 1000
      assert Enum.all?(refs, &is_reference/1)
    end
  end

  # ============================================================================
  # Aborting a Signal
  # ============================================================================

  describe "abort/1" do
    test "returns :ok" do
      ref = AbortSignal.new()
      assert :ok = AbortSignal.abort(ref)
    end

    test "marks the signal as aborted" do
      ref = AbortSignal.new()
      assert AbortSignal.aborted?(ref) == false

      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
    end

    test "can abort a signal that was never registered via new/0" do
      # This tests the ensure_table behavior with arbitrary refs
      ref = make_ref()
      assert :ok = AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
    end

    test "abort is idempotent - multiple aborts do not raise" do
      ref = AbortSignal.new()

      assert :ok = AbortSignal.abort(ref)
      assert :ok = AbortSignal.abort(ref)
      assert :ok = AbortSignal.abort(ref)

      assert AbortSignal.aborted?(ref) == true
    end
  end

  # ============================================================================
  # Checking Abort Status
  # ============================================================================

  describe "aborted?/1" do
    test "returns false for nil" do
      assert AbortSignal.aborted?(nil) == false
    end

    test "returns false for newly created signal" do
      ref = AbortSignal.new()
      assert AbortSignal.aborted?(ref) == false
    end

    test "returns true after abort is called" do
      ref = AbortSignal.new()
      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
    end

    test "returns false for unregistered reference" do
      # A reference that was never passed to new() or abort()
      ref = make_ref()
      assert AbortSignal.aborted?(ref) == false
    end

    test "returns false after signal is cleared" do
      ref = AbortSignal.new()
      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true

      AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false
    end

    test "does not affect other signals when checking" do
      ref1 = AbortSignal.new()
      ref2 = AbortSignal.new()

      AbortSignal.abort(ref1)

      assert AbortSignal.aborted?(ref1) == true
      assert AbortSignal.aborted?(ref2) == false
    end
  end

  # ============================================================================
  # Multiple Abort Calls
  # ============================================================================

  describe "multiple abort calls" do
    test "repeated aborts have no additional effect" do
      ref = AbortSignal.new()

      for _ <- 1..10 do
        assert :ok = AbortSignal.abort(ref)
      end

      assert AbortSignal.aborted?(ref) == true
    end

    test "aborting different signals independently" do
      refs = for _ <- 1..10, do: AbortSignal.new()

      # Abort only even-indexed signals
      refs
      |> Enum.with_index()
      |> Enum.each(fn {ref, idx} ->
        if rem(idx, 2) == 0, do: AbortSignal.abort(ref)
      end)

      # Verify status
      refs
      |> Enum.with_index()
      |> Enum.each(fn {ref, idx} ->
        expected = rem(idx, 2) == 0
        assert AbortSignal.aborted?(ref) == expected
      end)
    end

    test "abort after clear resets the signal to aborted state" do
      ref = AbortSignal.new()

      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true

      AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false

      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
    end
  end

  # ============================================================================
  # Clearing Signals
  # ============================================================================

  describe "clear/1" do
    test "returns :ok for nil" do
      assert :ok = AbortSignal.clear(nil)
    end

    test "returns :ok for valid reference" do
      ref = AbortSignal.new()
      assert :ok = AbortSignal.clear(ref)
    end

    test "removes signal from storage" do
      ref = AbortSignal.new()
      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true

      AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false
    end

    test "clearing an already cleared signal is safe" do
      ref = AbortSignal.new()

      assert :ok = AbortSignal.clear(ref)
      assert :ok = AbortSignal.clear(ref)
      assert :ok = AbortSignal.clear(ref)
    end

    test "clearing an unregistered reference is safe" do
      ref = make_ref()
      assert :ok = AbortSignal.clear(ref)
    end

    test "clearing does not affect other signals" do
      ref1 = AbortSignal.new()
      ref2 = AbortSignal.new()

      AbortSignal.abort(ref1)
      AbortSignal.abort(ref2)

      AbortSignal.clear(ref1)

      assert AbortSignal.aborted?(ref1) == false
      assert AbortSignal.aborted?(ref2) == true
    end
  end

  # ============================================================================
  # Concurrent Access (Multiple Processes)
  # ============================================================================

  describe "concurrent access" do
    test "multiple processes can check the same signal concurrently" do
      ref = AbortSignal.new()
      parent = self()

      # Spawn multiple processes that check the signal
      pids =
        for _ <- 1..100 do
          spawn(fn ->
            result = AbortSignal.aborted?(ref)
            send(parent, {:result, self(), result})
          end)
        end

      # Collect results
      results =
        for _ <- pids do
          receive do
            {:result, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      # All should return false
      assert Enum.all?(results, &(&1 == false))
    end

    test "multiple processes can abort the same signal concurrently" do
      ref = AbortSignal.new()
      parent = self()

      # Spawn multiple processes that abort the signal
      pids =
        for _ <- 1..100 do
          spawn(fn ->
            result = AbortSignal.abort(ref)
            send(parent, {:result, self(), result})
          end)
        end

      # Collect results
      results =
        for _ <- pids do
          receive do
            {:result, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      # All should return :ok
      assert Enum.all?(results, &(&1 == :ok))
      # Signal should be aborted
      assert AbortSignal.aborted?(ref) == true
    end

    test "concurrent abort and check operations are thread-safe" do
      ref = AbortSignal.new()
      parent = self()

      # Spawn processes that check the signal
      checkers =
        for i <- 1..50 do
          spawn(fn ->
            # Add small delay based on index to vary timing
            Process.sleep(rem(i, 10))
            result = AbortSignal.aborted?(ref)
            send(parent, {:check, self(), result})
          end)
        end

      # Spawn processes that abort the signal
      aborters =
        for i <- 1..50 do
          spawn(fn ->
            Process.sleep(rem(i, 10))
            result = AbortSignal.abort(ref)
            send(parent, {:abort, self(), result})
          end)
        end

      # Collect all results
      check_results =
        for _ <- checkers do
          receive do
            {:check, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      abort_results =
        for _ <- aborters do
          receive do
            {:abort, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      # All aborts should succeed
      assert Enum.all?(abort_results, &(&1 == :ok))

      # Check results should be booleans (some may have read before abort, some after)
      assert Enum.all?(check_results, &is_boolean/1)

      # Final state should be aborted
      assert AbortSignal.aborted?(ref) == true
    end

    test "concurrent clear and abort operations are thread-safe" do
      ref = AbortSignal.new()
      parent = self()

      # Alternate between abort and clear operations
      pids =
        for i <- 1..100 do
          spawn(fn ->
            if rem(i, 2) == 0 do
              AbortSignal.abort(ref)
              send(parent, {:done, self(), :abort})
            else
              AbortSignal.clear(ref)
              send(parent, {:done, self(), :clear})
            end
          end)
        end

      # Wait for all to complete
      for _ <- pids do
        receive do
          {:done, _pid, _op} -> :ok
        after
          1000 -> :timeout
        end
      end

      # No crashes should occur, final state depends on operation order
      # Just verify we can still use the signal
      result = AbortSignal.aborted?(ref)
      assert is_boolean(result)
    end

    test "different processes working with different signals do not interfere" do
      parent = self()

      # Ensure table exists first to avoid race condition during table creation
      _initial_ref = AbortSignal.new()

      # Each process gets its own signal
      pids =
        for i <- 1..50 do
          spawn(fn ->
            ref = AbortSignal.new()

            if AbortSignal.aborted?(ref) == false do
              AbortSignal.abort(ref)

              if AbortSignal.aborted?(ref) == true do
                AbortSignal.clear(ref)

                if AbortSignal.aborted?(ref) == false do
                  send(parent, {:done, self(), i})
                else
                  send(parent, {:error, self(), :clear_failed})
                end
              else
                send(parent, {:error, self(), :abort_failed})
              end
            else
              send(parent, {:error, self(), :initial_state_wrong})
            end
          end)
        end

      # All processes should complete successfully
      results =
        for _ <- pids do
          receive do
            {:done, _pid, i} -> i
            {:error, _pid, reason} -> {:error, reason}
          after
            5000 -> :timeout
          end
        end

      assert Enum.all?(results, &is_integer/1)
      assert length(results) == 50
    end

    test "high contention scenario with many processes" do
      ref = AbortSignal.new()
      parent = self()

      # Spawn many processes doing various operations
      pids =
        for i <- 1..200 do
          spawn(fn ->
            # Mix of operations
            case rem(i, 4) do
              0 -> AbortSignal.abort(ref)
              1 -> AbortSignal.aborted?(ref)
              2 -> AbortSignal.clear(ref)
              3 -> AbortSignal.aborted?(ref)
            end

            send(parent, {:done, self()})
          end)
        end

      # Wait for all to complete
      for _ <- pids do
        receive do
          {:done, _pid} -> :ok
        after
          2000 -> :timeout
        end
      end

      # System should remain stable
      # Verify we can still use signals
      new_ref = AbortSignal.new()
      assert AbortSignal.aborted?(new_ref) == false
      AbortSignal.abort(new_ref)
      assert AbortSignal.aborted?(new_ref) == true
    end
  end

  # ============================================================================
  # Memory Cleanup
  # ============================================================================

  describe "memory cleanup" do
    test "clear removes entries from ETS table" do
      # Create and immediately clear many signals
      for _ <- 1..1000 do
        ref = AbortSignal.new()
        AbortSignal.clear(ref)
      end

      # If clear works properly, we should not accumulate entries
      # The table should be able to be used without issues
      ref = AbortSignal.new()
      assert AbortSignal.aborted?(ref) == false
    end

    test "cleared signals free their ETS entries" do
      ref = AbortSignal.new()
      AbortSignal.abort(ref)

      # Clear should remove the entry
      AbortSignal.clear(ref)

      # Looking up a cleared ref returns false (entry not found)
      assert AbortSignal.aborted?(ref) == false
    end

    test "many signals can be created and cleared in rapid succession" do
      refs =
        for _ <- 1..5000 do
          ref = AbortSignal.new()
          AbortSignal.abort(ref)
          AbortSignal.clear(ref)
          ref
        end

      # All refs should now return false (cleared)
      assert Enum.all?(refs, fn ref -> AbortSignal.aborted?(ref) == false end)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "operations work with first reference created" do
      ref = AbortSignal.new()

      assert AbortSignal.aborted?(ref) == false
      assert :ok = AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
      assert :ok = AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false
    end

    test "aborted? with nil does not modify any state" do
      ref = AbortSignal.new()

      # Check nil multiple times
      for _ <- 1..10 do
        assert AbortSignal.aborted?(nil) == false
      end

      # Original ref should be unchanged
      assert AbortSignal.aborted?(ref) == false
    end

    test "clear with nil does not affect other signals" do
      ref = AbortSignal.new()
      AbortSignal.abort(ref)

      # Clear nil multiple times
      for _ <- 1..10 do
        assert :ok = AbortSignal.clear(nil)
      end

      # Original ref should be unchanged
      assert AbortSignal.aborted?(ref) == true
    end

    test "signal can be reused after clear" do
      ref = AbortSignal.new()

      # First lifecycle
      assert AbortSignal.aborted?(ref) == false
      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
      AbortSignal.clear(ref)

      # Second lifecycle (reusing after clear)
      # Note: after clear, the ref is no longer in the table
      # abort re-inserts it
      AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true
      AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false
    end

    test "rapid state transitions" do
      ref = AbortSignal.new()

      for _ <- 1..100 do
        assert AbortSignal.aborted?(ref) == false
        AbortSignal.abort(ref)
        assert AbortSignal.aborted?(ref) == true
        AbortSignal.clear(ref)
      end

      assert AbortSignal.aborted?(ref) == false
    end
  end

  # ============================================================================
  # ETS Table Behavior
  # ============================================================================

  describe "ETS table behavior" do
    test "table is created lazily on first operation" do
      # The table :agent_core_abort_signals should exist after any operation
      # This test just ensures no crash occurs
      ref = AbortSignal.new()
      assert is_reference(ref)

      # Verify table exists
      assert :ets.whereis(:agent_core_abort_signals) != :undefined
    end

    test "table survives across many operations" do
      # Perform many operations
      for _ <- 1..1000 do
        ref = AbortSignal.new()
        AbortSignal.abort(ref)
        AbortSignal.aborted?(ref)
        AbortSignal.clear(ref)
      end

      # Table should still be accessible
      ref = AbortSignal.new()
      assert AbortSignal.aborted?(ref) == false
    end

    test "concurrent table access from multiple processes is safe" do
      parent = self()

      # Ensure table exists first to avoid race condition during table creation
      # This is realistic - in production, the table is typically created at app startup
      _ref = AbortSignal.new()

      # Spawn processes that all call new() simultaneously
      pids =
        for _ <- 1..100 do
          spawn(fn ->
            ref = AbortSignal.new()
            send(parent, {:ref, self(), ref})
          end)
        end

      # Collect all refs
      refs =
        for _ <- pids do
          receive do
            {:ref, _pid, ref} -> ref
          after
            1000 -> nil
          end
        end

      # All should be valid refs
      assert Enum.all?(refs, &is_reference/1)
      assert length(Enum.uniq(refs)) == 100
    end
  end

  # ============================================================================
  # Integration-like Tests
  # ============================================================================

  describe "realistic usage patterns" do
    test "signal used to cancel a long-running task" do
      ref = AbortSignal.new()

      # Simulate a task that checks abort signal periodically
      task =
        Task.async(fn ->
          Enum.reduce_while(1..100, 0, fn i, acc ->
            if AbortSignal.aborted?(ref) do
              {:halt, {:aborted_at, acc}}
            else
              Process.sleep(10)
              {:cont, acc + i}
            end
          end)
        end)

      # Let it run for a bit
      Process.sleep(50)

      # Abort it
      AbortSignal.abort(ref)

      # Wait for task to complete
      result = Task.await(task, 5000)

      # Should have been aborted before completing
      assert match?({:aborted_at, _}, result)
    end

    test "multiple tasks sharing the same abort signal" do
      ref = AbortSignal.new()

      # Start multiple tasks that check the same signal
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Enum.reduce_while(1..50, 0, fn _, acc ->
              if AbortSignal.aborted?(ref) do
                {:halt, {:aborted, i, acc}}
              else
                Process.sleep(10)
                {:cont, acc + 1}
              end
            end)
          end)
        end

      # Let them run
      Process.sleep(100)

      # Abort all at once
      AbortSignal.abort(ref)

      # Wait for all tasks
      results = Enum.map(tasks, &Task.await(&1, 5000))

      # All should be aborted
      assert Enum.all?(results, fn result -> match?({:aborted, _, _}, result) end)
    end

    test "cleanup after task completion" do
      ref = AbortSignal.new()

      # Simulate task completion
      task =
        Task.async(fn ->
          for i <- 1..10 do
            if AbortSignal.aborted?(ref), do: throw(:aborted)
            Process.sleep(5)
            i
          end
        end)

      Task.await(task, 5000)

      # Clean up signal after task completes
      AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false
    end
  end
end
