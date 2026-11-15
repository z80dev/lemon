defmodule LemonAi.CircuitBreakerPeekTest do
  use ExUnit.Case, async: true

  alias LemonAi.CircuitBreaker

  test "peek reports closed and half-open snapshots without changing state" do
    provider = "peek-#{System.unique_integer([:positive])}"
    assert :not_started = CircuitBreaker.peek(provider)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    pid =
      start_supervised!(
        {CircuitBreaker,
         provider: provider,
         failure_threshold: 1,
         recovery_timeout: 10,
         monotonic_time: fn -> Agent.get(clock, & &1) end}
      )

    assert {:ok, %{state: :closed, failure_count: 0, time_until_recovery_ms: 0}} =
             CircuitBreaker.peek(provider)

    CircuitBreaker.record_failure(provider)
    Agent.update(clock, fn _ -> 10 end)
    assert {:ok, %{circuit_state: :half_open}} = CircuitBreaker.get_state(provider)

    assert {:ok, %{state: :half_open, failure_count: 1, time_until_recovery_ms: 0}} =
             CircuitBreaker.peek(provider)

    assert :sys.get_state(pid).circuit_state == :half_open
  end

  test "string status identifiers find existing atom-keyed breakers" do
    start_supervised!({CircuitBreaker, provider: :circuit_peek_atom_test})
    assert {:ok, %{state: :closed}} = CircuitBreaker.peek("circuit_peek_atom_test")
  end

  test "admission and status reads do not call a suspended breaker" do
    provider = "ets-breaker-#{System.unique_integer([:positive])}"
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    pid =
      start_supervised!(
        {CircuitBreaker,
         provider: provider,
         failure_threshold: 1,
         recovery_timeout: 100,
         monotonic_time: fn -> Agent.get(clock, & &1) end}
      )

    :ok = CircuitBreaker.record_failure(provider)
    :ok = :sys.suspend(pid)

    try do
      assert CircuitBreaker.open?(provider)
      assert CircuitBreaker.time_until_recovery(provider) == 100
      assert {:ok, %{state: :open, failure_count: 1}} = CircuitBreaker.peek(provider)
      Agent.update(clock, fn _ -> 100 end)
      refute CircuitBreaker.open?(provider)
      assert CircuitBreaker.time_until_recovery(provider) == 0
    after
      :sys.resume(pid)
    end

    :ok = CircuitBreaker.reset(provider)
    refute CircuitBreaker.open?(provider)
    assert {:ok, %{state: :closed, failure_count: 0}} = CircuitBreaker.peek(provider)
  end
end
