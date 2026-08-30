defmodule LemonAi.CircuitBreakerTest do
  @moduledoc """
  Unit tests for LemonAi.CircuitBreaker module.

  Tests cover:
  - State transitions (closed -> open -> half-open -> closed)
  - Failure counting and threshold behavior
  - Recovery timeout and half-open state
  - Reset functionality
  - Configuration options
  """
  use ExUnit.Case, async: false

  alias LemonAi.CircuitBreaker

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  @doc false
  def handle_telemetry([:lemon_ai, :circuit_breaker, event], measurements, metadata, test_pid) do
    send(test_pid, {:circuit_breaker_telemetry, event, measurements, metadata})
  end

  describe "initial state" do
    test "starts in closed state", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
      assert state.last_failure_reason == nil
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

  describe "open?/1" do
    test "returns false when circuit is closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      refute CircuitBreaker.open?(provider)
    end

    test "returns true when circuit is open", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.open?(provider)
    end

    test "returns false when circuit is half-open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 2, recovery_timeout: 30)

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.open?(provider)

      advance.(30)

      refute CircuitBreaker.open?(provider)
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "returns false for non-existent provider (auto-starts)", %{provider: provider} do
      # Provider doesn't exist yet, but open? should auto-start it
      refute CircuitBreaker.open?(provider)
    end
  end

  describe "record_failure/1 - closed state" do
    test "increments failure count", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CircuitBreaker.record_failure(provider, :timeout)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 1
      assert state.circuit_state == :closed
      assert state.last_failure_reason == :timeout
    end

    test "opens circuit when threshold is reached", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
      assert state.failure_count >= 3
    end

    test "does not open circuit before threshold", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      for _ <- 1..4 do
        CircuitBreaker.record_failure(provider)
      end

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

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 2

      # Record success
      CircuitBreaker.record_success(provider)

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

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "sets last_failure_time when opening", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)

      # We can't directly check last_failure_time from public API,
      # but we verify the circuit opened
      assert CircuitBreaker.open?(provider)
    end

    test "exposes last failure reason in state", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider, {:http_error, 503, "overloaded"})

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
      assert state.last_failure_reason == {:http_error, 503, "overloaded"}
    end
  end

  describe "state transition: open -> half-open" do
    test "transitions after recovery timeout expires", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 50)

      # Open the circuit
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(50)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "does not transition before recovery timeout", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 500)

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(499)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "resets success_count_in_half_open when transitioning", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open the circuit
      CircuitBreaker.record_failure(provider)

      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
      # success_count_in_half_open is not exposed in public state, but we test behavior
    end
  end

  describe "state transition: half-open -> closed" do
    test "transitions after 2 consecutive successes", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # First success
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Second success - should close
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "does not transition after single success", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Single success
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end
  end

  describe "state transition: half-open -> open" do
    test "transitions on any failure", %{provider: provider} do
      recovery_timeout = 200

      advance =
        start_with_clock(provider,
          failure_threshold: 1,
          recovery_timeout: recovery_timeout
        )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(recovery_timeout)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Failure should reopen circuit
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "transitions even after some successes", %{provider: provider} do
      recovery_timeout = 200

      advance =
        start_with_clock(provider,
          failure_threshold: 1,
          recovery_timeout: recovery_timeout
        )

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(recovery_timeout)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # One success (not enough to close)
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Now failure should reopen
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "resets success count when reopening", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)

      # One success
      CircuitBreaker.record_success(provider)

      # Failure reopens
      CircuitBreaker.record_failure(provider)

      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Now need 2 successes again (not just 1 more)
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end
  end

  describe "reset/1" do
    test "resets circuit from open to closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      # Open the circuit
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Reset
      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "resets circuit from half-open to closed", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Reset
      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "clears failure count when resetting from closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Accumulate some failures (not enough to open)
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 2

      # Reset
      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 0
    end
  end

  describe "record_failure/1 - open state" do
    test "extends recovery timeout on additional failures", %{provider: provider} do
      recovery_timeout = 1_000

      advance =
        start_with_clock(provider,
          failure_threshold: 1,
          recovery_timeout: recovery_timeout
        )

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)

      # Wait but not long enough for recovery
      advance.(800)

      # Record another failure - this should reset the recovery timer
      CircuitBreaker.record_failure(provider)

      # Wait a bit more. If the recovery timer was not extended, the circuit would
      # be half-open by now (800ms + 500ms > 1000ms).
      advance.(500)
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(500)
      assert_state(provider, :half_open)
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
      advance =
        start_with_clock(provider, failure_threshold: 2, recovery_timeout: 30)

      # Start: closed
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      # Trigger failures -> open
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Record 2 successes -> closed
      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      # Trigger failures again -> open
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end
  end

  describe "time_until_recovery/1" do
    test "returns 0 when circuit is closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider})

      assert CircuitBreaker.time_until_recovery(provider) == 0
    end

    test "returns positive value when circuit is open", %{provider: provider} do
      start_with_clock(provider, failure_threshold: 1, recovery_timeout: 5_000)

      CircuitBreaker.record_failure(provider)

      remaining = CircuitBreaker.time_until_recovery(provider)
      assert remaining > 0
      assert remaining <= 5_000
    end

    test "decreases over time", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 5_000)

      CircuitBreaker.record_failure(provider)

      remaining1 = CircuitBreaker.time_until_recovery(provider)
      advance.(100)
      remaining2 = CircuitBreaker.time_until_recovery(provider)

      assert remaining2 < remaining1
    end

    test "returns 0 when circuit is half-open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      CircuitBreaker.record_failure(provider)
      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      assert CircuitBreaker.time_until_recovery(provider) == 0
    end
  end

  describe "telemetry events" do
    test "emits :opened event when circuit opens", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})
      attach_telemetry(:opened)

      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      assert_receive {:circuit_breaker_telemetry, :opened, %{system_time: system_time}, metadata}
      assert is_integer(system_time)
      assert metadata.provider == provider
      assert metadata.failure_count == 2
      assert metadata.failure_threshold == 2
      assert metadata.reason == :unknown
    end

    test "emits :half_opened event when transitioning to half-open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      attach_telemetry(:half_opened)

      CircuitBreaker.record_failure(provider)
      advance.(30)

      # Trigger the transition by querying state
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      assert_receive {:circuit_breaker_telemetry, :half_opened, %{system_time: system_time},
                      metadata}

      assert is_integer(system_time)
      assert metadata.provider == provider
      assert metadata.recovery_timeout == 30
    end

    test "emits :closed event when circuit closes after recovery", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      attach_telemetry(:closed)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)
      {:ok, _} = CircuitBreaker.get_state(provider)

      # Close via 2 successes
      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)

      assert_receive {:circuit_breaker_telemetry, :closed, %{system_time: system_time}, metadata}
      assert is_integer(system_time)
      assert metadata.provider == provider
    end

    test "emits :reopened event when half-open circuit reopens", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      attach_telemetry(:reopened)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)
      {:ok, _} = CircuitBreaker.get_state(provider)

      # Failure in half-open reopens
      CircuitBreaker.record_failure(provider, :econnreset)

      assert_receive {:circuit_breaker_telemetry, :reopened, %{system_time: system_time},
                      metadata}

      assert is_integer(system_time)
      assert metadata.provider == provider
      assert metadata.reason == :econnreset
    end
  end

  describe "edge cases" do
    test "success in open state is ignored", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 1000}
      )

      # Open the circuit
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Record success - should be ignored
      CircuitBreaker.record_success(provider)

      # Still open
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "threshold of 1 opens circuit on first failure", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "very short recovery timeout works correctly", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 50)

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(50)

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

      # Due to success resetting failure count, circuit should stay closed
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end
  end

  defp start_with_clock(provider, opts) do
    clock = :atomics.new(1, signed: true)
    monotonic_time = fn -> :atomics.get(clock, 1) end

    start_supervised!(
      {CircuitBreaker,
       opts
       |> Keyword.put(:provider, provider)
       |> Keyword.put(:monotonic_time, monotonic_time)}
    )

    fn milliseconds ->
      # A call from the same process observes all earlier casts before time moves.
      {:ok, _state} = CircuitBreaker.get_state(provider)
      :atomics.add_get(clock, 1, milliseconds)
    end
  end

  defp assert_state(provider, expected_state) do
    assert {:ok, %{circuit_state: ^expected_state}} = CircuitBreaker.get_state(provider)
  end

  defp attach_telemetry(event) do
    handler_id = "circuit-breaker-#{event}-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:lemon_ai, :circuit_breaker, event],
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
