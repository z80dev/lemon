defmodule LemonCore.RateLimiterTest do
  use ExUnit.Case, async: true

  alias LemonCore.RateLimiter

  setup do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 100_000)
    name = __MODULE__

    pid =
      start_supervised!(
        {RateLimiter,
         name: name, profile: :a2a, limit: 2, clock: fn -> :atomics.get(clock, 1) end}
      )

    %{clock: clock, name: name, pid: pid}
  end

  test "sliding window retains the inclusive minute boundary", ctx do
    assert RateLimiter.allow?(ctx.name, "peer")
    assert RateLimiter.allow?(ctx.name, "peer")
    refute RateLimiter.allow?(ctx.name, "peer")
    :atomics.put(ctx.clock, 1, 160_000)
    refute RateLimiter.allow?(ctx.name, "peer")
    :atomics.put(ctx.clock, 1, 160_001)
    assert RateLimiter.allow?(ctx.name, "peer")
  end

  test "match-spec syntax in peer keys is treated literally", ctx do
    peers = [:"$1", :_, {:"$1", :_}]

    for peer <- peers do
      assert RateLimiter.allow?(ctx.name, peer)
      assert RateLimiter.allow?(ctx.name, peer)
      refute RateLimiter.allow?(ctx.name, peer)
    end

    for peer <- peers do
      assert [{^peer, [100_000, 100_000], 100_000}] = :ets.lookup(ctx.name, peer)
    end
  end

  test "periodic sweep evicts idle peers without dropping recently active peers", ctx do
    assert RateLimiter.allow?(ctx.name, "idle")
    assert RateLimiter.allow?(ctx.name, "active")
    :atomics.put(ctx.clock, 1, 160_000)
    refute :ets.lookup(ctx.name, "idle") == []
    assert RateLimiter.allow?(ctx.name, "active")
    :atomics.put(ctx.clock, 1, 160_001)
    send(ctx.pid, :sweep)
    :sys.get_state(ctx.pid)
    assert :ets.lookup(ctx.name, "idle") == []
    assert [{"active", _, 160_000}] = :ets.lookup(ctx.name, "active")
    assert RateLimiter.allow?(ctx.name, "idle")
  end

  test "admission does not call the table owner", ctx do
    :sys.suspend(ctx.pid)

    try do
      assert RateLimiter.allow?(ctx.name, "peer")
    after
      :sys.resume(ctx.pid)
    end
  end

  test "concurrent admissions cannot exceed the peer quota", ctx do
    results =
      1..32
      |> Task.async_stream(fn _ -> RateLimiter.allow?(ctx.name, "race") end,
        max_concurrency: 32,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, & &1) == 2
  end
end
