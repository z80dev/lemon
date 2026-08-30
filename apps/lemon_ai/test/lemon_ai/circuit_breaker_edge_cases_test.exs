defmodule LemonAi.CircuitBreakerEdgeCasesTest do
  @moduledoc """
  Edge case and advanced scenario tests for LemonAi.CircuitBreaker.

  Tests cover:
  - Half-open state recovery with success count reset
  - Rapid state transitions (open -> half-open -> open)
  - Success threshold in half-open state
  - Timing precision for recovery timeout
  - Custom failure thresholds
  - Manual reset during different states
  - Telemetry event emission
  """
  use ExUnit.Case, async: false

  alias LemonAi.CircuitBreaker

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"edge_case_provider_#{test_id}"
    {:ok, provider: provider}
  end

  @doc false
  def handle_telemetry([:lemon_ai, :circuit_breaker, event], measurements, metadata, test_pid) do
    send(test_pid, {:circuit_breaker_telemetry, event, measurements, metadata})
  end

  # ============================================================================
  # Half-open State Recovery with Success Count Reset
  # ============================================================================

  describe "half-open state recovery with success count reset" do
    test "success count resets when transitioning from open to half-open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open the circuit
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # First success should be counted towards threshold
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      # Still half-open because we need 2 successes
      assert state.circuit_state == :half_open
    end

    test "success count in half-open resets after failure and re-entering half-open", %{
      provider: provider
    } do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 30)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # One success (not enough to close)
      CircuitBreaker.record_success(provider)

      # Failure reopens
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(30)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Now we need 2 full successes again, not just 1
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "multiple cycles through half-open always require full success threshold", %{
      provider: provider
    } do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 25)

      # Perform 3 cycles of: closed -> open -> half-open (fail) -> open -> half-open (success) -> closed
      for cycle <- 1..3 do
        # Open the circuit
        CircuitBreaker.record_failure(provider)
        advance.(25)

        {:ok, state} = CircuitBreaker.get_state(provider)

        assert state.circuit_state == :half_open,
               "Cycle #{cycle}: Expected half-open after timeout"

        # Get 2 successes to close
        CircuitBreaker.record_success(provider)
        CircuitBreaker.record_success(provider)

        {:ok, state} = CircuitBreaker.get_state(provider)
        assert state.circuit_state == :closed, "Cycle #{cycle}: Expected closed after 2 successes"
      end
    end
  end

  # ============================================================================
  # Rapid State Transitions (open -> half-open -> open)
  # ============================================================================

  describe "rapid state transitions (open -> half-open -> open)" do
    test "immediate failure in half-open returns to open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 200)

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)

      advance.(200)
      assert_state(provider, :half_open)

      # Immediately record failure
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)
    end

    test "rapid open -> half-open -> open -> half-open -> closed cycle", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 200)

      # Open
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)

      # Wait for half-open
      advance.(200)
      assert_state(provider, :half_open)

      # Fail -> back to open
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)

      # Wait for half-open again
      advance.(200)
      assert_state(provider, :half_open)

      # Now succeed twice -> closed
      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)
      assert_state(provider, :closed)
    end

    test "failure after one success in half-open resets to open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 200)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)
      advance.(200)
      assert_state(provider, :half_open)

      # One success (not enough)
      CircuitBreaker.record_success(provider)
      assert_state(provider, :half_open)

      # Then failure -> reopen
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)
    end

    test "multiple rapid failures in half-open keep circuit open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 200)

      for _ <- 1..3 do
        # Open the circuit
        CircuitBreaker.record_failure(provider)

        advance.(200)

        {:ok, state} = CircuitBreaker.get_state(provider)
        assert state.circuit_state == :half_open

        # Fail again - back to open
        CircuitBreaker.record_failure(provider)

        {:ok, state} = CircuitBreaker.get_state(provider)
        assert state.circuit_state == :open
      end
    end
  end

  # ============================================================================
  # Success Threshold in Half-Open State
  # ============================================================================

  describe "success threshold in half-open state" do
    test "requires exactly 2 successes to close circuit", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(20)

      # First success
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Second success closes circuit
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "single success in half-open is not enough to close", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(20)

      # One success
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
      refute CircuitBreaker.open?(provider)
    end

    test "extra successes after threshold are harmless in closed state", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      # Open -> half-open -> closed
      CircuitBreaker.record_failure(provider)
      advance.(20)

      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      # Record many more successes
      for _ <- 1..10 do
        CircuitBreaker.record_success(provider)
      end

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "interleaved success-failure-success in half-open reopens circuit", %{
      provider: provider
    } do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(20)

      # Success, then failure, then success
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end
  end

  # ============================================================================
  # Timing Precision for Recovery Timeout
  # ============================================================================

  describe "timing precision for recovery timeout" do
    test "circuit stays open just before timeout expires", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 1_000)

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(999)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "circuit transitions to half-open right after timeout", %{provider: provider} do
      recovery_timeout = 200

      advance =
        start_with_clock(provider,
          failure_threshold: 1,
          recovery_timeout: recovery_timeout
        )

      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)
      advance.(recovery_timeout)
      assert_state(provider, :half_open)
    end

    test "additional failures extend the recovery timeout", %{provider: provider} do
      recovery_timeout = 1_000

      advance =
        start_with_clock(provider,
          failure_threshold: 1,
          recovery_timeout: recovery_timeout
        )

      # Open circuit
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)

      # Wait, but not long enough for recovery.
      advance.(800)

      # Record another failure (resets timeout)
      CircuitBreaker.record_failure(provider)

      # Wait long enough that we'd have recovered if the timer wasn't reset.
      advance.(500)

      # Should still be open because timeout restarted
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      advance.(500)
      assert_state(provider, :half_open)
    end

    test "very short recovery timeout (1ms) transitions quickly", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 1)

      CircuitBreaker.record_failure(provider)
      advance.(1)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "long recovery timeout keeps circuit open", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 10_000)

      CircuitBreaker.record_failure(provider)

      # Check multiple times over a short period
      for _ <- 1..5 do
        advance.(20)

        {:ok, state} = CircuitBreaker.get_state(provider)
        assert state.circuit_state == :open
      end
    end
  end

  # ============================================================================
  # Custom Failure Thresholds
  # ============================================================================

  describe "custom failure thresholds" do
    test "threshold of 1 opens circuit on first failure", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "threshold of 10 requires 10 failures", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 10})

      # 9 failures - still closed
      for _ <- 1..9 do
        CircuitBreaker.record_failure(provider)
      end

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 9

      # 10th failure opens circuit
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
      assert state.failure_count >= 10
    end

    test "high threshold with intermittent successes stays closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Pattern: 4 failures, 1 success (resets), repeat
      for _ <- 1..3 do
        for _ <- 1..4 do
          CircuitBreaker.record_failure(provider)
        end

        CircuitBreaker.record_success(provider)
      end

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      # Failure count should be 0 due to success reset
      assert state.failure_count == 0
    end

    test "different thresholds for different providers", %{provider: _provider} do
      test_id = System.unique_integer([:positive])
      provider_low = :"threshold_low_#{test_id}"
      provider_high = :"threshold_high_#{test_id}"

      start_supervised!(
        {CircuitBreaker, provider: provider_low, failure_threshold: 2},
        id: :low_threshold_cb
      )

      start_supervised!(
        {CircuitBreaker, provider: provider_high, failure_threshold: 5},
        id: :high_threshold_cb
      )

      # Both get 2 failures
      for _ <- 1..2 do
        CircuitBreaker.record_failure(provider_low)
        CircuitBreaker.record_failure(provider_high)
      end

      {:ok, state_low} = CircuitBreaker.get_state(provider_low)
      {:ok, state_high} = CircuitBreaker.get_state(provider_high)

      # Low threshold provider is open
      assert state_low.circuit_state == :open

      # High threshold provider is still closed
      assert state_high.circuit_state == :closed
      assert state_high.failure_count == 2
    end

    test "failure threshold equals failure count exactly when opening", %{provider: provider} do
      threshold = 3
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: threshold})

      for i <- 1..threshold do
        CircuitBreaker.record_failure(provider)

        {:ok, state} = CircuitBreaker.get_state(provider)

        if i < threshold do
          assert state.circuit_state == :closed
          assert state.failure_count == i
        else
          assert state.circuit_state == :open
          assert state.failure_count == threshold
        end
      end
    end
  end

  # ============================================================================
  # Manual Reset During Different States
  # ============================================================================

  describe "manual reset during different states" do
    test "reset from closed state clears failure count", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 10})

      # Accumulate some failures
      for _ <- 1..5 do
        CircuitBreaker.record_failure(provider)
      end

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 5

      # Reset
      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "reset from open state returns to closed", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "reset from half-open state returns to closed", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      CircuitBreaker.record_failure(provider)
      advance.(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 0
    end

    test "reset during half-open clears success count", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      # Open -> half-open
      CircuitBreaker.record_failure(provider)
      advance.(20)

      # One success
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Reset
      CircuitBreaker.reset(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed

      # Now open and half-open again - should need 2 full successes
      CircuitBreaker.record_failure(provider)
      advance.(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # One success is not enough
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Second success closes it
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "reset is idempotent", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)

      # Multiple resets
      for _ <- 1..5 do
        CircuitBreaker.reset(provider)

        {:ok, state} = CircuitBreaker.get_state(provider)
        assert state.circuit_state == :closed
        assert state.failure_count == 0
      end
    end

    test "reset after open? check works correctly", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 1})

      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.open?(provider)

      CircuitBreaker.reset(provider)

      refute CircuitBreaker.open?(provider)
    end

    test "operations after reset behave as if fresh start", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 3, recovery_timeout: 50}
      )

      # Open circuit
      for _ <- 1..3 do
        CircuitBreaker.record_failure(provider)
      end

      assert CircuitBreaker.open?(provider)

      # Reset
      CircuitBreaker.reset(provider)

      # Now failures should count from 0
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
      assert state.failure_count == 1

      # Need 2 more to open
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end
  end

  # ============================================================================
  # Telemetry Event Emission
  # ============================================================================

  describe "telemetry event emission" do
    test "emits the actual lifecycle event sequence", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      attach_lifecycle_telemetry()

      CircuitBreaker.record_failure(provider, :initial_failure)

      assert_telemetry(:opened, provider, fn metadata ->
        assert metadata.reason == :initial_failure
        assert metadata.failure_count == 1
        assert metadata.failure_threshold == 1
      end)

      advance.(20)
      assert_state(provider, :half_open)

      assert_telemetry(:half_opened, provider, fn metadata ->
        assert metadata.recovery_timeout == 20
      end)

      CircuitBreaker.record_failure(provider, :probe_failure)

      assert_telemetry(:reopened, provider, fn metadata ->
        assert metadata.reason == :probe_failure
      end)

      advance.(20)
      assert_state(provider, :half_open)
      assert_telemetry(:half_opened, provider, fn _metadata -> :ok end)

      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)
      assert_telemetry(:closed, provider, fn _metadata -> :ok end)
    end
  end

  # ============================================================================
  # Additional Edge Cases
  # ============================================================================

  describe "boundary conditions" do
    test "open? returns false for half-open state", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)

      CircuitBreaker.record_failure(provider)
      advance.(20)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # open? should return false for half-open (allows probe requests)
      refute CircuitBreaker.open?(provider)
    end

    test "record_success in open state has no effect", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 1, recovery_timeout: 1000}
      )

      CircuitBreaker.record_failure(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open

      # Success should be ignored in open state
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "state consistency after multiple rapid operations", %{provider: provider} do
      start_supervised!(
        {CircuitBreaker, provider: provider, failure_threshold: 3, recovery_timeout: 100}
      )

      # Rapid alternating operations
      for _ <- 1..50 do
        CircuitBreaker.record_failure(provider)
        CircuitBreaker.record_success(provider)
        CircuitBreaker.record_failure(provider)
        CircuitBreaker.record_success(provider)
      end

      # State should be consistent
      {:ok, state} = CircuitBreaker.get_state(provider)

      assert state.circuit_state in [:closed, :open, :half_open]
      assert is_integer(state.failure_count)
      assert state.failure_count >= 0
    end

    test "closed state resets failure count on success", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 10})

      # Build up some failures
      for _ <- 1..5 do
        CircuitBreaker.record_failure(provider)
      end

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 5

      # Success resets to 0
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.failure_count == 0
    end

    test "closing from half-open resets failure count to 0", %{provider: provider} do
      advance =
        start_with_clock(provider, failure_threshold: 2, recovery_timeout: 200)

      # Open the circuit (2 failures)
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open)

      # Transition to half-open
      advance.(200)
      assert_state(provider, :half_open)

      # Close with successes
      CircuitBreaker.record_success(provider)
      CircuitBreaker.record_success(provider)

      assert {:ok, %{circuit_state: :closed, failure_count: 0}} =
               CircuitBreaker.get_state(provider)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp assert_state(provider, expected_state) do
    {:ok, state} = CircuitBreaker.get_state(provider)

    assert state.circuit_state == expected_state,
           "Expected circuit state to be #{expected_state}, got #{state.circuit_state}"
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

  defp attach_lifecycle_telemetry do
    handler_id = "circuit-breaker-lifecycle-#{System.unique_integer([:positive])}"
    test_pid = self()

    events =
      Enum.map([:opened, :half_opened, :closed, :reopened], fn event ->
        [:lemon_ai, :circuit_breaker, event]
      end)

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_telemetry(event, provider, metadata_assertion) do
    assert_receive {:circuit_breaker_telemetry, ^event, %{system_time: system_time},
                    %{provider: ^provider} = metadata}

    assert is_integer(system_time)
    metadata_assertion.(metadata)
  end
end
