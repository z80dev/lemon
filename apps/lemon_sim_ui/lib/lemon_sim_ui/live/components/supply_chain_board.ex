defmodule LemonSimUi.Live.Components.SupplyChainBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    tiers = MapHelpers.get_key(world, :tiers) || %{}
    phase = MapHelpers.get_key(world, :phase) || "observe"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 20
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    messages = MapHelpers.get_key(world, :messages) || %{}
    message_log = MapHelpers.get_key(world, :message_log) || []
    consumer_demand = MapHelpers.get_key(world, :consumer_demand) || 0
    demand_history = MapHelpers.get_key(world, :demand_history) || []
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    team_bonus = MapHelpers.get_key(world, :team_bonus) || false
    total_chain_cost = MapHelpers.get_key(world, :total_chain_cost)
    costs = MapHelpers.get_key(world, :costs) || %{}
    journals = MapHelpers.get_key(world, :journals) || %{}

    tier_order = ["retailer", "distributor", "factory", "raw_materials"]

    # Build sorted tier list (by total_cost ascending = best first)
    sorted_tiers =
      tier_order
      |> Enum.map(fn tier_id ->
        tdata = Map.get(tiers, tier_id, %{})
        cost = get_val(tdata, :total_cost, 0.0)
        inv = get_val(tdata, :inventory, 0)
        backlog = get_val(tdata, :backlog, 0)
        {tier_id, tdata, cost, inv, backlog}
      end)

    # Recent messages
    recent_messages =
      message_log
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Active tier info
    active_tier_data =
      if active_actor_id do
        tid = to_string(active_actor_id)
        Map.get(tiers, active_actor_id) || Map.get(tiers, tid, %{})
      else
        %{}
      end

    active_role = get_val(active_tier_data, :role, to_string(active_actor_id || ""))

    # Total chain cost (computed if not stored)
    computed_chain_cost =
      total_chain_cost ||
        Enum.sum(Enum.map(tier_order, fn tid ->
          t = Map.get(tiers, tid, %{})
          get_val(t, :total_cost, 0.0)
        end))

    holding_rate = get_val(costs, :holding_cost_per_unit, 0.5)
    stockout_rate = get_val(costs, :stockout_penalty_per_unit, 2.0)

    assigns =
      assigns
      |> assign(:tiers, tiers)
      |> assign(:tier_order, tier_order)
      |> assign(:sorted_tiers, sorted_tiers)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_role, active_role)
      |> assign(:messages, messages)
      |> assign(:message_log, message_log)
      |> assign(:recent_messages, recent_messages)
      |> assign(:consumer_demand, consumer_demand)
      |> assign(:demand_history, demand_history)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:team_bonus, team_bonus)
      |> assign(:total_chain_cost, computed_chain_cost)
      |> assign(:holding_rate, holding_rate)
      |> assign(:stockout_rate, stockout_rate)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative w-full font-sans" style="background: #080c14; color: #e2e8f0; min-height: 640px;">
      <style>
        /* ── Tier Pulse ── */
        @keyframes sc-tier-pulse {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.12); }
        }
        .sc-tier-active { animation: sc-tier-pulse 2.5s ease-in-out infinite; }

        /* ── Flow Arrow ── */
        @keyframes sc-flow {
          0% { opacity: 0.3; transform: translateX(-4px); }
          50% { opacity: 1; }
          100% { opacity: 0.3; transform: translateX(4px); }
        }
        .sc-flow-arrow { animation: sc-flow 1.8s ease-in-out infinite; }

        /* ── Phase Breathe ── */
        @keyframes sc-phase-breathe {
          0%, 100% { opacity: 0.6; }
          50% { opacity: 1; }
        }
        .sc-phase-active { animation: sc-phase-breathe 2s ease-in-out infinite; }

        /* ── Victory Flash ── */
        @keyframes sc-victory-enter {
          from { opacity: 0; transform: scale(0.85) translateY(16px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .sc-victory { animation: sc-victory-enter 0.7s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Cost Bar ── */
        @keyframes sc-bar-grow {
          from { width: 0%; }
        }
        .sc-bar { animation: sc-bar-grow 0.6s ease-out forwards; }

        /* ── Scanline ── */
        @keyframes sc-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .sc-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(16, 185, 129, 0.12), transparent);
          animation: sc-scanline 5s linear infinite;
          pointer-events: none;
        }

        /* ── Message Fade ── */
        @keyframes sc-msg-in {
          from { opacity: 0; transform: translateY(5px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .sc-msg-item { animation: sc-msg-in 0.3s ease-out forwards; }

        /* ── Stockout warning ── */
        @keyframes sc-stockout {
          0%, 100% { border-color: rgba(239, 68, 68, 0.3); }
          50% { border-color: rgba(239, 68, 68, 0.9); box-shadow: 0 0 16px rgba(239, 68, 68, 0.3); }
        }
        .sc-stockout { animation: sc-stockout 1.5s ease-in-out infinite; }
      </style>

      <%!-- ═══════════════ STATUS BAR ═══════════════ --%>
      <div class="relative overflow-hidden" style="background: linear-gradient(90deg, rgba(16, 185, 129, 0.08), rgba(8, 12, 20, 0.9), rgba(59, 130, 246, 0.08)); border-bottom: 1px solid rgba(16, 185, 129, 0.15);">
        <div class="sc-scanline relative px-4 py-2.5 flex items-center justify-between">
          <%!-- Left: Game Identity --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-emerald-400 sc-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.25em] uppercase text-emerald-400/70">SUPPLY CHAIN</span>
            </div>
            <div class="h-4 w-px bg-emerald-900/30"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-mono text-gray-500">RND</span>
              <span class="text-sm font-black text-white tabular-nums">{@round}</span>
              <span class="text-[10px] text-gray-600">/ {@max_rounds}</span>
            </div>
          </div>

          <%!-- Center: Phase Badge --%>
          <div class="flex items-center gap-2">
            <div class={["px-3 py-1 rounded-full border text-[10px] font-bold tracking-wider uppercase", phase_badge_class(@phase)]}>
              {phase_label(@phase)}
            </div>
            <div :if={@consumer_demand > 0} class="text-[10px] text-emerald-400/60 tabular-nums">
              demand: {@consumer_demand}
            </div>
          </div>

          <%!-- Right: Active Tier + Cost --%>
          <div class="flex items-center gap-3">
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full sc-phase-active" style={"background: #{tier_color(to_string(@active_actor_id || ""))};"} />
              <span class="text-[10px] font-bold" style={"color: #{tier_color(to_string(@active_actor_id || ""))};"}>
                {tier_short_name(to_string(@active_actor_id || ""))}
              </span>
            </div>
            <div class="h-4 w-px bg-emerald-900/30"></div>
            <div class="flex items-center gap-1">
              <span class="text-[10px] text-gray-500">CHAIN</span>
              <span class="text-[10px] font-bold text-amber-400">${format_cost(@total_chain_cost)}</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
      <div class="flex" style="min-height: 580px;">

        <%!-- ──── LEFT: SUPPLY CHAIN PIPELINE ──── --%>
        <div class="flex-1 p-4 overflow-y-auto">

          <%!-- Chain Header --%>
          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full bg-emerald-500/70"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-emerald-400/50">SUPPLY PIPELINE</span>
            <div class="flex-1 h-px bg-gradient-to-r from-emerald-900/30 to-transparent"></div>
            <span class="text-[9px] text-gray-600 tracking-wider">RAW MATERIALS &#x2192; CONSUMERS</span>
          </div>

          <%!-- Supply Chain Tiers - Left to right: raw_materials -> factory -> distributor -> retailer --%>
          <div class="relative rounded-xl overflow-hidden" style="background: linear-gradient(135deg, rgba(15, 23, 42, 0.85), rgba(8, 12, 20, 0.95)); border: 1px solid rgba(16, 185, 129, 0.1);">
            <div class="absolute inset-0 opacity-[0.025]" style="background-image: linear-gradient(rgba(16, 185, 129, 0.5) 1px, transparent 1px), linear-gradient(90deg, rgba(16, 185, 129, 0.5) 1px, transparent 1px); background-size: 32px 32px;"></div>

            <div class="relative p-4">
              <div class="flex items-stretch gap-0">
                <%= for tier_id <- ["raw_materials", "factory", "distributor", "retailer"] do %>
                  <% tdata = Map.get(@tiers, tier_id, %{}) %>
                  <% inv = get_val(tdata, :inventory, 0) %>
                  <% backlog = get_val(tdata, :backlog, 0) %>
                  <% total_cost = get_val(tdata, :total_cost, 0.0) %>
                  <% safety_stock = get_val(tdata, :safety_stock, 0) %>
                  <% incoming = get_val(tdata, :incoming_deliveries, []) %>
                  <% incoming_qty = Enum.sum(Enum.map(incoming, fn d -> get_val(d, :quantity, 0) end)) %>
                  <% pending_order = get_val(tdata, :pending_order, 0) %>
                  <% is_active = to_string(@active_actor_id || "") == tier_id %>
                  <% is_winner = to_string(@winner || "") == tier_id %>
                  <% color = tier_color(tier_id) %>
                  <% has_stockout = backlog > 0 %>

                  <%!-- Tier Box --%>
                  <div class="flex-1 min-w-0">
                    <div
                      class={[
                        "rounded-xl p-3 h-full transition-all duration-300",
                        if(is_active, do: "sc-tier-active", else: ""),
                        if(has_stockout and is_active, do: "sc-stockout", else: "")
                      ]}
                      style={"background: #{tier_bg(color)}; border: 1px solid #{if is_winner, do: "#fbbf24", else: if(is_active, do: color, else: color <> "30")}; #{if is_winner, do: "box-shadow: 0 0 20px #fbbf2430;", else: if(is_active, do: "box-shadow: 0 0 16px " <> color <> "25;", else: "")}"}
                    >
                      <%!-- Tier Name --%>
                      <div class="text-center mb-2">
                        <span
                          class="text-[10px] font-black tracking-wider uppercase"
                          style={"color: #{color};"}
                        >
                          {tier_short_name(tier_id)}
                        </span>
                        <%= if is_winner do %>
                          <div class="text-[8px] font-bold text-amber-400 sc-victory">WINNER</div>
                        <% end %>
                        <%= if is_active and @game_status == "in_progress" do %>
                          <div class="w-1.5 h-1.5 rounded-full mx-auto mt-0.5 sc-phase-active" style={"background: #{color};"} />
                        <% end %>
                      </div>

                      <%!-- Inventory --%>
                      <div class="mb-2">
                        <div class="flex items-center justify-between mb-1">
                          <span class="text-[9px] text-gray-500">Inventory</span>
                          <span class="text-sm font-black tabular-nums" style={"color: #{color};"}>{inv}</span>
                        </div>
                        <div class="h-1.5 rounded-full overflow-hidden" style="background: rgba(0,0,0,0.4);">
                          <div
                            class="h-full rounded-full sc-bar"
                            style={"width: #{min(trunc(inv / 40 * 100), 100)}%; background: #{color}; opacity: 0.7;"}
                          />
                        </div>
                        <%!-- Safety stock marker --%>
                        <%= if safety_stock > 0 do %>
                          <div class="relative h-0">
                            <div
                              class="absolute top-[-6px] w-px h-2.5"
                              style={"left: #{min(trunc(safety_stock / 40 * 100), 100)}%; background: rgba(16, 185, 129, 0.8);"}
                              title={"Safety stock: #{safety_stock}"}
                            />
                          </div>
                        <% end %>
                      </div>

                      <%!-- Backlog --%>
                      <div class="flex items-center justify-between mb-1.5">
                        <span class="text-[9px] text-gray-500">Backlog</span>
                        <span class={["text-xs font-bold tabular-nums", if(backlog > 0, do: "text-red-400", else: "text-gray-600")]}>
                          {backlog}
                        </span>
                      </div>

                      <%!-- In Transit --%>
                      <div class="flex items-center justify-between mb-1.5">
                        <span class="text-[9px] text-gray-500">In Transit</span>
                        <span class="text-xs text-gray-400 tabular-nums">{incoming_qty}</span>
                      </div>

                      <%!-- Pending Order --%>
                      <%= if pending_order > 0 do %>
                        <div class="flex items-center justify-between mb-1.5">
                          <span class="text-[9px] text-gray-500">Ordering</span>
                          <span class="text-xs font-bold tabular-nums" style={"color: #{color}"}>{pending_order}</span>
                        </div>
                      <% end %>

                      <%!-- Total Cost --%>
                      <div class="flex items-center justify-between mt-2 pt-2" style="border-top: 1px solid rgba(255,255,255,0.06);">
                        <span class="text-[9px] text-gray-500">Total Cost</span>
                        <span class={["text-[10px] font-bold tabular-nums", cost_class(total_cost)]}>
                          ${format_cost(total_cost)}
                        </span>
                      </div>
                    </div>
                  </div>

                  <%!-- Flow Arrow between tiers --%>
                  <%= if tier_id != "retailer" do %>
                    <div class="flex items-center px-1 sc-flow-arrow">
                      <div style="color: rgba(16, 185, 129, 0.5); font-size: 18px;">&#x2192;</div>
                    </div>
                  <% end %>
                <% end %>

                <%!-- Consumer Block --%>
                <div class="flex items-center px-1 sc-flow-arrow">
                  <div style="color: rgba(16, 185, 129, 0.5); font-size: 18px;">&#x2192;</div>
                </div>
                <div style="min-width: 72px;">
                  <div class="rounded-xl p-3 text-center h-full" style="background: rgba(16, 185, 129, 0.06); border: 1px solid rgba(16, 185, 129, 0.2);">
                    <div class="text-[9px] font-bold tracking-wider uppercase text-emerald-400/60 mb-1">CONSUMERS</div>
                    <div class="text-xl font-black text-white tabular-nums">{@consumer_demand}</div>
                    <div class="text-[8px] text-gray-500 mt-0.5">units</div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- ──── COST RANKINGS ──── --%>
          <div class="mt-4">
            <div class="flex items-center gap-2 mb-2.5">
              <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">COST RANKINGS</span>
              <div class="flex-1 h-px bg-gradient-to-r from-amber-900/20 to-transparent"></div>
              <%= if @team_bonus do %>
                <span class="text-[9px] font-bold text-emerald-400 tracking-wide">TEAM BONUS EARNED</span>
              <% end %>
            </div>

            <div class="space-y-1.5">
              <%= for {tier_id, tdata, cost, inv, backlog} <- Enum.sort_by(@sorted_tiers, fn {_, _, c, _, _} -> c end) do %>
                <% color = tier_color(tier_id) %>
                <% fill_rate = compute_fill_rate(tdata) %>
                <% is_winner = to_string(@winner || "") == tier_id %>
                <div
                  class="flex items-center gap-2 px-3 py-2 rounded-lg"
                  style={"background: #{if is_winner, do: "rgba(251, 191, 36, 0.08)", else: "rgba(15, 23, 42, 0.6)"}; border: 1px solid #{if is_winner, do: "#fbbf2440", else: color <> "20"};"}
                >
                  <div class="w-2 h-2 rounded-full flex-shrink-0" style={"background: #{color};"}></div>
                  <span class="text-[10px] font-bold flex-1" style={"color: #{color};"}>
                    {tier_short_name(tier_id)}
                    <%= if is_winner do %><span class="text-amber-400 ml-1">[WIN]</span><% end %>
                  </span>
                  <span class="text-[10px] text-gray-500">inv: {inv}</span>
                  <span class={["text-[10px]", if(backlog > 0, do: "text-red-400", else: "text-gray-600")]}>
                    <%= if backlog > 0 do %>back: {backlog}<% else %>ok<% end %>
                  </span>
                  <span class="text-[10px] text-gray-500">fill: {fill_rate}</span>
                  <span class={["text-[11px] font-bold tabular-nums", cost_class(cost)]}>
                    ${format_cost(cost)}
                  </span>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- ──── DEMAND SPARKLINE ──── --%>
          <%= if length(@demand_history) > 1 do %>
            <div class="mt-4">
              <div class="flex items-center gap-2 mb-2">
                <div class="w-1.5 h-1.5 rounded-full bg-blue-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-blue-400/50">CONSUMER DEMAND TREND</span>
              </div>
              <div class="rounded-lg p-3" style="background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(59, 130, 246, 0.15);">
                <svg width="100%" height="48" style="overflow: visible;">
                  <% recent = Enum.take(@demand_history, -20) %>
                  <% max_d = Enum.max(recent) %>
                  <% n = length(recent) %>
                  <%= if n > 1 do %>
                    <polyline
                      points={
                        recent
                        |> Enum.with_index()
                        |> Enum.map(fn {d, i} ->
                          x = trunc(i * 100 / (n - 1))
                          y = trunc((1 - d / max_d) * 40 + 4)
                          "#{x}%,#{y}"
                        end)
                        |> Enum.join(" ")
                      }
                      fill="none"
                      stroke="rgba(59, 130, 246, 0.7)"
                      stroke-width="1.5"
                    />
                  <% end %>
                </svg>
                <div class="flex justify-between mt-1">
                  <span class="text-[8px] text-gray-600">Round {max(1, @round - length(@demand_history) + 1)}</span>
                  <span class="text-[8px] text-gray-600">Round {@round - 1}</span>
                </div>
              </div>
            </div>
          <% end %>

        </div>

        <%!-- ──── RIGHT: COMMS + INTEL ──── --%>
        <div class="w-72 border-l flex flex-col" style="border-color: rgba(16, 185, 129, 0.1); background: rgba(8, 12, 20, 0.6);">

          <%!-- Active Tier Intel --%>
          <%= if @active_actor_id && @game_status == "in_progress" do %>
            <% tid = to_string(@active_actor_id) %>
            <% color = tier_color(tid) %>
            <div class="p-3 border-b" style={"border-color: rgba(16, 185, 129, 0.08); background: #{tier_bg(color)}20;"}>
              <div class="flex items-center gap-2 mb-1">
                <div class="w-1.5 h-1.5 rounded-full sc-phase-active" style={"background: #{color};"}></div>
                <span class="text-[10px] font-bold tracking-wider uppercase" style={"color: #{color};"}>
                  {tier_short_name(tid)} — DECIDING
                </span>
              </div>
              <div class="text-[9px] text-gray-500 truncate">{@active_role}</div>
              <div class="mt-1.5 flex items-center gap-2">
                <span class={["px-2 py-0.5 rounded text-[9px] font-bold", phase_badge_class(@phase)]}>
                  {phase_label(@phase)}
                </span>
                <span class="text-[9px] text-gray-600">step #{@round}</span>
              </div>
            </div>
          <% end %>

          <%!-- Comms Log --%>
          <div class="flex-1 overflow-y-auto p-3">
            <div class="flex items-center gap-1.5 mb-2">
              <div class="w-1 h-1 rounded-full bg-blue-400/50"></div>
              <span class="text-[9px] font-bold tracking-[0.2em] uppercase text-blue-400/40">COMMS LOG</span>
            </div>

            <%= if @recent_messages == [] do %>
              <div class="text-center py-6">
                <div class="text-[10px] text-gray-600">No messages exchanged yet</div>
              </div>
            <% else %>
              <div class="space-y-1.5">
                <%= for msg <- @recent_messages do %>
                  <% from_id = to_string(get_val(msg, :from, get_msg_val(msg, "from", "?"))) %>
                  <% to_id = to_string(get_val(msg, :to, get_msg_val(msg, "to", "?"))) %>
                  <% msg_type = get_val(msg, :type, get_msg_val(msg, "type", "message")) %>
                  <% msg_round = get_val(msg, :round, get_msg_val(msg, "round", "?")) %>
                  <% from_color = tier_color(from_id) %>
                  <% to_color = tier_color(to_id) %>
                  <div class="sc-msg-item rounded-lg px-2.5 py-2" style="background: rgba(15, 23, 42, 0.7); border: 1px solid rgba(255,255,255,0.05);">
                    <div class="flex items-center gap-1.5 mb-0.5">
                      <div class="w-2 h-2 rounded-full flex-shrink-0" style={"background: #{from_color};"}></div>
                      <span class="text-[9px] font-bold truncate" style={"color: #{from_color};"}>
                        {tier_short_name(from_id)}
                      </span>
                      <span class="text-[8px] text-gray-600">&#x2192;</span>
                      <div class="w-2 h-2 rounded-full flex-shrink-0" style={"background: #{to_color};"}></div>
                      <span class="text-[9px] truncate" style={"color: #{to_color};"}>
                        {tier_short_name(to_id)}
                      </span>
                      <span class="ml-auto text-[8px] text-gray-600 flex-shrink-0">R{msg_round}</span>
                    </div>
                    <div class="text-[8px] text-gray-500 pl-3.5">
                      {msg_type_label(msg_type)}
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Cost Structure Reminder --%>
          <div class="p-3 border-t" style="border-color: rgba(16, 185, 129, 0.08);">
            <div class="text-[9px] font-bold tracking-wider uppercase text-gray-600 mb-1.5">COST RATES</div>
            <div class="space-y-1">
              <div class="flex justify-between">
                <span class="text-[9px] text-gray-500">Holding / unit</span>
                <span class="text-[9px] font-mono text-amber-400/80">${@holding_rate}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-[9px] text-gray-500">Stockout / unit</span>
                <span class="text-[9px] font-mono text-red-400/80">${@stockout_rate}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-[9px] text-gray-500">Delivery delay</span>
                <span class="text-[9px] font-mono text-gray-400">2 rounds</span>
              </div>
            </div>
            <%= if @game_status == "won" do %>
              <div class="mt-2 pt-2 border-t" style="border-color: rgba(251, 191, 36, 0.15);">
                <div class="text-center text-[10px] font-bold text-amber-400">
                  {tier_short_name(to_string(@winner || "?"))} wins!
                </div>
                <%= if @team_bonus do %>
                  <div class="text-center text-[9px] text-emerald-400 mt-0.5">Team bonus earned!</div>
                <% end %>
              </div>
            <% end %>
          </div>

        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp tier_color("retailer"), do: "#3b82f6"
  defp tier_color("distributor"), do: "#f59e0b"
  defp tier_color("factory"), do: "#10b981"
  defp tier_color("raw_materials"), do: "#8b5cf6"
  defp tier_color(_), do: "#94a3b8"

  defp tier_bg(color), do: "#{color}08"

  defp tier_short_name("retailer"), do: "Retailer"
  defp tier_short_name("distributor"), do: "Distributor"
  defp tier_short_name("factory"), do: "Factory"
  defp tier_short_name("raw_materials"), do: "Raw Materials"
  defp tier_short_name(other), do: other

  defp phase_label("observe"), do: "Observe"
  defp phase_label("communicate"), do: "Communicate"
  defp phase_label("order"), do: "Order"
  defp phase_label("fulfill"), do: "Fulfill"
  defp phase_label("accounting"), do: "Accounting"
  defp phase_label(other), do: String.capitalize(other)

  defp phase_badge_class("observe"),
    do: "bg-blue-500/10 border-blue-500/30 text-blue-400"

  defp phase_badge_class("communicate"),
    do: "bg-amber-500/10 border-amber-500/30 text-amber-400"

  defp phase_badge_class("order"),
    do: "bg-emerald-500/10 border-emerald-500/30 text-emerald-400"

  defp phase_badge_class("fulfill"),
    do: "bg-purple-500/10 border-purple-500/30 text-purple-400"

  defp phase_badge_class("accounting"),
    do: "bg-pink-500/10 border-pink-500/30 text-pink-400"

  defp phase_badge_class(_),
    do: "bg-gray-500/10 border-gray-500/30 text-gray-400"

  defp cost_class(cost) when is_number(cost) and cost > 200.0, do: "text-red-400"
  defp cost_class(cost) when is_number(cost) and cost > 100.0, do: "text-amber-400"
  defp cost_class(_), do: "text-gray-300"

  defp format_cost(cost) when is_float(cost), do: Float.round(cost, 1) |> to_string()
  defp format_cost(cost) when is_integer(cost), do: "#{cost}.0"
  defp format_cost(nil), do: "0.0"
  defp format_cost(other), do: to_string(other)

  defp msg_type_label("forecast"), do: "Demand forecast shared"
  defp msg_type_label("request"), do: "Info request sent"
  defp msg_type_label(other), do: String.capitalize(to_string(other))

  defp compute_fill_rate(tdata) do
    fulfilled = get_val(tdata, :orders_fulfilled, 0)
    received = get_val(tdata, :orders_received, 0)

    if received > 0 do
      pct = Float.round(fulfilled / received * 100, 0) |> trunc()
      "#{pct}%"
    else
      "N/A"
    end
  end

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key), default)
      val -> val
    end
  end

  defp get_val(_, _, default), do: default

  defp get_msg_val(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp get_msg_val(_, _, default), do: default
end
