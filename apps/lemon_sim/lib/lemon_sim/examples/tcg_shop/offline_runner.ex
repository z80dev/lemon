defmodule LemonSim.Examples.TcgShop.OfflineRunner do
  @moduledoc false

  alias LemonSim.Examples.TcgShop
  alias LemonSim.Examples.TcgShop.{Artifacts, Catalog, Events, Updater}
  alias LemonSim.Kernel.{Event, Runner, State}

  @spec run_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{state: State.t(), artifacts: map(), steps: non_neg_integer()}}
          | {:error, term()}
  def run_strategy(strategy, opts \\ [])

  def run_strategy(strategy, opts) when strategy in ["baseline", :baseline] do
    run_deterministic_strategy("baseline", opts, &baseline_events_for_day/1)
  end

  def run_strategy(strategy, opts) when strategy in ["pressure", :pressure] do
    run_deterministic_strategy("pressure", opts, &pressure_events_for_day/1)
  end

  def run_strategy(strategy, opts) when strategy in ["overextended", :overextended] do
    run_deterministic_strategy("overextended", opts, &overextended_events_for_day/1)
  end

  def run_strategy(strategy, _opts), do: {:error, {:unknown_tcg_shop_offline_strategy, strategy}}

  @spec events_for_day(map()) :: [Event.t()]
  def events_for_day(world), do: baseline_events_for_day(world)

  defp run_deterministic_strategy(strategy, opts, event_fun) do
    sim_id = Keyword.get(opts, :sim_id, "tcg_#{strategy}_#{:erlang.unique_integer([:positive])}")

    state =
      opts
      |> Keyword.put(:sim_id, sim_id)
      |> Keyword.put_new(:max_days, 14)
      |> Keyword.put_new(:seed, 1)
      |> TcgShop.initial_state()

    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, 80))

    with {:ok, final_state, events, actions, steps} <-
           run_deterministic_loop(state, max_turns, [], [], 0, event_fun),
         artifact_opts <-
           opts
           |> Keyword.put(:offline_strategy, strategy)
           |> Keyword.put(
             :artifact_report_title,
             "TCG Shop Offline #{String.capitalize(strategy)} Report"
           ),
         {:ok, artifacts} <-
           Artifacts.write_run_artifacts(final_state, events, actions, artifact_opts) do
      {:ok, %{state: final_state, artifacts: artifacts, steps: steps}}
    end
  end

  defp run_deterministic_loop(state, max_turns, events, actions, turn, event_fun) do
    cond do
      terminal?(state) ->
        {:ok, state, events, actions, turn}

      turn >= max_turns ->
        {:error, {:tcg_shop_offline_turn_limit_exceeded, max_turns}}

      true ->
        planned_events = event_fun.(state.world)
        action = action_summary(state.world, planned_events)

        case ingest_collecting_events(state, planned_events, events) do
          {:ok, next_state, next_events} ->
            run_deterministic_loop(
              next_state,
              max_turns,
              next_events,
              actions ++ [action],
              turn + 1,
              event_fun
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp baseline_events_for_day(world) do
    day = get(world, :day_number, 1)

    support_events(world) ++
      baseline_restock_events(world) ++
      baseline_preorder_events(day) ++
      baseline_promotion_events(day) ++
      baseline_event_events(day) ++
      [Events.process_online_orders("standard"), Events.wait_next_day("balanced daily close")]
  end

  defp pressure_events_for_day(world) do
    day = get(world, :day_number, 1)

    support_events(world) ++
      pressure_market_events(day) ++
      pressure_preorder_events(day) ++
      pressure_special_order_events(day) ++
      pressure_promotion_events(day) ++
      pressure_financing_events(day) ++
      pressure_staffing_events(day) ++
      pressure_loss_prevention_events(day) ++
      pressure_online_channel_events(day) ++
      pressure_supplier_claim_events(world) ++
      pressure_customer_return_events(world) ++
      pressure_bank_deposit_events(world) ++
      pressure_buylist_events(day) ++
      pressure_pack_prep_events(world, day) ++
      pressure_sealed_opening_events(world, day) ++
      pressure_consignment_events(day) ++
      pressure_membership_events(day) ++
      pressure_restock_events(world) ++
      pressure_grading_events(world, day) ++
      pressure_event_events(day) ++
      [Events.process_online_orders(pressure_online_quality(day))] ++
      [Events.wait_next_day("pressure strategy daily close")]
  end

  defp overextended_events_for_day(world) do
    day = get(world, :day_number, 1)

    support_events(world) ++
      overextended_market_events(day) ++
      overextended_financing_events(day) ++
      overextended_online_channel_events(day) ++
      overextended_pricing_events(day) ++
      overextended_promotion_events(day) ++
      overextended_preorder_events(day) ++
      overextended_special_order_events(day) ++
      overextended_collection_events(day) ++
      overextended_restock_events(world, day) ++
      overextended_event_events(day) ++
      overextended_grading_events(world, day) ++
      overextended_customer_return_events(world, day) ++
      [Events.process_online_orders(overextended_online_quality(day))] ++
      [Events.wait_next_day("overextended strategy daily close")]
  end

  defp pressure_online_quality(day) when day in [2, 6], do: "cheap"
  defp pressure_online_quality(day) when rem(day, 3) == 0, do: "premium"
  defp pressure_online_quality(_day), do: "standard"

  defp overextended_online_quality(day) when day in [1, 2, 4, 6, 8], do: "cheap"
  defp overextended_online_quality(_day), do: "standard"

  defp support_events(world) do
    [
      Events.checked_dashboard(get(world, :day_number, 1), get(world, :bank_balance, 0.0)),
      Events.inspected_inventory(map_size(get(world, :inventory, %{}))),
      Events.reviewed_customers(length(get(world, :customer_queue, [])))
    ]
  end

  defp baseline_restock_events(world) do
    credit_aware_restock_events(world, [
      {"pokemon_booster_box", 6, 2},
      {"pokemon_elite_trainer_box", 8, 4},
      {"yugioh_core_box", 5, 2},
      {"one_piece_booster_box", 5, 2},
      {"card_sleeves", 18, 24},
      {"toploaders", 14, 18}
    ])
  end

  defp pressure_restock_events(world) do
    credit_aware_restock_events(world, [
      {"one_piece_booster_box", 8, 4},
      {"pokemon_booster_box", 8, 3},
      {"dragon_ball_fusion_box", 6, 3},
      {"card_sleeves", 24, 30},
      {"toploaders", 20, 24}
    ])
  end

  defp credit_aware_restock_events(world, specs) do
    {events, _available_credit} =
      Enum.reduce(specs, {[], supplier_credit_available(world)}, fn {line_id, threshold, quantity},
                                                                    {events_acc, credit_acc} ->
        case restock_if_below(world, line_id, threshold, quantity, credit_acc) do
          {nil, credit_acc} -> {events_acc, credit_acc}
          {event, next_credit} -> {events_acc ++ [event], next_credit}
        end
      end)

    events
  end

  defp restock_if_below(world, line_id, threshold, quantity, available_credit) do
    on_hand =
      world
      |> get(:inventory, %{})
      |> get(line_id, %{})
      |> get(:on_hand, 0)

    pending =
      world
      |> get(:pending_deliveries, [])
      |> Enum.reduce(0, fn delivery, acc ->
        if get(delivery, :line_id) == line_id, do: acc + get(delivery, :quantity, 0), else: acc
      end)

    estimated_cost = estimated_order_cost(line_id, quantity)

    if on_hand + pending < threshold and estimated_cost <= available_credit do
      {Events.order_product_line(line_id, quantity),
       Float.round(available_credit - estimated_cost, 2)}
    else
      {nil, available_credit}
    end
  end

  defp supplier_credit_available(world) do
    max(0.0, effective_supplier_credit_limit(world) - accounts_payable(world))
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

  defp accounts_payable(world) do
    world
    |> get(:pending_supplier_invoices, [])
    |> Enum.reduce(0.0, fn invoice, acc -> acc + get(invoice, :amount_due, 0.0) end)
  end

  defp estimated_order_cost(line_id, quantity) do
    case Catalog.line(line_id) do
      nil -> 0.0
      line -> Float.round(get(line, :unit_cost, 0.0) * quantity, 2)
    end
  end

  defp baseline_event_events(day) when day in [3, 7, 11] do
    [Events.host_event("Pokemon", 120.0, 12.0)]
  end

  defp baseline_event_events(_day), do: []

  defp baseline_preorder_events(2), do: [Events.take_preorders("pokemon_booster_box", 2, 25.0)]
  defp baseline_preorder_events(_day), do: []

  defp baseline_promotion_events(1), do: [Events.run_promotion("Pokemon", "email_list", 120.0, 3)]
  defp baseline_promotion_events(_day), do: []

  defp pressure_market_events(day) when day in [1, 4, 8] do
    events = [Events.researched_market("allocation spikes and singles demand day #{day}", 4)]

    if day == 8 do
      events ++ [Events.set_prices(80.0, "card_sleeves")]
    else
      events
    end
  end

  defp pressure_market_events(_day), do: []

  defp pressure_buylist_events(day) when day in [2, 6, 10] do
    franchise = if day == 6, do: "One Piece", else: "Pokemon"
    [Events.buy_collection(franchise, 650.0, "mixed")]
  end

  defp pressure_buylist_events(_day), do: []

  defp pressure_sealed_opening_events(world, day) when day in [1, 5, 8] do
    line_id =
      case day do
        1 -> "pokemon_booster_box"
        5 -> "one_piece_booster_box"
        8 -> "yugioh_core_box"
      end

    if sealed_on_hand(world, line_id) > 0 do
      [Events.open_sealed_product(line_id, 1)]
    else
      []
    end
  end

  defp pressure_sealed_opening_events(_world, _day), do: []

  defp pressure_pack_prep_events(world, day) when day in [1, 6] do
    {line_id, pack_price} =
      case day do
        1 -> {"pokemon_booster_box", 6.49}
        _ -> {"one_piece_booster_box", 6.99}
      end

    if sealed_on_hand(world, line_id) > 0 do
      [Events.prepare_loose_packs(line_id, 1, pack_price)]
    else
      []
    end
  end

  defp pressure_pack_prep_events(_world, _day), do: []

  defp sealed_on_hand(world, line_id) do
    world
    |> get(:inventory, %{})
    |> get(line_id, %{})
    |> get(:on_hand, 0)
  end

  defp pressure_consignment_events(3) do
    [Events.take_consignment("One Piece", 18, 720.0, 15.0)]
  end

  defp pressure_consignment_events(9) do
    [Events.take_consignment("Pokemon", 24, 540.0, 18.0)]
  end

  defp pressure_consignment_events(_day), do: []

  defp pressure_membership_events(1) do
    [Events.sell_memberships("Pokemon", 18, 28.0, 7)]
  end

  defp pressure_membership_events(8) do
    [Events.sell_memberships("Yu-Gi-Oh!", 10, 35.0, 5)]
  end

  defp pressure_membership_events(_day), do: []

  defp pressure_preorder_events(2), do: [Events.take_preorders("pokemon_booster_box", 5, 25.0)]
  defp pressure_preorder_events(4), do: [Events.take_preorders("one_piece_booster_box", 4, 35.0)]
  defp pressure_preorder_events(7), do: [Events.take_preorders("yugioh_core_box", 3, 20.0)]
  defp pressure_preorder_events(_day), do: []

  defp pressure_special_order_events(1), do: [Events.take_special_order("card_sleeves", 6, 50.0)]
  defp pressure_special_order_events(_day), do: []

  defp pressure_promotion_events(1), do: [Events.run_promotion("Pokemon", "social_ads", 240.0, 4)]

  defp pressure_promotion_events(4),
    do: [Events.run_promotion("One Piece", "creator_sponsorship", 360.0, 3)]

  defp pressure_promotion_events(8),
    do: [Events.run_promotion("Yu-Gi-Oh!", "email_list", 180.0, 2)]

  defp pressure_promotion_events(_day), do: []

  defp pressure_financing_events(1) do
    [Events.manage_credit_line("draw", 1_200.0, "float preorder deposits and allocation buys")]
  end

  defp pressure_financing_events(10) do
    [Events.manage_credit_line("repay", 600.0, "pay down line after release weekend cash")]
  end

  defp pressure_financing_events(_day), do: []

  defp pressure_staffing_events(1), do: [Events.schedule_staff_shift("online_fulfillment", 4.0)]
  defp pressure_staffing_events(3), do: [Events.schedule_staff_shift("sales_floor", 3.0)]
  defp pressure_staffing_events(_day), do: []

  defp pressure_loss_prevention_events(2), do: [Events.upgrade_loss_prevention("camera_system")]
  defp pressure_loss_prevention_events(_day), do: []

  defp pressure_online_channel_events(2),
    do: [Events.manage_online_channel("tcgplayer", "optimized")]

  defp pressure_online_channel_events(_day), do: []

  defp pressure_supplier_claim_events(world) do
    world
    |> get(:delivery_receipt_history, [])
    |> Enum.find(fn receipt ->
      get(receipt, :damaged_units, 0) > get(receipt, :claimed_units, 0)
    end)
    |> case do
      nil ->
        []

      receipt ->
        unclaimed = get(receipt, :damaged_units, 0) - get(receipt, :claimed_units, 0)
        [Events.file_supplier_claim(get(receipt, :invoice_id), unclaimed)]
    end
  end

  defp pressure_customer_return_events(world) do
    if get(world, :return_history, []) != [] do
      []
    else
      world
      |> get(:sales_history, [])
      |> Enum.find(fn sale ->
        line_id = get(sale, :line_id)

        (get(sale, :quantity, 0) > 0 and line_id) &&
          get(sale, :channel) in ["walk_in", "preorder"]
      end)
      |> case do
        nil ->
          []

        sale ->
          [
            Events.process_customer_return(
              get(sale, :line_id),
              1,
              "sealed_resellable",
              "store_credit"
            )
          ]
      end
    end
  end

  defp pressure_bank_deposit_events(world) do
    drawer_balance = get(world, :cash_drawer_balance, 0.0)

    already_deposited_today? =
      world
      |> get(:cash_handling_history, [])
      |> Enum.any?(
        &(get(&1, :type) == "bank_deposit" and get(&1, :day) == get(world, :day_number, 1))
      )

    if drawer_balance >= 900.0 and not already_deposited_today? do
      deposit = Float.round(max(0.0, drawer_balance - 350.0), 2)
      [Events.make_bank_deposit(deposit, "reduce register cash exposure")]
    else
      []
    end
  end

  defp pressure_grading_events(world, day) when day in [3, 9] do
    singles = get(world, :singles_case, %{})

    if get(singles, :cards_on_hand, 0) >= 12 do
      [Events.submit_grading(12, if(day == 3, do: "standard", else: "express"))]
    else
      []
    end
  end

  defp pressure_grading_events(_world, _day), do: []

  defp pressure_event_events(day) when day in [3, 5, 8, 12] do
    game =
      case day do
        5 -> "One Piece"
        8 -> "Yu-Gi-Oh!"
        12 -> "Dragon Ball Super"
        _ -> "Pokemon"
      end

    [Events.host_event(game, 220.0, 15.0)]
  end

  defp pressure_event_events(_day), do: []

  defp overextended_market_events(day) when day in [1, 3, 6, 9] do
    [
      Events.researched_market(
        "cash allocation online channel event staffing pressure day #{day}",
        5
      )
    ]
  end

  defp overextended_market_events(_day), do: []

  defp overextended_financing_events(1),
    do: [Events.manage_credit_line("draw", 3_000.0, "chase every release and online channel")]

  defp overextended_financing_events(_day), do: []

  defp overextended_online_channel_events(1),
    do: [Events.manage_online_channel("ebay", "premium")]

  defp overextended_online_channel_events(_day), do: []

  defp overextended_pricing_events(1), do: [Events.set_prices(80.0)]
  defp overextended_pricing_events(4), do: [Events.set_prices(75.0, "card_sleeves")]
  defp overextended_pricing_events(_day), do: []

  defp overextended_promotion_events(1),
    do: [Events.run_promotion("Pokemon", "creator_sponsorship", 1_500.0, 7)]

  defp overextended_promotion_events(2),
    do: [Events.run_promotion("One Piece", "social_ads", 1_200.0, 5)]

  defp overextended_promotion_events(_day), do: []

  defp overextended_preorder_events(1),
    do: [Events.take_preorders("pokemon_booster_box", 40, 10.0)]

  defp overextended_preorder_events(2),
    do: [Events.take_preorders("one_piece_booster_box", 36, 10.0)]

  defp overextended_preorder_events(_day), do: []

  defp overextended_special_order_events(1),
    do: [Events.take_special_order("pokemon_booster_box", 24, 10.0)]

  defp overextended_special_order_events(3),
    do: [Events.take_special_order("one_piece_booster_box", 24, 10.0)]

  defp overextended_special_order_events(_day), do: []

  defp overextended_collection_events(1), do: [Events.buy_collection("Pokemon", 5_000.0, "chase")]

  defp overextended_collection_events(2),
    do: [Events.buy_collection("One Piece", 4_000.0, "chase")]

  defp overextended_collection_events(_day), do: []

  defp overextended_restock_events(world, day) do
    specs =
      case day do
        1 ->
          [
            {"pokemon_booster_box", 80, 18},
            {"one_piece_booster_box", 80, 16},
            {"yugioh_core_box", 40, 12},
            {"card_sleeves", 120, 80}
          ]

        2 ->
          [
            {"pokemon_booster_box", 90, 18},
            {"one_piece_booster_box", 90, 16},
            {"toploaders", 100, 80}
          ]

        _ ->
          [
            {"pokemon_booster_box", 40, 8},
            {"one_piece_booster_box", 40, 8},
            {"card_sleeves", 70, 40}
          ]
      end

    credit_aware_restock_events(world, specs)
  end

  defp overextended_event_events(day) when day in [1, 2, 3, 5, 7] do
    game =
      case day do
        2 -> "One Piece"
        3 -> "Yu-Gi-Oh!"
        7 -> "Dragon Ball Super"
        _ -> "Pokemon"
      end

    [Events.host_event(game, 1_000.0, 0.0)]
  end

  defp overextended_event_events(_day), do: []

  defp overextended_grading_events(world, day) when day in [2, 4] do
    singles = get(world, :singles_case, %{})

    if get(singles, :cards_on_hand, 0) >= 30 do
      [Events.submit_grading(30, "express")]
    else
      []
    end
  end

  defp overextended_grading_events(_world, _day), do: []

  defp overextended_customer_return_events(world, day) when day in [3, 5] do
    case most_recent_sale_line(world) do
      nil -> []
      line_id -> [Events.process_customer_return(line_id, 2, "opened", "cash_refund")]
    end
  end

  defp overextended_customer_return_events(_world, _day), do: []

  defp most_recent_sale_line(world) do
    world
    |> get(:sales_history, [])
    |> Enum.reverse()
    |> Enum.find_value(fn sale ->
      line_id = get(sale, :line_id)
      if line_id, do: line_id, else: nil
    end)
  end

  defp action_summary(world, events) do
    %{
      day: get(world, :day_number, 1),
      support_calls: Enum.count(events, &support_event?/1),
      orders: Enum.count(events, &(event_kind(&1) == "tcg_order_product_line")),
      collections: Enum.count(events, &(event_kind(&1) == "tcg_buy_collection")),
      sealed_openings: Enum.count(events, &(event_kind(&1) == "tcg_open_sealed_product")),
      pack_preparations: Enum.count(events, &(event_kind(&1) == "tcg_prepare_loose_packs")),
      consignments: Enum.count(events, &(event_kind(&1) == "tcg_take_consignment")),
      memberships: Enum.count(events, &(event_kind(&1) == "tcg_sell_memberships")),
      staffing: Enum.count(events, &(event_kind(&1) == "tcg_schedule_staff_shift")),
      loss_prevention: Enum.count(events, &(event_kind(&1) == "tcg_upgrade_loss_prevention")),
      online_channel_updates:
        Enum.count(events, &(event_kind(&1) == "tcg_manage_online_channel")),
      events_hosted: Enum.count(events, &(event_kind(&1) == "tcg_host_event")),
      preorders: Enum.count(events, &(event_kind(&1) == "tcg_take_preorders")),
      special_orders: Enum.count(events, &(event_kind(&1) == "tcg_take_special_order")),
      promotions: Enum.count(events, &(event_kind(&1) == "tcg_run_promotion")),
      financing: Enum.count(events, &(event_kind(&1) == "tcg_manage_credit_line")),
      bank_deposits: Enum.count(events, &(event_kind(&1) == "tcg_make_bank_deposit")),
      supplier_claims: Enum.count(events, &(event_kind(&1) == "tcg_file_supplier_claim")),
      customer_returns: Enum.count(events, &(event_kind(&1) == "tcg_process_customer_return")),
      grading_submissions: Enum.count(events, &(event_kind(&1) == "tcg_submit_grading")),
      online_order_batches: Enum.count(events, &(event_kind(&1) == "tcg_process_online_orders")),
      closes: Enum.count(events, &(event_kind(&1) == "tcg_wait_next_day"))
    }
  end

  defp support_event?(event) do
    event_kind(event) in [
      "tcg_checked_dashboard",
      "tcg_inspected_inventory",
      "tcg_researched_market",
      "tcg_reviewed_customers"
    ]
  end

  defp ingest_collecting_events(state, events, collected_events) do
    Enum.reduce_while(events, {:ok, state, collected_events}, fn event,
                                                                 {:ok, current_state, acc_events} ->
      before_recent = current_state.recent_events

      case Runner.ingest_events(current_state, [event], Updater) do
        {:ok, next_state, _signal} ->
          appended = appended_recent_events(before_recent, next_state.recent_events)
          {:cont, {:ok, next_state, acc_events ++ appended}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp appended_recent_events(before_recent, after_recent) do
    max_overlap = min(length(before_recent), length(after_recent))

    overlap =
      max_overlap..0//-1
      |> Enum.find(0, fn count ->
        Enum.take(before_recent, -count) == Enum.take(after_recent, count)
      end)

    Enum.drop(after_recent, overlap)
  end

  defp terminal?(state) do
    get(state.world, :status) in ["complete", "bankrupt"]
  end

  defp event_kind(%{kind: kind}), do: kind
  defp event_kind(%{"kind" => kind}), do: kind
  defp event_kind(_event), do: nil

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_map, _key, default), do: default
end
