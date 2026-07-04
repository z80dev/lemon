defmodule LemonSim.Examples.VendingBench.DeterministicPhysicalWorker do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.Events

  # Baseline worker policy, not a VendingBench game rule.
  @slot_capacity 6

  def run(world, opts \\ []) do
    instructions = Keyword.get(opts, :instructions, "Restock the machine.")
    storage_inventory = get(get(world, :storage, %{}), :inventory, %{})
    slots = get(get(world, :machine, %{}), :slots, %{})
    catalog = get(world, :catalog, %{})
    cash = get(world, :cash_in_machine, 0.0)

    {stock_events, _remaining} = stock_events(slots, storage_inventory, catalog)

    cash_events =
      if cash > 0 do
        [Events.cash_collected(cash)]
      else
        []
      end

    summary = summary(stock_events, cash)

    events =
      [
        Events.physical_worker_started(instructions),
        Events.machine_inventory_checked(%{
          "slots" => slots,
          "storage" => storage_inventory,
          "cash_in_machine" => cash
        })
      ] ++ stock_events ++ cash_events ++ [Events.physical_worker_finished(summary, [])]

    {:ok,
     %{
       events: events,
       summary: summary,
       tool_calls: tool_calls(stock_events, cash_events),
       turn_count: 1
     }}
  end

  defp stock_events(slots, storage_inventory, catalog) do
    slots
    |> Enum.sort_by(fn {slot_id, _slot} -> slot_id end)
    |> Enum.reduce({[], storage_inventory}, fn {slot_id, slot}, {events, remaining} ->
      item_id =
        get(slot, :item_id) || first_matching_item(remaining, catalog, get(slot, :slot_type))

      cond do
        is_nil(item_id) ->
          {events, remaining}

        Map.get(remaining, item_id, 0) <= 0 ->
          {events, remaining}

        true ->
          current = get(slot, :inventory, 0)
          quantity = min(Map.get(remaining, item_id, 0), max(@slot_capacity - current, 0))

          if quantity > 0 do
            event = Events.machine_stocked(slot_id, item_id, quantity, quantity)
            {events ++ [event], Map.update!(remaining, item_id, &(&1 - quantity))}
          else
            {events, remaining}
          end
      end
    end)
  end

  defp first_matching_item(storage_inventory, catalog, slot_type) do
    storage_inventory
    |> Enum.filter(fn {_item_id, quantity} -> quantity > 0 end)
    |> Enum.sort_by(fn {item_id, _quantity} -> item_id end)
    |> Enum.map(fn {item_id, _quantity} -> item_id end)
    |> Enum.find(fn item_id ->
      catalog
      |> Map.get(item_id, %{})
      |> Map.get(:size_class, "small")
      |> Kernel.==(slot_type || "small")
    end)
  end

  defp summary(stock_events, cash) do
    stocked = length(stock_events)

    cond do
      stocked > 0 and cash > 0 ->
        "Stocked #{stocked} slot(s) and collected machine cash."

      stocked > 0 ->
        "Stocked #{stocked} slot(s)."

      cash > 0 ->
        "Collected machine cash."

      true ->
        "Inspected the machine; no operational changes were needed."
    end
  end

  defp tool_calls(stock_events, cash_events) do
    Enum.map(stock_events, fn event ->
      %{
        tool_name: "stock_products",
        result_text:
          "Stocked #{get(event.payload, :quantity)} units of #{get(event.payload, :item_id)} into #{get(event.payload, :slot_id)}",
        result_details: %{"event" => event},
        is_error: false
      }
    end) ++
      Enum.map(cash_events, fn event ->
        %{
          tool_name: "collect_cash",
          result_text: "Collected $#{get(event.payload, :amount)} from the machine",
          result_details: %{"event" => event},
          is_error: false
        }
      end)
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
