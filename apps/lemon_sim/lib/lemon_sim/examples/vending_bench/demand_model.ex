defmodule LemonSim.Examples.VendingBench.DemandModel do
  @moduledoc """
  Deterministic demand generation for the Vending Bench simulation.

  Uses `:erlang.phash2` for reproducible pseudo-randomness seeded by day + slot + seed.
  """

  @catalog %{
    "sparkling_water" => %{
      display_name: "Sparkling Water",
      size_class: "small",
      wholesale_cost: 1.25,
      reference_price: 2.50,
      elasticity: 1.1,
      base_daily_sales: 4,
      shelf_life_days: 120
    },
    "energy_drink" => %{
      display_name: "Energy Drink",
      size_class: "small",
      wholesale_cost: 1.75,
      reference_price: 3.50,
      elasticity: 1.3,
      base_daily_sales: 3,
      shelf_life_days: 180
    },
    "chips" => %{
      display_name: "Chips",
      size_class: "small",
      wholesale_cost: 0.90,
      reference_price: 2.00,
      elasticity: 0.9,
      base_daily_sales: 5,
      shelf_life_days: 45
    },
    "candy_bar" => %{
      display_name: "Candy Bar",
      size_class: "small",
      wholesale_cost: 0.70,
      reference_price: 1.50,
      elasticity: 0.8,
      base_daily_sales: 6,
      shelf_life_days: 120
    },
    "cola" => %{
      display_name: "Cola",
      size_class: "small",
      wholesale_cost: 0.65,
      reference_price: 1.75,
      elasticity: 1.0,
      base_daily_sales: 5,
      shelf_life_days: 180
    },
    "water" => %{
      display_name: "Water",
      size_class: "small",
      wholesale_cost: 0.45,
      reference_price: 1.25,
      elasticity: 0.7,
      base_daily_sales: 7,
      shelf_life_days: 365
    },
    "trail_mix" => %{
      display_name: "Trail Mix",
      size_class: "small",
      wholesale_cost: 1.30,
      reference_price: 3.00,
      elasticity: 1.2,
      base_daily_sales: 3,
      shelf_life_days: 60
    },
    "granola_bar" => %{
      display_name: "Granola Bar",
      size_class: "small",
      wholesale_cost: 0.95,
      reference_price: 2.25,
      elasticity: 1.0,
      base_daily_sales: 4,
      shelf_life_days: 75
    },
    "sandwich" => %{
      display_name: "Sandwich",
      size_class: "large",
      wholesale_cost: 2.40,
      reference_price: 5.50,
      elasticity: 1.4,
      base_daily_sales: 3,
      shelf_life_days: 5
    },
    "protein_box" => %{
      display_name: "Protein Box",
      size_class: "large",
      wholesale_cost: 3.10,
      reference_price: 6.75,
      elasticity: 1.5,
      base_daily_sales: 2,
      shelf_life_days: 4
    }
  }

  @spec catalog() :: map()
  def catalog, do: @catalog

  @doc """
  Calculate daily sales for all stocked slots in the machine.

  Returns a list of `{slot_id, units_sold, revenue}` tuples.
  Sales are deterministic given the same day, machine state, weather, season, and seed.
  """
  @spec daily_sales(map(), map(), map(), pos_integer(), non_neg_integer()) :: [
          {String.t(), pos_integer(), float()}
        ]
  def daily_sales(machine_slots, catalog, weather, day, seed) do
    weather_mult = Map.get(weather, :demand_multiplier, 1.0)
    season_mult = season_for_day(day).demand_multiplier
    weekday_mult = weekday_multiplier(day)
    month_mult = month_multiplier(day)
    variety_mult = variety_multiplier(machine_slots)

    machine_slots
    |> Enum.filter(fn {_slot_id, slot} ->
      slot_item = get(slot, :item_id)
      slot_inv = get(slot, :inventory, 0)
      slot_item != nil and slot_inv > 0
    end)
    |> Enum.map(fn {slot_id, slot} ->
      item_id = get(slot, :item_id)
      current_price = get(slot, :price, 0.0)
      inventory = get(slot, :inventory, 0)

      item_info = Map.get(catalog, item_id, %{})
      base_sales = Map.get(item_info, :base_daily_sales, 3)
      ref_price = Map.get(item_info, :reference_price, 2.0)
      elasticity_val = Map.get(item_info, :elasticity, 1.0)

      # Deterministic variation: +/- 20% based on hash
      hash = :erlang.phash2({day, slot_id, seed})
      variation = 0.8 + rem(hash, 41) / 100.0

      # Price elasticity effect
      price_mult = price_elasticity(current_price, ref_price, elasticity_val)
      competition_mult = get(slot, :arena_demand_multiplier, 1.0)
      price_posture_mult = arena_price_posture_multiplier(get(slot, :arena_price_multiplier, 1.0))

      raw_demand =
        (base_sales * price_mult * weather_mult * season_mult * variation)
        |> Kernel.*(weekday_mult)
        |> Kernel.*(month_mult)
        |> Kernel.*(variety_mult)
        |> Kernel.*(competition_mult)
        |> Kernel.*(price_posture_mult)
        |> Float.round()
        |> trunc()
        |> max(0)

      units_sold = min(raw_demand, inventory)
      revenue = Float.round(units_sold * current_price, 2)

      {slot_id, units_sold, revenue}
    end)
    |> Enum.filter(fn {_, units, _} -> units > 0 end)
  end

  @doc """
  Price elasticity multiplier: `(reference_price / current_price) ^ elasticity`.

  Higher prices reduce demand; lower prices increase it.
  """
  @spec price_elasticity(number(), number(), number()) :: float()
  def price_elasticity(current_price, reference_price, elasticity) do
    if current_price <= 0 do
      0.0
    else
      :math.pow(reference_price / current_price, elasticity)
    end
  end

  defp arena_price_posture_multiplier(multiplier) when is_number(multiplier) do
    (1.0 + (1.0 - multiplier) * 0.5)
    |> min(1.1)
    |> max(0.85)
  end

  defp arena_price_posture_multiplier(_multiplier), do: 1.0

  @doc """
  Deterministic weather generation from day + seed.
  """
  @spec generate_weather(pos_integer(), non_neg_integer()) :: map()
  def generate_weather(day, seed) do
    hash = :erlang.phash2({:weather, day, seed})
    kind_idx = rem(hash, 100)

    cond do
      kind_idx < 40 -> %{kind: "mild", demand_multiplier: 1.0}
      kind_idx < 60 -> %{kind: "hot", demand_multiplier: 1.3}
      kind_idx < 75 -> %{kind: "cold", demand_multiplier: 0.8}
      kind_idx < 85 -> %{kind: "rainy", demand_multiplier: 0.7}
      kind_idx < 95 -> %{kind: "sunny", demand_multiplier: 1.2}
      true -> %{kind: "stormy", demand_multiplier: 0.5}
    end
  end

  @doc """
  Season progression over a full benchmark year.
  """
  @spec season_for_day(pos_integer()) :: map()
  def season_for_day(day) do
    day_of_year = rem(max(day, 1) - 1, 365) + 1

    cond do
      day_of_year <= 59 -> %{name: "winter", demand_multiplier: 0.85}
      day_of_year <= 151 -> %{name: "spring", demand_multiplier: 1.0}
      day_of_year <= 243 -> %{name: "summer", demand_multiplier: 1.2}
      day_of_year <= 334 -> %{name: "fall", demand_multiplier: 1.0}
      true -> %{name: "winter", demand_multiplier: 0.85}
    end
  end

  @spec weekday_multiplier(pos_integer()) :: float()
  def weekday_multiplier(day) do
    case rem(max(day, 1) - 1, 7) + 1 do
      1 -> 1.05
      2 -> 1.0
      3 -> 1.0
      4 -> 1.05
      5 -> 1.15
      6 -> 0.8
      7 -> 0.75
    end
  end

  @spec month_multiplier(pos_integer()) :: float()
  def month_multiplier(day) do
    month = div(rem(max(day, 1) - 1, 365), 30) + 1

    case month do
      month when month in [6, 7, 8] -> 1.1
      month when month in [11, 12] -> 0.9
      _ -> 1.0
    end
  end

  @spec variety_multiplier(map()) :: float()
  def variety_multiplier(machine_slots) when is_map(machine_slots) do
    unique_items =
      machine_slots
      |> Enum.map(fn {_slot_id, slot} -> get(slot, :item_id) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.size()

    cond do
      unique_items <= 1 -> 0.72
      unique_items == 2 -> 0.86
      unique_items <= 4 -> 1.0
      true -> 1.08
    end
  end

  defp get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
