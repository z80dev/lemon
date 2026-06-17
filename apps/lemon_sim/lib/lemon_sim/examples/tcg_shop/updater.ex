defmodule LemonSim.Examples.TcgShop.Updater do
  @moduledoc false

  @behaviour LemonSim.Kernel.Updater

  import LemonSim.Examples.Helpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.TcgShop.{Catalog, Events}
  alias LemonSim.Kernel.State

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "tcg_checked_dashboard" -> append_only(state, event)
      "tcg_inspected_inventory" -> append_only(state, event)
      "tcg_researched_market" -> apply_researched_market(state, event)
      "tcg_reviewed_customers" -> append_only(state, event)
      "tcg_order_product_line" -> apply_order_product_line(state, event)
      "tcg_buy_collection" -> apply_buy_collection(state, event)
      "tcg_set_prices" -> apply_set_prices(state, event)
      "tcg_host_event" -> apply_host_event(state, event)
      "tcg_submit_grading" -> apply_submit_grading(state, event)
      "tcg_process_online_orders" -> apply_process_online_orders(state, event)
      "tcg_wait_next_day" -> apply_wait_next_day(state, event)
      _ -> {:error, {:invalid_tcg_shop_event, event.kind}}
    end
  end

  defp append_only(%State{} = state, event) do
    {:ok, State.append_event(state, event), {:decide, "support observation recorded"}}
  end

  defp apply_researched_market(%State{} = state, event) do
    query = get(event.payload, "query", "")
    day = get(state.world, :day_number, 1)
    pulse = List.last(get(state.world, :market_pulses, []))

    entry = %{
      day: day,
      query: query,
      pulse: pulse,
      notes: [
        "Sealed margins depend on allocation and cash discipline.",
        "Singles demand decays quickly after metagame spikes.",
        "Events convert players into accessory and singles buyers."
      ]
    }

    next =
      state
      |> State.update_world(fn world ->
        Map.update(world, :research_history, [entry], &(&1 ++ [entry]))
      end)
      |> State.append_event(event)

    {:ok, next, {:decide, "market research recorded"}}
  end

  defp apply_order_product_line(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(quantity),
         {:ok, line} <- ensure_line(line),
         cost <- Float.round(line.unit_cost * quantity, 2),
         :ok <- ensure_cash(state.world, cost) do
      day = get(state.world, :day_number, 1)
      delivery_day = day + line.supplier_delay_days

      order = %{
        day: day,
        line_id: line_id,
        quantity: quantity,
        unit_cost: line.unit_cost,
        cost: cost,
        delivery_day: delivery_day,
        supplier: supplier_for(line.franchise)
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - cost, 2))
          |> Map.update(:pending_deliveries, [order], &(&1 ++ [order]))
          |> Map.update(:supplier_order_history, [order], &(&1 ++ [order]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "ordered #{quantity} units of #{line_id} for day #{delivery_day}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_buy_collection(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    budget = as_float(get(event.payload, "budget", 0.0))
    focus = get(event.payload, "focus", "mixed")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_cash(state.world, budget),
         :ok <- ensure_minimum(budget, 50.0) do
      day = get(state.world, :day_number, 1)
      multiplier = collection_multiplier(franchise, focus, day, get(state.world, :seed, 1))
      cards = max(1, trunc(budget / card_cost_for(focus)))
      market_value = Float.round(budget * multiplier, 2)

      buy = %{
        day: day,
        franchise: franchise,
        focus: focus,
        budget: budget,
        cards_added: cards,
        estimated_market_value: market_value
      }

      next =
        state
        |> State.update_world(fn world ->
          update_in(world, [:singles_case], fn singles ->
            singles
            |> Map.update(:cards_on_hand, cards, &(&1 + cards))
            |> Map.update(:total_market_value, market_value, &Float.round(&1 + market_value, 2))
          end)
          |> Map.update!(:bank_balance, &Float.round(&1 - budget, 2))
          |> Map.update(:buylist_history, [buy], &(&1 ++ [buy]))
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide, "bought #{franchise} collection with estimated value #{market_value}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_set_prices(%State{} = state, event) do
    markup_pct = as_float(get(event.payload, "markup_pct", 0.0))
    line_id = get(event.payload, "line_id", nil)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_markup(markup_pct),
         :ok <- ensure_optional_line(line_id) do
      day = get(state.world, :day_number, 1)

      next =
        state
        |> State.update_world(fn world ->
          catalog = get(world, :catalog, %{})
          inventory = get(world, :inventory, %{})

          updated =
            Enum.into(inventory, %{}, fn {id, item} ->
              if line_id in [nil, id] do
                line = Map.get(catalog, id, %{})
                price = Float.round(get(line, :market_price, 0.0) * (1.0 + markup_pct / 100.0), 2)
                {id, Map.put(item, :price, price)}
              else
                {id, item}
              end
            end)

          entry = %{day: day, line_id: line_id || "all", markup_pct: markup_pct}

          world
          |> Map.put(:inventory, updated)
          |> Map.update(:price_history, [entry], &(&1 ++ [entry]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "updated shelf prices"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_host_event(%State{} = state, event) do
    game = get(event.payload, "game")
    prize_budget = as_float(get(event.payload, "prize_budget", 0.0))
    entry_fee = as_float(get(event.payload, "entry_fee", 0.0))
    staff_cost = 45.0
    total_cost = prize_budget + staff_cost

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(game),
         :ok <- ensure_cash(state.world, total_cost) do
      world = state.world
      day = get(world, :day_number, 1)
      pulse = List.last(get(world, :market_pulses, [])) || %{}

      buzz =
        if get(pulse, :featured_franchise) == game,
          do: get(pulse, :buzz_multiplier, 1.0),
          else: 1.0

      attendance = max(4, trunc((8 + get(world, :reputation, 50) / 8 + prize_budget / 35) * buzz))
      entry_revenue = Float.round(attendance * entry_fee, 2)
      attach_sales = Float.round(attendance * (7.5 + min(prize_budget / 30, 20)), 2)
      reputation_gain = min(8, max(1, trunc(attendance / 5)))

      event_record = %{
        day: day,
        game: game,
        attendance: attendance,
        entry_revenue: entry_revenue,
        attach_sales: attach_sales,
        prize_budget: prize_budget
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(
            :bank_balance,
            &Float.round(&1 - total_cost + entry_revenue + attach_sales, 2)
          )
          |> reduce_matching_inventory(game, max(1, div(attendance, 8)))
          |> Map.update(:reputation, reputation_gain, &min(100, &1 + reputation_gain))
          |> Map.update(:tournament_history, [event_record], &(&1 ++ [event_record]))
          |> Map.update(:sales_history, [event_record], &(&1 ++ [event_record]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "hosted #{game} event with #{attendance} players"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_submit_grading(%State{} = state, event) do
    count = as_int(get(event.payload, "card_count", 0))
    service = get(event.payload, "service_level", "bulk")
    service_data = grading_service(service)
    singles = get(state.world, :singles_case, %{})
    cost = count * service_data.cost

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(count),
         :ok <- ensure_cards(singles, count),
         :ok <- ensure_cash(state.world, cost) do
      day = get(state.world, :day_number, 1)
      avg_value = get(singles, :total_market_value, 0.0) / max(get(singles, :cards_on_hand, 1), 1)
      raw_value = Float.round(avg_value * count, 2)

      submission = %{
        day: day,
        card_count: count,
        service_level: service,
        cost: cost,
        raw_value: raw_value,
        return_day: day + service_data.delay
      }

      next =
        state
        |> State.update_world(fn world ->
          update_in(world, [:singles_case], fn singles ->
            singles
            |> Map.update(:cards_on_hand, 0, &(&1 - count))
            |> Map.update(:total_market_value, 0.0, &Float.round(max(0.0, &1 - raw_value), 2))
          end)
          |> Map.update!(:bank_balance, &Float.round(&1 - cost, 2))
          |> Map.update(:pending_grading, [submission], &(&1 ++ [submission]))
          |> Map.update(:grading_history, [submission], &(&1 ++ [submission]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "submitted #{count} cards for grading"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_process_online_orders(%State{} = state, event) do
    quality = get(event.payload, "packing_quality", "standard")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_quality(quality) do
      world = state.world
      day = get(world, :day_number, 1)
      rating = get(world, :online_rating, 4.3)
      order_count = max(1, trunc(2 + rating + get(world, :reputation, 50) / 20))
      packing_cost = order_count * packing_cost(quality)
      revenue = fulfill_online_revenue(world, order_count)
      rating_delta = rating_delta(quality)

      record = %{
        day: day,
        order_count: order_count,
        revenue: revenue,
        packing_cost: packing_cost,
        packing_quality: quality
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 + revenue - packing_cost, 2))
          |> reduce_inventory_for_orders(order_count)
          |> Map.update(
            :online_rating,
            rating_delta,
            &Float.round(min(5.0, max(3.0, &1 + rating_delta)), 2)
          )
          |> Map.update(:online_order_history, [record], &(&1 ++ [record]))
          |> Map.update(:sales_history, [record], &(&1 ++ [record]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "processed #{order_count} online orders"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_wait_next_day(%State{} = state, event) do
    with :ok <- ensure_in_progress(state.world) do
      world = state.world
      current_day = get(world, :day_number, 1)
      next_day = current_day + 1
      max_days = get(world, :max_days, 14)
      seed = get(world, :seed, 1)
      calendar = get(world, :release_calendar, [])
      pulse = LemonSim.Examples.TcgShop.market_pulse(next_day, seed, calendar)

      {world, delivery_sales} =
        world
        |> apply_due_deliveries(next_day)
        |> apply_due_grading(next_day)
        |> apply_organic_sales(pulse)

      status =
        cond do
          get(world, :bank_balance, 0.0) < -500.0 -> "bankrupt"
          next_day > max_days -> "complete"
          true -> "in_progress"
        end

      next_world =
        world
        |> Map.put(:day_number, min(next_day, max_days))
        |> Map.put(:market_pulses, get(world, :market_pulses, []) ++ [pulse])
        |> Map.put(:customer_queue, customer_queue_for(next_day, pulse))
        |> Map.put(
          :competitor_snapshot,
          LemonSim.Examples.TcgShop.competitor_snapshot(next_day, seed)
        )
        |> Map.update!(:bank_balance, &Float.round(&1 - get(world, :daily_rent, 125.0), 2))
        |> Map.put(:status, status)

      next =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.day_advanced(min(next_day, max_days), delivery_sales, pulse))

      {:ok, next,
       if(status == "in_progress", do: {:decide, "advanced to day #{next_day}"}, else: :terminal)}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_due_deliveries(world, day) do
    {due, pending} =
      world
      |> get(:pending_deliveries, [])
      |> Enum.split_with(&(get(&1, :delivery_day, 0) <= day))

    delivered_world =
      Enum.reduce(due, world, fn delivery, acc ->
        line_id = get(delivery, :line_id)
        qty = get(delivery, :quantity, 0)
        update_in(acc, [:inventory, line_id, :on_hand], &((&1 || 0) + qty))
      end)

    Map.put(delivered_world, :pending_deliveries, pending)
  end

  defp apply_due_grading(world, day) do
    {due, pending} =
      world
      |> get(:pending_grading, [])
      |> Enum.split_with(&(get(&1, :return_day, 0) <= day))

    updated =
      Enum.reduce(due, world, fn submission, acc ->
        multiplier = grading_return_multiplier(submission)
        graded_value = Float.round(get(submission, :raw_value, 0.0) * multiplier, 2)

        graded_card = %{
          returned_day: day,
          card_count: get(submission, :card_count, 0),
          service_level: get(submission, :service_level, "bulk"),
          market_value: graded_value
        }

        update_in(acc, [:singles_case, :graded_cards], &((&1 || []) ++ [graded_card]))
      end)

    Map.put(updated, :pending_grading, pending)
  end

  defp apply_organic_sales(world, pulse) do
    catalog = get(world, :catalog, %{})
    inventory = get(world, :inventory, %{})
    reputation = get(world, :reputation, 50)
    buzz_franchise = get(pulse, :featured_franchise)
    buzz_multiplier = get(pulse, :buzz_multiplier, 1.0)
    day = get(world, :day_number, 1)

    {updated_inventory, sales, revenue} =
      Enum.reduce(inventory, {%{}, [], 0.0}, fn {line_id, item}, {inv_acc, sales_acc, rev_acc} ->
        line = Map.get(catalog, line_id, %{})
        on_hand = get(item, :on_hand, 0)
        price = get(item, :price, get(line, :suggested_price, 0.0))
        franchise = get(line, :franchise, "")
        demand_boost = if franchise == buzz_franchise, do: buzz_multiplier, else: 1.0
        price_drag = max(0.25, get(line, :market_price, 1.0) / max(price, 1.0))
        demand = get(line, :velocity, 1.0) * demand_boost * price_drag * (0.65 + reputation / 100)
        units = min(on_hand, trunc(demand))
        sale_value = Float.round(units * price, 2)
        item = Map.put(item, :on_hand, on_hand - units)

        sale =
          if units > 0 do
            [
              %{
                day: day,
                line_id: line_id,
                quantity: units,
                revenue: sale_value,
                channel: "walk_in"
              }
            ]
          else
            []
          end

        {Map.put(inv_acc, line_id, item), sales_acc ++ sale, rev_acc + sale_value}
      end)

    world =
      world
      |> Map.put(:inventory, updated_inventory)
      |> Map.update!(:bank_balance, &Float.round(&1 + revenue, 2))
      |> Map.update(:sales_history, sales, &(&1 ++ sales))

    {world, Float.round(revenue, 2)}
  end

  defp reject(%State{} = state, event, reason) do
    rejection = Events.action_rejected("operator", reason, event.kind)

    next =
      state
      |> State.update_world(fn world ->
        world
        |> Map.update(:invalid_action_count, 1, &(&1 + 1))
        |> Map.update(:reputation, -1, &max(0, &1 - 1))
      end)
      |> State.append_event(rejection)

    {:ok, next, {:decide, "action rejected: #{inspect(reason)}"}}
  end

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :not_in_progress}
  end

  defp ensure_line(nil), do: {:error, :unknown_product_line}
  defp ensure_line(line), do: {:ok, line}

  defp ensure_optional_line(nil), do: :ok

  defp ensure_optional_line(line_id),
    do: if(Catalog.line(line_id), do: :ok, else: {:error, :unknown_product_line})

  defp ensure_positive(value),
    do: if(value > 0, do: :ok, else: {:error, :quantity_must_be_positive})

  defp ensure_minimum(value, minimum),
    do: if(value >= minimum, do: :ok, else: {:error, {:below_minimum, minimum}})

  defp ensure_cash(world, cost) do
    if get(world, :bank_balance, 0.0) >= cost, do: :ok, else: {:error, :insufficient_cash}
  end

  defp ensure_franchise(franchise) do
    if franchise in (Catalog.franchises() -- ["Accessories"]),
      do: :ok,
      else: {:error, :unknown_franchise}
  end

  defp ensure_markup(markup),
    do: if(markup >= -20 and markup <= 80, do: :ok, else: {:error, :invalid_markup})

  defp ensure_quality(quality),
    do:
      if(quality in ["cheap", "standard", "premium"],
        do: :ok,
        else: {:error, :invalid_packing_quality}
      )

  defp ensure_cards(singles, count) do
    if get(singles, :cards_on_hand, 0) >= count, do: :ok, else: {:error, :not_enough_raw_singles}
  end

  defp supplier_for("Pokemon"), do: "gts_distribution"
  defp supplier_for("Accessories"), do: "gts_distribution"
  defp supplier_for("One Piece"), do: "premium_secondary"
  defp supplier_for(_), do: "alliance_distribution"

  defp collection_multiplier("One Piece", "chase", _day, _seed), do: 1.45
  defp collection_multiplier("Pokemon", "mixed", _day, _seed), do: 1.28
  defp collection_multiplier(_franchise, "bulk", _day, _seed), do: 1.08
  defp collection_multiplier(_franchise, "playables", _day, _seed), do: 1.22
  defp collection_multiplier(_franchise, "chase", _day, _seed), do: 1.34
  defp collection_multiplier(_franchise, _focus, _day, _seed), do: 1.18

  defp card_cost_for("bulk"), do: 0.35
  defp card_cost_for("playables"), do: 2.0
  defp card_cost_for("chase"), do: 12.0
  defp card_cost_for(_), do: 1.5

  defp grading_service("express"), do: %{cost: 38.0, delay: 2}
  defp grading_service("standard"), do: %{cost: 22.0, delay: 4}
  defp grading_service(_), do: %{cost: 14.0, delay: 7}

  defp grading_return_multiplier(%{service_level: "express"}), do: 1.42
  defp grading_return_multiplier(%{service_level: "standard"}), do: 1.34
  defp grading_return_multiplier(_), do: 1.24

  defp packing_cost("premium"), do: 2.25
  defp packing_cost("standard"), do: 1.15
  defp packing_cost(_), do: 0.45

  defp rating_delta("premium"), do: 0.04
  defp rating_delta("standard"), do: 0.01
  defp rating_delta(_), do: -0.08

  defp fulfill_online_revenue(world, order_count) do
    avg =
      world
      |> get(:inventory, %{})
      |> Enum.map(fn {_id, item} -> get(item, :price, 0.0) end)
      |> Enum.reject(&(&1 <= 0))
      |> case do
        [] -> 18.0
        prices -> Enum.sum(prices) / length(prices)
      end

    Float.round(order_count * min(avg, 65.0), 2)
  end

  defp reduce_inventory_for_orders(world, order_count) do
    ids =
      world
      |> get(:inventory, %{})
      |> Enum.filter(fn {_id, item} -> get(item, :on_hand, 0) > 0 end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(Enum.take(ids, order_count), world, fn id, acc ->
      update_in(acc, [:inventory, id, :on_hand], &max((&1 || 0) - 1, 0))
    end)
  end

  defp reduce_matching_inventory(world, game, units) do
    catalog = get(world, :catalog, %{})

    ids =
      world
      |> get(:inventory, %{})
      |> Enum.filter(fn {id, item} ->
        line = Map.get(catalog, id, %{})
        get(line, :franchise, "") in [game, "Accessories"] and get(item, :on_hand, 0) > 0
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(Enum.take(ids, units), world, fn id, acc ->
      update_in(acc, [:inventory, id, :on_hand], &max((&1 || 0) - 1, 0))
    end)
  end

  defp customer_queue_for(_day, pulse) do
    [
      %{
        type: "player",
        need: "#{get(pulse, :featured_franchise, "Pokemon")} sealed product",
        urgency: "high"
      },
      %{type: "collector", need: "graded chase cards and clean raw singles", urgency: "medium"},
      %{type: "competitive", need: "deck staples and sleeves", urgency: "high"}
    ]
  end

  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: MapHelpers.get_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp as_int(value) when is_integer(value), do: value
  defp as_int(value) when is_float(value), do: trunc(value)
  defp as_int(value) when is_binary(value), do: String.to_integer(value)
  defp as_int(_), do: 0

  defp as_float(value) when is_float(value), do: value
  defp as_float(value) when is_integer(value), do: value + 0.0
  defp as_float(value) when is_binary(value), do: String.to_float(value)
  defp as_float(_), do: 0.0
end
