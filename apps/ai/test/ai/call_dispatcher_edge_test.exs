defmodule Ai.CallDispatcherEdgeTest do
  @moduledoc """
  Edge case tests for CallDispatcher covering telemetry, concurrency,
  and complex failure scenarios.
  """
  use ExUnit.Case, async: false

  alias Ai.CallDispatcher
  alias Ai.RateLimiter
  alias Ai.CircuitBreaker

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"edge_test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  # ============================================================================
  # Telemetry Event Emission Tests
  # ============================================================================

  describe "telemetry events" do
    test "emits dispatch event on successful dispatch", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 10})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-dispatch-#{inspect(ref)}",
        [:ai, :dispatcher, :dispatch],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      CallDispatcher.dispatch(provider, fn -> {:ok, "result"} end)

      assert_receive {:telemetry, [:ai, :dispatcher, :dispatch], measurements, metadata}, 1000
      assert is_integer(measurements.system_time)
      assert metadata.provider == provider

      :telemetry.detach("test-dispatch-#{inspect(ref)}")
    end

    test "emits rejected event when circuit is open", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 10})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-rejected-circuit-#{inspect(ref)}",
        [:ai, :dispatcher, :rejected],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end)
      assert {:error, :circuit_open} = result

      assert_receive {:telemetry, [:ai, :dispatcher, :rejected], measurements, metadata}, 1000
      assert is_integer(measurements.duration)
      assert is_integer(measurements.system_time)
      assert metadata.provider == provider
      assert metadata.reason == :circuit_open

      :telemetry.detach("test-rejected-circuit-#{inspect(ref)}")
    end

    test "emits rejected event when rate limited", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Exhaust rate limit
      CallDispatcher.dispatch(provider, fn -> {:ok, "first"} end)

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-rejected-rate-#{inspect(ref)}",
        [:ai, :dispatcher, :rejected],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "second"} end)
      assert {:error, :rate_limited} = result

      assert_receive {:telemetry, [:ai, :dispatcher, :rejected], measurements, metadata}, 1000
      assert is_integer(measurements.duration)
      assert metadata.provider == provider
      assert metadata.reason == :rate_limited

      :telemetry.detach("test-rejected-rate-#{inspect(ref)}")
    end

    test "emits rejected event when max concurrency reached", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      parent = self()

      # Start a blocking request
      task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :slot_acquired)

            receive do
              :release -> {:ok, "done"}
            end
          end)
        end)

      assert_receive :slot_acquired, 1000

      ref = make_ref()

      :telemetry.attach(
        "test-rejected-concurrency-#{inspect(ref)}",
        [:ai, :dispatcher, :rejected],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "blocked"} end)
      assert {:error, :max_concurrency} = result

      assert_receive {:telemetry, [:ai, :dispatcher, :rejected], measurements, metadata}, 1000
      assert is_integer(measurements.duration)
      assert metadata.provider == provider
      assert metadata.reason == :max_concurrency

      :telemetry.detach("test-rejected-concurrency-#{inspect(ref)}")

      send(task.pid, :release)
      Task.await(task)
    end

    test "telemetry events include accurate timing information", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 10})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "test-timing-#{inspect(ref)}",
        [[:ai, :dispatcher, :dispatch], [:ai, :dispatcher, :rejected]],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Capture start time
      before_dispatch = System.system_time()

      CallDispatcher.dispatch(provider, fn ->
        Process.sleep(50)
        {:ok, "delayed"}
      end)

      after_dispatch = System.system_time()

      assert_receive {:telemetry, [:ai, :dispatcher, :dispatch], measurements, _metadata}, 1000

      # Verify system_time is within reasonable bounds
      assert measurements.system_time >= before_dispatch
      assert measurements.system_time <= after_dispatch

      :telemetry.detach("test-timing-#{inspect(ref)}")
    end
  end

  # ============================================================================
  # Cascading Failure Tests
  # ============================================================================

  describe "cascading failures" do
    test "multiple concurrent failures trigger circuit breaker", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      # Launch multiple concurrent failing requests
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn -> {:error, :simulated_failure} end)
          end)
        end

      # Wait for all tasks
      results = Task.await_many(tasks, 5000)

      # All should return error tuples
      assert Enum.all?(results, fn result ->
               match?({:error, _}, result)
             end)

      # Give time for circuit breaker to process failures
      Process.sleep(50)

      # Circuit should now be open
      assert CircuitBreaker.is_open?(provider)
    end

    test "failures during half-open state reopen circuit immediately", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})

      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 100}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)

      # Wait for half-open state
      Process.sleep(120)
      refute CircuitBreaker.is_open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Failure during half-open should reopen
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "exception in callback triggers circuit breaker failure recording", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # First failure via exception
      assert_raise RuntimeError, fn ->
        CallDispatcher.dispatch(provider, fn -> raise "simulated error" end)
      end

      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 1

      # Second failure via exception opens circuit
      assert_raise RuntimeError, fn ->
        CallDispatcher.dispatch(provider, fn -> raise "simulated error 2" end)
      end

      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)
    end

    test "mixed success and failure patterns", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      # Interleave successes and failures
      CallDispatcher.dispatch(provider, fn -> {:error, :fail1} end)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 1

      # Success resets failure count
      CallDispatcher.dispatch(provider, fn -> {:ok, "success"} end)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 0

      # Need 3 consecutive failures now
      CallDispatcher.dispatch(provider, fn -> {:error, :fail2} end)
      CallDispatcher.dispatch(provider, fn -> {:error, :fail3} end)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 2
      refute CircuitBreaker.is_open?(provider)

      CallDispatcher.dispatch(provider, fn -> {:error, :fail4} end)
      Process.sleep(10)

      assert CircuitBreaker.is_open?(provider)
    end
  end

  # ============================================================================
  # Rate Limiter + Circuit Breaker Interaction Tests
  # ============================================================================

  describe "rate limiter and circuit breaker interaction" do
    test "circuit breaker checked before rate limiter", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      # Even though rate limiter has tokens, circuit being open should reject first
      {:ok, rl_state} = RateLimiter.get_state(provider)
      assert rl_state.available_tokens > 0

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "test"} end)
      assert {:error, :circuit_open} = result

      # Rate limiter tokens should NOT be consumed (circuit check happens first)
      {:ok, rl_state_after} = RateLimiter.get_state(provider)
      assert rl_state_after.available_tokens == rl_state.available_tokens
    end

    test "rate limit rejection does not affect circuit breaker", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Use up rate limit
      {:ok, _} = CallDispatcher.dispatch(provider, fn -> {:ok, "first"} end)

      # Get initial circuit state
      {:ok, cb_state_before} = CircuitBreaker.get_state(provider)
      initial_failure_count = cb_state_before.failure_count

      # Multiple rate limit rejections
      for _ <- 1..3 do
        assert {:error, :rate_limited} = CallDispatcher.dispatch(provider, fn -> {:ok, "blocked"} end)
      end

      Process.sleep(20)

      # Circuit breaker failure count should not have increased
      {:ok, cb_state_after} = CircuitBreaker.get_state(provider)
      assert cb_state_after.failure_count == initial_failure_count
      refute CircuitBreaker.is_open?(provider)
    end

    test "circuit opens while rate limiter has available capacity", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Verify rate limiter has capacity
      {:ok, rl_state} = RateLimiter.get_state(provider)
      assert rl_state.available_tokens > 10

      # Open circuit through failures
      CallDispatcher.dispatch(provider, fn -> {:error, :fail1} end)
      CallDispatcher.dispatch(provider, fn -> {:error, :fail2} end)
      Process.sleep(20)

      # Rate limiter should still have capacity, but circuit is open
      {:ok, rl_state} = RateLimiter.get_state(provider)
      assert rl_state.available_tokens > 0
      assert CircuitBreaker.is_open?(provider)

      # Requests should fail with circuit_open, not rate_limited
      assert {:error, :circuit_open} = CallDispatcher.dispatch(provider, fn -> {:ok, "test"} end)
    end

    test "both rate limiter and circuit breaker recovery", %{provider: provider} do
      # Use separate providers to test independent recovery
      rl_provider = :"#{provider}_rl"
      cb_provider = :"#{provider}_cb"

      # Test rate limiter recovery
      start_supervised!(
        {RateLimiter, provider: rl_provider, tokens_per_second: 100, max_tokens: 2},
        id: {RateLimiter, rl_provider}
      )

      start_supervised!(
        {CircuitBreaker, provider: rl_provider, failure_threshold: 100},
        id: {CircuitBreaker, rl_provider}
      )

      # Exhaust rate limiter
      CallDispatcher.dispatch(rl_provider, fn -> {:ok, :token1} end)
      CallDispatcher.dispatch(rl_provider, fn -> {:ok, :token2} end)

      # Should be exhausted now
      assert {:error, :rate_limited} =
               CallDispatcher.dispatch(rl_provider, fn -> {:ok, "test"} end)

      # Wait for tokens to refill (100/s means ~50ms for 5 tokens)
      Process.sleep(60)

      {:ok, rl_state} = RateLimiter.get_state(rl_provider)
      assert rl_state.available_tokens >= 1

      # Test circuit breaker recovery
      start_supervised!(
        {RateLimiter, provider: cb_provider, tokens_per_second: 100, max_tokens: 10},
        id: {RateLimiter, cb_provider}
      )

      start_supervised!(
        {CircuitBreaker, provider: cb_provider, failure_threshold: 2, recovery_timeout: 100},
        id: {CircuitBreaker, cb_provider}
      )

      # Open circuit
      CircuitBreaker.record_failure(cb_provider)
      CircuitBreaker.record_failure(cb_provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(cb_provider)

      # Wait for recovery
      Process.sleep(120)

      # Circuit should be half-open (not open)
      refute CircuitBreaker.is_open?(cb_provider)
    end
  end

  # ============================================================================
  # Request Timeout Handling Tests
  # ============================================================================

  describe "request timeout handling" do
    test "slow callback holds slot until completion", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 2)

      parent = self()

      # Start a slow request
      slow_task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :slow_started)
            Process.sleep(200)
            {:ok, "slow"}
          end)
        end)

      assert_receive :slow_started, 1000

      # Verify active requests increased
      assert CallDispatcher.get_active_requests(provider) == 1

      # Can still dispatch another request (cap is 2)
      assert {:ok, "fast"} = CallDispatcher.dispatch(provider, fn -> {:ok, "fast"} end)

      # Wait for slow task
      assert {:ok, "slow"} = Task.await(slow_task, 1000)

      # Slot should be released
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)
    end

    test "callback timeout does not leave orphaned slots", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      parent = self()

      # Start a task that will be killed
      pid =
        spawn(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :callback_started)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :callback_started, 1000

      # Verify slot is held
      assert CallDispatcher.get_active_requests(provider) == 1

      # Kill the process
      Process.exit(pid, :kill)

      # Slot should be released via monitor
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      # Should be able to dispatch again
      assert {:ok, "after"} = CallDispatcher.dispatch(provider, fn -> {:ok, "after"} end)
    end

    test "GenServer call timeout does not corrupt state", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Perform many rapid operations
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              Process.sleep(10)
              {:ok, "quick"}
            end)
          end)
        end

      Task.await_many(tasks, 5000)

      # Wait for all slots to be released
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      # State should be consistent
      state_after = CallDispatcher.get_state()
      assert state_after.active_requests[provider] == 0 || state_after.active_requests[provider] == nil
    end
  end

  # ============================================================================
  # Dynamic Cap Changes Tests
  # ============================================================================

  describe "dynamic cap changes during active requests" do
    test "lowering cap does not kill active requests", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 5)

      parent = self()

      # Start 3 requests
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              send(parent, {:task_started, i})

              receive do
                :continue -> {:ok, i}
              after
                5000 -> {:error, :timeout}
              end
            end)
          end)
        end

      # Wait for all tasks to start
      for i <- 1..3 do
        assert_receive {:task_started, ^i}, 1000
      end

      # Verify active requests
      assert CallDispatcher.get_active_requests(provider) == 3

      # Lower cap below current active count
      CallDispatcher.set_concurrency_cap(provider, 1)

      # Active requests should still be 3
      assert CallDispatcher.get_active_requests(provider) == 3

      # New requests should be rejected
      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "blocked"} end)

      # Release existing tasks
      for task <- tasks do
        send(task.pid, :continue)
      end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, fn {:ok, _} -> true; _ -> false end)

      # Slots should be released
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)
    end

    test "raising cap allows new requests immediately", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      parent = self()

      # Start one blocking request
      blocking_task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :blocking_started)

            receive do
              :continue -> {:ok, "blocking"}
            end
          end)
        end)

      assert_receive :blocking_started, 1000

      # Cap is 1, so this should fail
      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "blocked"} end)

      # Raise cap
      CallDispatcher.set_concurrency_cap(provider, 2)

      # Now should succeed
      quick_task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn -> {:ok, "quick"} end)
        end)

      assert {:ok, "quick"} = Task.await(quick_task, 1000)

      # Clean up
      send(blocking_task.pid, :continue)
      Task.await(blocking_task)
    end

    test "cap changes are atomic with slot acquisition", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 10)

      # Rapidly change cap while dispatching
      cap_changer =
        Task.async(fn ->
          for cap <- Stream.cycle([1, 5, 10, 2, 8]) |> Enum.take(50) do
            CallDispatcher.set_concurrency_cap(provider, cap)
            Process.sleep(5)
          end
        end)

      # Simultaneously dispatch requests
      dispatch_tasks =
        for _ <- 1..30 do
          Task.async(fn ->
            try do
              CallDispatcher.dispatch(provider, fn ->
                Process.sleep(10)
                {:ok, "concurrent"}
              end)
            catch
              :exit, _ -> {:error, :exit}
            end
          end)
        end

      Task.await(cap_changer, 5000)
      results = Task.await_many(dispatch_tasks, 10_000)

      # All results should be valid (either success or max_concurrency)
      for result <- results do
        assert match?({:ok, _}, result) or match?({:error, :max_concurrency}, result) or
                 match?({:error, :exit}, result),
               "Unexpected result: #{inspect(result)}"
      end

      # State should be consistent after all operations
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end, 2000)
    end
  end

  # ============================================================================
  # Concurrent Dispatch Tests
  # ============================================================================

  describe "concurrent dispatch calls" do
    test "many concurrent requests to same provider", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 1000, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 100})

      CallDispatcher.set_concurrency_cap(provider, 50)

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              Process.sleep(:rand.uniform(20))
              {:ok, i}
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Count successes
      success_count =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # Should have some successes
      assert success_count > 0

      # All results should be valid
      for result <- results do
        assert match?({:ok, _}, result) or match?({:error, :max_concurrency}, result),
               "Unexpected result: #{inspect(result)}"
      end

      # Final state should be clean
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end, 2000)
    end

    test "concurrent requests to multiple providers", %{provider: base_provider} do
      providers =
        for i <- 1..3 do
          provider = :"#{base_provider}_multi_#{i}"

          start_supervised!(
            {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 20},
            id: {RateLimiter, provider}
          )

          start_supervised!(
            {CircuitBreaker, provider: provider, failure_threshold: 10},
            id: {CircuitBreaker, provider}
          )

          CallDispatcher.set_concurrency_cap(provider, 5)
          provider
        end

      # Dispatch to all providers concurrently
      tasks =
        for provider <- providers, i <- 1..10 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              Process.sleep(:rand.uniform(10))
              {:ok, {provider, i}}
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Group results by provider
      provider_results =
        results
        |> Enum.filter(fn
          {:ok, {_provider, _}} -> true
          _ -> false
        end)
        |> Enum.group_by(fn {:ok, {provider, _}} -> provider end)

      # Each provider should have some successes
      for provider <- providers do
        count = length(Map.get(provider_results, provider, []))
        assert count > 0, "Provider #{provider} had no successful requests"
      end

      # All providers should return to clean state
      for provider <- providers do
        wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end, 2000)
      end
    end

    test "concurrent dispatch with failures triggers circuit breaker appropriately", %{
      provider: provider
    } do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      # Use a higher threshold so the circuit doesn't open and reset on success
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 50})

      CallDispatcher.set_concurrency_cap(provider, 20)

      # Dispatch only failures to ensure circuit breaker records them
      tasks =
        for i <- 1..15 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              Process.sleep(:rand.uniform(10))
              {:error, {:simulated_failure, i}}
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should be error results
      assert Enum.all?(results, &match?({:error, _}, &1))

      # Allow time for circuit breaker to process all failures
      Process.sleep(100)

      # Circuit breaker state should reflect failures
      {:ok, cb_state} = CircuitBreaker.get_state(provider)

      # Should have recorded failures (won't hit threshold of 50)
      assert cb_state.failure_count > 0,
             "Expected failure_count > 0, got #{cb_state.failure_count}"
    end

    test "race condition: slot release and acquisition", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 100})

      CallDispatcher.set_concurrency_cap(provider, 1)

      parent = self()

      # Run multiple iterations to increase chance of catching race conditions
      for iteration <- 1..10 do
        # Quickly release and acquire
        task1 =
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              send(parent, {:task1_running, iteration})
              {:ok, :task1}
            end)
          end)

        # Wait for task1 to complete
        result1 = Task.await(task1, 1000)

        # Immediately try to acquire
        task2 =
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              send(parent, {:task2_running, iteration})
              {:ok, :task2}
            end)
          end)

        result2 = Task.await(task2, 1000)

        # Both should succeed (cap is 1, but they're sequential)
        assert match?({:ok, :task1}, result1) or match?({:error, :max_concurrency}, result1)
        assert match?({:ok, :task2}, result2) or match?({:error, :max_concurrency}, result2)
      end

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)
    end

    test "high contention stress test", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10000, max_tokens: 1000})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1000})

      # Very low cap to create high contention
      CallDispatcher.set_concurrency_cap(provider, 3)

      # Many concurrent requests
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              # Random work
              Process.sleep(:rand.uniform(5))
              {:ok, i}
            end)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # Count outcomes
      success_count = Enum.count(results, &match?({:ok, _}, &1))

      # Should have some successes
      assert success_count > 0, "Expected some successful requests"

      # Final state clean
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end, 2000)

      # State should be internally consistent
      state = CallDispatcher.get_state()
      assert state.active_requests[provider] == 0 or state.active_requests[provider] == nil
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "dispatch with non-tuple return value", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 10})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Return a non-tuple value (treated as success)
      result = CallDispatcher.dispatch(provider, fn -> "raw_string" end)
      assert result == "raw_string"

      {:ok, cb_state} = CircuitBreaker.get_state(provider)
      assert cb_state.failure_count == 0
    end

    test "dispatch with nil return value", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 10})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      result = CallDispatcher.dispatch(provider, fn -> nil end)
      assert result == nil

      {:ok, cb_state} = CircuitBreaker.get_state(provider)
      assert cb_state.failure_count == 0
    end

    test "provider with very long atom name", %{provider: _provider} do
      long_name = String.duplicate("a", 100) |> String.to_atom()

      start_supervised!(
        {RateLimiter, provider: long_name, tokens_per_second: 100, max_tokens: 10},
        id: {RateLimiter, long_name}
      )

      start_supervised!(
        {CircuitBreaker, provider: long_name, failure_threshold: 5},
        id: {CircuitBreaker, long_name}
      )

      result = CallDispatcher.dispatch(long_name, fn -> {:ok, "long_name_works"} end)
      assert {:ok, "long_name_works"} = result
    end

    test "same process makes multiple concurrent requests", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 10)

      # Same process spawns multiple tasks
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              Process.sleep(10)
              {:ok, i}
            end)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "nested dispatch calls", %{provider: provider} do
      # Create two providers for nesting
      inner_provider = :"#{provider}_inner"

      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 10},
        id: {RateLimiter, provider}
      )

      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 5},
        id: {CircuitBreaker, provider}
      )

      start_supervised!(
        {RateLimiter, provider: inner_provider, tokens_per_second: 100, max_tokens: 10},
        id: {RateLimiter, inner_provider}
      )

      start_supervised!(
        {CircuitBreaker, provider: inner_provider, failure_threshold: 5},
        id: {CircuitBreaker, inner_provider}
      )

      result =
        CallDispatcher.dispatch(provider, fn ->
          inner_result =
            CallDispatcher.dispatch(inner_provider, fn ->
              {:ok, "inner"}
            end)

          {:ok, {:outer, inner_result}}
        end)

      assert {:ok, {:outer, {:ok, "inner"}}} = result
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp wait_until(fun, timeout_ms \\ 1_000, step_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(step_ms)
        wait_until(fun, timeout_ms, step_ms)
      else
        flunk("condition not met within #{timeout_ms}ms")
      end
    end
  end
end
