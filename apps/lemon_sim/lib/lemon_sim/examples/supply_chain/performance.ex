defmodule LemonSim.Examples.SupplyChain.Performance do
  @moduledoc """
  Objective performance summary for Supply Chain simulation runs.

  The benchmark emphasis is cost efficiency, bullwhip reduction,
  fill rate maximization, and communication quality.
  """

  import LemonSim.GameHelpers

  alias LemonSim.Examples.SupplyChain.DemandModel

  @tier_order ["retailer", "distributor", "factory", "raw_materials"]

  @spec summarize(map()) :: map()
  def summarize(world) do
    tiers = get(world, :tiers, %{})
    winner = get(world, :winner)
    demand_history = get(world, :demand_history, [])
    message_log = get(world, :message_log, [])
    total_chain_cost = get(world, :total_chain_cost, nil)
    team_bonus = get(world, :team_bonus, false)

    tier_metrics =
      @tier_order
      |> Enum.into(%{}, fn tier_id ->
        tier = Map.get(tiers, tier_id, %{})
        {tier_id, build_tier_metrics(tier_id, tier, demand_history, message_log, winner)}
      end)

    chain_metrics = build_chain_metrics(tiers, demand_history, total_chain_cost, team_bonus)

    %{
      benchmark_focus: "cost efficiency, bullwhip reduction, fill rate, and communication quality",
      tiers: tier_metrics,
      chain: chain_metrics
    }
  end

  defp build_tier_metrics(tier_id, tier, demand_history, message_log, winner) do
    total_cost = get(tier, :total_cost, 0.0)
    cost_history = get(tier, :cost_history, [])
    order_history = get(tier, :order_history, [])
    orders_received = get(tier, :orders_received, 0)
    orders_fulfilled = get(tier, :orders_fulfilled, 0)

    order_quantities = Enum.map(order_history, &get(&1, :quantity, 0))
    fill_rate = DemandModel.fill_rate(orders_fulfilled, orders_received)
    bullwhip = DemandModel.bullwhip_ratio(order_quantities, demand_history)

    avg_inventory =
      if cost_history == [] do
        0.0
      else
        total_inv = Enum.sum(Enum.map(cost_history, fn c -> get(c, :inventory_snapshot, 0.0) end))
        total_inv / length(cost_history)
      end

    avg_demand = if demand_history == [], do: 0.0, else: Enum.sum(demand_history) / length(demand_history)
    inv_efficiency = DemandModel.inventory_efficiency(avg_inventory, avg_demand)

    messages_sent =
      Enum.count(message_log, fn log ->
        get(log, :from, nil) == tier_id
      end)

    total_holding = Enum.sum(Enum.map(cost_history, fn c -> get(c, :holding, 0.0) end))
    total_stockout = Enum.sum(Enum.map(cost_history, fn c -> get(c, :stockout, 0.0) end))
    total_ordering = Enum.sum(Enum.map(cost_history, fn c -> get(c, :ordering, 0.0) end))

    %{
      role: tier_id,
      won: winner == tier_id,
      total_cost: Float.round(total_cost, 2),
      holding_cost: Float.round(total_holding, 2),
      stockout_cost: Float.round(total_stockout, 2),
      ordering_cost: Float.round(total_ordering, 2),
      fill_rate: fill_rate,
      bullwhip_ratio: bullwhip,
      inventory_efficiency: inv_efficiency,
      messages_sent: messages_sent,
      orders_placed: length(order_history),
      orders_received: orders_received,
      orders_fulfilled: orders_fulfilled
    }
  end

  defp build_chain_metrics(tiers, demand_history, total_chain_cost, team_bonus) do
    all_costs =
      Enum.map(@tier_order, fn tier_id ->
        tier = Map.get(tiers, tier_id, %{})
        get(tier, :total_cost, 0.0)
      end)

    computed_total = if total_chain_cost, do: total_chain_cost, else: Enum.sum(all_costs)

    retailer = Map.get(tiers, "retailer", %{})
    retailer_fulfilled = get(retailer, :orders_fulfilled, 0)
    retailer_received = get(retailer, :orders_received, 0)
    end_to_end_fill_rate = DemandModel.fill_rate(retailer_fulfilled, retailer_received)

    avg_demand = if demand_history == [], do: 0.0, else: Enum.sum(demand_history) / length(demand_history)
    peak_demand = Enum.max(demand_history ++ [0])
    demand_variance = compute_variance(demand_history)

    %{
      total_chain_cost: Float.round(computed_total, 2),
      team_bonus_earned: team_bonus,
      end_to_end_fill_rate: end_to_end_fill_rate,
      avg_consumer_demand: Float.round(avg_demand, 1),
      peak_consumer_demand: peak_demand,
      demand_variance: Float.round(demand_variance, 2),
      rounds_played: length(demand_history)
    }
  end

  defp compute_variance([]), do: 0.0
  defp compute_variance([_]), do: 0.0

  defp compute_variance(list) do
    n = length(list)
    mean = Enum.sum(list) / n
    sum_sq = Enum.sum(Enum.map(list, fn x -> (x - mean) * (x - mean) end))
    Float.round(sum_sq / (n - 1), 2)
  end
end
