defmodule Ai.CircuitBreakerConcurrencyTest do
  @moduledoc """
  Tests for CircuitBreaker behavior under concurrent load.

  These tests verify race conditions, state consistency, and concurrent
  request handling that may not be caught by sequential tests.
  """
  use ExUnit.Case, async: false

  alias Ai.CircuitBreaker
  alias Ai.CallDispatcher
  alias Ai.RateLimiter

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"concurrent_test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  describe "concurrent failure recording" do
    test "handles multiple simultaneous failures correctly", %{provider: provider} do
      # Start with threshold of 10 to allow time for concurrent failures
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 10, recovery_timeout: 5000}
      )

      # Spawn 20 concurrent tasks that each record a failure
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            CircuitBreaker.record_failure(provider)
          end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Allow time for all casts to be processed
      Process.sleep(50)

      # Circuit should be open (we exceeded threshold)
      assert CircuitBreaker.is_open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
      # Failure count should be >= threshold (could be slightly more due to race)
      assert state.failure_count >= 10
    end

    test "failure count remains consistent under heavy load", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 100, recovery_timeout: 5000}
      )

      num_failures = 50

      # Record failures concurrently
      tasks =
        for _ <- 1..num_failures do
          Task.async(fn ->
            CircuitBreaker.record_failure(provider)
          end)
        end

      Enum.each(tasks, &Task.await/1)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      # Should have recorded all failures (circuit still closed)
      assert state.failure_count == num_failures
      assert state.circuit_state == :closed
    end
  end

  describe "concurrent success/failure mixed" do
    test "handles interleaved successes and failures", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 10, recovery_timeout: 5000}
      )

      # Spawn tasks that alternate between success and failure
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              CircuitBreaker.record_success(provider)
            else
              CircuitBreaker.record_failure(provider)
            end
          end)
        end

      Enum.each(tasks, &Task.await/1)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      # With 10 successes resetting failure count, circuit should stay closed
      assert state.circuit_state == :closed
    end
  end

  describe "concurrent dispatch under load" do
    test "multiple concurrent dispatches respect circuit state", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 1000, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      # First, record enough failures to open the circuit
      for _ <- 1..3 do
        CircuitBreaker.record_failure(provider)
      end

      Process.sleep(20)

      # Now dispatch 10 concurrent requests - all should fail with circuit_open
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All requests should be rejected
      assert Enum.all?(results, &match?({:error, :circuit_open}, &1))
    end

    test "concurrent successful requests don't interfere with each other", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 1000, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 100})

      # Increase concurrency cap to allow all requests (default is 10)
      CallDispatcher.set_concurrency_cap(provider, 50)

      # Dispatch 20 concurrent successful requests
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              # Small random delay to introduce timing variation
              Process.sleep(:rand.uniform(5))
              {:ok, "result_#{i}"}
            end)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end
  end

  describe "half-open state under concurrent access" do
    test "only allows limited requests through in half-open state", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 50}
      )
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 1000, max_tokens: 100})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)

      # Wait for half-open
      Process.sleep(60)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Now try 10 concurrent requests in half-open state
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn ->
              Agent.update(counter, &(&1 + 1))
              {:ok, "success"}
            end)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      Process.sleep(20)

      executed_count = Agent.get(counter, & &1)
      Agent.stop(counter)

      # In half-open, some requests should succeed
      success_count = Enum.count(results, &match?({:ok, _}, &1))
      assert success_count > 0

      # The executed count should match the success count
      assert executed_count == success_count
    end

    test "failure in half-open state immediately reopens circuit", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 50}
      )
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 1000, max_tokens: 100})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      # Wait for half-open
      Process.sleep(60)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Record a failure - should reopen circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end
  end

  describe "race condition: opening circuit during dispatch" do
    test "handles circuit opening mid-dispatch gracefully", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 1000, max_tokens: 100})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      # Track how many requests actually executed
      {:ok, executed} = Agent.start_link(fn -> 0 end)
      parent = self()

      # Start a slow request
      slow_task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :slow_started)
            Process.sleep(100)
            Agent.update(executed, &(&1 + 1))
            {:ok, "slow_done"}
          end)
        end)

      # Wait for slow request to start
      assert_receive :slow_started, 1000

      # While slow request is running, open the circuit
      for _ <- 1..3 do
        CircuitBreaker.record_failure(provider)
      end

      Process.sleep(20)
      assert CircuitBreaker.is_open?(provider)

      # Try another request - should be rejected
      result = CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end)
      assert {:error, :circuit_open} = result

      # The slow request should still complete (it started before circuit opened)
      slow_result = Task.await(slow_task, 500)
      assert {:ok, "slow_done"} = slow_result

      Agent.stop(executed)
    end
  end

  describe "state consistency" do
    test "get_state returns consistent snapshot under load", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 50, recovery_timeout: 5000}
      )

      # Spawn tasks that read and write state concurrently
      writer_tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            CircuitBreaker.record_failure(provider)
          end)
        end

      reader_tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            {:ok, state} = CircuitBreaker.get_state(provider)
            state
          end)
        end

      # Wait for writers
      Enum.each(writer_tasks, &Task.await/1)

      # Get reader results
      states = Enum.map(reader_tasks, &Task.await/1)

      # All states should be valid (have required keys)
      assert Enum.all?(states, fn state ->
               Map.has_key?(state, :circuit_state) and
                 Map.has_key?(state, :failure_count) and
                 is_integer(state.failure_count) and
                 state.failure_count >= 0
             end)
    end
  end
end
