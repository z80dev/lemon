defmodule LemonSim.Examples.TcgShop.Updaters.Hosting do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Preorders
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_host_event(%State{} = state, event) do
    game = get(event.payload, "game")
    prize_budget = as_float(get(event.payload, "prize_budget", 0.0))
    entry_fee = as_float(get(event.payload, "entry_fee", 0.0))
    sanctioned = get(event.payload, "sanctioned", true)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(game) do
      world = state.world
      day = get(world, :day_number, 1)
      pulse = List.last(get(world, :market_pulses, [])) || %{}
      play_space = get(world, :play_space, %{})
      seats = max(4, as_int(get(play_space, :seats, 32)))
      sanction_fee = if sanctioned, do: as_float(get(play_space, :sanction_fee, 6.0)), else: 0.0

      buzz =
        if get(pulse, :featured_franchise) == game,
          do: get(pulse, :buzz_multiplier, 1.0),
          else: 1.0

      requested_attendance =
        max(4, trunc((8 + get(world, :reputation, 50) / 8 + prize_budget / 35) * buzz))

      no_shows = event_no_shows(world, game, day, requested_attendance)
      attendance_demand = max(0, requested_attendance - no_shows)
      attendance = min(seats, attendance_demand)
      turn_aways = max(0, attendance_demand - seats)
      event_hours = Float.round(3.0 + attendance / 18, 2)

      judge_cost =
        Float.round(event_hours * as_float(get(play_space, :judge_hourly_wage, 20.0)), 2)

      event_operating_cost = Float.round(judge_cost + sanction_fee, 2)
      entry_revenue = Float.round(attendance * entry_fee, 2)
      attach_sales = Float.round(attendance * (7.5 + min(prize_budget / 30, 20)), 2)
      reputation_gain = min(8, max(1, trunc(attendance / 5)))
      attach_units = max(1, div(attendance, 8))
      prize_support = prize_support_for(world, game, prize_budget)
      prize_world = apply_prize_support_lines(world, get(prize_support, :lines, []))
      attach_cogs = matching_inventory_cogs(prize_world, game, attach_units)

      event_cogs =
        Float.round(
          get(prize_support, :inventory_cost, 0.0) +
            get(prize_support, :store_credit_issued, 0.0) + attach_cogs,
          2
        )

      event_revenue = Float.round(entry_revenue + attach_sales, 2)

      event_record =
        %{
          day: day,
          game: game,
          sanctioned: sanctioned,
          seat_capacity: seats,
          requested_attendance: requested_attendance,
          no_shows: no_shows,
          turn_aways: turn_aways,
          attendance: attendance,
          capacity_utilization_pct: Float.round(attendance / seats * 100, 2),
          entry_revenue: entry_revenue,
          attach_sales: attach_sales,
          revenue: event_revenue,
          sanction_fee: sanction_fee,
          judge_cost: judge_cost,
          operating_cost: event_operating_cost,
          cost_of_goods_sold: event_cogs,
          gross_profit: Float.round(event_revenue - event_cogs, 2),
          sales_tax_collected: Finance.sales_tax_for(world, attach_sales),
          prize_budget: prize_budget
        }
        |> Map.merge(prize_support_record(prize_support))

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - event_operating_cost, 2))
          |> Finance.apply_local_tender(entry_revenue + attach_sales, "store_event", day)
          |> Finance.apply_local_sales_tax(attach_sales, "store_event", day)
          |> Finance.apply_local_transaction_costs(
            entry_revenue + attach_sales,
            "store_event",
            day,
            transaction_count: attendance
          )
          |> apply_prize_support_lines(get(prize_support, :lines, []))
          |> Finance.apply_store_credit_issue(
            get(prize_support, :store_credit_issued, 0.0),
            "event_prize_support",
            day
          )
          |> reduce_matching_inventory(game, attach_units)
          |> Map.update(:reputation, reputation_gain, &min(100, &1 + reputation_gain))
          |> Map.update(:tournament_history, [event_record], &(&1 ++ [event_record]))
          |> Map.update(:sales_history, [event_record], &(&1 ++ [event_record]))
          |> Customers.update_customer_segment(Customers.customer_segment_for_franchise(game), %{
            loyalty_delta: min(5, reputation_gain),
            satisfaction_delta: min(6, reputation_gain + 1),
            visits_delta: attendance,
            spend_delta: entry_revenue + attach_sales,
            reason: "store_event"
          })
          |> Staffing.consume_staff_hours(event_hours, "store_event")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "hosted #{game} event with #{attendance} players"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp event_no_shows(world, game, day, requested_attendance) do
    seed = get(world, :seed, 1)
    base = rem(seed + day + String.length(game), 4)

    min(max(0, requested_attendance - 4), base)
  end

  defp prize_support_for(world, game, advertised_value) do
    advertised_value = Float.round(max(0.0, advertised_value), 2)

    {lines, inventory_value, inventory_cost} =
      world
      |> prize_support_candidates(game)
      |> Enum.reduce_while({[], 0.0, 0.0}, fn candidate, {lines, value, cost} ->
        if value >= advertised_value do
          {:halt, {lines, value, cost}}
        else
          needed = max(0.0, advertised_value - value)
          unit_value = get(candidate, :unit_value, 0.0)
          available = get(candidate, :available, 0)
          quantity = min(available, max(1, ceil(needed / max(unit_value, 0.01))))

          line = %{
            line_id: get(candidate, :line_id),
            quantity: quantity,
            unit_value: unit_value,
            unit_cost: get(candidate, :unit_cost, 0.0),
            value: Float.round(quantity * unit_value, 2),
            cost: Float.round(quantity * get(candidate, :unit_cost, 0.0), 2)
          }

          {:cont,
           {
             lines ++ [line],
             Float.round(value + get(line, :value, 0.0), 2),
             Float.round(cost + get(line, :cost, 0.0), 2)
           }}
        end
      end)

    store_credit_issued = Float.round(max(0.0, advertised_value - inventory_value), 2)

    %{
      advertised_value: advertised_value,
      inventory_value: Float.round(inventory_value, 2),
      inventory_cost: Float.round(inventory_cost, 2),
      store_credit_issued: store_credit_issued,
      fulfilled_value: Float.round(inventory_value + store_credit_issued, 2),
      lines: lines
    }
  end

  defp prize_support_candidates(world, game) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.flat_map(fn {line_id, item} ->
      line = Map.get(catalog, line_id, %{})
      franchise = get(line, :franchise, "")
      category = get(line, :category, "")

      available =
        max(0, get(item, :on_hand, 0) - Preorders.pending_preorder_units_for_line(world, line_id))

      if available > 0 and franchise in [game, "Accessories"] do
        [
          %{
            line_id: line_id,
            franchise: franchise,
            category: category,
            available: available,
            unit_value:
              get(item, :price, get(line, :suggested_price, get(line, :market_price, 0.0))),
            unit_cost: get(line, :unit_cost, 0.0)
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(fn candidate ->
      {
        prize_support_priority(candidate, game),
        -get(candidate, :unit_value, 0.0)
      }
    end)
  end

  defp prize_support_priority(candidate, game) do
    cond do
      get(candidate, :franchise) == game and get(candidate, :category) == "sealed" -> 0
      get(candidate, :franchise) == "Accessories" -> 1
      true -> 2
    end
  end

  defp prize_support_record(prize_support) do
    %{
      prize_inventory_value: get(prize_support, :inventory_value, 0.0),
      prize_inventory_cost: get(prize_support, :inventory_cost, 0.0),
      prize_store_credit_issued: get(prize_support, :store_credit_issued, 0.0),
      prize_fulfilled_value: get(prize_support, :fulfilled_value, 0.0),
      prize_support_lines: get(prize_support, :lines, [])
    }
  end

  defp apply_prize_support_lines(world, lines) do
    Enum.reduce(lines, world, fn line, acc ->
      line_id = get(line, :line_id)
      quantity = get(line, :quantity, 0)
      update_in(acc, [:inventory, line_id, :on_hand], &max((&1 || 0) - quantity, 0))
    end)
  end

  defp reduce_matching_inventory(world, game, units) do
    catalog = get(world, :catalog, %{})

    ids =
      world
      |> get(:inventory, %{})
      |> Enum.filter(fn {id, item} ->
        line = Map.get(catalog, id, %{})
        get(line, :franchise, "") in [game, "Accessories"] and get(item, :on_hand, 0) > 0
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(Enum.take(ids, units), world, fn id, acc ->
      update_in(acc, [:inventory, id, :on_hand], &max((&1 || 0) - 1, 0))
    end)
  end

  defp matching_inventory_cogs(world, game, units) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.filter(fn {id, item} ->
      line = Map.get(catalog, id, %{})
      get(line, :franchise, "") in [game, "Accessories"] and get(item, :on_hand, 0) > 0
    end)
    |> Enum.map(fn {id, _item} -> Map.get(catalog, id, %{}) end)
    |> Enum.take(units)
    |> Enum.reduce(0.0, fn line, acc -> acc + get(line, :unit_cost, 0.0) end)
    |> Float.round(2)
  end
end
