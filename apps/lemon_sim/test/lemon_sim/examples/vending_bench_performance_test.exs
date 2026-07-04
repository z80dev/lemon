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

  test "scorecard adds historical stockout days with old JSON default" do
    world = %{
      "sim_id" => "vb_old_json",
      "status" => "running",
      "day_number" => 2,
      "bank_balance" => 600.0,
      "cash_in_machine" => 0.0,
      "storage" => %{"inventory" => %{}},
      "machine" => %{
        "slots" => %{"A1" => %{"item_id" => "water", "inventory" => 0, "price" => 1.25}}
      },
      "catalog" => %{"water" => %{"wholesale_cost" => 0.4}},
      "sales_history" => [%{"day" => 1, "item_id" => "water", "quantity" => 1, "revenue" => 1.25}]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.stockout_count == 1
    assert scorecard.stockout_days == 0
    refute scorecard.failure_modes.chronic_stockouts
  end

  test "operational score penalty uses historical stockout days" do
    world = %{
      sim_id: "vb_stockout_penalty",
      status: "running",
      day_number: 2,
      bank_balance: 600.0,
      cash_in_machine: 0.0,
      stockout_days: 0,
      storage: %{inventory: %{}},
      machine: %{slots: %{"A1" => %{item_id: "water", inventory: 0, price: 1.25}}},
      catalog: %{"water" => %{wholesale_cost: 0.4}},
      sales_history: [%{day: 1, item_id: "water", quantity: 1, revenue: 1.25}]
    }

    clean = Performance.scorecard(world)
    historical = Performance.scorecard(%{world | stockout_days: 4})

    assert clean.stockout_count == historical.stockout_count

    assert clean.score_modes.lemon_operational_score -
             historical.score_modes.lemon_operational_score ==
             4.0
  end

  test "chronic stockouts scale with elapsed run length" do
    world = %{
      sim_id: "vb_stockout_threshold",
      status: "running",
      day_number: 101,
      bank_balance: 600.0,
      cash_in_machine: 0.0,
      storage: %{inventory: %{}},
      machine: %{slots: %{"A1" => %{item_id: "water", inventory: 0, price: 1.25}}},
      catalog: %{"water" => %{wholesale_cost: 0.4}},
      sales_history: [%{day: 1, item_id: "water", quantity: 1, revenue: 1.25}]
    }

    refute Performance.scorecard(Map.put(world, :stockout_days, 9)).failure_modes.chronic_stockouts

    assert Performance.scorecard(Map.put(world, :stockout_days, 10)).failure_modes.chronic_stockouts
  end
end
