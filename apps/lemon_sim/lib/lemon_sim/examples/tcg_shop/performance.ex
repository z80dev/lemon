defmodule LemonSim.Examples.TcgShop.Performance do
  @moduledoc false

  alias LemonCore.MapHelpers

  @behaviour LemonSim.Bench.Scorecard

  @impl true
  def primary_metric, do: %{key: "net_worth", direction: :maximize}

  @impl true
  def scorecard(world) do
    balance = get(world, :bank_balance, 0.0)
    cash_drawer = get(world, :cash_drawer_balance, 0.0)
    inventory_value = inventory_value(world)
    singles = get(world, :singles_case, %{})
    singles_value = get(singles, :total_market_value, 0.0)
    graded_value = graded_value(singles)
    preorder_liability = preorder_liability(world)
    special_order_liability = get(world, :special_order_liability, 0.0)
    sales_tax_liability = get(world, :sales_tax_liability, 0.0)
    store_credit_liability = get(world, :store_credit_liability, 0.0)
    consignment_payable = get(world, :consignment_payable, 0.0)
    membership_liability = get(world, :membership_liability, 0.0)
    credit_line_balance = get(world, :credit_line_balance, 0.0)
    accounts_payable = accounts_payable(world)

    net_worth =
      balance + cash_drawer + inventory_value + singles_value + graded_value - preorder_liability -
        special_order_liability - sales_tax_liability - store_credit_liability -
        consignment_payable -
        membership_liability - credit_line_balance - accounts_payable

    starting_balance =
      get(world, :starting_balance, 10_000.0) + get(world, :starting_cash_drawer_balance, 0.0)

    base = %{
      bank_balance: round_money(balance),
      cash_drawer_balance: round_money(cash_drawer),
      cash_tender_sales: round_money(cash_handling_total(world, :cash_amount, "tender_split")),
      card_tender_sales: round_money(cash_handling_total(world, :card_amount, "tender_split")),
      bank_deposits: round_money(cash_handling_total(world, :amount, "bank_deposit")),
      cash_reconciliations: length(cash_reconciliation_entries(world)),
      cash_over_short: round_money(cash_reconciliation_total(world, :over_short_amount)),
      cash_shortage_loss: round_money(cash_reconciliation_total(world, :shortage_amount)),
      cash_overage_gain: round_money(cash_reconciliation_total(world, :overage_amount)),
      cash_handling_events: length(get(world, :cash_handling_history, [])),
      inventory_value: round_money(inventory_value),
      average_inventory_age_days: average_inventory_age_days(world),
      stale_inventory_units: stale_inventory_units(world),
      stale_inventory_markdowns: length(get(world, :stale_inventory_history, [])),
      stale_inventory_markdown_loss: round_money(stale_inventory_markdown_loss(world)),
      singles_value: round_money(singles_value),
      graded_value: round_money(graded_value),
      preorder_liability: round_money(preorder_liability),
      special_order_liability: round_money(special_order_liability),
      sales_tax_liability: round_money(sales_tax_liability),
      store_credit_liability: round_money(store_credit_liability),
      consignment_payable: round_money(consignment_payable),
      membership_liability: round_money(membership_liability),
      credit_line_balance: round_money(credit_line_balance),
      credit_line_limit: round_money(get(world, :credit_line_limit, 0.0)),
      credit_line_available:
        round_money(max(0.0, get(world, :credit_line_limit, 0.0) - credit_line_balance)),
      credit_line_draws: round_money(debt_total(world, "draw")),
      credit_line_repayments: round_money(debt_total(world, "repay")),
      credit_line_interest: round_money(debt_total(world, "interest")),
      accounts_payable: round_money(accounts_payable),
      net_worth: round_money(net_worth),
      roi_pct: round_money((net_worth - starting_balance) / starting_balance * 100.0),
      reputation: get(world, :reputation, 50),
      online_rating: get(world, :online_rating, 4.3),
      sell_through_units: sell_through_units(world),
      sales_revenue: round_money(sales_revenue(world)),
      net_sales_revenue: round_money(sales_revenue(world) - refund_amount(world)),
      cost_of_goods_sold: round_money(cost_of_goods_sold(world)),
      gross_profit: round_money(gross_profit(world)),
      gross_margin_pct: gross_margin_pct(world),
      fixed_overhead: round_money(fixed_overhead(world)),
      rent_expense: round_money(overhead_total(world, :rent)),
      utilities_expense: round_money(overhead_total(world, :utilities)),
      insurance_expense: round_money(overhead_total(world, :insurance)),
      operating_expenses: round_money(operating_expenses(world)),
      operating_profit: round_money(operating_profit(world)),
      net_profit_after_financing:
        round_money(operating_profit(world) - debt_total(world, "interest")),
      refund_amount: round_money(refund_amount(world)),
      refund_count: length(get(world, :refund_history, [])),
      chargeback_count: chargeback_count(world),
      customer_returns: length(get(world, :return_history, [])),
      returned_units: return_total(world, :quantity),
      return_refunds: round_money(return_total(world, :refund_amount)),
      returned_inventory_units: return_total(world, :restocked_units),
      return_cogs_recovered: round_money(return_total(world, :cogs_recovered)),
      return_writeoff_loss: round_money(return_total(world, :writeoff_loss)),
      return_store_credit: round_money(return_resolution_total(world, "store_credit")),
      return_cash_refunds: round_money(return_resolution_total(world, "cash_refund")),
      events_hosted: length(get(world, :tournament_history, [])),
      event_attendance: event_total(world, :attendance),
      event_capacity_utilization_pct: event_capacity_utilization_pct(world),
      event_turn_aways: event_total(world, :turn_aways),
      event_no_shows: event_total(world, :no_shows),
      sanctioned_events: sanctioned_events(world),
      event_prize_value: round_money(event_total(world, :prize_fulfilled_value)),
      event_prize_inventory_cost: round_money(event_total(world, :prize_inventory_cost)),
      event_prize_store_credit: round_money(event_total(world, :prize_store_credit_issued)),
      event_judge_cost: round_money(event_total(world, :judge_cost)),
      event_sanction_fees: round_money(event_total(world, :sanction_fee)),
      event_operating_cost: round_money(event_total(world, :operating_cost)),
      grading_submissions: length(get(world, :grading_history, [])),
      grading_results: length(get(world, :grading_result_history, [])),
      authenticated_failures: authenticated_failures(world),
      authentication_loss: round_money(authentication_loss(world)),
      collection_markdown_loss: round_money(collection_markdown_loss(world)),
      sealed_openings: length(get(world, :sealed_opening_history, [])),
      sealed_units_opened: sealed_opening_total(world, :quantity),
      sealed_packs_opened: sealed_opening_total(world, :packs_opened),
      sealed_opening_cards_added: sealed_opening_total(world, :cards_added),
      sealed_opening_cost_basis: round_money(sealed_opening_total(world, :cost_basis)),
      sealed_opening_market_value_consumed:
        round_money(sealed_opening_total(world, :sealed_market_value_consumed)),
      sealed_opening_singles_value:
        round_money(sealed_opening_total(world, :singles_market_value_added)),
      sealed_opening_value_delta:
        round_money(sealed_opening_total(world, :value_delta_vs_market)),
      sealed_opening_chase_hits: sealed_opening_total(world, :chase_hits),
      loose_pack_units: loose_pack_units(world),
      loose_pack_inventory_value: round_money(loose_pack_inventory_value(world)),
      loose_pack_preparations: length(get(world, :pack_preparation_history, [])),
      loose_pack_units_prepared: pack_preparation_total(world, :packs_added),
      loose_pack_units_sold: sold_units(get(world, :pack_sale_history, [])),
      loose_pack_revenue: round_money(pack_sale_total(world, :revenue)),
      loose_pack_gross_profit: round_money(pack_sale_total(world, :gross_profit)),
      store_credit_issued: round_money(store_credit_total(world, "issued")),
      store_credit_redeemed: round_money(store_credit_total(world, "redeemed")),
      gem_mint_cards: grade_count(world, :gem_mint),
      mint_cards: grade_count(world, :mint),
      raw_singles_sold: sold_units(get(world, :singles_sale_history, [])),
      consignment_lots_open: consignment_lots_open(world),
      consignment_cards_remaining: consignment_cards_remaining(world),
      consignment_revenue: round_money(consignment_revenue(world)),
      consignment_commission: round_money(consignment_commission(world)),
      consignment_payouts_paid: round_money(consignment_payouts_paid(world)),
      active_memberships: active_memberships(world),
      active_membership_batches: active_membership_batches(world),
      membership_revenue_collected: round_money(membership_total(world, "sold", :collected)),
      membership_revenue_recognized:
        round_money(membership_total(world, "recognized", :revenue_recognized)),
      graded_cards_sold: sold_units(get(world, :graded_sale_history, [])),
      preorder_deposits: round_money(preorder_deposits(world)),
      preorder_revenue: round_money(preorder_revenue(world)),
      preorder_units_fulfilled: preorder_units_fulfilled(world),
      preorder_units_short: preorder_units_short(world),
      pending_preorder_units: pending_preorder_units(world),
      special_order_deposits: round_money(special_order_deposits(world)),
      special_order_revenue: round_money(special_order_revenue(world)),
      special_order_units_fulfilled: special_order_units_fulfilled(world),
      special_order_units_short: special_order_units_short(world),
      pending_special_order_units: pending_special_order_units(world),
      marketing_spend: round_money(marketing_spend(world)),
      active_promotions: length(get(world, :active_promotions, [])),
      promoted_units_sold: promoted_units_sold(world),
      promoted_revenue: round_money(promoted_revenue(world)),
      taxable_sales: round_money(taxable_sales(world)),
      sales_tax_collected: round_money(sales_tax_collected(world)),
      sales_tax_remitted: round_money(sales_tax_remitted(world)),
      payment_processing_fees: round_money(payment_processing_fees(world)),
      shipping_label_cost: round_money(shipping_label_cost(world)),
      marketplace_fees: round_money(marketplace_fees(world)),
      online_channel_updates: length(get(world, :online_channel_history, [])),
      online_channel_setup_spend: round_money(online_channel_setup_spend(world)),
      online_channel_platform: get(get(world, :online_channel, %{}), :platform, "local_pickup"),
      online_listing_quality: get(get(world, :online_channel, %{}), :listing_quality, "basic"),
      packing_supply_cost: round_money(packing_supply_cost(world)),
      channel_costs: round_money(channel_costs(world)),
      stockout_events: length(get(world, :stockout_history, [])),
      stockout_units: stockout_units(world),
      shrinkage_units: shrinkage_units(world),
      shrinkage_loss: round_money(shrinkage_loss(world)),
      loss_prevention_score: get(world, :loss_prevention_score, 0),
      loss_prevention_spend: round_money(loss_prevention_spend(world)),
      loss_prevention_upgrades: length(get(world, :loss_prevention_history, [])),
      service_issues: length(get(world, :service_issue_history, [])),
      online_backorders: online_backorders(world),
      supplier_fill_rate_pct: supplier_fill_rate_pct(world),
      allocation_shortfalls: allocation_shortfalls(world),
      supplier_invoices_open: length(get(world, :pending_supplier_invoices, [])),
      supplier_invoices_overdue: supplier_invoices_overdue(world),
      supplier_invoices_paid: round_money(supplier_invoices_paid(world)),
      supplier_late_fees: round_money(supplier_late_fees(world)),
      supplier_credit_used: round_money(accounts_payable),
      supplier_credit_available: round_money(supplier_credit_available(world)),
      supplier_credit_limit_effective: round_money(effective_supplier_credit_limit(world)),
      average_supplier_standing: average_supplier_standing(world),
      preferred_supplier_accounts: supplier_account_count(world, "preferred"),
      strained_supplier_accounts: supplier_account_count(world, "strained"),
      supplier_account_events: length(get(world, :supplier_account_history, [])),
      damaged_delivery_units: delivery_receipt_total(world, :damaged_units),
      damaged_delivery_value: round_money(delivery_receipt_total(world, :damage_value)),
      supplier_damage_claims: length(get(world, :supplier_claim_history, [])),
      supplier_claim_credits: round_money(supplier_claim_total(world, :claim_amount)),
      staff_hours_used: staff_hours_used(world),
      scheduled_staff_shifts: length(get(world, :staffing_history, [])),
      scheduled_staff_hours: round_money(staffing_total(world, :hours)),
      scheduled_staff_hours_used: scheduled_staff_hours_used(world),
      scheduled_staff_cost: round_money(staffing_total(world, :labor_cost)),
      payroll_paid_hours: payroll_paid_hours(world),
      regular_payroll: round_money(regular_payroll(world)),
      overtime_hours: operations_metric(world, :cumulative_overtime_hours),
      overtime_cost: operations_metric(world, :cumulative_overtime_cost),
      total_labor_cost:
        round_money(
          regular_payroll(world) + operations_metric(world, :cumulative_overtime_cost) +
            staffing_total(world, :labor_cost)
        ),
      fatigue: operations_metric(world, :fatigue),
      backlog_tasks: length(get(get(world, :operations, %{}), :backlog_tasks, [])),
      average_customer_loyalty: average_customer_metric(world, :loyalty),
      average_customer_satisfaction: average_customer_metric(world, :satisfaction),
      at_risk_customer_segments: at_risk_customer_segments(world),
      customer_visits: customer_total(world, :visits),
      customer_lifetime_spend: round_money(customer_total(world, :lifetime_spend)),
      local_market_share_pct: competitive_metric(world, :local_market_share_pct, 34.0),
      competitor_pressure: competitive_metric(world, :competitor_pressure, 0.0),
      price_reputation: competitive_metric(world, :price_reputation, "fair"),
      competitor_reactions: length(get(world, :competitor_history, [])),
      rejections: get(world, :invalid_action_count, 0)
    }

    base
    |> Map.merge(failure_summary(world, base))
    |> Map.put(:sim_id, get(world, :sim_id, nil))
    |> Map.put(:status, get(world, :status, nil))
    |> Map.put(:day_number, get(world, :day_number, nil))
  end

  def inventory_value(world) do
    catalog = get(world, :catalog, %{})

    sealed_value =
      world
      |> get(:inventory, %{})
      |> Enum.reduce(0.0, fn {line_id, item}, acc ->
        line = get(catalog, line_id, %{})
        acc + get(item, :on_hand, 0) * get(line, :market_price, 0.0)
      end)

    sealed_value + loose_pack_inventory_value(world)
  end

  defp loose_pack_units(world) do
    world
    |> get(:pack_inventory, %{})
    |> Enum.reduce(0, fn {_line_id, pack}, acc -> acc + get(pack, :packs_on_hand, 0) end)
  end

  defp loose_pack_inventory_value(world) do
    world
    |> get(:pack_inventory, %{})
    |> Enum.reduce(0.0, fn {_line_id, pack}, acc ->
      acc + get(pack, :packs_on_hand, 0) * get(pack, :market_value_per_pack, 0.0)
    end)
  end

  defp pack_preparation_total(world, field) do
    world
    |> get(:pack_preparation_history, [])
    |> Enum.reduce(0, fn entry, acc -> acc + get(entry, field, 0) end)
  end

  defp pack_sale_total(world, field) do
    world
    |> get(:pack_sale_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, field, 0.0) end)
  end

  defp average_inventory_age_days(world) do
    {weighted_age, units} =
      world
      |> get(:inventory, %{})
      |> Enum.reduce({0.0, 0}, fn {_line_id, item}, {age_acc, unit_acc} ->
        on_hand = get(item, :on_hand, 0)
        {age_acc + on_hand * get(item, :age_days, 0), unit_acc + on_hand}
      end)

    if units > 0 do
      round_money(weighted_age / units)
    else
      0.0
    end
  end

  defp stale_inventory_units(world) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.reduce(0, fn {line_id, item}, acc ->
      line = get(catalog, line_id, %{})

      if get(item, :age_days, 0) >= stale_age_threshold(line) do
        acc + get(item, :on_hand, 0)
      else
        acc
      end
    end)
  end

  defp stale_inventory_markdown_loss(world) do
    world
    |> get(:stale_inventory_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :markdown_loss, 0.0) end)
  end

  defp stale_age_threshold(line) do
    case get(line, :category, "sealed") do
      "accessory" -> 8
      _ -> 8
    end
  end

  defp graded_value(singles) do
    singles
    |> get(:graded_cards, [])
    |> Enum.reduce(0.0, fn card, acc -> acc + get(card, :market_value, 0.0) end)
  end

  defp authenticated_failures(world) do
    world
    |> get(:authentication_loss_history, [])
    |> Enum.reduce(0, fn entry, acc -> acc + get(entry, :card_count, 0) end)
  end

  defp authentication_loss(world) do
    world
    |> get(:authentication_loss_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :raw_value_lost, 0.0) end)
  end

  defp collection_markdown_loss(world) do
    world
    |> get(:buylist_history, [])
    |> Enum.reduce(0.0, fn buy, acc -> acc + get(buy, :markdown_loss, 0.0) end)
  end

  defp sealed_opening_total(world, field) do
    world
    |> get(:sealed_opening_history, [])
    |> Enum.reduce(0, fn opening, acc -> acc + get(opening, field, 0) end)
  end

  defp store_credit_total(world, type) do
    world
    |> get(:store_credit_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == type))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :amount, 0.0) end)
  end

  defp event_total(world, key) do
    world
    |> get(:tournament_history, [])
    |> Enum.reduce(0, fn event, acc -> acc + get(event, key, 0) end)
  end

  defp event_capacity_utilization_pct(world) do
    {attendance, capacity} =
      world
      |> get(:tournament_history, [])
      |> Enum.reduce({0, 0}, fn event, {attendance_acc, capacity_acc} ->
        {attendance_acc + get(event, :attendance, 0),
         capacity_acc + get(event, :seat_capacity, 0)}
      end)

    if capacity > 0 do
      round_money(attendance / capacity * 100.0)
    else
      0.0
    end
  end

  defp sanctioned_events(world) do
    world
    |> get(:tournament_history, [])
    |> Enum.count(&get(&1, :sanctioned, false))
  end

  defp grade_count(world, grade) do
    world
    |> get(:grading_result_history, [])
    |> Enum.reduce(0, fn result, acc ->
      result
      |> get(:grade_mix, %{})
      |> get(grade, 0)
      |> Kernel.+(acc)
    end)
  end

  defp consignment_lots_open(world) do
    world
    |> get(:consignment_lots, [])
    |> Enum.count(&(get(&1, :cards_remaining, 0) > 0))
  end

  defp consignment_cards_remaining(world) do
    world
    |> get(:consignment_lots, [])
    |> Enum.reduce(0, fn lot, acc -> acc + get(lot, :cards_remaining, 0) end)
  end

  defp consignment_revenue(world) do
    world
    |> get(:consignment_sale_history, [])
    |> Enum.reduce(0.0, fn sale, acc -> acc + get(sale, :revenue, 0.0) end)
  end

  defp consignment_commission(world) do
    world
    |> get(:consignment_sale_history, [])
    |> Enum.reduce(0.0, fn sale, acc -> acc + get(sale, :commission_revenue, 0.0) end)
  end

  defp consignment_payouts_paid(world) do
    world
    |> get(:consignment_payout_history, [])
    |> Enum.reduce(0.0, fn payout, acc -> acc + get(payout, :amount_paid, 0.0) end)
  end

  defp active_memberships(world) do
    world
    |> get(:active_memberships, [])
    |> Enum.filter(&(get(&1, :status, "active") == "active"))
    |> Enum.reduce(0, fn membership, acc -> acc + get(membership, :member_count, 0) end)
  end

  defp active_membership_batches(world) do
    world
    |> get(:active_memberships, [])
    |> Enum.count(&(get(&1, :status, "active") == "active"))
  end

  defp membership_total(world, type, field) do
    world
    |> get(:membership_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == type))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, field, 0.0) end)
  end

  defp sell_through_units(world) do
    world
    |> get(:sales_history, [])
    |> sold_units()
  end

  defp sold_units(entries) do
    Enum.reduce(entries, 0, fn entry, acc ->
      acc +
        get(
          entry,
          :quantity,
          get(entry, :fulfilled_count, get(entry, :order_count, get(entry, :attendance, 0)))
        )
    end)
  end

  defp stockout_units(world) do
    world
    |> get(:stockout_history, [])
    |> Enum.reduce(0, fn stockout, acc -> acc + get(stockout, :lost_units, 0) end)
  end

  defp preorder_deposits(world) do
    world
    |> get(:preorder_history, [])
    |> Enum.reduce(0.0, fn preorder, acc -> acc + get(preorder, :deposit_collected, 0.0) end)
  end

  defp preorder_revenue(world) do
    world
    |> get(:preorder_fulfillment_history, [])
    |> Enum.reduce(0.0, fn fulfillment, acc ->
      acc + get(fulfillment, :deposit_applied, 0.0) + get(fulfillment, :balance_revenue, 0.0)
    end)
  end

  defp preorder_units_fulfilled(world) do
    world
    |> get(:preorder_fulfillment_history, [])
    |> Enum.reduce(0, fn fulfillment, acc -> acc + get(fulfillment, :fulfilled_quantity, 0) end)
  end

  defp preorder_units_short(world) do
    world
    |> get(:preorder_fulfillment_history, [])
    |> Enum.reduce(0, fn fulfillment, acc -> acc + get(fulfillment, :shorted_quantity, 0) end)
  end

  defp pending_preorder_units(world) do
    world
    |> get(:pending_preorders, [])
    |> Enum.reduce(0, fn preorder, acc -> acc + get(preorder, :remaining_quantity, 0) end)
  end

  defp special_order_deposits(world) do
    world
    |> get(:special_order_history, [])
    |> Enum.reduce(0.0, fn order, acc -> acc + get(order, :deposit_collected, 0.0) end)
  end

  defp special_order_revenue(world) do
    world
    |> get(:special_order_fulfillment_history, [])
    |> Enum.reduce(0.0, fn fulfillment, acc ->
      acc + get(fulfillment, :deposit_applied, 0.0) + get(fulfillment, :balance_revenue, 0.0)
    end)
  end

  defp special_order_units_fulfilled(world) do
    world
    |> get(:special_order_fulfillment_history, [])
    |> Enum.reduce(0, fn fulfillment, acc -> acc + get(fulfillment, :fulfilled_quantity, 0) end)
  end

  defp special_order_units_short(world) do
    world
    |> get(:special_order_fulfillment_history, [])
    |> Enum.reduce(0, fn fulfillment, acc -> acc + get(fulfillment, :shorted_quantity, 0) end)
  end

  defp pending_special_order_units(world) do
    world
    |> get(:pending_special_orders, [])
    |> Enum.reduce(0, fn order, acc -> acc + get(order, :remaining_quantity, 0) end)
  end

  defp preorder_liability(world) do
    world
    |> get(:pending_preorders, [])
    |> Enum.reduce(0.0, fn preorder, acc ->
      unit_price = get(preorder, :unit_price, 0.0)
      deposit_pct = get(preorder, :deposit_pct, 0.0)
      acc + get(preorder, :remaining_quantity, 0) * unit_price * deposit_pct / 100
    end)
  end

  defp marketing_spend(world) do
    world
    |> get(:promotion_history, [])
    |> Enum.reduce(0.0, fn promotion, acc -> acc + get(promotion, :budget, 0.0) end)
  end

  defp promoted_units_sold(world) do
    world
    |> get(:sales_history, [])
    |> Enum.filter(&get(&1, :promotion_id, nil))
    |> sold_units()
  end

  defp promoted_revenue(world) do
    world
    |> get(:sales_history, [])
    |> Enum.filter(&get(&1, :promotion_id, nil))
    |> Enum.reduce(0.0, fn sale, acc -> acc + get(sale, :revenue, 0.0) end)
  end

  defp sales_revenue(world) do
    world
    |> get(:sales_history, [])
    |> Enum.reduce(0.0, fn sale, acc -> acc + sale_revenue(sale) end)
  end

  defp sale_revenue(sale) do
    cond do
      get(sale, :revenue, 0.0) > 0.0 ->
        get(sale, :revenue, 0.0)

      get(sale, :taxable_revenue, 0.0) > 0.0 ->
        get(sale, :taxable_revenue, 0.0)

      true ->
        get(sale, :entry_revenue, 0.0) + get(sale, :attach_sales, 0.0)
    end
  end

  defp cost_of_goods_sold(world) do
    sold_cogs =
      world
      |> get(:sales_history, [])
      |> Enum.reduce(0.0, fn sale, acc -> acc + get(sale, :cost_of_goods_sold, 0.0) end)

    max(0.0, sold_cogs - return_total(world, :cogs_recovered))
  end

  defp gross_profit(world) do
    sales_revenue(world) - cost_of_goods_sold(world)
  end

  defp gross_margin_pct(world) do
    revenue = sales_revenue(world)

    if revenue > 0.0 do
      round_money(gross_profit(world) / revenue * 100.0)
    else
      0.0
    end
  end

  defp fixed_overhead(world) do
    overhead_total(world, :total)
  end

  defp overhead_total(world, field) do
    world
    |> get(:overhead_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, field, 0.0) end)
  end

  defp operating_expenses(world) do
    channel_costs(world) + marketing_spend(world) + regular_payroll(world) +
      operations_metric(world, :cumulative_overtime_cost) + staffing_total(world, :labor_cost) +
      online_channel_setup_spend(world) + fixed_overhead(world) +
      event_total(world, :operating_cost)
  end

  defp operating_profit(world) do
    gross_profit(world) - refund_amount(world) +
      membership_total(world, "recognized", :revenue_recognized) -
      operating_expenses(world)
  end

  defp debt_total(world, type) do
    world
    |> get(:debt_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == type))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :amount, 0.0) end)
  end

  defp cash_handling_total(world, field, type) do
    world
    |> get(:cash_handling_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == type))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, field, 0.0) end)
  end

  defp cash_reconciliation_entries(world) do
    world
    |> get(:cash_handling_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == "cash_reconciliation"))
  end

  defp cash_reconciliation_total(world, field) do
    world
    |> cash_reconciliation_entries()
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, field, 0.0) end)
  end

  defp refund_amount(world) do
    world
    |> get(:refund_history, [])
    |> Enum.reduce(0.0, fn refund, acc -> acc + get(refund, :refund_amount, 0.0) end)
  end

  defp return_total(world, field) do
    world
    |> get(:return_history, [])
    |> Enum.reduce(0, fn entry, acc -> acc + get(entry, field, 0) end)
  end

  defp return_resolution_total(world, resolution) do
    world
    |> get(:return_history, [])
    |> Enum.filter(&(get(&1, :resolution, nil) == resolution))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :refund_amount, 0.0) end)
  end

  defp chargeback_count(world) do
    world
    |> get(:refund_history, [])
    |> Enum.count(&get(&1, :chargeback, false))
  end

  defp taxable_sales(world) do
    world
    |> get(:tax_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == "collected"))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :taxable_sales, 0.0) end)
  end

  defp sales_tax_collected(world) do
    world
    |> get(:tax_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == "collected"))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :tax_collected, 0.0) end)
  end

  defp sales_tax_remitted(world) do
    world
    |> get(:tax_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == "remitted"))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :tax_remitted, 0.0) end)
  end

  defp payment_processing_fees(world) do
    world
    |> get(:transaction_cost_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :processing_fee, 0.0) end)
  end

  defp shipping_label_cost(world) do
    world
    |> get(:transaction_cost_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :shipping_label_cost, 0.0) end)
  end

  defp marketplace_fees(world) do
    world
    |> get(:transaction_cost_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :marketplace_fee, 0.0) end)
  end

  defp online_channel_setup_spend(world) do
    world
    |> get(:online_channel_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :setup_cost, 0.0) end)
  end

  defp packing_supply_cost(world) do
    world
    |> get(:online_order_history, [])
    |> Enum.reduce(0.0, fn order, acc -> acc + get(order, :packing_cost, 0.0) end)
  end

  defp channel_costs(world) do
    payment_processing_fees(world) + shipping_label_cost(world) + marketplace_fees(world) +
      packing_supply_cost(world)
  end

  defp shrinkage_units(world) do
    world
    |> get(:shrinkage_history, [])
    |> Enum.reduce(0, fn shrinkage, acc -> acc + get(shrinkage, :units, 0) end)
  end

  defp shrinkage_loss(world) do
    world
    |> get(:shrinkage_history, [])
    |> Enum.reduce(0.0, fn shrinkage, acc -> acc + get(shrinkage, :estimated_loss, 0.0) end)
  end

  defp loss_prevention_spend(world) do
    world
    |> get(:loss_prevention_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :cost, 0.0) end)
  end

  defp online_backorders(world) do
    world
    |> get(:online_order_history, [])
    |> Enum.reduce(0, fn order, acc -> acc + get(order, :backorder_count, 0) end)
  end

  defp supplier_fill_rate_pct(world) do
    orders = get(world, :supplier_order_history, [])
    requested = Enum.reduce(orders, 0, fn order, acc -> acc + requested_quantity(order) end)
    allocated = Enum.reduce(orders, 0, fn order, acc -> acc + get(order, :quantity, 0) end)

    if requested == 0 do
      100.0
    else
      round_money(allocated / requested * 100.0)
    end
  end

  defp allocation_shortfalls(world) do
    world
    |> get(:supplier_order_history, [])
    |> Enum.count(&(get(&1, :quantity, 0) < requested_quantity(&1)))
  end

  defp accounts_payable(world) do
    world
    |> get(:pending_supplier_invoices, [])
    |> Enum.reduce(0.0, fn invoice, acc -> acc + get(invoice, :amount_due, 0.0) end)
  end

  defp supplier_invoices_overdue(world) do
    world
    |> get(:pending_supplier_invoices, [])
    |> Enum.count(&(get(&1, :status, nil) == "overdue"))
  end

  defp supplier_invoices_paid(world) do
    world
    |> get(:supplier_invoice_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == "paid"))
    |> Enum.reduce(0.0, fn invoice, acc -> acc + get(invoice, :amount_paid, 0.0) end)
  end

  defp supplier_late_fees(world) do
    world
    |> get(:supplier_invoice_history, [])
    |> Enum.filter(&(get(&1, :type, nil) == "late_fee"))
    |> Enum.reduce(0.0, fn invoice, acc -> acc + get(invoice, :late_fee, 0.0) end)
  end

  defp supplier_credit_available(world) do
    max(0.0, effective_supplier_credit_limit(world) - accounts_payable(world))
  end

  defp effective_supplier_credit_limit(world) do
    base = get(world, :supplier_credit_limit, 0.0)
    Float.round(max(0.0, base + supplier_credit_adjustment(world)), 2)
  end

  defp supplier_credit_adjustment(world) do
    average = average_supplier_standing(world)

    cond do
      average > 55 -> min(750.0, (average - 55) * 20)
      average < 55 -> max(-750.0, (average - 55) * 25)
      true -> 0.0
    end
  end

  defp average_supplier_standing(world) do
    accounts = world |> get(:supplier_accounts, %{}) |> Map.values()

    if accounts == [] do
      55.0
    else
      accounts
      |> Enum.reduce(0.0, fn account, acc -> acc + get(account, :standing, 55) end)
      |> Kernel./(length(accounts))
      |> round_money()
    end
  end

  defp supplier_account_count(world, status) do
    world
    |> get(:supplier_accounts, %{})
    |> Map.values()
    |> Enum.count(&(get(&1, :status, "current") == status))
  end

  defp delivery_receipt_total(world, field) do
    world
    |> get(:delivery_receipt_history, [])
    |> Enum.reduce(0, fn receipt, acc -> acc + get(receipt, field, 0) end)
  end

  defp supplier_claim_total(world, field) do
    world
    |> get(:supplier_claim_history, [])
    |> Enum.reduce(0.0, fn claim, acc -> acc + get(claim, field, 0.0) end)
  end

  defp requested_quantity(order) do
    get(order, :requested_quantity, get(order, :quantity, 0))
  end

  defp staff_hours_used(world) do
    world
    |> get(:operations_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :staff_hours, 0.0) end)
    |> round_money()
  end

  defp staffing_total(world, field) do
    world
    |> get(:staffing_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, field, 0.0) end)
  end

  defp scheduled_staff_hours_used(world) do
    world
    |> get(:operations_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :scheduled_hours, 0.0) end)
    |> round_money()
  end

  defp payroll_paid_hours(world) do
    world
    |> get(:payroll_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :paid_hours, 0.0) end)
    |> round_money()
  end

  defp regular_payroll(world) do
    world
    |> get(:payroll_history, [])
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :payroll_cost, 0.0) end)
  end

  defp operations_metric(world, key) do
    world
    |> get(:operations, %{})
    |> get(key, 0)
  end

  defp average_customer_metric(world, key) do
    segments =
      world
      |> get(:customer_base, %{})
      |> Map.values()

    case segments do
      [] ->
        0.0

      segments ->
        segments
        |> Enum.reduce(0.0, fn segment, acc -> acc + get(segment, key, 0) end)
        |> Kernel./(length(segments))
        |> round_money()
    end
  end

  defp at_risk_customer_segments(world) do
    world
    |> get(:customer_base, %{})
    |> Enum.count(fn {_id, segment} -> get(segment, :satisfaction, 50) < 45 end)
  end

  defp customer_total(world, key) do
    world
    |> get(:customer_base, %{})
    |> Enum.reduce(0, fn {_id, segment}, acc -> acc + get(segment, key, 0) end)
  end

  defp competitive_metric(world, key, default) do
    world
    |> get(:competitive_position, %{})
    |> get(key, default)
  end

  defp failure_summary(world, scorecard) do
    gross_profit = get(scorecard, :gross_profit, 0.0)
    day = get(world, :day_number, 1)

    failure_modes =
      [
        maybe_failure(
          "negative_operating_profit",
          day > 1 and get(scorecard, :operating_profit, 0.0) < 0.0,
          "Operating expenses, refunds, labor, financing, and overhead exceed gross profit."
        ),
        maybe_failure(
          "cash_squeeze",
          get(scorecard, :bank_balance, 0.0) < 500.0 or
            get(scorecard, :credit_line_available, 0.0) < 250.0,
          "Bank cash or available working-capital credit is thin for a shop with daily overhead."
        ),
        maybe_failure(
          "supplier_credit_squeeze",
          get(scorecard, :supplier_credit_available, 0.0) < 250.0 or
            get(scorecard, :supplier_invoices_overdue, 0) > 0 or
            get(scorecard, :strained_supplier_accounts, 0) > 0,
          "Distributor AP, overdue invoices, or strained account standing are limiting allocations."
        ),
        maybe_failure(
          "customer_trust_damage",
          get(scorecard, :online_rating, 5.0) < 4.1 or
            get(scorecard, :service_issues, 0) > 0 or
            get(scorecard, :at_risk_customer_segments, 0) > 0,
          "Service issues, low online rating, or at-risk customer segments are damaging demand."
        ),
        maybe_failure(
          "stockout_damage",
          get(scorecard, :stockout_units, 0) >= 10 or
            get(scorecard, :online_backorders, 0) >= 5,
          "Inventory misses are causing stockouts or online backorders."
        ),
        maybe_failure(
          "commitment_shortfall",
          get(scorecard, :preorder_units_short, 0) > 0 or
            get(scorecard, :special_order_units_short, 0) > 0,
          "Customer preorder or special-order promises were not fully fulfilled."
        ),
        maybe_failure(
          "channel_cost_drag",
          get(scorecard, :channel_costs, 0.0) > 100.0 and
            get(scorecard, :channel_costs, 0.0) > max(gross_profit, 1.0) * 0.2,
          "Marketplace, shipping, packing, and payment costs are eating too much gross profit."
        ),
        maybe_failure(
          "stale_inventory_drag",
          get(scorecard, :stale_inventory_units, 0) > 10 or
            get(scorecard, :stale_inventory_markdown_loss, 0.0) > 100.0,
          "Aging sealed or accessory stock is forcing markdowns or tying up shelf capital."
        ),
        maybe_failure(
          "labor_overload",
          get(scorecard, :overtime_hours, 0.0) > 2.0 or
            get(scorecard, :backlog_tasks, 0) > 0 or get(scorecard, :fatigue, 0) > 2,
          "Owner/staff capacity is overloaded, increasing fatigue, overtime, or backlog risk."
        ),
        maybe_failure(
          "shrinkage_control_loss",
          get(scorecard, :shrinkage_loss, 0.0) > 0.0,
          "Shrinkage losses indicate theft, mishandling, or weak inventory controls."
        ),
        maybe_failure(
          "debt_pressure",
          get(scorecard, :credit_line_limit, 0.0) > 0.0 and
            get(scorecard, :credit_line_balance, 0.0) >
              get(scorecard, :credit_line_limit, 0.0) * 0.5,
          "The working-capital line is carrying more than half its limit."
        ),
        maybe_failure(
          "tax_liability_pressure",
          get(scorecard, :sales_tax_liability, 0.0) > 500.0,
          "Sales-tax liability is large enough to distort apparent cash."
        ),
        maybe_failure(
          "invalid_action_noise",
          get(scorecard, :rejections, 0) > 0,
          "Invalid operator actions were rejected and made visible in benchmark traces."
        )
      ]
      |> Enum.reject(&is_nil/1)

    %{
      failure_modes: failure_modes,
      active_failure_mode_count: length(failure_modes)
    }
  end

  defp maybe_failure(_id, false, _description), do: nil

  defp maybe_failure(id, true, description) do
    %{id: id, description: description}
  end

  defp get(map, key, default) do
    MapHelpers.get_key(map, key) || default
  end

  defp round_money(value), do: Float.round((value || 0) + 0.0, 2)
end
