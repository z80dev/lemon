defmodule LemonChannels.OutboxRateLimitingTest do
  @moduledoc """
  RateLimiter.consume atomically checks and decrements tokens, check is
  read-only, and an exhausted bucket answers with a positive wait.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Outbox.RateLimiter

  setup do
    # Start the RateLimiter if not running
    case Process.whereis(RateLimiter) do
      nil ->
        {:ok, pid} = RateLimiter.start_link([])

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

        {:ok, rate_limiter_pid: pid}

      pid ->
        {:ok, rate_limiter_pid: pid}
    end
  end

  test "check does not consume tokens" do
    channel = "check-no-consume-#{System.unique_integer([:positive])}"
    account = "account-1"

    # Get initial status
    status1 = RateLimiter.status(channel, account)
    initial_tokens = status1.tokens

    # Check multiple times
    :ok = RateLimiter.check(channel, account)
    :ok = RateLimiter.check(channel, account)
    :ok = RateLimiter.check(channel, account)

    # Tokens should not have decreased (check doesn't consume)
    status2 = RateLimiter.status(channel, account)
    # Note: tokens may have increased slightly due to refill, but shouldn't be less
    assert status2.tokens >= initial_tokens - 0.1
  end

  test "consume is atomic - multiple calls decrement multiple tokens" do
    channel = "atomic-consume-#{System.unique_integer([:positive])}"
    account = "account-1"

    # Get initial status (fresh bucket has burst tokens)
    status1 = RateLimiter.status(channel, account)
    initial_tokens = status1.tokens

    # Consume 3 tokens
    :ok = RateLimiter.consume(channel, account)
    :ok = RateLimiter.consume(channel, account)
    :ok = RateLimiter.consume(channel, account)

    # Should have 3 fewer tokens (approximately, accounting for refill)
    status2 = RateLimiter.status(channel, account)
    tokens_consumed = initial_tokens - status2.tokens
    # Allow for some refill during the test
    assert tokens_consumed > 2.5
  end

  test "record decrements tokens" do
    channel = "record-channel-#{System.unique_integer([:positive])}"
    account = "account-1"

    status1 = RateLimiter.status(channel, account)
    initial_tokens = status1.tokens

    :ok = RateLimiter.record(channel, account)

    # The cast is handled before the following status call from the same process
    status2 = RateLimiter.status(channel, account)
    assert status2.tokens < initial_tokens
  end

  test "new buckets start with burst tokens" do
    channel = "new-bucket-#{System.unique_integer([:positive])}"
    status = RateLimiter.status(channel, "account-1")

    assert status.tokens == status.burst
  end

  test "rapid consumption of an exhausted bucket is rate limited with a wait" do
    channel = "rapid-#{System.unique_integer([:positive])}"
    results = for _ <- 1..20, do: RateLimiter.consume(channel, "account-1")

    assert Enum.any?(results, fn
             {:rate_limited, wait_ms} -> is_integer(wait_ms) and wait_ms > 0
             _ -> false
           end)
  end
end
