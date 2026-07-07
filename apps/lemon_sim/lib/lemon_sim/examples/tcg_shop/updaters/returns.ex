defmodule LemonSim.Examples.TcgShop.Updaters.Returns do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Catalog
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing
  alias LemonSim.Examples.TcgShop.Updaters.Suppliers

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_process_customer_return(%State{} = state, event) do
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
          |> Customers.update_customer_segment(
            Customers.customer_segment_for_franchise(get(line, :franchise)),
            %{
              loyalty_delta: if(resolution == "store_credit", do: 1, else: 0),
              satisfaction_delta: return_satisfaction_delta(condition),
              visits_delta: 0,
              spend_delta: -refund_amount,
              reason: "customer_return"
            }
          )
          |> Staffing.consume_staff_hours(
            Float.round(0.25 + quantity * 0.06, 2),
            "customer_return"
          )
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "processed #{quantity} #{line_id} customer returns"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

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
    Finance.apply_store_credit_issue(world, refund_amount, "customer_return", day)
  end

  defp apply_return_resolution(world, "cash_refund", refund_amount, _day) do
    Map.update!(world, :bank_balance, &Float.round(&1 - refund_amount, 2))
  end

  defp restock_returned_inventory(world, _line_id, restocked_units) when restocked_units <= 0,
    do: world

  defp restock_returned_inventory(world, line_id, restocked_units) do
    update_in(world, [:inventory, line_id], &Suppliers.receive_inventory(&1, restocked_units))
  end
end
