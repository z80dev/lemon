defmodule LemonSimUi.Live.Components.DiplomacyBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    territories = MapHelpers.get_key(world, :territories) || %{}
    adjacency = MapHelpers.get_key(world, :adjacency) || %{}
    players = MapHelpers.get_key(world, :players) || %{}
    phase = MapHelpers.get_key(world, :phase) || "diplomacy"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 10
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    private_messages = MapHelpers.get_key(world, :private_messages) || %{}
    message_history = MapHelpers.get_key(world, :message_history) || []
    pending_orders = MapHelpers.get_key(world, :pending_orders) || %{}
    orders_submitted = MapHelpers.get_key(world, :orders_submitted) || []
    order_history = MapHelpers.get_key(world, :order_history) || []
    capture_history = MapHelpers.get_key(world, :capture_history) || []
    resolution_log = MapHelpers.get_key(world, :resolution_log) || []
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    traits = MapHelpers.get_key(world, :traits) || %{}
    connections = MapHelpers.get_key(world, :connections) || []
    journals = MapHelpers.get_key(world, :journals) || %{}

    # Territory grid layout: 4 rows x 3 columns
    # Row 1: northland, highland, eastmarch
    # Row 2: westwood, central, eastwood
    # Row 3: southmoor, lowland, southeast
    # Row 4: farwest, badlands, fareast
    territory_grid = [
      ["northland", "highland", "eastmarch"],
      ["westwood", "central", "eastwood"],
      ["southmoor", "lowland", "southeast"],
      ["farwest", "badlands", "fareast"]
    ]

    # Build sorted player list with territory counts
    sorted_players =
      players
      |> Enum.map(fn {pid, pdata} ->
        pid_str = to_string(pid)

        owned =
          territories
          |> Enum.filter(fn {_tname, tdata} ->
            owner = get_val(tdata, :owner, nil)
            owner != nil and to_string(owner) == pid_str
          end)
          |> Enum.map(fn {tname, _} -> to_string(tname) end)
          |> Enum.sort()

        {pid_str, pdata, owned, length(owned)}
      end)
      |> Enum.sort_by(fn {_, _, _, count} -> count end, :desc)

    max_territories = 12

    # Active player faction info
    active_player_data =
      if active_actor_id do
        pid_str = to_string(active_actor_id)
        Map.get(players, active_actor_id) || Map.get(players, pid_str, %{})
      else
        %{}
      end

    active_faction = get_val(active_player_data, :faction, "Unknown")

    # Recent messages (last 8 from message_history)
    recent_messages =
      message_history
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Recent captures (last 6)
    recent_captures =
      capture_history
      |> Enum.reverse()
      |> Enum.take(6)
      |> Enum.reverse()

    # Orders submitted count
    submitted_count =
      cond do
        is_list(orders_submitted) -> length(orders_submitted)
        is_map(orders_submitted) -> map_size(orders_submitted)
        true -> 0
      end

    total_players =
      players
      |> Enum.count(fn {_pid, pd} -> get_val(pd, :status, "alive") == "alive" end)

    assigns =
      assigns
      |> assign(:territories, territories)
      |> assign(:adjacency, adjacency)
      |> assign(:players, players)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_faction, active_faction)
      |> assign(:turn_order, turn_order)
      |> assign(:private_messages, private_messages)
      |> assign(:message_history, message_history)
      |> assign(:recent_messages, recent_messages)
      |> assign(:pending_orders, pending_orders)
      |> assign(:orders_submitted, orders_submitted)
      |> assign(:submitted_count, submitted_count)
      |> assign(:total_players, total_players)
      |> assign(:order_history, order_history)
      |> assign(:capture_history, capture_history)
      |> assign(:recent_captures, recent_captures)
      |> assign(:resolution_log, resolution_log)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:territory_grid, territory_grid)
      |> assign(:sorted_players, sorted_players)
      |> assign(:max_territories, max_territories)
      |> assign(:traits, traits)
      |> assign(:connections, connections)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0a0e1a; color: #e2e8f0; min-height: 640px;">
      <style>
        /* ── Territory Pulse ── */
        @keyframes dip-territory-pulse {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.15); }
        }
        .dip-territory-active { animation: dip-territory-pulse 2.5s ease-in-out infinite; }

        /* ── Command Glow ── */
        @keyframes dip-cmd-glow {
          0%, 100% { box-shadow: 0 0 8px 2px rgba(6, 182, 212, 0.2); }
          50% { box-shadow: 0 0 20px 6px rgba(6, 182, 212, 0.5); }
        }
        .dip-cmd-active { animation: dip-cmd-glow 2s ease-in-out infinite; }

        /* ── Scanline ── */
        @keyframes dip-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .dip-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(6, 182, 212, 0.15), transparent);
          animation: dip-scanline 4s linear infinite;
          pointer-events: none;
        }

        /* ── Territory Capture Flash ── */
        @keyframes dip-capture-flash {
          0% { box-shadow: 0 0 0 0 rgba(251, 191, 36, 0.7); }
          50% { box-shadow: 0 0 24px 8px rgba(251, 191, 36, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(251, 191, 36, 0); }
        }
        .dip-captured { animation: dip-capture-flash 2s ease-out; }

        /* ── Phase Indicator ── */
        @keyframes dip-phase-breathe {
          0%, 100% { opacity: 0.6; }
          50% { opacity: 1; }
        }
        .dip-phase-active { animation: dip-phase-breathe 2s ease-in-out infinite; }

        /* ── Army Badge Bounce ── */
        @keyframes dip-army-bounce {
          0%, 100% { transform: scale(1); }
          50% { transform: scale(1.08); }
        }
        .dip-army-badge:hover { animation: dip-army-bounce 0.6s ease-in-out; }

        /* ── Victory Entrance ── */
        @keyframes dip-victory-enter {
          from { opacity: 0; transform: scale(0.8) translateY(20px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .dip-victory { animation: dip-victory-enter 0.8s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Intel Fade In ── */
        @keyframes dip-intel-in {
          from { opacity: 0; transform: translateY(6px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .dip-intel-item { animation: dip-intel-in 0.3s ease-out forwards; }

        /* ── Grid Connection Lines ── */
        .dip-grid-cell {
          position: relative;
        }

        /* ── Neon text shadows ── */
        .dip-neon-cyan { text-shadow: 0 0 8px rgba(6, 182, 212, 0.5); }
        .dip-neon-red { text-shadow: 0 0 8px rgba(239, 68, 68, 0.5); }
        .dip-neon-green { text-shadow: 0 0 8px rgba(16, 185, 129, 0.5); }
        .dip-neon-amber { text-shadow: 0 0 8px rgba(245, 158, 11, 0.5); }
        .dip-neon-purple { text-shadow: 0 0 8px rgba(168, 85, 247, 0.5); }
        .dip-neon-pink { text-shadow: 0 0 8px rgba(236, 72, 153, 0.5); }

        /* ── Radar sweep for map background ── */
        @keyframes dip-radar {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
        .dip-radar-sweep {
          position: absolute;
          width: 100%; height: 100%;
          background: conic-gradient(from 0deg, transparent 0deg, rgba(6, 182, 212, 0.03) 30deg, transparent 60deg);
          animation: dip-radar 12s linear infinite;
          pointer-events: none;
        }
      </style>

      <%!-- ═══════════════ STATUS BAR ═══════════════ --%>
      <div class="relative overflow-hidden" style="background: linear-gradient(90deg, rgba(6, 182, 212, 0.08), rgba(15, 23, 42, 0.9), rgba(168, 85, 247, 0.08)); border-bottom: 1px solid rgba(6, 182, 212, 0.15);">
        <div class="dip-scanline relative px-4 py-2.5 flex items-center justify-between">
          <%!-- Left: Game Identity --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-cyan-400 dip-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.25em] uppercase text-cyan-400/70">DIPLOMACY</span>
            </div>
            <div class="h-4 w-px bg-cyan-900/30"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-mono text-gray-500">RND</span>
              <span class="text-sm font-black text-white tabular-nums">{@round}</span>
              <span class="text-[10px] text-gray-600">/ {@max_rounds}</span>
            </div>
          </div>

          <%!-- Center: Phase Badge --%>
          <div class="flex items-center gap-2">
            <div class={[
              "px-3 py-1 rounded-full border text-[10px] font-bold tracking-wider uppercase",
              phase_badge_class(@phase)
            ]}>
              {phase_label(@phase)}
            </div>
            <div :if={@phase == "orders"} class="text-[10px] text-gray-500 tabular-nums">
              {@submitted_count}/{@total_players} submitted
            </div>
          </div>

          <%!-- Right: Active Player + Win Threshold --%>
          <div class="flex items-center gap-3">
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full dip-phase-active" style={"background: #{faction_color(to_string(@active_actor_id))};"} />
              <span class="text-[10px] font-bold" style={"color: #{faction_color(to_string(@active_actor_id))};"}>
                {@active_faction}
              </span>
            </div>
            <div class="h-4 w-px bg-cyan-900/30"></div>
            <div class="flex items-center gap-1">
              <span class="text-[10px] text-gray-500">WIN</span>
              <span class="text-[10px] font-bold text-amber-400">7 territories</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
      <div class="flex" style="min-height: 580px;">

        <%!-- ──── LEFT: MAP + SCOREBOARD ──── --%>
        <div class="flex-1 p-4 overflow-y-auto">

          <%!-- Territory Map Header --%>
          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full bg-cyan-500/70"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/50">STRATEGIC COMMAND MAP</span>
            <div class="flex-1 h-px bg-gradient-to-r from-cyan-900/30 to-transparent"></div>
          </div>

          <%!-- Territory Grid Map --%>
          <div class="relative rounded-xl overflow-hidden" style="background: linear-gradient(135deg, rgba(15, 23, 42, 0.8), rgba(10, 15, 30, 0.95)); border: 1px solid rgba(6, 182, 212, 0.1);">
            <%!-- Radar sweep overlay --%>
            <div class="dip-radar-sweep"></div>

            <%!-- Grid background pattern --%>
            <div class="absolute inset-0 opacity-[0.03]" style="background-image: linear-gradient(rgba(6, 182, 212, 0.5) 1px, transparent 1px), linear-gradient(90deg, rgba(6, 182, 212, 0.5) 1px, transparent 1px); background-size: 40px 40px;"></div>

            <div class="relative p-4">
              <%!-- SVG connection lines --%>
              <svg class="absolute inset-0 w-full h-full pointer-events-none" style="z-index: 0;">
                <%!-- Row 1 horizontal connections --%>
                <line x1="16.7%" y1="14%" x2="50%" y2="14%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="50%" y1="14%" x2="83.3%" y2="14%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Row 2 horizontal connections --%>
                <line x1="16.7%" y1="39%" x2="50%" y2="39%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="50%" y1="39%" x2="83.3%" y2="39%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Row 3 horizontal connections --%>
                <line x1="16.7%" y1="64%" x2="50%" y2="64%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="50%" y1="64%" x2="83.3%" y2="64%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Row 4 horizontal connections --%>
                <line x1="16.7%" y1="89%" x2="50%" y2="89%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="50%" y1="89%" x2="83.3%" y2="89%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Vertical connections col 1 --%>
                <line x1="16.7%" y1="14%" x2="16.7%" y2="39%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="16.7%" y1="39%" x2="16.7%" y2="64%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="16.7%" y1="64%" x2="16.7%" y2="89%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Vertical connections col 2 --%>
                <line x1="50%" y1="14%" x2="50%" y2="39%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="50%" y1="39%" x2="50%" y2="64%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="50%" y1="64%" x2="50%" y2="89%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Vertical connections col 3 --%>
                <line x1="83.3%" y1="14%" x2="83.3%" y2="39%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="83.3%" y1="39%" x2="83.3%" y2="64%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <line x1="83.3%" y1="64%" x2="83.3%" y2="89%" stroke="rgba(6, 182, 212, 0.12)" stroke-width="1" stroke-dasharray="4,4" />
                <%!-- Diagonal connections: northland-central, eastmarch-central --%>
                <line x1="16.7%" y1="14%" x2="50%" y2="39%" stroke="rgba(6, 182, 212, 0.08)" stroke-width="1" stroke-dasharray="3,5" />
                <line x1="83.3%" y1="14%" x2="50%" y2="39%" stroke="rgba(6, 182, 212, 0.08)" stroke-width="1" stroke-dasharray="3,5" />
                <%!-- Diagonal connections: westwood-central(bottom), eastwood-central(bottom) --%>
                <line x1="16.7%" y1="39%" x2="50%" y2="64%" stroke="rgba(6, 182, 212, 0.08)" stroke-width="1" stroke-dasharray="3,5" />
                <line x1="83.3%" y1="39%" x2="50%" y2="64%" stroke="rgba(6, 182, 212, 0.08)" stroke-width="1" stroke-dasharray="3,5" />
              </svg>

              <%!-- Territory Grid --%>
              <div class="relative grid grid-cols-3 gap-3" style="z-index: 1;">
                <%= for row <- @territory_grid do %>
                  <%= for tname <- row do %>
                    <% tdata = get_territory(@territories, tname) %>
                    <% owner = get_val(tdata, :owner, nil) %>
                    <% armies = get_val(tdata, :armies, 0) %>
                    <% owner_str = if owner, do: to_string(owner), else: nil %>
                    <% color = if owner_str, do: faction_color(owner_str), else: "#475569" %>
                    <% faction = if owner_str, do: get_faction_name(owner_str, @players), else: "Neutral" %>
                    <% is_recent_capture = is_recently_captured(tname, @capture_history, @round) %>
                    <div
                      class={[
                        "dip-grid-cell rounded-lg p-2.5 text-center transition-all duration-300",
                        if(is_recent_capture, do: "dip-captured", else: ""),
                        if(owner_str, do: "dip-territory-active", else: "")
                      ]}
                      style={"background: #{if owner_str, do: territory_bg(color), else: "rgba(30, 41, 59, 0.3)"}; border: 1px solid #{if owner_str, do: color <> "40", else: "rgba(71, 85, 105, 0.2)"}; #{if owner_str, do: "box-shadow: 0 0 12px " <> color <> "15, inset 0 1px 0 " <> color <> "10;", else: ""}"}
                    >
                      <%!-- Territory Name --%>
                      <div class={[
                        "text-[10px] font-bold tracking-wider uppercase mb-1.5",
                        if(owner_str, do: "", else: "text-gray-500")
                      ]} style={if owner_str, do: "color: #{color};", else: ""}>
                        {territory_display_name(tname)}
                      </div>

                      <%!-- Army Count Badge --%>
                      <div class="flex items-center justify-center gap-1.5">
                        <div
                          class="dip-army-badge inline-flex items-center justify-center w-8 h-8 rounded-full text-sm font-black"
                          style={"background: #{if owner_str, do: color <> "25", else: "rgba(71, 85, 105, 0.15)"}; color: #{if owner_str, do: color, else: "#64748b"}; border: 2px solid #{if owner_str, do: color <> "50", else: "rgba(71, 85, 105, 0.2)"};"}
                        >
                          {armies}
                        </div>
                      </div>

                      <%!-- Owner Faction Tag --%>
                      <div class="mt-1.5">
                        <span
                          class={[
                            "text-[8px] font-semibold tracking-wide uppercase px-1.5 py-0.5 rounded",
                            if(owner_str, do: "", else: "text-gray-600 bg-gray-800/30")
                          ]}
                          style={if owner_str, do: "color: #{color}; background: #{color}15;", else: ""}
                        >
                          {faction}
                        </span>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- ──── PLAYER SCOREBOARD ──── --%>
          <div class="mt-4">
            <div class="flex items-center gap-2 mb-2.5">
              <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">FACTION CONTROL</span>
              <div class="flex-1 h-px bg-gradient-to-r from-amber-900/20 to-transparent"></div>
            </div>

            <div class="space-y-1.5">
              <%= for {pid, pdata, owned_list, terr_count} <- @sorted_players do %>
                <% faction_name = get_val(pdata, :faction, pid) %>
                <% p_status = get_val(pdata, :status, "alive") %>
                <% color = faction_color(pid) %>
                <% bar_pct = min(100, terr_count / @max_territories * 100) %>
                <% win_pct = 7 / @max_territories * 100 %>
                <% is_active = @active_actor_id && to_string(@active_actor_id) == pid %>
                <div
                  class={[
                    "rounded-lg px-3 py-2 transition-all duration-200",
                    if(is_active, do: "dip-cmd-active", else: ""),
                    if(p_status == "eliminated", do: "opacity-40", else: "")
                  ]}
                  style={"background: #{color}08; border: 1px solid #{color}20;"}
                >
                  <% leader_name = get_val(pdata, :name, nil) %>
                  <% leader_trait = get_val(pdata, :trait, nil) %>
                  <div class="flex items-center gap-2 mb-1">
                    <%!-- Faction indicator --%>
                    <div class="w-2.5 h-2.5 rounded-sm" style={"background: #{color}; box-shadow: 0 0 6px #{color}60;"}></div>
                    <span class="text-xs font-bold truncate" style={"color: #{color};"}>{faction_name}</span>
                    <%!-- Leader name + trait badge --%>
                    <span :if={leader_name} class="text-[9px] text-gray-400 italic truncate">{leader_name}</span>
                    <span :if={leader_trait} class="text-[8px] font-semibold px-1.5 py-0.5 rounded-full truncate" style="background: rgba(244, 63, 94, 0.15); color: #fb7185; border: 1px solid rgba(244, 63, 94, 0.25);">
                      {leader_trait}
                    </span>
                    <span class="flex-1"></span>
                    <%!-- Territory count --%>
                    <span class="text-sm font-black tabular-nums text-white">{terr_count}</span>
                    <span class="text-[9px] text-gray-500">territories</span>
                    <%!-- Status badge --%>
                    <span :if={p_status == "eliminated"} class="text-[8px] font-bold px-1.5 py-0.5 rounded bg-red-950/40 border border-red-800/30 text-red-400 uppercase tracking-wider">
                      Eliminated
                    </span>
                  </div>

                  <%!-- Territory Bar --%>
                  <div class="relative h-2 rounded-full overflow-hidden" style="background: rgba(30, 41, 59, 0.5);">
                    <div
                      class="absolute inset-y-0 left-0 rounded-full transition-all duration-700"
                      style={"width: #{bar_pct}%; background: linear-gradient(90deg, #{color}80, #{color});"}
                    />
                    <%!-- Win threshold marker --%>
                    <div
                      class="absolute top-0 bottom-0 w-px"
                      style={"left: #{win_pct}%; background: rgba(251, 191, 36, 0.5);"}
                    />
                  </div>

                  <%!-- Owned territories list --%>
                  <div :if={owned_list != []} class="flex flex-wrap gap-1 mt-1.5">
                    <%= for tname <- owned_list do %>
                      <span class="text-[8px] px-1.5 py-0.5 rounded font-medium" style={"background: #{color}12; color: #{color}; border: 1px solid #{color}20;"}>
                        {territory_short_name(tname)}
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- ──── RIGHT: INTELLIGENCE PANEL ──── --%>
        <div class="w-72 flex-shrink-0 border-l border-cyan-900/15 bg-gray-900/30 flex flex-col overflow-hidden">

          <%!-- Intel Panel Header --%>
          <div class="px-3 py-2 border-b border-cyan-900/15" style="background: linear-gradient(180deg, rgba(6, 182, 212, 0.04), transparent);">
            <div class="flex items-center gap-2">
              <div class="w-1.5 h-1.5 rounded-full bg-cyan-500/70 dip-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/50">INTELLIGENCE</span>
            </div>
          </div>

          <div class="flex-1 overflow-y-auto p-3 space-y-4">

            <%!-- Phase Status Section --%>
            <div class="rounded-lg p-2.5" style="background: rgba(15, 23, 42, 0.5); border: 1px solid rgba(6, 182, 212, 0.1);">
              <div class="text-[9px] font-bold tracking-wider uppercase text-gray-500 mb-1.5">CURRENT PHASE</div>
              <div class={[
                "text-xs font-bold",
                phase_text_class(@phase)
              ]}>
                {phase_description(@phase)}
              </div>
              <div :if={@phase == "orders"} class="mt-1.5 text-[10px] text-gray-500">
                Awaiting orders from {@total_players - @submitted_count} faction(s)
              </div>
            </div>

            <%!-- Messages Section --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-purple-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-purple-400/50">DIPLOMATIC COMMS</span>
              </div>
              <div class="space-y-1.5 max-h-48 overflow-y-auto">
                <%= for msg <- @recent_messages do %>
                  <% sender = get_val(msg, :from, get_val(msg, :sender, "unknown")) %>
                  <% content = get_val(msg, :content, get_val(msg, :message, "")) %>
                  <% msg_round = get_val(msg, :round, 0) %>
                  <% recipient = get_val(msg, :to, get_val(msg, :recipient, nil)) %>
                  <% sender_str = to_string(sender) %>
                  <% sender_color = faction_color(sender_str) %>
                  <div class="dip-intel-item rounded-lg px-2.5 py-2" style={"background: #{sender_color}06; border: 1px solid #{sender_color}15;"}>
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-[10px] font-bold" style={"color: #{sender_color};"}>
                        {get_faction_name(sender_str, @players)}
                      </span>
                      <div class="flex items-center gap-1.5">
                        <span :if={recipient} class="text-[8px] text-gray-600">
                          to {get_faction_name(to_string(recipient), @players)}
                        </span>
                        <span class="text-[8px] text-gray-600 tabular-nums">R{msg_round}</span>
                      </div>
                    </div>
                    <div class="text-[10px] text-gray-400 leading-relaxed">{content}</div>
                  </div>
                <% end %>
                <div :if={@recent_messages == []} class="text-[10px] text-gray-600 px-2 py-3 text-center">
                  No diplomatic communications yet
                </div>
              </div>
            </div>

            <%!-- Resolution Log Section --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-red-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/50">ORDERS RESOLUTION</span>
              </div>
              <div class="space-y-1 max-h-40 overflow-y-auto">
                <%= for event <- @resolution_log do %>
                  <% event_text = if is_binary(event), do: event, else: get_val(event, :text, get_val(event, :description, inspect(event))) %>
                  <% event_type = if is_map(event), do: get_val(event, :type, "info"), else: "info" %>
                  <div class={[
                    "dip-intel-item px-2.5 py-1.5 rounded text-[10px] border",
                    resolution_event_class(event_type)
                  ]}>
                    {event_text}
                  </div>
                <% end %>
                <div :if={@resolution_log == []} class="text-[10px] text-gray-600 px-2 py-3 text-center">
                  No resolution events yet
                </div>
              </div>
            </div>

            <%!-- Capture History Timeline --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">CAPTURE HISTORY</span>
              </div>
              <div class="space-y-1.5 max-h-44 overflow-y-auto">
                <%= for cap <- @recent_captures do %>
                  <% cap_territory = get_val(cap, :territory, "unknown") %>
                  <% cap_from = get_val(cap, :from, get_val(cap, :previous_owner, nil)) %>
                  <% cap_to = get_val(cap, :to, get_val(cap, :new_owner, "unknown")) %>
                  <% cap_round = get_val(cap, :round, 0) %>
                  <% attacker_str = to_string(cap_to) %>
                  <% attacker_color = faction_color(attacker_str) %>
                  <div class="dip-intel-item rounded-lg px-2.5 py-2" style={"background: #{attacker_color}06; border: 1px solid #{attacker_color}15;"}>
                    <div class="flex items-center gap-1 text-[10px]">
                      <span class="font-bold" style={"color: #{attacker_color};"}>
                        {get_faction_name(attacker_str, @players)}
                      </span>
                      <span class="text-gray-600">captured</span>
                      <span class="font-semibold text-white">{territory_display_name(cap_territory)}</span>
                    </div>
                    <div class="flex items-center justify-between mt-0.5">
                      <span :if={cap_from} class="text-[9px] text-gray-600">
                        from {get_faction_name(to_string(cap_from), @players)}
                      </span>
                      <span :if={cap_from == nil} class="text-[9px] text-gray-600">from neutral</span>
                      <span class="text-[8px] text-gray-600 tabular-nums">Round {cap_round}</span>
                    </div>
                  </div>
                <% end %>
                <div :if={@recent_captures == []} class="text-[10px] text-gray-600 px-2 py-3 text-center">
                  No territorial changes yet
                </div>
              </div>
            </div>

            <%!-- Backstory Connections --%>
            <div :if={@connections != []}>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-rose-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-rose-400/50">ALLIANCES & RIVALRIES</span>
              </div>
              <div class="space-y-1.5 max-h-40 overflow-y-auto">
                <%= for conn <- @connections do %>
                  <% conn_type = get_val(conn, :type, "unknown") %>
                  <% conn_desc = get_val(conn, :description, "") %>
                  <% pair = get_val(conn, :pair, {nil, nil}) %>
                  <% {id_a, id_b} = if is_tuple(pair), do: pair, else: {nil, nil} %>
                  <% is_hostile = conn_type in ["blood_feud", "rivalry", "enemy", "vendetta"] %>
                  <div class={[
                    "dip-intel-item rounded-lg px-2.5 py-2 border",
                    if(is_hostile,
                      do: "bg-red-950/15 border-red-800/20",
                      else: "bg-emerald-950/15 border-emerald-800/20")
                  ]}>
                    <div class="flex items-center gap-1.5 mb-0.5">
                      <span :if={id_a} class="text-[10px] font-bold" style={"color: #{faction_color(to_string(id_a))};"}>
                        {get_faction_name(to_string(id_a), @players)}
                      </span>
                      <span class={[
                        "text-[8px] font-bold px-1 py-0.5 rounded uppercase tracking-wider",
                        if(is_hostile, do: "text-red-400 bg-red-950/30", else: "text-emerald-400 bg-emerald-950/30")
                      ]}>
                        {conn_type |> to_string() |> String.replace("_", " ")}
                      </span>
                      <span :if={id_b} class="text-[10px] font-bold" style={"color: #{faction_color(to_string(id_b))};"}>
                        {get_faction_name(to_string(id_b), @players)}
                      </span>
                    </div>
                    <div :if={conn_desc != ""} class="text-[9px] text-gray-500 leading-relaxed">{conn_desc}</div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Leader Journals --%>
            <div :if={@journals != %{}}>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-indigo-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-indigo-400/50">LEADER JOURNALS</span>
              </div>
              <div class="space-y-2 max-h-52 overflow-y-auto">
                <%= for {leader, entries} <- @journals do %>
                  <% leader_str = to_string(leader) %>
                  <% recent_entries = entries |> Enum.reverse() |> Enum.take(3) |> Enum.reverse() %>
                  <div class="rounded-lg px-2.5 py-2" style={"background: rgba(99, 102, 241, 0.05); border: 1px solid rgba(99, 102, 241, 0.12);"}>
                    <div class="text-[10px] font-bold text-indigo-400 mb-1">{leader_str}</div>
                    <div class="space-y-1">
                      <%= for entry <- recent_entries do %>
                        <% entry_round = get_val(entry, :round, "?") %>
                        <% entry_phase = get_val(entry, :phase, "") %>
                        <% entry_thought = get_val(entry, :thought, "") %>
                        <div class="dip-intel-item">
                          <div class="flex items-center gap-1 mb-0.5">
                            <span class="text-[8px] tabular-nums text-gray-600">R{entry_round}</span>
                            <span :if={entry_phase != ""} class="text-[8px] text-gray-600 uppercase">{entry_phase}</span>
                          </div>
                          <div class="text-[9px] text-gray-400 leading-relaxed italic">{entry_thought}</div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Order History (past rounds) --%>
            <div :if={@order_history != []}>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-gray-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-gray-500">PAST ROUNDS</span>
              </div>
              <div class="space-y-1">
                <%= for {past_round, idx} <- Enum.with_index(@order_history) do %>
                  <details class="group">
                    <summary class="cursor-pointer px-2 py-1.5 rounded bg-gray-800/20 border border-gray-700/20 text-[10px] text-gray-400 hover:text-gray-300 transition-colors flex items-center gap-1">
                      <svg xmlns="http://www.w3.org/2000/svg" class="w-2.5 h-2.5 transform group-open:rotate-90 transition-transform" viewBox="0 0 20 20" fill="currentColor">
                        <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                      </svg>
                      Round {idx + 1} Resolution
                    </summary>
                    <div class="mt-1 pl-3 space-y-0.5">
                      <%= if is_list(past_round) do %>
                        <%= for entry <- past_round do %>
                          <% entry_text = if is_binary(entry), do: entry, else: get_val(entry, :text, inspect(entry)) %>
                          <div class="text-[9px] text-gray-500 py-0.5">{entry_text}</div>
                        <% end %>
                      <% else %>
                        <div class="text-[9px] text-gray-500 py-0.5">{inspect(past_round)}</div>
                      <% end %>
                    </div>
                  </details>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Bottom: Turn Order Bar --%>
          <div class="px-3 py-2 border-t border-cyan-900/15" style="background: rgba(15, 23, 42, 0.5);">
            <div class="text-[8px] font-bold tracking-wider uppercase text-gray-600 mb-1.5">TURN ORDER</div>
            <div class="flex items-center gap-1">
              <%= for pid <- @turn_order do %>
                <% pid_str = to_string(pid) %>
                <% color = faction_color(pid_str) %>
                <% is_current = @active_actor_id && to_string(@active_actor_id) == pid_str %>
                <% p_data = Map.get(@players, pid) || Map.get(@players, pid_str, %{}) %>
                <% p_status = get_val(p_data, :status, "alive") %>
                <div
                  class={[
                    "flex-1 h-2 rounded-full transition-all duration-300",
                    if(is_current, do: "dip-phase-active", else: ""),
                    if(p_status == "eliminated", do: "opacity-20", else: "")
                  ]}
                  style={"background: #{if is_current, do: color, else: color <> "40"}; #{if is_current, do: "box-shadow: 0 0 8px " <> color <> "60;", else: ""}"}
                  title={get_faction_name(pid_str, @players)}
                />
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ VICTORY OVERLAY ═══════════════ --%>
      <div
        :if={@game_status == "won" and @winner}
        class="absolute inset-0 z-50 flex items-center justify-center rounded-xl"
        style="background: radial-gradient(ellipse at center, rgba(0,0,0,0.85), rgba(0,0,0,0.95));"
      >
        <% winner_str = to_string(@winner) %>
        <% winner_color = faction_color(winner_str) %>
        <% winner_faction = get_faction_name(winner_str, @players) %>
        <% _winner_data = Map.get(@players, @winner) || Map.get(@players, winner_str, %{}) %>
        <% winner_territories = @sorted_players |> Enum.find(fn {pid, _, _, _} -> pid == winner_str end) %>
        <% winner_terr_count = if winner_territories, do: elem(winner_territories, 3), else: 0 %>
        <div class="dip-victory text-center space-y-5 px-8">
          <%!-- Victory crown glow --%>
          <div class="relative inline-block">
            <div class="absolute inset-0 rounded-full blur-3xl opacity-30" style={"background: #{winner_color};"}></div>
            <div
              class="relative w-24 h-24 rounded-full flex items-center justify-center text-4xl font-black border-4 mx-auto"
              style={"background: #{winner_color}20; border-color: #{winner_color}; color: #{winner_color}; box-shadow: 0 0 40px #{winner_color}40, 0 0 80px #{winner_color}20;"}
            >
              {String.first(winner_faction)}
            </div>
          </div>

          <%!-- Title --%>
          <div>
            <div class="text-[10px] font-bold tracking-[0.3em] uppercase text-gray-500 mb-2">TOTAL DOMINATION</div>
            <div class="text-3xl font-black tracking-tight" style={"color: #{winner_color}; text-shadow: 0 0 30px #{winner_color}50;"}>
              {winner_faction}
            </div>
            <div class="text-lg text-gray-400 mt-1">controls the continent</div>
          </div>

          <%!-- Stats --%>
          <div class="flex justify-center gap-8 mt-4">
            <div class="text-center">
              <div class="text-3xl font-bold text-white">{winner_terr_count}</div>
              <div class="text-[10px] uppercase tracking-wider text-gray-500 mt-1">Territories Held</div>
            </div>
            <div class="text-center">
              <div class="text-3xl font-bold text-white">{@round}</div>
              <div class="text-[10px] uppercase tracking-wider text-gray-500 mt-1">Rounds Played</div>
            </div>
            <div class="text-center">
              <div class="text-3xl font-bold text-white">{length(@capture_history)}</div>
              <div class="text-[10px] uppercase tracking-wider text-gray-500 mt-1">Total Captures</div>
            </div>
          </div>

          <%!-- Faction listing --%>
          <div class="mt-4 pt-4 border-t border-gray-700/30">
            <div class="text-[10px] uppercase tracking-wider text-gray-500 mb-3">Final Standings</div>
            <div class="flex flex-wrap justify-center gap-2">
              <%= for {pid, pdata, _owned, terr_count} <- @sorted_players do %>
                <% f_color = faction_color(pid) %>
                <% f_name = get_val(pdata, :faction, pid) %>
                <% f_status = get_val(pdata, :status, "alive") %>
                <div
                  class={[
                    "px-3 py-1.5 rounded-lg border text-xs font-bold",
                    if(f_status == "eliminated", do: "opacity-40", else: "")
                  ]}
                  style={"background: #{f_color}10; border-color: #{f_color}30; color: #{f_color};"}
                >
                  <span>{f_name}</span>
                  <span class="ml-1.5 text-gray-400">{terr_count}</span>
                </div>
              <% end %>
            </div>
          </div>

          <div
            class="w-64 h-1 rounded-full mx-auto mt-4"
            style={"background: linear-gradient(90deg, transparent, #{winner_color}, transparent);"}
          ></div>
        </div>
      </div>
    </div>
    """
  end

  # ── Flexible Key Access ──────────────────────────────────────────

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp get_val(_, _, default), do: default

  # ── Territory Helpers ──────────────────────────────────────────

  defp get_territory(territories, name) when is_map(territories) do
    Map.get(territories, name) ||
      Map.get(territories, String.to_atom(name)) ||
      Map.get(territories, to_string(name), %{})
  end

  defp get_territory(_, _), do: %{}

  defp territory_display_name(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp territory_short_name(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(fn word -> String.upcase(String.slice(word, 0, 3)) end)
    |> Enum.join("")
  end

  defp territory_bg(color) do
    "#{color}0a"
  end

  defp is_recently_captured(tname, capture_history, current_round) do
    capture_history
    |> Enum.any?(fn cap ->
      cap_terr = get_val(cap, :territory, nil)
      cap_round = get_val(cap, :round, 0)
      to_string(cap_terr) == to_string(tname) and cap_round == current_round
    end)
  end

  # ── Faction Helpers ────────────────────────────────────────────

  defp faction_color(player_id) do
    pid = to_string(player_id)

    cond do
      String.contains?(pid, "1") -> "#06b6d4"
      String.contains?(pid, "2") -> "#ef4444"
      String.contains?(pid, "3") -> "#10b981"
      String.contains?(pid, "4") -> "#f59e0b"
      String.contains?(pid, "5") -> "#a855f7"
      String.contains?(pid, "6") -> "#ec4899"
      true ->
        hue = :erlang.phash2(pid, 360)
        "hsl(#{hue}, 70%, 55%)"
    end
  end

  defp get_faction_name(player_id, players) when is_map(players) do
    pid_str = to_string(player_id)

    pdata =
      Map.get(players, player_id) ||
        Map.get(players, pid_str) ||
        try_atom_key(players, pid_str) ||
        %{}

    get_val(pdata, :faction, pid_str)
  end

  defp get_faction_name(player_id, _), do: to_string(player_id)

  defp try_atom_key(map, key_str) when is_map(map) and is_binary(key_str) do
    try do
      Map.get(map, String.to_existing_atom(key_str))
    rescue
      ArgumentError -> nil
    end
  end

  defp try_atom_key(_, _), do: nil

  # ── Phase Helpers ──────────────────────────────────────────────

  defp phase_badge_class("diplomacy") do
    "border-purple-500/30 bg-purple-950/20 text-purple-400"
  end

  defp phase_badge_class("orders") do
    "border-cyan-500/30 bg-cyan-950/20 text-cyan-400"
  end

  defp phase_badge_class("resolution") do
    "border-red-500/30 bg-red-950/20 text-red-400"
  end

  defp phase_badge_class(_) do
    "border-gray-500/30 bg-gray-800/20 text-gray-400"
  end

  defp phase_label("diplomacy"), do: "DIPLOMACY"
  defp phase_label("orders"), do: "ORDERS"
  defp phase_label("resolution"), do: "RESOLUTION"

  defp phase_label(other) when is_binary(other),
    do: other |> String.upcase()

  defp phase_label(_), do: "UNKNOWN"

  defp phase_text_class("diplomacy"), do: "text-purple-400 dip-neon-purple"
  defp phase_text_class("orders"), do: "text-cyan-400 dip-neon-cyan"
  defp phase_text_class("resolution"), do: "text-red-400 dip-neon-red"
  defp phase_text_class(_), do: "text-gray-400"

  defp phase_description("diplomacy"), do: "Send messages to other players. Forge alliances, broker deals, or deceive your rivals."
  defp phase_description("orders"), do: "Issue move, hold, or support orders to your armies across the continent."
  defp phase_description("resolution"), do: "All orders resolving simultaneously. Conflicts determined by support strength."
  defp phase_description(_), do: "Awaiting next phase..."

  # ── Resolution Event Styling ───────────────────────────────────

  defp resolution_event_class("attack"), do: "bg-red-950/20 border-red-800/20 text-red-400"
  defp resolution_event_class("capture"), do: "bg-amber-950/20 border-amber-800/20 text-amber-400"
  defp resolution_event_class("support"), do: "bg-cyan-950/20 border-cyan-800/20 text-cyan-400"
  defp resolution_event_class("hold"), do: "bg-gray-800/20 border-gray-700/20 text-gray-400"
  defp resolution_event_class("bounce"), do: "bg-purple-950/20 border-purple-800/20 text-purple-400"
  defp resolution_event_class("retreat"), do: "bg-orange-950/20 border-orange-800/20 text-orange-400"
  defp resolution_event_class(_), do: "bg-gray-800/20 border-gray-700/20 text-gray-400"
end
