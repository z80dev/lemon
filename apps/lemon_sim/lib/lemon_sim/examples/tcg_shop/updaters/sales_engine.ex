defmodule LemonSim.Examples.TcgShop.Updaters.SalesEngine do
  @moduledoc false

  alias LemonSim.Examples.TcgShop.Updaters.Consignment
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Grading
  alias LemonSim.Examples.TcgShop.Updaters.Market
  alias LemonSim.Examples.TcgShop.Updaters.Preorders
  alias LemonSim.Examples.TcgShop.Updaters.Promotions
  alias LemonSim.Examples.TcgShop.Updaters.Purchasing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_organic_sales(world, pulse) do
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

        available_for_walk_in =
          max(0, on_hand - Preorders.pending_preorder_units_for_line(world, line_id))

        price = get(item, :price, get(line, :suggested_price, 0.0))
        franchise = get(line, :franchise, "")
        segment_id = Customers.customer_segment_for_franchise(franchise)
        demand_boost = if franchise == buzz_franchise, do: buzz_multiplier, else: 1.0
        promotion = Promotions.active_promotion_for(world, franchise, day)
        promotion_boost = Promotions.promotion_multiplier(promotion)
        price_drag = max(0.25, get(line, :market_price, 1.0) / max(price, 1.0))

        demand =
          get(line, :velocity, 1.0) * demand_boost * promotion_boost * price_drag *
            (0.65 + reputation / 100) *
            Customers.customer_demand_multiplier(world, segment_id) *
            Market.competitive_demand_multiplier(world)

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
                sales_tax_collected: Finance.sales_tax_for(world, sale_value),
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
    {world, pack_revenue, pack_sales} = Purchasing.apply_pack_sales(world, pulse)
    {world, singles_revenue, singles_sales} = Purchasing.apply_singles_sales(world, pulse)

    {world, consignment_revenue, consignment_sales} =
      Consignment.apply_consignment_sales(world, pulse)

    {world, graded_revenue, graded_sales} = Grading.apply_graded_sales(world, pulse)

    revenue =
      Float.round(
        sealed_revenue + pack_revenue + singles_revenue + consignment_revenue + graded_revenue,
        2
      )

    store_credit_redeemed = Finance.store_credit_redemption_for(world, revenue)
    payment_revenue = Float.round(max(0.0, revenue - store_credit_redeemed), 2)
    reputation_penalty = stockout_reputation_penalty(stockouts)

    world =
      world
      |> Finance.apply_local_tender(payment_revenue, "daily_sales", day)
      |> Finance.apply_local_sales_tax(revenue, "daily_sales", day)
      |> Finance.apply_local_transaction_costs(payment_revenue, "daily_sales", day,
        transaction_count:
          estimated_transaction_count(sales ++ singles_sales ++ consignment_sales ++ graded_sales)
      )
      |> Finance.apply_store_credit_redemption(store_credit_redeemed, "daily_sales", day)
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
      |> Customers.apply_customer_sales(
        sales ++ pack_sales ++ singles_sales ++ consignment_sales ++ graded_sales
      )
      |> Customers.apply_customer_stockouts(stockouts)

    {world, Float.round(revenue, 2)}
  end

  defp estimated_transaction_count(sales) do
    Enum.reduce(sales, 0, fn sale, acc ->
      acc + max(1, div(get(sale, :quantity, 1) + 1, 2))
    end)
  end

  defp stockout_reputation_penalty(stockouts) do
    stockouts
    |> Enum.reduce(0, fn stockout, acc -> acc + get(stockout, :lost_units, 0) end)
    |> then(&min(5, div(&1 + 1, 2)))
  end
end
