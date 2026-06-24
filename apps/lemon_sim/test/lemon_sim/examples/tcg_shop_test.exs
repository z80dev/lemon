defmodule LemonSim.Examples.TcgShopTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentTool
  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.TcgShop
  alias LemonSim.Bench.Artifacts.Verifier
  alias LemonSim.Examples.TcgShop.{Events, OfflineRunner, Performance, Updater}
  alias LemonSim.Kernel.Runner
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal

  test "initial world models a realistic TCG shop mix" do
    world = TcgShop.initial_world(max_days: 14, seed: 7)

    assert world.mode == "tcg_shop"
    assert world.bank_balance == 10_000.0
    assert world.starting_cash_drawer_balance == 350.0
    assert world.cash_drawer_balance == 350.0
    assert world.local_cash_tender_rate == 0.32
    assert world.cash_handling_history == []
    assert world.daily_rent == 125.0
    assert world.daily_utilities == 22.5
    assert world.daily_insurance == 7.5
    assert world.overhead_history == []
    assert world.play_space.seats == 32
    assert world.play_space.sanction_fee == 6.0
    assert world.play_space.judge_hourly_wage == 20.0
    assert world.credit_line_limit == 3000.0
    assert world.credit_line_balance == 0.0
    assert world.credit_line_apr == 0.18
    assert world.debt_history == []
    assert Map.has_key?(world.catalog, "pokemon_booster_box")
    assert Map.has_key?(world.catalog, "yugioh_core_box")
    assert Map.has_key?(world.catalog, "one_piece_booster_box")
    assert Map.has_key?(world.catalog, "dragon_ball_fusion_box")
    assert world.singles_case.cards_on_hand > 0
    assert length(world.release_calendar) > 0
    assert world.operations.staff_hours_remaining == 10.0
    assert world.supplier_credit_limit == 2500.0
    assert world.supplier_accounts["gts_distribution"].standing == 55
    assert world.supplier_account_history == []
    assert world.pending_supplier_invoices == []
    assert world.delivery_receipt_history == []
    assert world.supplier_claim_history == []
    assert world.return_history == []
    assert world.active_memberships == []
    assert world.membership_liability == 0.0
    assert world.sealed_opening_history == []
    assert world.pack_inventory == %{}
    assert world.pack_preparation_history == []
    assert world.pack_sale_history == []
    assert world.special_order_liability == 0.0
    assert world.pending_special_orders == []
    assert world.special_order_history == []
    assert world.special_order_fulfillment_history == []
    assert world.staffing_history == []
    assert world.loss_prevention_score == 0
    assert world.loss_prevention_history == []
    assert world.online_channel.platform == "local_pickup"
    assert world.online_channel.listing_quality == "basic"
    assert world.online_channel_history == []
    assert world.operations.scheduled_staff_hours == 0.0
    assert world.operations.scheduled_staff_hours_remaining == 0.0
    assert world.operations.scheduled_staff_cost == 0.0
    assert world.customer_base["league_regulars"].loyalty > 0
    assert Enum.any?(world.customer_queue, &(&1.segment_id == "league_regulars"))
    assert world.competitive_position.local_market_share_pct == 34.0
    assert world.competitive_position.price_reputation == "fair"
  end

  test "default options classify TCG research as support and operating actions as terminal" do
    opts =
      TcgShop.default_opts(
        model: fake_model("operator"),
        stream_options: %{},
        complete_fn: fn _model, _context, _stream_opts -> flunk("unused") end
      )

    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_check_dashboard"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_research_market"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "memory_read_file"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_order_product_line"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_host_event"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_take_consignment"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_sell_memberships"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_schedule_staff_shift"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_upgrade_loss_prevention"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_manage_credit_line"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_manage_online_channel"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_file_supplier_claim"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_process_customer_return"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_make_bank_deposit"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_open_sealed_product"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_prepare_loose_packs"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_take_special_order"})
  end

  test "support research can precede a terminal product order" do
    state = TcgShop.initial_state(sim_id: "tcg_support_order", seed: 4)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           tool_call("tcg_research_market", %{"query" => "One Piece allocation"}),
           tool_call("tcg_order_product_line", %{
             "line_id" => "one_piece_booster_box",
             "quantity" => 2
           })
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               TcgShop.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal,
               support_tool_matcher: &TcgShop.support_tool?/1
             )

    assert Enum.map(result.events, & &1.kind) == [
             "tcg_researched_market",
             "tcg_order_product_line"
           ]

    assert [%{query: "One Piece allocation", source: "local_market_research"} = research] =
             result.state.world.research_history

    assert Enum.any?(research.notes, &String.contains?(&1, "Allocation-sensitive"))
  end

  test "next-day resolution delivers inventory, applies overhead, and records sales" do
    state = TcgShop.initial_state(sim_id: "tcg_next_day", seed: 2)

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.order_product_line("card_sleeves", 3), [])

    assert ordered.world.pending_deliveries != []
    assert ordered.world.bank_balance == 10_000.0
    assert [%{amount_due: 6.3, status: "open"}] = ordered.world.pending_supplier_invoices

    assert {:ok, advanced, _} =
             Updater.apply_event(ordered, Events.wait_next_day("close register"), [])

    assert advanced.world.pending_deliveries == []
    assert advanced.world.day_number == 2
    assert advanced.world.bank_balance != ordered.world.bank_balance

    assert [
             %{
               day: 1,
               rent: 125.0,
               utilities: 22.5,
               insurance: 7.5,
               total: 155.0,
               type: "fixed_overhead"
             }
           ] = advanced.world.overhead_history

    assert length(advanced.world.sales_history) > 0

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.fixed_overhead == 155.0
    assert scorecard.rent_expense == 125.0
    assert scorecard.utilities_expense == 22.5
    assert scorecard.insurance_expense == 7.5
    assert is_float(scorecard.operating_profit)
  end

  test "online order fulfillment is constrained by actual inventory and damages trust" do
    state = TcgShop.initial_state(sim_id: "tcg_online_stockout", seed: 2)

    inventory =
      Enum.into(state.world.inventory, %{}, fn {line_id, item} ->
        {line_id, Map.put(item, :on_hand, 0)}
      end)

    state = put_in(state.world.inventory, inventory)

    assert {:ok, result, _} =
             Updater.apply_event(state, Events.process_online_orders("cheap"), [])

    assert [order] = result.world.online_order_history
    assert order.requested_count > 0
    assert order.fulfilled_count == 0
    assert order.backorder_count == order.requested_count
    assert order.revenue == 0.0
    assert result.world.online_rating < state.world.online_rating
    assert result.world.reputation < state.world.reputation
    assert [%{source: "online_orders"}] = result.world.service_issue_history
    assert [%{source: "online_orders", lost_units: lost_units}] = result.world.stockout_history
    assert lost_units == order.backorder_count
  end

  test "taxable sales collect sales tax as liability and remit on schedule" do
    state = TcgShop.initial_state(sim_id: "tcg_sales_tax", seed: 2)

    assert {:ok, sold, _} =
             Updater.apply_event(state, Events.process_online_orders("standard"), [])

    assert [order] = sold.world.online_order_history
    expected_tax = Float.round(order.revenue * sold.world.sales_tax_rate, 2)

    assert order.sales_tax_collected == expected_tax
    assert sold.world.sales_tax_liability == expected_tax
    assert [cost] = sold.world.transaction_cost_history
    assert cost.source == "online_orders"

    assert sold.world.bank_balance ==
             Float.round(
               state.world.bank_balance + order.revenue + expected_tax - order.packing_cost -
                 cost.total_cost,
               2
             )

    scorecard = Performance.scorecard(sold.world)
    assert scorecard.sales_tax_liability == expected_tax
    assert scorecard.sales_tax_collected == expected_tax
    assert scorecard.sales_tax_remitted == 0.0

    day_seven =
      Enum.reduce(1..6, sold, fn _, acc ->
        {:ok, next, _} = Updater.apply_event(acc, Events.wait_next_day("tax remittance"), [])
        next
      end)

    assert day_seven.world.day_number == 7
    assert day_seven.world.sales_tax_liability == 0.0
    assert Enum.any?(day_seven.world.tax_history, &(&1.type == "remitted"))

    scorecard = Performance.scorecard(day_seven.world)
    assert scorecard.sales_tax_remitted == scorecard.sales_tax_collected
  end

  test "hot sealed product orders can receive partial distributor allocations" do
    state = TcgShop.initial_state(sim_id: "tcg_partial_allocation", seed: 2)

    assert {:ok, ordered, _} =
             Updater.apply_event(
               state,
               Events.order_product_line("one_piece_booster_box", 10),
               []
             )

    assert [order] = ordered.world.supplier_order_history
    assert order.requested_quantity == 10
    assert order.quantity < order.requested_quantity
    assert order.allocation_rate < 1.0
    assert order.cost == Float.round(order.quantity * 74.0, 2)
    assert ordered.world.bank_balance == 10_000.0
    assert order.payment_status == "invoiced"
    assert [invoice] = ordered.world.pending_supplier_invoices
    assert invoice.id == order.invoice_id
    assert invoice.amount_due == order.cost
    assert [%{quantity: quantity}] = ordered.world.pending_deliveries
    assert quantity == order.quantity

    scorecard = Performance.scorecard(ordered.world)
    assert scorecard.allocation_shortfalls == 1
    assert scorecard.supplier_fill_rate_pct < 100.0
    assert scorecard.accounts_payable == order.cost
    assert scorecard.supplier_invoices_open == 1
    assert scorecard.supplier_credit_available == Float.round(2500.0 - order.cost, 2)
  end

  test "supplier invoices are paid from cash flow when distributor terms mature" do
    state = TcgShop.initial_state(sim_id: "tcg_supplier_invoice", seed: 2, supplier_terms_days: 0)

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.order_product_line("card_sleeves", 10), [])

    assert [invoice] = ordered.world.pending_supplier_invoices
    assert invoice.amount_due == 21.0
    assert invoice.due_day == 2
    assert ordered.world.bank_balance == state.world.bank_balance

    assert {:ok, advanced, _} =
             Updater.apply_event(ordered, Events.wait_next_day("receive and pay invoice"), [])

    assert advanced.world.pending_supplier_invoices == []
    assert Enum.any?(advanced.world.supplier_invoice_history, &(&1.type == "paid"))
    assert advanced.world.supplier_accounts["gts_distribution"].standing == 58
    assert advanced.world.supplier_accounts["gts_distribution"].invoices_paid == 1

    assert [
             %{
               supplier: "gts_distribution",
               standing_before: 55,
               standing_after: 58,
               type: "paid"
             }
           ] = advanced.world.supplier_account_history

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.accounts_payable == 0.0
    assert scorecard.supplier_invoices_paid == 21.0
    assert scorecard.supplier_invoices_open == 0
    assert scorecard.average_supplier_standing == 56.0
    assert scorecard.supplier_credit_limit_effective == 2520.0
    assert scorecard.supplier_account_events == 1
  end

  test "supplier account standing changes scarce sealed allocations" do
    preferred =
      TcgShop.initial_state(sim_id: "tcg_preferred_supplier", seed: 2)
      |> put_in(
        [Access.key!(:world), Access.key!(:supplier_accounts), "premium_secondary", :standing],
        85
      )

    strained =
      TcgShop.initial_state(sim_id: "tcg_strained_supplier", seed: 2)
      |> put_in(
        [Access.key!(:world), Access.key!(:supplier_accounts), "premium_secondary", :standing],
        30
      )

    assert {:ok, preferred_ordered, _} =
             Updater.apply_event(
               preferred,
               Events.order_product_line("one_piece_booster_box", 10),
               []
             )

    assert {:ok, strained_ordered, _} =
             Updater.apply_event(
               strained,
               Events.order_product_line("one_piece_booster_box", 10),
               []
             )

    [preferred_order] = preferred_ordered.world.supplier_order_history
    [strained_order] = strained_ordered.world.supplier_order_history

    assert preferred_order.supplier_standing == 85
    assert strained_order.supplier_standing == 30
    assert preferred_order.quantity > strained_order.quantity
  end

  test "credit line draws cash, accrues interest, and supports repayment" do
    state = TcgShop.initial_state(sim_id: "tcg_credit_line", seed: 4)

    assert {:ok, drawn, _} =
             Updater.apply_event(
               state,
               Events.manage_credit_line("draw", 1_000.0, "holiday allocation float"),
               []
             )

    assert drawn.world.bank_balance == 11_000.0
    assert drawn.world.credit_line_balance == 1_000.0
    assert [%{type: "draw", amount: 1_000.0, balance_after: 1_000.0}] = drawn.world.debt_history

    assert {:ok, advanced, _} =
             Updater.apply_event(drawn, Events.wait_next_day("accrue financing cost"), [])

    assert advanced.world.credit_line_balance == 1_000.49
    assert Enum.any?(advanced.world.debt_history, &(&1.type == "interest" and &1.amount == 0.49))

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.credit_line_balance == 1_000.49
    assert scorecard.credit_line_draws == 1_000.0
    assert scorecard.credit_line_interest == 0.49
    assert scorecard.credit_line_available == 1_999.51

    assert {:ok, repaid, _} =
             Updater.apply_event(
               advanced,
               Events.manage_credit_line("repay", 500.0, "pay down after event weekend"),
               []
             )

    assert repaid.world.credit_line_balance == 500.49
    assert Enum.any?(repaid.world.debt_history, &(&1.type == "repay" and &1.amount == 500.0))
    assert Performance.scorecard(repaid.world).credit_line_repayments == 500.0
  end

  test "local sales split cash and card tenders and can be deposited to bank" do
    state = TcgShop.initial_state(sim_id: "tcg_cash_drawer", seed: 4)

    assert {:ok, sold, _} =
             Updater.apply_event(state, Events.sell_memberships("Pokemon", 4, 25.0, 7), [])

    assert sold.world.cash_drawer_balance > state.world.cash_drawer_balance
    assert sold.world.bank_balance > state.world.bank_balance

    assert Enum.any?(
             sold.world.cash_handling_history,
             &(&1.type == "tender_split" and &1.source == "membership_sale")
           )

    scorecard = Performance.scorecard(sold.world)
    assert scorecard.cash_drawer_balance == sold.world.cash_drawer_balance
    assert scorecard.cash_tender_sales > 0
    assert scorecard.card_tender_sales > 0
    assert scorecard.bank_deposits == 0.0

    deposit_amount = Float.round(sold.world.cash_drawer_balance - 350.0, 2)

    assert {:ok, deposited, _} =
             Updater.apply_event(
               sold,
               Events.make_bank_deposit(deposit_amount, "daily cash drop"),
               []
             )

    assert deposited.world.cash_drawer_balance == 350.0

    assert deposited.world.bank_balance ==
             Float.round(sold.world.bank_balance + deposit_amount, 2)

    assert Enum.any?(
             deposited.world.cash_handling_history,
             &(&1.type == "bank_deposit" and &1.amount == deposit_amount)
           )

    scorecard = Performance.scorecard(deposited.world)
    assert scorecard.bank_deposits == deposit_amount

    assert {:ok, rejected, _} =
             Updater.apply_event(
               deposited,
               Events.make_bank_deposit(10_000.0, "impossible cash deposit"),
               []
             )

    assert rejected.world.invalid_action_count == deposited.world.invalid_action_count + 1
  end

  test "daily close reconciles register cash over short against tender activity" do
    state = TcgShop.initial_state(sim_id: "tcg_cash_reconcile", seed: 4)

    tender = %{
      day: 2,
      type: "tender_split",
      source: "test_cash_sale",
      amount: 500.0,
      cash_amount: 200.0,
      card_amount: 300.0,
      cash_rate: 0.4
    }

    state = %{
      state
      | world: %{
          state.world
          | inventory: %{},
            cash_drawer_balance: 550.0,
            cash_handling_history: [tender]
        }
    }

    assert {:ok, advanced, _} =
             Updater.apply_event(state, Events.wait_next_day("count drawer"), [])

    assert reconciliation =
             Enum.find(advanced.world.cash_handling_history, &(&1.type == "cash_reconciliation"))

    assert reconciliation.day == 2
    assert reconciliation.source == "daily_close"
    assert reconciliation.tender_cash_total >= 200.0
    assert reconciliation.expected_cash >= 550.0
    assert reconciliation.actual_cash == advanced.world.cash_drawer_balance
    assert reconciliation.over_short_amount != 0.0

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.cash_reconciliations == 1
    assert scorecard.cash_over_short == reconciliation.over_short_amount
    assert scorecard.cash_shortage_loss + scorecard.cash_overage_gain > 0.0
  end

  test "business actions consume staff hours and surface overtime pressure" do
    state = TcgShop.initial_state(sim_id: "tcg_overtime", seed: 2)
    state = put_in(state.world.operations.staff_hours_remaining, 0.25)

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.order_product_line("card_sleeves", 80), [])

    assert [entry] = ordered.world.operations_history
    assert entry.action == "supplier_order"
    assert entry.staff_hours == 2.8
    assert entry.overtime_hours == 2.55
    assert entry.overtime_cost == 71.4
    assert ordered.world.operations.staff_hours_remaining == 0.0
    assert ordered.world.operations.cumulative_overtime_hours == 2.55
    assert ordered.world.operations.fatigue == 2
    assert length(ordered.world.operations.backlog_tasks) == 1
    assert ordered.world.bank_balance == Float.round(10_000.0 - 71.4, 2)
    assert [%{amount_due: 168.0}] = ordered.world.pending_supplier_invoices

    scorecard = Performance.scorecard(ordered.world)
    assert scorecard.staff_hours_used == 2.8
    assert scorecard.overtime_hours == 2.55
    assert scorecard.overtime_cost == 71.4
    assert scorecard.backlog_tasks == 1
  end

  test "scheduled staff adds labor coverage before overtime and records cost" do
    state = TcgShop.initial_state(sim_id: "tcg_staffing", seed: 2)
    state = put_in(state.world.operations.staff_hours_remaining, 0.0)

    assert {:ok, staffed, _} =
             Updater.apply_event(state, Events.schedule_staff_shift("sorting", 4.0), [])

    assert staffed.world.bank_balance == 9936.0

    assert [
             %{
               role: "sorting",
               hours: 4.0,
               hourly_wage: 16.0,
               labor_cost: 64.0,
               type: "scheduled_shift"
             }
           ] = staffed.world.staffing_history

    assert staffed.world.operations.scheduled_staff_hours == 4.0
    assert staffed.world.operations.scheduled_staff_hours_remaining == 4.0
    assert staffed.world.operations.scheduled_staff_cost == 64.0

    assert {:ok, ordered, _} =
             Updater.apply_event(staffed, Events.order_product_line("card_sleeves", 80), [])

    assert [operation] = ordered.world.operations_history
    assert operation.action == "supplier_order"
    assert operation.regular_hours == 0.0
    assert operation.scheduled_hours == 2.8

    assert ordered.world.operations.scheduled_staff_hours_remaining == 1.2
    assert ordered.world.operations.cumulative_overtime_hours == 0.0
    assert ordered.world.operations.backlog_tasks == []
    assert ordered.world.bank_balance == 9936.0

    scorecard = Performance.scorecard(ordered.world)
    assert scorecard.scheduled_staff_shifts == 1
    assert scorecard.scheduled_staff_hours == 4.0
    assert scorecard.scheduled_staff_hours_used == 2.8
    assert scorecard.scheduled_staff_cost == 64.0
    assert scorecard.overtime_cost == 0.0
    assert scorecard.total_labor_cost == 64.0
    assert scorecard.operating_expenses == 64.0
  end

  test "regular staff hours create a daily payroll cash cost" do
    state = TcgShop.initial_state(sim_id: "tcg_payroll", seed: 2)

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.order_product_line("card_sleeves", 10), [])

    assert ordered.world.payroll_history == []

    assert {:ok, advanced, _} =
             Updater.apply_event(ordered, Events.wait_next_day("close register"), [])

    assert [payroll] = advanced.world.payroll_history
    assert payroll.day == 1
    assert payroll.regular_hours_used == 0.7
    assert payroll.paid_hours == 4.0
    assert payroll.hourly_wage == 18.0
    assert payroll.payroll_cost == 72.0
    assert advanced.world.operations.cumulative_regular_payroll == 72.0

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.payroll_paid_hours == 4.0
    assert scorecard.regular_payroll == 72.0
    assert scorecard.total_labor_cost == 72.0
  end

  test "card payments and online fulfillment create channel cost ledger entries" do
    state = TcgShop.initial_state(sim_id: "tcg_channel_costs", seed: 2)
    starting_balance = state.world.bank_balance

    assert {:ok, processed, _} =
             Updater.apply_event(state, Events.process_online_orders("standard"), [])

    assert [entry] = processed.world.transaction_cost_history
    assert [order] = processed.world.online_order_history
    assert entry.source == "online_orders"
    assert entry.transaction_count == order.fulfilled_count
    assert entry.shipped_orders == order.fulfilled_count
    assert entry.processing_fee > 0.0
    assert entry.shipping_label_cost == order.shipping_label_cost
    assert entry.total_cost == Float.round(entry.processing_fee + entry.shipping_label_cost, 2)
    assert order.cost_of_goods_sold > 0.0
    assert order.gross_profit == Float.round(order.revenue - order.cost_of_goods_sold, 2)
    assert Enum.all?(order.lines, &(&1.cost_of_goods_sold > 0.0))

    expected_balance =
      Float.round(
        starting_balance + order.revenue + order.sales_tax_collected - order.packing_cost -
          entry.total_cost,
        2
      )

    assert processed.world.bank_balance == expected_balance

    scorecard = Performance.scorecard(processed.world)
    assert scorecard.sales_revenue == order.revenue
    assert scorecard.cost_of_goods_sold == order.cost_of_goods_sold
    assert scorecard.gross_profit == order.gross_profit
    assert scorecard.gross_margin_pct > 0.0
    assert scorecard.payment_processing_fees == entry.processing_fee
    assert scorecard.shipping_label_cost == entry.shipping_label_cost
    assert scorecard.packing_supply_cost == order.packing_cost

    assert scorecard.channel_costs ==
             Float.round(entry.total_cost + order.packing_cost, 2)
  end

  test "online channel management changes demand and records marketplace fees" do
    state = TcgShop.initial_state(sim_id: "tcg_online_channel", seed: 2)

    assert {:ok, managed, _} =
             Updater.apply_event(
               state,
               Events.manage_online_channel("tcgplayer", "optimized"),
               []
             )

    assert managed.world.bank_balance == 9910.0
    assert managed.world.online_channel.platform == "tcgplayer"
    assert managed.world.online_channel.listing_quality == "optimized"
    assert managed.world.online_channel.demand_multiplier == 1.53
    assert managed.world.online_channel.marketplace_fee_rate == 0.105
    assert [%{platform: "tcgplayer", setup_cost: 90.0}] = managed.world.online_channel_history
    assert [%{action: "online_listing", staff_hours: 1.0}] = managed.world.operations_history

    scorecard = Performance.scorecard(managed.world)
    assert scorecard.online_channel_updates == 1
    assert scorecard.online_channel_setup_spend == 90.0
    assert scorecard.online_channel_platform == "tcgplayer"
    assert scorecard.online_listing_quality == "optimized"
    assert scorecard.operating_expenses == 90.0

    assert {:ok, processed, _} =
             Updater.apply_event(managed, Events.process_online_orders("standard"), [])

    [order] = processed.world.online_order_history
    [cost] = processed.world.transaction_cost_history

    assert order.platform == "tcgplayer"
    assert order.listing_quality == "optimized"
    assert order.requested_count == 13
    assert order.fulfilled_count == 13
    assert order.revenue == 1579.87
    assert order.marketplace_fee == 165.89
    assert cost.marketplace_platform == "tcgplayer"
    assert cost.marketplace_fee == 165.89
    assert cost.total_cost == 270.86

    scorecard = Performance.scorecard(processed.world)
    assert scorecard.marketplace_fees == 165.89
    assert scorecard.channel_costs == 285.81
    assert scorecard.operating_expenses == 375.81
    assert scorecard.operating_profit == 248.06
  end

  test "online service issues create refunds and chargebacks on daily close" do
    state = TcgShop.initial_state(sim_id: "tcg_refunds", seed: 2)

    assert {:ok, processed, _} =
             Updater.apply_event(state, Events.process_online_orders("cheap"), [])

    assert [%{complaints: complaints}] = processed.world.service_issue_history
    assert complaints > 0
    assert processed.world.refund_history == []

    assert {:ok, advanced, _} =
             Updater.apply_event(processed, Events.wait_next_day("settle refunds"), [])

    assert [refund] = advanced.world.refund_history
    assert refund.source == "online_orders"
    assert refund.refund_amount > 0.0
    assert refund.chargeback

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.refund_amount == refund.refund_amount

    assert scorecard.net_sales_revenue ==
             Float.round(scorecard.sales_revenue - refund.refund_amount, 2)

    assert scorecard.refund_count == 1
    assert scorecard.chargeback_count == 1
  end

  test "customer returns refund prior local sales and restock resellable sealed product" do
    state = TcgShop.initial_state(sim_id: "tcg_customer_return", seed: 2)

    sale = %{
      day: 1,
      line_id: "pokemon_booster_box",
      segment_id: "league_regulars",
      quantity: 2,
      revenue: 260.0,
      cost_of_goods_sold: 188.0,
      gross_profit: 72.0,
      channel: "walk_in"
    }

    state = put_in(state.world.sales_history, [sale])
    starting_inventory = state.world.inventory["pokemon_booster_box"].on_hand

    assert {:ok, returned, _} =
             Updater.apply_event(
               state,
               Events.process_customer_return(
                 "pokemon_booster_box",
                 1,
                 "sealed_resellable",
                 "store_credit"
               ),
               []
             )

    assert [
             %{
               line_id: "pokemon_booster_box",
               quantity: 1,
               condition: "sealed_resellable",
               resolution: "store_credit",
               refund_amount: 130.0,
               restocked_units: 1,
               cogs_recovered: 94.0,
               writeoff_loss: writeoff_loss
             }
           ] = returned.world.return_history

    assert writeoff_loss == 0.0

    assert [%{source: "customer_return", refund_amount: 130.0, chargeback: false}] =
             returned.world.refund_history

    assert [%{type: "issued", source: "customer_return", amount: 130.0}] =
             returned.world.store_credit_history

    assert returned.world.store_credit_liability == 130.0
    assert returned.world.inventory["pokemon_booster_box"].on_hand == starting_inventory + 1

    scorecard = Performance.scorecard(returned.world)
    assert scorecard.customer_returns == 1
    assert scorecard.returned_units == 1
    assert scorecard.return_refunds == 130.0
    assert scorecard.returned_inventory_units == 1
    assert scorecard.return_cogs_recovered == 94.0
    assert scorecard.return_store_credit == 130.0
    assert scorecard.refund_amount == 130.0
    assert scorecard.net_sales_revenue == 130.0
    assert scorecard.cost_of_goods_sold == 94.0

    assert {:ok, rejected, _} =
             Updater.apply_event(
               returned,
               Events.process_customer_return(
                 "pokemon_booster_box",
                 2,
                 "sealed_resellable",
                 "store_credit"
               ),
               []
             )

    assert rejected.world.invalid_action_count == returned.world.invalid_action_count + 1
  end

  test "store events improve the matching customer segment" do
    state = TcgShop.initial_state(sim_id: "tcg_customer_event", seed: 2)
    before = state.world.customer_base["league_regulars"]

    assert {:ok, hosted, _} =
             Updater.apply_event(state, Events.host_event("Pokemon", 120.0, 12.0), [])

    after_segment = hosted.world.customer_base["league_regulars"]
    assert after_segment.loyalty > before.loyalty
    assert after_segment.satisfaction > before.satisfaction
    assert after_segment.visits > 0
    assert [event] = hosted.world.tournament_history
    assert event.prize_budget == 120.0
    assert event.prize_inventory_value >= 120.0
    assert event.prize_inventory_cost > 0.0
    assert event.prize_store_credit_issued == 0.0
    assert [%{line_id: "pokemon_booster_box", quantity: 1}] = event.prize_support_lines
    assert event.sanctioned
    assert event.seat_capacity == 32
    assert event.requested_attendance >= event.attendance
    assert event.no_shows >= 0
    assert event.turn_aways >= 0
    assert event.capacity_utilization_pct > 0.0
    assert event.sanction_fee == 6.0
    assert event.judge_cost > 0.0
    assert event.operating_cost == Float.round(event.judge_cost + event.sanction_fee, 2)

    assert [%{segment_id: "league_regulars", reason: "store_event"}] =
             hosted.world.customer_history

    scorecard = Performance.scorecard(hosted.world)

    assert scorecard.average_customer_loyalty >
             Performance.scorecard(state.world).average_customer_loyalty

    assert scorecard.customer_visits == after_segment.visits
    assert scorecard.event_attendance == event.attendance
    assert scorecard.sanctioned_events == 1
    assert scorecard.event_capacity_utilization_pct == event.capacity_utilization_pct
    assert scorecard.event_turn_aways == event.turn_aways
    assert scorecard.event_no_shows == event.no_shows
    assert scorecard.event_prize_value == event.prize_fulfilled_value
    assert scorecard.event_prize_inventory_cost == event.prize_inventory_cost
    assert scorecard.event_prize_store_credit == 0.0
    assert scorecard.event_judge_cost == event.judge_cost
    assert scorecard.event_sanction_fees == 6.0
    assert scorecard.event_operating_cost == event.operating_cost
  end

  test "store events issue prize credit when prize inventory is unavailable" do
    state = TcgShop.initial_state(sim_id: "tcg_event_prize_credit", seed: 2)

    inventory =
      Enum.into(state.world.inventory, %{}, fn {line_id, item} ->
        line = state.world.catalog[line_id]

        if line.franchise in ["Pokemon", "Accessories"] do
          {line_id, Map.put(item, :on_hand, 0)}
        else
          {line_id, item}
        end
      end)

    state = put_in(state.world.inventory, inventory)

    assert {:ok, hosted, _} =
             Updater.apply_event(state, Events.host_event("Pokemon", 120.0, 12.0), [])

    assert [event] = hosted.world.tournament_history
    assert event.prize_inventory_value == 0.0
    assert event.prize_inventory_cost == 0.0
    assert event.prize_store_credit_issued == 120.0
    assert event.prize_fulfilled_value == 120.0
    assert event.prize_support_lines == []
    assert hosted.world.store_credit_liability == 120.0

    assert [%{source: "event_prize_support", type: "issued", amount: 120.0}] =
             hosted.world.store_credit_history

    scorecard = Performance.scorecard(hosted.world)
    assert scorecard.event_prize_store_credit == 120.0
    assert scorecard.store_credit_liability == 120.0
  end

  test "walk-in stockouts damage the matching customer segment and next queue" do
    state = TcgShop.initial_state(sim_id: "tcg_customer_stockout", seed: 2)
    before = state.world.customer_base["league_regulars"]

    inventory =
      Enum.into(state.world.inventory, %{}, fn {line_id, item} ->
        if line_id in ["pokemon_booster_box", "pokemon_elite_trainer_box"] do
          {line_id, Map.put(item, :on_hand, 0)}
        else
          {line_id, item}
        end
      end)

    state = put_in(state.world.inventory, inventory)

    assert {:ok, advanced, _} =
             Updater.apply_event(state, Events.wait_next_day("close register"), [])

    after_segment = advanced.world.customer_base["league_regulars"]
    assert after_segment.loyalty < before.loyalty
    assert after_segment.satisfaction < before.satisfaction
    assert Enum.any?(advanced.world.customer_history, &(&1.reason == "stockout"))
    assert Enum.any?(advanced.world.customer_queue, &(&1.segment_id == "league_regulars"))
  end

  test "stockouts and high shelf prices trigger competitor pressure" do
    state = TcgShop.initial_state(sim_id: "tcg_competitor_pressure", seed: 2)

    assert {:ok, priced, _} =
             Updater.apply_event(state, Events.set_prices(80.0), [])

    inventory =
      Enum.into(priced.world.inventory, %{}, fn {line_id, item} ->
        {line_id, Map.put(item, :on_hand, 0)}
      end)

    priced = put_in(priced.world.inventory, inventory)
    before = priced.world.competitive_position

    assert {:ok, advanced, _} =
             Updater.apply_event(priced, Events.wait_next_day("close register"), [])

    assert [reaction] = advanced.world.competitor_history
    assert reaction.stockout_units > 0
    assert reaction.competitor_pressure > before.competitor_pressure

    assert advanced.world.competitive_position.local_market_share_pct <
             before.local_market_share_pct

    assert advanced.world.competitive_position.price_reputation in ["premium", "expensive"]

    assert reaction.reaction in [
             "competitors advertise in-stock alternatives",
             "nearby shop undercuts high shelf prices",
             "online sellers pressure local prices"
           ]

    scorecard = Performance.scorecard(advanced.world)

    assert scorecard.local_market_share_pct ==
             advanced.world.competitive_position.local_market_share_pct

    assert scorecard.competitor_pressure ==
             advanced.world.competitive_position.competitor_pressure

    assert scorecard.competitor_reactions == 1
  end

  test "preorders collect deposits and create unearned liability" do
    state = TcgShop.initial_state(sim_id: "tcg_preorder_deposit", seed: 2)
    unit_price = state.world.inventory["pokemon_booster_box"].price
    expected_deposit = Float.round(unit_price * 4 * 0.25, 2)

    assert {:ok, reserved, _} =
             Updater.apply_event(state, Events.take_preorders("pokemon_booster_box", 4, 25.0), [])

    assert [preorder] = reserved.world.pending_preorders
    assert preorder.quantity == 4
    assert preorder.remaining_quantity == 4
    assert preorder.release_day == 3
    assert preorder.deposit_collected == expected_deposit
    assert [cost] = reserved.world.transaction_cost_history
    assert cost.source == "preorder_deposit"
    assert cost.processing_fee > 0.0
    assert [tender] = reserved.world.cash_handling_history
    assert tender.source == "preorder_deposit"
    assert tender.cash_amount > 0.0
    assert tender.card_amount > 0.0

    assert reserved.world.cash_drawer_balance ==
             Float.round(state.world.cash_drawer_balance + tender.cash_amount, 2)

    assert reserved.world.bank_balance ==
             Float.round(state.world.bank_balance + tender.card_amount - cost.total_cost, 2)

    scorecard = Performance.scorecard(reserved.world)
    assert scorecard.preorder_deposits == expected_deposit
    assert scorecard.preorder_liability == expected_deposit
    assert scorecard.pending_preorder_units == 4
  end

  test "release-day preorders reserve inventory and record shortfalls before walk-in sales" do
    state = TcgShop.initial_state(sim_id: "tcg_preorder_release", seed: 2)

    inventory =
      Map.update!(state.world.inventory, "pokemon_booster_box", &Map.put(&1, :on_hand, 2))

    state = %{state | world: %{state.world | inventory: inventory}}

    assert {:ok, reserved, _} =
             Updater.apply_event(state, Events.take_preorders("pokemon_booster_box", 4, 25.0), [])

    assert {:ok, day_two, _} =
             Updater.apply_event(reserved, Events.wait_next_day("hold preorder stock"), [])

    assert day_two.world.inventory["pokemon_booster_box"].on_hand == 2
    assert [%{remaining_quantity: 4}] = day_two.world.pending_preorders

    assert {:ok, day_three, _} =
             Updater.apply_event(day_two, Events.wait_next_day("release day"), [])

    assert [fulfillment] = day_three.world.preorder_fulfillment_history
    assert fulfillment.fulfilled_quantity == 2
    assert fulfillment.shorted_quantity == 2
    assert fulfillment.status == "partial_backorder"
    assert day_three.world.inventory["pokemon_booster_box"].on_hand == 0
    assert [%{remaining_quantity: 2, status: "backordered"}] = day_three.world.pending_preorders

    assert Enum.any?(
             day_three.world.stockout_history,
             &(&1.source == "preorder_fulfillment" and &1.lost_units == 2)
           )

    scorecard = Performance.scorecard(day_three.world)
    assert scorecard.preorder_units_fulfilled == 2
    assert scorecard.preorder_units_short == 2
    assert scorecard.pending_preorder_units == 2
    assert scorecard.preorder_revenue > 0.0
  end

  test "customer special orders collect deposits, reserve stock, and fulfill from inventory" do
    state = TcgShop.initial_state(sim_id: "tcg_special_order", seed: 2)

    inventory =
      Map.update!(state.world.inventory, "card_sleeves", &Map.put(&1, :on_hand, 4))

    state = %{state | world: %{state.world | inventory: inventory}}

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.take_special_order("card_sleeves", 4, 50.0), [])

    assert [
             %{
               line_id: "card_sleeves",
               franchise: "Accessories",
               quantity: 4,
               remaining_quantity: 4,
               unit_price: 6.49,
               total_price: 25.96,
               deposit_pct: 50.0,
               deposit_collected: 12.98,
               deposit_remaining: 12.98,
               due_day: 2,
               status: "open"
             }
           ] = ordered.world.pending_special_orders

    assert ordered.world.special_order_liability == 12.98

    assert [%{action: "special_order_intake", staff_hours: 0.37}] =
             ordered.world.operations_history

    assert [%{source: "special_order_deposit"}] = ordered.world.transaction_cost_history

    scorecard = Performance.scorecard(ordered.world)
    assert scorecard.special_order_liability == 12.98
    assert scorecard.special_order_deposits == 12.98
    assert scorecard.pending_special_order_units == 4

    assert {:ok, advanced, _} =
             Updater.apply_event(ordered, Events.wait_next_day("fulfill special order"), [])

    assert advanced.world.pending_special_orders == []
    assert advanced.world.special_order_liability == 0.0
    assert advanced.world.inventory["card_sleeves"].on_hand == 0

    assert [
             %{
               channel: "special_order",
               line_id: "card_sleeves",
               fulfilled_quantity: 4,
               shorted_quantity: 0,
               deposit_applied: 12.98,
               balance_revenue: 12.98,
               taxable_revenue: 25.96,
               revenue: 25.96,
               cost_of_goods_sold: 8.4,
               gross_profit: 17.56,
               sales_tax_collected: 2.14,
               status: "fulfilled"
             }
           ] = advanced.world.special_order_fulfillment_history

    assert Enum.any?(advanced.world.sales_history, &(&1.channel == "special_order"))

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.special_order_liability == 0.0
    assert scorecard.special_order_revenue == 25.96
    assert scorecard.special_order_units_fulfilled == 4
    assert scorecard.special_order_units_short == 0
    assert scorecard.pending_special_order_units == 0
  end

  test "special orders backorder unfilled customer holds without double-counting shortfalls" do
    state = TcgShop.initial_state(sim_id: "tcg_special_order_shortfall", seed: 2)

    inventory =
      Map.update!(state.world.inventory, "card_sleeves", &Map.put(&1, :on_hand, 1))

    state = %{state | world: %{state.world | inventory: inventory}}

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.take_special_order("card_sleeves", 4, 50.0), [])

    assert {:ok, advanced, _} =
             Updater.apply_event(ordered, Events.wait_next_day("partial fill"), [])

    assert [%{remaining_quantity: 3, status: "backordered", shortfall_recorded: true}] =
             advanced.world.pending_special_orders

    assert advanced.world.special_order_liability == 9.73

    assert [%{fulfilled_quantity: 1, shorted_quantity: 3, delayed_quantity: 3}] =
             advanced.world.special_order_fulfillment_history

    assert Enum.any?(
             advanced.world.stockout_history,
             &(&1.source == "special_order_fulfillment" and &1.lost_units == 3)
           )

    assert Enum.any?(
             advanced.world.service_issue_history,
             &(&1.source == "special_order_fulfillment" and &1.shorted_units == 3)
           )

    assert {:ok, still_pending, _} =
             Updater.apply_event(advanced, Events.wait_next_day("still waiting"), [])

    assert [%{remaining_quantity: 3, status: "backordered"}] =
             still_pending.world.pending_special_orders

    assert Enum.count(
             still_pending.world.stockout_history,
             &(&1.source == "special_order_fulfillment")
           ) == 1
  end

  test "promotions spend cash and attribute boosted walk-in sales" do
    state = TcgShop.initial_state(sim_id: "tcg_promotion", seed: 2)

    assert {:ok, promoted, _} =
             Updater.apply_event(
               state,
               Events.run_promotion("Pokemon", "social_ads", 300.0, 3),
               []
             )

    assert [promotion] = promoted.world.active_promotions
    assert promotion.franchise == "Pokemon"
    assert promotion.demand_lift > 0.0
    assert promoted.world.bank_balance < state.world.bank_balance

    scorecard = Performance.scorecard(promoted.world)
    assert scorecard.marketing_spend == 300.0
    assert scorecard.active_promotions == 1

    assert {:ok, advanced, _} =
             Updater.apply_event(promoted, Events.wait_next_day("measure campaign"), [])

    assert Enum.any?(
             advanced.world.sales_history,
             &(Map.get(&1, :promotion_id) == promotion.id and Map.get(&1, :quantity, 0) > 0)
           )

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.promoted_units_sold > 0
    assert scorecard.promoted_revenue > 0.0
  end

  test "fatigue and large inventory counts create daily shrinkage losses" do
    state = TcgShop.initial_state(sim_id: "tcg_shrinkage", seed: 2)

    inventory =
      Enum.into(state.world.inventory, %{}, fn {line_id, item} ->
        {line_id, Map.put(item, :on_hand, 80)}
      end)

    operations =
      state.world.operations
      |> Map.put(:fatigue, 9)
      |> Map.put(:backlog_tasks, [
        %{day: 1, task: "cycle count"},
        %{day: 1, task: "sort singles"},
        %{day: 1, task: "clean event space"},
        %{day: 1, task: "receive cases"}
      ])

    state = %{state | world: %{state.world | inventory: inventory, operations: operations}}

    assert {:ok, advanced, _} =
             Updater.apply_event(state, Events.wait_next_day("close register"), [])

    assert length(advanced.world.shrinkage_history) > 0

    assert Enum.all?(
             advanced.world.shrinkage_history,
             &(&1.reason == "fatigued handling damaged inventory")
           )

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.shrinkage_units > 0
    assert scorecard.shrinkage_loss > 0.0
  end

  test "loss-prevention controls spend cash and reduce future shrinkage risk" do
    state = TcgShop.initial_state(sim_id: "tcg_loss_prevention", seed: 2)

    assert {:ok, secured, _} =
             Updater.apply_event(state, Events.upgrade_loss_prevention("camera_system"), [])

    assert secured.world.bank_balance == 9350.0
    assert secured.world.loss_prevention_score == 28

    assert [
             %{
               control: "camera_system",
               cost: 650.0,
               protection_score: 28,
               type: "loss_prevention_upgrade"
             }
           ] = secured.world.loss_prevention_history

    scorecard = Performance.scorecard(secured.world)
    assert scorecard.loss_prevention_score == 28
    assert scorecard.loss_prevention_spend == 650.0
    assert scorecard.loss_prevention_upgrades == 1

    assert {:ok, rejected, _} =
             Updater.apply_event(secured, Events.upgrade_loss_prevention("camera_system"), [])

    assert rejected.world.invalid_action_count == 1
    assert length(rejected.world.loss_prevention_history) == 1

    inventory =
      Enum.into(state.world.inventory, %{}, fn {line_id, item} ->
        {line_id, Map.put(item, :on_hand, 80)}
      end)

    operations =
      state.world.operations
      |> Map.put(:fatigue, 9)
      |> Map.put(:backlog_tasks, [
        %{day: 1, task: "cycle count"},
        %{day: 1, task: "sort singles"},
        %{day: 1, task: "clean event space"},
        %{day: 1, task: "receive cases"}
      ])

    risky = %{state | world: %{state.world | inventory: inventory, operations: operations}}

    assert {:ok, unprotected, _} =
             Updater.apply_event(risky, Events.wait_next_day("unprotected close"), [])

    assert {:ok, camera, _} =
             Updater.apply_event(risky, Events.upgrade_loss_prevention("camera_system"), [])

    assert {:ok, protected, _} =
             Updater.apply_event(camera, Events.upgrade_loss_prevention("display_case_locks"), [])

    assert {:ok, protected_closed, _} =
             Updater.apply_event(protected, Events.wait_next_day("protected close"), [])

    unprotected_score = Performance.scorecard(unprotected.world)
    protected_score = Performance.scorecard(protected_closed.world)

    assert unprotected_score.shrinkage_units == 28
    assert protected_score.shrinkage_units == 12
    assert protected_score.shrinkage_loss < unprotected_score.shrinkage_loss
    assert protected_score.loss_prevention_score == 46

    assert Enum.all?(
             protected_closed.world.shrinkage_history,
             &(&1.reason == "loss prevention controls missed a high-risk incident")
           )
  end

  test "remaining sealed inventory ages and stale stock is marked down" do
    state = TcgShop.initial_state(sim_id: "tcg_stale_inventory", seed: 2)

    inventory =
      state.world.inventory
      |> Map.update!("dragon_ball_fusion_box", fn item ->
        item
        |> Map.put(:on_hand, 4)
        |> Map.put(:age_days, 8)
        |> Map.put(:price, 140.0)
      end)

    state = %{state | world: %{state.world | inventory: inventory, reputation: 0}}

    assert {:ok, advanced, _} =
             Updater.apply_event(state, Events.wait_next_day("age stale inventory"), [])

    item = advanced.world.inventory["dragon_ball_fusion_box"]
    assert item.age_days >= 9
    assert item.price < 140.0

    assert [markdown] = advanced.world.stale_inventory_history
    assert markdown.line_id == "dragon_ball_fusion_box"
    assert markdown.units == item.on_hand
    assert markdown.markdown_loss > 0.0

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.average_inventory_age_days > 0.0
    assert scorecard.stale_inventory_units >= item.on_hand
    assert scorecard.stale_inventory_markdowns == 1
    assert scorecard.stale_inventory_markdown_loss == markdown.markdown_loss
  end

  test "next-day resolution reprices market and liquidates singles and graded cards" do
    state = TcgShop.initial_state(sim_id: "tcg_singles_liquidity", seed: 9)

    state =
      put_in(state.world.singles_case.graded_cards, [
        %{returned_day: 1, card_count: 2, service_level: "express", market_value: 180.0}
      ])

    before_price = state.world.catalog["pokemon_booster_box"].market_price
    before_raw_cards = state.world.singles_case.cards_on_hand

    assert {:ok, advanced, _} =
             Updater.apply_event(state, Events.wait_next_day("close register"), [])

    assert advanced.world.catalog["pokemon_booster_box"].market_price != before_price
    assert advanced.world.singles_case.cards_on_hand < before_raw_cards
    assert length(advanced.world.singles_sale_history) == 1
    assert length(advanced.world.graded_sale_history) == 1

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.raw_singles_sold > 0
    assert scorecard.graded_cards_sold == 2
  end

  test "collection buys carry condition markdown and authentication risk" do
    state = TcgShop.initial_state(sim_id: "tcg_collection_condition", seed: 8)

    assert {:ok, bought, _} =
             Updater.apply_event(state, Events.buy_collection("One Piece", 650.0, "chase"), [])

    assert [buy] = bought.world.buylist_history
    assert buy.cash_paid == 487.5
    assert buy.store_credit_issued == 195.0
    assert buy.condition_mix.near_mint > 0
    assert buy.authentication_risk_pct > 0
    assert buy.markdown_loss > 0.0
    assert buy.estimated_market_value < 650.0 * 1.45
    assert bought.world.bank_balance == Float.round(state.world.bank_balance - buy.cash_paid, 2)
    assert bought.world.store_credit_liability == buy.store_credit_issued
    assert [%{type: "issued", amount: 195.0}] = bought.world.store_credit_history

    scorecard = Performance.scorecard(bought.world)
    assert scorecard.collection_markdown_loss == buy.markdown_loss
    assert scorecard.store_credit_liability == 195.0
    assert scorecard.store_credit_issued == 195.0
  end

  test "sealed product opening converts inventory into raw singles with EV tracking" do
    state = TcgShop.initial_state(sim_id: "tcg_sealed_opening", seed: 6)
    before_singles = state.world.singles_case

    assert {:ok, opened, _} =
             Updater.apply_event(state, Events.open_sealed_product("pokemon_booster_box", 1), [])

    assert opened.world.inventory["pokemon_booster_box"].on_hand == 3
    assert opened.world.singles_case.cards_on_hand == before_singles.cards_on_hand + 240
    assert opened.world.singles_case.total_market_value == 1863.6

    assert [
             %{
               line_id: "pokemon_booster_box",
               franchise: "Pokemon",
               quantity: 1,
               packs_opened: 24,
               cards_added: 240,
               cost_basis: 94.0,
               sealed_market_value_consumed: 142.0,
               singles_market_value_added: 113.6,
               value_delta_vs_market: -28.4,
               chase_hits: 1
             }
           ] = opened.world.sealed_opening_history

    assert [%{action: "sealed_opening", staff_hours: 1.31}] = opened.world.operations_history
    assert [%{reason: "fresh_singles_from_sealed"}] = opened.world.customer_history

    scorecard = Performance.scorecard(opened.world)
    assert scorecard.sealed_openings == 1
    assert scorecard.sealed_units_opened == 1
    assert scorecard.sealed_packs_opened == 24
    assert scorecard.sealed_opening_cards_added == 240
    assert scorecard.sealed_opening_cost_basis == 94.0
    assert scorecard.sealed_opening_market_value_consumed == 142.0
    assert scorecard.sealed_opening_singles_value == 113.6
    assert scorecard.sealed_opening_value_delta == -28.4
    assert scorecard.sealed_opening_chase_hits == 1
  end

  test "sealed opening rejects non-sealed or unavailable inventory" do
    state = TcgShop.initial_state(sim_id: "tcg_bad_sealed_opening", seed: 6)

    assert {:ok, rejected, _} =
             Updater.apply_event(state, Events.open_sealed_product("card_sleeves", 1), [])

    assert rejected.world.invalid_action_count == 1
    assert rejected.world.sealed_opening_history == []
    assert [%{kind: "action_rejected"}] = rejected.recent_events

    assert {:ok, unavailable, _} =
             Updater.apply_event(state, Events.open_sealed_product("pokemon_booster_box", 12), [])

    assert unavailable.world.invalid_action_count == 1
    assert unavailable.world.inventory["pokemon_booster_box"].on_hand == 4
    assert unavailable.world.sealed_opening_history == []
  end

  test "sealed boxes can be prepared as loose packs and sold through daily traffic" do
    state = TcgShop.initial_state(sim_id: "tcg_loose_packs", seed: 3)
    starting_boxes = state.world.inventory["pokemon_booster_box"].on_hand

    assert {:ok, prepared, _} =
             Updater.apply_event(
               state,
               Events.prepare_loose_packs("pokemon_booster_box", 1, 6.49),
               []
             )

    assert prepared.world.inventory["pokemon_booster_box"].on_hand == starting_boxes - 1

    assert [
             %{
               line_id: "pokemon_booster_box",
               franchise: "Pokemon",
               sealed_units_opened: 1,
               packs_added: 24,
               pack_price: 6.49,
               cost_basis: 94.0,
               market_value: 142.0,
               cost_basis_per_pack: 3.92,
               market_value_per_pack: 5.92
             }
           ] = prepared.world.pack_preparation_history

    assert prepared.world.pack_inventory["pokemon_booster_box"].packs_on_hand == 24
    assert prepared.world.pack_inventory["pokemon_booster_box"].cost_basis_per_pack == 3.92
    assert [%{action: "pack_preparation", staff_hours: 0.49}] = prepared.world.operations_history
    assert [%{reason: "fresh_loose_packs"}] = prepared.world.customer_history

    scorecard = Performance.scorecard(prepared.world)
    assert scorecard.loose_pack_units == 24
    assert scorecard.loose_pack_inventory_value == 142.08
    assert scorecard.loose_pack_preparations == 1
    assert scorecard.loose_pack_units_prepared == 24
    assert scorecard.loose_pack_units_sold == 0
    assert scorecard.loose_pack_revenue == 0.0
    assert scorecard.loose_pack_gross_profit == 0.0

    focused = %{
      prepared
      | world: %{
          prepared.world
          | inventory: %{},
            singles_case: %{cards_on_hand: 0, total_market_value: 0.0, graded_cards: []}
        }
    }

    assert {:ok, advanced, _} =
             Updater.apply_event(focused, Events.wait_next_day("sell loose packs"), [])

    assert [
             %{
               channel: "loose_packs",
               line_id: "pokemon_booster_box",
               quantity: quantity,
               revenue: revenue,
               gross_profit: gross_profit
             }
           ] = advanced.world.pack_sale_history

    assert quantity > 0
    assert revenue > 0
    assert gross_profit > 0
    assert advanced.world.pack_inventory["pokemon_booster_box"].packs_on_hand == 24 - quantity

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.loose_pack_units_sold == quantity
    assert scorecard.loose_pack_revenue == revenue
    assert scorecard.loose_pack_gross_profit == gross_profit
  end

  test "loose pack preparation rejects non-sealed or unavailable inventory" do
    state = TcgShop.initial_state(sim_id: "tcg_bad_loose_packs", seed: 6)

    assert {:ok, rejected, _} =
             Updater.apply_event(state, Events.prepare_loose_packs("card_sleeves", 1, 4.99), [])

    assert rejected.world.invalid_action_count == 1
    assert rejected.world.pack_preparation_history == []
    assert rejected.world.pack_inventory == %{}

    assert {:ok, unavailable, _} =
             Updater.apply_event(
               state,
               Events.prepare_loose_packs("pokemon_booster_box", 12, 6.49),
               []
             )

    assert unavailable.world.invalid_action_count == 1
    assert unavailable.world.inventory["pokemon_booster_box"].on_hand == 4
    assert unavailable.world.pack_preparation_history == []
    assert unavailable.world.pack_inventory == %{}
  end

  test "store credit liability redeems against future walk-in sales" do
    state = TcgShop.initial_state(sim_id: "tcg_store_credit", seed: 8)

    assert {:ok, bought, _} =
             Updater.apply_event(state, Events.buy_collection("Pokemon", 200.0, "mixed"), [])

    assert bought.world.store_credit_liability == 96.0

    assert {:ok, advanced, _} =
             Updater.apply_event(bought, Events.wait_next_day("redeem store credit"), [])

    assert Enum.any?(advanced.world.store_credit_history, &(&1.type == "redeemed"))
    redeemed = Enum.find(advanced.world.store_credit_history, &(&1.type == "redeemed"))
    assert redeemed.amount > 0.0
    assert advanced.world.store_credit_liability == Float.round(96.0 - redeemed.amount, 2)

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.store_credit_redeemed == redeemed.amount
    assert scorecard.store_credit_liability == advanced.world.store_credit_liability
  end

  test "consignment lots sell on commission and create consignor payables" do
    state = TcgShop.initial_state(sim_id: "tcg_consignment", seed: 8)

    assert {:ok, consigned, _} =
             Updater.apply_event(
               state,
               Events.take_consignment("Pokemon", 12, 480.0, 20.0),
               []
             )

    assert [lot] = consigned.world.consignment_lots
    assert lot.cards_remaining == 12
    assert lot.value_remaining == 480.0
    assert consigned.world.bank_balance == state.world.bank_balance
    assert consigned.world.consignment_payable == 0.0
    assert [%{type: "intake"}] = consigned.world.consignment_history

    scorecard = Performance.scorecard(consigned.world)
    assert scorecard.consignment_lots_open == 1
    assert scorecard.consignment_cards_remaining == 12
    assert scorecard.consignment_payable == 0.0

    assert {:ok, sold, _} =
             Updater.apply_event(consigned, Events.wait_next_day("sell consignment"), [])

    assert [sale] = sold.world.consignment_sale_history
    assert sale.channel == "consignment_case"
    assert sale.revenue > 0.0
    assert sale.commission_revenue == Float.round(sale.revenue * 0.2, 2)
    assert sale.consignor_payout == Float.round(sale.revenue - sale.commission_revenue, 2)
    assert sold.world.consignment_payable == sale.consignor_payout

    scorecard = Performance.scorecard(sold.world)
    assert scorecard.consignment_revenue == sale.revenue
    assert scorecard.consignment_commission == sale.commission_revenue
    assert scorecard.consignment_payable == sale.consignor_payout

    assert {:ok, paid, _} =
             Updater.apply_event(sold, Events.wait_next_day("pay consignor"), [])

    assert paid.world.consignment_payable == 0.0
    assert [payout] = paid.world.consignment_payout_history
    assert payout.amount_paid >= sale.consignor_payout
    assert Performance.scorecard(paid.world).consignment_payouts_paid == payout.amount_paid
  end

  test "memberships collect cash, defer liability, and recognize over time" do
    state = TcgShop.initial_state(sim_id: "tcg_memberships", seed: 5)

    assert {:ok, sold, _} =
             Updater.apply_event(state, Events.sell_memberships("Pokemon", 10, 30.0, 3), [])

    assert [batch] = sold.world.active_memberships
    assert batch.member_count == 10
    assert batch.remaining_days == 3
    assert batch.remaining_value == 300.0
    assert sold.world.membership_liability == 300.0
    assert [%{type: "sold", collected: 300.0}] = sold.world.membership_history

    fee = Enum.find(sold.world.transaction_cost_history, &(&1.source == "membership_sale"))
    tender = Enum.find(sold.world.cash_handling_history, &(&1.source == "membership_sale"))

    tax_tender =
      Enum.find(sold.world.cash_handling_history, &(&1.source == "membership_sale_tax"))

    assert fee.processing_fee == 8.02
    assert tender.cash_amount > 0.0
    assert tax_tender.cash_amount > 0.0

    assert sold.world.bank_balance ==
             Float.round(
               state.world.bank_balance + tender.card_amount + tax_tender.card_amount -
                 fee.total_cost,
               2
             )

    scorecard = Performance.scorecard(sold.world)
    assert scorecard.active_memberships == 10
    assert scorecard.active_membership_batches == 1
    assert scorecard.membership_liability == 300.0
    assert scorecard.membership_revenue_collected == 300.0
    assert scorecard.membership_revenue_recognized == 0.0

    assert {:ok, advanced, _} =
             Updater.apply_event(sold, Events.wait_next_day("serve memberships"), [])

    assert [updated_batch] = advanced.world.active_memberships
    assert updated_batch.remaining_days == 2
    assert updated_batch.remaining_value == 200.0
    assert advanced.world.membership_liability == 200.0
    assert Enum.any?(advanced.world.membership_history, &(&1.type == "recognized"))

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.membership_revenue_recognized == 100.0
    assert scorecard.membership_liability == 200.0
    assert scorecard.active_memberships == 10
  end

  test "grading returns grade mix and authentication failures from risky submissions" do
    state = TcgShop.initial_state(sim_id: "tcg_grading_risk", seed: 8)

    assert {:ok, bought, _} =
             Updater.apply_event(state, Events.buy_collection("One Piece", 650.0, "chase"), [])

    assert {:ok, submitted, _} =
             Updater.apply_event(bought, Events.submit_grading(20, "express"), [])

    [%{return_day: return_day}] = submitted.world.pending_grading

    advanced =
      Enum.reduce(1..return_day, submitted, fn _, acc ->
        {:ok, next, _} = Updater.apply_event(acc, Events.wait_next_day("wait for grading"), [])
        next
      end)

    assert advanced.world.pending_grading == []
    assert [result] = advanced.world.grading_result_history
    assert result.grade_mix.gem_mint > 0
    assert result.authenticated_failures > 0
    assert [loss] = advanced.world.authentication_loss_history
    assert loss.card_count == result.authenticated_failures

    scorecard = Performance.scorecard(advanced.world)
    assert scorecard.authenticated_failures == result.authenticated_failures
    assert scorecard.authentication_loss == loss.raw_value_lost
    assert scorecard.gem_mint_cards == result.grade_mix.gem_mint
  end

  test "damaged distributor deliveries can be claimed against supplier invoices" do
    state = TcgShop.initial_state(sim_id: "tcg_supplier_claim", seed: 2)

    delivery = %{
      day: 1,
      line_id: "one_piece_booster_box",
      requested_quantity: 4,
      quantity: 4,
      unit_cost: 74.0,
      cost: 296.0,
      delivery_day: 2,
      invoice_id: "claim_invoice_1",
      invoice_due_day: 9,
      payment_terms_days: 7,
      payment_status: "invoiced",
      supplier: "premium_secondary",
      supplier_standing: 55,
      allocation_rate: 1.0,
      allocation_note: "test case delivery"
    }

    invoice = %{
      id: "claim_invoice_1",
      day: 1,
      supplier: "premium_secondary",
      line_id: "one_piece_booster_box",
      amount_original: 296.0,
      amount_due: 296.0,
      due_day: 9,
      payment_terms_days: 7,
      status: "open",
      type: "created",
      late_fee_total: 0.0
    }

    state = %{
      state
      | world: %{
          state.world
          | pending_deliveries: [delivery],
            pending_supplier_invoices: [invoice],
            supplier_invoice_history: [invoice]
        }
    }

    assert {:ok, received, _} =
             Updater.apply_event(state, Events.wait_next_day("receive damaged case"), [])

    assert [
             %{
               invoice_id: "claim_invoice_1",
               ordered_quantity: 4,
               received_quantity: 3,
               damaged_units: 1,
               claimed_units: 0,
               claim_status: "unclaimed",
               damage_value: 74.0
             }
           ] = received.world.delivery_receipt_history

    assert {:ok, claimed, _} =
             Updater.apply_event(received, Events.file_supplier_claim("claim_invoice_1", 1), [])

    assert [
             %{
               invoice_id: "claim_invoice_1",
               damaged_units: 1,
               claim_amount: 74.0,
               settlement: "invoice_credit"
             }
           ] = claimed.world.supplier_claim_history

    assert [%{amount_due: 222.0, claim_credit_total: 74.0}] =
             claimed.world.pending_supplier_invoices

    assert Enum.any?(
             claimed.world.supplier_invoice_history,
             &(&1.type == "credit_memo" and &1.amount == 74.0)
           )

    assert [
             %{
               claim_status: "claimed",
               claimed_units: 1,
               claim_amount: 74.0
             }
           ] = claimed.world.delivery_receipt_history

    scorecard = Performance.scorecard(claimed.world)
    assert scorecard.damaged_delivery_units == 1
    assert scorecard.damaged_delivery_value == 74.0
    assert scorecard.supplier_damage_claims == 1
    assert scorecard.supplier_claim_credits == 74.0

    assert {:ok, rejected, _} =
             Updater.apply_event(claimed, Events.file_supplier_claim("claim_invoice_1", 1), [])

    assert rejected.world.invalid_action_count == claimed.world.invalid_action_count + 1
    assert length(rejected.world.supplier_claim_history) == 1
  end

  test "invalid orders become benchmark-visible rejections" do
    state = TcgShop.initial_state(sim_id: "tcg_reject", starting_balance: 100.0)

    assert {:ok, result, _} =
             Updater.apply_event(
               state,
               Events.order_product_line("card_sleeves", 2_000),
               []
             )

    assert result.world.invalid_action_count == 1
    assert [%{kind: "action_rejected"}] = result.recent_events
    assert result.world.bank_balance == 100.0
  end

  test "performance scorecard includes inventory, singles, grading, and ROI" do
    world = TcgShop.initial_world(seed: 5)
    scorecard = Performance.scorecard(world)

    assert scorecard.net_worth > world.bank_balance
    assert scorecard.cash_drawer_balance == 350.0
    assert scorecard.cash_tender_sales == 0.0
    assert scorecard.card_tender_sales == 0.0
    assert scorecard.bank_deposits == 0.0
    assert scorecard.cash_reconciliations == 0
    assert scorecard.cash_over_short == 0.0
    assert scorecard.cash_shortage_loss == 0.0
    assert scorecard.cash_overage_gain == 0.0
    assert scorecard.cash_handling_events == 0
    assert scorecard.inventory_value > 0
    assert scorecard.average_inventory_age_days == 5.12
    assert scorecard.stale_inventory_units == 0
    assert scorecard.stale_inventory_markdowns == 0
    assert scorecard.stale_inventory_markdown_loss == 0.0
    assert scorecard.singles_value > 0
    assert is_float(scorecard.roi_pct)
    assert scorecard.stockout_events == 0
    assert scorecard.online_backorders == 0
    assert scorecard.supplier_fill_rate_pct == 100.0
    assert scorecard.sales_revenue == 0.0
    assert scorecard.net_sales_revenue == 0.0
    assert scorecard.cost_of_goods_sold == 0.0
    assert scorecard.gross_profit == 0.0
    assert scorecard.gross_margin_pct == 0.0
    assert scorecard.fixed_overhead == 0.0
    assert scorecard.rent_expense == 0.0
    assert scorecard.utilities_expense == 0.0
    assert scorecard.insurance_expense == 0.0
    assert scorecard.operating_expenses == 0.0
    assert scorecard.operating_profit == 0.0
    assert scorecard.net_profit_after_financing == 0.0
    assert scorecard.refund_amount == 0.0
    assert scorecard.refund_count == 0
    assert scorecard.chargeback_count == 0
    assert scorecard.customer_returns == 0
    assert scorecard.returned_units == 0
    assert scorecard.return_refunds == 0.0
    assert scorecard.returned_inventory_units == 0
    assert scorecard.return_cogs_recovered == 0.0
    assert scorecard.return_writeoff_loss == 0.0
    assert scorecard.return_store_credit == 0.0
    assert scorecard.return_cash_refunds == 0.0
    assert scorecard.average_customer_satisfaction > 0
    assert scorecard.authenticated_failures == 0
    assert scorecard.local_market_share_pct == 34.0
    assert scorecard.competitor_pressure == 0
    assert scorecard.price_reputation == "fair"
    assert scorecard.preorder_deposits == 0.0
    assert scorecard.preorder_liability == 0.0
    assert scorecard.pending_preorder_units == 0
    assert scorecard.special_order_liability == 0.0
    assert scorecard.special_order_deposits == 0.0
    assert scorecard.special_order_revenue == 0.0
    assert scorecard.special_order_units_fulfilled == 0
    assert scorecard.special_order_units_short == 0
    assert scorecard.pending_special_order_units == 0
    assert scorecard.marketing_spend == 0.0
    assert scorecard.promoted_units_sold == 0
    assert scorecard.sales_tax_liability == 0.0
    assert scorecard.store_credit_liability == 0.0
    assert scorecard.store_credit_issued == 0.0
    assert scorecard.store_credit_redeemed == 0.0
    assert scorecard.consignment_payable == 0.0
    assert scorecard.membership_liability == 0.0
    assert scorecard.credit_line_balance == 0.0
    assert scorecard.credit_line_limit == 3000.0
    assert scorecard.credit_line_available == 3000.0
    assert scorecard.credit_line_draws == 0.0
    assert scorecard.credit_line_repayments == 0.0
    assert scorecard.credit_line_interest == 0.0
    assert scorecard.active_memberships == 0
    assert scorecard.active_membership_batches == 0
    assert scorecard.membership_revenue_collected == 0.0
    assert scorecard.membership_revenue_recognized == 0.0
    assert scorecard.consignment_lots_open == 0
    assert scorecard.consignment_cards_remaining == 0
    assert scorecard.consignment_revenue == 0.0
    assert scorecard.consignment_commission == 0.0
    assert scorecard.consignment_payouts_paid == 0.0
    assert scorecard.event_attendance == 0
    assert scorecard.event_capacity_utilization_pct == 0.0
    assert scorecard.event_turn_aways == 0
    assert scorecard.event_no_shows == 0
    assert scorecard.sanctioned_events == 0
    assert scorecard.event_prize_value == 0.0
    assert scorecard.event_prize_inventory_cost == 0.0
    assert scorecard.event_prize_store_credit == 0.0
    assert scorecard.event_judge_cost == 0.0
    assert scorecard.event_sanction_fees == 0.0
    assert scorecard.event_operating_cost == 0.0
    assert scorecard.sales_tax_collected == 0.0
    assert scorecard.sales_tax_remitted == 0.0
    assert scorecard.accounts_payable == 0.0
    assert scorecard.supplier_invoices_open == 0
    assert scorecard.supplier_invoices_overdue == 0
    assert scorecard.supplier_invoices_paid == 0.0
    assert scorecard.supplier_late_fees == 0.0
    assert scorecard.supplier_credit_available == 2500.0
    assert scorecard.supplier_credit_limit_effective == 2500.0
    assert scorecard.average_supplier_standing == 55.0
    assert scorecard.preferred_supplier_accounts == 0
    assert scorecard.strained_supplier_accounts == 0
    assert scorecard.supplier_account_events == 0
    assert scorecard.damaged_delivery_units == 0
    assert scorecard.damaged_delivery_value == 0.0
    assert scorecard.supplier_damage_claims == 0
    assert scorecard.supplier_claim_credits == 0.0
    assert scorecard.payment_processing_fees == 0.0
    assert scorecard.shipping_label_cost == 0.0
    assert scorecard.marketplace_fees == 0.0
    assert scorecard.online_channel_updates == 0
    assert scorecard.online_channel_setup_spend == 0.0
    assert scorecard.online_channel_platform == "local_pickup"
    assert scorecard.online_listing_quality == "basic"
    assert scorecard.packing_supply_cost == 0.0
    assert scorecard.channel_costs == 0.0
    assert scorecard.payroll_paid_hours == 0.0
    assert scorecard.regular_payroll == 0.0
    assert scorecard.scheduled_staff_shifts == 0
    assert scorecard.scheduled_staff_hours == 0.0
    assert scorecard.scheduled_staff_hours_used == 0.0
    assert scorecard.scheduled_staff_cost == 0.0
    assert scorecard.total_labor_cost == 0.0
    assert scorecard.shrinkage_units == 0
    assert scorecard.shrinkage_loss == 0.0
    assert scorecard.loss_prevention_score == 0
    assert scorecard.loss_prevention_spend == 0.0
    assert scorecard.loss_prevention_upgrades == 0
    assert scorecard.sealed_openings == 0
    assert scorecard.sealed_units_opened == 0
    assert scorecard.sealed_packs_opened == 0
    assert scorecard.sealed_opening_cards_added == 0
    assert scorecard.sealed_opening_cost_basis == 0
    assert scorecard.sealed_opening_market_value_consumed == 0
    assert scorecard.sealed_opening_singles_value == 0
    assert scorecard.sealed_opening_value_delta == 0
    assert scorecard.sealed_opening_chase_hits == 0
    assert scorecard.loose_pack_units == 0
    assert scorecard.loose_pack_inventory_value == 0.0
    assert scorecard.loose_pack_preparations == 0
    assert scorecard.loose_pack_units_prepared == 0
    assert scorecard.loose_pack_units_sold == 0
    assert scorecard.loose_pack_revenue == 0.0
    assert scorecard.loose_pack_gross_profit == 0.0
    assert scorecard.active_failure_mode_count == 0
    assert scorecard.failure_modes == []
  end

  test "offline baseline writes verifiable benchmark artifacts" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "tcg_baseline_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state, artifacts: artifacts, steps: steps}} =
             OfflineRunner.run_strategy("baseline",
               sim_id: "tcg_baseline_test",
               max_days: 5,
               driver_max_turns: 20,
               seed: 3,
               artifact_dir: artifact_dir
             )

    assert state.world.status == "complete"
    assert steps > 0
    assert File.exists?(artifacts.final_world)
    assert File.exists?(artifacts.replay_html)
    assert File.exists?(artifacts.counterparty_transcript)

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "tcg_shop"
    assert verified.scorecard["status"] == "complete"
    assert verified.scorecard["net_worth"] > 0

    assert File.read!(artifacts.report) =~ "TCG Shop Offline Baseline Report"
    assert File.read!(artifacts.report) =~ "Counterparty transcript"
    assert File.read!(artifacts.replay_html) =~ "TCG Shop Replay"

    transcript = artifacts.counterparty_transcript |> File.read!() |> Jason.decode!()
    assert transcript["schema_version"] == "tcg_shop.counterparties.v1"
    assert is_list(transcript["market_research"])
    assert is_map(transcript["suppliers"])
    assert is_map(transcript["customers"])
    assert is_map(transcript["staff"])
  end

  test "offline deterministic artifact mode is byte-reproducible across output directories" do
    artifact_dir_a =
      Path.join(System.tmp_dir!(), "tcg_repro_a_#{System.unique_integer([:positive])}")

    artifact_dir_b =
      Path.join(System.tmp_dir!(), "tcg_repro_b_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(artifact_dir_a)
      File.rm_rf!(artifact_dir_b)
    end)

    run_opts = [
      sim_id: "tcg_repro_test",
      max_days: 3,
      seed: 13,
      driver_max_turns: 10,
      deterministic_artifacts?: true
    ]

    assert {:ok, _} =
             OfflineRunner.run_strategy(
               "baseline",
               Keyword.put(run_opts, :artifact_dir, artifact_dir_a)
             )

    assert {:ok, _} =
             OfflineRunner.run_strategy(
               "baseline",
               Keyword.put(run_opts, :artifact_dir, artifact_dir_b)
             )

    bundle_a = deterministic_bundle(artifact_dir_a)
    bundle_b = deterministic_bundle(artifact_dir_b)

    assert bundle_a.hashes == bundle_b.hashes
    assert bundle_a.manifest == bundle_b.manifest
    assert bundle_a.report == bundle_b.report
    assert bundle_a.replay == bundle_b.replay

    assert get_in(bundle_a.manifest, ["runtime", "started_at"]) == "1970-01-01T00:00:00Z"
    assert get_in(bundle_a.manifest, ["runtime", "finished_at"]) == "1970-01-01T00:00:00Z"
    refute bundle_a.report =~ artifact_dir_a
    refute bundle_b.report =~ artifact_dir_b

    assert {:ok, _} = Verifier.verify_run(artifact_dir_a)
    assert {:ok, _} = Verifier.verify_run(artifact_dir_b)
  end

  test "offline pressure strategy exercises buylist, grading, events, and market research" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "tcg_pressure_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state}} =
             OfflineRunner.run_strategy(:pressure,
               sim_id: "tcg_pressure_test",
               max_days: 12,
               driver_max_turns: 40,
               seed: 8,
               artifact_dir: artifact_dir
             )

    assert length(state.world.buylist_history) > 0
    assert length(state.world.grading_history) > 0
    assert length(state.world.tournament_history) > 0
    assert length(state.world.research_history) > 0
    assert length(state.world.sealed_opening_history) > 0
    assert length(state.world.pack_preparation_history) > 0
    assert length(state.world.pack_sale_history) > 0
    assert length(state.world.special_order_history) > 0
    assert length(state.world.special_order_fulfillment_history) > 0
    assert length(state.world.staffing_history) > 0
    assert length(state.world.loss_prevention_history) > 0
    assert length(state.world.online_channel_history) > 0
    assert length(state.world.delivery_receipt_history) > 0
    assert length(state.world.supplier_claim_history) > 0
    assert length(state.world.return_history) > 0
    assert length(state.world.cash_handling_history) > 0
    assert Enum.any?(state.world.cash_handling_history, &(&1.type == "bank_deposit"))
    assert Enum.any?(state.world.cash_handling_history, &(&1.type == "cash_reconciliation"))

    scorecard = Performance.scorecard(state.world)
    assert scorecard.events_hosted > 0
    assert scorecard.grading_submissions > 0
    assert scorecard.sealed_openings > 0
    assert scorecard.loose_pack_preparations > 0
    assert scorecard.loose_pack_units_prepared > 0
    assert scorecard.loose_pack_units_sold > 0
    assert scorecard.loose_pack_revenue > 0
    assert scorecard.loose_pack_gross_profit > 0
    assert scorecard.special_order_deposits > 0
    assert scorecard.special_order_revenue > 0
    assert scorecard.special_order_units_fulfilled > 0
    assert scorecard.scheduled_staff_shifts > 0
    assert scorecard.loss_prevention_upgrades > 0
    assert scorecard.online_channel_updates > 0
    assert scorecard.marketplace_fees > 0
    assert scorecard.damaged_delivery_units > 0
    assert scorecard.supplier_damage_claims > 0
    assert scorecard.supplier_claim_credits > 0
    assert scorecard.customer_returns > 0
    assert scorecard.returned_units > 0
    assert scorecard.return_refunds > 0
    assert scorecard.cash_tender_sales > 0
    assert scorecard.card_tender_sales > 0
    assert scorecard.bank_deposits > 0
    assert scorecard.cash_reconciliations > 0
    assert scorecard.cash_shortage_loss + scorecard.cash_overage_gain > 0.0

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.scorecard["events_hosted"] > 0
    assert verified.scorecard["sealed_openings"] > 0
    assert verified.scorecard["loose_pack_preparations"] > 0
    assert verified.scorecard["loose_pack_units_prepared"] > 0
    assert verified.scorecard["loose_pack_units_sold"] > 0
    assert verified.scorecard["loose_pack_revenue"] > 0
    assert verified.scorecard["loose_pack_gross_profit"] > 0
    assert verified.scorecard["special_order_deposits"] > 0
    assert verified.scorecard["special_order_revenue"] > 0
    assert verified.scorecard["special_order_units_fulfilled"] > 0
    assert verified.scorecard["scheduled_staff_shifts"] > 0
    assert verified.scorecard["loss_prevention_upgrades"] > 0
    assert verified.scorecard["online_channel_updates"] > 0
    assert verified.scorecard["marketplace_fees"] > 0
    assert verified.scorecard["damaged_delivery_units"] > 0
    assert verified.scorecard["supplier_damage_claims"] > 0
    assert verified.scorecard["supplier_claim_credits"] > 0
    assert verified.scorecard["customer_returns"] > 0
    assert verified.scorecard["returned_units"] > 0
    assert verified.scorecard["return_refunds"] > 0
    assert verified.scorecard["cash_tender_sales"] > 0
    assert verified.scorecard["card_tender_sales"] > 0
    assert verified.scorecard["bank_deposits"] > 0
    assert verified.scorecard["cash_reconciliations"] > 0

    assert verified.scorecard["cash_shortage_loss"] + verified.scorecard["cash_overage_gain"] >
             0.0
  end

  test "offline overextended strategy surfaces realistic failure modes" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "tcg_overextended_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state, artifacts: artifacts}} =
             OfflineRunner.run_strategy(:overextended,
               sim_id: "tcg_overextended_test",
               max_days: 10,
               driver_max_turns: 80,
               seed: 8,
               artifact_dir: artifact_dir
             )

    scorecard = Performance.scorecard(state.world)
    failure_ids = Enum.map(scorecard.failure_modes, & &1.id)

    assert scorecard.active_failure_mode_count > 0
    assert "negative_operating_profit" in failure_ids
    assert "customer_trust_damage" in failure_ids or "stockout_damage" in failure_ids
    assert scorecard.operating_profit < 0.0

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.scorecard["active_failure_mode_count"] > 0
    assert File.exists?(artifacts.counterparty_transcript)
  end

  test "mix task can run a deterministic TCG shop artifact bundle" do
    artifact_dir = Path.join(System.tmp_dir!(), "tcg_mix_#{System.unique_integer([:positive])}")

    Mix.Tasks.Lemon.Sim.TcgShop.run([
      "--preset",
      "ci",
      "--offline-strategy",
      "baseline",
      "--sim-id",
      "tcg_mix_test",
      "--artifact-dir",
      artifact_dir
    ])

    assert File.exists?(Path.join(artifact_dir, "manifest.json"))
    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "tcg_shop"
  end

  defp fake_model(id) do
    %Model{
      id: id,
      name: id,
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp deterministic_bundle(artifact_dir) do
    %{
      hashes: artifact_json(artifact_dir, "hashes.json"),
      manifest: artifact_json(artifact_dir, "manifest.json"),
      replay: artifact_json(artifact_dir, "replay.json"),
      report: artifact_text(artifact_dir, "report.md")
    }
  end

  defp artifact_json(artifact_dir, file) do
    artifact_dir
    |> artifact_text(file)
    |> Jason.decode!()
  end

  defp artifact_text(artifact_dir, file) do
    artifact_dir
    |> Path.join(file)
    |> File.read!()
  end

  defp tool_call(name, arguments) do
    %ToolCall{
      type: :tool_call,
      id: "call_#{name}_#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments
    }
  end
end
