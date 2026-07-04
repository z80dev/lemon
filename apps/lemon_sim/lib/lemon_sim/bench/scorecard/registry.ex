defmodule LemonSim.Bench.Scorecard.Registry do
  @moduledoc false

  alias LemonSim.Examples.{Pandemic, Poker, StockMarket, TcgShop, VendingBench}

  @scorecards %{
    "pandemic" => Pandemic.Performance,
    "poker" => Poker.Performance,
    "stock_market" => StockMarket.Performance,
    "tcg_shop" => TcgShop.Performance,
    "vending_bench" => VendingBench.Performance,
    "vending_bench_arena" => VendingBench.ArenaScorecard
  }

  def all, do: @scorecards

  def fetch(scenario_id) when is_binary(scenario_id) do
    case Map.fetch(@scorecards, scenario_id) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  def get(scenario_id) when is_binary(scenario_id), do: Map.get(@scorecards, scenario_id)

  def registered?(scenario_id) when is_binary(scenario_id),
    do: Map.has_key?(@scorecards, scenario_id)

  def scorecard(scenario_id, final_world) when is_binary(scenario_id) and is_map(final_world) do
    case fetch(scenario_id) do
      {:ok, module} -> {:ok, module.scorecard(final_world)}
      :error -> {:ok, :skip}
    end
  end
end
