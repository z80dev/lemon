defmodule LemonSim.Examples.TcgShop.Updaters.Purchasing do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Catalog
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_buy_collection(%State{} = state, event) do
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
      condition = collection_condition_profile(franchise, focus, day, get(state.world, :seed, 1))
      risk_discount = collection_risk_discount(condition)
      market_value = Float.round(budget * multiplier * risk_discount, 2)
      markdown_loss = Float.round(budget * multiplier * (1.0 - risk_discount), 2)
      credit_base = Float.round(budget * store_credit_share(focus), 2)
      store_credit_issued = Float.round(credit_base * 1.2, 2)
      cash_paid = Float.round(budget - credit_base, 2)

      buy = %{
        day: day,
        franchise: franchise,
        focus: focus,
        budget: budget,
        cash_paid: cash_paid,
        store_credit_issued: store_credit_issued,
        cards_added: cards,
        estimated_market_value: market_value,
        condition_mix: get(condition, :mix, %{}),
        authentication_risk_pct: get(condition, :authentication_risk_pct, 0),
        markdown_loss: markdown_loss
      }

      next =
        state
        |> State.update_world(fn world ->
          update_in(world, [:singles_case], fn singles ->
            singles
            |> Map.update(:cards_on_hand, cards, &(&1 + cards))
            |> Map.update(:total_market_value, market_value, &Float.round(&1 + market_value, 2))
          end)
          |> Map.update!(:bank_balance, &Float.round(&1 - cash_paid, 2))
          |> Finance.apply_store_credit_issue(store_credit_issued, "collection_buy", day)
          |> Map.update(:buylist_history, [buy], &(&1 ++ [buy]))
          |> Customers.update_customer_segment("collectors", %{
            loyalty_delta: 1,
            satisfaction_delta: 2,
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "fresh_collection_buy"
          })
          |> Staffing.consume_staff_hours(2.0, "collection_intake")
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide, "bought #{franchise} collection with estimated value #{market_value}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_open_sealed_product(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         {:ok, line} <- ensure_line(line),
         :ok <- ensure_sealed_line(line),
         :ok <- ensure_positive(quantity),
         :ok <- ensure_inventory_units(state.world, line_id, quantity) do
      world = state.world
      day = get(world, :day_number, 1)
      pulse = List.last(get(world, :market_pulses, [])) || %{}
      packs = sealed_pack_count(line_id) * quantity
      cards_added = packs * 10
      market_value_consumed = Float.round(get(line, :market_price, 0.0) * quantity, 2)
      cost_basis = Float.round(get(line, :unit_cost, 0.0) * quantity, 2)
      pull_multiplier = sealed_opening_multiplier(line, pulse, world, day, quantity)
      singles_value = Float.round(market_value_consumed * pull_multiplier, 2)
      chase_hits = sealed_chase_hits(line, world, day, quantity)

      opening = %{
        day: day,
        line_id: line_id,
        franchise: get(line, :franchise),
        quantity: quantity,
        packs_opened: packs,
        cards_added: cards_added,
        sealed_market_value_consumed: market_value_consumed,
        cost_basis: cost_basis,
        singles_market_value_added: singles_value,
        pull_multiplier: pull_multiplier,
        chase_hits: chase_hits,
        value_delta_vs_market: Float.round(singles_value - market_value_consumed, 2),
        value_delta_vs_cost: Float.round(singles_value - cost_basis, 2)
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> update_in([:inventory, line_id, :on_hand], &max((&1 || 0) - quantity, 0))
          |> update_in([:singles_case], fn singles ->
            singles
            |> Map.update(:cards_on_hand, cards_added, &(&1 + cards_added))
            |> Map.update(:total_market_value, singles_value, &Float.round(&1 + singles_value, 2))
          end)
          |> Map.update(:sealed_opening_history, [opening], &(&1 ++ [opening]))
          |> Customers.update_customer_segment(
            Customers.customer_segment_for_franchise(get(line, :franchise)),
            %{
              loyalty_delta: 1,
              satisfaction_delta: if(chase_hits > 0, do: 2, else: 1),
              visits_delta: 0,
              spend_delta: 0.0,
              reason: "fresh_singles_from_sealed"
            }
          )
          |> Staffing.consume_staff_hours(Float.round(0.35 + packs * 0.04, 2), "sealed_opening")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "opened #{quantity} #{line_id} into #{cards_added} raw singles"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_prepare_loose_packs(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    pack_price = as_float(get(event.payload, "pack_price", 0.0))
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         {:ok, line} <- ensure_line(line),
         :ok <- ensure_sealed_line(line),
         :ok <- ensure_positive(quantity),
         :ok <- ensure_minimum(pack_price, 1.0),
         :ok <- ensure_inventory_units(state.world, line_id, quantity) do
      world = state.world
      day = get(world, :day_number, 1)
      packs = sealed_pack_count(line_id) * quantity
      cost_basis = Float.round(get(line, :unit_cost, 0.0) * quantity, 2)
      market_value = Float.round(get(line, :market_price, 0.0) * quantity, 2)

      entry = %{
        day: day,
        line_id: line_id,
        franchise: get(line, :franchise),
        sealed_units_opened: quantity,
        packs_added: packs,
        pack_price: Float.round(pack_price, 2),
        cost_basis: cost_basis,
        market_value: market_value,
        cost_basis_per_pack: Float.round(cost_basis / max(packs, 1), 2),
        market_value_per_pack: Float.round(market_value / max(packs, 1), 2),
        type: "pack_preparation"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> update_in([:inventory, line_id, :on_hand], &max((&1 || 0) - quantity, 0))
          |> Map.update(
            :pack_inventory,
            %{},
            &add_pack_inventory(&1, line_id, line, packs, entry)
          )
          |> Map.update(:pack_preparation_history, [entry], &(&1 ++ [entry]))
          |> Customers.update_customer_segment(
            Customers.customer_segment_for_franchise(get(line, :franchise)),
            %{
              loyalty_delta: 1,
              satisfaction_delta: 1,
              visits_delta: 0,
              spend_delta: 0.0,
              reason: "fresh_loose_packs"
            }
          )
          |> Staffing.consume_staff_hours(Float.round(0.25 + packs * 0.01, 2), "pack_preparation")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "prepared #{packs} loose packs from #{quantity} #{line_id}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_sealed_line(line) do
    if get(line, :category) == "sealed",
      do: :ok,
      else: {:error, :sealed_opening_requires_sealed_product}
  end

  defp ensure_inventory_units(world, line_id, quantity) do
    on_hand =
      world
      |> get(:inventory, %{})
      |> get(line_id, %{})
      |> get(:on_hand, 0)

    if on_hand >= quantity,
      do: :ok,
      else: {:error, :not_enough_sealed_inventory}
  end

  defp store_credit_share("bulk"), do: 0.55
  defp store_credit_share("playables"), do: 0.35
  defp store_credit_share("chase"), do: 0.25
  defp store_credit_share(_focus), do: 0.4

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

  defp add_pack_inventory(pack_inventory, line_id, line, packs, entry) do
    existing = get(pack_inventory, line_id, %{})
    existing_packs = get(existing, :packs_on_hand, 0)
    next_packs = existing_packs + packs

    weighted_cost =
      weighted_pack_value(
        existing_packs,
        get(existing, :cost_basis_per_pack, get(entry, :cost_basis_per_pack, 0.0)),
        packs,
        get(entry, :cost_basis_per_pack, 0.0)
      )

    weighted_market =
      weighted_pack_value(
        existing_packs,
        get(existing, :market_value_per_pack, get(entry, :market_value_per_pack, 0.0)),
        packs,
        get(entry, :market_value_per_pack, 0.0)
      )

    pack =
      existing
      |> Map.merge(%{
        line_id: line_id,
        franchise: get(line, :franchise),
        source_name: get(line, :name),
        packs_on_hand: next_packs,
        pack_price: get(entry, :pack_price, 0.0),
        cost_basis_per_pack: weighted_cost,
        market_value_per_pack: weighted_market
      })

    Map.put(pack_inventory, line_id, pack)
  end

  defp weighted_pack_value(existing_units, existing_value, added_units, added_value) do
    total_units = existing_units + added_units

    if total_units > 0 do
      Float.round((existing_units * existing_value + added_units * added_value) / total_units, 2)
    else
      0.0
    end
  end

  defp sealed_pack_count("pokemon_elite_trainer_box"), do: 9
  defp sealed_pack_count(_line_id), do: 24

  defp sealed_opening_multiplier(line, pulse, world, day, quantity) do
    featured_bonus =
      if get(pulse, :featured_franchise) == get(line, :franchise) do
        min(0.18, (get(pulse, :buzz_multiplier, 1.0) - 1.0) / 4)
      else
        0.0
      end

    variance =
      rem(get(world, :seed, 1) + day * 7 + String.length(get(line, :id, "")) + quantity * 3, 9)

    (0.72 + featured_bonus + variance / 100)
    |> clamp_float(0.62, 1.08)
    |> Float.round(2)
  end

  defp sealed_chase_hits(line, world, day, quantity) do
    seed = get(world, :seed, 1)
    volatility = get(line, :volatility, 0.15)
    base = if volatility >= 0.2, do: 1, else: 0

    max(
      0,
      base + div(quantity, 2) + rem(seed + day + String.length(get(line, :franchise, "")), 3) - 1
    )
  end

  defp collection_condition_profile(franchise, focus, day, seed) do
    risk_offset = rem(seed + day + String.length(franchise), 4)

    base =
      case focus do
        "bulk" -> %{near_mint: 35, light_play: 40, moderate_play: 20, damaged: 5}
        "playables" -> %{near_mint: 58, light_play: 30, moderate_play: 10, damaged: 2}
        "chase" -> %{near_mint: 72, light_play: 20, moderate_play: 7, damaged: 1}
        _ -> %{near_mint: 52, light_play: 32, moderate_play: 13, damaged: 3}
      end

    authentication_risk =
      case franchise do
        "One Piece" -> 3 + risk_offset
        "Pokemon" -> 2 + div(risk_offset, 2)
        _ -> 1 + div(risk_offset, 2)
      end

    %{mix: base, authentication_risk_pct: authentication_risk}
  end

  defp collection_risk_discount(condition) do
    mix = get(condition, :mix, %{})
    damaged = get(mix, :damaged, 0)
    moderate = get(mix, :moderate_play, 0)
    auth_risk = get(condition, :authentication_risk_pct, 0)

    Float.round(max(0.65, 1.0 - damaged / 200 - moderate / 350 - auth_risk / 250), 3)
  end

  def apply_singles_sales(world, pulse) do
    singles = get(world, :singles_case, %{})
    cards_on_hand = get(singles, :cards_on_hand, 0)
    total_value = get(singles, :total_market_value, 0.0)

    if cards_on_hand <= 0 or total_value <= 0.0 do
      {world, 0.0, []}
    else
      reputation = get(world, :reputation, 50)
      buzz = get(pulse, :buzz_multiplier, 1.0)
      day = get(pulse, :day, get(world, :day_number, 1))
      average_value = total_value / cards_on_hand
      cards_sold = min(cards_on_hand, max(1, trunc((2 + reputation / 25) * min(buzz, 1.8))))
      raw_value = Float.round(average_value * cards_sold, 2)
      revenue = Float.round(raw_value * 0.92, 2)

      sale = %{
        day: day,
        channel: "singles_case",
        segment_id: "collectors",
        quantity: cards_sold,
        revenue: revenue,
        cost_of_goods_sold: raw_value,
        gross_profit: Float.round(revenue - raw_value, 2),
        sales_tax_collected: Finance.sales_tax_for(world, revenue),
        market_value_removed: raw_value
      }

      next =
        update_in(world, [:singles_case], fn singles ->
          singles
          |> Map.update(:cards_on_hand, 0, &max(&1 - cards_sold, 0))
          |> Map.update(:total_market_value, 0.0, &Float.round(max(&1 - raw_value, 0.0), 2))
        end)

      {next, revenue, [sale]}
    end
  end

  def apply_pack_sales(world, pulse) do
    pack_inventory = get(world, :pack_inventory, %{})

    if pack_inventory == %{} do
      {world, 0.0, []}
    else
      reputation = get(world, :reputation, 50)
      day = get(pulse, :day, get(world, :day_number, 1))
      featured = get(pulse, :featured_franchise)

      {next_inventory, sales, revenue} =
        Enum.reduce(pack_inventory, {%{}, [], 0.0}, fn {line_id, pack},
                                                       {inv_acc, sales_acc, revenue_acc} ->
          packs_on_hand = get(pack, :packs_on_hand, 0)
          pack_price = get(pack, :pack_price, 0.0)
          market_value = get(pack, :market_value_per_pack, pack_price)
          franchise = get(pack, :franchise)
          segment_id = Customers.customer_segment_for_franchise(franchise)

          buzz =
            if franchise == featured, do: min(1.8, get(pulse, :buzz_multiplier, 1.0)), else: 1.0

          price_drag = max(0.3, market_value / max(pack_price, 0.01))
          demand = (1.5 + reputation / 28) * buzz * price_drag
          units = min(packs_on_hand, max(0, trunc(demand)))
          revenue = Float.round(units * pack_price, 2)
          cost_of_goods_sold = Float.round(units * get(pack, :cost_basis_per_pack, 0.0), 2)
          remaining = packs_on_hand - units

          next_pack =
            pack
            |> Map.put(:packs_on_hand, remaining)

          sale =
            if units > 0 do
              [
                %{
                  day: day,
                  line_id: line_id,
                  channel: "loose_packs",
                  segment_id: segment_id,
                  franchise: franchise,
                  quantity: units,
                  revenue: revenue,
                  cost_of_goods_sold: cost_of_goods_sold,
                  gross_profit: Float.round(revenue - cost_of_goods_sold, 2),
                  sales_tax_collected: Finance.sales_tax_for(world, revenue),
                  pack_price: pack_price,
                  cost_basis_per_pack: get(pack, :cost_basis_per_pack, 0.0)
                }
              ]
            else
              []
            end

          {Map.put(inv_acc, line_id, next_pack), sales_acc ++ sale, revenue_acc + revenue}
        end)

      {Map.put(world, :pack_inventory, next_inventory), Float.round(revenue, 2), sales}
    end
  end
end
