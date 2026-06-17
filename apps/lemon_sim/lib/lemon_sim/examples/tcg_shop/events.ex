defmodule LemonSim.Examples.TcgShop.Events do
  @moduledoc false

  alias LemonSim.Kernel.Event

  def normalize(raw), do: Event.new(raw)

  def checked_dashboard(day, balance) do
    Event.new("tcg_checked_dashboard", %{"day" => day, "bank_balance" => balance})
  end

  def inspected_inventory(count) do
    Event.new("tcg_inspected_inventory", %{"sku_count" => count})
  end

  def researched_market(query, result_count) do
    Event.new("tcg_researched_market", %{"query" => query, "result_count" => result_count})
  end

  def reviewed_customers(queue_count) do
    Event.new("tcg_reviewed_customers", %{"queue_count" => queue_count})
  end

  def order_product_line(line_id, quantity) do
    Event.new("tcg_order_product_line", %{"line_id" => line_id, "quantity" => quantity})
  end

  def buy_collection(franchise, budget, focus) do
    Event.new("tcg_buy_collection", %{
      "franchise" => franchise,
      "budget" => budget,
      "focus" => focus
    })
  end

  def set_prices(markup_pct, line_id \\ nil) do
    payload = %{"markup_pct" => markup_pct}

    Event.new(
      "tcg_set_prices",
      if(line_id, do: Map.put(payload, "line_id", line_id), else: payload)
    )
  end

  def host_event(game, prize_budget, entry_fee) do
    Event.new("tcg_host_event", %{
      "game" => game,
      "prize_budget" => prize_budget,
      "entry_fee" => entry_fee
    })
  end

  def submit_grading(card_count, service_level) do
    Event.new("tcg_submit_grading", %{
      "card_count" => card_count,
      "service_level" => service_level
    })
  end

  def process_online_orders(packing_quality) do
    Event.new("tcg_process_online_orders", %{"packing_quality" => packing_quality})
  end

  def wait_next_day(reason) do
    Event.new("tcg_wait_next_day", %{"reason" => reason})
  end

  def action_rejected(actor, reason, attempted_kind) do
    Event.new("action_rejected", %{
      "actor" => actor,
      "reason" => inspect(reason),
      "attempted_kind" => attempted_kind
    })
  end

  def day_advanced(day, sales, pulse) do
    Event.new("tcg_day_advanced", %{"day" => day, "sales" => sales, "market_pulse" => pulse})
  end
end
