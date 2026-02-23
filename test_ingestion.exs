#!/usr/bin/env elixir

# Test script for the data ingestion pipeline
# Run with: mix run test_ingestion.exs

IO.puts("🧪 Testing Data Ingestion Pipeline")
IO.puts("=" |> String.duplicate(50))

# Test 1: Subscription Registry
IO.puts("\n📋 Test 1: Subscription Registry")

# Subscribe a test session
{:ok, _} = LemonIngestion.subscribe("agent:test:main", %{
  type: :polymarket,
  filters: %{min_liquidity: 100_000},
  importance: :medium
})

IO.puts("  ✅ Subscribed agent:test:main to Polymarket events")

# List subscriptions
subs = LemonIngestion.list_subscriptions()
IO.puts("  📊 Active subscriptions: #{length(subs)}")

# Test 2: Event Routing
IO.puts("\n📡 Test 2: Event Routing")

# Create a test event
event = %{
  id: "evt_test_001",
  source: :polymarket,
  type: :large_trade,
  timestamp: DateTime.utc_now(),
  importance: :high,
  data: %{
    market_id: "0xabc123",
    market_title: "Will ETH hit $5000 by March?",
    trade_size: 50_000,
    liquidity: 2_000_000
  },
  url: "https://polymarket.com/market/test"
}

IO.puts("  📤 Ingesting test event...")
{:ok, result} = LemonIngestion.ingest(event)
IO.puts("  ✅ Event routed: #{result.delivered} delivered, #{result.failed} failed")

# Test 3: Unsubscribe
IO.puts("\n🗑️ Test 3: Unsubscribe")
:ok = LemonIngestion.unsubscribe("agent:test:main")
IO.puts("  ✅ Unsubscribed agent:test:main")

# Verify
subs_after = LemonIngestion.list_subscriptions()
IO.puts("  📊 Active subscriptions: #{length(subs_after)}")

# Test 4: Polymarket Adapter Status
IO.puts("\n🎯 Test 4: Polymarket Adapter Status")
status = LemonIngestion.Adapters.Polymarket.status()
IO.puts("  📊 Adapter status: #{inspect(status)}")

IO.puts("\n" <> "=" |> String.duplicate(50))
IO.puts("✅ All tests completed!")
