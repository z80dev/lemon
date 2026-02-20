defmodule MarketIntelTest do
  use ExUnit.Case
  doctest MarketIntel

  setup do
    if Process.whereis(MarketIntel.Cache) == nil do
      start_supervised!(MarketIntel.Cache)
    end

    :ok
  end

  test "cache stores and retrieves data" do
    :ok = MarketIntel.Cache.put(:test_key, %{value: 42}, 1000)
    {:ok, data} = MarketIntel.Cache.get(:test_key)
    assert data.value == 42
  end

  test "cache returns expired for old data" do
    :ok = MarketIntel.Cache.put(:expired_key, %{value: 42}, 1)
    Process.sleep(10)
    assert MarketIntel.Cache.get(:expired_key) == :expired
  end
end
