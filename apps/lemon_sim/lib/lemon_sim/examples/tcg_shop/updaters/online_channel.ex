defmodule LemonSim.Examples.TcgShop.Updaters.OnlineChannel do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_manage_online_channel(%State{} = state, event) do
    platform = get(event.payload, "platform")
    listing_quality = get(event.payload, "listing_quality", "basic")

    with :ok <- ensure_in_progress(state.world),
         {:ok, profile} <- online_channel_profile(platform, listing_quality),
         :ok <- ensure_cash(state.world, get(profile, :setup_cost, 0.0)) do
      day = get(state.world, :day_number, 1)
      setup_cost = get(profile, :setup_cost, 0.0)

      channel =
        profile
        |> Map.put(:platform, platform)
        |> Map.put(:listing_quality, listing_quality)

      entry =
        channel
        |> Map.put(:day, day)
        |> Map.put(:type, "online_channel_update")

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - setup_cost, 2))
          |> Map.put(:online_channel, channel)
          |> Map.update(:online_channel_history, [entry], &(&1 ++ [entry]))
          |> Staffing.consume_staff_hours(online_listing_hours(listing_quality), "online_listing")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "updated online channel to #{platform}/#{listing_quality}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_process_online_orders(%State{} = state, event) do
    quality = get(event.payload, "packing_quality", "standard")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_quality(quality) do
      world = state.world
      day = get(world, :day_number, 1)
      rating = get(world, :online_rating, 4.3)
      channel = get(world, :online_channel, default_online_channel())

      order_count =
        max(
          1,
          trunc(
            (2 + rating + get(world, :reputation, 50) / 20) * online_demand_multiplier(channel)
          )
        )

      packing_cost = order_count * packing_cost(quality)
      marketplace_fee_rate = get(channel, :marketplace_fee_rate, 0.0)

      record = %{
        day: day,
        platform: get(channel, :platform, "local_pickup"),
        listing_quality: get(channel, :listing_quality, "basic"),
        requested_count: order_count,
        fulfilled_count: 0,
        backorder_count: 0,
        revenue: 0.0,
        packing_cost: packing_cost,
        packing_quality: quality,
        marketplace_fee_rate: marketplace_fee_rate,
        lines: []
      }

      {fulfilled_world, revenue, fulfilled_count, backorder_count, lines} =
        fulfill_online_orders(world, order_count)

      complaint_count = complaint_count(quality, fulfilled_count, backorder_count)
      rating_delta = rating_delta(quality) - backorder_count * 0.03 - complaint_count * 0.05

      record =
        Map.merge(record, %{
          fulfilled_count: fulfilled_count,
          backorder_count: backorder_count,
          revenue: revenue,
          cost_of_goods_sold: online_cogs(lines),
          gross_profit: Float.round(revenue - online_cogs(lines), 2),
          sales_tax_collected: Finance.sales_tax_for(fulfilled_world, revenue),
          shipping_label_cost: Finance.shipping_label_cost(fulfilled_world, fulfilled_count),
          marketplace_fee: Finance.marketplace_fee_for(revenue, marketplace_fee_rate),
          lines: lines
        })

      issue =
        if complaint_count > 0 or backorder_count > 0 do
          %{
            day: day,
            source: "online_orders",
            packing_quality: quality,
            complaints: complaint_count,
            backorders: backorder_count,
            note: service_issue_note(complaint_count, backorder_count)
          }
        end

      stockout =
        if backorder_count > 0 do
          %{
            day: day,
            source: "online_orders",
            line_id: "mixed_online_cart",
            lost_units: backorder_count
          }
        end

      next =
        state
        |> State.update_world(fn _world ->
          fulfilled_world
          |> Map.update!(:bank_balance, &Float.round(&1 + revenue - packing_cost, 2))
          |> Finance.apply_sales_tax(revenue, "online_orders", day)
          |> Finance.apply_transaction_costs(revenue, "online_orders", day,
            transaction_count: fulfilled_count,
            shipped_orders: fulfilled_count,
            marketplace_fee_rate: marketplace_fee_rate,
            marketplace_platform: get(channel, :platform, "local_pickup")
          )
          |> Map.update(
            :online_rating,
            rating_delta,
            &Float.round(min(5.0, max(3.0, &1 + rating_delta)), 2)
          )
          |> Map.update(:reputation, 0, &max(0, &1 - min(6, backorder_count + complaint_count)))
          |> Map.update(:online_order_history, [record], &(&1 ++ [record]))
          |> maybe_append(:service_issue_history, issue)
          |> maybe_append(:stockout_history, stockout)
          |> Map.update(:sales_history, [record], &(&1 ++ [record]))
          |> Customers.update_customer_segment("online_buyers", %{
            loyalty_delta: if(backorder_count > 0, do: -2, else: 1),
            satisfaction_delta: rating_delta_to_customer_delta(rating_delta),
            visits_delta: fulfilled_count,
            spend_delta: revenue,
            reason: "online_fulfillment"
          })
          |> Staffing.consume_staff_hours(
            Float.round(0.5 + fulfilled_count * 0.18, 2),
            "online_fulfillment"
          )
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "processed #{order_count} online orders"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp online_channel_profile(platform, listing_quality) do
    with {:ok, platform_profile} <- online_platform_profile(platform),
         {:ok, quality_profile} <- online_listing_profile(listing_quality) do
      {:ok,
       %{
         marketplace_fee_rate: get(platform_profile, :marketplace_fee_rate, 0.0),
         demand_multiplier:
           Float.round(
             get(platform_profile, :demand_multiplier, 1.0) *
               get(quality_profile, :demand_multiplier, 1.0),
             2
           ),
         setup_cost: get(quality_profile, :setup_cost, 0.0)
       }}
    end
  end

  defp online_platform_profile("local_pickup"),
    do: {:ok, %{marketplace_fee_rate: 0.0, demand_multiplier: 0.85}}

  defp online_platform_profile("tcgplayer"),
    do: {:ok, %{marketplace_fee_rate: 0.105, demand_multiplier: 1.3}}

  defp online_platform_profile("ebay"),
    do: {:ok, %{marketplace_fee_rate: 0.132, demand_multiplier: 1.18}}

  defp online_platform_profile(_platform), do: {:error, :invalid_online_platform}

  defp online_listing_profile("basic"), do: {:ok, %{setup_cost: 35.0, demand_multiplier: 1.0}}

  defp online_listing_profile("optimized"),
    do: {:ok, %{setup_cost: 90.0, demand_multiplier: 1.18}}

  defp online_listing_profile("premium"), do: {:ok, %{setup_cost: 160.0, demand_multiplier: 1.35}}
  defp online_listing_profile(_quality), do: {:error, :invalid_listing_quality}

  defp online_listing_hours("premium"), do: 1.4
  defp online_listing_hours("optimized"), do: 1.0
  defp online_listing_hours(_quality), do: 0.6

  defp ensure_quality(quality),
    do:
      if(quality in ["cheap", "standard", "premium"],
        do: :ok,
        else: {:error, :invalid_packing_quality}
      )

  defp packing_cost("premium"), do: 2.25
  defp packing_cost("standard"), do: 1.15
  defp packing_cost(_), do: 0.45

  defp rating_delta("premium"), do: 0.04
  defp rating_delta("standard"), do: 0.01
  defp rating_delta(_), do: -0.08

  defp fulfill_online_orders(world, order_count) do
    catalog = get(world, :catalog, %{})

    candidates =
      world
      |> get(:inventory, %{})
      |> Enum.filter(fn {_id, item} -> get(item, :on_hand, 0) > 0 end)
      |> Enum.sort_by(fn {_id, item} -> -get(item, :price, 0.0) end)

    {updated_world, fulfilled_count, revenue, lines} =
      Enum.reduce_while(candidates, {world, 0, 0.0, []}, fn {line_id, item},
                                                            {acc, filled, rev, line_acc} ->
        remaining = order_count - filled

        if remaining <= 0 do
          {:halt, {acc, filled, rev, line_acc}}
        else
          quantity = min(get(item, :on_hand, 0), remaining)
          price = get(item, :price, 0.0)
          line_revenue = Float.round(quantity * price, 2)
          line_cogs = sealed_cogs(Map.get(catalog, line_id, %{}), quantity)

          line = %{
            line_id: line_id,
            quantity: quantity,
            revenue: line_revenue,
            cost_of_goods_sold: line_cogs,
            gross_profit: Float.round(line_revenue - line_cogs, 2)
          }

          next =
            update_in(acc, [:inventory, line_id, :on_hand], &max((&1 || 0) - quantity, 0))

          {:cont, {next, filled + quantity, rev + line_revenue, line_acc ++ [line]}}
        end
      end)

    {
      updated_world,
      Float.round(revenue, 2),
      fulfilled_count,
      max(0, order_count - fulfilled_count),
      lines
    }
  end

  defp complaint_count("premium", _fulfilled_count, backorder_count), do: div(backorder_count, 4)

  defp complaint_count("standard", fulfilled_count, backorder_count) do
    div(fulfilled_count, 10) + div(backorder_count + 1, 3)
  end

  defp complaint_count(_quality, fulfilled_count, backorder_count) do
    div(fulfilled_count + 3, 4) + div(backorder_count + 1, 2)
  end

  defp service_issue_note(complaints, backorders) do
    cond do
      complaints > 0 and backorders > 0 -> "damaged parcels and unfilled carts hurt trust"
      complaints > 0 -> "packing complaints hurt online trust"
      backorders > 0 -> "online carts exceeded available inventory"
      true -> "no service issue"
    end
  end

  def apply_daily_refunds({world, revenue}, day), do: {apply_daily_refunds(world, day), revenue}

  def apply_daily_refunds(world, day) do
    refunded_issue_keys =
      world
      |> get(:refund_history, [])
      |> Enum.map(&get(&1, :issue_key))
      |> MapSet.new()

    world
    |> get(:service_issue_history, [])
    |> Enum.filter(&(get(&1, :source) == "online_orders" and get(&1, :day, 0) <= day))
    |> Enum.reject(&MapSet.member?(refunded_issue_keys, refund_issue_key(&1)))
    |> Enum.reduce(world, fn issue, acc ->
      case online_refund_entry(acc, issue, day) do
        nil -> acc
        refund -> apply_refund(acc, refund)
      end
    end)
  end

  defp online_refund_entry(world, issue, day) do
    issue_day = get(issue, :day, day)
    order = Enum.find(get(world, :online_order_history, []), &(get(&1, :day) == issue_day))

    if order do
      fulfilled = get(order, :fulfilled_count, 0)
      revenue = get(order, :revenue, 0.0)
      avg_order = if fulfilled > 0, do: revenue / fulfilled, else: 0.0
      complaints = get(issue, :complaints, 0)
      backorders = get(issue, :backorders, 0)

      refund_amount =
        Float.round(
          min(fulfilled, complaints) * avg_order * 0.5 +
            min(max(fulfilled - complaints, 0), backorders) * avg_order * 0.15,
          2
        )

      if refund_amount > 0.0 do
        %{
          day: day,
          issue_day: issue_day,
          issue_key: refund_issue_key(issue),
          source: "online_orders",
          channel: "online",
          refund_amount: refund_amount,
          chargeback: complaints > 0 and get(order, :packing_quality, "standard") == "cheap",
          complaints: complaints,
          backorders: backorders,
          note: get(issue, :note, "online service refund")
        }
      end
    end
  end

  defp apply_refund(world, refund) do
    refund_amount = get(refund, :refund_amount, 0.0)

    world
    |> Map.update!(:bank_balance, &Float.round(&1 - refund_amount, 2))
    |> Map.update(:refund_history, [refund], &(&1 ++ [refund]))
    |> Map.update(
      :online_rating,
      0.0,
      &Float.round(max(3.0, &1 - refund_rating_penalty(refund)), 2)
    )
    |> Map.update(:reputation, 0, &max(0, &1 - refund_reputation_penalty(refund)))
    |> Customers.update_customer_segment("online_buyers", %{
      loyalty_delta: if(get(refund, :chargeback, false), do: -3, else: -1),
      satisfaction_delta: if(get(refund, :chargeback, false), do: -4, else: -2),
      visits_delta: 0,
      spend_delta: -refund_amount,
      reason: if(get(refund, :chargeback, false), do: "chargeback", else: "refund")
    })
  end

  defp refund_issue_key(issue) do
    "#{get(issue, :source)}:#{get(issue, :day)}:#{get(issue, :line_id, "online")}:#{get(issue, :note, "")}"
  end

  defp refund_rating_penalty(refund) do
    if get(refund, :chargeback, false), do: 0.08, else: 0.03
  end

  defp refund_reputation_penalty(refund) do
    if get(refund, :chargeback, false), do: 2, else: 1
  end

  defp online_cogs(lines) do
    lines
    |> Enum.reduce(0.0, fn line, acc -> acc + get(line, :cost_of_goods_sold, 0.0) end)
    |> Float.round(2)
  end

  defp default_online_channel do
    %{
      platform: "local_pickup",
      listing_quality: "basic",
      demand_multiplier: 1.0,
      marketplace_fee_rate: 0.0,
      setup_cost: 0.0
    }
  end

  defp online_demand_multiplier(channel) do
    get(channel, :demand_multiplier, 1.0)
  end

  defp rating_delta_to_customer_delta(delta) when delta >= 0.03, do: 2
  defp rating_delta_to_customer_delta(delta) when delta >= 0.0, do: 1
  defp rating_delta_to_customer_delta(delta) when delta <= -0.1, do: -4
  defp rating_delta_to_customer_delta(_), do: -2
end
