defmodule LemonSim.Examples.VendingBench.MachineEvents do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.Events
  alias LemonSim.Kernel.State
  alias LemonSim.Examples.VendingBench.DayRollover

  import LemonSim.Examples.VendingBench.Support

  @worker_visit_minutes 75
  @worker_day_end_minutes 17 * 60
  @worker_latest_departure_minutes @worker_day_end_minutes - @worker_visit_minutes

  def apply_worker_requested(state, event) do
    time_minutes = get(state.world, :time_minutes, 540)

    if time_minutes > @worker_latest_departure_minutes do
      reject_worker_dispatch(
        state,
        "Too late to dispatch the physical worker at #{format_time(time_minutes)}. " <>
          "Worker visits must start by #{format_time(@worker_latest_departure_minutes)} to be back by 17:00."
      )
    else
      state =
        state
        |> State.update_world(fn world ->
          count = get(world, :physical_worker_run_count, 0)

          world
          |> Map.put(:physical_worker_run_count, count + 1)
          |> Map.put(:time_minutes, get(world, :time_minutes, 540) + @worker_visit_minutes)
        end)
        |> State.append_event(event)

      {:ok, state, :skip}
    end
  end

  def apply_machine_stocked(state, event) do
    slot_id = get(event.payload, :slot_id, "")
    item_id = get(event.payload, :item_id, "")
    quantity = get(event.payload, :quantity, 0)
    world = state.world
    machine = get(world, :machine, %{})
    slots = get(machine, :slots, %{})
    storage = get(world, :storage, %{})
    storage_inv = get(storage, :inventory, %{})
    catalog = get(world, :catalog, %{})
    slot = Map.get(slots, slot_id)
    storage_qty = Map.get(storage_inv, item_id, 0)
    item_info = Map.get(catalog, item_id, %{})
    item_size = Map.get(item_info, :size_class, "small")
    slot_type = get(slot || %{}, :slot_type, "small")

    cond do
      is_nil(slot) ->
        reject_worker_event(state, "Invalid slot #{slot_id}")

      not Map.has_key?(catalog, item_id) ->
        reject_worker_event(state, "Unknown catalog item #{item_id}")

      item_size != slot_type ->
        reject_worker_event(
          state,
          "Cannot stock #{item_id} in #{slot_id}; #{item_size} items require a #{item_size} slot"
        )

      quantity <= 0 ->
        reject_worker_event(state, "Stock quantity must be positive")

      storage_qty < quantity ->
        reject_worker_event(
          state,
          "Cannot stock #{quantity} units of #{item_id}; only #{storage_qty} available in storage"
        )

      get(slot, :item_id) != nil and get(slot, :item_id) != item_id ->
        reject_worker_event(
          state,
          "Slot #{slot_id} already contains #{get(slot, :item_id)}"
        )

      true ->
        state =
          state
          |> State.update_world(fn world ->
            machine = get(world, :machine, %{})
            slots = get(machine, :slots, %{})
            storage = get(world, :storage, %{})
            catalog = get(world, :catalog, %{})
            slot = Map.get(slots, slot_id, %{})
            current_inv = get(slot, :inventory, 0)

            new_storage = DayRollover.remove_from_storage(storage, item_id, quantity)

            new_price =
              if get(slot, :price) do
                get(slot, :price)
              else
                item_info = Map.get(catalog, item_id, %{})
                Map.get(item_info, :reference_price, 2.00)
              end

            new_slot =
              slot
              |> Map.put(:item_id, item_id)
              |> Map.put(:inventory, current_inv + quantity)
              |> Map.put(:price, new_price)

            new_slots = Map.put(slots, slot_id, new_slot)
            new_machine = Map.put(machine, :slots, new_slots)

            world
            |> Map.put(:machine, new_machine)
            |> Map.put(:storage, new_storage)
          end)
          |> State.append_event(event)

        {:ok, state, :skip}
    end
  end

  def apply_cash_collected(state, event) do
    amount = get(event.payload, :amount, 0.0)
    cash = get(state.world, :cash_in_machine, 0.0)

    cond do
      amount <= 0 ->
        reject_worker_event(state, "Collected cash amount must be positive")

      cash <= 0 ->
        reject_worker_event(state, "No cash is available to collect")

      amount > cash ->
        reject_worker_event(
          state,
          "Cannot collect $#{format_price(amount)}; only $#{format_price(cash)} is available"
        )

      true ->
        state =
          state
          |> State.update_world(fn world ->
            balance = get(world, :bank_balance, 0.0)
            cash = get(world, :cash_in_machine, 0.0)

            world
            |> Map.put(:bank_balance, Float.round(balance + amount, 2))
            |> Map.put(:cash_in_machine, Float.round(cash - amount, 2))
          end)
          |> State.append_event(event)

        {:ok, state, :skip}
    end
  end

  def apply_price_set(state, event) do
    slot_id = get(event.payload, :slot_id, "")
    new_price = get(event.payload, :new_price, 0.0)
    machine = get(state.world, :machine, %{})
    slots = get(machine, :slots, %{})
    slot = Map.get(slots, slot_id)

    cond do
      is_nil(slot) ->
        reject_worker_event(state, "Invalid slot #{slot_id}")

      get(slot, :item_id) == nil ->
        reject_worker_event(state, "Cannot price empty slot #{slot_id}")

      new_price <= 0 ->
        reject_worker_event(state, "Price must be positive")

      true ->
        state =
          state
          |> State.update_world(fn world ->
            machine = get(world, :machine, %{})
            slots = get(machine, :slots, %{})
            slot = Map.get(slots, slot_id, %{})

            new_slot = Map.put(slot, :price, Float.round(new_price * 1.0, 2))
            new_slots = Map.put(slots, slot_id, new_slot)
            new_machine = Map.put(machine, :slots, new_slots)

            price_changes = get(world, :price_change_count, 0)

            world
            |> Map.put(:machine, new_machine)
            |> Map.put(:price_change_count, price_changes + 1)
          end)
          |> State.append_event(event)

        {:ok, state, :skip}
    end
  end

  def apply_expired_inventory_removed(state, event) do
    item_id = get(event.payload, :item_id, "")
    quantity = get(event.payload, :quantity, 0)
    world = state.world
    storage = get(world, :storage, %{})
    storage_inv = get(storage, :inventory, %{})
    catalog = get(world, :catalog, %{})
    day = get(world, :day_number, 1)
    storage_qty = Map.get(storage_inv, item_id, 0)
    expired_qty = DayRollover.expired_storage_quantity(storage, catalog, item_id, day)

    cond do
      not Map.has_key?(catalog, item_id) ->
        reject_worker_event(state, "Unknown catalog item #{item_id}")

      quantity <= 0 ->
        reject_worker_event(state, "Removed quantity must be positive")

      storage_qty < quantity ->
        reject_worker_event(
          state,
          "Cannot remove #{quantity} units of #{item_id}; only #{storage_qty} available in storage"
        )

      expired_qty < quantity ->
        reject_worker_event(
          state,
          "Cannot remove #{quantity} expired units of #{item_id}; only #{expired_qty} expired"
        )

      true ->
        item_info = Map.get(catalog, item_id, %{})
        loss = Float.round(Map.get(item_info, :wholesale_cost, 0.0) * quantity, 2)
        authoritative_event = Events.expired_inventory_removed(item_id, quantity, loss, day)

        state =
          state
          |> State.update_world(fn world ->
            storage = get(world, :storage, %{})

            storage =
              storage
              |> DayRollover.remove_from_storage(item_id, quantity)
              |> Map.put(:spoiled_units, get(storage, :spoiled_units, 0) + quantity)
              |> Map.put(
                :spoilage_loss,
                Float.round(get(storage, :spoilage_loss, 0.0) + loss, 2)
              )

            Map.put(world, :storage, storage)
          end)
          |> State.append_event(authoritative_event)

        {:ok, state, :skip}
    end
  end

  def apply_machine_fault_reported(state, event) do
    description = event.payload |> get(:description, "") |> to_string() |> String.trim()
    severity = event.payload |> get(:severity, "low") |> to_string() |> String.trim()
    day = get(state.world, :day_number, 1)

    report = %{description: description, severity: severity, day: day}
    event = Events.machine_fault_reported(description, severity, day)

    state =
      state
      |> State.update_world(fn world ->
        reports = get(world, :machine_fault_reports, [])
        Map.put(world, :machine_fault_reports, reports ++ [report])
      end)
      |> State.append_event(event)

    {:ok, state, :skip}
  end

  def apply_worker_finished(state, event) do
    summary = get(event.payload, :summary, "")
    tool_calls = get(event.payload, :tool_calls, [])
    memory_namespace = get(event.payload, :memory_namespace)
    turn_count = get(event.payload, :turn_count)

    state =
      state
      |> State.update_world(fn world ->
        history = get(world, :physical_worker_history, [])

        report = %{
          summary: summary,
          day: get(world, :day_number, 1),
          time: get(world, :time_minutes, 540),
          tool_calls: tool_calls,
          memory_namespace: memory_namespace,
          turn_count: turn_count
        }

        world
        |> Map.put(:physical_worker_last_report, report)
        |> Map.put(:physical_worker_history, history ++ [report])
      end)
      |> State.append_event(event)

    case DayRollover.maybe_rollover(state) do
      {:ok, next_state, :skip} ->
        {:ok, next_state, {:decide, "Worker visit complete: #{summary}"}}

      other ->
        other
    end
  end

  defp reject_worker_event(state, reason) do
    apply_action_rejected(state, Events.action_rejected("physical_worker", reason))
  end

  defp reject_worker_dispatch(state, reason) do
    apply_action_rejected(state, Events.action_rejected("operator", reason))
  end
end
