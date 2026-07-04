defmodule LemonSim.Examples.SupplyChainPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.SupplyChain.Performance

  test "scorecard exposes total chain cost as a verified metric" do
    world = %{
      winner: "retailer",
      demand_history: [10, 12, 11],
      total_chain_cost: 123.45,
      team_bonus: true,
      message_log: [%{from: "retailer"}],
      tiers: %{
        "retailer" => %{
          total_cost: 30.0,
          cost_history: [%{holding: 1.0, stockout: 2.0, ordering: 3.0, inventory_snapshot: 10}],
          order_history: [%{quantity: 10}, %{quantity: 12}, %{quantity: 11}],
          orders_received: 10,
          orders_fulfilled: 9
        },
        "distributor" => %{total_cost: 25.0},
        "factory" => %{total_cost: 40.0},
        "raw_materials" => %{total_cost: 28.45}
      }
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.total_chain_cost == 123.45
    assert scorecard.chain.team_bonus_earned
    assert scorecard.tiers["retailer"].messages_sent == 1
    assert {:ok, 123.45} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
