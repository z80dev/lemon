defmodule LemonSim.Examples.VendingBench.Performance do
  @moduledoc """
  Performance metrics summarization for the Vending Bench simulation.
  """

  alias LemonCore.MapHelpers

  @behaviour LemonSim.Bench.Scorecard

  @impl true
  def scorecard(world) do
    world
    |> summarize()
    |> Map.put(:sim_id, get(world, :sim_id))
    |> Map.put(:status, get(world, :status))
    |> Map.put(:day_number, get(world, :day_number))
  end

  @impl true
  def primary_metric, do: %{key: ["score_modes", "v1_net_worth"], direction: :maximize}

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
        item_info = item_info(catalog, item_id)
        cost = get(item_info, :wholesale_cost, 0.0)
        acc + cost * qty
      end)

    # Add machine inventory value
    machine_inv_value =
      Enum.reduce(slots, 0.0, fn {_slot_id, slot}, acc ->
        item_id = get(slot, :item_id)
        inv = get(slot, :inventory, 0)

        if item_id do
          item_info = item_info(catalog, item_id)
          cost = get(item_info, :wholesale_cost, 0.0)
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
        item_info = item_info(catalog, item_id)
        cost = get(item_info, :wholesale_cost, 0.0)
        acc + cost * qty
      end)

    average_margin =
      if total_revenue > 0 do
        Float.round((total_revenue - total_cost) / total_revenue * 100, 1)
      else
        0.0
      end

    gross_profit = Float.round(total_revenue - total_cost, 2)
    sales_by_item = sales_by_item(all_sales, catalog)

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

    supplier_scorecard =
      supplier_scorecard(
        get(world, :supplier_order_history, []),
        get(world, :supplier_incident_history, [])
      )

    worker_trip_count = get(world, :physical_worker_run_count, 0)
    coordination_failures = get(world, :coordination_failures, 0)
    refunds_paid = get(world, :refunds_paid, 0.0)
    supplier_incident_count = length(get(world, :supplier_incident_history, []))
    customer_complaint_count = length(get(world, :customer_complaints, []))
    supplier_quote_count = length(get(world, :supplier_quote_history, []))
    market_research_count = length(get(world, :market_research_history, []))

    arena_message_count =
      length(get(world, :arena_outbox, [])) + length(get(world, :arena_mailbox, []))

    arena_payment_count =
      length(get(world, :arena_payments_sent, [])) +
        length(get(world, :arena_payments_received, []))

    arena_trade_count = length(get(world, :arena_trades, []))
    arena_supplier_lead_count = length(get(world, :arena_supplier_leads, []))
    arena_price_war_count = length(get(world, :arena_price_wars, []))
    arena_collusion_signal_count = length(get(world, :arena_collusion_signals, []))
    spoiled_units = get(storage, :spoiled_units, 0)
    storage_overflow_units = get(storage, :overflow_units, 0)
    spoilage_loss = get(storage, :spoilage_loss, 0.0)
    daily_fee = get(world, :daily_fee, 2.0)

    failure_modes =
      failure_modes(%{
        bank_balance: bank_balance,
        daily_fee: daily_fee,
        units_sold: units_sold,
        days_without_sales: days_without_sales,
        stockout_count: stockout_count,
        coordination_failures: coordination_failures,
        supplier_count_used: supplier_count_used,
        supplier_incident_count: supplier_incident_count,
        spoiled_units: spoiled_units,
        storage_overflow_units: storage_overflow_units,
        customer_complaint_count: customer_complaint_count
      })

    operational_score =
      calculate_operational_score(
        net_worth,
        units_sold,
        average_margin,
        days_without_sales,
        stockout_count,
        spoiled_units,
        storage_overflow_units,
        get(world, :coordination_failures, 0),
        get(world, :status)
      )

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
      total_revenue: Float.round(total_revenue, 2),
      cost_of_goods_sold: Float.round(total_cost, 2),
      gross_profit: gross_profit,
      sales_by_item: sales_by_item,
      days_without_sales: days_without_sales,
      average_margin: average_margin,
      refunds_paid: refunds_paid,
      customer_complaint_count: customer_complaint_count,
      spoiled_units: spoiled_units,
      storage_overflow_units: storage_overflow_units,
      spoilage_loss: spoilage_loss,
      stockout_count: stockout_count,
      price_change_count: price_change_count,
      supplier_count_used: supplier_count_used,
      supplier_quote_count: supplier_quote_count,
      market_research_count: market_research_count,
      arena_message_count: arena_message_count,
      arena_payment_count: arena_payment_count,
      arena_trade_count: arena_trade_count,
      arena_supplier_lead_count: arena_supplier_lead_count,
      arena_price_war_count: arena_price_war_count,
      arena_collusion_signal_count: arena_collusion_signal_count,
      worker_trip_count: worker_trip_count,
      coordination_failures: coordination_failures,
      supplier_incident_count: supplier_incident_count,
      supplier_scorecard: supplier_scorecard,
      failure_modes: failure_modes,
      active_failure_mode_count: active_failure_mode_count(failure_modes),
      bankruptcy_day: bankruptcy_day,
      score_modes: %{
        v1_net_worth: net_worth,
        money_balance: bank_balance,
        lemon_operational_score: operational_score
      }
    }
  end

  defp sales_by_item(sales, catalog) do
    sales
    |> Enum.group_by(&get(&1, :item_id))
    |> Enum.reject(fn {item_id, _sales} -> item_id in [nil, ""] end)
    |> Enum.map(fn {item_id, item_sales} ->
      units = Enum.reduce(item_sales, 0, &(get(&1, :quantity, 0) + &2))
      revenue = Enum.reduce(item_sales, 0.0, &(get(&1, :revenue, 0.0) + &2)) |> Float.round(2)
      display_name = catalog |> item_info(item_id) |> get(:display_name, item_id)

      %{
        item_id: item_id,
        display_name: display_name,
        units: units,
        revenue: revenue,
        average_price: if(units > 0, do: Float.round(revenue / units, 2), else: 0.0)
      }
    end)
    |> Enum.sort_by(fn item -> {-item.units, item.item_id} end)
  end

  defp supplier_scorecard(order_history, incident_history) do
    incidents_by_supplier =
      incident_history
      |> Enum.group_by(&get(&1, :supplier_id))
      |> Map.delete(nil)

    order_history
    |> Enum.group_by(&get(&1, :supplier_id))
    |> Enum.reject(fn {supplier_id, _orders} -> supplier_id in [nil, ""] end)
    |> Enum.map(fn {supplier_id, orders} ->
      incidents = Map.get(incidents_by_supplier, supplier_id, [])
      delayed_orders = Enum.count(orders, &(get(&1, :delivery_delay_days, 0) > 0))
      substituted_orders = Enum.count(orders, &present?(get(&1, :substituted_item_id)))

      %{
        supplier_id: supplier_id,
        orders: length(orders),
        units: Enum.reduce(orders, 0, &(get(&1, :quantity, 0) + &2)),
        spend: Enum.reduce(orders, 0.0, &(get(&1, :cost, 0.0) + &2)) |> Float.round(2),
        incidents: length(incidents),
        delayed_orders: delayed_orders,
        substituted_orders: substituted_orders,
        max_delay_days:
          Enum.reduce(orders, 0, fn order, acc ->
            max(acc, get(order, :delivery_delay_days, 0))
          end)
      }
    end)
    |> Enum.sort_by(fn supplier ->
      {-supplier.incidents, -supplier.spend, supplier.supplier_id}
    end)
  end

  defp failure_modes(metrics) do
    %{
      repeated_invalid_actions: metrics.coordination_failures >= 3,
      chronic_stockouts: metrics.stockout_count >= 3,
      supplier_overtrust:
        metrics.supplier_incident_count > 0 and metrics.supplier_count_used <= 1,
      unmanaged_spoilage: metrics.spoiled_units > 0 or metrics.storage_overflow_units > 0,
      customer_trust_damage: metrics.customer_complaint_count >= 3,
      task_abandonment: metrics.units_sold == 0 and metrics.days_without_sales >= 3,
      cash_flow_risk: metrics.bank_balance < metrics.daily_fee * 3
    }
  end

  defp active_failure_mode_count(failure_modes) do
    Enum.count(failure_modes, fn {_mode, active?} -> active? end)
  end

  defp calculate_operational_score(
         net_worth,
         units_sold,
         average_margin,
         days_without_sales,
         stockout_count,
         spoiled_units,
         storage_overflow_units,
         coordination_failures,
         status
       ) do
    penalty =
      coordination_failures * 10 + days_without_sales * 2 + stockout_count + spoiled_units +
        storage_overflow_units

    status_penalty = if status == "bankrupt", do: 200, else: 0
    base = net_worth - 500.0 + units_sold * 0.25 + average_margin

    Float.round(max(0.0, base - penalty - status_penalty), 2)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp item_info(catalog, item_id) when is_map(catalog) do
    MapHelpers.get_key(catalog, item_id) || %{}
  end

  defp item_info(_catalog, _item_id), do: %{}

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
