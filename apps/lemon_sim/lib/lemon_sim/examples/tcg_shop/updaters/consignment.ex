defmodule LemonSim.Examples.TcgShop.Updaters.Consignment do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_take_consignment(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    card_count = as_int(get(event.payload, "card_count", 0))
    estimated_value = as_float(get(event.payload, "estimated_value", 0.0))
    commission_pct = as_float(get(event.payload, "commission_pct", 15.0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_positive(card_count),
         :ok <- ensure_minimum(estimated_value, 25.0),
         :ok <- ensure_commission_pct(commission_pct) do
      day = get(state.world, :day_number, 1)

      lot = %{
        id: consignment_lot_id(state.world, day, franchise),
        day: day,
        franchise: franchise,
        card_count: card_count,
        cards_remaining: card_count,
        estimated_value: Float.round(estimated_value, 2),
        value_remaining: Float.round(estimated_value, 2),
        commission_pct: commission_pct,
        status: "open"
      }

      entry = Map.merge(lot, %{type: "intake"})

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update(:consignment_lots, [lot], &(&1 ++ [lot]))
          |> Map.update(:consignment_history, [entry], &(&1 ++ [entry]))
          |> Customers.update_customer_segment("collectors", %{
            loyalty_delta: 2,
            satisfaction_delta: 2,
            visits_delta: 0,
            spend_delta: 0.0,
            reason: "consignment_intake"
          })
          |> Staffing.consume_staff_hours(
            Float.round(0.6 + card_count * 0.03, 2),
            "consignment_intake"
          )
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "accepted #{card_count} #{franchise} consignment cards"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_commission_pct(commission_pct) do
    if commission_pct >= 5 and commission_pct <= 30,
      do: :ok,
      else: {:error, :invalid_commission_pct}
  end

  defp consignment_lot_id(world, day, franchise) do
    next_number = length(get(world, :consignment_history, [])) + 1
    slug = String.replace(franchise, ~r/[^A-Za-z0-9]+/, "_")
    "consign_#{day}_#{slug}_#{next_number}"
  end

  def apply_due_consignment_payouts(world, day, status) do
    payable = Float.round(get(world, :consignment_payable, 0.0), 2)

    if payable > 0.0 and consignment_payout_due?(day, status) and
         get(world, :bank_balance, 0.0) >= payable do
      entry = %{
        day: day,
        amount_paid: payable,
        type: "paid",
        status: "paid"
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - payable, 2))
      |> Map.put(:consignment_payable, 0.0)
      |> Map.update(:consignment_payout_history, [entry], &(&1 ++ [entry]))
      |> Map.update(:consignment_history, [entry], &(&1 ++ [entry]))
    else
      world
    end
  end

  defp consignment_payout_due?(day, "complete"), do: day >= 1
  defp consignment_payout_due?(day, _status), do: rem(day, 3) == 0

  def apply_consignment_sales(world, pulse) do
    lots = get(world, :consignment_lots, [])

    case next_consignment_lot(lots, pulse) do
      nil ->
        {world, 0.0, []}

      lot ->
        reputation = get(world, :reputation, 50)
        day = get(pulse, :day, get(world, :day_number, 1))
        cards_remaining = get(lot, :cards_remaining, 0)
        value_remaining = get(lot, :value_remaining, 0.0)
        value_per_card = value_remaining / max(cards_remaining, 1)
        buzz = consignment_buzz_multiplier(lot, pulse)
        cards_sold = min(cards_remaining, max(1, trunc((1 + reputation / 35) * buzz)))
        market_value = Float.round(value_per_card * cards_sold, 2)
        revenue = Float.round(market_value * 0.96, 2)
        commission_pct = get(lot, :commission_pct, 15.0)
        commission = Float.round(revenue * commission_pct / 100, 2)
        payout = Float.round(revenue - commission, 2)

        sale = %{
          day: day,
          channel: "consignment_case",
          consignment_lot_id: get(lot, :id),
          franchise: get(lot, :franchise),
          segment_id: "collectors",
          quantity: cards_sold,
          revenue: revenue,
          consignor_payout: payout,
          commission_revenue: commission,
          commission_pct: commission_pct,
          cost_of_goods_sold: payout,
          gross_profit: commission,
          sales_tax_collected: Finance.sales_tax_for(world, revenue),
          market_value_removed: market_value
        }

        entry = Map.merge(sale, %{type: "sale"})

        next =
          world
          |> Map.put(
            :consignment_lots,
            update_consignment_lots(lots, lot, cards_sold, market_value)
          )
          |> Map.update(:consignment_payable, payout, &Float.round(&1 + payout, 2))
          |> Map.update(:consignment_history, [entry], &(&1 ++ [entry]))

        {next, revenue, [sale]}
    end
  end

  defp next_consignment_lot(lots, pulse) do
    lots
    |> Enum.filter(&(get(&1, :cards_remaining, 0) > 0))
    |> Enum.sort_by(fn lot ->
      {
        if(get(lot, :franchise) == get(pulse, :featured_franchise), do: 0, else: 1),
        get(lot, :day, 0)
      }
    end)
    |> List.first()
  end

  defp consignment_buzz_multiplier(lot, pulse) do
    if get(lot, :franchise) == get(pulse, :featured_franchise) do
      min(1.8, get(pulse, :buzz_multiplier, 1.0))
    else
      1.0
    end
  end

  defp update_consignment_lots(lots, sold_lot, cards_sold, market_value) do
    Enum.map(lots, fn lot ->
      if get(lot, :id) == get(sold_lot, :id) do
        remaining = max(0, get(lot, :cards_remaining, 0) - cards_sold)

        lot
        |> Map.put(:cards_remaining, remaining)
        |> Map.update(:value_remaining, 0.0, &Float.round(max(0.0, &1 - market_value), 2))
        |> Map.put(:status, if(remaining > 0, do: "open", else: "sold"))
      else
        lot
      end
    end)
  end
end
