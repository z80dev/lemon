defmodule LemonSim.Examples.VendingBench.Performance do
  @moduledoc """
  Performance metrics summarization for the Vending Bench simulation.
  """

  @spec summarize(map()) :: map()
  def summarize(world) do
    bank_balance = get(world, :bank_balance, 0.0)
    cash_in_machine = get(world, :cash_in_machine, 0.0)
    storage = get(world, :storage, %{})
    storage_inv = get(storage, :inventory, %{})
    catalog = get(world, :catalog, %{})
    sales_history = get(world, :sales_history, [])
    all_sales = sales_history
    machine = get(world, :machine, %{})
    slots = get(machine, :slots, %{})
    day_number = get(world, :day_number, 1)

    # Inventory value at wholesale
    inventory_value =
      Enum.reduce(storage_inv, 0.0, fn {item_id, qty}, acc ->
        item_info = Map.get(catalog, item_id, %{})
        cost = Map.get(item_info, :wholesale_cost, 0.0)
        acc + cost * qty
      end)

    # Add machine inventory value
    machine_inv_value =
      Enum.reduce(slots, 0.0, fn {_slot_id, slot}, acc ->
        item_id = get(slot, :item_id)
        inv = get(slot, :inventory, 0)

        if item_id do
          item_info = Map.get(catalog, item_id, %{})
          cost = Map.get(item_info, :wholesale_cost, 0.0)
          acc + cost * inv
        else
          acc
        end
      end)

    total_inventory_value = Float.round(inventory_value + machine_inv_value, 2)
    net_worth = Float.round(bank_balance + cash_in_machine + total_inventory_value, 2)

    # Units sold
    units_sold =
      Enum.reduce(all_sales, 0, fn sale, acc ->
        acc + get(sale, :quantity, 0)
      end)

    # Revenue and cost for margin calculation
    total_revenue =
      Enum.reduce(all_sales, 0.0, fn sale, acc ->
        acc + get(sale, :revenue, 0.0)
      end)

    total_cost =
      Enum.reduce(all_sales, 0.0, fn sale, acc ->
        item_id = get(sale, :item_id)
        qty = get(sale, :quantity, 0)
        item_info = Map.get(catalog, item_id, %{})
        cost = Map.get(item_info, :wholesale_cost, 0.0)
        acc + cost * qty
      end)

    average_margin =
      if total_revenue > 0 do
        Float.round((total_revenue - total_cost) / total_revenue * 100, 1)
      else
        0.0
      end

    # Days without any sales
    days_with_sales =
      all_sales
      |> Enum.map(fn sale -> get(sale, :day) end)
      |> Enum.filter(&(&1 != nil))
      |> MapSet.new()

    days_without_sales = max(0, day_number - 1 - MapSet.size(days_with_sales))

    # Stockout count (slots that ran out of inventory during a sale day)
    stockout_count =
      Enum.count(slots, fn {_slot_id, slot} ->
        get(slot, :item_id) != nil and get(slot, :inventory, 0) == 0
      end)

    # Price change count from events
    price_change_count = get(world, :price_change_count, 0)

    # Suppliers used
    supplier_count_used =
      get(world, :supplier_order_history, [])
      |> Enum.map(fn entry -> get(entry, :supplier_id) end)
      |> Enum.filter(&(&1 != nil))
      |> MapSet.new()
      |> MapSet.size()

    worker_trip_count = get(world, :physical_worker_run_count, 0)
    coordination_failures = get(world, :coordination_failures, 0)
    refunds_paid = 0.0

    bankruptcy_day =
      if get(world, :status) == "bankrupt" do
        get(world, :day_number)
      else
        nil
      end

    %{
      net_worth: net_worth,
      cash_on_hand: bank_balance,
      cash_in_machine: cash_in_machine,
      inventory_value_wholesale: total_inventory_value,
      units_sold: units_sold,
      days_without_sales: days_without_sales,
      average_margin: average_margin,
      refunds_paid: refunds_paid,
      stockout_count: stockout_count,
      price_change_count: price_change_count,
      supplier_count_used: supplier_count_used,
      worker_trip_count: worker_trip_count,
      coordination_failures: coordination_failures,
      bankruptcy_day: bankruptcy_day
    }
  end

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
