defmodule LemonSim.Examples.SupplyChain.DemandModel do
  @moduledoc """
  Demand pattern generation and cost calculation for the Supply Chain simulation.

  ## Demand Patterns

  Consumer demand has a stable base with occasional spikes — this
  asymmetry triggers the bullwhip effect when each tier over-orders
  in response to perceived demand uncertainty.

  ## Cost Structure

  - Holding cost: 0.5 per unit in inventory per round
  - Stockout penalty: 2.0 per unit of unfilled demand per round
  - Order cost: 1.0 per order placed (regardless of quantity)
  - Expedite surcharge: 3.0 per unit expedited
  """

  @base_demand 10
  @demand_noise 3
  @spike_probability 0.15
  @spike_multiplier 2.5

  @holding_cost_per_unit 0.5
  @stockout_penalty_per_unit 2.0
  @order_cost 1.0
  @expedite_surcharge_per_unit 3.0

  @team_bonus_threshold 600.0

  @doc """
  Returns the default cost configuration.
  """
  @spec default_costs() :: map()
  def default_costs do
    %{
      holding_cost_per_unit: @holding_cost_per_unit,
      stockout_penalty_per_unit: @stockout_penalty_per_unit,
      order_cost: @order_cost,
      expedite_surcharge_per_unit: @expedite_surcharge_per_unit
    }
  end

  @doc """
  Returns the team bonus threshold — total chain cost below this earns a bonus.
  """
  @spec team_bonus_threshold() :: float()
  def team_bonus_threshold, do: @team_bonus_threshold

  @doc """
  Generates demand for the given round using a seeded random pattern.

  Demand is stable with occasional spikes to simulate real-world disruptions.
  The seed is derived from the sim_id so demand is reproducible per game.
  """
  @spec generate_demand(pos_integer(), non_neg_integer()) :: pos_integer()
  def generate_demand(round, seed) do
    # Deterministic pseudo-random using round + seed
    hash = :erlang.phash2({round, seed, :demand}, 1_000_000)
    noise_hash = :erlang.phash2({round, seed, :noise}, 1_000_000)
    spike_hash = :erlang.phash2({round, seed, :spike}, 1_000_000)

    # Base demand with noise
    noise = rem(noise_hash, @demand_noise * 2 + 1) - @demand_noise
    base = @base_demand + noise

    # Occasional spike
    spike? = spike_hash < trunc(@spike_probability * 1_000_000)
    _ = hash

    if spike? do
      round(base * @spike_multiplier)
    else
      max(1, base)
    end
  end

  @doc """
  Calculates round costs for a tier based on current inventory and backlog.
  """
  @spec calculate_round_cost(map(), map()) :: %{
          holding: float(),
          stockout: float(),
          ordering: float(),
          total: float()
        }
  def calculate_round_cost(tier, costs) do
    inventory = Map.get(tier, :inventory, 0)
    backlog = Map.get(tier, :backlog, 0)
    order_placed = Map.get(tier, :order_placed_this_round, false)

    holding = inventory * Map.get(costs, :holding_cost_per_unit, @holding_cost_per_unit)
    stockout = backlog * Map.get(costs, :stockout_penalty_per_unit, @stockout_penalty_per_unit)
    ordering = if order_placed, do: Map.get(costs, :order_cost, @order_cost), else: 0.0

    total = holding + stockout + ordering

    %{holding: holding, stockout: stockout, ordering: ordering, total: total}
  end

  @doc """
  Calculates expedite surcharge for a given quantity.
  """
  @spec expedite_cost(non_neg_integer(), map()) :: float()
  def expedite_cost(quantity, costs) do
    quantity * Map.get(costs, :expedite_surcharge_per_unit, @expedite_surcharge_per_unit)
  end

  @doc """
  Computes the bullwhip ratio: order variance / demand variance.

  A ratio of 1.0 means perfect responsiveness. Higher values indicate amplification.
  Returns nil if insufficient data.
  """
  @spec bullwhip_ratio([non_neg_integer()], [non_neg_integer()]) :: float() | nil
  def bullwhip_ratio(order_history, demand_history) when length(order_history) >= 3 and length(demand_history) >= 3 do
    order_var = variance(order_history)
    demand_var = variance(demand_history)

    if demand_var > 0 do
      Float.round(order_var / demand_var, 2)
    else
      nil
    end
  end

  def bullwhip_ratio(_, _), do: nil

  @doc """
  Computes the fill rate: fulfilled orders / total orders received.
  """
  @spec fill_rate(non_neg_integer(), non_neg_integer()) :: float()
  def fill_rate(_fulfilled, 0), do: 1.0
  def fill_rate(fulfilled, total), do: Float.round(fulfilled / total, 3)

  @doc """
  Computes inventory efficiency: average inventory / average demand.

  Values near 1.0 are optimal. Much higher means excess stock, lower means stockouts.
  """
  @spec inventory_efficiency(float(), float()) :: float() | nil
  def inventory_efficiency(_avg_inventory, 0.0), do: nil
  def inventory_efficiency(avg_inventory, avg_demand) do
    Float.round(avg_inventory / avg_demand, 2)
  end

  # -- Private helpers --

  defp variance([]), do: 0.0
  defp variance([_]), do: 0.0

  defp variance(list) do
    n = length(list)
    mean = Enum.sum(list) / n
    sum_sq = Enum.sum(Enum.map(list, fn x -> (x - mean) * (x - mean) end))
    sum_sq / (n - 1)
  end
end
