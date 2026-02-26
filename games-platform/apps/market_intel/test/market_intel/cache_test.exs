defmodule MarketIntel.CacheTest do
  use ExUnit.Case

  setup do
    # Ensure cache process is running
    case Process.whereis(MarketIntel.Cache) do
      nil -> start_supervised!(MarketIntel.Cache)
      _pid -> :ok
    end

    # Clean the table between tests
    :ets.delete_all_objects(:market_intel_cache)
    :ok
  end

  describe "put/3 and get/1" do
    test "stores and retrieves a value with default TTL" do
      assert :ok = MarketIntel.Cache.put(:test_key, "hello")
      assert {:ok, "hello"} = MarketIntel.Cache.get(:test_key)
    end

    test "stores and retrieves complex values" do
      value = %{price: 100.5, volume: 9999}
      assert :ok = MarketIntel.Cache.put(:complex_key, value)
      assert {:ok, ^value} = MarketIntel.Cache.get(:complex_key)
    end

    test "stores with custom TTL" do
      assert :ok = MarketIntel.Cache.put(:custom_ttl_key, "value", :timer.seconds(60))
      assert {:ok, "value"} = MarketIntel.Cache.get(:custom_ttl_key)
    end

    test "overwrites existing key" do
      MarketIntel.Cache.put(:overwrite_key, "first")
      MarketIntel.Cache.put(:overwrite_key, "second")
      assert {:ok, "second"} = MarketIntel.Cache.get(:overwrite_key)
    end
  end

  describe "get/1 missing keys" do
    test "returns :not_found for keys that were never set" do
      assert :not_found = MarketIntel.Cache.get(:nonexistent_key)
    end
  end

  describe "expiration" do
    test "returns :expired for entries past their TTL" do
      MarketIntel.Cache.put(:expiring_key, "ephemeral", 1)
      Process.sleep(10)
      assert :expired = MarketIntel.Cache.get(:expiring_key)
    end
  end

  describe "get_snapshot/0" do
    test "returns expected map structure" do
      snapshot = MarketIntel.Cache.get_snapshot()

      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :token)
      assert Map.has_key?(snapshot, :eth)
      assert Map.has_key?(snapshot, :base)
      assert Map.has_key?(snapshot, :polymarket)
      assert Map.has_key?(snapshot, :mentions)
      assert Map.has_key?(snapshot, :timestamp)
      assert %DateTime{} = snapshot.timestamp
    end

    test "snapshot reflects cached data" do
      MarketIntel.Cache.put(:eth_price, %{usd: 3500.0})
      snapshot = MarketIntel.Cache.get_snapshot()
      assert {:ok, %{usd: 3500.0}} = snapshot.eth
    end

    test "snapshot returns :not_found for uncached keys" do
      snapshot = MarketIntel.Cache.get_snapshot()
      assert :not_found = snapshot.eth
    end
  end

  describe "handle_info(:cleanup, state)" do
    test "removes expired entries from the ETS table" do
      # Insert an already-expired entry directly into ETS
      expired_at = System.monotonic_time(:millisecond) - 1000
      :ets.insert(:market_intel_cache, {:cleanup_test, "old_value", expired_at})

      # Insert a valid entry
      MarketIntel.Cache.put(:still_valid, "fresh", :timer.minutes(5))

      # Send cleanup message to the GenServer
      pid = Process.whereis(MarketIntel.Cache)
      send(pid, :cleanup)

      # Give it a moment to process
      Process.sleep(50)

      # Expired entry should be gone
      assert [] = :ets.lookup(:market_intel_cache, :cleanup_test)

      # Valid entry should remain
      assert {:ok, "fresh"} = MarketIntel.Cache.get(:still_valid)
    end
  end
end
