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
      "tcg_open_sealed_product" -> apply_open_sealed_product(state, event)
      "tcg_prepare_loose_packs" -> apply_prepare_loose_packs(state, event)
      "tcg_take_consignment" -> apply_take_consignment(state, event)
      "tcg_sell_memberships" -> apply_sell_memberships(state, event)
      "tcg_schedule_staff_shift" -> apply_schedule_staff_shift(state, event)
      "tcg_upgrade_loss_prevention" -> apply_upgrade_loss_prevention(state, event)
      "tcg_manage_credit_line" -> apply_manage_credit_line(state, event)
      "tcg_make_bank_deposit" -> apply_make_bank_deposit(state, event)
      "tcg_set_prices" -> apply_set_prices(state, event)
      "tcg_host_event" -> apply_host_event(state, event)
      "tcg_take_preorders" -> apply_take_preorders(state, event)
      "tcg_take_special_order" -> apply_take_special_order(state, event)
      "tcg_run_promotion" -> apply_run_promotion(state, event)
      "tcg_manage_online_channel" -> apply_manage_online_channel(state, event)
      "tcg_file_supplier_claim" -> apply_file_supplier_claim(state, event)
      "tcg_process_customer_return" -> apply_process_customer_return(state, event)
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
      notes:
        get(event.payload, "notes", [
          "Sealed margins depend on allocation and cash discipline.",
          "Singles demand decays quickly after metagame spikes.",
          "Events convert players into accessory and singles buyers."
        ]),
      source: "local_market_research",
      confidence: "operating_estimate"
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
         allocated_quantity <- allocated_quantity(line, quantity, state.world),
         :ok <- ensure_positive_allocation(allocated_quantity),
         cost <- Float.round(line.unit_cost * allocated_quantity, 2),
         :ok <- ensure_supplier_credit(state.world, cost) do
      day = get(state.world, :day_number, 1)
      delivery_day = day + line.supplier_delay_days
      terms_days = get(state.world, :supplier_terms_days, 7)
      invoice_id = supplier_invoice_id(state.world, day, line_id)
      supplier = supplier_for(line.franchise)

      order = %{
        day: day,
        line_id: line_id,
        requested_quantity: quantity,
        quantity: allocated_quantity,
        unit_cost: line.unit_cost,
        cost: cost,
        delivery_day: delivery_day,
        invoice_id: invoice_id,
        invoice_due_day: delivery_day + terms_days,
        payment_terms_days: terms_days,
        payment_status: "invoiced",
        supplier: supplier,
        supplier_standing: supplier_account_standing(state.world, supplier),
        allocation_rate: Float.round(allocated_quantity / quantity, 2),
        allocation_note: allocation_note(quantity, allocated_quantity, line.franchise)
      }

      invoice = supplier_invoice_for_order(order)

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update(:pending_deliveries, [order], &(&1 ++ [order]))
          |> Map.update(:supplier_order_history, [order], &(&1 ++ [order]))
          |> Map.update(:pending_supplier_invoices, [invoice], &(&1 ++ [invoice]))
          |> Map.update(:supplier_invoice_history, [invoice], &(&1 ++ [invoice]))
          |> consume_staff_hours(
            Float.round(0.4 + allocated_quantity * 0.03, 2),
            "supplier_order"
          )
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "ordered #{allocated_quantity}/#{quantity} allocated units of #{line_id} for day #{delivery_day}"}}
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
          |> apply_store_credit_issue(store_credit_issued, "collection_buy", day)
          |> Map.update(:buylist_history, [buy], &(&1 ++ [buy]))
          |> update_customer_segment("collectors", %{
            loyalty_delta: 1,
            satisfaction_delta: 2,
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "fresh_collection_buy"
          })
          |> consume_staff_hours(2.0, "collection_intake")
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide, "bought #{franchise} collection with estimated value #{market_value}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_open_sealed_product(%State{} = state, event) do
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
          |> update_customer_segment(customer_segment_for_franchise(get(line, :franchise)), %{
            loyalty_delta: 1,
            satisfaction_delta: if(chase_hits > 0, do: 2, else: 1),
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "fresh_singles_from_sealed"
          })
          |> consume_staff_hours(Float.round(0.35 + packs * 0.04, 2), "sealed_opening")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "opened #{quantity} #{line_id} into #{cards_added} raw singles"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_prepare_loose_packs(%State{} = state, event) do
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
          |> update_customer_segment(customer_segment_for_franchise(get(line, :franchise)), %{
            loyalty_delta: 1,
            satisfaction_delta: 1,
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "fresh_loose_packs"
          })
          |> consume_staff_hours(Float.round(0.25 + packs * 0.01, 2), "pack_preparation")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "prepared #{packs} loose packs from #{quantity} #{line_id}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_take_consignment(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    card_count = as_int(get(event.payload, "card_count", 0))
    estimated_value = as_float(get(event.payload, "estimated_value", 0.0))
    commission_pct = as_float(get(event.payload, "commission_pct", 15.0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_positive(card_count),
         :ok <- ensure_minimum(estimated_value, 25.0),
         :ok <- ensure_commission_pct(commission_pct) do
      day = get(state.world, :day_number, 1)

      lot = %{
        id: consignment_lot_id(state.world, day, franchise),
        day: day,
        franchise: franchise,
        card_count: card_count,
        cards_remaining: card_count,
        estimated_value: Float.round(estimated_value, 2),
        value_remaining: Float.round(estimated_value, 2),
        commission_pct: commission_pct,
        status: "open"
      }

      entry = Map.merge(lot, %{type: "intake"})

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update(:consignment_lots, [lot], &(&1 ++ [lot]))
          |> Map.update(:consignment_history, [entry], &(&1 ++ [entry]))
          |> update_customer_segment("collectors", %{
            loyalty_delta: 2,
            satisfaction_delta: 2,
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "consignment_intake"
          })
          |> consume_staff_hours(Float.round(0.6 + card_count * 0.03, 2), "consignment_intake")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "accepted #{card_count} #{franchise} consignment cards"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_sell_memberships(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    count = as_int(get(event.payload, "count", 0))
    fee = as_float(get(event.payload, "fee", 0.0))
    duration_days = as_int(get(event.payload, "duration_days", 0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_positive(count),
         :ok <- ensure_minimum(fee, 5.0),
         :ok <- ensure_membership_duration(duration_days) do
      day = get(state.world, :day_number, 1)
      collected = Float.round(count * fee, 2)
      segment_id = customer_segment_for_franchise(franchise)

      batch = %{
        id: membership_batch_id(state.world, day, franchise),
        day: day,
        franchise: franchise,
        segment_id: segment_id,
        member_count: count,
        fee: Float.round(fee, 2),
        duration_days: duration_days,
        remaining_days: duration_days,
        collected: collected,
        remaining_value: collected,
        status: "active"
      }

      entry = Map.merge(batch, %{type: "sold"})

      next =
        state
        |> State.update_world(fn world ->
          world
          |> apply_local_tender(collected, "membership_sale", day)
          |> apply_local_sales_tax(collected, "membership_sale", day)
          |> apply_local_transaction_costs(collected, "membership_sale", day,
            transaction_count: max(1, count)
          )
          |> Map.update(:active_memberships, [batch], &(&1 ++ [batch]))
          |> Map.update(:membership_liability, collected, &Float.round(&1 + collected, 2))
          |> Map.update(:membership_history, [entry], &(&1 ++ [entry]))
          |> update_customer_segment(segment_id, %{
            loyalty_delta: 3,
            satisfaction_delta: 2,
            visits_delta: count,
            spend_delta: collected,
            reason: "membership_sale"
          })
          |> consume_staff_hours(Float.round(0.4 + count * 0.04, 2), "membership_sale")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "sold #{count} #{franchise} memberships"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_schedule_staff_shift(%State{} = state, event) do
    role = get(event.payload, "role")
    hours = as_float(get(event.payload, "hours", 0.0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_staff_role(role),
         :ok <- ensure_positive(hours),
         :ok <- ensure_staff_shift_hours(hours) do
      day = get(state.world, :day_number, 1)
      hourly_wage = staff_role_wage(role)
      labor_cost = Float.round(hours * hourly_wage, 2)

      with :ok <- ensure_cash(state.world, labor_cost) do
        operations = get(state.world, :operations, default_operations())
        current_backlog = get(operations, :backlog_tasks, [])
        backlog_cleared = min(length(current_backlog), trunc(hours / 3))
        fatigue_relief = if(hours >= 4.0, do: 1, else: 0)

        entry = %{
          day: day,
          role: role,
          hours: Float.round(hours, 2),
          hourly_wage: hourly_wage,
          labor_cost: labor_cost,
          backlog_cleared: backlog_cleared,
          fatigue_relief: fatigue_relief,
          type: "scheduled_shift"
        }

        next =
          state
          |> State.update_world(fn world ->
            world
            |> Map.update!(:bank_balance, &Float.round(&1 - labor_cost, 2))
            |> Map.update(:staffing_history, [entry], &(&1 ++ [entry]))
            |> update_in([:operations], fn operations ->
              operations = operations || default_operations()

              operations
              |> Map.update(:scheduled_staff_hours, hours, &Float.round(&1 + hours, 2))
              |> Map.update(
                :scheduled_staff_hours_remaining,
                hours,
                &Float.round(&1 + hours, 2)
              )
              |> Map.update(:scheduled_staff_cost, labor_cost, &Float.round(&1 + labor_cost, 2))
              |> Map.update(:fatigue, 0, &max(0, &1 - fatigue_relief))
              |> Map.update(:backlog_tasks, [], &Enum.drop(&1, backlog_cleared))
            end)
          end)
          |> State.append_event(event)

        {:ok, next, {:decide, "scheduled #{hours} hours of #{role} coverage"}}
      else
        {:error, reason} -> reject(state, event, reason)
      end
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_upgrade_loss_prevention(%State{} = state, event) do
    control = get(event.payload, "control")

    with :ok <- ensure_in_progress(state.world),
         {:ok, option} <- loss_prevention_option(control),
         :ok <- ensure_loss_prevention_not_installed(state.world, control),
         :ok <- ensure_cash(state.world, get(option, :cost, 0.0)) do
      day = get(state.world, :day_number, 1)
      cost = get(option, :cost, 0.0)
      protection = get(option, :protection, 0)

      entry = %{
        day: day,
        control: control,
        label: get(option, :label),
        cost: cost,
        protection_score: protection,
        type: "loss_prevention_upgrade"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - cost, 2))
          |> Map.update(:loss_prevention_score, protection, &min(80, &1 + protection))
          |> Map.update(:loss_prevention_history, [entry], &(&1 ++ [entry]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "installed #{control} loss-prevention control"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_manage_credit_line(%State{} = state, event) do
    action = get(event.payload, "action")
    amount = as_float(get(event.payload, "amount", 0.0))
    reason = get(event.payload, "reason", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_credit_action(action),
         :ok <- ensure_minimum(amount, 50.0),
         :ok <- ensure_credit_capacity(state.world, action, amount) do
      day = get(state.world, :day_number, 1)

      entry = %{
        day: day,
        action: action,
        amount: Float.round(amount, 2),
        reason: reason,
        balance_after: credit_line_balance_after(state.world, action, amount),
        type: action
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> apply_credit_line_action(action, amount)
          |> Map.update(:debt_history, [entry], &(&1 ++ [entry]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "#{action} credit line #{Float.round(amount, 2)}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_make_bank_deposit(%State{} = state, event) do
    amount = as_float(get(event.payload, "amount", 0.0))
    reason = get(event.payload, "reason", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(amount),
         :ok <- ensure_cash_drawer(state.world, amount) do
      day = get(state.world, :day_number, 1)

      entry = %{
        day: day,
        type: "bank_deposit",
        source: "bank_deposit",
        amount: Float.round(amount, 2),
        reason: reason
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:cash_drawer_balance, &Float.round(&1 - amount, 2))
          |> Map.update!(:bank_balance, &Float.round(&1 + amount, 2))
          |> Map.update(:cash_handling_history, [entry], &(&1 ++ [entry]))
          |> consume_staff_hours(0.15, "bank_deposit")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "deposited $#{amount} from register cash"}}
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
          |> consume_staff_hours(0.75, "price_update")
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
    sanctioned = get(event.payload, "sanctioned", true)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(game) do
      world = state.world
      day = get(world, :day_number, 1)
      pulse = List.last(get(world, :market_pulses, [])) || %{}
      play_space = get(world, :play_space, %{})
      seats = max(4, as_int(get(play_space, :seats, 32)))
      sanction_fee = if sanctioned, do: as_float(get(play_space, :sanction_fee, 6.0)), else: 0.0

      buzz =
        if get(pulse, :featured_franchise) == game,
          do: get(pulse, :buzz_multiplier, 1.0),
          else: 1.0

      requested_attendance =
        max(4, trunc((8 + get(world, :reputation, 50) / 8 + prize_budget / 35) * buzz))

      no_shows = event_no_shows(world, game, day, requested_attendance)
      attendance_demand = max(0, requested_attendance - no_shows)
      attendance = min(seats, attendance_demand)
      turn_aways = max(0, attendance_demand - seats)
      event_hours = Float.round(3.0 + attendance / 18, 2)

      judge_cost =
        Float.round(event_hours * as_float(get(play_space, :judge_hourly_wage, 20.0)), 2)

      event_operating_cost = Float.round(judge_cost + sanction_fee, 2)
      entry_revenue = Float.round(attendance * entry_fee, 2)
      attach_sales = Float.round(attendance * (7.5 + min(prize_budget / 30, 20)), 2)
      reputation_gain = min(8, max(1, trunc(attendance / 5)))
      attach_units = max(1, div(attendance, 8))
      prize_support = prize_support_for(world, game, prize_budget)
      prize_world = apply_prize_support_lines(world, get(prize_support, :lines, []))
      attach_cogs = matching_inventory_cogs(prize_world, game, attach_units)

      event_cogs =
        Float.round(
          get(prize_support, :inventory_cost, 0.0) +
            get(prize_support, :store_credit_issued, 0.0) + attach_cogs,
          2
        )

      event_revenue = Float.round(entry_revenue + attach_sales, 2)

      event_record =
        %{
          day: day,
          game: game,
          sanctioned: sanctioned,
          seat_capacity: seats,
          requested_attendance: requested_attendance,
          no_shows: no_shows,
          turn_aways: turn_aways,
          attendance: attendance,
          capacity_utilization_pct: Float.round(attendance / seats * 100, 2),
          entry_revenue: entry_revenue,
          attach_sales: attach_sales,
          revenue: event_revenue,
          sanction_fee: sanction_fee,
          judge_cost: judge_cost,
          operating_cost: event_operating_cost,
          cost_of_goods_sold: event_cogs,
          gross_profit: Float.round(event_revenue - event_cogs, 2),
          sales_tax_collected: sales_tax_for(world, attach_sales),
          prize_budget: prize_budget
        }
        |> Map.merge(prize_support_record(prize_support))

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - event_operating_cost, 2))
          |> apply_local_tender(entry_revenue + attach_sales, "store_event", day)
          |> apply_local_sales_tax(attach_sales, "store_event", day)
          |> apply_local_transaction_costs(entry_revenue + attach_sales, "store_event", day,
            transaction_count: attendance
          )
          |> apply_prize_support_lines(get(prize_support, :lines, []))
          |> apply_store_credit_issue(
            get(prize_support, :store_credit_issued, 0.0),
            "event_prize_support",
            day
          )
          |> reduce_matching_inventory(game, attach_units)
          |> Map.update(:reputation, reputation_gain, &min(100, &1 + reputation_gain))
          |> Map.update(:tournament_history, [event_record], &(&1 ++ [event_record]))
          |> Map.update(:sales_history, [event_record], &(&1 ++ [event_record]))
          |> update_customer_segment(customer_segment_for_franchise(game), %{
            loyalty_delta: min(5, reputation_gain),
            satisfaction_delta: min(6, reputation_gain + 1),
            visits_delta: attendance,
            spend_delta: entry_revenue + attach_sales,
            reason: "store_event"
          })
          |> consume_staff_hours(event_hours, "store_event")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "hosted #{game} event with #{attendance} players"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_take_preorders(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    deposit_pct = as_float(get(event.payload, "deposit_pct", 25.0))
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(quantity),
         {:ok, line} <- ensure_line(line),
         :ok <- ensure_preorder_line(line),
         :ok <- ensure_deposit_pct(deposit_pct) do
      day = get(state.world, :day_number, 1)
      release_day = next_release_day(state.world, line.franchise, day)
      unit_price = preorder_unit_price(state.world, line_id, line)
      total_price = Float.round(unit_price * quantity, 2)
      deposit_collected = Float.round(total_price * deposit_pct / 100, 2)

      preorder = %{
        day: day,
        line_id: line_id,
        franchise: line.franchise,
        quantity: quantity,
        remaining_quantity: quantity,
        unit_price: unit_price,
        total_price: total_price,
        deposit_pct: deposit_pct,
        deposit_collected: deposit_collected,
        release_day: release_day,
        status: "open"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> apply_local_tender(deposit_collected, "preorder_deposit", day)
          |> apply_local_transaction_costs(deposit_collected, "preorder_deposit", day,
            transaction_count: 1
          )
          |> Map.update(:pending_preorders, [preorder], &(&1 ++ [preorder]))
          |> Map.update(:preorder_history, [preorder], &(&1 ++ [preorder]))
          |> update_customer_segment(customer_segment_for_franchise(line.franchise), %{
            loyalty_delta: 1,
            satisfaction_delta: 1,
            visits_delta: 0,
            spend_delta: deposit_collected,
            reason: "preorder_deposit"
          })
          |> consume_staff_hours(Float.round(0.35 + quantity * 0.04, 2), "preorder_intake")
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "reserved #{quantity} #{line_id} for day #{release_day} with $#{deposit_collected} deposits"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_take_special_order(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    deposit_pct = as_float(get(event.payload, "deposit_pct", 25.0))
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(quantity),
         {:ok, line} <- ensure_line(line),
         :ok <- ensure_deposit_pct(deposit_pct) do
      day = get(state.world, :day_number, 1)
      unit_price = special_order_unit_price(state.world, line_id, line)
      total_price = Float.round(unit_price * quantity, 2)
      deposit_collected = Float.round(total_price * deposit_pct / 100, 2)
      segment_id = customer_segment_for_franchise(line.franchise)

      order = %{
        id: special_order_id(state.world, day, line_id),
        day: day,
        line_id: line_id,
        franchise: line.franchise,
        customer_segment_id: segment_id,
        quantity: quantity,
        remaining_quantity: quantity,
        unit_price: unit_price,
        total_price: total_price,
        deposit_pct: deposit_pct,
        deposit_collected: deposit_collected,
        deposit_remaining: deposit_collected,
        due_day: day + 1,
        status: "open"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> apply_local_tender(deposit_collected, "special_order_deposit", day)
          |> apply_local_transaction_costs(deposit_collected, "special_order_deposit", day,
            transaction_count: 1
          )
          |> Map.update(
            :special_order_liability,
            deposit_collected,
            &Float.round(&1 + deposit_collected, 2)
          )
          |> Map.update(:pending_special_orders, [order], &(&1 ++ [order]))
          |> Map.update(:special_order_history, [order], &(&1 ++ [order]))
          |> update_customer_segment(segment_id, %{
            loyalty_delta: 1,
            satisfaction_delta: 1,
            visits_delta: 0,
            spend_delta: deposit_collected,
            reason: "special_order_deposit"
          })
          |> consume_staff_hours(Float.round(0.25 + quantity * 0.03, 2), "special_order_intake")
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "took special order #{order.id} for #{quantity} #{line_id} with $#{deposit_collected} deposit"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_run_promotion(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    channel = get(event.payload, "channel", "social_ads")
    budget = as_float(get(event.payload, "budget", 0.0))
    duration_days = as_int(get(event.payload, "duration_days", 1))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_promotion_channel(channel),
         :ok <- ensure_minimum(budget, 25.0),
         :ok <- ensure_duration(duration_days),
         :ok <- ensure_cash(state.world, budget) do
      day = get(state.world, :day_number, 1)
      promotion = build_promotion(franchise, channel, budget, duration_days, day, state.world)

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - budget, 2))
          |> Map.update(:active_promotions, [promotion], &(&1 ++ [promotion]))
          |> Map.update(:promotion_history, [promotion], &(&1 ++ [promotion]))
          |> update_customer_segment(customer_segment_for_franchise(franchise), %{
            loyalty_delta: 1,
            satisfaction_delta: 1,
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "promotion"
          })
          |> consume_staff_hours(Float.round(0.45 + duration_days * 0.12, 2), "promotion")
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "started #{channel} promotion for #{franchise} through day #{promotion.ends_day}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_manage_online_channel(%State{} = state, event) do
    platform = get(event.payload, "platform")
    listing_quality = get(event.payload, "listing_quality", "basic")

    with :ok <- ensure_in_progress(state.world),
         {:ok, profile} <- online_channel_profile(platform, listing_quality),
         :ok <- ensure_cash(state.world, get(profile, :setup_cost, 0.0)) do
      day = get(state.world, :day_number, 1)
      setup_cost = get(profile, :setup_cost, 0.0)

      channel =
        profile
        |> Map.put(:platform, platform)
        |> Map.put(:listing_quality, listing_quality)

      entry =
        channel
        |> Map.put(:day, day)
        |> Map.put(:type, "online_channel_update")

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - setup_cost, 2))
          |> Map.put(:online_channel, channel)
          |> Map.update(:online_channel_history, [entry], &(&1 ++ [entry]))
          |> consume_staff_hours(online_listing_hours(listing_quality), "online_listing")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "updated online channel to #{platform}/#{listing_quality}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_file_supplier_claim(%State{} = state, event) do
    invoice_id = get(event.payload, "invoice_id")
    damaged_units = as_int(get(event.payload, "damaged_units", 0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(damaged_units),
         {:ok, receipt} <- claimable_delivery_receipt(state.world, invoice_id, damaged_units) do
      day = get(state.world, :day_number, 1)
      claim_amount = supplier_claim_amount(receipt, damaged_units)

      pending_invoice? =
        Enum.any?(get(state.world, :pending_supplier_invoices, []), &(get(&1, :id) == invoice_id))

      claim = %{
        day: day,
        invoice_id: invoice_id,
        supplier: get(receipt, :supplier),
        line_id: get(receipt, :line_id),
        damaged_units: damaged_units,
        claim_amount: claim_amount,
        settlement: if(pending_invoice?, do: "invoice_credit", else: "cash_reimbursement"),
        type: "supplier_damage_claim"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> settle_supplier_claim(claim)
          |> mark_delivery_receipt_claimed(invoice_id, damaged_units, claim_amount)
          |> Map.update(:supplier_claim_history, [claim], &(&1 ++ [claim]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "filed supplier claim for #{damaged_units} damaged units"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp apply_process_customer_return(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    condition = get(event.payload, "condition", "sealed_resellable")
    resolution = get(event.payload, "resolution", "store_credit")
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         {:ok, line} <- ensure_line(line),
         :ok <- ensure_positive(quantity),
         :ok <- ensure_return_condition(condition),
         :ok <- ensure_return_resolution(resolution),
         {:ok, sold} <- eligible_return_sale_totals(state.world, line_id, quantity) do
      day = get(state.world, :day_number, 1)
      refund_rate = return_refund_rate(condition)
      unit_price = get(sold, :unit_price, 0.0)
      unit_cogs = get(sold, :unit_cogs, 0.0)
      refund_amount = Float.round(unit_price * quantity * refund_rate, 2)
      restocked_units = if condition == "sealed_resellable", do: quantity, else: 0
      cogs_recovered = Float.round(unit_cogs * restocked_units, 2)
      writeoff_loss = Float.round(unit_cogs * (quantity - restocked_units), 2)

      return_entry = %{
        day: day,
        line_id: line_id,
        franchise: get(line, :franchise),
        quantity: quantity,
        condition: condition,
        resolution: resolution,
        refund_rate: refund_rate,
        refund_amount: refund_amount,
        restocked_units: restocked_units,
        cogs_recovered: cogs_recovered,
        writeoff_loss: writeoff_loss,
        average_sale_price: unit_price,
        type: "customer_return"
      }

      refund_entry = %{
        day: day,
        source: "customer_return",
        issue_key:
          "return:#{day}:#{line_id}:#{length(get(state.world, :return_history, [])) + 1}",
        line_id: line_id,
        refund_amount: refund_amount,
        chargeback: false,
        note: "#{condition} return resolved as #{resolution}"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> apply_return_resolution(resolution, refund_amount, day)
          |> restock_returned_inventory(line_id, restocked_units)
          |> Map.update(:return_history, [return_entry], &(&1 ++ [return_entry]))
          |> Map.update(:refund_history, [refund_entry], &(&1 ++ [refund_entry]))
          |> update_customer_segment(customer_segment_for_franchise(get(line, :franchise)), %{
            loyalty_delta: if(resolution == "store_credit", do: 1, else: 0),
            satisfaction_delta: return_satisfaction_delta(condition),
            visits_delta: 0,
            spend_delta: -refund_amount,
            reason: "customer_return"
          })
          |> consume_staff_hours(Float.round(0.25 + quantity * 0.06, 2), "customer_return")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "processed #{quantity} #{line_id} customer returns"}}
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
      grading_profile = grading_submission_profile(state.world, count)

      submission = %{
        day: day,
        card_count: count,
        service_level: service,
        cost: cost,
        raw_value: raw_value,
        condition_mix: get(grading_profile, :condition_mix, %{}),
        authentication_risk_pct: get(grading_profile, :authentication_risk_pct, 0),
        expected_authentication_failures:
          get(grading_profile, :expected_authentication_failures, 0),
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
          |> consume_staff_hours(Float.round(0.75 + count * 0.03, 2), "grading_prep")
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
      channel = get(world, :online_channel, default_online_channel())

      order_count =
        max(
          1,
          trunc(
            (2 + rating + get(world, :reputation, 50) / 20) * online_demand_multiplier(channel)
          )
        )

      packing_cost = order_count * packing_cost(quality)
      marketplace_fee_rate = get(channel, :marketplace_fee_rate, 0.0)

      record = %{
        day: day,
        platform: get(channel, :platform, "local_pickup"),
        listing_quality: get(channel, :listing_quality, "basic"),
        requested_count: order_count,
        fulfilled_count: 0,
        backorder_count: 0,
        revenue: 0.0,
        packing_cost: packing_cost,
        packing_quality: quality,
        marketplace_fee_rate: marketplace_fee_rate,
        lines: []
      }

      {fulfilled_world, revenue, fulfilled_count, backorder_count, lines} =
        fulfill_online_orders(world, order_count)

      complaint_count = complaint_count(quality, fulfilled_count, backorder_count)
      rating_delta = rating_delta(quality) - backorder_count * 0.03 - complaint_count * 0.05

      record =
        Map.merge(record, %{
          fulfilled_count: fulfilled_count,
          backorder_count: backorder_count,
          revenue: revenue,
          cost_of_goods_sold: online_cogs(lines),
          gross_profit: Float.round(revenue - online_cogs(lines), 2),
          sales_tax_collected: sales_tax_for(fulfilled_world, revenue),
          shipping_label_cost: shipping_label_cost(fulfilled_world, fulfilled_count),
          marketplace_fee: marketplace_fee_for(revenue, marketplace_fee_rate),
          lines: lines
        })

      issue =
        if complaint_count > 0 or backorder_count > 0 do
          %{
            day: day,
            source: "online_orders",
            packing_quality: quality,
            complaints: complaint_count,
            backorders: backorder_count,
            note: service_issue_note(complaint_count, backorder_count)
          }
        end

      stockout =
        if backorder_count > 0 do
          %{
            day: day,
            source: "online_orders",
            line_id: "mixed_online_cart",
            lost_units: backorder_count
          }
        end

      next =
        state
        |> State.update_world(fn _world ->
          fulfilled_world
          |> Map.update!(:bank_balance, &Float.round(&1 + revenue - packing_cost, 2))
          |> apply_sales_tax(revenue, "online_orders", day)
          |> apply_transaction_costs(revenue, "online_orders", day,
            transaction_count: fulfilled_count,
            shipped_orders: fulfilled_count,
            marketplace_fee_rate: marketplace_fee_rate,
            marketplace_platform: get(channel, :platform, "local_pickup")
          )
          |> Map.update(
            :online_rating,
            rating_delta,
            &Float.round(min(5.0, max(3.0, &1 + rating_delta)), 2)
          )
          |> Map.update(:reputation, 0, &max(0, &1 - min(6, backorder_count + complaint_count)))
          |> Map.update(:online_order_history, [record], &(&1 ++ [record]))
          |> maybe_append(:service_issue_history, issue)
          |> maybe_append(:stockout_history, stockout)
          |> Map.update(:sales_history, [record], &(&1 ++ [record]))
          |> update_customer_segment("online_buyers", %{
            loyalty_delta: if(backorder_count > 0, do: -2, else: 1),
            satisfaction_delta: rating_delta_to_customer_delta(rating_delta),
            visits_delta: fulfilled_count,
            spend_delta: revenue,
            reason: "online_fulfillment"
          })
          |> consume_staff_hours(
            Float.round(0.5 + fulfilled_count * 0.18, 2),
            "online_fulfillment"
          )
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
        |> apply_market_movement(next_day, pulse)
        |> apply_due_preorders(next_day)
        |> apply_due_special_orders(next_day)
        |> apply_organic_sales(pulse)
        |> apply_daily_shrinkage(next_day)
        |> apply_daily_refunds(next_day)
        |> apply_inventory_aging_and_markdowns(next_day)
        |> apply_cash_reconciliation(next_day)

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
        |> Map.put(:customer_queue, customer_queue_for(world, pulse))
        |> apply_competitor_reaction(next_day, pulse)
        |> expire_promotions(next_day)
        |> Map.put(
          :competitor_snapshot,
          LemonSim.Examples.TcgShop.competitor_snapshot(next_day, seed)
        )
        |> apply_daily_overhead(current_day)
        |> apply_credit_line_interest(current_day)
        |> apply_due_supplier_invoices(next_day)
        |> maybe_remit_sales_tax(next_day, status)
        |> apply_due_consignment_payouts(next_day, status)
        |> apply_membership_recognition(next_day)
        |> apply_daily_payroll(current_day)
        |> Map.put(:status, status)
        |> reset_staff_day()

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
        damaged_units = delivery_damaged_units(delivery)
        received_qty = max(0, qty - damaged_units)
        receipt = delivery_receipt(delivery, day, damaged_units, received_qty)

        acc
        |> update_in([:inventory, line_id], &receive_inventory(&1, received_qty))
        |> Map.update(:delivery_receipt_history, [receipt], &(&1 ++ [receipt]))
      end)

    Map.put(delivered_world, :pending_deliveries, pending)
  end

  defp receive_inventory(nil, qty), do: %{on_hand: qty, age_days: 0}

  defp receive_inventory(item, qty) do
    existing_qty = get(item, :on_hand, 0)
    existing_age = get(item, :age_days, 0)
    next_qty = existing_qty + qty

    next_age =
      if next_qty > 0 do
        Float.round(existing_qty * existing_age / next_qty, 2)
      else
        0
      end

    item
    |> Map.put(:on_hand, next_qty)
    |> Map.put(:age_days, next_age)
  end

  defp delivery_damaged_units(delivery) do
    line = Catalog.line(get(delivery, :line_id))
    qty = get(delivery, :quantity, 0)

    if get(line || %{}, :category) == "sealed" and qty >= 4 do
      1
    else
      0
    end
  end

  defp delivery_receipt(delivery, day, damaged_units, received_qty) do
    unit_cost = get(delivery, :unit_cost, 0.0)

    %{
      day: day,
      invoice_id: get(delivery, :invoice_id),
      supplier: get(delivery, :supplier),
      line_id: get(delivery, :line_id),
      ordered_quantity: get(delivery, :quantity, 0),
      received_quantity: received_qty,
      damaged_units: damaged_units,
      claimed_units: 0,
      claim_status: if(damaged_units > 0, do: "unclaimed", else: "none"),
      unit_cost: unit_cost,
      damage_value: Float.round(damaged_units * unit_cost, 2)
    }
  end

  defp apply_due_grading(world, day) do
    {due, pending} =
      world
      |> get(:pending_grading, [])
      |> Enum.split_with(&(get(&1, :return_day, 0) <= day))

    updated =
      Enum.reduce(due, world, fn submission, acc ->
        outcome = grading_outcome(submission, day, get(acc, :seed, 1))
        graded_value = get(outcome, :graded_value, 0.0)

        graded_card = %{
          returned_day: day,
          card_count: get(outcome, :graded_count, 0),
          service_level: get(submission, :service_level, "bulk"),
          market_value: graded_value,
          grade_mix: get(outcome, :grade_mix, %{}),
          authenticated_failures: get(outcome, :authentication_failures, 0)
        }

        loss =
          if get(outcome, :authentication_failures, 0) > 0 do
            [
              %{
                day: day,
                card_count: get(outcome, :authentication_failures, 0),
                raw_value_lost: get(outcome, :authentication_loss, 0.0),
                source: "grading_authentication"
              }
            ]
          else
            []
          end

        acc
        |> update_in([:singles_case, :graded_cards], &((&1 || []) ++ [graded_card]))
        |> Map.update(:grading_result_history, [graded_card], &(&1 ++ [graded_card]))
        |> Map.update(:authentication_loss_history, loss, &(&1 ++ loss))
      end)

    Map.put(updated, :pending_grading, pending)
  end

  defp apply_due_preorders(world, day) do
    {due, pending} =
      world
      |> get(:pending_preorders, [])
      |> Enum.split_with(&(get(&1, :release_day, 0) <= day))

    {updated_world, carried} =
      Enum.reduce(due, {world, pending}, fn preorder, {acc, pending_acc} ->
        line_id = get(preorder, :line_id)
        remaining = get(preorder, :remaining_quantity, get(preorder, :quantity, 0))
        on_hand = get_in(acc, [:inventory, line_id, :on_hand]) || 0
        fulfilled = min(on_hand, remaining)
        shorted = remaining - fulfilled

        new_shortfall_units =
          if shorted > 0 and not get(preorder, :shortfall_recorded, false), do: shorted, else: 0

        unit_price = get(preorder, :unit_price, 0.0)
        deposit_pct = get(preorder, :deposit_pct, 0.0)
        balance_revenue = Float.round(fulfilled * unit_price * (1.0 - deposit_pct / 100), 2)
        taxable_revenue = Float.round(fulfilled * unit_price, 2)
        preorder_cogs = preorder_cogs(acc, line_id, fulfilled)

        fulfillment = %{
          day: day,
          line_id: line_id,
          franchise: get(preorder, :franchise),
          requested_quantity: remaining,
          quantity: fulfilled,
          fulfilled_quantity: fulfilled,
          shorted_quantity: new_shortfall_units,
          delayed_quantity: shorted,
          deposit_applied: Float.round(fulfilled * unit_price * deposit_pct / 100, 2),
          balance_revenue: balance_revenue,
          taxable_revenue: taxable_revenue,
          revenue: taxable_revenue,
          cost_of_goods_sold: preorder_cogs,
          gross_profit: Float.round(taxable_revenue - preorder_cogs, 2),
          sales_tax_collected: sales_tax_for(acc, taxable_revenue),
          channel: "preorder",
          status: if(shorted > 0, do: "partial_backorder", else: "fulfilled")
        }

        stockout =
          if new_shortfall_units > 0 do
            %{
              day: day,
              source: "preorder_fulfillment",
              line_id: line_id,
              segment_id: customer_segment_for_franchise(get(preorder, :franchise)),
              lost_units: new_shortfall_units,
              requested_units: remaining
            }
          end

        issue =
          if new_shortfall_units > 0 do
            %{
              day: day,
              source: "preorder_fulfillment",
              line_id: line_id,
              shorted_units: new_shortfall_units,
              note: "release-day preorder demand exceeded available allocation"
            }
          end

        carried_preorders =
          if shorted > 0 do
            [
              preorder
              |> Map.put(:remaining_quantity, shorted)
              |> Map.put(:status, "backordered")
              |> Map.put(:shortfall_recorded, true)
              |> Map.put(:release_day, day + 1)
            ]
          else
            []
          end

        next =
          acc
          |> update_in([:inventory, line_id, :on_hand], &max((&1 || 0) - fulfilled, 0))
          |> apply_local_tender(balance_revenue, "preorder_balance", day)
          |> apply_local_sales_tax(taxable_revenue, "preorder_fulfillment", day)
          |> apply_local_transaction_costs(balance_revenue, "preorder_balance", day,
            transaction_count: fulfilled
          )
          |> Map.update(:preorder_fulfillment_history, [fulfillment], &(&1 ++ [fulfillment]))
          |> maybe_append(:stockout_history, stockout)
          |> maybe_append(:service_issue_history, issue)
          |> Map.update(:sales_history, [fulfillment], &(&1 ++ [fulfillment]))
          |> update_customer_segment(customer_segment_for_franchise(get(preorder, :franchise)), %{
            loyalty_delta: if(new_shortfall_units > 0, do: -min(4, new_shortfall_units), else: 2),
            satisfaction_delta:
              if(new_shortfall_units > 0, do: -min(7, new_shortfall_units * 2), else: 2),
            visits_delta: fulfilled,
            spend_delta:
              Float.round(
                get(fulfillment, :deposit_applied, 0.0) + get(fulfillment, :balance_revenue, 0.0),
                2
              ),
            reason:
              if(new_shortfall_units > 0, do: "preorder_shortfall", else: "preorder_fulfillment")
          })
          |> Map.update(
            :reputation,
            0,
            &max(0, &1 - if(new_shortfall_units > 0, do: min(4, new_shortfall_units), else: 0))
          )

        {next, pending_acc ++ carried_preorders}
      end)

    Map.put(updated_world, :pending_preorders, carried)
  end

  defp apply_due_special_orders(world, day) do
    {due, pending} =
      world
      |> get(:pending_special_orders, [])
      |> Enum.split_with(&(get(&1, :due_day, 0) <= day))

    {updated_world, carried} =
      Enum.reduce(due, {world, pending}, fn order, {acc, pending_acc} ->
        line_id = get(order, :line_id)
        remaining = get(order, :remaining_quantity, get(order, :quantity, 0))
        on_hand = get_in(acc, [:inventory, line_id, :on_hand]) || 0
        fulfilled = min(on_hand, remaining)
        delayed = remaining - fulfilled

        new_shortfall_units =
          if delayed > 0 and not get(order, :shortfall_recorded, false), do: delayed, else: 0

        unit_price = get(order, :unit_price, 0.0)
        deposit_remaining = get(order, :deposit_remaining, 0.0)
        deposit_applied = special_order_deposit_applied(order, fulfilled, remaining)
        balance_revenue = Float.round(max(0.0, fulfilled * unit_price - deposit_applied), 2)
        taxable_revenue = Float.round(fulfilled * unit_price, 2)
        cogs = sealed_cogs(Catalog.line(line_id) || %{}, fulfilled)

        segment_id =
          get(order, :customer_segment_id, customer_segment_for_franchise(get(order, :franchise)))

        fulfillment = %{
          day: day,
          order_id: get(order, :id),
          line_id: line_id,
          franchise: get(order, :franchise),
          requested_quantity: remaining,
          quantity: fulfilled,
          fulfilled_quantity: fulfilled,
          delayed_quantity: delayed,
          shorted_quantity: new_shortfall_units,
          deposit_applied: deposit_applied,
          balance_revenue: balance_revenue,
          taxable_revenue: taxable_revenue,
          revenue: taxable_revenue,
          cost_of_goods_sold: cogs,
          gross_profit: Float.round(taxable_revenue - cogs, 2),
          sales_tax_collected: sales_tax_for(acc, taxable_revenue),
          channel: "special_order",
          status: if(delayed > 0, do: "partial_backorder", else: "fulfilled")
        }

        stockout =
          if new_shortfall_units > 0 do
            %{
              day: day,
              source: "special_order_fulfillment",
              line_id: line_id,
              segment_id: segment_id,
              lost_units: new_shortfall_units,
              requested_units: remaining
            }
          end

        issue =
          if new_shortfall_units > 0 do
            %{
              day: day,
              source: "special_order_fulfillment",
              line_id: line_id,
              shorted_units: new_shortfall_units,
              note: "customer special order could not be fully filled from available stock"
            }
          end

        carried_orders =
          if delayed > 0 do
            [
              order
              |> Map.put(:remaining_quantity, delayed)
              |> Map.put(
                :deposit_remaining,
                Float.round(max(0.0, deposit_remaining - deposit_applied), 2)
              )
              |> Map.put(:status, "backordered")
              |> Map.put(:shortfall_recorded, true)
              |> Map.put(:due_day, day + 1)
            ]
          else
            []
          end

        next =
          acc
          |> update_in([:inventory, line_id, :on_hand], &max((&1 || 0) - fulfilled, 0))
          |> apply_local_tender(balance_revenue, "special_order_balance", day)
          |> apply_local_sales_tax(taxable_revenue, "special_order_fulfillment", day)
          |> apply_local_transaction_costs(balance_revenue, "special_order_balance", day,
            transaction_count: fulfilled
          )
          |> Map.update(
            :special_order_liability,
            0.0,
            &Float.round(max(0.0, &1 - deposit_applied), 2)
          )
          |> Map.update(:special_order_fulfillment_history, [fulfillment], &(&1 ++ [fulfillment]))
          |> maybe_append(:stockout_history, stockout)
          |> maybe_append(:service_issue_history, issue)
          |> Map.update(:sales_history, [fulfillment], &(&1 ++ [fulfillment]))
          |> update_customer_segment(segment_id, %{
            loyalty_delta: if(new_shortfall_units > 0, do: -min(3, new_shortfall_units), else: 2),
            satisfaction_delta:
              if(new_shortfall_units > 0, do: -min(5, new_shortfall_units * 2), else: 2),
            visits_delta: fulfilled,
            spend_delta:
              Float.round(
                get(fulfillment, :deposit_applied, 0.0) + get(fulfillment, :balance_revenue, 0.0),
                2
              ),
            reason:
              if(new_shortfall_units > 0,
                do: "special_order_shortfall",
                else: "special_order_fulfillment"
              )
          })
          |> Map.update(
            :reputation,
            0,
            &max(0, &1 - if(new_shortfall_units > 0, do: min(3, new_shortfall_units), else: 0))
          )

        {next, pending_acc ++ carried_orders}
      end)

    Map.put(updated_world, :pending_special_orders, carried)
  end

  defp apply_organic_sales(world, pulse) do
    catalog = get(world, :catalog, %{})
    inventory = get(world, :inventory, %{})
    reputation = get(world, :reputation, 50)
    buzz_franchise = get(pulse, :featured_franchise)
    buzz_multiplier = get(pulse, :buzz_multiplier, 1.0)
    day = get(pulse, :day, get(world, :day_number, 1))

    {updated_inventory, sales, stockouts, sealed_revenue} =
      Enum.reduce(inventory, {%{}, [], [], 0.0}, fn {line_id, item},
                                                    {inv_acc, sales_acc, stockouts_acc, rev_acc} ->
        line = Map.get(catalog, line_id, %{})
        on_hand = get(item, :on_hand, 0)
        available_for_walk_in = max(0, on_hand - pending_preorder_units_for_line(world, line_id))
        price = get(item, :price, get(line, :suggested_price, 0.0))
        franchise = get(line, :franchise, "")
        segment_id = customer_segment_for_franchise(franchise)
        demand_boost = if franchise == buzz_franchise, do: buzz_multiplier, else: 1.0
        promotion = active_promotion_for(world, franchise, day)
        promotion_boost = promotion_multiplier(promotion)
        price_drag = max(0.25, get(line, :market_price, 1.0) / max(price, 1.0))

        demand =
          get(line, :velocity, 1.0) * demand_boost * promotion_boost * price_drag *
            (0.65 + reputation / 100) *
            customer_demand_multiplier(world, segment_id) *
            competitive_demand_multiplier(world)

        requested_units = max(0, trunc(demand))
        units = min(available_for_walk_in, requested_units)
        lost_units = max(0, requested_units - units)
        sale_value = Float.round(units * price, 2)
        cost_of_goods_sold = sealed_cogs(line, units)
        item = Map.put(item, :on_hand, on_hand - units)

        sale =
          if units > 0 do
            [
              %{
                day: day,
                line_id: line_id,
                segment_id: segment_id,
                quantity: units,
                revenue: sale_value,
                cost_of_goods_sold: cost_of_goods_sold,
                gross_profit: Float.round(sale_value - cost_of_goods_sold, 2),
                sales_tax_collected: sales_tax_for(world, sale_value),
                channel: "walk_in",
                promotion_id: get(promotion, :id)
              }
            ]
          else
            []
          end

        stockout =
          if lost_units > 0 do
            [
              %{
                day: day,
                source: "walk_in",
                line_id: line_id,
                segment_id: segment_id,
                lost_units: lost_units,
                requested_units: requested_units
              }
            ]
          else
            []
          end

        {Map.put(inv_acc, line_id, item), sales_acc ++ sale, stockouts_acc ++ stockout,
         rev_acc + sale_value}
      end)

    world = Map.put(world, :inventory, updated_inventory)
    {world, pack_revenue, pack_sales} = apply_pack_sales(world, pulse)
    {world, singles_revenue, singles_sales} = apply_singles_sales(world, pulse)
    {world, consignment_revenue, consignment_sales} = apply_consignment_sales(world, pulse)
    {world, graded_revenue, graded_sales} = apply_graded_sales(world, pulse)

    revenue =
      Float.round(
        sealed_revenue + pack_revenue + singles_revenue + consignment_revenue + graded_revenue,
        2
      )

    store_credit_redeemed = store_credit_redemption_for(world, revenue)
    payment_revenue = Float.round(max(0.0, revenue - store_credit_redeemed), 2)
    reputation_penalty = stockout_reputation_penalty(stockouts)

    world =
      world
      |> apply_local_tender(payment_revenue, "daily_sales", day)
      |> apply_local_sales_tax(revenue, "daily_sales", day)
      |> apply_local_transaction_costs(payment_revenue, "daily_sales", day,
        transaction_count:
          estimated_transaction_count(sales ++ singles_sales ++ consignment_sales ++ graded_sales)
      )
      |> apply_store_credit_redemption(store_credit_redeemed, "daily_sales", day)
      |> Map.update(:reputation, 0, &max(0, &1 - reputation_penalty))
      |> Map.update(:stockout_history, stockouts, &(&1 ++ stockouts))
      |> Map.update(:pack_sale_history, pack_sales, &(&1 ++ pack_sales))
      |> Map.update(:singles_sale_history, singles_sales, &(&1 ++ singles_sales))
      |> Map.update(:consignment_sale_history, consignment_sales, &(&1 ++ consignment_sales))
      |> Map.update(:graded_sale_history, graded_sales, &(&1 ++ graded_sales))
      |> Map.update(
        :sales_history,
        sales ++ pack_sales ++ singles_sales ++ consignment_sales ++ graded_sales,
        fn history ->
          history ++ sales ++ pack_sales ++ singles_sales ++ consignment_sales ++ graded_sales
        end
      )
      |> apply_customer_sales(
        sales ++ pack_sales ++ singles_sales ++ consignment_sales ++ graded_sales
      )
      |> apply_customer_stockouts(stockouts)

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

  defp ensure_positive_allocation(value),
    do: if(value > 0, do: :ok, else: {:error, :allocation_unavailable})

  defp ensure_minimum(value, minimum),
    do: if(value >= minimum, do: :ok, else: {:error, {:below_minimum, minimum}})

  defp ensure_return_condition(condition) do
    if condition in ["sealed_resellable", "opened", "damaged"],
      do: :ok,
      else: {:error, :invalid_return_condition}
  end

  defp ensure_return_resolution(resolution) do
    if resolution in ["store_credit", "cash_refund"],
      do: :ok,
      else: {:error, :invalid_return_resolution}
  end

  defp ensure_cash(world, cost) do
    if get(world, :bank_balance, 0.0) >= cost, do: :ok, else: {:error, :insufficient_cash}
  end

  defp ensure_cash_drawer(world, amount) do
    if get(world, :cash_drawer_balance, 0.0) >= amount,
      do: :ok,
      else: {:error, :insufficient_register_cash}
  end

  defp ensure_supplier_credit(world, cost) do
    credit_limit = effective_supplier_credit_limit(world)

    if accounts_payable(world) + cost <= credit_limit do
      :ok
    else
      {:error, :supplier_credit_limit_exceeded}
    end
  end

  defp ensure_franchise(franchise) do
    if franchise in (Catalog.franchises() -- ["Accessories"]),
      do: :ok,
      else: {:error, :unknown_franchise}
  end

  defp ensure_preorder_line(line) do
    if get(line, :category) == "sealed",
      do: :ok,
      else: {:error, :preorders_require_sealed_product}
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

  defp ensure_deposit_pct(deposit_pct) do
    if deposit_pct >= 10 and deposit_pct <= 100,
      do: :ok,
      else: {:error, :invalid_deposit_pct}
  end

  defp ensure_promotion_channel(channel) do
    if channel in ["social_ads", "email_list", "community_flyers", "creator_sponsorship"],
      do: :ok,
      else: {:error, :invalid_promotion_channel}
  end

  defp online_channel_profile(platform, listing_quality) do
    with {:ok, platform_profile} <- online_platform_profile(platform),
         {:ok, quality_profile} <- online_listing_profile(listing_quality) do
      {:ok,
       %{
         marketplace_fee_rate: get(platform_profile, :marketplace_fee_rate, 0.0),
         demand_multiplier:
           Float.round(
             get(platform_profile, :demand_multiplier, 1.0) *
               get(quality_profile, :demand_multiplier, 1.0),
             2
           ),
         setup_cost: get(quality_profile, :setup_cost, 0.0)
       }}
    end
  end

  defp online_platform_profile("local_pickup"),
    do: {:ok, %{marketplace_fee_rate: 0.0, demand_multiplier: 0.85}}

  defp online_platform_profile("tcgplayer"),
    do: {:ok, %{marketplace_fee_rate: 0.105, demand_multiplier: 1.3}}

  defp online_platform_profile("ebay"),
    do: {:ok, %{marketplace_fee_rate: 0.132, demand_multiplier: 1.18}}

  defp online_platform_profile(_platform), do: {:error, :invalid_online_platform}

  defp online_listing_profile("basic"), do: {:ok, %{setup_cost: 35.0, demand_multiplier: 1.0}}

  defp online_listing_profile("optimized"),
    do: {:ok, %{setup_cost: 90.0, demand_multiplier: 1.18}}

  defp online_listing_profile("premium"), do: {:ok, %{setup_cost: 160.0, demand_multiplier: 1.35}}
  defp online_listing_profile(_quality), do: {:error, :invalid_listing_quality}

  defp online_listing_hours("premium"), do: 1.4
  defp online_listing_hours("optimized"), do: 1.0
  defp online_listing_hours(_quality), do: 0.6

  defp ensure_duration(duration_days) do
    if duration_days >= 1 and duration_days <= 7,
      do: :ok,
      else: {:error, :invalid_duration}
  end

  defp ensure_membership_duration(duration_days) do
    if duration_days >= 1 and duration_days <= 30,
      do: :ok,
      else: {:error, :invalid_membership_duration}
  end

  defp ensure_commission_pct(commission_pct) do
    if commission_pct >= 5 and commission_pct <= 30,
      do: :ok,
      else: {:error, :invalid_commission_pct}
  end

  defp ensure_staff_role(role) do
    if role in ["sales_floor", "sorting", "event_judge", "online_fulfillment"],
      do: :ok,
      else: {:error, :invalid_staff_role}
  end

  defp ensure_staff_shift_hours(hours) do
    if hours <= 10,
      do: :ok,
      else: {:error, :staff_shift_too_long}
  end

  defp ensure_loss_prevention_not_installed(world, control) do
    installed? =
      world
      |> get(:loss_prevention_history, [])
      |> Enum.any?(&(get(&1, :control) == control))

    if installed?,
      do: {:error, :loss_prevention_already_installed},
      else: :ok
  end

  defp staff_role_wage("sales_floor"), do: 17.0
  defp staff_role_wage("sorting"), do: 16.0
  defp staff_role_wage("event_judge"), do: 24.0
  defp staff_role_wage("online_fulfillment"), do: 18.5
  defp staff_role_wage(_role), do: 18.0

  defp loss_prevention_option("display_case_locks") do
    {:ok, %{label: "Locked display cases", cost: 220.0, protection: 18}}
  end

  defp loss_prevention_option("camera_system") do
    {:ok, %{label: "Camera system", cost: 650.0, protection: 28}}
  end

  defp loss_prevention_option("inventory_audit_process") do
    {:ok, %{label: "Inventory audit process", cost: 140.0, protection: 14}}
  end

  defp loss_prevention_option(_control), do: {:error, :invalid_loss_prevention_control}

  defp ensure_credit_action(action) do
    if action in ["draw", "repay"],
      do: :ok,
      else: {:error, :invalid_credit_line_action}
  end

  defp ensure_credit_capacity(world, "draw", amount) do
    available =
      get(world, :credit_line_limit, 0.0) - get(world, :credit_line_balance, 0.0)

    if amount <= available,
      do: :ok,
      else: {:error, :credit_line_limit_exceeded}
  end

  defp ensure_credit_capacity(world, "repay", amount) do
    cond do
      amount > get(world, :credit_line_balance, 0.0) -> {:error, :repayment_exceeds_debt}
      amount > get(world, :bank_balance, 0.0) -> {:error, :insufficient_cash}
      true -> :ok
    end
  end

  defp event_no_shows(world, game, day, requested_attendance) do
    seed = get(world, :seed, 1)
    base = rem(seed + day + String.length(game), 4)

    min(max(0, requested_attendance - 4), base)
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

  defp supplier_invoice_id(world, day, line_id) do
    next_number = length(get(world, :supplier_order_history, [])) + 1
    "inv_#{day}_#{line_id}_#{next_number}"
  end

  defp consignment_lot_id(world, day, franchise) do
    next_number = length(get(world, :consignment_history, [])) + 1
    slug = String.replace(franchise, ~r/[^A-Za-z0-9]+/, "_")
    "consign_#{day}_#{slug}_#{next_number}"
  end

  defp membership_batch_id(world, day, franchise) do
    next_number = length(get(world, :membership_history, [])) + 1
    slug = String.replace(franchise, ~r/[^A-Za-z0-9]+/, "_")
    "member_#{day}_#{slug}_#{next_number}"
  end

  defp supplier_invoice_for_order(order) do
    %{
      id: get(order, :invoice_id),
      day: get(order, :day),
      supplier: get(order, :supplier),
      line_id: get(order, :line_id),
      amount_original: get(order, :cost, 0.0),
      amount_due: get(order, :cost, 0.0),
      due_day: get(order, :invoice_due_day),
      payment_terms_days: get(order, :payment_terms_days, 0),
      status: "open",
      type: "created",
      late_fee_total: 0.0
    }
  end

  defp claimable_delivery_receipt(world, invoice_id, damaged_units) do
    receipt =
      world
      |> get(:delivery_receipt_history, [])
      |> Enum.find(&(get(&1, :invoice_id) == invoice_id))

    cond do
      is_nil(receipt) ->
        {:error, :unknown_delivery_receipt}

      get(receipt, :damaged_units, 0) <= get(receipt, :claimed_units, 0) ->
        {:error, :no_unclaimed_delivery_damage}

      damaged_units > get(receipt, :damaged_units, 0) - get(receipt, :claimed_units, 0) ->
        {:error, :claim_exceeds_unclaimed_damage}

      true ->
        {:ok, receipt}
    end
  end

  defp supplier_claim_amount(receipt, damaged_units) do
    Float.round(damaged_units * get(receipt, :unit_cost, 0.0), 2)
  end

  defp eligible_return_sale_totals(world, line_id, quantity) do
    sold =
      world
      |> get(:sales_history, [])
      |> Enum.filter(&(get(&1, :line_id) == line_id and local_return_channel?(get(&1, :channel))))
      |> Enum.reduce(%{quantity: 0, revenue: 0.0, cost_of_goods_sold: 0.0}, fn sale, acc ->
        %{
          quantity: get(acc, :quantity, 0) + get(sale, :quantity, 0),
          revenue: get(acc, :revenue, 0.0) + get(sale, :revenue, 0.0),
          cost_of_goods_sold:
            get(acc, :cost_of_goods_sold, 0.0) + get(sale, :cost_of_goods_sold, 0.0)
        }
      end)

    returned =
      world
      |> get(:return_history, [])
      |> Enum.filter(&(get(&1, :line_id) == line_id))
      |> Enum.reduce(0, fn entry, acc -> acc + get(entry, :quantity, 0) end)

    available = get(sold, :quantity, 0) - returned

    cond do
      available < quantity ->
        {:error, :return_exceeds_local_sales}

      get(sold, :quantity, 0) <= 0 ->
        {:error, :no_local_sales_to_return}

      true ->
        {:ok,
         %{
           unit_price: Float.round(get(sold, :revenue, 0.0) / get(sold, :quantity, 1), 2),
           unit_cogs:
             Float.round(get(sold, :cost_of_goods_sold, 0.0) / get(sold, :quantity, 1), 2)
         }}
    end
  end

  defp local_return_channel?(channel), do: channel in ["walk_in", "preorder", "special_order"]

  defp return_refund_rate("sealed_resellable"), do: 1.0
  defp return_refund_rate("opened"), do: 0.65
  defp return_refund_rate("damaged"), do: 0.25
  defp return_refund_rate(_condition), do: 0.0

  defp return_satisfaction_delta("sealed_resellable"), do: 1
  defp return_satisfaction_delta("opened"), do: -1
  defp return_satisfaction_delta("damaged"), do: -3
  defp return_satisfaction_delta(_condition), do: 0

  defp apply_return_resolution(world, "store_credit", refund_amount, day) do
    apply_store_credit_issue(world, refund_amount, "customer_return", day)
  end

  defp apply_return_resolution(world, "cash_refund", refund_amount, _day) do
    Map.update!(world, :bank_balance, &Float.round(&1 - refund_amount, 2))
  end

  defp restock_returned_inventory(world, _line_id, restocked_units) when restocked_units <= 0,
    do: world

  defp restock_returned_inventory(world, line_id, restocked_units) do
    update_in(world, [:inventory, line_id], &receive_inventory(&1, restocked_units))
  end

  defp settle_supplier_claim(world, claim) do
    invoice_id = get(claim, :invoice_id)
    claim_amount = get(claim, :claim_amount, 0.0)

    case Enum.split_with(
           get(world, :pending_supplier_invoices, []),
           &(get(&1, :id) == invoice_id)
         ) do
      {[invoice], rest} ->
        credited_invoice =
          invoice
          |> Map.update(:claim_credit_total, claim_amount, &Float.round(&1 + claim_amount, 2))
          |> Map.update(:amount_due, 0.0, &Float.round(max(0.0, &1 - claim_amount), 2))

        credit_entry = %{
          day: get(claim, :day),
          id: invoice_id,
          supplier: get(claim, :supplier),
          line_id: get(claim, :line_id),
          amount: claim_amount,
          type: "credit_memo"
        }

        world
        |> Map.put(:pending_supplier_invoices, [credited_invoice | rest])
        |> Map.update(:supplier_invoice_history, [credit_entry], &(&1 ++ [credit_entry]))

      _ ->
        world
        |> Map.update!(:bank_balance, &Float.round(&1 + claim_amount, 2))
    end
  end

  defp mark_delivery_receipt_claimed(world, invoice_id, damaged_units, claim_amount) do
    receipts =
      world
      |> get(:delivery_receipt_history, [])
      |> Enum.map(fn receipt ->
        if get(receipt, :invoice_id) == invoice_id do
          claimed_units = get(receipt, :claimed_units, 0) + damaged_units
          remaining_units = get(receipt, :damaged_units, 0) - claimed_units

          receipt
          |> Map.put(:claimed_units, claimed_units)
          |> Map.update(:claim_amount, claim_amount, &Float.round(&1 + claim_amount, 2))
          |> Map.put(
            :claim_status,
            if(remaining_units > 0, do: "partially_claimed", else: "claimed")
          )
        else
          receipt
        end
      end)

    Map.put(world, :delivery_receipt_history, receipts)
  end

  defp apply_due_supplier_invoices(world, day) do
    {world, pending} =
      world
      |> get(:pending_supplier_invoices, [])
      |> Enum.reduce({world, []}, fn invoice, {acc, pending_acc} ->
        cond do
          get(invoice, :due_day, 0) > day ->
            {acc, pending_acc ++ [invoice]}

          get(acc, :bank_balance, 0.0) >= get(invoice, :amount_due, 0.0) ->
            amount = Float.round(get(invoice, :amount_due, 0.0), 2)

            paid = %{
              id: get(invoice, :id),
              day: day,
              supplier: get(invoice, :supplier),
              line_id: get(invoice, :line_id),
              amount_paid: amount,
              status: "paid",
              type: "paid"
            }

            next =
              acc
              |> Map.update!(:bank_balance, &Float.round(&1 - amount, 2))
              |> Map.update(:supplier_invoice_history, [paid], &(&1 ++ [paid]))
              |> update_supplier_account(get(invoice, :supplier), day, :paid, invoice)

            {next, pending_acc}

          true ->
            {next, overdue} = mark_supplier_invoice_overdue(acc, invoice, day)
            {next, pending_acc ++ [overdue]}
        end
      end)

    Map.put(world, :pending_supplier_invoices, pending)
  end

  defp mark_supplier_invoice_overdue(world, invoice, day) do
    late_fee =
      if day > get(invoice, :due_day, 0) and get(invoice, :last_late_fee_day, nil) != day do
        Float.round(
          get(invoice, :amount_due, 0.0) * get(world, :supplier_late_fee_rate, 0.035),
          2
        )
      else
        0.0
      end

    overdue =
      invoice
      |> Map.put(:status, "overdue")
      |> Map.update(:amount_due, late_fee, &Float.round(&1 + late_fee, 2))
      |> Map.update(:late_fee_total, late_fee, &Float.round(&1 + late_fee, 2))
      |> maybe_put_late_fee_day(day, late_fee)

    if late_fee > 0.0 do
      fee_entry = %{
        id: get(invoice, :id),
        day: day,
        supplier: get(invoice, :supplier),
        line_id: get(invoice, :line_id),
        late_fee: late_fee,
        status: "overdue",
        type: "late_fee"
      }

      next =
        world
        |> Map.update(:supplier_invoice_history, [fee_entry], &(&1 ++ [fee_entry]))
        |> update_supplier_account(get(invoice, :supplier), day, :late_fee, overdue)

      {next, overdue}
    else
      {world, overdue}
    end
  end

  defp maybe_put_late_fee_day(invoice, day, late_fee) when late_fee > 0.0,
    do: Map.put(invoice, :last_late_fee_day, day)

  defp maybe_put_late_fee_day(invoice, _day, _late_fee), do: invoice

  defp accounts_payable(world) do
    world
    |> get(:pending_supplier_invoices, [])
    |> Enum.reduce(0.0, fn invoice, acc -> acc + get(invoice, :amount_due, 0.0) end)
    |> Float.round(2)
  end

  defp effective_supplier_credit_limit(world) do
    base = get(world, :supplier_credit_limit, 0.0)
    Float.round(max(0.0, base + supplier_credit_adjustment(world)), 2)
  end

  defp supplier_credit_adjustment(world) do
    average = average_supplier_standing(world)

    cond do
      average > 55 -> min(750.0, (average - 55) * 20)
      average < 55 -> max(-750.0, (average - 55) * 25)
      true -> 0.0
    end
  end

  defp average_supplier_standing(world) do
    accounts = world |> get(:supplier_accounts, %{}) |> Map.values()

    if accounts == [] do
      55.0
    else
      accounts
      |> Enum.reduce(0.0, fn account, acc -> acc + get(account, :standing, 55) end)
      |> Kernel./(length(accounts))
      |> Float.round(2)
    end
  end

  defp supplier_account_standing(world, supplier) do
    world
    |> get(:supplier_accounts, %{})
    |> Map.get(supplier, %{})
    |> get(:standing, 55)
  end

  defp update_supplier_account(world, nil, _day, _reason, _invoice), do: world

  defp update_supplier_account(world, supplier, day, reason, invoice) do
    accounts = get(world, :supplier_accounts, %{})
    account = Map.get(accounts, supplier, default_supplier_account(supplier))
    before = get(account, :standing, 55)
    due_day = get(invoice, :due_day, day)

    delta =
      case reason do
        :paid -> if(day <= due_day, do: 3, else: 1)
        :late_fee -> -8
      end

    after_standing = clamp_int(before + delta, 0, 100)

    updated =
      account
      |> Map.put(:standing, after_standing)
      |> Map.put(:status, supplier_account_status(after_standing))
      |> Map.put(:last_event_day, day)
      |> maybe_increment_supplier_counter(reason)

    history = %{
      day: day,
      supplier: supplier,
      invoice_id: get(invoice, :id),
      line_id: get(invoice, :line_id),
      standing_before: before,
      standing_after: after_standing,
      delta: delta,
      status: get(updated, :status),
      type: Atom.to_string(reason)
    }

    world
    |> Map.put(:supplier_accounts, Map.put(accounts, supplier, updated))
    |> Map.update(:supplier_account_history, [history], &(&1 ++ [history]))
  end

  defp default_supplier_account(supplier) do
    %{
      supplier: supplier,
      standing: 55,
      status: "current",
      invoices_paid: 0,
      late_invoices: 0,
      last_event_day: nil
    }
  end

  defp maybe_increment_supplier_counter(account, :paid),
    do: Map.update(account, :invoices_paid, 1, &(&1 + 1))

  defp maybe_increment_supplier_counter(account, :late_fee),
    do: Map.update(account, :late_invoices, 1, &(&1 + 1))

  defp supplier_account_status(standing) when standing >= 70, do: "preferred"
  defp supplier_account_status(standing) when standing < 45, do: "strained"
  defp supplier_account_status(_standing), do: "current"

  defp apply_due_consignment_payouts(world, day, status) do
    payable = Float.round(get(world, :consignment_payable, 0.0), 2)

    if payable > 0.0 and consignment_payout_due?(day, status) and
         get(world, :bank_balance, 0.0) >= payable do
      entry = %{
        day: day,
        amount_paid: payable,
        type: "paid",
        status: "paid"
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - payable, 2))
      |> Map.put(:consignment_payable, 0.0)
      |> Map.update(:consignment_payout_history, [entry], &(&1 ++ [entry]))
      |> Map.update(:consignment_history, [entry], &(&1 ++ [entry]))
    else
      world
    end
  end

  defp consignment_payout_due?(day, "complete"), do: day >= 1
  defp consignment_payout_due?(day, _status), do: rem(day, 3) == 0

  defp apply_membership_recognition(world, day) do
    {memberships, entries, recognized} =
      world
      |> get(:active_memberships, [])
      |> Enum.reduce({[], [], 0.0}, fn membership, {memberships_acc, entries_acc, total_acc} ->
        if get(membership, :status, "active") == "active" and
             get(membership, :remaining_days, 0) > 0 and
             get(membership, :remaining_value, 0.0) > 0.0 do
          remaining_days = max(1, get(membership, :remaining_days, 1))
          remaining_value = get(membership, :remaining_value, 0.0)
          recognition = Float.round(min(remaining_value, remaining_value / remaining_days), 2)
          next_remaining_value = Float.round(max(0.0, remaining_value - recognition), 2)
          next_remaining_days = max(0, remaining_days - 1)

          status =
            if next_remaining_days > 0 and next_remaining_value > 0.0,
              do: "active",
              else: "expired"

          updated =
            membership
            |> Map.put(:remaining_days, next_remaining_days)
            |> Map.put(:remaining_value, next_remaining_value)
            |> Map.put(:status, status)

          entry = %{
            id: get(membership, :id),
            day: day,
            franchise: get(membership, :franchise),
            segment_id: get(membership, :segment_id),
            member_count: get(membership, :member_count, 0),
            revenue_recognized: recognition,
            remaining_value: next_remaining_value,
            remaining_days: next_remaining_days,
            status: status,
            type: "recognized"
          }

          {memberships_acc ++ [updated], entries_acc ++ [entry], total_acc + recognition}
        else
          {memberships_acc ++ [membership], entries_acc, total_acc}
        end
      end)

    recognized = Float.round(recognized, 2)

    world
    |> Map.put(:active_memberships, memberships)
    |> Map.update(:membership_liability, 0.0, &Float.round(max(0.0, &1 - recognized), 2))
    |> Map.update(:membership_history, entries, &(&1 ++ entries))
  end

  defp allocated_quantity(line, requested_quantity, world) do
    if line.category == "accessory" do
      requested_quantity
    else
      min(requested_quantity, allocation_limit(line, world))
    end
  end

  defp allocation_limit(line, world) do
    reputation = get(world, :reputation, 50)
    pulse = List.last(get(world, :market_pulses, [])) || %{}
    hype_penalty = if get(pulse, :featured_franchise) == line.franchise, do: 1, else: 0
    reputation_bonus = div(reputation, 30)
    standing_bonus = allocation_standing_bonus(world, supplier_for(line.franchise))

    base =
      case line.franchise do
        "One Piece" -> 3
        "Pokemon" -> 6
        "Yu-Gi-Oh!" -> 7
        "Dragon Ball Super" -> 5
        _ -> 6
      end

    max(1, base + reputation_bonus + standing_bonus - hype_penalty)
  end

  defp allocation_standing_bonus(world, supplier) do
    standing = supplier_account_standing(world, supplier)

    cond do
      standing >= 80 -> 2
      standing >= 65 -> 1
      standing < 35 -> -2
      standing < 45 -> -1
      true -> 0
    end
  end

  defp allocation_note(requested, allocated, _franchise) when allocated >= requested,
    do: "filled in full"

  defp allocation_note(_requested, _allocated, "One Piece"),
    do: "partial allocation due to scarce Bandai sealed supply"

  defp allocation_note(_requested, _allocated, "Pokemon"),
    do: "partial allocation during high Pokemon distributor demand"

  defp allocation_note(_requested, _allocated, _franchise),
    do: "partial distributor allocation"

  defp preorder_unit_price(world, line_id, line) do
    world
    |> get(:inventory, %{})
    |> get(line_id, %{})
    |> get(:price, get(line, :suggested_price, get(line, :market_price, 0.0)))
  end

  defp special_order_unit_price(world, line_id, line),
    do: preorder_unit_price(world, line_id, line)

  defp special_order_id(world, day, line_id) do
    count = length(get(world, :special_order_history, [])) + 1
    "special_#{day}_#{line_id}_#{count}"
  end

  defp special_order_deposit_applied(_order, fulfilled, _remaining) when fulfilled <= 0, do: 0.0

  defp special_order_deposit_applied(order, fulfilled, remaining) do
    deposit_remaining = get(order, :deposit_remaining, 0.0)
    unit_price = get(order, :unit_price, 0.0)
    deposit_pct = get(order, :deposit_pct, 0.0)
    expected = Float.round(fulfilled * unit_price * deposit_pct / 100, 2)
    prorated = Float.round(deposit_remaining * fulfilled / max(remaining, 1), 2)

    min(deposit_remaining, max(expected, prorated))
    |> Float.round(2)
  end

  defp next_release_day(world, franchise, day) do
    world
    |> get(:release_calendar, [])
    |> Enum.filter(&(get(&1, :franchise) == franchise and get(&1, :day, 0) > day))
    |> Enum.map(&get(&1, :day, day + 2))
    |> Enum.min(fn -> day + 2 end)
  end

  defp build_promotion(franchise, channel, budget, duration_days, day, world) do
    pressure =
      world
      |> get(:competitive_position, %{})
      |> get(:competitor_pressure, 0.0)

    lift =
      budget
      |> Kernel./(900.0)
      |> Kernel.*(promotion_channel_lift(channel))
      |> Kernel.-(pressure / 60)
      |> clamp_float(0.05, 0.55)
      |> Float.round(2)

    %{
      id: "promo_#{day}_#{String.replace(franchise, ~r/[^A-Za-z0-9]+/, "_")}_#{channel}",
      day: day,
      franchise: franchise,
      channel: channel,
      budget: Float.round(budget, 2),
      duration_days: duration_days,
      ends_day: day + duration_days,
      demand_lift: lift,
      status: "active"
    }
  end

  defp promotion_channel_lift("email_list"), do: 1.25
  defp promotion_channel_lift("community_flyers"), do: 0.85
  defp promotion_channel_lift("creator_sponsorship"), do: 1.45
  defp promotion_channel_lift(_), do: 1.0

  defp expire_promotions(world, day) do
    active =
      world
      |> get(:active_promotions, [])
      |> Enum.filter(&(get(&1, :ends_day, 0) >= day))

    Map.put(world, :active_promotions, active)
  end

  defp active_promotion_for(world, franchise, day) do
    world
    |> get(:active_promotions, [])
    |> Enum.filter(fn promotion ->
      get(promotion, :franchise) == franchise and get(promotion, :day, 0) <= day and
        get(promotion, :ends_day, 0) >= day
    end)
    |> Enum.max_by(&get(&1, :demand_lift, 0.0), fn -> nil end)
  end

  defp promotion_multiplier(nil), do: 1.0

  defp promotion_multiplier(promotion),
    do: Float.round(1.0 + get(promotion, :demand_lift, 0.0), 2)

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

  defp grading_service("express"), do: %{cost: 38.0, delay: 2}
  defp grading_service("standard"), do: %{cost: 22.0, delay: 4}
  defp grading_service(_), do: %{cost: 14.0, delay: 7}

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

  defp grading_submission_profile(world, count) do
    recent_buy =
      world
      |> get(:buylist_history, [])
      |> Enum.reverse()
      |> Enum.find(&get(&1, :condition_mix, nil))

    condition_mix =
      get(recent_buy || %{}, :condition_mix, %{
        near_mint: 55,
        light_play: 30,
        moderate_play: 12,
        damaged: 3
      })

    auth_risk = get(recent_buy || %{}, :authentication_risk_pct, 1)
    failures = min(count, div(count * auth_risk + 99, 100))

    %{
      condition_mix: condition_mix,
      authentication_risk_pct: auth_risk,
      expected_authentication_failures: failures
    }
  end

  defp grading_outcome(submission, day, seed) do
    count = get(submission, :card_count, 0)
    failures = min(count, deterministic_authentication_failures(submission, day, seed))
    graded_count = max(0, count - failures)
    raw_value = get(submission, :raw_value, 0.0)
    value_per_card = raw_value / max(count, 1)
    grade_mix = grade_mix_for(submission, graded_count, day, seed)
    multiplier = grade_mix_multiplier(grade_mix)
    graded_value = Float.round(value_per_card * graded_count * multiplier, 2)

    %{
      graded_count: graded_count,
      authentication_failures: failures,
      authentication_loss: Float.round(value_per_card * failures, 2),
      grade_mix: grade_mix,
      graded_value: graded_value
    }
  end

  defp deterministic_authentication_failures(submission, day, seed) do
    expected = get(submission, :expected_authentication_failures, 0)
    risk = get(submission, :authentication_risk_pct, 0)
    count = get(submission, :card_count, 0)

    if rem(seed + day + risk + count, 5) == 0 do
      min(count, expected + 1)
    else
      min(count, expected)
    end
  end

  defp grade_mix_for(_submission, 0, _day, _seed), do: %{gem_mint: 0, mint: 0, near_mint: 0}

  defp grade_mix_for(submission, graded_count, day, seed) do
    condition = get(submission, :condition_mix, %{})
    near_mint_pct = get(condition, :near_mint, 55)
    service_bonus = if get(submission, :service_level, "bulk") == "express", do: 1, else: 0
    deterministic_bonus = rem(seed + day + graded_count, 3)
    gem_mint = min(graded_count, max(0, div(graded_count * near_mint_pct, 220) + service_bonus))

    mint =
      min(
        graded_count - gem_mint,
        max(0, div(graded_count * near_mint_pct, 160) + deterministic_bonus)
      )

    near_mint = max(0, graded_count - gem_mint - mint)

    %{gem_mint: gem_mint, mint: mint, near_mint: near_mint}
  end

  defp grade_mix_multiplier(grade_mix) do
    total =
      grade_mix
      |> Map.values()
      |> Enum.sum()

    if total == 0 do
      0.0
    else
      weighted =
        get(grade_mix, :gem_mint, 0) * 2.1 +
          get(grade_mix, :mint, 0) * 1.45 +
          get(grade_mix, :near_mint, 0) * 1.05

      Float.round(weighted / total, 3)
    end
  end

  defp packing_cost("premium"), do: 2.25
  defp packing_cost("standard"), do: 1.15
  defp packing_cost(_), do: 0.45

  defp rating_delta("premium"), do: 0.04
  defp rating_delta("standard"), do: 0.01
  defp rating_delta(_), do: -0.08

  defp fulfill_online_orders(world, order_count) do
    catalog = get(world, :catalog, %{})

    candidates =
      world
      |> get(:inventory, %{})
      |> Enum.filter(fn {_id, item} -> get(item, :on_hand, 0) > 0 end)
      |> Enum.sort_by(fn {_id, item} -> -get(item, :price, 0.0) end)

    {updated_world, fulfilled_count, revenue, lines} =
      Enum.reduce_while(candidates, {world, 0, 0.0, []}, fn {line_id, item},
                                                            {acc, filled, rev, line_acc} ->
        remaining = order_count - filled

        if remaining <= 0 do
          {:halt, {acc, filled, rev, line_acc}}
        else
          quantity = min(get(item, :on_hand, 0), remaining)
          price = get(item, :price, 0.0)
          line_revenue = Float.round(quantity * price, 2)
          line_cogs = sealed_cogs(Map.get(catalog, line_id, %{}), quantity)

          line = %{
            line_id: line_id,
            quantity: quantity,
            revenue: line_revenue,
            cost_of_goods_sold: line_cogs,
            gross_profit: Float.round(line_revenue - line_cogs, 2)
          }

          next =
            update_in(acc, [:inventory, line_id, :on_hand], &max((&1 || 0) - quantity, 0))

          {:cont, {next, filled + quantity, rev + line_revenue, line_acc ++ [line]}}
        end
      end)

    {
      updated_world,
      Float.round(revenue, 2),
      fulfilled_count,
      max(0, order_count - fulfilled_count),
      lines
    }
  end

  defp complaint_count("premium", _fulfilled_count, backorder_count), do: div(backorder_count, 4)

  defp complaint_count("standard", fulfilled_count, backorder_count) do
    div(fulfilled_count, 10) + div(backorder_count + 1, 3)
  end

  defp complaint_count(_quality, fulfilled_count, backorder_count) do
    div(fulfilled_count + 3, 4) + div(backorder_count + 1, 2)
  end

  defp service_issue_note(complaints, backorders) do
    cond do
      complaints > 0 and backorders > 0 -> "damaged parcels and unfilled carts hurt trust"
      complaints > 0 -> "packing complaints hurt online trust"
      backorders > 0 -> "online carts exceeded available inventory"
      true -> "no service issue"
    end
  end

  defp maybe_append(world, _key, nil), do: world
  defp maybe_append(world, key, value), do: Map.update(world, key, [value], &(&1 ++ [value]))

  defp apply_store_credit_issue(world, amount, source, day) when amount > 0 do
    entry = %{
      day: day,
      source: source,
      amount: Float.round(amount, 2),
      type: "issued"
    }

    world
    |> Map.update(:store_credit_liability, amount, &Float.round(&1 + amount, 2))
    |> Map.update(:store_credit_history, [entry], &(&1 ++ [entry]))
  end

  defp apply_store_credit_issue(world, _amount, _source, _day), do: world

  defp apply_store_credit_redemption(world, amount, source, day) when amount > 0 do
    entry = %{
      day: day,
      source: source,
      amount: Float.round(amount, 2),
      type: "redeemed"
    }

    world
    |> Map.update(:store_credit_liability, 0.0, &Float.round(max(0.0, &1 - amount), 2))
    |> Map.update(:store_credit_history, [entry], &(&1 ++ [entry]))
  end

  defp apply_store_credit_redemption(world, _amount, _source, _day), do: world

  defp store_credit_redemption_for(world, revenue) when revenue > 0 do
    liability = get(world, :store_credit_liability, 0.0)
    Float.round(min(liability, revenue * 0.22), 2)
  end

  defp store_credit_redemption_for(_world, _revenue), do: 0.0

  defp apply_daily_refunds({world, revenue}, day), do: {apply_daily_refunds(world, day), revenue}

  defp apply_daily_refunds(world, day) do
    refunded_issue_keys =
      world
      |> get(:refund_history, [])
      |> Enum.map(&get(&1, :issue_key))
      |> MapSet.new()

    world
    |> get(:service_issue_history, [])
    |> Enum.filter(&(get(&1, :source) == "online_orders" and get(&1, :day, 0) <= day))
    |> Enum.reject(&MapSet.member?(refunded_issue_keys, refund_issue_key(&1)))
    |> Enum.reduce(world, fn issue, acc ->
      case online_refund_entry(acc, issue, day) do
        nil -> acc
        refund -> apply_refund(acc, refund)
      end
    end)
  end

  defp online_refund_entry(world, issue, day) do
    issue_day = get(issue, :day, day)
    order = Enum.find(get(world, :online_order_history, []), &(get(&1, :day) == issue_day))

    if order do
      fulfilled = get(order, :fulfilled_count, 0)
      revenue = get(order, :revenue, 0.0)
      avg_order = if fulfilled > 0, do: revenue / fulfilled, else: 0.0
      complaints = get(issue, :complaints, 0)
      backorders = get(issue, :backorders, 0)

      refund_amount =
        Float.round(
          min(fulfilled, complaints) * avg_order * 0.5 +
            min(max(fulfilled - complaints, 0), backorders) * avg_order * 0.15,
          2
        )

      if refund_amount > 0.0 do
        %{
          day: day,
          issue_day: issue_day,
          issue_key: refund_issue_key(issue),
          source: "online_orders",
          channel: "online",
          refund_amount: refund_amount,
          chargeback: complaints > 0 and get(order, :packing_quality, "standard") == "cheap",
          complaints: complaints,
          backorders: backorders,
          note: get(issue, :note, "online service refund")
        }
      end
    end
  end

  defp apply_refund(world, refund) do
    refund_amount = get(refund, :refund_amount, 0.0)

    world
    |> Map.update!(:bank_balance, &Float.round(&1 - refund_amount, 2))
    |> Map.update(:refund_history, [refund], &(&1 ++ [refund]))
    |> Map.update(
      :online_rating,
      0.0,
      &Float.round(max(3.0, &1 - refund_rating_penalty(refund)), 2)
    )
    |> Map.update(:reputation, 0, &max(0, &1 - refund_reputation_penalty(refund)))
    |> update_customer_segment("online_buyers", %{
      loyalty_delta: if(get(refund, :chargeback, false), do: -3, else: -1),
      satisfaction_delta: if(get(refund, :chargeback, false), do: -4, else: -2),
      visits_delta: 0,
      spend_delta: -refund_amount,
      reason: if(get(refund, :chargeback, false), do: "chargeback", else: "refund")
    })
  end

  defp refund_issue_key(issue) do
    "#{get(issue, :source)}:#{get(issue, :day)}:#{get(issue, :line_id, "online")}:#{get(issue, :note, "")}"
  end

  defp refund_rating_penalty(refund) do
    if get(refund, :chargeback, false), do: 0.08, else: 0.03
  end

  defp refund_reputation_penalty(refund) do
    if get(refund, :chargeback, false), do: 2, else: 1
  end

  defp apply_inventory_aging_and_markdowns({world, revenue}, day) do
    {apply_inventory_aging_and_markdowns(world, day), revenue}
  end

  defp apply_inventory_aging_and_markdowns(world, day) do
    catalog = get(world, :catalog, %{})

    {inventory, entries} =
      world
      |> get(:inventory, %{})
      |> Enum.reduce({%{}, []}, fn {line_id, item}, {inventory_acc, entries_acc} ->
        line = Map.get(catalog, line_id, %{})
        aged_item = age_inventory_item(item)

        case stale_inventory_markdown(line_id, line, aged_item, day) do
          nil ->
            {Map.put(inventory_acc, line_id, aged_item), entries_acc}

          {marked_item, entry} ->
            {Map.put(inventory_acc, line_id, marked_item), entries_acc ++ [entry]}
        end
      end)

    world =
      world
      |> Map.put(:inventory, inventory)

    if entries == [] do
      world
    else
      Map.update(world, :stale_inventory_history, entries, &(&1 ++ entries))
    end
  end

  defp age_inventory_item(item) do
    if get(item, :on_hand, 0) > 0 do
      Map.update(item, :age_days, 1.0, &Float.round((&1 + 1) / 1, 2))
    else
      Map.put(item, :age_days, 0)
    end
  end

  defp stale_inventory_markdown(line_id, line, item, day) do
    on_hand = get(item, :on_hand, 0)
    age_days = get(item, :age_days, 0)
    threshold = stale_age_threshold(line)
    current_price = get(item, :price, get(line, :suggested_price, 0.0))
    target_price = stale_target_price(line, item, threshold)

    if on_hand > 0 and age_days >= threshold and target_price < current_price do
      new_price = Float.round(target_price, 2)
      markdown_loss = Float.round((current_price - new_price) * on_hand, 2)

      entry = %{
        day: day,
        line_id: line_id,
        franchise: get(line, :franchise, "Unknown"),
        category: get(line, :category, "unknown"),
        units: on_hand,
        age_days: age_days,
        old_price: current_price,
        new_price: new_price,
        markdown_loss: markdown_loss,
        reason: stale_inventory_reason(line, age_days, threshold)
      }

      {
        item
        |> Map.put(:price, new_price)
        |> Map.put(:last_markdown_day, day),
        entry
      }
    end
  end

  defp stale_age_threshold(line) do
    case get(line, :category, "sealed") do
      "accessory" -> 8
      _ -> 8
    end
  end

  defp stale_target_price(line, item, threshold) do
    age_days = get(item, :age_days, 0)
    market_price = get(line, :market_price, get(item, :price, 0.0))
    markdown_pct = min(0.25, 0.06 + max(0, age_days - threshold) * 0.025)

    Float.round(market_price * (1.0 - markdown_pct), 2)
  end

  defp stale_inventory_reason(line, age_days, threshold) do
    category = get(line, :category, "sealed")

    if category == "accessory" do
      "slow accessory turnover after #{age_days} days on shelf"
    else
      "stale sealed inventory exceeded #{threshold}-day target turn"
    end
  end

  defp apply_sales_tax(world, taxable_amount, source, day) when taxable_amount > 0 do
    rate = get(world, :sales_tax_rate, 0.0)
    tax = Float.round(taxable_amount * rate, 2)

    entry = %{
      day: day,
      source: source,
      taxable_sales: Float.round(taxable_amount, 2),
      tax_collected: tax,
      rate: rate,
      type: "collected"
    }

    world
    |> Map.update!(:bank_balance, &Float.round(&1 + tax, 2))
    |> Map.update(:sales_tax_liability, tax, &Float.round(&1 + tax, 2))
    |> Map.update(:tax_history, [entry], &(&1 ++ [entry]))
  end

  defp apply_sales_tax(world, _taxable_amount, _source, _day), do: world

  defp apply_local_sales_tax(world, taxable_amount, source, day, opts \\ [])

  defp apply_local_sales_tax(world, taxable_amount, source, day, opts) when taxable_amount > 0 do
    rate = get(world, :sales_tax_rate, 0.0)
    tax = Float.round(taxable_amount * rate, 2)

    entry = %{
      day: day,
      source: source,
      taxable_sales: Float.round(taxable_amount, 2),
      tax_collected: tax,
      rate: rate,
      type: "collected"
    }

    world
    |> apply_local_tender(tax, "#{source}_tax", day, opts)
    |> Map.update(:sales_tax_liability, tax, &Float.round(&1 + tax, 2))
    |> Map.update(:tax_history, [entry], &(&1 ++ [entry]))
  end

  defp apply_local_sales_tax(world, _taxable_amount, _source, _day, _opts), do: world

  defp sales_tax_for(world, taxable_amount) when taxable_amount > 0 do
    Float.round(taxable_amount * get(world, :sales_tax_rate, 0.0), 2)
  end

  defp sales_tax_for(_world, _taxable_amount), do: 0.0

  defp apply_transaction_costs(world, revenue, source, day, opts) do
    transaction_count = Keyword.get(opts, :transaction_count, 1)
    shipped_orders = Keyword.get(opts, :shipped_orders, 0)
    marketplace_fee_rate = Keyword.get(opts, :marketplace_fee_rate, 0.0)
    marketplace_platform = Keyword.get(opts, :marketplace_platform, nil)
    processing_fee = processing_fee_for(world, revenue, transaction_count)
    shipping_cost = shipping_label_cost(world, shipped_orders)
    marketplace_fee = marketplace_fee_for(revenue, marketplace_fee_rate)
    total_cost = Float.round(processing_fee + shipping_cost + marketplace_fee, 2)

    if total_cost > 0.0 do
      entry = %{
        day: day,
        source: source,
        marketplace_platform: marketplace_platform,
        revenue: Float.round(revenue, 2),
        transaction_count: transaction_count,
        shipped_orders: shipped_orders,
        processing_fee: processing_fee,
        shipping_label_cost: shipping_cost,
        marketplace_fee: marketplace_fee,
        total_cost: total_cost
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - total_cost, 2))
      |> Map.update(:transaction_cost_history, [entry], &(&1 ++ [entry]))
    else
      world
    end
  end

  defp apply_local_transaction_costs(world, revenue, source, day, opts) do
    cash_rate = Keyword.get(opts, :cash_rate, get(world, :local_cash_tender_rate, 0.32))
    card_revenue = card_tender_amount(revenue, cash_rate)
    transaction_count = Keyword.get(opts, :transaction_count, 1)
    card_transaction_count = card_transaction_count(transaction_count, cash_rate, card_revenue)

    opts =
      opts
      |> Keyword.put(:transaction_count, card_transaction_count)
      |> Keyword.delete(:cash_rate)

    apply_transaction_costs(world, card_revenue, source, day, opts)
  end

  defp apply_local_tender(world, amount, source, day, opts \\ [])

  defp apply_local_tender(world, amount, source, day, opts) when amount > 0 do
    cash_rate = Keyword.get(opts, :cash_rate, get(world, :local_cash_tender_rate, 0.32))
    cash_amount = cash_tender_amount(amount, cash_rate)
    card_amount = Float.round(amount - cash_amount, 2)

    entry = %{
      day: day,
      type: "tender_split",
      source: source,
      amount: Float.round(amount, 2),
      cash_amount: cash_amount,
      card_amount: card_amount,
      cash_rate: cash_rate
    }

    world
    |> Map.update!(:cash_drawer_balance, &Float.round(&1 + cash_amount, 2))
    |> Map.update!(:bank_balance, &Float.round(&1 + card_amount, 2))
    |> Map.update(:cash_handling_history, [entry], &(&1 ++ [entry]))
  end

  defp apply_local_tender(world, _amount, _source, _day, _opts), do: world

  defp apply_cash_reconciliation({world, revenue}, day) do
    {apply_cash_reconciliation(world, day), revenue}
  end

  defp apply_cash_reconciliation(world, day) do
    already_reconciled? =
      world
      |> get(:cash_handling_history, [])
      |> Enum.any?(&(get(&1, :type) == "cash_reconciliation" and get(&1, :day) == day))

    cash_tender_total = cash_tender_total_for_day(world, day)

    cond do
      already_reconciled? ->
        world

      cash_tender_total <= 0.0 ->
        world

      true ->
        over_short = cash_reconciliation_delta(world, day, cash_tender_total)
        expected_cash = get(world, :cash_drawer_balance, 0.0)
        actual_cash = Float.round(max(0.0, expected_cash + over_short), 2)
        over_short = Float.round(actual_cash - expected_cash, 2)

        entry = %{
          day: day,
          type: "cash_reconciliation",
          source: "daily_close",
          expected_cash: Float.round(expected_cash, 2),
          actual_cash: actual_cash,
          over_short_amount: over_short,
          shortage_amount: if(over_short < 0, do: Float.round(abs(over_short), 2), else: 0.0),
          overage_amount: if(over_short > 0, do: over_short, else: 0.0),
          tender_cash_total: cash_tender_total,
          transaction_count: cash_transaction_count_for_day(world, day),
          fatigue: get(get(world, :operations, %{}), :fatigue, 0),
          loss_prevention_score: get(world, :loss_prevention_score, 0)
        }

        world
        |> Map.put(:cash_drawer_balance, actual_cash)
        |> Map.update(:cash_handling_history, [entry], &(&1 ++ [entry]))
    end
  end

  defp cash_tender_total_for_day(world, day) do
    world
    |> get(:cash_handling_history, [])
    |> Enum.filter(&(get(&1, :type) == "tender_split" and get(&1, :day) == day))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :cash_amount, 0.0) end)
    |> Float.round(2)
  end

  defp cash_transaction_count_for_day(world, day) do
    world
    |> get(:cash_handling_history, [])
    |> Enum.count(&(get(&1, :type) == "tender_split" and get(&1, :day) == day))
  end

  defp cash_reconciliation_delta(world, day, cash_tender_total) do
    seed = get(world, :seed, 1)
    fatigue = get(get(world, :operations, %{}), :fatigue, 0)
    backlog_count = length(get(get(world, :operations, %{}), :backlog_tasks, []))
    prevention_score = get(world, :loss_prevention_score, 0)

    magnitude =
      cash_tender_total * 0.006 + fatigue * 0.35 + backlog_count * 0.25 -
        prevention_score * 0.03

    magnitude =
      magnitude
      |> max(0.25)
      |> min(35.0)
      |> Float.round(2)

    if :erlang.phash2({seed, day, :cash_reconciliation}, 100) < 68 do
      -magnitude
    else
      magnitude
    end
  end

  defp cash_tender_amount(amount, cash_rate) when amount > 0 do
    Float.round(amount * cash_rate, 2)
  end

  defp cash_tender_amount(_amount, _cash_rate), do: 0.0

  defp card_tender_amount(amount, cash_rate) when amount > 0 do
    Float.round(amount - cash_tender_amount(amount, cash_rate), 2)
  end

  defp card_tender_amount(_amount, _cash_rate), do: 0.0

  defp card_transaction_count(_transaction_count, _cash_rate, card_revenue)
       when card_revenue <= 0.0,
       do: 0

  defp card_transaction_count(transaction_count, cash_rate, _card_revenue) do
    transaction_count
    |> Kernel.*(1.0 - cash_rate)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  defp processing_fee_for(_world, revenue, _transaction_count) when revenue <= 0.0, do: 0.0

  defp processing_fee_for(world, revenue, transaction_count) do
    rate = get(world, :payment_processing_rate, 0.029)
    fixed_fee = get(world, :payment_processing_fixed_fee, 0.3)
    Float.round(revenue * rate + max(transaction_count, 0) * fixed_fee, 2)
  end

  defp marketplace_fee_for(revenue, rate) when revenue > 0.0 do
    Float.round(revenue * rate, 2)
  end

  defp marketplace_fee_for(_revenue, _rate), do: 0.0

  defp shipping_label_cost(_world, shipped_orders) when shipped_orders <= 0, do: 0.0

  defp shipping_label_cost(world, shipped_orders) do
    Float.round(shipped_orders * get(world, :online_shipping_label_cost, 4.25), 2)
  end

  defp online_cogs(lines) do
    lines
    |> Enum.reduce(0.0, fn line, acc -> acc + get(line, :cost_of_goods_sold, 0.0) end)
    |> Float.round(2)
  end

  defp maybe_remit_sales_tax(world, day, status) do
    liability = get(world, :sales_tax_liability, 0.0)

    if liability > 0.0 and (rem(day, 7) == 0 or status == "complete") do
      entry = %{
        day: day,
        source: "sales_tax_remittance",
        tax_remitted: Float.round(liability, 2),
        type: "remitted"
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - liability, 2))
      |> Map.put(:sales_tax_liability, 0.0)
      |> Map.update(:tax_history, [entry], &(&1 ++ [entry]))
    else
      world
    end
  end

  defp apply_credit_line_action(world, "draw", amount) do
    world
    |> Map.update!(:bank_balance, &Float.round(&1 + amount, 2))
    |> Map.update(:credit_line_balance, amount, &Float.round(&1 + amount, 2))
  end

  defp apply_credit_line_action(world, "repay", amount) do
    world
    |> Map.update!(:bank_balance, &Float.round(&1 - amount, 2))
    |> Map.update(:credit_line_balance, 0.0, &Float.round(max(0.0, &1 - amount), 2))
  end

  defp credit_line_balance_after(world, "draw", amount) do
    Float.round(get(world, :credit_line_balance, 0.0) + amount, 2)
  end

  defp credit_line_balance_after(world, "repay", amount) do
    Float.round(max(0.0, get(world, :credit_line_balance, 0.0) - amount), 2)
  end

  defp apply_credit_line_interest(world, day) do
    balance = get(world, :credit_line_balance, 0.0)

    already_accrued? =
      world
      |> get(:debt_history, [])
      |> Enum.any?(&(get(&1, :day, nil) == day and get(&1, :type, nil) == "interest"))

    if balance > 0.0 and not already_accrued? do
      apr = get(world, :credit_line_apr, 0.18)
      interest = Float.round(balance * apr / 365, 2)

      if interest > 0.0 do
        entry = %{
          day: day,
          action: "interest",
          amount: interest,
          apr: apr,
          balance_before: Float.round(balance, 2),
          balance_after: Float.round(balance + interest, 2),
          type: "interest"
        }

        world
        |> Map.update(:credit_line_balance, interest, &Float.round(&1 + interest, 2))
        |> Map.update(:debt_history, [entry], &(&1 ++ [entry]))
      else
        world
      end
    else
      world
    end
  end

  defp apply_daily_overhead(world, day) do
    already_recorded? =
      world
      |> get(:overhead_history, [])
      |> Enum.any?(&(get(&1, :day, nil) == day))

    if already_recorded? do
      world
    else
      rent = Float.round(get(world, :daily_rent, 125.0), 2)
      utilities = Float.round(get(world, :daily_utilities, 22.5), 2)
      insurance = Float.round(get(world, :daily_insurance, 7.5), 2)
      total = Float.round(rent + utilities + insurance, 2)

      entry = %{
        day: day,
        rent: rent,
        utilities: utilities,
        insurance: insurance,
        total: total,
        type: "fixed_overhead"
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - total, 2))
      |> Map.update(:overhead_history, [entry], &(&1 ++ [entry]))
    end
  end

  defp apply_daily_payroll(world, day) do
    already_paid? =
      world
      |> get(:payroll_history, [])
      |> Enum.any?(&(get(&1, :day, nil) == day))

    if already_paid? do
      world
    else
      operations = get(world, :operations, default_operations())
      wage = get(operations, :regular_hourly_wage, 18.0)

      regular_hours =
        world
        |> get(:operations_history, [])
        |> Enum.filter(&(get(&1, :day, nil) == day))
        |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :regular_hours, 0.0) end)
        |> Float.round(2)

      paid_hours =
        if regular_hours > 0.0 do
          Float.round(max(regular_hours, 4.0), 2)
        else
          0.0
        end

      payroll_cost = Float.round(paid_hours * wage, 2)

      if payroll_cost > 0.0 do
        entry = %{
          day: day,
          regular_hours_used: regular_hours,
          paid_hours: paid_hours,
          hourly_wage: wage,
          payroll_cost: payroll_cost
        }

        updated_operations =
          operations
          |> Map.update(
            :cumulative_regular_payroll,
            payroll_cost,
            &Float.round(&1 + payroll_cost, 2)
          )

        world
        |> Map.put(:operations, updated_operations)
        |> Map.update!(:bank_balance, &Float.round(&1 - payroll_cost, 2))
        |> Map.update(:payroll_history, [entry], &(&1 ++ [entry]))
      else
        world
      end
    end
  end

  defp consume_staff_hours(world, hours, action) do
    day = get(world, :day_number, 1)
    operations = get(world, :operations, default_operations())
    remaining = get(operations, :staff_hours_remaining, 0.0)
    scheduled_remaining = get(operations, :scheduled_staff_hours_remaining, 0.0)
    regular_hours = Float.round(min(hours, remaining), 2)
    scheduled_hours = Float.round(min(max(0.0, hours - regular_hours), scheduled_remaining), 2)
    overtime_hours = Float.round(max(0.0, hours - regular_hours - scheduled_hours), 2)
    overtime_cost = Float.round(overtime_hours * 28.0, 2)

    entry = %{
      day: day,
      action: action,
      staff_hours: hours,
      regular_hours: regular_hours,
      scheduled_hours: scheduled_hours,
      overtime_hours: overtime_hours,
      overtime_cost: overtime_cost
    }

    backlog =
      if overtime_hours >= 1.0 do
        [
          %{
            day: day,
            source: action,
            task: "follow up after overtime-heavy #{String.replace(action, "_", " ")}"
          }
        ]
      else
        []
      end

    updated_operations =
      operations
      |> Map.put(:staff_hours_remaining, Float.round(max(0.0, remaining - hours), 2))
      |> Map.put(
        :scheduled_staff_hours_remaining,
        Float.round(max(0.0, scheduled_remaining - max(0.0, hours - regular_hours)), 2)
      )
      |> Map.update(
        :cumulative_overtime_hours,
        overtime_hours,
        &Float.round(&1 + overtime_hours, 2)
      )
      |> Map.update(:cumulative_overtime_cost, overtime_cost, &Float.round(&1 + overtime_cost, 2))
      |> Map.update(
        :fatigue,
        fatigue_delta(overtime_hours),
        &min(10, &1 + fatigue_delta(overtime_hours))
      )
      |> Map.update(:backlog_tasks, backlog, &(&1 ++ backlog))

    world
    |> Map.put(:operations, updated_operations)
    |> Map.update!(:bank_balance, &Float.round(&1 - overtime_cost, 2))
    |> Map.update(:operations_history, [entry], &(&1 ++ [entry]))
  end

  defp reset_staff_day(world) do
    operations = get(world, :operations, default_operations())
    daily_hours = get(operations, :daily_staff_hours, 10.0)

    backlog_tasks =
      operations
      |> get(:backlog_tasks, [])
      |> Enum.take(-6)

    updated_operations =
      operations
      |> Map.put(:staff_hours_remaining, daily_hours)
      |> Map.put(:scheduled_staff_hours, 0.0)
      |> Map.put(:scheduled_staff_hours_remaining, 0.0)
      |> Map.put(:scheduled_staff_cost, 0.0)
      |> Map.put(:fatigue, max(0, get(operations, :fatigue, 0) - 1))
      |> Map.put(:backlog_tasks, backlog_tasks)

    Map.put(world, :operations, updated_operations)
  end

  defp default_operations do
    %{
      daily_staff_hours: 10.0,
      staff_hours_remaining: 10.0,
      regular_hourly_wage: 18.0,
      scheduled_staff_hours: 0.0,
      scheduled_staff_hours_remaining: 0.0,
      scheduled_staff_cost: 0.0,
      cumulative_regular_payroll: 0.0,
      cumulative_overtime_hours: 0.0,
      cumulative_overtime_cost: 0.0,
      fatigue: 0,
      backlog_tasks: []
    }
  end

  defp default_online_channel do
    %{
      platform: "local_pickup",
      listing_quality: "basic",
      demand_multiplier: 1.0,
      marketplace_fee_rate: 0.0,
      setup_cost: 0.0
    }
  end

  defp online_demand_multiplier(channel) do
    get(channel, :demand_multiplier, 1.0)
  end

  defp estimated_transaction_count(sales) do
    Enum.reduce(sales, 0, fn sale, acc ->
      acc + max(1, div(get(sale, :quantity, 1) + 1, 2))
    end)
  end

  defp preorder_cogs(world, line_id, quantity) do
    world
    |> get(:catalog, %{})
    |> Map.get(line_id, %{})
    |> sealed_cogs(quantity)
  end

  defp sealed_cogs(line, quantity) do
    Float.round(get(line, :unit_cost, 0.0) * quantity, 2)
  end

  defp fatigue_delta(overtime_hours) when overtime_hours >= 2.0, do: 2
  defp fatigue_delta(overtime_hours) when overtime_hours > 0.0, do: 1
  defp fatigue_delta(_), do: 0

  defp apply_competitor_reaction(world, day, pulse) do
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

  defp apply_daily_shrinkage({world, revenue}, day) do
    {apply_daily_shrinkage(world, day), revenue}
  end

  defp apply_daily_shrinkage(world, day) do
    catalog = get(world, :catalog, %{})
    operations = get(world, :operations, default_operations())
    fatigue = get(operations, :fatigue, 0)
    backlog_count = length(get(operations, :backlog_tasks, []))
    prevention_score = get(world, :loss_prevention_score, 0)
    seed = get(world, :seed, 1)

    {inventory, entries} =
      world
      |> get(:inventory, %{})
      |> Enum.reduce({%{}, []}, fn {line_id, item}, {inventory_acc, entries_acc} ->
        on_hand = get(item, :on_hand, 0)
        risk = shrinkage_risk(on_hand, fatigue, backlog_count, prevention_score)

        if shrinkage_trigger?(seed, day, line_id, risk) do
          line = Map.get(catalog, line_id, %{})
          units = min(on_hand, max(1, div(on_hand, 25) + if(fatigue >= 8, do: 1, else: 0)))
          market_price = get(line, :market_price, get(item, :price, 0.0))

          entry = %{
            day: day,
            line_id: line_id,
            units: units,
            estimated_loss: Float.round(units * market_price * 0.65, 2),
            prevention_score: prevention_score,
            risk_score: risk,
            reason: shrinkage_reason(fatigue, backlog_count, prevention_score)
          }

          updated_item = Map.put(item, :on_hand, max(0, on_hand - units))
          {Map.put(inventory_acc, line_id, updated_item), entries_acc ++ [entry]}
        else
          {Map.put(inventory_acc, line_id, item), entries_acc}
        end
      end)

    if entries == [] do
      world
    else
      world
      |> Map.put(:inventory, inventory)
      |> Map.update(:shrinkage_history, entries, &(&1 ++ entries))
    end
  end

  defp shrinkage_risk(on_hand, _fatigue, _backlog_count, _prevention_score) when on_hand <= 0,
    do: 0

  defp shrinkage_risk(on_hand, fatigue, _backlog_count, prevention_score)
       when fatigue >= 8 and on_hand >= 40,
       do: max(0, 100 - prevention_score)

  defp shrinkage_risk(on_hand, fatigue, backlog_count, prevention_score) do
    max(0, 2 + fatigue * 2 + min(8, div(on_hand, 8)) + min(backlog_count, 5) - prevention_score)
  end

  defp shrinkage_trigger?(_seed, _day, _line_id, risk) when risk >= 100, do: true
  defp shrinkage_trigger?(_seed, _day, _line_id, risk) when risk <= 0, do: false

  defp shrinkage_trigger?(seed, day, line_id, risk) do
    :erlang.phash2({seed, day, line_id, :shrinkage}, 100) < risk
  end

  defp shrinkage_reason(fatigue, backlog_count, prevention_score) do
    cond do
      prevention_score >= 40 -> "loss prevention controls missed a high-risk incident"
      fatigue >= 8 -> "fatigued handling damaged inventory"
      backlog_count >= 4 -> "backlog delayed inventory cleanup"
      true -> "normal retail shrinkage"
    end
  end

  defp apply_customer_sales(world, sales) do
    Enum.reduce(sales, world, fn sale, acc ->
      segment_id = get(sale, :segment_id)

      update_customer_segment(acc, segment_id, %{
        loyalty_delta: 1,
        satisfaction_delta: 1,
        visits_delta: get(sale, :quantity, get(sale, :fulfilled_count, 0)),
        spend_delta: get(sale, :revenue, get(sale, :attach_sales, 0.0)),
        reason: get(sale, :channel, "sale")
      })
    end)
  end

  defp apply_customer_stockouts(world, stockouts) do
    Enum.reduce(stockouts, world, fn stockout, acc ->
      lost_units = get(stockout, :lost_units, 0)

      update_customer_segment(acc, get(stockout, :segment_id), %{
        loyalty_delta: -min(4, lost_units),
        satisfaction_delta: -min(6, lost_units * 2),
        visits_delta: 0,
        spend_delta: 0.0,
        reason: "stockout"
      })
    end)
  end

  defp update_customer_segment(world, nil, _changes), do: world

  defp update_customer_segment(world, segment_id, changes) do
    customer_base = get(world, :customer_base, %{})

    case Map.get(customer_base, segment_id) do
      nil ->
        world

      segment ->
        day = get(world, :day_number, 1)
        loyalty_delta = get(changes, :loyalty_delta, 0)
        satisfaction_delta = get(changes, :satisfaction_delta, 0)
        visits_delta = get(changes, :visits_delta, 0)
        spend_delta = get(changes, :spend_delta, 0.0)

        updated =
          segment
          |> Map.update(:loyalty, 50, &clamp_int(&1 + loyalty_delta, 0, 100))
          |> Map.update(:satisfaction, 50, &clamp_int(&1 + satisfaction_delta, 0, 100))
          |> Map.update(:visits, visits_delta, &(&1 + visits_delta))
          |> Map.update(:lifetime_spend, Float.round(spend_delta, 2), fn value ->
            Float.round(value + spend_delta, 2)
          end)

        history = %{
          day: day,
          segment_id: segment_id,
          reason: get(changes, :reason, "customer_update"),
          loyalty_delta: loyalty_delta,
          satisfaction_delta: satisfaction_delta,
          visits_delta: visits_delta,
          spend_delta: Float.round(spend_delta, 2),
          loyalty: get(updated, :loyalty, 50),
          satisfaction: get(updated, :satisfaction, 50)
        }

        world
        |> put_in([:customer_base, segment_id], updated)
        |> Map.update(:customer_history, [history], &(&1 ++ [history]))
    end
  end

  defp customer_demand_multiplier(world, segment_id) do
    segment =
      world
      |> get(:customer_base, %{})
      |> Map.get(segment_id, %{})

    loyalty = get(segment, :loyalty, 50)
    satisfaction = get(segment, :satisfaction, 50)
    size = get(segment, :size, 20)

    Float.round(
      (0.65 + loyalty / 180 + satisfaction / 220 + min(size, 60) / 180) *
        membership_demand_multiplier(world, segment_id),
      2
    )
  end

  defp membership_demand_multiplier(world, segment_id) do
    members =
      world
      |> get(:active_memberships, [])
      |> Enum.filter(
        &(get(&1, :status, "active") == "active" and get(&1, :segment_id) == segment_id)
      )
      |> Enum.reduce(0, fn membership, acc -> acc + get(membership, :member_count, 0) end)

    (1.0 + min(members, 60) / 240)
    |> clamp_float(1.0, 1.25)
  end

  defp competitive_demand_multiplier(world) do
    position = get(world, :competitive_position, default_competitive_position())
    share = get(position, :local_market_share_pct, 34.0)
    pressure = get(position, :competitor_pressure, 0.0)

    (0.75 + share / 100 - pressure / 35)
    |> clamp_float(0.55, 1.35)
    |> Float.round(2)
  end

  defp pending_preorder_units_for_line(world, line_id) do
    preorder_units =
      world
      |> get(:pending_preorders, [])
      |> Enum.filter(&(get(&1, :line_id) == line_id))
      |> Enum.reduce(0, fn preorder, acc -> acc + get(preorder, :remaining_quantity, 0) end)

    preorder_units + pending_special_order_units_for_line(world, line_id)
  end

  defp pending_special_order_units_for_line(world, line_id) do
    world
    |> get(:pending_special_orders, [])
    |> Enum.filter(&(get(&1, :line_id) == line_id))
    |> Enum.reduce(0, fn order, acc -> acc + get(order, :remaining_quantity, 0) end)
  end

  defp customer_segment_for_franchise("Pokemon"), do: "league_regulars"
  defp customer_segment_for_franchise("Yu-Gi-Oh!"), do: "competitive_grinders"
  defp customer_segment_for_franchise("One Piece"), do: "collectors"
  defp customer_segment_for_franchise("Dragon Ball Super"), do: "league_regulars"
  defp customer_segment_for_franchise("Accessories"), do: "parents_new_players"
  defp customer_segment_for_franchise(_), do: "league_regulars"

  defp rating_delta_to_customer_delta(delta) when delta >= 0.03, do: 2
  defp rating_delta_to_customer_delta(delta) when delta >= 0.0, do: 1
  defp rating_delta_to_customer_delta(delta) when delta <= -0.1, do: -4
  defp rating_delta_to_customer_delta(_), do: -2

  defp clamp_int(value, min, max), do: Kernel.min(Kernel.max(value, min), max)
  defp clamp_float(value, min, max), do: Kernel.min(Kernel.max(value, min), max)

  defp apply_market_movement(world, day, pulse) do
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

  defp apply_singles_sales(world, pulse) do
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
        sales_tax_collected: sales_tax_for(world, revenue),
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

  defp apply_pack_sales(world, pulse) do
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
          segment_id = customer_segment_for_franchise(franchise)

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
                  sales_tax_collected: sales_tax_for(world, revenue),
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

  defp apply_consignment_sales(world, pulse) do
    lots = get(world, :consignment_lots, [])

    case next_consignment_lot(lots, pulse) do
      nil ->
        {world, 0.0, []}

      lot ->
        reputation = get(world, :reputation, 50)
        day = get(pulse, :day, get(world, :day_number, 1))
        cards_remaining = get(lot, :cards_remaining, 0)
        value_remaining = get(lot, :value_remaining, 0.0)
        value_per_card = value_remaining / max(cards_remaining, 1)
        buzz = consignment_buzz_multiplier(lot, pulse)
        cards_sold = min(cards_remaining, max(1, trunc((1 + reputation / 35) * buzz)))
        market_value = Float.round(value_per_card * cards_sold, 2)
        revenue = Float.round(market_value * 0.96, 2)
        commission_pct = get(lot, :commission_pct, 15.0)
        commission = Float.round(revenue * commission_pct / 100, 2)
        payout = Float.round(revenue - commission, 2)

        sale = %{
          day: day,
          channel: "consignment_case",
          consignment_lot_id: get(lot, :id),
          franchise: get(lot, :franchise),
          segment_id: "collectors",
          quantity: cards_sold,
          revenue: revenue,
          consignor_payout: payout,
          commission_revenue: commission,
          commission_pct: commission_pct,
          cost_of_goods_sold: payout,
          gross_profit: commission,
          sales_tax_collected: sales_tax_for(world, revenue),
          market_value_removed: market_value
        }

        entry = Map.merge(sale, %{type: "sale"})

        next =
          world
          |> Map.put(
            :consignment_lots,
            update_consignment_lots(lots, lot, cards_sold, market_value)
          )
          |> Map.update(:consignment_payable, payout, &Float.round(&1 + payout, 2))
          |> Map.update(:consignment_history, [entry], &(&1 ++ [entry]))

        {next, revenue, [sale]}
    end
  end

  defp next_consignment_lot(lots, pulse) do
    lots
    |> Enum.filter(&(get(&1, :cards_remaining, 0) > 0))
    |> Enum.sort_by(fn lot ->
      {
        if(get(lot, :franchise) == get(pulse, :featured_franchise), do: 0, else: 1),
        get(lot, :day, 0)
      }
    end)
    |> List.first()
  end

  defp consignment_buzz_multiplier(lot, pulse) do
    if get(lot, :franchise) == get(pulse, :featured_franchise) do
      min(1.8, get(pulse, :buzz_multiplier, 1.0))
    else
      1.0
    end
  end

  defp update_consignment_lots(lots, sold_lot, cards_sold, market_value) do
    Enum.map(lots, fn lot ->
      if get(lot, :id) == get(sold_lot, :id) do
        remaining = max(0, get(lot, :cards_remaining, 0) - cards_sold)

        lot
        |> Map.put(:cards_remaining, remaining)
        |> Map.update(:value_remaining, 0.0, &Float.round(max(0.0, &1 - market_value), 2))
        |> Map.put(:status, if(remaining > 0, do: "open", else: "sold"))
      else
        lot
      end
    end)
  end

  defp apply_graded_sales(world, pulse) do
    singles = get(world, :singles_case, %{})
    graded_cards = get(singles, :graded_cards, [])

    case graded_cards do
      [] ->
        {world, 0.0, []}

      [card | remaining] ->
        day = get(pulse, :day, get(world, :day_number, 1))
        market_value = get(card, :market_value, 0.0)
        revenue = Float.round(market_value * 0.95, 2)

        sale = %{
          day: day,
          channel: "graded_case",
          segment_id: "collectors",
          quantity: get(card, :card_count, 1),
          revenue: revenue,
          cost_of_goods_sold: market_value,
          gross_profit: Float.round(revenue - market_value, 2),
          sales_tax_collected: sales_tax_for(world, revenue),
          market_value_removed: market_value,
          service_level: get(card, :service_level, "bulk")
        }

        next = put_in(world, [:singles_case, :graded_cards], remaining)
        {next, revenue, [sale]}
    end
  end

  defp stockout_reputation_penalty(stockouts) do
    stockouts
    |> Enum.reduce(0, fn stockout, acc -> acc + get(stockout, :lost_units, 0) end)
    |> then(&min(5, div(&1 + 1, 2)))
  end

  defp prize_support_for(world, game, advertised_value) do
    advertised_value = Float.round(max(0.0, advertised_value), 2)

    {lines, inventory_value, inventory_cost} =
      world
      |> prize_support_candidates(game)
      |> Enum.reduce_while({[], 0.0, 0.0}, fn candidate, {lines, value, cost} ->
        if value >= advertised_value do
          {:halt, {lines, value, cost}}
        else
          needed = max(0.0, advertised_value - value)
          unit_value = get(candidate, :unit_value, 0.0)
          available = get(candidate, :available, 0)
          quantity = min(available, max(1, ceil(needed / max(unit_value, 0.01))))

          line = %{
            line_id: get(candidate, :line_id),
            quantity: quantity,
            unit_value: unit_value,
            unit_cost: get(candidate, :unit_cost, 0.0),
            value: Float.round(quantity * unit_value, 2),
            cost: Float.round(quantity * get(candidate, :unit_cost, 0.0), 2)
          }

          {:cont,
           {
             lines ++ [line],
             Float.round(value + get(line, :value, 0.0), 2),
             Float.round(cost + get(line, :cost, 0.0), 2)
           }}
        end
      end)

    store_credit_issued = Float.round(max(0.0, advertised_value - inventory_value), 2)

    %{
      advertised_value: advertised_value,
      inventory_value: Float.round(inventory_value, 2),
      inventory_cost: Float.round(inventory_cost, 2),
      store_credit_issued: store_credit_issued,
      fulfilled_value: Float.round(inventory_value + store_credit_issued, 2),
      lines: lines
    }
  end

  defp prize_support_candidates(world, game) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.flat_map(fn {line_id, item} ->
      line = Map.get(catalog, line_id, %{})
      franchise = get(line, :franchise, "")
      category = get(line, :category, "")
      available = max(0, get(item, :on_hand, 0) - pending_preorder_units_for_line(world, line_id))

      if available > 0 and franchise in [game, "Accessories"] do
        [
          %{
            line_id: line_id,
            franchise: franchise,
            category: category,
            available: available,
            unit_value:
              get(item, :price, get(line, :suggested_price, get(line, :market_price, 0.0))),
            unit_cost: get(line, :unit_cost, 0.0)
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(fn candidate ->
      {
        prize_support_priority(candidate, game),
        -get(candidate, :unit_value, 0.0)
      }
    end)
  end

  defp prize_support_priority(candidate, game) do
    cond do
      get(candidate, :franchise) == game and get(candidate, :category) == "sealed" -> 0
      get(candidate, :franchise) == "Accessories" -> 1
      true -> 2
    end
  end

  defp prize_support_record(prize_support) do
    %{
      prize_inventory_value: get(prize_support, :inventory_value, 0.0),
      prize_inventory_cost: get(prize_support, :inventory_cost, 0.0),
      prize_store_credit_issued: get(prize_support, :store_credit_issued, 0.0),
      prize_fulfilled_value: get(prize_support, :fulfilled_value, 0.0),
      prize_support_lines: get(prize_support, :lines, [])
    }
  end

  defp apply_prize_support_lines(world, lines) do
    Enum.reduce(lines, world, fn line, acc ->
      line_id = get(line, :line_id)
      quantity = get(line, :quantity, 0)
      update_in(acc, [:inventory, line_id, :on_hand], &max((&1 || 0) - quantity, 0))
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

  defp matching_inventory_cogs(world, game, units) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.filter(fn {id, item} ->
      line = Map.get(catalog, id, %{})
      get(line, :franchise, "") in [game, "Accessories"] and get(item, :on_hand, 0) > 0
    end)
    |> Enum.map(fn {id, _item} -> Map.get(catalog, id, %{}) end)
    |> Enum.take(units)
    |> Enum.reduce(0.0, fn line, acc -> acc + get(line, :unit_cost, 0.0) end)
    |> Float.round(2)
  end

  defp customer_queue_for(world, pulse) do
    featured = get(pulse, :featured_franchise, "Pokemon")

    world
    |> get(:customer_base, %{})
    |> Enum.map(fn {segment_id, segment} ->
      %{
        segment_id: segment_id,
        type: get(segment, :type, "customer"),
        name: get(segment, :name, segment_id),
        need: customer_need(segment, featured),
        urgency: customer_urgency(segment, featured),
        loyalty: get(segment, :loyalty, 50),
        satisfaction: get(segment, :satisfaction, 50)
      }
    end)
    |> Enum.sort_by(fn customer ->
      {urgency_rank(get(customer, :urgency, "medium")), -get(customer, :satisfaction, 50)}
    end)
    |> Enum.take(4)
  end

  defp customer_need(segment, featured) do
    if get(segment, :preferred_franchise, "") == featured do
      "#{featured} demand spike: #{get(segment, :need, "")}"
    else
      get(segment, :need, "")
    end
  end

  defp customer_urgency(segment, featured) do
    cond do
      get(segment, :satisfaction, 50) < 45 -> "at_risk"
      get(segment, :preferred_franchise, "") == featured -> "high"
      true -> "medium"
    end
  end

  defp urgency_rank("high"), do: 0
  defp urgency_rank("at_risk"), do: 1
  defp urgency_rank(_), do: 2

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
