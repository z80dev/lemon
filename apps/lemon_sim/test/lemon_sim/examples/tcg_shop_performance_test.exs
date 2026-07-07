defmodule LemonSim.Examples.TcgShopPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.TcgShop.Performance

  test "scorecard exposes net worth as a verified metric" do
    world = %{
      bank_balance: 1_000.0,
      cash_drawer_balance: 200.0,
      starting_balance: 1_000.0,
      starting_cash_drawer_balance: 100.0,
      inventory: %{"booster" => %{quantity: 10, unit_cost: 3.0}},
      singles_case: %{total_market_value: 150.0},
      credit_line_balance: 50.0,
      sales_history: [%{revenue: 120.0, cost: 70.0, quantity: 3}]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.net_worth > 0
    assert scorecard.bank_balance == 1000.0
    assert Map.has_key?(scorecard, :roi_pct)
    assert {:ok, value} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert is_number(value)
    assert Performance.scorecard(world) == scorecard
  end

  test "primary_metric targets net_worth for maximization" do
    assert Performance.primary_metric() == %{key: "net_worth", direction: :maximize}
  end

  test "computes sales revenue, COGS, margin, and refund/return metrics" do
    world = %{
      sales_history: [
        %{revenue: 500.0, cost_of_goods_sold: 200.0, quantity: 5},
        %{revenue: 300.0, cost_of_goods_sold: 100.0, quantity: 3, promotion_id: "promo1"}
      ],
      refund_history: [
        %{refund_amount: 50.0, chargeback: false},
        %{refund_amount: 20.0, chargeback: true}
      ],
      return_history: [
        %{
          quantity: 2,
          refund_amount: 30.0,
          restocked_units: 2,
          cogs_recovered: 10.0,
          writeoff_loss: 0.0,
          resolution: "store_credit"
        },
        %{
          quantity: 1,
          refund_amount: 15.0,
          restocked_units: 0,
          cogs_recovered: 0.0,
          writeoff_loss: 15.0,
          resolution: "cash_refund"
        }
      ],
      promotion_history: [%{budget: 100.0}]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.sales_revenue == 800.0
    assert scorecard.cost_of_goods_sold == 290.0
    assert scorecard.gross_profit == 510.0
    assert scorecard.gross_margin_pct == 63.75
    assert scorecard.refund_amount == 70.0
    assert scorecard.net_sales_revenue == 730.0
    assert scorecard.refund_count == 2
    assert scorecard.chargeback_count == 1
    assert scorecard.sell_through_units == 8
    assert scorecard.promoted_units_sold == 3
    assert scorecard.promoted_revenue == 300.0
    assert scorecard.marketing_spend == 100.0
    assert scorecard.customer_returns == 2
    assert scorecard.returned_units == 3
    assert scorecard.return_refunds == 45.0
    assert scorecard.returned_inventory_units == 2
    assert scorecard.return_cogs_recovered == 10.0
    assert scorecard.return_writeoff_loss == 15.0
    assert scorecard.return_store_credit == 30.0
    assert scorecard.return_cash_refunds == 15.0
    assert scorecard.operating_expenses == 100.0
    assert scorecard.operating_profit == 340.0
    assert scorecard.net_profit_after_financing == 340.0
  end

  test "computes inventory value, aging, and stale markdown metrics" do
    world = %{
      catalog: %{
        "boosters" => %{market_price: 4.0, category: "sealed"},
        "sleeves" => %{market_price: 2.0, category: "accessory"}
      },
      inventory: %{
        "boosters" => %{on_hand: 100, age_days: 10, unit_cost: 3.0},
        "sleeves" => %{on_hand: 50, age_days: 3, unit_cost: 1.0}
      },
      pack_inventory: %{
        "boosters" => %{packs_on_hand: 20, market_value_per_pack: 5.0}
      },
      stale_inventory_history: [
        %{markdown_loss: 25.0},
        %{markdown_loss: 10.0}
      ]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.inventory_value == 600.0
    assert scorecard.average_inventory_age_days == 7.67
    assert scorecard.stale_inventory_units == 100
    assert scorecard.stale_inventory_markdowns == 2
    assert scorecard.stale_inventory_markdown_loss == 35.0
    assert scorecard.loose_pack_units == 20
    assert scorecard.loose_pack_inventory_value == 100.0
    assert Performance.inventory_value(world) == 600.0
  end

  test "computes overhead, payroll, and operating profit metrics" do
    world = %{
      overhead_history: [
        %{rent: 500.0, utilities: 100.0, insurance: 50.0, total: 650.0}
      ],
      payroll_history: [
        %{payroll_cost: 800.0, paid_hours: 160.0}
      ],
      staffing_history: [
        %{hours: 40.0, labor_cost: 400.0}
      ],
      operations: %{cumulative_overtime_hours: 5.0, cumulative_overtime_cost: 75.0, fatigue: 1},
      operations_history: [
        %{staff_hours: 45.0, scheduled_hours: 40.0}
      ],
      debt_history: [
        %{type: "interest", amount: 20.0},
        %{type: "draw", amount: 500.0},
        %{type: "repay", amount: 100.0}
      ],
      sales_history: [%{revenue: 1_000.0, cost_of_goods_sold: 400.0, quantity: 10}]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.fixed_overhead == 650.0
    assert scorecard.rent_expense == 500.0
    assert scorecard.utilities_expense == 100.0
    assert scorecard.insurance_expense == 50.0
    assert scorecard.regular_payroll == 800.0
    assert scorecard.overtime_hours == 5.0
    assert scorecard.overtime_cost == 75.0
    assert scorecard.total_labor_cost == 1_275.0
    assert scorecard.staff_hours_used == 45.0
    assert scorecard.scheduled_staff_hours_used == 40.0
    assert scorecard.payroll_paid_hours == 160.0
    assert scorecard.scheduled_staff_shifts == 1
    assert scorecard.fatigue == 1
    assert scorecard.backlog_tasks == 0
    assert scorecard.credit_line_interest == 20.0
    assert scorecard.credit_line_draws == 500.0
    assert scorecard.credit_line_repayments == 100.0
    assert scorecard.operating_expenses == 1_925.0
    assert scorecard.operating_profit == -1_325.0
    assert scorecard.net_profit_after_financing == -1_345.0
  end

  test "computes supplier standing, accounts payable, and delivery metrics" do
    world = %{
      pending_supplier_invoices: [
        %{amount_due: 300.0, status: "overdue"},
        %{amount_due: 200.0, status: "current"}
      ],
      supplier_invoice_history: [
        %{type: "paid", amount_paid: 150.0},
        %{type: "late_fee", late_fee: 25.0}
      ],
      supplier_order_history: [
        %{requested_quantity: 100, quantity: 80},
        %{requested_quantity: 50, quantity: 50}
      ],
      supplier_accounts: %{
        "acct_1" => %{standing: 70, status: "preferred"},
        "acct_2" => %{standing: 40, status: "strained"}
      },
      supplier_credit_limit: 1_000.0,
      delivery_receipt_history: [
        %{damaged_units: 3, damage_value: 45.0}
      ],
      supplier_claim_history: [
        %{claim_amount: 45.0}
      ]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.accounts_payable == 500.0
    assert scorecard.supplier_invoices_open == 2
    assert scorecard.supplier_invoices_overdue == 1
    assert scorecard.supplier_invoices_paid == 150.0
    assert scorecard.supplier_late_fees == 25.0
    assert scorecard.supplier_fill_rate_pct == 86.67
    assert scorecard.allocation_shortfalls == 1
    assert scorecard.average_supplier_standing == 55.0
    assert scorecard.supplier_credit_limit_effective == 1_000.0
    assert scorecard.supplier_credit_available == 500.0
    assert scorecard.supplier_credit_used == 500.0
    assert scorecard.preferred_supplier_accounts == 1
    assert scorecard.strained_supplier_accounts == 1
    assert scorecard.damaged_delivery_units == 3
    assert scorecard.damaged_delivery_value == 45.0
    assert scorecard.supplier_damage_claims == 1
    assert scorecard.supplier_claim_credits == 45.0
  end

  test "computes preorder, special order, membership, and consignment metrics" do
    world = %{
      pending_preorders: [
        %{remaining_quantity: 5, unit_price: 40.0, deposit_pct: 20.0}
      ],
      preorder_history: [
        %{deposit_collected: 100.0}
      ],
      preorder_fulfillment_history: [
        %{
          deposit_applied: 50.0,
          balance_revenue: 150.0,
          fulfilled_quantity: 5,
          shorted_quantity: 1
        }
      ],
      pending_special_orders: [
        %{remaining_quantity: 2}
      ],
      special_order_history: [
        %{deposit_collected: 60.0}
      ],
      special_order_fulfillment_history: [
        %{
          deposit_applied: 30.0,
          balance_revenue: 90.0,
          fulfilled_quantity: 3,
          shorted_quantity: 0
        }
      ],
      active_memberships: [
        %{status: "active", member_count: 10},
        %{status: "cancelled", member_count: 5}
      ],
      membership_history: [
        %{type: "sold", collected: 200.0},
        %{type: "recognized", revenue_recognized: 40.0}
      ],
      consignment_lots: [
        %{cards_remaining: 5},
        %{cards_remaining: 0}
      ],
      consignment_sale_history: [
        %{revenue: 500.0, commission_revenue: 50.0}
      ],
      consignment_payout_history: [
        %{amount_paid: 450.0}
      ]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.preorder_liability == 40.0
    assert scorecard.preorder_deposits == 100.0
    assert scorecard.preorder_revenue == 200.0
    assert scorecard.preorder_units_fulfilled == 5
    assert scorecard.preorder_units_short == 1
    assert scorecard.pending_preorder_units == 5

    assert scorecard.special_order_deposits == 60.0
    assert scorecard.special_order_revenue == 120.0
    assert scorecard.special_order_units_fulfilled == 3
    assert scorecard.special_order_units_short == 0
    assert scorecard.pending_special_order_units == 2

    assert scorecard.active_memberships == 10
    assert scorecard.active_membership_batches == 1
    assert scorecard.membership_revenue_collected == 200.0
    assert scorecard.membership_revenue_recognized == 40.0

    assert scorecard.consignment_lots_open == 1
    assert scorecard.consignment_cards_remaining == 5
    assert scorecard.consignment_revenue == 500.0
    assert scorecard.consignment_commission == 50.0
    assert scorecard.consignment_payouts_paid == 450.0
  end

  test "computes event, grading, sealed opening, and loose pack metrics" do
    world = %{
      tournament_history: [
        %{
          attendance: 8,
          seat_capacity: 10,
          sanctioned: true,
          turn_aways: 1,
          no_shows: 2,
          prize_fulfilled_value: 100.0,
          prize_inventory_cost: 60.0,
          prize_store_credit_issued: 20.0,
          judge_cost: 30.0,
          sanction_fee: 15.0,
          operating_cost: 50.0
        },
        %{
          attendance: 4,
          seat_capacity: 8,
          sanctioned: false,
          turn_aways: 0,
          no_shows: 1,
          prize_fulfilled_value: 40.0,
          prize_inventory_cost: 20.0,
          prize_store_credit_issued: 0.0,
          judge_cost: 10.0,
          sanction_fee: 0.0,
          operating_cost: 20.0
        }
      ],
      grading_history: [%{}],
      grading_result_history: [
        %{grade_mix: %{gem_mint: 3, mint: 5}}
      ],
      authentication_loss_history: [
        %{card_count: 2, raw_value_lost: 300.0}
      ],
      buylist_history: [
        %{markdown_loss: 75.0}
      ],
      sealed_opening_history: [
        %{
          quantity: 10,
          packs_opened: 200,
          cards_added: 2_000,
          cost_basis: 800.0,
          sealed_market_value_consumed: 1_000.0,
          singles_market_value_added: 1_200.0,
          value_delta_vs_market: 200.0,
          chase_hits: 3
        }
      ],
      pack_preparation_history: [
        %{packs_added: 50}
      ],
      pack_sale_history: [
        %{quantity: 30, revenue: 300.0, gross_profit: 100.0}
      ]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.events_hosted == 2
    assert scorecard.event_attendance == 12
    assert scorecard.event_capacity_utilization_pct == 66.67
    assert scorecard.event_turn_aways == 1
    assert scorecard.event_no_shows == 3
    assert scorecard.sanctioned_events == 1
    assert scorecard.event_prize_value == 140.0
    assert scorecard.event_prize_inventory_cost == 80.0
    assert scorecard.event_prize_store_credit == 20.0
    assert scorecard.event_judge_cost == 40.0
    assert scorecard.event_sanction_fees == 15.0
    assert scorecard.event_operating_cost == 70.0

    assert scorecard.grading_submissions == 1
    assert scorecard.grading_results == 1
    assert scorecard.gem_mint_cards == 3
    assert scorecard.mint_cards == 5
    assert scorecard.authenticated_failures == 2
    assert scorecard.authentication_loss == 300.0
    assert scorecard.collection_markdown_loss == 75.0

    assert scorecard.sealed_openings == 1
    assert scorecard.sealed_units_opened == 10
    assert scorecard.sealed_packs_opened == 200
    assert scorecard.sealed_opening_cards_added == 2_000
    assert scorecard.sealed_opening_cost_basis == 800.0
    assert scorecard.sealed_opening_market_value_consumed == 1_000.0
    assert scorecard.sealed_opening_singles_value == 1_200.0
    assert scorecard.sealed_opening_value_delta == 200.0
    assert scorecard.sealed_opening_chase_hits == 3

    assert scorecard.loose_pack_preparations == 1
    assert scorecard.loose_pack_units_prepared == 50
    assert scorecard.loose_pack_units_sold == 30
    assert scorecard.loose_pack_revenue == 300.0
    assert scorecard.loose_pack_gross_profit == 100.0
  end

  test "computes cash handling, tax, channel, stockout, and customer metrics" do
    world = %{
      cash_handling_history: [
        %{type: "tender_split", cash_amount: 200.0, card_amount: 300.0},
        %{type: "bank_deposit", amount: 150.0},
        %{
          type: "cash_reconciliation",
          over_short_amount: -5.0,
          shortage_amount: 5.0,
          overage_amount: 0.0
        }
      ],
      tax_history: [
        %{type: "collected", taxable_sales: 1_000.0, tax_collected: 80.0},
        %{type: "remitted", tax_remitted: 60.0}
      ],
      transaction_cost_history: [
        %{processing_fee: 20.0, shipping_label_cost: 10.0, marketplace_fee: 5.0}
      ],
      online_channel_history: [%{setup_cost: 100.0}],
      online_channel: %{platform: "shopify", listing_quality: "premium"},
      online_order_history: [
        %{packing_cost: 15.0, backorder_count: 2}
      ],
      stockout_history: [%{lost_units: 4}],
      shrinkage_history: [%{units: 3, estimated_loss: 60.0}],
      loss_prevention_history: [%{cost: 40.0}],
      loss_prevention_score: 70,
      service_issue_history: [%{}],
      customer_base: %{
        "seg1" => %{loyalty: 60, satisfaction: 40, visits: 10, lifetime_spend: 500.0},
        "seg2" => %{loyalty: 80, satisfaction: 90, visits: 20, lifetime_spend: 1_000.0}
      },
      competitive_position: %{
        local_market_share_pct: 40.0,
        competitor_pressure: 2.0,
        price_reputation: "premium"
      },
      competitor_history: [%{}],
      active_promotions: [%{}],
      store_credit_history: [
        %{type: "issued", amount: 100.0},
        %{type: "redeemed", amount: 40.0}
      ],
      invalid_action_count: 3
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.cash_tender_sales == 200.0
    assert scorecard.card_tender_sales == 300.0
    assert scorecard.bank_deposits == 150.0
    assert scorecard.cash_reconciliations == 1
    assert scorecard.cash_over_short == -5.0
    assert scorecard.cash_shortage_loss == 5.0
    assert scorecard.cash_overage_gain == 0.0
    assert scorecard.cash_handling_events == 3

    assert scorecard.taxable_sales == 1_000.0
    assert scorecard.sales_tax_collected == 80.0
    assert scorecard.sales_tax_remitted == 60.0

    assert scorecard.payment_processing_fees == 20.0
    assert scorecard.shipping_label_cost == 10.0
    assert scorecard.marketplace_fees == 5.0
    assert scorecard.online_channel_setup_spend == 100.0
    assert scorecard.packing_supply_cost == 15.0
    assert scorecard.channel_costs == 50.0
    assert scorecard.online_channel_platform == "shopify"
    assert scorecard.online_listing_quality == "premium"
    assert scorecard.online_backorders == 2
    assert scorecard.online_channel_updates == 1

    assert scorecard.stockout_events == 1
    assert scorecard.stockout_units == 4
    assert scorecard.shrinkage_units == 3
    assert scorecard.shrinkage_loss == 60.0
    assert scorecard.loss_prevention_spend == 40.0
    assert scorecard.loss_prevention_score == 70
    assert scorecard.loss_prevention_upgrades == 1
    assert scorecard.service_issues == 1

    assert scorecard.average_customer_loyalty == 70.0
    assert scorecard.average_customer_satisfaction == 65.0
    assert scorecard.at_risk_customer_segments == 1
    assert scorecard.customer_visits == 30
    assert scorecard.customer_lifetime_spend == 1_500.0

    assert scorecard.local_market_share_pct == 40.0
    assert scorecard.competitor_pressure == 2.0
    assert scorecard.price_reputation == "premium"
    assert scorecard.competitor_reactions == 1

    assert scorecard.store_credit_issued == 100.0
    assert scorecard.store_credit_redeemed == 40.0
    assert scorecard.active_promotions == 1
    assert scorecard.rejections == 3
  end

  test "flags every failure mode when the shop is in broad distress" do
    world = %{
      day_number: 5,
      bank_balance: 100.0,
      cash_drawer_balance: 0.0,
      starting_balance: 1_000.0,
      credit_line_balance: 900.0,
      credit_line_limit: 1_000.0,
      supplier_credit_limit: 100.0,
      pending_supplier_invoices: [%{amount_due: 100.0, status: "overdue"}],
      supplier_accounts: %{"a" => %{standing: 30, status: "strained"}},
      online_rating: 3.5,
      service_issue_history: [%{}],
      customer_base: %{"seg" => %{satisfaction: 20}},
      stockout_history: [%{lost_units: 12}],
      pending_preorders: [%{remaining_quantity: 1, unit_price: 10.0, deposit_pct: 10.0}],
      preorder_fulfillment_history: [%{shorted_quantity: 1}],
      transaction_cost_history: [%{processing_fee: 150.0}],
      stale_inventory_history: [%{markdown_loss: 200.0}],
      operations: %{cumulative_overtime_hours: 3.0, backlog_tasks: [1, 2], fatigue: 3},
      shrinkage_history: [%{estimated_loss: 20.0}],
      sales_tax_liability: 600.0,
      invalid_action_count: 2,
      sales_history: [%{revenue: 10.0, cost_of_goods_sold: 500.0, quantity: 1}]
    }

    scorecard = Performance.scorecard(world)
    failure_ids = scorecard.failure_modes |> Enum.map(& &1.id) |> Enum.sort()

    assert failure_ids ==
             Enum.sort(~w(
               negative_operating_profit
               cash_squeeze
               supplier_credit_squeeze
               customer_trust_damage
               stockout_damage
               commitment_shortfall
               channel_cost_drag
               stale_inventory_drag
               labor_overload
               shrinkage_control_loss
               debt_pressure
               tax_liability_pressure
               invalid_action_noise
             ))

    assert scorecard.active_failure_mode_count == 13
  end

  test "reports no failure modes for a healthy shop" do
    world = %{
      day_number: 10,
      bank_balance: 5_000.0,
      cash_drawer_balance: 500.0,
      credit_line_limit: 1_000.0,
      credit_line_balance: 0.0,
      supplier_credit_limit: 2_000.0,
      online_rating: 4.8,
      sales_history: [%{revenue: 1_000.0, cost_of_goods_sold: 300.0, quantity: 10}]
    }

    scorecard = Performance.scorecard(world)

    assert scorecard.failure_modes == []
    assert scorecard.active_failure_mode_count == 0
  end

  test "passes through sim_id, status, and day_number metadata" do
    world = %{sim_id: "abc123", status: "completed", day_number: 7}
    scorecard = Performance.scorecard(world)

    assert scorecard.sim_id == "abc123"
    assert scorecard.status == "completed"
    assert scorecard.day_number == 7
  end
end
