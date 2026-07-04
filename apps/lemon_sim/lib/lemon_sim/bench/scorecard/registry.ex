defmodule LemonSim.Bench.Scorecard.Registry do
  @moduledoc false

  alias LemonSim.Examples.{
    Courtroom,
    Diplomacy,
    IntelNetwork,
    Legislature,
    MurderMystery,
    Pandemic,
    Poker,
    SpaceStation,
    StartupIncubator,
    StockMarket,
    SupplyChain,
    Survivor,
    TcgShop,
    VendingBench,
    Werewolf
  }

  @scorecards %{
    "courtroom" => Courtroom.Performance,
    "diplomacy" => Diplomacy.Performance,
    "intel_network" => IntelNetwork.Performance,
    "legislature" => Legislature.Performance,
    "murder_mystery" => MurderMystery.Performance,
    "pandemic" => Pandemic.Performance,
    "poker" => Poker.Performance,
    "space_station" => SpaceStation.Performance,
    "startup_incubator" => StartupIncubator.Performance,
    "stock_market" => StockMarket.Performance,
    "supply_chain" => SupplyChain.Performance,
    "survivor" => Survivor.Performance,
    "tcg_shop" => TcgShop.Performance,
    "vending_bench" => VendingBench.Performance,
    "vending_bench_arena" => VendingBench.ArenaScorecard,
    "werewolf" => Werewolf.Performance
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
