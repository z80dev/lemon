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

  def researched_market(query, result_count, notes \\ nil) do
    payload = %{"query" => query, "result_count" => result_count}

    Event.new(
      "tcg_researched_market",
      if(notes, do: Map.put(payload, "notes", notes), else: payload)
    )
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

  def open_sealed_product(line_id, quantity) do
    Event.new("tcg_open_sealed_product", %{
      "line_id" => line_id,
      "quantity" => quantity
    })
  end

  def prepare_loose_packs(line_id, quantity, pack_price) do
    Event.new("tcg_prepare_loose_packs", %{
      "line_id" => line_id,
      "quantity" => quantity,
      "pack_price" => pack_price
    })
  end

  def take_consignment(franchise, card_count, estimated_value, commission_pct) do
    Event.new("tcg_take_consignment", %{
      "franchise" => franchise,
      "card_count" => card_count,
      "estimated_value" => estimated_value,
      "commission_pct" => commission_pct
    })
  end

  def sell_memberships(franchise, count, fee, duration_days) do
    Event.new("tcg_sell_memberships", %{
      "franchise" => franchise,
      "count" => count,
      "fee" => fee,
      "duration_days" => duration_days
    })
  end

  def schedule_staff_shift(role, hours) do
    Event.new("tcg_schedule_staff_shift", %{
      "role" => role,
      "hours" => hours
    })
  end

  def upgrade_loss_prevention(control) do
    Event.new("tcg_upgrade_loss_prevention", %{
      "control" => control
    })
  end

  def manage_credit_line(action, amount, reason) do
    Event.new("tcg_manage_credit_line", %{
      "action" => action,
      "amount" => amount,
      "reason" => reason
    })
  end

  def make_bank_deposit(amount, reason) do
    Event.new("tcg_make_bank_deposit", %{
      "amount" => amount,
      "reason" => reason
    })
  end

  def set_prices(markup_pct, line_id \\ nil) do
    payload = %{"markup_pct" => markup_pct}

    Event.new(
      "tcg_set_prices",
      if(line_id, do: Map.put(payload, "line_id", line_id), else: payload)
    )
  end

  def host_event(game, prize_budget, entry_fee, sanctioned \\ true) do
    Event.new("tcg_host_event", %{
      "game" => game,
      "prize_budget" => prize_budget,
      "entry_fee" => entry_fee,
      "sanctioned" => sanctioned
    })
  end

  def take_preorders(line_id, quantity, deposit_pct) do
    Event.new("tcg_take_preorders", %{
      "line_id" => line_id,
      "quantity" => quantity,
      "deposit_pct" => deposit_pct
    })
  end

  def take_special_order(line_id, quantity, deposit_pct) do
    Event.new("tcg_take_special_order", %{
      "line_id" => line_id,
      "quantity" => quantity,
      "deposit_pct" => deposit_pct
    })
  end

  def run_promotion(franchise, channel, budget, duration_days) do
    Event.new("tcg_run_promotion", %{
      "franchise" => franchise,
      "channel" => channel,
      "budget" => budget,
      "duration_days" => duration_days
    })
  end

  def manage_online_channel(platform, listing_quality) do
    Event.new("tcg_manage_online_channel", %{
      "platform" => platform,
      "listing_quality" => listing_quality
    })
  end

  def file_supplier_claim(invoice_id, damaged_units) do
    Event.new("tcg_file_supplier_claim", %{
      "invoice_id" => invoice_id,
      "damaged_units" => damaged_units
    })
  end

  def process_customer_return(line_id, quantity, condition, resolution) do
    Event.new("tcg_process_customer_return", %{
      "line_id" => line_id,
      "quantity" => quantity,
      "condition" => condition,
      "resolution" => resolution
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
