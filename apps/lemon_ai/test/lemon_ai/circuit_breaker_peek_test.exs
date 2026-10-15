defmodule LemonAi.CircuitBreakerPeekTest do
  use ExUnit.Case, async: true

  alias LemonAi.CircuitBreaker

  test "peek reports closed and half-open snapshots without changing state" do
    provider = "peek-#{System.unique_integer([:positive])}"
    assert :not_started = CircuitBreaker.peek(provider)
    pid = start_supervised!({CircuitBreaker, provider: provider})

    assert {:ok, %{state: :closed, failure_count: 0, time_until_recovery_ms: 0}} =
             CircuitBreaker.peek(provider)

    :sys.replace_state(pid, &%{&1 | circuit_state: :half_open, failure_count: 5})

    assert {:ok, %{state: :half_open, failure_count: 5, time_until_recovery_ms: 0}} =
             CircuitBreaker.peek(provider)

    assert :sys.get_state(pid).circuit_state == :half_open
  end

  test "string status identifiers find existing atom-keyed breakers" do
    start_supervised!({CircuitBreaker, provider: :circuit_peek_atom_test})
    assert {:ok, %{state: :closed}} = CircuitBreaker.peek("circuit_peek_atom_test")
  end
end
