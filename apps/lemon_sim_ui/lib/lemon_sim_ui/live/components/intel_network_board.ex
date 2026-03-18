defmodule LemonSimUi.Live.Components.IntelNetworkBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    adjacency = MapHelpers.get_key(world, :adjacency) || %{}
    phase = MapHelpers.get_key(world, :phase) || "intel_briefing"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 8
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    message_log = MapHelpers.get_key(world, :message_log) || %{}
    operations_log = MapHelpers.get_key(world, :operations_log) || []
    suspicion_board = MapHelpers.get_key(world, :suspicion_board) || %{}
    leaked_intel = MapHelpers.get_key(world, :leaked_intel) || []
    intel_pool = MapHelpers.get_key(world, :intel_pool) || []
    analysis_notes = MapHelpers.get_key(world, :analysis_notes) || %{}
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    journals = MapHelpers.get_key(world, :journals) || %{}

    # Find the mole (only shown in game_over or for the mole player itself)
    mole_id =
      players
      |> Enum.find_value(fn {id, p} ->
        if get_val(p, :role, "operative") == "mole", do: id, else: nil
      end)

    # Build sorted agent list with intel counts
    sorted_agents =
      players
      |> Enum.map(fn {pid, pdata} ->
        pid_str = to_string(pid)
        intel = get_val(pdata, :intel_fragments, [])
        intel_count = if is_list(intel), do: length(intel), else: 0
        suspicion_count = length(Map.get(suspicion_board, pid, []))
        role = get_val(pdata, :role, "operative")
        {pid_str, pdata, intel_count, suspicion_count, role}
      end)
      |> Enum.sort_by(fn {_, _, intel_count, _, _} -> intel_count end, :desc)

    # Recent messages across all edges
    recent_messages =
      message_log
      |> Map.values()
      |> List.flatten()
      |> Enum.sort_by(fn m -> get_val(m, :round, get_val(m, "round", 0)) end)
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Recent operations
    recent_operations = Enum.take(operations_log, -8)

    leaked_count = length(leaked_intel)
    intel_pool_size = length(intel_pool)

    active_player_data =
      if active_actor_id do
        pid_str = to_string(active_actor_id)
        Map.get(players, active_actor_id) || Map.get(players, pid_str, %{})
      else
        %{}
      end

    active_codename = get_val(active_player_data, :codename, "Unknown")

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:adjacency, adjacency)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_codename, active_codename)
      |> assign(:turn_order, turn_order)
      |> assign(:message_log, message_log)
      |> assign(:operations_log, operations_log)
      |> assign(:suspicion_board, suspicion_board)
      |> assign(:leaked_intel, leaked_intel)
      |> assign(:intel_pool, intel_pool)
      |> assign(:leaked_count, leaked_count)
      |> assign(:intel_pool_size, intel_pool_size)
      |> assign(:analysis_notes, analysis_notes)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:mole_id, mole_id)
      |> assign(:sorted_agents, sorted_agents)
      |> assign(:recent_messages, recent_messages)
      |> assign(:recent_operations, recent_operations)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative w-full font-sans" style="background: #080c10; color: #e0eaf4; min-height: 640px;">
      <style>
        /* ── Node Pulse ── */
        @keyframes net-node-pulse {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.2); }
        }
        .net-node-active { animation: net-node-pulse 2.5s ease-in-out infinite; }

        /* ── Mole Glow ── */
        @keyframes net-mole-glow {
          0%, 100% { box-shadow: 0 0 8px 2px rgba(255, 71, 87, 0.2); }
          50% { box-shadow: 0 0 24px 8px rgba(255, 71, 87, 0.5); }
        }
        .net-mole-active { animation: net-mole-glow 2s ease-in-out infinite; }

        /* ── Scanline ── */
        @keyframes net-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .net-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(0, 212, 255, 0.1), transparent);
          animation: net-scanline 4s linear infinite;
          pointer-events: none;
        }

        /* ── Leak Flash ── */
        @keyframes net-leak-flash {
          0% { box-shadow: 0 0 0 0 rgba(255, 71, 87, 0.7); }
          50% { box-shadow: 0 0 24px 8px rgba(255, 71, 87, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(255, 71, 87, 0); }
        }
        .net-leaked { animation: net-leak-flash 2s ease-out; }

        /* ── Phase Breathe ── */
        @keyframes net-phase-breathe {
          0%, 100% { opacity: 0.6; }
          50% { opacity: 1; }
        }
        .net-phase-active { animation: net-phase-breathe 2s ease-in-out infinite; }

        /* ── Victory Entrance ── */
        @keyframes net-victory-enter {
          from { opacity: 0; transform: scale(0.8) translateY(20px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .net-victory { animation: net-victory-enter 0.8s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Intel Fade In ── */
        @keyframes net-intel-in {
          from { opacity: 0; transform: translateY(6px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .net-intel-item { animation: net-intel-in 0.3s ease-out forwards; }

        /* ── Data Pulse ── */
        @keyframes net-data-pulse {
          0%, 100% { opacity: 0.7; }
          50% { opacity: 1; }
        }
        .net-data-active { animation: net-data-pulse 1.5s ease-in-out infinite; }

        /* ── Neon text shadows ── */
        .net-neon-cyan { text-shadow: 0 0 8px rgba(0, 212, 255, 0.5); }
        .net-neon-red { text-shadow: 0 0 8px rgba(255, 71, 87, 0.6); }
        .net-neon-green { text-shadow: 0 0 8px rgba(39, 174, 96, 0.5); }
      </style>

      <%!-- ═══════════════ STATUS BAR ═══════════════ --%>
      <div class="relative overflow-hidden net-scanline" style="background: linear-gradient(90deg, rgba(0, 212, 255, 0.06), rgba(8, 12, 16, 0.95), rgba(255, 71, 87, 0.06)); border-bottom: 1px solid rgba(0, 212, 255, 0.12);">
        <div class="relative px-4 py-2.5 flex items-center justify-between">
          <%!-- Left: Game Identity --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-cyan-400 net-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.25em] uppercase text-cyan-400/70">INTEL NETWORK</span>
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
          </div>

          <%!-- Right: Leaked Intel Counter + Active Agent --%>
          <div class="flex items-center gap-3">
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full net-phase-active" style={"background: #{agent_color(to_string(@active_actor_id))};"}></div>
              <span class="text-[10px] font-bold" style={"color: #{agent_color(to_string(@active_actor_id))};"}>
                {@active_codename}
              </span>
            </div>
            <div class="h-4 w-px bg-cyan-900/30"></div>
            <%!-- Leak counter --%>
            <div class={["flex items-center gap-1", if(@leaked_count > 0, do: "net-neon-red", else: "")]}>
              <span class="text-[10px] text-gray-500">LEAKED</span>
              <span class={["text-sm font-black tabular-nums", if(@leaked_count >= 3, do: "text-red-400", else: "text-gray-300")]}>
                {@leaked_count}
              </span>
              <span class="text-[10px] text-gray-600">/5</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
      <div class="flex" style="min-height: 580px;">

        <%!-- ──── LEFT: NETWORK MAP + AGENT ROSTER ──── --%>
        <div class="flex-1 p-4 overflow-y-auto">

          <%!-- Network Map Header --%>
          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full bg-cyan-500/70"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/50">CELL NETWORK TOPOLOGY</span>
            <div class="flex-1 h-px bg-gradient-to-r from-cyan-900/30 to-transparent"></div>
          </div>

          <%!-- Network Graph Visualization --%>
          <div class="relative rounded-xl overflow-hidden mb-4" style="background: linear-gradient(135deg, rgba(8, 12, 16, 0.9), rgba(10, 15, 26, 0.95)); border: 1px solid rgba(0, 212, 255, 0.1); min-height: 200px;">
            <div class="absolute inset-0 opacity-[0.02]" style="background-image: linear-gradient(rgba(0, 212, 255, 0.5) 1px, transparent 1px), linear-gradient(90deg, rgba(0, 212, 255, 0.5) 1px, transparent 1px); background-size: 30px 30px;"></div>

            <div class="relative p-4">
              <%!-- Agent nodes in a ring layout --%>
              <div class="flex flex-wrap gap-3 justify-center">
                <%= for {pid, pdata, intel_count, suspicion_count, role} <- @sorted_agents do %>
                  <% codename = get_val(pdata, :codename, pid) %>
                  <% is_active = @active_actor_id && to_string(@active_actor_id) == pid %>
                  <% is_mole_reveal = @game_status == "won" && role == "mole" %>
                  <% color = if is_mole_reveal, do: "#ff4757", else: agent_color(pid) %>
                  <% neighbors = Map.get(@adjacency, pid, []) %>
                  <div
                    class={[
                      "rounded-lg px-3 py-2 text-center transition-all duration-300",
                      if(is_active, do: "net-node-active", else: ""),
                      if(is_mole_reveal, do: "net-mole-active", else: "")
                    ]}
                    style={"background: #{color}0f; border: 1px solid #{color}30; min-width: 90px;"}
                  >
                    <div class="text-[11px] font-bold tracking-wider" style={"color: #{color};"}>
                      {codename}
                    </div>
                    <div class="text-[8px] text-gray-500 mt-0.5">{pid}</div>
                    <div class="flex items-center justify-center gap-2 mt-1.5">
                      <span class="text-[9px] font-bold" style={"color: #{color};"}>
                        {intel_count} intel
                      </span>
                      <%= if suspicion_count > 0 do %>
                        <span class="text-[9px] font-bold text-red-400">
                          {suspicion_count} ⚠
                        </span>
                      <% end %>
                    </div>
                    <%= if is_mole_reveal do %>
                      <div class="text-[8px] font-bold mt-1 text-red-400 net-neon-red">THE MOLE</div>
                    <% end %>
                    <%!-- Adjacent nodes --%>
                    <div :if={length(neighbors) > 0} class="mt-1">
                      <div class="text-[7px] text-gray-600">{length(neighbors)} links</div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- ──── AGENT ROSTER ──── --%>
          <div>
            <div class="flex items-center gap-2 mb-2.5">
              <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">FIELD OPERATIVES</span>
              <div class="flex-1 h-px bg-gradient-to-r from-amber-900/20 to-transparent"></div>
            </div>

            <div class="space-y-1.5">
              <%= for {pid, pdata, intel_count, suspicion_count, role} <- @sorted_agents do %>
                <% codename = get_val(pdata, :codename, pid) %>
                <% color = agent_color(pid) %>
                <% is_active = @active_actor_id && to_string(@active_actor_id) == pid %>
                <% is_mole_reveal = @game_status == "won" && role == "mole" %>
                <% display_color = if is_mole_reveal, do: "#ff4757", else: color %>
                <% bar_pct = if @intel_pool_size > 0, do: min(100, intel_count / @intel_pool_size * 100), else: 0 %>
                <div
                  class={["rounded-lg px-3 py-2 transition-all duration-200", if(is_active, do: "ring-1", else: "")]}
                  style={"background: #{display_color}08; border: 1px solid #{display_color}20; #{if is_active, do: "ring-color: #{display_color}40;", else: ""}"}
                >
                  <div class="flex items-center gap-2 mb-1">
                    <div class="w-2.5 h-2.5 rounded-sm" style={"background: #{display_color}; box-shadow: 0 0 6px #{display_color}60;"}></div>
                    <span class="text-xs font-bold font-mono truncate" style={"color: #{display_color};"}>
                      {codename}
                    </span>
                    <span class="text-[9px] text-gray-500">{pid}</span>
                    <%= if is_mole_reveal do %>
                      <span class="text-[8px] font-bold px-1.5 py-0.5 rounded net-neon-red" style="background: rgba(255,71,87,0.15); color: #ff4757; border: 1px solid rgba(255,71,87,0.3);">
                        MOLE
                      </span>
                    <% end %>
                    <span class="flex-1"></span>
                    <span class="text-sm font-black tabular-nums text-white">{intel_count}</span>
                    <span class="text-[9px] text-gray-500">intel</span>
                    <%= if suspicion_count > 0 do %>
                      <span class="text-[9px] font-bold px-1.5 py-0.5 rounded" style="background: rgba(255,71,87,0.15); color: #ff4757;">
                        {suspicion_count} ⚠
                      </span>
                    <% end %>
                  </div>

                  <%!-- Intel progress bar --%>
                  <div class="relative h-1.5 rounded-full overflow-hidden" style="background: rgba(30, 41, 59, 0.5);">
                    <div
                      class="absolute inset-y-0 left-0 rounded-full transition-all duration-700"
                      style={"width: #{bar_pct}%; background: linear-gradient(90deg, #{display_color}60, #{display_color});"}
                    />
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- ──── RIGHT: INTEL PANEL ──── --%>
        <div class="w-72 flex-shrink-0 border-l border-cyan-900/15 bg-gray-900/20 flex flex-col overflow-hidden">

          <%!-- Intel Panel Header --%>
          <div class="px-3 py-2 border-b border-cyan-900/15" style="background: linear-gradient(180deg, rgba(0, 212, 255, 0.04), transparent);">
            <div class="flex items-center gap-2">
              <div class="w-1.5 h-1.5 rounded-full bg-cyan-500/70 net-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/50">SITUATION REPORT</span>
            </div>
          </div>

          <div class="flex-1 overflow-y-auto p-3 space-y-4">

            <%!-- Phase Status --%>
            <div class="rounded-lg p-2.5" style="background: rgba(15, 23, 42, 0.5); border: 1px solid rgba(0, 212, 255, 0.1);">
              <div class="text-[9px] font-bold tracking-wider uppercase text-gray-500 mb-1.5">CURRENT PHASE</div>
              <div class={["text-xs font-bold", phase_text_class(@phase)]}>
                {phase_description(@phase)}
              </div>
            </div>

            <%!-- Leak Status --%>
            <div class="rounded-lg p-2.5" style={"background: #{if @leaked_count >= 3, do: "rgba(255, 71, 87, 0.08)", else: "rgba(15, 23, 42, 0.5)"}; border: 1px solid #{if @leaked_count >= 3, do: "rgba(255,71,87,0.2)", else: "rgba(0,212,255,0.1)"};"}>
              <div class="text-[9px] font-bold tracking-wider uppercase text-gray-500 mb-2">INTEL COMPROMISE STATUS</div>
              <div class="flex items-center justify-between mb-1.5">
                <span class="text-[10px] text-gray-400">Fragments leaked</span>
                <span class={["text-sm font-black tabular-nums", if(@leaked_count >= 3, do: "text-red-400", else: "text-gray-200")]}>
                  {@leaked_count} / 5
                </span>
              </div>
              <div class="relative h-2 rounded-full overflow-hidden" style="background: rgba(30, 41, 59, 0.6);">
                <div
                  class="absolute inset-y-0 left-0 rounded-full transition-all duration-700"
                  style={"width: #{min(100, @leaked_count / 5 * 100)}%; background: linear-gradient(90deg, #f39c1260, #ff4757);"}
                />
                <%!-- threshold markers --%>
                <%= for i <- 1..4 do %>
                  <div
                    class="absolute top-0 bottom-0 w-px"
                    style={"left: #{i * 20}%; background: rgba(255,255,255,0.1);"}
                  />
                <% end %>
              </div>
              <%= if @leaked_count >= 5 do %>
                <div class="mt-1.5 text-[10px] font-bold text-red-400 net-neon-red">ADVERSARY HAS FULL PICTURE</div>
              <% end %>
            </div>

            <%!-- Suspicion Board --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-red-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/50">SUSPICION BOARD</span>
              </div>
              <div class="space-y-1.5">
                <%= if @suspicion_board == %{} do %>
                  <div class="text-[10px] text-gray-600 italic px-2">No suspicions reported yet</div>
                <% else %>
                  <%= for {suspect_id, reporters} <- Enum.sort_by(@suspicion_board, fn {_, v} -> length(v) end, :desc) do %>
                    <% suspect_str = to_string(suspect_id) %>
                    <% suspect_data = Map.get(@players, suspect_id, Map.get(@players, suspect_str, %{})) %>
                    <% codename = get_val(suspect_data, :codename, suspect_str) %>
                    <% report_count = length(reporters) %>
                    <% color = agent_color(suspect_str) %>
                    <div class="rounded-lg px-2.5 py-2" style="background: rgba(255,71,87,0.06); border: 1px solid rgba(255,71,87,0.15);">
                      <div class="flex items-center justify-between">
                        <div class="flex items-center gap-1.5">
                          <div class="w-2 h-2 rounded-full" style={"background: #{color};"}></div>
                          <span class="text-[10px] font-bold font-mono" style={"color: #{color};"}>
                            {codename}
                          </span>
                        </div>
                        <span class="text-[11px] font-black text-red-400">{report_count} report{if report_count != 1, do: "s", else: ""}</span>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>

            <%!-- Recent Messages --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-blue-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-blue-400/50">TRANSMISSIONS</span>
              </div>
              <div class="space-y-1.5 max-h-40 overflow-y-auto">
                <%= if @recent_messages == [] do %>
                  <div class="text-[10px] text-gray-600 italic px-2">No transmissions yet</div>
                <% else %>
                  <%= for msg <- @recent_messages do %>
                    <% from_id = to_string(get_val(msg, :from, get_val(msg, "from", "?"))) %>
                    <% to_id = to_string(get_val(msg, :to, get_val(msg, "to", "?"))) %>
                    <% msg_round = get_val(msg, :round, get_val(msg, "round", "?")) %>
                    <% from_color = agent_color(from_id) %>
                    <% to_color = agent_color(to_id) %>
                    <% from_data = Map.get(@players, from_id, %{}) %>
                    <% to_data = Map.get(@players, to_id, %{}) %>
                    <% from_codename = get_val(from_data, :codename, from_id) %>
                    <% to_codename = get_val(to_data, :codename, to_id) %>
                    <div class="net-intel-item rounded px-2 py-1.5" style="background: rgba(15, 23, 42, 0.4); border: 1px solid rgba(0,212,255,0.06);">
                      <div class="flex items-center gap-1.5">
                        <span class="text-[9px] font-bold font-mono" style={"color: #{from_color};"}>
                          {from_codename}
                        </span>
                        <span class="text-[8px] text-gray-600">&#x25BA;</span>
                        <span class="text-[9px] font-bold font-mono" style={"color: #{to_color};"}>
                          {to_codename}
                        </span>
                        <span class="flex-1"></span>
                        <span class="text-[8px] text-gray-600">R{msg_round}</span>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>

            <%!-- Recent Operations --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-0.5">
                <div class="w-1.5 h-1.5 rounded-full bg-green-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-green-400/50">OPERATIONS LOG</span>
              </div>
              <div class="space-y-1.5 max-h-40 overflow-y-auto">
                <%= if @recent_operations == [] do %>
                  <div class="text-[10px] text-gray-600 italic px-2">No operations yet</div>
                <% else %>
                  <%= for op <- @recent_operations do %>
                    <% player_id = to_string(get_val(op, :player_id, get_val(op, "player_id", "?"))) %>
                    <% op_type = get_val(op, :operation_type, get_val(op, "operation_type", "?")) %>
                    <% target = get_val(op, :target_id, get_val(op, "target_id", nil)) %>
                    <% op_round = get_val(op, :round, get_val(op, "round", "?")) %>
                    <% color = agent_color(player_id) %>
                    <% player_data = Map.get(@players, player_id, %{}) %>
                    <% codename = get_val(player_data, :codename, player_id) %>
                    <div class="net-intel-item rounded px-2 py-1.5" style={"background: #{operation_bg(op_type)}; border: 1px solid #{operation_border(op_type)};"}>
                      <div class="flex items-center gap-1.5">
                        <div class="w-1.5 h-1.5 rounded-full" style={"background: #{color};"}></div>
                        <span class="text-[9px] font-bold font-mono" style={"color: #{color};"}>
                          {codename}
                        </span>
                        <span class="text-[8px] font-bold uppercase tracking-wide" style={"color: #{operation_color(op_type)};"}>
                          {operation_label(op_type)}
                        </span>
                        <span :if={target} class="text-[8px] text-gray-500">&#x25BA; {target}</span>
                        <span class="flex-1"></span>
                        <span class="text-[8px] text-gray-600">R{op_round}</span>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>

          </div>
        </div>
      </div>

      <%!-- ═══════════════ GAME OVER OVERLAY ═══════════════ --%>
      <%= if @game_status == "won" do %>
        <% loyalists_won = @winner == "loyalists" %>
        <% mole_data = if @mole_id, do: Map.get(@players, @mole_id, %{}), else: %{} %>
        <% mole_codename = get_val(mole_data, :codename, to_string(@mole_id)) %>
        <div class="absolute inset-0 flex items-center justify-center" style="background: rgba(8, 12, 16, 0.88); z-index: 50;">
          <div class="net-victory rounded-2xl p-8 text-center max-w-lg mx-4" style={"background: rgba(15, 23, 42, 0.95); border: 2px solid #{if loyalists_won, do: "#00d4ff", else: "#ff4757"}; box-shadow: 0 0 40px #{if loyalists_won, do: "rgba(0,212,255,0.2)", else: "rgba(255,71,87,0.2)"};"}>
            <div class="text-3xl font-black mb-2" style={"color: #{if loyalists_won, do: "#00d4ff", else: "#ff4757"};"}>
              {if loyalists_won, do: "NETWORK SECURE", else: "NETWORK COMPROMISED"}
            </div>
            <div class="text-sm text-gray-400 mb-4">
              {if loyalists_won, do: "Loyal operatives correctly identified the mole.", else: "The mole evaded detection."}
            </div>
            <div class="rounded-lg p-3 mb-4" style={"background: #{if loyalists_won, do: "rgba(0,212,255,0.06)", else: "rgba(255,71,87,0.06)"}; border: 1px solid #{if loyalists_won, do: "rgba(0,212,255,0.2)", else: "rgba(255,71,87,0.2)"};"}>
              <div class="text-[10px] text-gray-500 uppercase tracking-wider mb-1">The Mole Was</div>
              <div class="text-lg font-black font-mono text-red-400">{mole_codename}</div>
              <div class="text-[10px] text-gray-500">{@mole_id}</div>
            </div>
            <div class="text-sm text-gray-400">
              Intel leaked: <span class="font-bold text-white">{@leaked_count}/5</span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp agent_color("agent_1"), do: "#00d4ff"
  defp agent_color("agent_2"), do: "#27ae60"
  defp agent_color("agent_3"), do: "#f39c12"
  defp agent_color("agent_4"), do: "#e74c3c"
  defp agent_color("agent_5"), do: "#8e44ad"
  defp agent_color("agent_6"), do: "#16a085"
  defp agent_color("agent_7"), do: "#2980b9"
  defp agent_color("agent_8"), do: "#c0392b"
  defp agent_color(_), do: "#7a9ab5"

  defp phase_label("intel_briefing"), do: "BRIEFING"
  defp phase_label("communication"), do: "COMMS"
  defp phase_label("analysis"), do: "ANALYSIS"
  defp phase_label("operation"), do: "OPERATION"
  defp phase_label("mole_action"), do: "CLANDESTINE"
  defp phase_label(other), do: String.upcase(to_string(other))

  defp phase_badge_class("intel_briefing"),
    do: "border-blue-700/50 bg-blue-900/20 text-blue-400"

  defp phase_badge_class("communication"),
    do: "border-cyan-700/50 bg-cyan-900/20 text-cyan-400"

  defp phase_badge_class("analysis"),
    do: "border-amber-700/50 bg-amber-900/20 text-amber-400"

  defp phase_badge_class("operation"),
    do: "border-green-700/50 bg-green-900/20 text-green-400"

  defp phase_badge_class("mole_action"),
    do: "border-red-700/50 bg-red-900/20 text-red-400"

  defp phase_badge_class(_), do: "border-gray-700/50 bg-gray-900/20 text-gray-400"

  defp phase_text_class("intel_briefing"), do: "text-blue-400"
  defp phase_text_class("communication"), do: "text-cyan-400"
  defp phase_text_class("analysis"), do: "text-amber-400"
  defp phase_text_class("operation"), do: "text-green-400"
  defp phase_text_class("mole_action"), do: "text-red-400"
  defp phase_text_class(_), do: "text-gray-400"

  defp phase_description("intel_briefing"), do: "Agents receiving classified intel assignments"
  defp phase_description("communication"), do: "Secure transmissions between adjacent nodes"
  defp phase_description("analysis"), do: "Private analysis and trust assessment"
  defp phase_description("operation"), do: "Field operations in progress"
  defp phase_description("mole_action"), do: "Clandestine activity (hidden from loyalists)"
  defp phase_description(other), do: to_string(other)

  defp operation_label("share_intel"), do: "SHARE"
  defp operation_label("relay_message"), do: "RELAY"
  defp operation_label("verify_agent"), do: "VERIFY"
  defp operation_label("report_suspicion"), do: "FLAG"
  defp operation_label(other), do: String.upcase(to_string(other))

  defp operation_color("share_intel"), do: "#27ae60"
  defp operation_color("relay_message"), do: "#2980b9"
  defp operation_color("verify_agent"), do: "#f39c12"
  defp operation_color("report_suspicion"), do: "#ff4757"
  defp operation_color(_), do: "#7a9ab5"

  defp operation_bg("report_suspicion"), do: "rgba(255,71,87,0.06)"
  defp operation_bg("share_intel"), do: "rgba(39,174,96,0.06)"
  defp operation_bg("verify_agent"), do: "rgba(243,156,18,0.06)"
  defp operation_bg(_), do: "rgba(15, 23, 42, 0.4)"

  defp operation_border("report_suspicion"), do: "rgba(255,71,87,0.15)"
  defp operation_border("share_intel"), do: "rgba(39,174,96,0.15)"
  defp operation_border("verify_agent"), do: "rgba(243,156,18,0.15)"
  defp operation_border(_), do: "rgba(0,212,255,0.06)"

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_map, _key, default), do: default
end
