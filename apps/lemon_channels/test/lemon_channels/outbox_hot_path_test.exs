defmodule LemonChannels.OutboxHotPathTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Outbox.{Dedupe}
  alias LemonCore.RateLimiter

  test "concurrent confirmed-key inserts have exactly one winner" do
    key = "atomic-confirmed-#{System.unique_integer([:positive])}"
    full_key = {"hot-path-regression", key}
    on_exit(fn -> :ets.delete(:lemon_channels_outbox_dedupe, full_key) end)
    assert Dedupe.check(elem(full_key, 0), key) == :new
    results = race(64, fn -> Dedupe.mark_new(elem(full_key, 0), key) end)
    assert Enum.count(results, &(&1 == :new)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 63
    assert Dedupe.check(elem(full_key, 0), key) == :duplicate

    :ets.insert(
      :lemon_channels_outbox_dedupe,
      {full_key, System.monotonic_time(:millisecond) + 10_000}
    )

    before_mark = System.monotonic_time(:millisecond)
    assert :ok = Dedupe.mark(elem(full_key, 0), key)
    [{^full_key, refreshed_expiry}] = :ets.lookup(:lemon_channels_outbox_dedupe, full_key)
    assert refreshed_expiry >= before_mark + Dedupe.ttl_ms()
  end

  test "concurrent expired-key replacement cannot erase a fresh confirmed marker" do
    key = "atomic-expired-#{System.unique_integer([:positive])}"
    channel = "hot-path-regression"
    full_key = {channel, key}

    :ets.insert(
      :lemon_channels_outbox_dedupe,
      {full_key, System.monotonic_time(:millisecond) - 1}
    )

    on_exit(fn -> :ets.delete(:lemon_channels_outbox_dedupe, full_key) end)
    results = race(64, fn -> Dedupe.mark_new(channel, key) end)
    assert Enum.count(results, &(&1 == :new)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 63
    assert Dedupe.check(channel, key) == :duplicate
  end

  test "concurrent token consumption cannot exceed the existing five-token burst" do
    channel = "atomic-bucket-#{System.unique_integer([:positive])}"
    account = "hot-path-regression"
    full_key = {channel, account}
    # Freeze refill beyond the test deadline, without sleeping or changing the
    # production clock. CAS must preserve this timestamp across contenders.
    :ets.insert(
      LemonChannels.Outbox.RateLimiter,
      {full_key, 5, System.monotonic_time(:millisecond) + 60_000}
    )

    on_exit(fn -> :ets.delete(LemonChannels.Outbox.RateLimiter, full_key) end)

    results =
      race(64, fn -> RateLimiter.consume(LemonChannels.Outbox.RateLimiter, channel, account) end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &(&1 == {:rate_limited, 33})) == 59

    assert RateLimiter.check(LemonChannels.Outbox.RateLimiter, channel, account) ==
             {:rate_limited, 33}

    assert RateLimiter.status(LemonChannels.Outbox.RateLimiter, channel, account) == %{
             tokens: 0.0,
             rate: 30,
             burst: 5
           }

    assert :ok = RateLimiter.record(LemonChannels.Outbox.RateLimiter, channel, account)
    assert RateLimiter.status(LemonChannels.Outbox.RateLimiter, channel, account).tokens == 0
  end

  defp race(count, callback) do
    parent = self()
    token = make_ref()

    workers =
      for _ <- 1..count do
        spawn_monitor(fn ->
          send(parent, {:ready, token, self()})

          receive do
            {:go, ^token} -> send(parent, {:race_result, token, callback.()})
          end
        end)
      end

    try do
      for {worker, _monitor} <- workers do
        assert_receive {:ready, ^token, ^worker}, 1_000
      end

      Enum.each(workers, fn {worker, _monitor} -> send(worker, {:go, token}) end)

      for _ <- workers do
        assert_receive {:race_result, ^token, result}, 1_000
        result
      end
    after
      Enum.each(workers, fn {worker, monitor} ->
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
      end)
    end
  end
end
