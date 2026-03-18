defmodule LemonSim.Examples.SupplyChain.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.SupplyChain.{DemandModel, Events}

  # Tier ordering: retailer is index 0 (downstream), raw_materials is index 3 (upstream)
  @tier_order ["retailer", "distributor", "factory", "raw_materials"]

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "check_inventory" -> apply_check_inventory(state, event)
      "send_forecast" -> apply_send_forecast(state, event)
      "request_info" -> apply_request_info(state, event)
      "end_communicate" -> apply_end_communicate(state, event)
      "place_order" -> apply_place_order(state, event)
      "adjust_safety_stock" -> apply_adjust_safety_stock(state, event)
      "expedite_order" -> apply_expedite_order(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Observe phase: check_inventory --

  defp apply_check_inventory(%State{} = state, event) do
    tier_id = fetch(event.payload, :tier_id, "tier_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "observe"),
         :ok <- ensure_active_actor(state.world, tier_id) do
      tier = get_tier(state.world, tier_id)
      round = get(state.world, :round, 1)

      snapshot = %{
        "inventory" => get(tier, :inventory, 0),
        "backlog" => get(tier, :backlog, 0),
        "pending_orders" => get(tier, :pending_orders, []),
        "incoming_deliveries" => get(tier, :incoming_deliveries, []),
        "cash" => get(tier, :cash, 0.0),
        "safety_stock" => get(tier, :safety_stock, 0),
        "last_order" => last_order(tier),
        "round" => round
      }

      observe_done = get(state.world, :observe_done, MapSet.new())
      observe_done = MapSet.put(observe_done, tier_id)

      next_world =
        state.world
        |> Map.put(:observe_done, observe_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.inventory_observed(tier_id, snapshot))

      all_done = Enum.all?(@tier_order, &MapSet.member?(observe_done, &1))

      if all_done do
        next_world2 =
          next_world
          |> Map.put(:phase, "communicate")
          |> Map.put(:communicate_done, MapSet.new())
          |> Map.put(:active_actor_id, List.first(@tier_order))

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("observe", "communicate"))

        {:ok, next_state2,
         {:decide, "all tiers observed, now in communicate phase for #{List.first(@tier_order)}"}}
      else
        {next_world2, _} = advance_tier(next_world, tier_id, observe_done, "observe_done")

        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide, "#{tier_id} observed inventory, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action_sc(state, event, tier_id, reason)
    end
  end

  # -- Communicate phase: send_forecast --

  defp apply_send_forecast(%State{} = state, event) do
    sender_id = fetch(event.payload, :sender_id, "sender_id")
    recipient_id = fetch(event.payload, :recipient_id, "recipient_id")
    forecast = fetch(event.payload, :forecast, "forecast", %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communicate"),
         :ok <- ensure_active_actor(state.world, sender_id),
         :ok <- ensure_adjacent_tier(sender_id, recipient_id) do
      messages = get(state.world, :messages, %{})
      recipient_msgs = Map.get(messages, recipient_id, [])
      round = get(state.world, :round, 1)

      new_msg = %{
        "from" => sender_id,
        "to" => recipient_id,
        "type" => "forecast",
        "forecast" => forecast,
        "round" => round
      }

      updated_messages = Map.put(messages, recipient_id, recipient_msgs ++ [new_msg])

      message_log = get(state.world, :message_log, [])
      updated_log = message_log ++ [%{round: round, from: sender_id, to: recipient_id, type: "forecast"}]

      next_world =
        state.world
        |> Map.put(:messages, updated_messages)
        |> Map.put(:message_log, updated_log)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.forecast_sent(sender_id, recipient_id, forecast))

      {:ok, next_state, {:decide, "#{sender_id} sent forecast to #{recipient_id}, continue communicating"}}
    else
      {:error, reason} ->
        reject_action_sc(state, event, sender_id, reason)
    end
  end

  # -- Communicate phase: request_info --

  defp apply_request_info(%State{} = state, event) do
    requester_id = fetch(event.payload, :requester_id, "requester_id")
    target_id = fetch(event.payload, :target_id, "target_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communicate"),
         :ok <- ensure_active_actor(state.world, requester_id),
         :ok <- ensure_adjacent_tier(requester_id, target_id) do
      messages = get(state.world, :messages, %{})
      target_msgs = Map.get(messages, target_id, [])
      round = get(state.world, :round, 1)

      # Post an info request visible to target — they can respond next round
      new_msg = %{
        "from" => requester_id,
        "to" => target_id,
        "type" => "request",
        "round" => round
      }

      updated_messages = Map.put(messages, target_id, target_msgs ++ [new_msg])

      next_world = Map.put(state.world, :messages, updated_messages)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.info_requested(requester_id, target_id))

      {:ok, next_state, {:decide, "#{requester_id} requested info from #{target_id}, continue communicating"}}
    else
      {:error, reason} ->
        reject_action_sc(state, event, requester_id, reason)
    end
  end

  # -- Communicate phase: end_communicate --

  defp apply_end_communicate(%State{} = state, event) do
    tier_id = fetch(event.payload, :tier_id, "tier_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communicate"),
         :ok <- ensure_active_actor(state.world, tier_id) do
      communicate_done = get(state.world, :communicate_done, MapSet.new())
      communicate_done = MapSet.put(communicate_done, tier_id)

      next_world = Map.put(state.world, :communicate_done, communicate_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.communicate_ended(tier_id))

      all_done = Enum.all?(@tier_order, &MapSet.member?(communicate_done, &1))

      if all_done do
        next_world2 =
          next_world
          |> Map.put(:phase, "order")
          |> Map.put(:order_done, MapSet.new())
          |> Map.put(:active_actor_id, List.first(@tier_order))

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("communicate", "order"))

        {:ok, next_state2,
         {:decide, "all tiers done communicating, now in order phase for #{List.first(@tier_order)}"}}
      else
        {next_world2, _} = advance_tier(next_world, tier_id, communicate_done, "communicate_done")

        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide, "#{tier_id} done communicating, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action_sc(state, event, tier_id, reason)
    end
  end

  # -- Order phase: place_order --

  defp apply_place_order(%State{} = state, event) do
    tier_id = fetch(event.payload, :tier_id, "tier_id")
    quantity = fetch(event.payload, :quantity, "quantity", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "order"),
         :ok <- ensure_active_actor(state.world, tier_id),
         :ok <- ensure_non_negative(quantity) do
      # Record the order on the tier
      tiers = get(state.world, :tiers, %{})
      tier = Map.get(tiers, tier_id, %{})
      round = get(state.world, :round, 1)

      order_history = get(tier, :order_history, [])
      updated_tier =
        tier
        |> Map.put(:pending_order, quantity)
        |> Map.put(:order_placed_this_round, true)
        |> Map.put(:order_history, order_history ++ [%{round: round, quantity: quantity}])

      updated_tiers = Map.put(tiers, tier_id, updated_tier)

      order_done = get(state.world, :order_done, MapSet.new())
      order_done = MapSet.put(order_done, tier_id)

      next_world =
        state.world
        |> Map.put(:tiers, updated_tiers)
        |> Map.put(:order_done, order_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.order_placed(tier_id, quantity))

      all_done = Enum.all?(@tier_order, &MapSet.member?(order_done, &1))

      if all_done do
        # Run fulfill, demand, and accounting phases automatically
        {final_world, phase_events} = run_fulfill_demand_accounting(next_world)
        {final_world2, game_events} = check_victory(final_world)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> final_world2 end)
          |> State.append_events(phase_events)
          |> State.append_events(game_events)

        if get(final_world2, :status, "in_progress") != "in_progress" do
          {:ok, next_state2, :skip}
        else
          {:ok, next_state2,
           {:decide,
            "round #{get(final_world2, :round, 1)} observe phase for #{MapHelpers.get_key(final_world2, :active_actor_id)}"}}
        end
      else
        {next_world2, _} = advance_tier(next_world, tier_id, order_done, "order_done")

        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide, "#{tier_id} placed order for #{quantity} units, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action_sc(state, event, tier_id, reason)
    end
  end

  # -- Adjust safety stock --

  defp apply_adjust_safety_stock(%State{} = state, event) do
    tier_id = fetch(event.payload, :tier_id, "tier_id")
    target_minimum = fetch(event.payload, :target_minimum, "target_minimum", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, tier_id),
         :ok <- ensure_non_negative(target_minimum) do
      tiers = get(state.world, :tiers, %{})
      tier = Map.get(tiers, tier_id, %{})
      updated_tier = Map.put(tier, :safety_stock, target_minimum)
      updated_tiers = Map.put(tiers, tier_id, updated_tier)

      next_world = Map.put(state.world, :tiers, updated_tiers)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.safety_stock_adjusted(tier_id, target_minimum))

      {:ok, next_state, {:decide, "#{tier_id} set safety stock to #{target_minimum} units"}}
    else
      {:error, reason} ->
        reject_action_sc(state, event, tier_id, reason)
    end
  end

  # -- Expedite order --

  defp apply_expedite_order(%State{} = state, event) do
    tier_id = fetch(event.payload, :tier_id, "tier_id")
    quantity = fetch(event.payload, :quantity, "quantity", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in_order_or_communicate(state.world),
         :ok <- ensure_active_actor(state.world, tier_id),
         :ok <- ensure_non_negative(quantity),
         :ok <- ensure_not_raw_materials(tier_id) do
      tiers = get(state.world, :tiers, %{})
      tier = Map.get(tiers, tier_id, %{})
      costs = get(state.world, :costs, DemandModel.default_costs())
      surcharge = DemandModel.expedite_cost(quantity, costs)

      # Expedited delivery arrives next round (1-round delay instead of 2)
      round = get(state.world, :round, 1)
      arrive_round = round + 1
      supplier_id = upstream_tier(tier_id)

      incoming = get(tier, :incoming_deliveries, [])
      updated_tier =
        tier
        |> Map.put(:cash, get(tier, :cash, 0.0) - surcharge)
        |> Map.put(:incoming_deliveries, incoming ++ [%{from: supplier_id, quantity: quantity, arrive_round: arrive_round, expedited: true}])

      updated_tiers = Map.put(tiers, tier_id, updated_tier)
      next_world = Map.put(state.world, :tiers, updated_tiers)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.expedite_order_placed(tier_id, quantity))

      {:ok, next_state, {:decide, "#{tier_id} expedited #{quantity} units (surcharge: #{surcharge})"}}
    else
      {:error, reason} ->
        reject_action_sc(state, event, tier_id, reason)
    end
  end

  # -- Automated phase resolution --

  defp run_fulfill_demand_accounting(world) do
    {world1, fulfill_events} = run_fulfill_phase(world)
    {world2, demand_events} = run_demand_phase(world1)
    {world3, accounting_events} = run_accounting_phase(world2)

    # Advance round and reset for next observe phase
    round = get(world3, :round, 1) + 1

    world4 =
      world3
      |> Map.put(:round, round)
      |> Map.put(:phase, "observe")
      |> Map.put(:observe_done, MapSet.new())
      |> Map.put(:active_actor_id, List.first(@tier_order))
      |> reset_round_flags()

    all_events =
      fulfill_events ++
        demand_events ++
        accounting_events ++
        [Events.phase_changed("order", "observe"), Events.round_advanced(round)]

    {world4, all_events}
  end

  defp run_fulfill_phase(world) do
    # Process in upstream-to-downstream order
    # raw_materials -> factory -> distributor -> retailer
    upstream_to_downstream = Enum.reverse(@tier_order)
    round = get(world, :round, 1)

    {tiers, events} =
      Enum.reduce(upstream_to_downstream, {get(world, :tiers, %{}), []}, fn supplier_id, {tiers_acc, events_acc} ->
        customer_id = downstream_tier(supplier_id)

        if customer_id == nil do
          {tiers_acc, events_acc}
        else
          supplier = Map.get(tiers_acc, supplier_id, %{})
          customer = Map.get(tiers_acc, customer_id, %{})

          ordered = get(customer, :pending_order, 0)
          supplier_inv = get(supplier, :inventory, 0)

          fulfilled = min(ordered, supplier_inv)
          backlog = get(customer, :backlog, 0)
          new_backlog = max(0, backlog + ordered - fulfilled)

          # Deliver now if in transit, or queue with delay
          delivery_delay = get(world, :delivery_delay, 2)
          arrive_round = round + delivery_delay

          updated_supplier = Map.put(supplier, :inventory, supplier_inv - fulfilled)

          # Add delivery to customer's incoming queue
          customer_incoming = get(customer, :incoming_deliveries, [])
          new_delivery = %{from: supplier_id, quantity: fulfilled, arrive_round: arrive_round}

          updated_customer =
            customer
            |> Map.put(:incoming_deliveries, customer_incoming ++ [new_delivery])
            |> Map.put(:backlog, new_backlog)
            |> Map.put(:pending_order, 0)
            |> Map.put(:orders_received, get(customer, :orders_received, 0) + ordered)
            |> Map.put(:orders_fulfilled, get(customer, :orders_fulfilled, 0) + fulfilled)

          new_tiers =
            tiers_acc
            |> Map.put(supplier_id, updated_supplier)
            |> Map.put(customer_id, updated_customer)

          fulfill_event = Events.order_fulfilled(supplier_id, customer_id, ordered, fulfilled)
          dispatch_event = Events.delivery_dispatched(supplier_id, customer_id, fulfilled, arrive_round)

          {new_tiers, events_acc ++ [fulfill_event, dispatch_event]}
        end
      end)

    # Raw materials tier: self-replenish from its own pending order
    tiers2 = fulfill_raw_materials(tiers, round, get(world, :delivery_delay, 2))

    {Map.put(world, :tiers, tiers2), events}
  end

  defp fulfill_raw_materials(tiers, round, delivery_delay) do
    rm = Map.get(tiers, "raw_materials", %{})
    ordered = get(rm, :pending_order, 0)

    # Raw materials tier produces its own stock — it gets what it orders (simulating extraction)
    arrive_round = round + delivery_delay
    incoming = get(rm, :incoming_deliveries, [])

    updated_rm =
      rm
      |> Map.put(:incoming_deliveries, incoming ++ [%{from: "source", quantity: ordered, arrive_round: arrive_round}])
      |> Map.put(:pending_order, 0)
      |> Map.put(:orders_received, get(rm, :orders_received, 0) + ordered)
      |> Map.put(:orders_fulfilled, get(rm, :orders_fulfilled, 0) + ordered)

    Map.put(tiers, "raw_materials", updated_rm)
  end

  defp run_demand_phase(world) do
    round = get(world, :round, 1)
    seed = get(world, :demand_seed, 0)
    demand = DemandModel.generate_demand(round, seed)

    tiers = get(world, :tiers, %{})
    retailer = Map.get(tiers, "retailer", %{})

    retailer_inv = get(retailer, :inventory, 0)
    existing_backlog = get(retailer, :backlog, 0)

    total_demand = demand + existing_backlog
    fulfilled = min(total_demand, retailer_inv)
    new_backlog = total_demand - fulfilled

    updated_retailer =
      retailer
      |> Map.put(:inventory, retailer_inv - fulfilled)
      |> Map.put(:backlog, new_backlog)
      |> Map.put(:orders_received, get(retailer, :orders_received, 0) + demand)
      |> Map.put(:orders_fulfilled, get(retailer, :orders_fulfilled, 0) + fulfilled)

    # Process arriving deliveries for all tiers
    {tiers_with_arrivals, arrival_events} =
      Enum.reduce(@tier_order, {Map.put(tiers, "retailer", updated_retailer), []}, fn tier_id, {t_acc, e_acc} ->
        process_arrivals(t_acc, tier_id, round, e_acc)
      end)

    demand_history = get(world, :demand_history, [])

    updated_world =
      world
      |> Map.put(:tiers, tiers_with_arrivals)
      |> Map.put(:consumer_demand, demand)
      |> Map.put(:demand_history, demand_history ++ [demand])

    demand_event = Events.demand_realized(demand, fulfilled, new_backlog)
    {updated_world, [demand_event | arrival_events]}
  end

  defp process_arrivals(tiers, tier_id, current_round, events_acc) do
    tier = Map.get(tiers, tier_id, %{})
    incoming = get(tier, :incoming_deliveries, [])

    {arriving, still_pending} =
      Enum.split_with(incoming, fn delivery ->
        Map.get(delivery, :arrive_round, Map.get(delivery, "arrive_round", 999)) <= current_round
      end)

    total_arriving = Enum.sum(Enum.map(arriving, fn d -> Map.get(d, :quantity, Map.get(d, "quantity", 0)) end))

    if total_arriving > 0 do
      updated_tier =
        tier
        |> Map.put(:inventory, get(tier, :inventory, 0) + total_arriving)
        |> Map.put(:incoming_deliveries, still_pending)

      arrival_event = Events.delivery_arrived(tier_id, total_arriving)
      {Map.put(tiers, tier_id, updated_tier), events_acc ++ [arrival_event]}
    else
      updated_tier = Map.put(tier, :incoming_deliveries, still_pending)
      {Map.put(tiers, tier_id, updated_tier), events_acc}
    end
  end

  defp run_accounting_phase(world) do
    tiers = get(world, :tiers, %{})
    costs = get(world, :costs, DemandModel.default_costs())

    {updated_tiers, events} =
      Enum.reduce(@tier_order, {tiers, []}, fn tier_id, {t_acc, e_acc} ->
        tier = Map.get(t_acc, tier_id, %{})
        round_costs = DemandModel.calculate_round_cost(tier, costs)

        cost_history = get(tier, :cost_history, [])

        updated_tier =
          tier
          |> Map.put(:cash, get(tier, :cash, 0.0) - round_costs.total)
          |> Map.put(:total_cost, get(tier, :total_cost, 0.0) + round_costs.total)
          |> Map.put(:cost_history, cost_history ++ [round_costs])
          |> Map.put(:order_placed_this_round, false)

        cost_event = Events.costs_assessed(tier_id, round_costs.holding, round_costs.stockout, round_costs.total)

        {Map.put(t_acc, tier_id, updated_tier), e_acc ++ [cost_event]}
      end)

    {Map.put(world, :tiers, updated_tiers), events}
  end

  # -- Victory Check --

  defp check_victory(world) do
    max_rounds = get(world, :max_rounds, 20)
    round = get(world, :round, 1)

    if round > max_rounds do
      tiers = get(world, :tiers, %{})
      costs = get(world, :cost_threshold, nil)

      # Winner: tier with lowest total cost
      {winner, _cost} =
        @tier_order
        |> Enum.map(fn tier_id ->
          tier = Map.get(tiers, tier_id, %{})
          {tier_id, get(tier, :total_cost, 0.0)}
        end)
        |> Enum.min_by(fn {_id, cost} -> cost end)

      # Check team bonus
      total_chain_cost =
        Enum.sum(Enum.map(@tier_order, fn tier_id ->
          tier = Map.get(tiers, tier_id, %{})
          get(tier, :total_cost, 0.0)
        end))

      team_bonus = costs != nil and total_chain_cost < costs

      final_world =
        world
        |> Map.put(:status, "won")
        |> Map.put(:winner, winner)
        |> Map.put(:team_bonus, team_bonus)
        |> Map.put(:total_chain_cost, total_chain_cost)

      {final_world, [Events.game_over("won", winner)]}
    else
      {world, []}
    end
  end

  # -- Phase Helpers --

  defp advance_tier(world, current_tier_id, done_set, _done_key) do
    remaining =
      @tier_order
      |> Enum.reject(&MapSet.member?(done_set, &1))

    next_tier =
      case remaining do
        [] -> current_tier_id
        [first | _] -> first
      end

    next_world = Map.put(world, :active_actor_id, next_tier)
    {next_world, []}
  end

  defp reset_round_flags(world) do
    tiers = get(world, :tiers, %{})

    updated_tiers =
      Enum.into(@tier_order, tiers, fn tier_id ->
        tier = Map.get(tiers, tier_id, %{})
        {tier_id, Map.put(tier, :order_placed_this_round, false)}
      end)

    Map.put(world, :tiers, updated_tiers)
  end

  # -- Tier Adjacency --

  defp upstream_tier("retailer"), do: "distributor"
  defp upstream_tier("distributor"), do: "factory"
  defp upstream_tier("factory"), do: "raw_materials"
  defp upstream_tier("raw_materials"), do: nil

  defp downstream_tier("raw_materials"), do: "factory"
  defp downstream_tier("factory"), do: "distributor"
  defp downstream_tier("distributor"), do: "retailer"
  defp downstream_tier("retailer"), do: nil

  defp adjacent_tiers(tier_id) do
    [upstream_tier(tier_id), downstream_tier(tier_id)]
    |> Enum.reject(&is_nil/1)
  end

  # -- Getters --

  defp get_tier(world, tier_id) do
    tiers = get(world, :tiers, %{})
    Map.get(tiers, tier_id, %{})
  end

  defp last_order(tier) do
    order_history = get(tier, :order_history, [])
    List.last(order_history)
  end

  # -- Validation --

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :game_over}
  end

  defp ensure_phase(world, expected_phase) do
    if get(world, :phase, nil) == expected_phase,
      do: :ok,
      else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, tier_id) do
    if MapHelpers.get_key(world, :active_actor_id) == tier_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp ensure_adjacent_tier(sender_id, recipient_id) do
    if recipient_id in adjacent_tiers(sender_id),
      do: :ok,
      else: {:error, :not_adjacent_tier}
  end

  defp ensure_non_negative(quantity) when is_integer(quantity) and quantity >= 0, do: :ok
  defp ensure_non_negative(quantity) when is_float(quantity) and quantity >= 0.0, do: :ok
  defp ensure_non_negative(_), do: {:error, :invalid_quantity}

  defp ensure_not_raw_materials("raw_materials"), do: {:error, :no_upstream_supplier}
  defp ensure_not_raw_materials(_), do: :ok

  defp ensure_phase_in_order_or_communicate(world) do
    phase = get(world, :phase, nil)
    if phase in ["communicate", "order"],
      do: :ok,
      else: {:error, :wrong_phase}
  end

  # -- Error handling --

  defp reject_action_sc(%State{} = state, event, tier_id, reason) do
    message = rejection_reason_sc(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(event.kind, to_string(tier_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp rejection_reason_sc(:game_over), do: "game already over"
  defp rejection_reason_sc(:wrong_phase), do: "wrong phase for this action"
  defp rejection_reason_sc(:not_active_actor), do: "not the active tier"
  defp rejection_reason_sc(:not_adjacent_tier), do: "can only communicate with adjacent tiers"
  defp rejection_reason_sc(:invalid_quantity), do: "quantity must be a non-negative integer"
  defp rejection_reason_sc(:no_upstream_supplier), do: "raw materials tier has no upstream supplier"
  defp rejection_reason_sc(other), do: "rejected: #{inspect(other)}"
end
