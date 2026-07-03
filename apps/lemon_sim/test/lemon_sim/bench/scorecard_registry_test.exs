defmodule LemonSim.Bench.Scorecard.RegistryTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Scorecard.Registry
  alias LemonSim.Examples.{Pandemic, Poker, StockMarket, TcgShop, VendingBench}

  test "registered scenarios expose scorecard modules and primary metrics" do
    expected = %{
      "pandemic" => Pandemic.Performance,
      "poker" => Poker.Performance,
      "stock_market" => StockMarket.Performance,
      "tcg_shop" => TcgShop.Performance,
      "vending_bench" => VendingBench.Performance,
      "vending_bench_arena" => VendingBench.ArenaScorecard
    }

    assert Registry.all() == expected

    Enum.each(expected, fn {scenario_id, module} ->
      assert Registry.fetch(scenario_id) == {:ok, module}
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert function_exported?(module, :scorecard, 1)
      assert %{key: key, direction: direction} = module.primary_metric()
      assert is_binary(key) or (is_list(key) and Enum.all?(key, &is_binary/1))
      assert direction in [:maximize, :minimize]
    end)
  end

  test "unregistered scenarios keep skip semantics" do
    assert Registry.fetch("unknown_scenario") == :error
    assert Registry.scorecard("unknown_scenario", %{}) == {:ok, :skip}
  end
end
