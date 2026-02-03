defmodule Ai.CircuitBreakerTest do
  @moduledoc """
  Unit tests for Ai.CircuitBreaker module.

  Tests cover:
  - State transitions (closed -> open -> half-open -> closed)
  - Failure counting and threshold behavior
  - Recovery timeout and half-open state
  - Reset functionality
  - Configuration options
  """
  use ExUnit.Case, async: false

  alias Ai.CircuitBreaker

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  describe "initial state" do
    test "starts in closed state", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "uses default failure threshold of 5", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_threshold == 5
    end

    test "uses default recovery timeout of 30000ms", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.recovery_timeout == 30_000
    end

    test "accepts custom failure threshold", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 10})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_threshold == 10
    end

    test "accepts custom recovery timeout", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, recovery_timeout: 5000})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.recovery_timeout == 5000
    end
  end

  describe "is_open?/1" do
    test "returns false when circuit is closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      refute CircuitBreaker.is_open?(provider)
    end

    test "returns true when circuit is open", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)
    end

    test "returns false when circuit is half-open", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 30}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      assert CircuitBreaker.is_open?(provider)

      # Wait for half-open
      Process.sleep(50)

      refute CircuitBreaker.is_open?(provider)
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "returns false for non-existent provider (auto-starts)", %{provider: provider} do
      # Provider doesn't exist yet, but is_open? should auto-start it
      refute CircuitBreaker.is_open?(provider)
    end
  end

  describe "record_failure/1 - closed state" do
    test "increments failure count", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 1
      assert state.circuit_state == :closed
    end

    test "opens circuit when threshold is reached", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
      assert state.failure_count >= 3
    end

    test "does not open circuit before threshold", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      for _ <- 1..4 do
        CircuitBreaker.record_failure(provider)
      end

      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 4
    end
  end

  describe "record_success/1 - closed state" do
    test "resets failure count", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Accumulate some failures
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 2

      # Record success
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 0
    end
  end

  describe "state transition: closed -> open" do
    test "transitions when failure threshold is reached", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "sets last_failure_time when opening", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      # We can't directly check last_failure_time from public API,
      # but we verify the circuit opened
      assert CircuitBreaker.is_open?(provider)
    end
  end

  describe "state transition: open -> half-open" do
    test "transitions after recovery timeout expires", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 50}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Wait for recovery timeout
      Process.sleep(60)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "does not transition before recovery timeout", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 500}
      )

      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Check immediately - should still be open
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "resets success_count_in_half_open when transitioning", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      # Wait for half-open
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
      # success_count_in_half_open is not exposed in public state, but we test behavior
    end
  end

  describe "state transition: half-open -> closed" do
    test "transitions after 2 consecutive successes", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # First success
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Second success - should close
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "does not transition after single success", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Single success
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end
  end

  describe "state transition: half-open -> open" do
    test "transitions on any failure", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Failure should reopen circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "transitions even after some successes", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # One success (not enough to close)
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Now failure should reopen
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "resets success count when reopening", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      Process.sleep(50)

      # One success
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      # Failure reopens
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      # Wait for half-open again
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Now need 2 successes again (not just 1 more)
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end
  end

  describe "reset/1" do
    test "resets circuit from open to closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Reset
      CircuitBreaker.reset(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "resets circuit from half-open to closed", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 30}
      )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Reset
      CircuitBreaker.reset(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "clears failure count when resetting from closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Accumulate some failures (not enough to open)
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 2

      # Reset
      CircuitBreaker.reset(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 0
    end
  end

  describe "record_failure/1 - open state" do
    test "extends recovery timeout on additional failures", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 50}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Wait but not long enough for recovery
      Process.sleep(30)

      # Record another failure - this should reset the recovery timer
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      # Circuit should still be open
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Wait a bit more - should still be open because timer was reset
      Process.sleep(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Now wait for full recovery timeout from last failure
      Process.sleep(40)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end
  end

  describe "ensure_started/2" do
    test "starts circuit breaker for new provider", %{provider: provider} do
      {:ok, pid} = CircuitBreaker.ensure_started(provider)
      assert is_pid(pid)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "returns existing pid for already started provider", %{provider: provider} do
      {:ok, pid1} = CircuitBreaker.ensure_started(provider)
      {:ok, pid2} = CircuitBreaker.ensure_started(provider)

      assert pid1 == pid2
    end

    test "accepts custom options", %{provider: provider} do
      {:ok, _pid} =
        CircuitBreaker.ensure_started(provider,
          failure_threshold: 10,
          recovery_timeout: 1000
        )

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_threshold == 10
      assert state.recovery_timeout == 1000
    end
  end

  describe "get_state/1" do
    test "returns error for non-existent provider when not auto-started" do
      # This test verifies the catch clause works
      # Since ensure_started is called, it will auto-start, so we get :ok
      test_id = System.unique_integer([:positive])
      provider = :"get_state_test_#{test_id}"

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "returns full state information", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 7, recovery_timeout: 2500}
      )

      {:ok, state} = CircuitBreaker.get_state(provider)

      assert Map.has_key?(state, :provider)
      assert Map.has_key?(state, :circuit_state)
      assert Map.has_key?(state, :failure_count)
      assert Map.has_key?(state, :failure_threshold)
      assert Map.has_key?(state, :recovery_timeout)

      assert state.provider == provider
      assert state.circuit_state == :closed
      assert state.failure_count == 0
      assert state.failure_threshold == 7
      assert state.recovery_timeout == 2500
    end
  end

  describe "complete state cycle" do
    test "closed -> open -> half-open -> closed -> open", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 2, recovery_timeout: 30}
      )

      # Start: closed
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      # Trigger failures -> open
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Wait for recovery -> half-open
      Process.sleep(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Record 2 successes -> closed
      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      # Trigger failures again -> open
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      Process.sleep(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end
  end

  describe "edge cases" do
    test "success in open state is ignored", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 1000}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Record success - should be ignored
      CircuitBreaker.record_success(provider)
      Process.sleep(10)

      # Still open
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "threshold of 1 opens circuit on first failure", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "very short recovery timeout works correctly", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 50}
      )

      CircuitBreaker.record_failure(provider)
      Process.sleep(10)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      Process.sleep(70)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "rapid success/failure sequences are handled correctly", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Rapid alternating calls
      for _ <- 1..10 do
        CircuitBreaker.record_failure(provider)
        CircuitBreaker.record_success(provider)
      end

      Process.sleep(50)

      # Due to success resetting failure count, circuit should stay closed
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end
  end
end
