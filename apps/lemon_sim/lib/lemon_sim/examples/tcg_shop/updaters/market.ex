defmodule LemonSim.Examples.TcgShop.Updaters.Market do
  @moduledoc false

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_competitor_reaction(world, day, pulse) do
    stockout_units = day_stockout_units(world, day)
    event_count = day_event_count(world, day)
    markup_pressure = average_markup_pressure(world)
    reputation = get(world, :reputation, 50)
    featured = get(pulse, :featured_franchise, "Pokemon")
    position = get(world, :competitive_position, default_competitive_position())

    pressure_delta =
      Float.round(
        markup_pressure / 18 + stockout_units / 6 - event_count * 1.4 -
          max(0, reputation - 60) / 25,
        2
      )

    pressure = clamp_float(get(position, :competitor_pressure, 0) + pressure_delta, 0.0, 10.0)

    share_delta =
      Float.round(
        event_count * 1.1 + max(0, reputation - 55) / 20 - pressure / 8 -
          stockout_units / 12,
        2
      )

    share = clamp_float(get(position, :local_market_share_pct, 34.0) + share_delta, 10.0, 70.0)

    reaction = %{
      day: day,
      featured_franchise: featured,
      stockout_units: stockout_units,
      event_count: event_count,
      average_markup_pct: Float.round(markup_pressure, 2),
      pressure_delta: pressure_delta,
      local_market_share_pct: Float.round(share, 2),
      competitor_pressure: Float.round(pressure, 2),
      reaction:
        competitor_reaction_label(pressure_delta, stockout_units, markup_pressure, event_count)
    }

    updated_position = %{
      local_market_share_pct: Float.round(share, 2),
      competitor_pressure: Float.round(pressure, 2),
      price_reputation: price_reputation(markup_pressure),
      last_reaction: reaction.reaction
    }

    world
    |> Map.put(:competitive_position, updated_position)
    |> Map.update(:competitor_history, [reaction], &(&1 ++ [reaction]))
  end

  defp default_competitive_position do
    %{
      local_market_share_pct: 34.0,
      competitor_pressure: 0,
      price_reputation: "fair",
      last_reaction: "opening baseline"
    }
  end

  defp day_stockout_units(world, day) do
    world
    |> get(:stockout_history, [])
    |> Enum.filter(&(get(&1, :day, 0) == day))
    |> Enum.reduce(0, fn stockout, acc -> acc + get(stockout, :lost_units, 0) end)
  end

  defp day_event_count(world, day) do
    world
    |> get(:tournament_history, [])
    |> Enum.count(&(get(&1, :day, 0) == day))
  end

  defp average_markup_pressure(world) do
    catalog = get(world, :catalog, %{})

    markups =
      world
      |> get(:inventory, %{})
      |> Enum.map(fn {line_id, item} ->
        line = Map.get(catalog, line_id, %{})
        market = get(line, :market_price, 0.0)
        price = get(item, :price, market)

        if market > 0 do
          (price - market) / market * 100
        else
          0.0
        end
      end)

    case markups do
      [] -> 0.0
      values -> Enum.sum(values) / length(values)
    end
  end

  defp competitor_reaction_label(pressure_delta, stockout_units, markup, event_count) do
    cond do
      stockout_units >= 6 -> "competitors advertise in-stock alternatives"
      markup >= 35 -> "nearby shop undercuts high shelf prices"
      pressure_delta >= 2 -> "online sellers pressure local prices"
      event_count > 0 -> "community events defend local share"
      pressure_delta <= -1 -> "competitors lose momentum"
      true -> "market position holds"
    end
  end

  defp price_reputation(markup) when markup >= 35, do: "expensive"
  defp price_reputation(markup) when markup >= 15, do: "premium"
  defp price_reputation(markup) when markup <= -5, do: "discount"
  defp price_reputation(_), do: "fair"

  def competitive_demand_multiplier(world) do
    position = get(world, :competitive_position, default_competitive_position())
    share = get(position, :local_market_share_pct, 34.0)
    pressure = get(position, :competitor_pressure, 0.0)

    (0.75 + share / 100 - pressure / 35)
    |> clamp_float(0.55, 1.35)
    |> Float.round(2)
  end

  def apply_market_movement(world, day, pulse) do
    seed = get(world, :seed, 1)
    buzz_franchise = get(pulse, :featured_franchise)
    buzz_multiplier = get(pulse, :buzz_multiplier, 1.0)
    competitor = get(world, :competitor_snapshot, %{})

    catalog =
      world
      |> get(:catalog, %{})
      |> Enum.into(%{}, fn {line_id, line} ->
        franchise = get(line, :franchise, "")
        current = get(line, :market_price, 0.0)
        volatility = get(line, :volatility, 0.0)

        demand_delta =
          if franchise == buzz_franchise, do: (buzz_multiplier - 1.0) * 0.09, else: 0.0

        random_delta = deterministic_delta(seed, day, line_id) * volatility
        competitor_delta = competitor_delta(franchise, competitor)

        next_price =
          Float.round(
            max(
              get(line, :unit_cost, 0.0) * 0.85,
              current * (1.0 + demand_delta + random_delta + competitor_delta)
            ),
            2
          )

        {line_id, Map.put(line, :market_price, next_price)}
      end)

    Map.put(world, :catalog, catalog)
  end

  defp deterministic_delta(seed, day, line_id) do
    (:erlang.phash2({seed, day, line_id}, 21) - 10) / 100.0
  end

  defp competitor_delta("Pokemon", competitor) do
    case get(competitor, :big_box_stock, "normal") do
      "heavy" -> -0.04
      "thin" -> 0.03
      _ -> 0.0
    end
  end

  defp competitor_delta(_franchise, competitor) do
    case get(competitor, :online_spread, "healthy") do
      "volatile" -> 0.025
      "tight" -> -0.015
      _ -> 0.0
    end
  end
end
