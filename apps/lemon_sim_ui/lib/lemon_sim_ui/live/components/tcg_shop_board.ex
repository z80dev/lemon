defmodule LemonSimUi.Live.Components.TcgShopBoard do
  @moduledoc false

  use Phoenix.Component

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.TcgShop.Performance

  attr(:world, :map, required: true)
  attr(:interactive, :boolean, default: false)

  def render(assigns) do
    scorecard = Performance.scorecard(assigns.world)
    assigns = assign(assigns, scorecard: scorecard)

    ~H"""
    <div class="space-y-5">
      <div class="rounded-xl border border-amber-500/25 bg-slate-950/80 overflow-hidden shadow-[0_0_32px_rgba(245,158,11,0.12)]">
        <div class="px-5 py-4 border-b border-amber-500/20 bg-slate-900/70 flex flex-wrap items-center justify-between gap-3">
          <div>
            <div class="text-[10px] uppercase tracking-[0.24em] text-amber-300 font-mono">Local Game Store</div>
            <h2 class="text-2xl font-bold text-white">TCG Shop</h2>
          </div>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-right">
            <.metric label="Day" value={"#{get(@world, :day_number, 1)}/#{get(@world, :max_days, 14)}"} />
            <.metric label="Bank" value={"$#{money(get(@world, :bank_balance, 0.0))}"} />
            <.metric label="Drawer" value={"$#{money(get(@world, :cash_drawer_balance, 0.0))}"} />
            <.metric label="Net Worth" value={"$#{money(@scorecard.net_worth)}"} />
            <.metric label="Rating" value={to_string(get(@world, :online_rating, 4.3))} />
          </div>
        </div>

        <div class="p-5 grid grid-cols-1 xl:grid-cols-12 gap-5">
          <div class="xl:col-span-8 space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <%= for {line_id, item} <- inventory_rows(@world) do %>
                <% line = catalog_line(@world, line_id) %>
                <div class={[
                  "rounded-lg border p-3 bg-slate-900/70",
                  franchise_border(get(line, :franchise, ""))
                ]}>
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="text-[10px] uppercase tracking-widest text-slate-400 font-mono">{get(line, :franchise, "Unknown")}</div>
                      <div class="font-semibold text-slate-100 truncate">{get(line, :name, line_id)}</div>
                    </div>
                    <div class="text-right shrink-0">
                      <div class="text-xl font-bold text-white">{get(item, :on_hand, 0)}</div>
                      <div class="text-[10px] text-slate-500">on hand</div>
                    </div>
                  </div>
                  <div class="mt-3 grid grid-cols-3 gap-2 text-xs">
                    <div>
                      <div class="text-slate-500">Shelf</div>
                      <div class="text-emerald-300 font-mono">$#{money(get(item, :price, 0.0))}</div>
                    </div>
                    <div>
                      <div class="text-slate-500">Market</div>
                      <div class="text-cyan-300 font-mono">$#{money(get(line, :market_price, 0.0))}</div>
                    </div>
                    <div>
                      <div class="text-slate-500">Velocity</div>
                      <div class="text-amber-300 font-mono">{get(line, :velocity, 0.0)}x</div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
              <.panel title="Singles Case">
                <% singles = get(@world, :singles_case, %{}) %>
                <div class="text-3xl font-bold text-white">{get(singles, :cards_on_hand, 0)}</div>
                <div class="text-xs text-slate-400">raw cards</div>
                <div class="mt-2 text-sm text-emerald-300 font-mono">$#{money(get(singles, :total_market_value, 0.0))}</div>
                <div class="text-xs text-slate-500">raw market value</div>
                <div class="mt-2 text-xs text-slate-400">{length(get(singles, :graded_cards, []))} graded lots in case</div>
              </.panel>
              <.panel title="Pending">
                <% operations = get(@world, :operations, %{}) %>
                <div class="text-sm text-slate-300">{length(get(@world, :pending_deliveries, []))} deliveries</div>
                <div class="text-sm text-slate-300">{@scorecard.pending_preorder_units} preorder units</div>
                <div class="text-sm text-slate-300">{@scorecard.pending_special_order_units} special-order units</div>
                <div class="text-sm text-slate-300">{length(get(@world, :pending_grading, []))} grading orders</div>
                <div class="text-sm text-slate-300">{money(get(operations, :staff_hours_remaining, 0.0))} staff hours left</div>
                <div class="text-sm text-slate-300">{length(get(operations, :backlog_tasks, []))} backlog tasks</div>
                <div class="mt-2 text-xs text-slate-500">Distribution and grading delays resolve on next-day ticks.</div>
              </.panel>
              <.panel title="Score">
                <div class="text-sm text-slate-300">ROI <span class="font-mono text-amber-300">{money(@scorecard.roi_pct)}%</span></div>
                <div class="text-sm text-slate-300">Reputation <span class="font-mono text-cyan-300">{@scorecard.reputation}</span></div>
                <div class="text-sm text-slate-300">Events <span class="font-mono text-fuchsia-300">{@scorecard.events_hosted}</span></div>
                <div class="text-sm text-slate-300">Prizes <span class="font-mono text-fuchsia-300">$#{money(@scorecard.event_prize_value)}</span></div>
                <div class="text-sm text-slate-300">Age <span class="font-mono text-amber-300">{money(@scorecard.average_inventory_age_days)}d</span></div>
                <div class="text-sm text-slate-300">Fill Rate <span class="font-mono text-lime-300">{money(@scorecard.supplier_fill_rate_pct)}%</span></div>
                <div class="text-sm text-slate-300">GM <span class="font-mono text-cyan-300">{money(@scorecard.gross_margin_pct)}%</span></div>
                <div class="text-sm text-slate-300">Op Profit <span class="font-mono text-emerald-300">$#{money(@scorecard.operating_profit)}</span></div>
                <div class="text-sm text-slate-300">Refunds <span class="font-mono text-rose-300">$#{money(@scorecard.refund_amount)}</span></div>
                <div class="text-sm text-slate-300">A/P <span class="font-mono text-yellow-300">$#{money(@scorecard.accounts_payable)}</span></div>
                <div class="text-sm text-slate-300">Consign <span class="font-mono text-yellow-300">$#{money(@scorecard.consignment_payable)}</span></div>
                <div class="text-sm text-slate-300">Member <span class="font-mono text-green-300">$#{money(@scorecard.membership_liability)}</span></div>
                <div class="text-sm text-slate-300">Debt <span class="font-mono text-rose-300">$#{money(@scorecard.credit_line_balance)}</span></div>
                <div class="text-sm text-slate-300">Credit <span class="font-mono text-violet-300">$#{money(@scorecard.store_credit_liability)}</span></div>
                <div class="text-sm text-slate-300">Fees <span class="font-mono text-rose-300">$#{money(@scorecard.channel_costs)}</span></div>
                <div class="text-sm text-slate-300">Payroll <span class="font-mono text-emerald-300">$#{money(@scorecard.regular_payroll)}</span></div>
                <div class="text-sm text-slate-300">Staffing <span class="font-mono text-emerald-300">$#{money(@scorecard.scheduled_staff_cost)}</span></div>
                <div class="text-sm text-slate-300">Overtime <span class="font-mono text-sky-300">{money(@scorecard.overtime_hours)}h</span></div>
                <div class="text-sm text-slate-300">Cust Sat <span class="font-mono text-teal-300">{money(@scorecard.average_customer_satisfaction)}</span></div>
                <div class="text-sm text-slate-300">Share <span class="font-mono text-lime-300">{money(@scorecard.local_market_share_pct)}%</span></div>
                <div class="text-sm text-slate-300">Pressure <span class="font-mono text-red-300">{money(@scorecard.competitor_pressure)}</span></div>
                <div class="text-sm text-slate-300">Preorders <span class="font-mono text-cyan-300">{@scorecard.preorder_units_fulfilled}/{@scorecard.preorder_units_short}</span></div>
                <div class="text-sm text-slate-300">Specials <span class="font-mono text-cyan-300">{@scorecard.special_order_units_fulfilled}/{@scorecard.special_order_units_short}</span></div>
                <div class="text-sm text-slate-300">Promoted <span class="font-mono text-emerald-300">{@scorecard.promoted_units_sold}</span></div>
                <div class="text-sm text-slate-300">Tax Due <span class="font-mono text-yellow-300">$#{money(@scorecard.sales_tax_liability)}</span></div>
                <div class="text-sm text-slate-300">Auth Fails <span class="font-mono text-rose-300">{@scorecard.authenticated_failures}</span></div>
                <div class="text-sm text-slate-300">Gem Mint <span class="font-mono text-indigo-300">{@scorecard.gem_mint_cards}</span></div>
                <div class="text-sm text-slate-300">Opened <span class="font-mono text-pink-300">{@scorecard.sealed_units_opened}</span></div>
                <div class="text-sm text-slate-300">Stockouts <span class="font-mono text-red-300">{@scorecard.stockout_units}</span></div>
                <div class="text-sm text-slate-300">Shrink <span class="font-mono text-orange-300">{@scorecard.shrinkage_units}</span></div>
                <div class="text-sm text-slate-300">Security <span class="font-mono text-lime-300">{@scorecard.loss_prevention_score}</span></div>
                <div class="text-sm text-slate-300">Backorders <span class="font-mono text-orange-300">{@scorecard.online_backorders}</span></div>
                <div class="text-sm text-slate-300">Failures <span class="font-mono text-red-300">{@scorecard.active_failure_mode_count}</span></div>
              </.panel>
            </div>
          </div>

          <div class="xl:col-span-4 space-y-4">
            <.panel title="Market Pulse">
              <% pulse = List.last(get(@world, :market_pulses, [])) || %{} %>
              <div class="text-lg font-semibold text-white">{get(pulse, :featured_franchise, "Unknown")}</div>
              <div class="text-sm text-amber-300 font-mono">{get(pulse, :buzz_multiplier, 1.0)}x buzz</div>
              <p class="mt-2 text-sm text-slate-400">{get(pulse, :note, "")}</p>
            </.panel>

            <.panel title="Local Competition">
              <% position = get(@world, :competitive_position, %{}) %>
              <div class="grid grid-cols-2 gap-2 text-sm">
                <div>
                  <div class="text-slate-500">Share</div>
                  <div class="font-mono text-lime-300">{money(get(position, :local_market_share_pct, 34.0))}%</div>
                </div>
                <div>
                  <div class="text-slate-500">Pressure</div>
                  <div class="font-mono text-red-300">{money(get(position, :competitor_pressure, 0.0))}</div>
                </div>
              </div>
              <div class="mt-2 text-xs text-slate-400">
                {get(position, :price_reputation, "fair")} pricing · {get(position, :last_reaction, "opening baseline")}
              </div>
            </.panel>

            <.panel title="Promotions">
              <div class="text-sm text-slate-300">{@scorecard.active_promotions} active campaigns</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.marketing_spend)} spent</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.promoted_revenue)} promoted revenue</div>
            </.panel>

            <.panel title="Organized Play">
              <div class="text-sm text-slate-300">{@scorecard.events_hosted} events hosted</div>
              <div class="text-sm text-slate-300">{@scorecard.event_attendance} player entries</div>
              <div class="text-sm text-slate-300">{money(@scorecard.event_capacity_utilization_pct)}% capacity used</div>
              <div class="text-sm text-slate-300">{@scorecard.event_turn_aways} turn-aways</div>
              <div class="text-sm text-slate-300">{@scorecard.event_no_shows} no-shows</div>
              <div class="text-sm text-slate-300">{@scorecard.sanctioned_events} sanctioned events</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.event_prize_value)} prize value</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.event_prize_store_credit)} credit prizes</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.event_operating_cost)} event ops cost</div>
            </.panel>

            <.panel title="Inventory Aging">
              <div class="text-sm text-slate-300">{money(@scorecard.average_inventory_age_days)} average days</div>
              <div class="text-sm text-slate-300">{@scorecard.stale_inventory_units} stale units</div>
              <div class="text-sm text-slate-300">{@scorecard.stale_inventory_markdowns} markdown records</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.stale_inventory_markdown_loss)} markdown loss</div>
            </.panel>

            <.panel title="Loss Prevention">
              <div class="text-sm text-slate-300">{@scorecard.loss_prevention_score} protection score</div>
              <div class="text-sm text-slate-300">{@scorecard.loss_prevention_upgrades} controls installed</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.loss_prevention_spend)} invested</div>
              <div class="text-sm text-slate-300">{@scorecard.shrinkage_units} shrinkage units</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.shrinkage_loss)} shrinkage loss</div>
            </.panel>

            <.panel title="Tax Ledger">
              <div class="text-sm text-slate-300">$#{money(@scorecard.taxable_sales)} taxable sales</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.sales_tax_collected)} collected</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.sales_tax_remitted)} remitted</div>
            </.panel>

            <.panel title="Cash Handling">
              <div class="text-sm text-slate-300">$#{money(@scorecard.cash_drawer_balance)} drawer balance</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.cash_tender_sales)} cash tenders</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.card_tender_sales)} card tenders</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.bank_deposits)} bank deposits</div>
              <div class="text-sm text-slate-300">{@scorecard.cash_reconciliations} drawer counts</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.cash_over_short)} over/short</div>
            </.panel>

            <.panel title="Channel Costs">
              <div class="text-sm text-slate-300">{@scorecard.online_channel_platform} / {@scorecard.online_listing_quality}</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.online_channel_setup_spend)} listing setup</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.payment_processing_fees)} processing</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.shipping_label_cost)} shipping labels</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.marketplace_fees)} marketplace fees</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.packing_supply_cost)} packing supplies</div>
            </.panel>

            <.panel title="Gross Margin">
              <div class="text-sm text-slate-300">$#{money(@scorecard.sales_revenue)} sales revenue</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.net_sales_revenue)} net sales</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.cost_of_goods_sold)} COGS</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.gross_profit)} gross profit</div>
            </.panel>

            <.panel title="Sealed Opening">
              <div class="text-sm text-slate-300">{@scorecard.sealed_units_opened} sealed units opened</div>
              <div class="text-sm text-slate-300">{@scorecard.sealed_packs_opened} packs cracked</div>
              <div class="text-sm text-slate-300">{@scorecard.sealed_opening_cards_added} cards added</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.sealed_opening_singles_value)} singles value</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.sealed_opening_value_delta)} vs sealed market</div>
              <div class="text-sm text-slate-300">{@scorecard.sealed_opening_chase_hits} chase hits</div>
            </.panel>

            <.panel title="Loose Packs">
              <div class="text-sm text-slate-300">{@scorecard.loose_pack_units} packs on hand</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.loose_pack_inventory_value)} pack inventory</div>
              <div class="text-sm text-slate-300">{@scorecard.loose_pack_units_prepared} packs prepared</div>
              <div class="text-sm text-slate-300">{@scorecard.loose_pack_units_sold} packs sold</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.loose_pack_revenue)} pack revenue</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.loose_pack_gross_profit)} pack gross profit</div>
            </.panel>

            <.panel title="Special Orders">
              <div class="text-sm text-slate-300">{@scorecard.pending_special_order_units} units pending</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.special_order_liability)} deposit liability</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.special_order_deposits)} deposits collected</div>
              <div class="text-sm text-slate-300">{@scorecard.special_order_units_fulfilled} units fulfilled</div>
              <div class="text-sm text-slate-300">{@scorecard.special_order_units_short} units delayed</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.special_order_revenue)} special-order revenue</div>
            </.panel>

            <.panel title="Overhead">
              <div class="text-sm text-slate-300">$#{money(@scorecard.fixed_overhead)} fixed overhead</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.rent_expense)} rent</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.utilities_expense)} utilities</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.insurance_expense)} insurance</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.operating_expenses)} operating expenses</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.operating_profit)} operating profit</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.net_profit_after_financing)} after financing</div>
            </.panel>

            <.panel title="Staffing">
              <div class="text-sm text-slate-300">{@scorecard.scheduled_staff_shifts} scheduled shifts</div>
              <div class="text-sm text-slate-300">{money(@scorecard.scheduled_staff_hours)} hours booked</div>
              <div class="text-sm text-slate-300">{money(@scorecard.scheduled_staff_hours_used)} hours used</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.scheduled_staff_cost)} scheduled labor</div>
              <div class="text-sm text-slate-300">{money(@scorecard.overtime_hours)} overtime hours</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.total_labor_cost)} total labor</div>
            </.panel>

            <.panel title="Financing">
              <div class="text-sm text-slate-300">$#{money(@scorecard.credit_line_balance)} balance</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.credit_line_available)} available</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.credit_line_draws)} drawn</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.credit_line_repayments)} repaid</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.credit_line_interest)} interest</div>
            </.panel>

            <.panel title="Consignment">
              <div class="text-sm text-slate-300">{@scorecard.consignment_lots_open} open lots</div>
              <div class="text-sm text-slate-300">{@scorecard.consignment_cards_remaining} cards remaining</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.consignment_revenue)} sales</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.consignment_commission)} commission</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.consignment_payable)} payable</div>
            </.panel>

            <.panel title="Memberships">
              <div class="text-sm text-slate-300">{@scorecard.active_memberships} active members</div>
              <div class="text-sm text-slate-300">{@scorecard.active_membership_batches} active batches</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.membership_liability)} deferred liability</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.membership_revenue_collected)} collected</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.membership_revenue_recognized)} recognized</div>
            </.panel>

            <.panel title="Refunds">
              <div class="text-sm text-slate-300">$#{money(@scorecard.refund_amount)} refunded</div>
              <div class="text-sm text-slate-300">{@scorecard.refund_count} refund records</div>
              <div class="text-sm text-slate-300">{@scorecard.chargeback_count} chargebacks</div>
              <div class="text-sm text-slate-300">{@scorecard.customer_returns} customer returns</div>
              <div class="text-sm text-slate-300">{@scorecard.returned_units} returned units</div>
              <div class="text-sm text-slate-300">{@scorecard.returned_inventory_units} restocked units</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.return_writeoff_loss)} return writeoff</div>
            </.panel>

            <.panel title="Supplier Credit">
              <div class="text-sm text-slate-300">$#{money(@scorecard.accounts_payable)} accounts payable</div>
              <div class="text-sm text-slate-300">{money(@scorecard.average_supplier_standing)} standing</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.supplier_credit_limit_effective)} effective limit</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.supplier_credit_available)} credit available</div>
              <div class="text-sm text-slate-300">{@scorecard.preferred_supplier_accounts} preferred accounts</div>
              <div class="text-sm text-slate-300">{@scorecard.strained_supplier_accounts} strained accounts</div>
              <div class="text-sm text-slate-300">{@scorecard.supplier_invoices_open} open invoices</div>
              <div class="text-sm text-slate-300">{@scorecard.supplier_invoices_overdue} overdue invoices</div>
              <div class="text-sm text-slate-300">{@scorecard.damaged_delivery_units} damaged units received</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.supplier_claim_credits)} claim credits</div>
            </.panel>

            <.panel title="Store Credit">
              <div class="text-sm text-slate-300">$#{money(@scorecard.store_credit_liability)} liability</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.store_credit_issued)} issued</div>
              <div class="text-sm text-slate-300">$#{money(@scorecard.store_credit_redeemed)} redeemed</div>
            </.panel>

            <.panel title="Failure Modes">
              <%= if @scorecard.failure_modes == [] do %>
                <div class="text-sm text-emerald-300">No active failure modes</div>
              <% else %>
                <div class="space-y-2">
                  <%= for failure <- @scorecard.failure_modes do %>
                    <div class="rounded border border-red-500/25 bg-red-950/30 p-2">
                      <div class="text-xs uppercase tracking-wider text-red-300 font-mono">{get(failure, :id, "unknown")}</div>
                      <div class="text-xs text-slate-300">{get(failure, :description, "")}</div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </.panel>

            <.panel title="Customer Queue">
              <div class="space-y-2">
                <%= for customer <- Enum.take(get(@world, :customer_queue, []), 5) do %>
                  <div class="rounded border border-slate-700/70 bg-slate-950/60 p-2">
                    <div class="text-xs uppercase tracking-wider text-cyan-300">{get(customer, :name, get(customer, :type, "customer"))}</div>
                    <div class="text-sm text-slate-200">{get(customer, :need, "")}</div>
                    <div class="mt-1 text-[11px] text-slate-500">
                      loyalty {get(customer, :loyalty, "?")} / satisfaction {get(customer, :satisfaction, "?")}
                    </div>
                  </div>
                <% end %>
              </div>
            </.panel>

            <.panel title="Recent Activity">
              <div class="space-y-2">
                <%= for sale <- Enum.take(Enum.reverse(get(@world, :sales_history, [])), 6) do %>
                  <div class="flex justify-between gap-2 text-xs">
                    <span class="text-slate-400 truncate">{activity_label(sale)}</span>
                    <span class="text-emerald-300 font-mono shrink-0">$#{money(get(sale, :revenue, get(sale, :attach_sales, 0.0)))}</span>
                  </div>
                <% end %>
              </div>
            </.panel>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="rounded-md border border-slate-700 bg-slate-950/60 px-3 py-2">
      <div class="text-[10px] uppercase tracking-widest text-slate-500">{@label}</div>
      <div class="text-sm font-mono text-slate-100 whitespace-nowrap">{@value}</div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-slate-700/80 bg-slate-900/70 p-4">
      <div class="text-[10px] uppercase tracking-[0.2em] text-slate-500 font-mono mb-3">{@title}</div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp inventory_rows(world) do
    world
    |> get(:inventory, %{})
    |> Enum.sort_by(fn {line_id, _item} -> line_id end)
  end

  defp catalog_line(world, line_id) do
    world
    |> get(:catalog, %{})
    |> Map.get(line_id, %{})
  end

  defp franchise_border("Pokemon"), do: "border-yellow-400/35"
  defp franchise_border("Yu-Gi-Oh!"), do: "border-violet-400/35"
  defp franchise_border("One Piece"), do: "border-red-400/35"
  defp franchise_border("Dragon Ball Super"), do: "border-orange-400/35"
  defp franchise_border(_), do: "border-cyan-400/25"

  defp activity_label(sale) do
    get(sale, :line_id, get(sale, :game, get(sale, :packing_quality, "shop activity")))
  end

  defp get(map, key, default) when is_map(map), do: MapHelpers.get_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp money(value), do: :erlang.float_to_binary((value || 0) + 0.0, decimals: 2)
end
