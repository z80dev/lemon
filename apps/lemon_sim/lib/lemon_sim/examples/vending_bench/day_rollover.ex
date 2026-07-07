defmodule LemonSim.Examples.VendingBench.DayRollover do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.{DemandModel, Events, Performance}
  alias LemonSim.Kernel.State

  import LemonSim.Examples.VendingBench.Support

  @bankruptcy_threshold 10
  @start_of_day_minutes 9 * 60

  def apply_next_day_waited(state, event) do
    state = State.append_event(state, event)
    run_day_rollover(state)
  end

  defp run_day_rollover(state) do
    world = state.world
    day = get(world, :day_number, 1)
    max_days = get(world, :max_days, 30)
    seed = get(world, :seed, 42)
    next_day = day + 1

    machine = get(world, :machine, %{})
    slots = get(machine, :slots, %{})
    catalog = get(world, :catalog, %{})
    weather = get(world, :weather, %{kind: "mild", demand_multiplier: 1.0})

    # 1. Resolve sales
    sales = DemandModel.daily_sales(demand_slots(slots, world), catalog, weather, day, seed)

    {updated_slots, total_revenue, sale_events, sale_records} =
      Enum.reduce(sales, {slots, 0.0, [], []}, fn {slot_id, units_sold, revenue},
                                                  {acc_slots, acc_rev, acc_events, acc_records} ->
        slot = Map.get(acc_slots, slot_id, %{})
        current_inv = get(slot, :inventory, 0)
        new_inv = max(0, current_inv - units_sold)
        item_id = get(slot, :item_id)

        updated_slot = Map.put(slot, :inventory, new_inv)
        new_slots = Map.put(acc_slots, slot_id, updated_slot)

        sale_event = Events.sale_realized(slot_id, item_id, units_sold, revenue, day)

        sale_record = %{
          slot_id: slot_id,
          item_id: item_id,
          quantity: units_sold,
          revenue: revenue,
          day: day
        }

        {new_slots, acc_rev + revenue, acc_events ++ [sale_event], acc_records ++ [sale_record]}
      end)

    {refund_events, refund_records, total_refunds} = refunds_for_sales(sale_records, catalog)

    # 2. Add net revenue to cash_in_machine after same-day customer refunds
    cash_in_machine = get(world, :cash_in_machine, 0.0) + total_revenue - total_refunds

    # 3. Resolve deliveries arriving today
    pending = get(world, :pending_deliveries, [])

    {arrived, still_pending} =
      Enum.split_with(pending, fn d -> get(d, :delivery_day) <= next_day end)

    {storage_after_deliveries, delivery_events, inbox_items} =
      Enum.reduce(arrived, {get(world, :storage, %{}), [], []}, fn delivery,
                                                                   {acc_storage, acc_events,
                                                                    acc_inbox} ->
        item_id = get(delivery, :item_id)
        quantity = get(delivery, :quantity, 0)
        supplier_id = get(delivery, :supplier_id, "")

        {new_storage, accepted_quantity, overflow_quantity} =
          receive_delivery(acc_storage, item_id, quantity, next_day)

        del_event = Events.delivery_arrived(supplier_id, item_id, accepted_quantity, next_day)

        overflow_events =
          if overflow_quantity > 0 do
            [Events.storage_overflow_discarded(item_id, overflow_quantity, next_day)]
          else
            []
          end

        ordered_item_id = get(delivery, :ordered_item_id, item_id)
        substituted_item_id = get(delivery, :substituted_item_id)
        delay_days = get(delivery, :delivery_delay_days, 0)

        body =
          delivery_body(
            accepted_quantity,
            ordered_item_id,
            item_id,
            delay_days,
            substituted_item_id,
            overflow_quantity
          )

        inbox_item = %{
          from: supplier_id,
          subject: "Order Delivered",
          body: body,
          day: next_day,
          metadata: %{
            ordered_item_id: ordered_item_id,
            delivered_item_id: item_id,
            substituted_item_id: substituted_item_id,
            delivery_delay_days: delay_days
          }
        }

        {new_storage, acc_events ++ [del_event | overflow_events], acc_inbox ++ [inbox_item]}
      end)

    {storage_after_spoilage, spoilage_events} =
      expire_storage(storage_after_deliveries, catalog, next_day)

    # 4. Deduct daily fee
    balance = get(world, :bank_balance, 0.0)
    daily_fee = get(world, :daily_fee, 2.0)
    unpaid_streak = get(world, :unpaid_fee_streak, 0)

    {new_balance, new_unpaid} =
      if balance >= daily_fee do
        {Float.round(balance - daily_fee, 2), 0}
      else
        {balance, unpaid_streak + 1}
      end

    fee_event = Events.daily_fee_charged(daily_fee, new_balance)

    # 5. Check bankruptcy
    bankrupt? = new_unpaid >= @bankruptcy_threshold

    # 6. Update weather
    new_weather = DemandModel.generate_weather(next_day, seed)
    new_season = DemandModel.season_for_day(next_day)
    weather_event = Events.weather_changed(new_weather.kind, new_weather.demand_multiplier)

    # 7. Build new world
    new_machine = Map.put(machine, :slots, updated_slots)
    stockout_days = stockout_days(world) + daily_stockout_slots(updated_slots)

    sales_history = get(world, :sales_history, [])
    complaint_history = get(world, :customer_complaints, [])
    refunds_paid = get(world, :refunds_paid, 0.0)

    day_event = Events.day_advanced(day, next_day)

    updated_world =
      world
      |> Map.put(:machine, new_machine)
      |> Map.put(:storage, storage_after_spoilage)
      |> Map.put(:cash_in_machine, Float.round(cash_in_machine, 2))
      |> Map.put(:bank_balance, new_balance)
      |> Map.put(:unpaid_fee_streak, new_unpaid)
      |> Map.put(:pending_deliveries, still_pending)
      |> Map.put(:recent_sales, sale_records)
      |> Map.put(:sales_history, sales_history ++ sale_records)
      |> Map.put(:customer_complaints, complaint_history ++ refund_records)
      |> Map.put(:refunds_paid, Float.round(refunds_paid + total_refunds, 2))
      |> Map.put(:stockout_days, stockout_days)
      |> Map.put(:inbox, get(world, :inbox, []) ++ inbox_items)
      |> Map.put(:weather, new_weather)
      |> Map.put(:season, new_season)
      |> Map.put(:day_number, next_day)
      |> Map.put(:time_minutes, @start_of_day_minutes)

    # 8. Check terminal conditions
    {final_world, terminal_events} =
      cond do
        bankrupt? ->
          bankruptcy_event = Events.bankruptcy_triggered(day, new_unpaid)
          perf = Performance.summarize(updated_world)
          game_over_event = Events.game_over("bankruptcy", day, perf)

          w =
            updated_world
            |> Map.put(:status, "bankrupt")

          {w, [bankruptcy_event, game_over_event]}

        next_day > max_days ->
          perf = Performance.summarize(updated_world)
          game_over_event = Events.game_over("completed", day, perf)

          w =
            updated_world
            |> Map.put(:day_number, max_days)
            |> Map.put(:status, "complete")

          {w, [game_over_event]}

        true ->
          {updated_world, []}
      end

    all_rollover_events =
      sale_events ++
        refund_events ++
        delivery_events ++
        spoilage_events ++ [fee_event, weather_event, day_event] ++ terminal_events

    state =
      state
      |> State.update_world(fn _ -> final_world end)
      |> State.append_events(all_rollover_events)

    if final_world[:status] in ["bankrupt", "complete"] do
      {:ok, state, :skip}
    else
      {:ok, state, {:decide, "Day #{next_day} begins. Weather: #{new_weather.kind}."}}
    end
  end

  def maybe_rollover(state) do
    world = state.world

    if get(world, :time_minutes, 0) >= get(world, :minutes_per_day, 24 * 60) do
      run_day_rollover(state)
    else
      {:ok, state, :skip}
    end
  end

  defp receive_delivery(storage, item_id, quantity, received_day) do
    inventory = get(storage, :inventory, %{})
    batches = get(storage, :batches, [])
    capacity = get(storage, :capacity_units, 160)
    used = storage_used_units(inventory)
    accepted_quantity = min(max(capacity - used, 0), quantity)
    overflow_quantity = quantity - accepted_quantity

    inventory =
      if accepted_quantity > 0 do
        Map.put(inventory, item_id, Map.get(inventory, item_id, 0) + accepted_quantity)
      else
        inventory
      end

    batches =
      if accepted_quantity > 0 do
        batches ++ [%{item_id: item_id, quantity: accepted_quantity, received_day: received_day}]
      else
        batches
      end

    storage =
      storage
      |> Map.put(:inventory, inventory)
      |> Map.put(:batches, batches)
      |> Map.put(:overflow_units, get(storage, :overflow_units, 0) + overflow_quantity)

    {storage, accepted_quantity, overflow_quantity}
  end

  def remove_from_storage(storage, item_id, quantity) do
    inventory = get(storage, :inventory, %{})
    batches = get(storage, :batches, [])
    current_quantity = Map.get(inventory, item_id, 0)

    storage
    |> Map.put(:inventory, Map.put(inventory, item_id, max(0, current_quantity - quantity)))
    |> Map.put(:batches, remove_from_batches(batches, item_id, quantity))
  end

  def add_to_storage(storage, item_id, quantity) do
    inventory = get(storage, :inventory, %{})
    batches = get(storage, :batches, [])

    storage
    |> Map.put(:inventory, Map.put(inventory, item_id, Map.get(inventory, item_id, 0) + quantity))
    |> Map.put(:batches, batches ++ [%{item_id: item_id, quantity: quantity, received_day: nil}])
  end

  defp remove_from_batches(batches, item_id, quantity) do
    {updated_batches, _remaining} =
      Enum.map_reduce(batches, quantity, fn batch, remaining ->
        cond do
          remaining <= 0 or get(batch, :item_id) != item_id ->
            {batch, remaining}

          get(batch, :quantity, 0) <= remaining ->
            {Map.put(batch, :quantity, 0), remaining - get(batch, :quantity, 0)}

          true ->
            {Map.put(batch, :quantity, get(batch, :quantity, 0) - remaining), 0}
        end
      end)

    Enum.reject(updated_batches, &(get(&1, :quantity, 0) <= 0))
  end

  def expired_storage_quantity(storage, catalog, item_id, day) do
    storage
    |> get(:batches, [])
    |> Enum.reduce(0, fn batch, acc ->
      batch_item_id = get(batch, :item_id)
      quantity = get(batch, :quantity, 0)
      received_day = get(batch, :received_day, day)
      item_info = Map.get(catalog, batch_item_id, %{})
      shelf_life_days = Map.get(item_info, :shelf_life_days, 365)

      if batch_item_id == item_id and quantity > 0 and day - received_day > shelf_life_days do
        acc + quantity
      else
        acc
      end
    end)
  end

  defp expire_storage(storage, catalog, day) do
    batches = get(storage, :batches, [])
    inventory = get(storage, :inventory, %{})
    unbatched_inventory = inventory_without_batches(inventory, batches)

    {kept_batches, spoiled_records, kept_inventory} =
      Enum.reduce(batches, {[], [], unbatched_inventory}, fn batch,
                                                             {batch_acc, spoiled_acc, inv_acc} ->
        item_id = get(batch, :item_id)
        quantity = get(batch, :quantity, 0)
        received_day = get(batch, :received_day, day)
        item_info = Map.get(catalog, item_id, %{})
        shelf_life_days = Map.get(item_info, :shelf_life_days, 365)

        if quantity > 0 and day - received_day > shelf_life_days do
          loss = Float.round(Map.get(item_info, :wholesale_cost, 0.0) * quantity, 2)
          record = %{item_id: item_id, quantity: quantity, loss: loss}
          {batch_acc, spoiled_acc ++ [record], inv_acc}
        else
          inv_acc = Map.put(inv_acc, item_id, Map.get(inv_acc, item_id, 0) + quantity)
          {batch_acc ++ [batch], spoiled_acc, inv_acc}
        end
      end)

    spoiled_units = Enum.reduce(spoiled_records, 0, &(&1.quantity + &2))
    spoilage_loss = Enum.reduce(spoiled_records, 0.0, &(&1.loss + &2)) |> Float.round(2)

    events =
      Enum.map(spoiled_records, fn record ->
        Events.inventory_spoiled(record.item_id, record.quantity, record.loss, day)
      end)

    storage =
      storage
      |> Map.put(:inventory, kept_inventory)
      |> Map.put(:batches, kept_batches)
      |> Map.put(:spoiled_units, get(storage, :spoiled_units, 0) + spoiled_units)
      |> Map.put(
        :spoilage_loss,
        Float.round(get(storage, :spoilage_loss, 0.0) + spoilage_loss, 2)
      )

    {storage, events}
  end

  defp inventory_without_batches(inventory, batches) do
    batched_totals =
      Enum.reduce(batches, %{}, fn batch, acc ->
        item_id = get(batch, :item_id)
        Map.put(acc, item_id, Map.get(acc, item_id, 0) + get(batch, :quantity, 0))
      end)

    Map.new(inventory, fn {item_id, quantity} ->
      {item_id, max(0, quantity - Map.get(batched_totals, item_id, 0))}
    end)
  end

  defp storage_used_units(inventory) do
    Enum.reduce(inventory, 0, fn {_item_id, quantity}, acc -> acc + quantity end)
  end

  defp demand_slots(slots, world) do
    case get(world, :arena_price_multiplier) do
      multiplier when is_number(multiplier) ->
        Map.new(slots, fn {slot_id, slot} ->
          {slot_id, Map.put(slot, :arena_price_multiplier, multiplier)}
        end)

      _ ->
        slots
    end
  end

  defp daily_stockout_slots(slots) do
    Enum.count(slots, fn {_slot_id, slot} ->
      get(slot, :item_id) != nil and get(slot, :inventory, 0) == 0
    end)
  end

  defp stockout_days(world) do
    case get(world, :stockout_days, 0) do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  defp delivery_body(
         quantity,
         ordered_item_id,
         item_id,
         delay_days,
         substituted_item_id,
         overflow_quantity
       ) do
    base =
      "Your order of #{quantity}x #{ordered_item_id} has been delivered to storage."

    substitution =
      if substituted_item_id do
        " Shipped item: #{item_id}."
      else
        ""
      end

    delay =
      if delay_days > 0 do
        " Delivery was delayed by #{delay_days} day(s)."
      else
        ""
      end

    overflow =
      if overflow_quantity > 0 do
        " #{overflow_quantity} unit(s) were discarded because storage was full."
      else
        ""
      end

    base <> substitution <> delay <> overflow
  end

  defp refunds_for_sales(sale_records, catalog) do
    Enum.reduce(sale_records, {[], [], 0.0}, fn sale, {events, records, total} ->
      item_id = get(sale, :item_id)
      quantity = get(sale, :quantity, 0)
      revenue = get(sale, :revenue, 0.0)
      day = get(sale, :day)
      item_info = Map.get(catalog, item_id, %{})
      reference_price = Map.get(item_info, :reference_price, 0.0)
      paid_price = if quantity > 0, do: revenue / quantity, else: 0.0

      if reference_price > 0.0 and paid_price > reference_price * 1.8 do
        refund_quantity = 1
        amount = Float.round(paid_price * refund_quantity, 2)
        reason = "customer_complaint_overpriced_sale"
        event = Events.customer_refund_paid(item_id, refund_quantity, amount, reason, day)

        record = %{
          item_id: item_id,
          quantity: refund_quantity,
          amount: amount,
          reason: reason,
          day: day
        }

        {events ++ [event], records ++ [record], Float.round(total + amount, 2)}
      else
        {events, records, total}
      end
    end)
  end
end
