defmodule LemonSim.Examples.TcgShop.Updaters.DayRollover do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Events
  alias LemonSim.Examples.TcgShop.Updaters.Consignment
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Grading
  alias LemonSim.Examples.TcgShop.Updaters.InventoryAging
  alias LemonSim.Examples.TcgShop.Updaters.LossPrevention
  alias LemonSim.Examples.TcgShop.Updaters.Market
  alias LemonSim.Examples.TcgShop.Updaters.Memberships
  alias LemonSim.Examples.TcgShop.Updaters.OnlineChannel
  alias LemonSim.Examples.TcgShop.Updaters.Preorders
  alias LemonSim.Examples.TcgShop.Updaters.Promotions
  alias LemonSim.Examples.TcgShop.Updaters.SalesEngine
  alias LemonSim.Examples.TcgShop.Updaters.Staffing
  alias LemonSim.Examples.TcgShop.Updaters.Suppliers

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_wait_next_day(%State{} = state, event) do
    case ensure_in_progress(state.world) do
      :ok ->
        world = state.world
        current_day = get(world, :day_number, 1)
        next_day = current_day + 1
        max_days = get(world, :max_days, 14)
        seed = get(world, :seed, 1)
        calendar = get(world, :release_calendar, [])
        pulse = LemonSim.Examples.TcgShop.market_pulse(next_day, seed, calendar)

        {world, delivery_sales} =
          world
          |> Suppliers.apply_due_deliveries(next_day)
          |> Grading.apply_due_grading(next_day)
          |> Market.apply_market_movement(next_day, pulse)
          |> Preorders.apply_due_preorders(next_day)
          |> Preorders.apply_due_special_orders(next_day)
          |> SalesEngine.apply_organic_sales(pulse)
          |> LossPrevention.apply_daily_shrinkage(next_day)
          |> OnlineChannel.apply_daily_refunds(next_day)
          |> InventoryAging.apply_inventory_aging_and_markdowns(next_day)
          |> Finance.apply_cash_reconciliation(next_day)

        status =
          cond do
            get(world, :bank_balance, 0.0) < -500.0 -> "bankrupt"
            next_day > max_days -> "complete"
            true -> "in_progress"
          end

        next_world =
          world
          |> Map.put(:day_number, min(next_day, max_days))
          |> Map.put(:market_pulses, get(world, :market_pulses, []) ++ [pulse])
          |> Map.put(:customer_queue, Customers.customer_queue_for(world, pulse))
          |> Market.apply_competitor_reaction(next_day, pulse)
          |> Promotions.expire_promotions(next_day)
          |> Map.put(
            :competitor_snapshot,
            LemonSim.Examples.TcgShop.competitor_snapshot(next_day, seed)
          )
          |> Finance.apply_daily_overhead(current_day)
          |> Finance.apply_credit_line_interest(current_day)
          |> Suppliers.apply_due_supplier_invoices(next_day)
          |> Finance.maybe_remit_sales_tax(next_day, status)
          |> Consignment.apply_due_consignment_payouts(next_day, status)
          |> Memberships.apply_membership_recognition(next_day)
          |> Staffing.apply_daily_payroll(current_day)
          |> Map.put(:status, status)
          |> Staffing.reset_staff_day()

        next =
          state
          |> State.update_world(fn _ -> next_world end)
          |> State.append_event(event)
          |> State.append_event(
            Events.day_advanced(min(next_day, max_days), delivery_sales, pulse)
          )

        {:ok, next,
         if(status == "in_progress",
           do: {:decide, "advanced to day #{next_day}"},
           else: :terminal
         )}

      {:error, reason} ->
        reject(state, event, reason)
    end
  end
end
