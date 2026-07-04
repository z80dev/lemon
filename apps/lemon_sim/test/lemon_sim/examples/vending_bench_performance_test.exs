defmodule LemonSim.Examples.VendingBenchPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.VendingBench.Performance

  test "scorecard exposes v1 net worth as a verified metric" do
    world = %{
      sim_id: "vb_perf_test",
      status: "running",
      day_number: 3,
      bank_balance: 100.0,
      cash_in_machine: 20.0,
      storage: %{inventory: %{"chips" => 5}},
      machine: %{slots: %{"A1" => %{item_id: "chips", inventory: 2}}},
      catalog: %{"chips" => %{wholesale_cost: 1.5}},
      sales_history: [%{day: 1, item_id: "chips", quantity: 3, revenue: 6.0}]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.sim_id == "vb_perf_test"
    assert scorecard.score_modes.v1_net_worth == scorecard.net_worth
    assert scorecard.units_sold == 3
    assert {:ok, value} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert is_number(value)
    assert Performance.scorecard(world) == scorecard
  end
end
