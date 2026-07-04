defmodule LemonSim.Examples.TcgShopPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.TcgShop.Performance

  test "scorecard exposes net worth as a verified metric" do
    world = %{
      bank_balance: 1_000.0,
      cash_drawer_balance: 200.0,
      starting_balance: 1_000.0,
      starting_cash_drawer_balance: 100.0,
      inventory: %{"booster" => %{quantity: 10, unit_cost: 3.0}},
      singles_case: %{total_market_value: 150.0},
      credit_line_balance: 50.0,
      sales_history: [%{revenue: 120.0, cost: 70.0, quantity: 3}]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.net_worth > 0
    assert scorecard.bank_balance == 1000.0
    assert Map.has_key?(scorecard, :roi_pct)
    assert {:ok, value} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert is_number(value)
    assert Performance.scorecard(world) == scorecard
  end
end
