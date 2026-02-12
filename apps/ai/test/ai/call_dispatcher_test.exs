defmodule Ai.CallDispatcherTest do
  use ExUnit.Case, async: false

  alias Ai.CallDispatcher
  alias Ai.RateLimiter
  alias Ai.CircuitBreaker
  alias Ai.EventStream

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  describe "Ai.CallDispatcher" do
    test "dispatch allows requests when conditions are met", %{provider: provider} do
      # Start rate limiter and circuit breaker for this provider
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10, max_tokens: 5})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "success"} end)

      assert {:ok, "success"} = result
    end

    test "dispatch rejects when circuit is open", %{provider: provider} do
      # Start rate limiter and circuit breaker
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10, max_tokens: 5})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Record enough failures to open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      # Give time for the casts to be processed
      Process.sleep(10)

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end)

      assert {:error, :circuit_open} = result
    end

    test "dispatch rejects when rate limited", %{provider: provider} do
      # Start rate limiter with only 1 token and no refill
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # First request should succeed
      assert {:ok, _} = CallDispatcher.dispatch(provider, fn -> {:ok, "first"} end)

      # Second request should be rate limited (no tokens left)
      result = CallDispatcher.dispatch(provider, fn -> {:ok, "second"} end)

      assert {:error, :rate_limited} = result
    end

    test "dispatch enforces concurrency cap", %{provider: provider} do
      # Start rate limiter and circuit breaker
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Set concurrency cap to 1
      CallDispatcher.set_concurrency_cap(provider, 1)

      # Start a long-running request that holds the slot
      parent = self()

      task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :slot_acquired)
            # Hold the slot for a while
            receive do
              :release -> {:ok, "done"}
            end
          end)
        end)

      # Wait for the first request to acquire the slot
      assert_receive :slot_acquired, 1000

      # Second request should be rejected due to max concurrency
      result = CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end)
      assert {:error, :max_concurrency} = result

      # Release the first request
      send(task.pid, :release)
      Task.await(task)
    end

    test "dispatcher releases slot if caller is killed", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      pid =
        spawn(fn ->
          CallDispatcher.dispatch(provider, fn ->
            Process.sleep(:infinity)
          end)
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      # :kill ensures the caller's `after` cleanup does not run.
      Process.exit(pid, :kill)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      assert {:ok, "ok"} = CallDispatcher.dispatch(provider, fn -> {:ok, "ok"} end)
    end

    test "stream dispatch keeps slot occupied until stream terminal result", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "blocked"} end)

      EventStream.complete(stream, %{stop_reason: :end_turn, content: []})

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      assert {:ok, "after_stream"} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "after_stream"} end)
    end

    test "stream terminal error is recorded as circuit breaker failure", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      {:ok, cb_before} = CircuitBreaker.get_state(provider)
      assert cb_before.failure_count == 0

      EventStream.error(stream, %{
        stop_reason: :error,
        error_message: "stream failed",
        content: []
      })

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      wait_until(fn ->
        {:ok, state} = CircuitBreaker.get_state(provider)
        state.failure_count == 1
      end)
    end

    test "set_concurrency_cap works correctly", %{provider: provider} do
      # Default cap is 10
      assert 10 = CallDispatcher.get_concurrency_cap(provider)

      # Set a new cap
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 5)
      assert 5 = CallDispatcher.get_concurrency_cap(provider)

      # Set another value
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 20)
      assert 20 = CallDispatcher.get_concurrency_cap(provider)
    end
  end

  describe "Ai.RateLimiter" do
    test "acquire allows requests when tokens available", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10, max_tokens: 5})

      # Should allow multiple requests up to max_tokens
      assert :ok = RateLimiter.acquire(provider)
      assert :ok = RateLimiter.acquire(provider)
      assert :ok = RateLimiter.acquire(provider)
    end

    test "acquire rejects when bucket is empty", %{provider: provider} do
      # Start with only 2 tokens and no refill
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 2})

      # Use up all tokens
      assert :ok = RateLimiter.acquire(provider)
      assert :ok = RateLimiter.acquire(provider)

      # Should be rate limited now
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)
    end

    test "tokens refill over time", %{provider: provider} do
      # Start with 1 token, refill rate of 100 per second
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 5})

      # Use the initial tokens
      for _ <- 1..5 do
        assert :ok = RateLimiter.acquire(provider)
      end

      # Should be empty
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)

      # Wait for tokens to refill (100/s = 1 token every 10ms)
      Process.sleep(50)

      # Should have tokens again
      assert :ok = RateLimiter.acquire(provider)
    end
  end

  describe "Ai.CircuitBreaker" do
    test "starts in closed state", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Circuit should be closed (not open)
      refute CircuitBreaker.is_open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "opens after threshold failures", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      # Circuit should start closed
      refute CircuitBreaker.is_open?(provider)

      # Record failures
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      # Still closed (only 2 failures)
      refute CircuitBreaker.is_open?(provider)

      # Third failure should open the circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      assert CircuitBreaker.is_open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "transitions to half_open after timeout", %{provider: provider} do
      # Use a short (but not too short) recovery timeout to avoid timing flakes
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 200}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)

      # Wait for recovery timeout
      Process.sleep(220)

      # Should transition to half_open (not open)
      refute CircuitBreaker.is_open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "closes after successful requests in half_open", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 200}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)

      # Wait for half_open
      Process.sleep(220)

      refute CircuitBreaker.is_open?(provider)
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Record successful requests (need 2 for half_open_success_threshold)
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      # Should be closed now
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end
  end

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
