defmodule LemonCore.RetryTest do
  use ExUnit.Case, async: true

  alias LemonCore.Retry
  alias LemonCore.Retry.Policy

  test "attempt count includes initial delivery" do
    policy = Retry.policy(max_attempts: 4)
    assert %Policy{} = policy
    assert Enum.map(0..4, &Retry.retry_allowed?(&1, policy)) == [true, true, true, false, false]
  end

  test "delay stops at the total attempt budget even with a server hint" do
    policy = Retry.policy(max_attempts: 4, base_delay_ms: 1_000, jitter: :none)

    assert Enum.map(0..4, &Retry.delay(policy, &1)) ==
             [1_000, 2_000, 4_000, :give_up, :give_up]

    assert Retry.delay(policy, 2, 7_000) == 7_000
    assert Retry.delay(policy, 3, 0) == :give_up
    assert Retry.delay(policy, 3, 7_000) == :give_up
    assert Retry.delay(%{policy | max_attempts: 1}, 0) == :give_up

    exhausted = %{policy | jitter: :equal, jitter_fun: fn _ -> flunk("exhausted jitter") end}
    assert Retry.delay(exhausted, 3) == :give_up
  end

  test "raw fixed, exponential and fractional backoffs are independent of attempt budgets" do
    fixed = Retry.policy(base_delay_ms: 30_000, max_delay_ms: 30_000, jitter: :none)
    assert Retry.backoff_delay_ms(0, fixed) == 30_000
    assert Retry.backoff_delay_ms(12, fixed) == 30_000

    reconnect =
      Retry.policy(base_delay_ms: 1_000, max_delay_ms: 10_000, factor: 1.8, jitter: :none)

    assert Retry.backoff_delay_ms(2, reconnect) == 3_240
    assert Retry.backoff_delay_ms(20, reconnect) == 10_000
  end

  test "capped_backoff preserves arbitrary attempt and timing options" do
    assert Retry.capped_backoff(500, 2, 10_000) == 2_000
    assert Retry.capped_backoff(500, 10, 10_000) == 10_000
    assert Retry.capped_backoff(1_000, 2, 10_000, factor: 1.8) == 3_240
    assert Retry.capped_backoff(500, 10, 10_000, jitter: 0.25) in 7_500..12_500
  end

  test "injected jitter and server hints obey bounded policy" do
    policy = Retry.policy(base_delay_ms: 1_000, max_delay_ms: 8_000, jitter_fun: fn n -> n end)
    assert Retry.delay(policy, 0) == 1_000
    assert Retry.backoff_delay_ms(9, policy) == 8_000
    assert Retry.delay(policy, 0, 7_000) == 7_000
    assert Retry.delay(policy, 0, 8_001) == :give_up

    symmetric = %{policy | jitter: :symmetric, jitter_fraction: 0.25}
    assert Retry.delay(symmetric, 0) == 1_250
  end

  test "durable delivery may retain uncapped historical server hints" do
    policy =
      Retry.policy(
        max_attempts: 4,
        max_delay_ms: :infinity,
        max_retry_after_ms: :infinity,
        jitter: :none
      )

    assert Retry.delay(policy, 0, 100_000_000) == 100_000_000
    assert Retry.delay(policy, 2) == 2_000
  end
end
