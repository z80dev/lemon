defmodule LemonSim.Examples.TcgShop.Updaters.Preorders do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Catalog
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_take_preorders(%State{} = state, event) do
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
          |> Finance.apply_local_tender(deposit_collected, "preorder_deposit", day)
          |> Finance.apply_local_transaction_costs(deposit_collected, "preorder_deposit", day,
            transaction_count: 1
          )
          |> Map.update(:pending_preorders, [preorder], &(&1 ++ [preorder]))
          |> Map.update(:preorder_history, [preorder], &(&1 ++ [preorder]))
          |> Customers.update_customer_segment(
            Customers.customer_segment_for_franchise(line.franchise),
            %{
              loyalty_delta: 1,
              satisfaction_delta: 1,
              visits_delta: 0,
              spend_delta: deposit_collected,
              reason: "preorder_deposit"
            }
          )
          |> Staffing.consume_staff_hours(
            Float.round(0.35 + quantity * 0.04, 2),
            "preorder_intake"
          )
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "reserved #{quantity} #{line_id} for day #{release_day} with $#{deposit_collected} deposits"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_take_special_order(%State{} = state, event) do
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
      segment_id = Customers.customer_segment_for_franchise(line.franchise)

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
          |> Finance.apply_local_tender(deposit_collected, "special_order_deposit", day)
          |> Finance.apply_local_transaction_costs(
            deposit_collected,
            "special_order_deposit",
            day,
            transaction_count: 1
          )
          |> Map.update(
            :special_order_liability,
            deposit_collected,
            &Float.round(&1 + deposit_collected, 2)
          )
          |> Map.update(:pending_special_orders, [order], &(&1 ++ [order]))
          |> Map.update(:special_order_history, [order], &(&1 ++ [order]))
          |> Customers.update_customer_segment(segment_id, %{
            loyalty_delta: 1,
            satisfaction_delta: 1,
            visits_delta: 0,
            spend_delta: deposit_collected,
            reason: "special_order_deposit"
          })
          |> Staffing.consume_staff_hours(
            Float.round(0.25 + quantity * 0.03, 2),
            "special_order_intake"
          )
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "took special order #{order.id} for #{quantity} #{line_id} with $#{deposit_collected} deposit"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_due_preorders(world, day) do
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
          sales_tax_collected: Finance.sales_tax_for(acc, taxable_revenue),
          channel: "preorder",
          status: if(shorted > 0, do: "partial_backorder", else: "fulfilled")
        }

        stockout =
          if new_shortfall_units > 0 do
            %{
              day: day,
              source: "preorder_fulfillment",
              line_id: line_id,
              segment_id: Customers.customer_segment_for_franchise(get(preorder, :franchise)),
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
          |> Finance.apply_local_tender(balance_revenue, "preorder_balance", day)
          |> Finance.apply_local_sales_tax(taxable_revenue, "preorder_fulfillment", day)
          |> Finance.apply_local_transaction_costs(balance_revenue, "preorder_balance", day,
            transaction_count: fulfilled
          )
          |> Map.update(:preorder_fulfillment_history, [fulfillment], &(&1 ++ [fulfillment]))
          |> maybe_append(:stockout_history, stockout)
          |> maybe_append(:service_issue_history, issue)
          |> Map.update(:sales_history, [fulfillment], &(&1 ++ [fulfillment]))
          |> Customers.update_customer_segment(
            Customers.customer_segment_for_franchise(get(preorder, :franchise)),
            %{
              loyalty_delta:
                if(new_shortfall_units > 0, do: -min(4, new_shortfall_units), else: 2),
              satisfaction_delta:
                if(new_shortfall_units > 0, do: -min(7, new_shortfall_units * 2), else: 2),
              visits_delta: fulfilled,
              spend_delta:
                Float.round(
                  get(fulfillment, :deposit_applied, 0.0) +
                    get(fulfillment, :balance_revenue, 0.0),
                  2
                ),
              reason:
                if(new_shortfall_units > 0,
                  do: "preorder_shortfall",
                  else: "preorder_fulfillment"
                )
            }
          )
          |> Map.update(
            :reputation,
            0,
            &max(0, &1 - if(new_shortfall_units > 0, do: min(4, new_shortfall_units), else: 0))
          )

        {next, pending_acc ++ carried_preorders}
      end)

    Map.put(updated_world, :pending_preorders, carried)
  end

  def apply_due_special_orders(world, day) do
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
          get(
            order,
            :customer_segment_id,
            Customers.customer_segment_for_franchise(get(order, :franchise))
          )

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
          sales_tax_collected: Finance.sales_tax_for(acc, taxable_revenue),
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
          |> Finance.apply_local_tender(balance_revenue, "special_order_balance", day)
          |> Finance.apply_local_sales_tax(taxable_revenue, "special_order_fulfillment", day)
          |> Finance.apply_local_transaction_costs(balance_revenue, "special_order_balance", day,
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
          |> Customers.update_customer_segment(segment_id, %{
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

  defp ensure_preorder_line(line) do
    if get(line, :category) == "sealed",
      do: :ok,
      else: {:error, :preorders_require_sealed_product}
  end

  defp ensure_deposit_pct(deposit_pct) do
    if deposit_pct >= 10 and deposit_pct <= 100,
      do: :ok,
      else: {:error, :invalid_deposit_pct}
  end

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

  defp preorder_cogs(world, line_id, quantity) do
    world
    |> get(:catalog, %{})
    |> Map.get(line_id, %{})
    |> sealed_cogs(quantity)
  end

  def pending_preorder_units_for_line(world, line_id) do
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
end
