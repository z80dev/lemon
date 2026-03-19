defmodule LemonSim.Examples.VendingBench.Events do
  @moduledoc """
  Event factory functions for the Vending Bench simulation.
  """

  alias LemonSim.Event

  # -- Normalize --

  def normalize(raw), do: Event.new(raw)

  # -- Operator events --

  def operator_checked_balance(balance) do
    Event.new("operator_checked_balance", %{"balance" => balance})
  end

  def operator_checked_storage(storage) do
    Event.new("operator_checked_storage", %{"storage" => storage})
  end

  def operator_read_inbox(inbox_count) do
    Event.new("operator_read_inbox", %{"inbox_count" => inbox_count})
  end

  def operator_inspected_suppliers(supplier_count) do
    Event.new("operator_inspected_suppliers", %{"supplier_count" => supplier_count})
  end

  def operator_reviewed_sales(sales_count) do
    Event.new("operator_reviewed_sales", %{"sales_count" => sales_count})
  end

  def supplier_email_sent(supplier_id, item_id, quantity, cost, delivery_day) do
    Event.new("supplier_email_sent", %{
      "supplier_id" => supplier_id,
      "item_id" => item_id,
      "quantity" => quantity,
      "cost" => cost,
      "delivery_day" => delivery_day
    })
  end

  def physical_worker_run_requested(instructions) do
    Event.new("physical_worker_run_requested", %{"instructions" => instructions})
  end

  def next_day_waited do
    Event.new("next_day_waited", %{})
  end

  # -- Physical worker events --

  def physical_worker_started(instructions) do
    Event.new("physical_worker_started", %{"instructions" => instructions})
  end

  def machine_inventory_checked(snapshot) do
    Event.new("machine_inventory_checked", %{"snapshot" => snapshot})
  end

  def machine_stocked(slot_id, item_id, quantity, from_storage) do
    Event.new("machine_stocked", %{
      "slot_id" => slot_id,
      "item_id" => item_id,
      "quantity" => quantity,
      "from_storage" => from_storage
    })
  end

  def cash_collected(amount) do
    Event.new("cash_collected", %{"amount" => amount})
  end

  def price_set(slot_id, new_price, old_price) do
    Event.new("price_set", %{
      "slot_id" => slot_id,
      "new_price" => new_price,
      "old_price" => old_price
    })
  end

  def physical_worker_finished(summary, tool_calls, extra_payload \\ %{}) do
    payload =
      %{
        "summary" => summary,
        "tool_calls" => tool_calls
      }
      |> Map.merge(Map.new(extra_payload))

    Event.new("physical_worker_finished", payload)
  end

  # -- System events --

  def day_advanced(from_day, to_day) do
    Event.new("day_advanced", %{"from_day" => from_day, "to_day" => to_day})
  end

  def daily_fee_charged(amount, new_balance) do
    Event.new("daily_fee_charged", %{"amount" => amount, "new_balance" => new_balance})
  end

  def sale_realized(slot_id, item_id, quantity, revenue, day) do
    Event.new("sale_realized", %{
      "slot_id" => slot_id,
      "item_id" => item_id,
      "quantity" => quantity,
      "revenue" => revenue,
      "day" => day
    })
  end

  def delivery_arrived(supplier_id, item_id, quantity, day) do
    Event.new("delivery_arrived", %{
      "supplier_id" => supplier_id,
      "item_id" => item_id,
      "quantity" => quantity,
      "day" => day
    })
  end

  def supplier_reply_received(supplier_id, message) do
    Event.new("supplier_reply_received", %{
      "supplier_id" => supplier_id,
      "message" => message
    })
  end

  def weather_changed(kind, demand_multiplier) do
    Event.new("weather_changed", %{"kind" => kind, "demand_multiplier" => demand_multiplier})
  end

  def bankruptcy_triggered(day, unpaid_streak) do
    Event.new("bankruptcy_triggered", %{"day" => day, "unpaid_streak" => unpaid_streak})
  end

  def game_over(reason, day, performance) do
    Event.new("game_over", %{"reason" => reason, "day" => day, "performance" => performance})
  end

  def action_rejected(actor_id, reason) do
    Event.new("action_rejected", %{"actor_id" => actor_id, "reason" => reason})
  end
end
