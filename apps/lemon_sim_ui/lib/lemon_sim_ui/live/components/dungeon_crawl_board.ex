defmodule LemonSimUi.Live.Components.DungeonCrawlBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    rooms = MapHelpers.get_key(world, :rooms) || []
    current_room = MapHelpers.get_key(world, :current_room) || 0
    party = MapHelpers.get_key(world, :party) || %{}
    enemies = MapHelpers.get_key(world, :enemies) || %{}
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || ["warrior", "rogue", "mage", "cleric"]
    round = MapHelpers.get_key(world, :round) || 1
    inventory = MapHelpers.get_key(world, :inventory) || []
    buffs = MapHelpers.get_key(world, :buffs) || %{}
    taunt_active = MapHelpers.get_key(world, :taunt_active)
    attacks_this_turn = MapHelpers.get_key(world, :attacks_this_turn) || []
    combat_log = MapHelpers.get_key(world, :combat_log) || []
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    traits = MapHelpers.get_key(world, :traits) || %{}
    connections = MapHelpers.get_key(world, :connections) || []
    journals = MapHelpers.get_key(world, :journals) || %{}

    current_room_data =
      if is_list(rooms) and length(rooms) > current_room do
        Enum.at(rooms, current_room)
      else
        %{}
      end

    room_enemies = get_val(current_room_data, :enemies, [])
    room_traps = get_val(current_room_data, :traps, [])
    room_treasure = get_val(current_room_data, :treasure, [])
    room_cleared = get_val(current_room_data, :cleared, false)
    room_name = get_val(current_room_data, :name, "Unknown Chamber")

    # Order party members by turn order
    ordered_party =
      turn_order
      |> Enum.map(fn id ->
        member = Map.get(party, id, Map.get(party, String.to_atom(id), nil))
        {id, member}
      end)
      |> Enum.filter(fn {_id, m} -> not is_nil(m) end)

    # Alive party count
    alive_count =
      ordered_party
      |> Enum.count(fn {_id, m} -> get_val(m, :status, "alive") != "dead" end)

    # Active traps (not disarmed)
    active_traps = Enum.filter(room_traps, fn t -> not get_val(t, :disarmed, false) end)

    # Alive enemies
    alive_enemies =
      room_enemies
      |> Enum.filter(fn e -> get_val(e, :status, "alive") != "dead" end)

    # Recent combat log (last 20)
    recent_log = Enum.take(combat_log, -20)

    assigns =
      assigns
      |> assign(:rooms, rooms)
      |> assign(:current_room, current_room)
      |> assign(:party, party)
      |> assign(:enemies, enemies)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:turn_order, turn_order)
      |> assign(:round, round)
      |> assign(:inventory, inventory)
      |> assign(:buffs, buffs)
      |> assign(:taunt_active, taunt_active)
      |> assign(:attacks_this_turn, attacks_this_turn)
      |> assign(:combat_log, combat_log)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:current_room_data, current_room_data)
      |> assign(:room_enemies, room_enemies)
      |> assign(:room_traps, room_traps)
      |> assign(:room_treasure, room_treasure)
      |> assign(:room_cleared, room_cleared)
      |> assign(:room_name, room_name)
      |> assign(:ordered_party, ordered_party)
      |> assign(:alive_count, alive_count)
      |> assign(:active_traps, active_traps)
      |> assign(:alive_enemies, alive_enemies)
      |> assign(:recent_log, recent_log)
      |> assign(:traits, traits)
      |> assign(:connections, connections)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative font-sans">
      <%!-- Dungeon-themed animations and effects --%>
      <style>
        @keyframes torch-flicker {
          0%, 100% { opacity: 0.7; filter: brightness(1); }
          25% { opacity: 0.85; filter: brightness(1.1); }
          50% { opacity: 0.6; filter: brightness(0.95); }
          75% { opacity: 0.9; filter: brightness(1.05); }
        }
        @keyframes pulse-active {
          0%, 100% { box-shadow: 0 0 12px rgba(251, 191, 36, 0.3), inset 0 0 6px rgba(251, 191, 36, 0.1); }
          50% { box-shadow: 0 0 24px rgba(251, 191, 36, 0.6), inset 0 0 12px rgba(251, 191, 36, 0.2); }
        }
        @keyframes pulse-room {
          0%, 100% { box-shadow: 0 0 8px rgba(251, 191, 36, 0.4); }
          50% { box-shadow: 0 0 20px rgba(251, 191, 36, 0.8), 0 0 40px rgba(251, 191, 36, 0.3); }
        }
        @keyframes enemy-idle {
          0%, 100% { transform: translateY(0); }
          50% { transform: translateY(-2px); }
        }
        @keyframes skull-bob {
          0%, 100% { transform: scale(1); }
          50% { transform: scale(1.05); }
        }
        @keyframes cleared-fade {
          0% { opacity: 0; transform: scale(0.8); }
          100% { opacity: 1; transform: scale(1); }
        }
        @keyframes victory-glow {
          0%, 100% { text-shadow: 0 0 20px rgba(16, 185, 129, 0.5); transform: scale(1); }
          50% { text-shadow: 0 0 40px rgba(16, 185, 129, 0.8), 0 0 80px rgba(16, 185, 129, 0.3); transform: scale(1.02); }
        }
        @keyframes defeat-pulse {
          0%, 100% { text-shadow: 0 0 20px rgba(239, 68, 68, 0.5); }
          50% { text-shadow: 0 0 40px rgba(239, 68, 68, 0.8), 0 0 80px rgba(239, 68, 68, 0.3); }
        }
        @keyframes log-slide-in {
          from { transform: translateX(20px); opacity: 0; }
          to { transform: translateX(0); opacity: 1; }
        }
        @keyframes trap-warning {
          0%, 100% { border-color: rgba(168, 85, 247, 0.3); }
          50% { border-color: rgba(168, 85, 247, 0.7); box-shadow: 0 0 12px rgba(168, 85, 247, 0.3); }
        }
        .torch-glow { animation: torch-flicker 3s ease-in-out infinite; }
        .active-member { animation: pulse-active 2s cubic-bezier(0.4, 0, 0.6, 1) infinite; }
        .pulse-room-node { animation: pulse-room 2s ease-in-out infinite; }
        .enemy-float { animation: enemy-idle 3s ease-in-out infinite; }
        .skull-pulse { animation: skull-bob 2s ease-in-out infinite; }
        .cleared-anim { animation: cleared-fade 0.5s ease-out; }
        .victory-banner { animation: victory-glow 2s ease-in-out infinite; }
        .defeat-banner { animation: defeat-pulse 2s ease-in-out infinite; }
        .log-entry { animation: log-slide-in 0.3s ease-out; }
        .trap-pulse { animation: trap-warning 2s ease-in-out infinite; }
        .dungeon-bg {
          background: linear-gradient(135deg, rgba(15, 5, 30, 0.95) 0%, rgba(20, 10, 40, 0.9) 50%, rgba(10, 5, 25, 0.95) 100%);
        }
        .custom-scrollbar::-webkit-scrollbar { width: 4px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: rgba(30, 20, 50, 0.5); border-radius: 2px; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: rgba(120, 80, 180, 0.4); border-radius: 2px; }
        .custom-scrollbar::-webkit-scrollbar-thumb:hover { background: rgba(120, 80, 180, 0.6); }
      </style>

      <%!-- ═══════════════ DUNGEON PROGRESS BAR ═══════════════ --%>
      <div class="mb-4 px-4 py-4 rounded-xl glass-panel dungeon-bg relative overflow-hidden">
        <%!-- Ambient torch glow overlays --%>
        <div class="absolute top-0 left-8 w-24 h-24 bg-amber-500/10 rounded-full blur-3xl torch-glow pointer-events-none"></div>
        <div class="absolute top-0 right-8 w-24 h-24 bg-amber-500/10 rounded-full blur-3xl torch-glow pointer-events-none" style="animation-delay: 1.5s"></div>

        <div class="flex items-center justify-between mb-3 relative z-10">
          <div class="flex items-center gap-3">
            <span class="text-purple-400 font-mono text-[10px] tracking-[0.2em] uppercase font-black">Dungeon Descent</span>
            <span class="w-px h-4 bg-purple-500/30"></span>
            <span class="text-slate-400 font-mono text-[10px] tracking-widest uppercase font-bold">Room</span>
            <span class="text-amber-400 font-black text-sm tabular-nums">{@current_room + 1}/{length(@rooms)}</span>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-slate-500 font-mono text-[10px] tracking-widest uppercase font-bold">Round</span>
            <span class="text-amber-300 font-black text-sm tabular-nums">{@round}</span>
            <span class="w-px h-4 bg-purple-500/30"></span>
            <span class="text-slate-500 font-mono text-[10px] tracking-widest uppercase font-bold">Party</span>
            <span class="text-emerald-400 font-black text-sm">{@alive_count}/{length(@ordered_party)}</span>
          </div>
        </div>

        <%!-- Room progress nodes --%>
        <div class="flex items-center justify-center gap-0 relative z-10 px-4">
          <%= for {room, idx} <- Enum.with_index(@rooms) do %>
            <% room_cleared_flag = get_val(room, :cleared, false) %>
            <% is_current = idx == @current_room %>
            <% is_future = idx > @current_room %>
            <% is_boss = idx == length(@rooms) - 1 %>
            <% r_name = get_val(room, :name, "Room #{idx + 1}") %>

            <%!-- Connector line (not before first) --%>
            <div
              :if={idx > 0}
              class={[
                "h-0.5 flex-1 max-w-16 rounded-full transition-all duration-500",
                cond do
                  idx <= @current_room -> "bg-gradient-to-r from-emerald-500/60 to-emerald-500/60 shadow-[0_0_6px_rgba(16,185,129,0.4)]"
                  idx == @current_room + 1 -> "bg-gradient-to-r from-emerald-500/40 to-slate-700/40"
                  true -> "bg-slate-700/30"
                end
              ]}
            ></div>

            <%!-- Room node --%>
            <div class="flex flex-col items-center gap-1.5 flex-shrink-0">
              <div class={[
                "w-10 h-10 rounded-full flex items-center justify-center border-2 transition-all duration-500 relative",
                cond do
                  room_cleared_flag -> "bg-emerald-900/60 border-emerald-500/60 shadow-[0_0_12px_rgba(16,185,129,0.3)]"
                  is_current -> "bg-amber-900/40 border-amber-500/60 pulse-room-node"
                  true -> "bg-slate-900/60 border-slate-700/40 opacity-50"
                end,
                if(is_boss && !room_cleared_flag, do: "ring-1 ring-red-500/30", else: "")
              ]}>
                <%= cond do %>
                  <% room_cleared_flag -> %>
                    <span class="text-emerald-400 text-sm font-black cleared-anim">&#x2713;</span>
                  <% is_current -> %>
                    <span class="text-amber-300 text-sm font-black">{idx + 1}</span>
                    <%!-- Torch glow ring --%>
                    <div class="absolute inset-0 rounded-full border border-amber-400/20 torch-glow"></div>
                  <% is_boss && is_future -> %>
                    <span class="text-red-500/60 text-sm font-black skull-pulse">&#x2620;</span>
                  <% true -> %>
                    <span class="text-slate-600 text-xs font-bold">{idx + 1}</span>
                <% end %>
              </div>
              <span class={[
                "text-[9px] font-mono tracking-wide max-w-20 text-center truncate",
                cond do
                  room_cleared_flag -> "text-emerald-500/70"
                  is_current -> "text-amber-400/90 font-bold"
                  true -> "text-slate-600/60"
                end
              ]}>
                {truncate_name(r_name, 12)}
              </span>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- ═══════════════ MAIN 3-COLUMN LAYOUT ═══════════════ --%>
      <div class="flex gap-4 items-start">

        <%!-- ─── LEFT COLUMN: PARTY STATUS ─── --%>
        <div class="w-56 flex-shrink-0 space-y-2">
          <div class="flex items-center gap-2 px-3 py-2 rounded-xl bg-purple-950/40 border border-purple-500/20 shadow-[0_0_15px_rgba(168,85,247,0.1)]">
            <div class="w-2.5 h-2.5 rounded-full bg-purple-500 shadow-[0_0_8px_rgba(168,85,247,1)]"></div>
            <span class="text-purple-300 text-xs font-black tracking-widest uppercase">Adventuring Party</span>
          </div>

          <div class="space-y-2 p-1">
            <%= for {member_id, member} <- @ordered_party do %>
              <.party_card
                member_id={member_id}
                member={member}
                active={member_id == @active_actor_id}
                buffs={Map.get(@buffs, member_id, Map.get(@buffs, String.to_atom(to_string(member_id)), []))}
                taunt_active={@taunt_active == member_id}
                char_name={get_val(member, :name, nil)}
                member_traits={Map.get(@traits, member_id, Map.get(@traits, String.to_atom(to_string(member_id)), get_val(member, :traits, [])))}
              />
            <% end %>
          </div>
        </div>

        <%!-- ─── CENTER COLUMN: COMBAT ARENA ─── --%>
        <div class="flex-1 min-w-0">
          <%!-- Room header --%>
          <div class="glass-panel dungeon-bg rounded-xl border border-purple-500/20 p-4 mb-3 relative overflow-hidden">
            <div class="absolute inset-0 bg-gradient-to-r from-amber-500/5 via-transparent to-amber-500/5 pointer-events-none torch-glow"></div>
            <div class="flex items-center justify-between relative z-10">
              <div class="flex items-center gap-3">
                <div class="w-8 h-8 rounded-lg bg-amber-900/50 border border-amber-500/30 flex items-center justify-center shadow-[0_0_10px_rgba(251,191,36,0.2)]">
                  <span class="text-amber-400 text-sm font-black">{@current_room + 1}</span>
                </div>
                <div>
                  <div class="text-amber-200 font-black text-sm tracking-wide">{@room_name}</div>
                  <div class="text-slate-500 text-[10px] font-mono tracking-widest uppercase">
                    {length(@alive_enemies)} enemies remaining
                  </div>
                </div>
              </div>
              <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-2">
                <span class="text-slate-500 text-[10px] font-mono tracking-widest uppercase font-bold">Turn:</span>
                <span class={[
                  "px-3 py-1 rounded-md text-xs font-black tracking-wider border",
                  class_badge_style(@active_actor_id)
                ]}>
                  {class_display_name(@active_actor_id)}
                </span>
              </div>
            </div>

            <%!-- Active traps warning --%>
            <div :if={@active_traps != []} class="mt-3 flex flex-wrap gap-2">
              <%= for trap <- @active_traps do %>
                <div class="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-purple-950/60 border border-purple-500/30 trap-pulse">
                  <span class="text-purple-400 text-[10px] font-black">&#x26A0;</span>
                  <span class="text-purple-300 text-[10px] font-mono uppercase tracking-wider">
                    {get_val(trap, :type, "trap")} trap
                  </span>
                  <span class="text-purple-400/60 text-[10px]">
                    ({get_val(trap, :damage, 0)} dmg)
                  </span>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Enemy roster --%>
          <div class="glass-panel dungeon-bg rounded-xl border border-red-500/10 p-4 relative overflow-hidden min-h-[200px]">
            <div class="absolute top-0 left-0 w-32 h-32 bg-red-500/5 rounded-full blur-3xl pointer-events-none"></div>
            <div class="absolute bottom-0 right-0 w-32 h-32 bg-purple-500/5 rounded-full blur-3xl pointer-events-none"></div>

            <div class="text-[10px] text-red-400 uppercase tracking-[0.2em] font-black mb-3 flex items-center gap-2 relative z-10">
              <span class="w-1.5 h-1.5 rounded-full bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.8)]"></span>
              Enemies
              <span class="text-slate-600 ml-auto font-mono">{length(@alive_enemies)} alive</span>
            </div>

            <div class="space-y-2 relative z-10">
              <%= for enemy <- @room_enemies do %>
                <% e_id = get_val(enemy, :id, "???") %>
                <% e_type = get_val(enemy, :type, "unknown") %>
                <% e_hp = get_val(enemy, :hp, 0) %>
                <% e_max_hp = get_val(enemy, :max_hp, 1) %>
                <% e_attack = get_val(enemy, :attack, 0) %>
                <% e_status = get_val(enemy, :status, "alive") %>
                <% e_dead = e_status == "dead" %>
                <% e_hp_pct = if e_max_hp > 0, do: round(e_hp / e_max_hp * 100), else: 0 %>

                <div class={[
                  "px-3 py-2.5 rounded-lg border transition-all duration-300 relative overflow-hidden",
                  if(e_dead,
                    do: "bg-slate-900/40 border-slate-800/40 opacity-40 grayscale",
                    else: "glass-card border-red-500/20 hover:border-red-500/40"
                  )
                ]}>
                  <div :if={!e_dead} class="absolute inset-0 bg-gradient-to-r from-red-500/5 to-transparent pointer-events-none"></div>

                  <div class="flex items-center gap-3 relative z-10">
                    <%!-- Enemy icon --%>
                    <div class={[
                      "w-9 h-9 rounded-lg flex items-center justify-center border font-black text-sm",
                      if(e_dead,
                        do: "bg-slate-800 border-slate-700 text-slate-600",
                        else: "bg-red-950/60 border-red-500/30 text-red-400 shadow-[0_0_8px_rgba(239,68,68,0.2)] enemy-float"
                      )
                    ]}>
                      <span :if={!e_dead}>{enemy_icon(e_type)}</span>
                      <span :if={e_dead} class="text-slate-600">X</span>
                    </div>

                    <div class="flex-1 min-w-0">
                      <div class="flex items-center justify-between mb-1">
                        <span class={[
                          "text-xs font-bold tracking-wide",
                          if(e_dead, do: "text-slate-600 line-through", else: "text-slate-200")
                        ]}>
                          {String.capitalize(to_string(e_type))}
                        </span>
                        <div class="flex items-center gap-2">
                          <span :if={!e_dead} class="text-[10px] text-red-400/70 font-mono">
                            ATK {e_attack}
                          </span>
                          <span :if={e_dead} class="text-[9px] text-slate-600 font-mono uppercase tracking-widest">
                            Slain
                          </span>
                        </div>
                      </div>

                      <%!-- HP bar --%>
                      <div :if={!e_dead} class="w-full h-2 bg-slate-900/80 rounded-full overflow-hidden shadow-inner border border-slate-800/50">
                        <div
                          class={[
                            "h-full rounded-full transition-all duration-500",
                            cond do
                              e_hp_pct > 60 -> "bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.6)]"
                              e_hp_pct > 30 -> "bg-orange-500 shadow-[0_0_6px_rgba(249,115,22,0.6)]"
                              true -> "bg-yellow-500 shadow-[0_0_6px_rgba(234,179,8,0.6)]"
                            end
                          ]}
                          style={"width: #{e_hp_pct}%"}
                        ></div>
                      </div>
                      <div :if={!e_dead} class="flex items-center justify-between mt-0.5">
                        <span class="text-[10px] font-mono text-slate-400">
                          <span class="text-slate-200 font-semibold">{e_hp}</span>/{e_max_hp} HP
                        </span>
                        <span class="text-[9px] font-mono text-slate-600">{e_id}</span>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Room cleared overlay --%>
            <div
              :if={@room_cleared && @game_status == "in_progress"}
              class="absolute inset-0 z-20 flex items-center justify-center bg-slate-950/70 rounded-xl backdrop-blur-sm cleared-anim"
            >
              <div class="text-center p-6">
                <div class="text-emerald-400 text-2xl font-black tracking-widest uppercase mb-2" style="text-shadow: 0 0 20px rgba(16,185,129,0.5);">
                  &#x2713; Room Cleared
                </div>
                <div class="text-emerald-300/60 text-xs font-mono tracking-widest uppercase">
                  Advancing deeper...
                </div>
              </div>
            </div>

            <%!-- Empty state --%>
            <div :if={@room_enemies == []} class="flex items-center justify-center py-8">
              <span class="text-slate-600 text-xs font-mono tracking-widest uppercase">No enemies in this room</span>
            </div>

            <%!-- Disarmed traps --%>
            <div :if={Enum.any?(@room_traps, fn t -> get_val(t, :disarmed, false) end)} class="mt-3 pt-3 border-t border-slate-800/50">
              <div class="text-[10px] text-slate-500 uppercase tracking-widest font-bold mb-2">Disarmed Traps</div>
              <div class="flex flex-wrap gap-2">
                <%= for trap <- Enum.filter(@room_traps, fn t -> get_val(t, :disarmed, false) end) do %>
                  <div class="px-2 py-1 rounded bg-slate-800/40 border border-slate-700/30 text-[10px] text-slate-500 font-mono line-through">
                    {get_val(trap, :type, "trap")}
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Treasure display --%>
            <div :if={@room_treasure != []} class="mt-3 pt-3 border-t border-amber-500/10">
              <div class="text-[10px] text-amber-400/70 uppercase tracking-widest font-bold mb-2 flex items-center gap-1.5">
                <span>&#x2726;</span> Treasure Found
              </div>
              <div class="flex flex-wrap gap-2">
                <%= for item <- @room_treasure do %>
                  <div class="px-2.5 py-1 rounded-md bg-amber-950/30 border border-amber-500/20 text-[10px] text-amber-300 font-mono shadow-[0_0_8px_rgba(251,191,36,0.1)]">
                    {get_val(item, :name, "item")}
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- ─── RIGHT COLUMN: COMBAT LOG + INVENTORY ─── --%>
        <div class="w-56 flex-shrink-0 flex flex-col gap-3">
          <%!-- Combat Log --%>
          <div class="glass-panel dungeon-bg rounded-xl border border-purple-500/10 overflow-hidden">
            <div class="flex items-center gap-2 px-3 py-2.5 border-b border-purple-500/10">
              <span class="w-1.5 h-1.5 rounded-full bg-purple-500 shadow-[0_0_6px_rgba(168,85,247,0.8)]"></span>
              <span class="text-purple-300 text-[10px] font-black tracking-widest uppercase">Combat Log</span>
              <span class="text-slate-600 text-[10px] font-mono ml-auto">{length(@combat_log)}</span>
            </div>

            <div class="max-h-80 overflow-y-auto custom-scrollbar p-2 space-y-1">
              <%= if @recent_log == [] do %>
                <div class="text-slate-600 text-[10px] font-mono text-center py-4 tracking-widest">
                  Awaiting first action...
                </div>
              <% end %>
              <%= for {entry, idx} <- Enum.with_index(@recent_log) do %>
                <div class={[
                  "px-2 py-1.5 rounded text-[10px] leading-snug font-mono border-l-2 shadow-sm log-entry",
                  log_entry_style(entry)
                ]} style={"animation-delay: #{idx * 30}ms"}>
                  {entry}
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Inventory --%>
          <div class="glass-panel dungeon-bg rounded-xl border border-amber-500/10 overflow-hidden">
            <div class="flex items-center gap-2 px-3 py-2.5 border-b border-amber-500/10">
              <span class="text-amber-400 text-xs">&#x2726;</span>
              <span class="text-amber-300/80 text-[10px] font-black tracking-widest uppercase">Inventory</span>
              <span class="text-slate-600 text-[10px] font-mono ml-auto">{length(@inventory)}</span>
            </div>

            <div class="p-2 space-y-1">
              <%= if @inventory == [] do %>
                <div class="text-slate-600 text-[10px] font-mono text-center py-3 tracking-widest">
                  Empty
                </div>
              <% end %>
              <%= for item <- @inventory do %>
                <div class="flex items-center justify-between px-2 py-1.5 rounded bg-amber-950/20 border border-amber-500/10 group/item hover:border-amber-500/30 transition-all">
                  <div class="flex items-center gap-2">
                    <span class="text-amber-400/70 text-[10px]">&#x25C6;</span>
                    <span class="text-amber-200/80 text-[10px] font-mono">{get_val(item, :name, "item")}</span>
                  </div>
                  <span :if={get_val(item, :value, nil)} class="text-amber-500/50 text-[9px] font-mono">
                    {get_val(item, :value, 0)}g
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ JOURNALS & CONNECTIONS ═══════════════ --%>
      <div :if={@journals != %{} || @connections != []} class="flex gap-4 mt-4 items-start">
        <%!-- Party Journals --%>
        <div :if={@journals != %{}} class="flex-1 glass-panel dungeon-bg rounded-xl border border-purple-500/10 overflow-hidden">
          <div class="flex items-center gap-2 px-3 py-2.5 border-b border-purple-500/10">
            <span class="text-purple-400 text-xs">&#x270D;</span>
            <span class="text-purple-300 text-[10px] font-black tracking-widest uppercase">Party Journals</span>
          </div>
          <div class="max-h-60 overflow-y-auto custom-scrollbar p-2 space-y-2">
            <%= for {class_id, entries} <- @journals do %>
              <% member = Map.get(@party, class_id, Map.get(@party, String.to_atom(to_string(class_id)), %{})) %>
              <% char_name = get_val(member, :name, class_display_name(to_string(class_id))) %>
              <div class="space-y-1">
                <div class="text-[10px] font-black tracking-wider text-slate-300 px-1">
                  {char_name}
                  <span class="text-slate-600 font-normal ml-1">({class_display_name(to_string(class_id))})</span>
                </div>
                <%= for entry <- Enum.take(List.wrap(entries), -3) do %>
                  <div class="px-2 py-1.5 rounded bg-slate-800/40 border border-slate-700/20 text-[10px] font-mono leading-snug">
                    <span class="text-amber-400/70">R{get_val(entry, :round, "?")}</span>
                    <span :if={get_val(entry, :phase, nil)} class="text-purple-400/50 ml-1">{get_val(entry, :phase, "")}</span>
                    <span class="text-slate-500 mx-1">|</span>
                    <span class="text-slate-400">{get_val(entry, :thought, "...")}</span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Party Connections --%>
        <div :if={@connections != []} class="w-64 flex-shrink-0 glass-panel dungeon-bg rounded-xl border border-amber-500/10 overflow-hidden">
          <div class="flex items-center gap-2 px-3 py-2.5 border-b border-amber-500/10">
            <span class="text-amber-400 text-xs">&#x2694;</span>
            <span class="text-amber-300/80 text-[10px] font-black tracking-widest uppercase">Party Bonds</span>
          </div>
          <div class="max-h-60 overflow-y-auto custom-scrollbar p-2 space-y-1.5">
            <%= for conn <- @connections do %>
              <% players = get_val(conn, :players, []) %>
              <% conn_type = get_val(conn, :type, "bond") %>
              <% description = get_val(conn, :description, nil) %>
              <div class="px-2 py-2 rounded-lg bg-amber-950/20 border border-amber-500/10">
                <div class="flex items-center gap-1.5 mb-1">
                  <span class="text-[9px] font-black text-amber-300/80 uppercase tracking-wider">
                    {Enum.map(players, fn p ->
                      m = Map.get(@party, p, Map.get(@party, String.to_atom(to_string(p)), %{}))
                      get_val(m, :name, class_display_name(to_string(p)))
                    end) |> Enum.join(" & ")}
                  </span>
                </div>
                <div class="flex items-center gap-1.5">
                  <span class="text-[8px] font-bold px-1.5 py-0.5 rounded-full bg-purple-500/15 text-purple-400 border border-purple-500/25">
                    {String.replace(to_string(conn_type), "_", " ")}
                  </span>
                </div>
                <div :if={description} class="text-[9px] text-slate-400/80 font-mono mt-1 leading-snug">
                  {description}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ VICTORY OVERLAY ═══════════════ --%>
      <div
        :if={@game_status == "won"}
        class="absolute inset-0 z-50 flex items-center justify-center bg-slate-950/85 rounded-2xl backdrop-blur-xl border border-emerald-500/20 overflow-hidden"
      >
        <div class="absolute inset-0 bg-[radial-gradient(circle_at_center,rgba(16,185,129,0.08)_0%,transparent_70%)] pointer-events-none"></div>
        <div class="absolute top-0 left-1/4 w-40 h-40 bg-emerald-500/10 rounded-full blur-3xl torch-glow pointer-events-none"></div>
        <div class="absolute bottom-0 right-1/4 w-40 h-40 bg-amber-500/10 rounded-full blur-3xl torch-glow pointer-events-none" style="animation-delay: 1s"></div>

        <div class="text-center p-12 space-y-6 relative z-10">
          <div class="text-5xl font-black tracking-tighter uppercase text-emerald-400 victory-banner">
            Dungeon Conquered
          </div>
          <div class="text-slate-400 text-sm font-mono tracking-widest uppercase">
            The darkness has been vanquished
          </div>
          <div class="flex justify-center gap-8 text-sm text-slate-300 mt-6">
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-emerald-500/20 shadow-lg">
              <div class="text-3xl font-black text-emerald-400 drop-shadow-md">{@alive_count}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Survivors</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-emerald-500/20 shadow-lg">
              <div class="text-3xl font-black text-amber-400 drop-shadow-md">{rooms_cleared_count(@rooms)}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Rooms Cleared</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-emerald-500/20 shadow-lg">
              <div class="text-3xl font-black text-purple-400 drop-shadow-md">{@round}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Rounds</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-emerald-500/20 shadow-lg">
              <div class="text-3xl font-black text-cyan-400 drop-shadow-md">{length(@inventory)}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Loot</div>
            </div>
          </div>
          <div class="w-full h-px rounded-full mt-6 bg-gradient-to-r from-transparent via-emerald-500 to-transparent shadow-[0_0_10px_rgba(16,185,129,0.5)]"></div>
        </div>
      </div>

      <%!-- ═══════════════ DEFEAT OVERLAY ═══════════════ --%>
      <div
        :if={@game_status == "lost"}
        class="absolute inset-0 z-50 flex items-center justify-center bg-slate-950/90 rounded-2xl backdrop-blur-xl border border-red-500/20 overflow-hidden"
      >
        <div class="absolute inset-0 bg-[radial-gradient(circle_at_center,rgba(239,68,68,0.08)_0%,transparent_70%)] pointer-events-none"></div>
        <div class="absolute top-1/4 left-1/3 w-32 h-32 bg-red-500/10 rounded-full blur-3xl pointer-events-none" style="animation: torch-flicker 4s ease-in-out infinite"></div>

        <div class="text-center p-12 space-y-6 relative z-10">
          <div class="text-5xl font-black tracking-tighter uppercase text-red-500 defeat-banner">
            Party Wiped
          </div>
          <div class="text-slate-500 text-sm font-mono tracking-widest uppercase">
            The dungeon claims another party...
          </div>
          <div class="flex justify-center gap-8 text-sm text-slate-300 mt-6">
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-red-500/20 shadow-lg">
              <div class="text-3xl font-black text-red-400 drop-shadow-md">{@current_room + 1}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Room Reached</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-red-500/20 shadow-lg">
              <div class="text-3xl font-black text-red-400 drop-shadow-md">{rooms_cleared_count(@rooms)}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Rooms Cleared</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-red-500/20 shadow-lg">
              <div class="text-3xl font-black text-red-400 drop-shadow-md">{@round}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Rounds</div>
            </div>
          </div>
          <div class="w-full h-px rounded-full mt-6 bg-gradient-to-r from-transparent via-red-500 to-transparent shadow-[0_0_10px_rgba(239,68,68,0.5)]"></div>
        </div>
      </div>
    </div>
    """
  end

  # ── Party Member Card Component ─────────────────────────────────

  attr :member_id, :string, required: true
  attr :member, :map, required: true
  attr :active, :boolean, default: false
  attr :buffs, :list, default: []
  attr :taunt_active, :boolean, default: false
  attr :char_name, :string, default: nil
  attr :member_traits, :list, default: []

  defp party_card(assigns) do
    member = assigns.member
    member_id = assigns.member_id
    is_dead = get_val(member, :status, "alive") == "dead"
    hp = get_val(member, :hp, 0)
    max_hp = get_val(member, :max_hp, 1)
    ap = get_val(member, :ap, 0)
    max_ap = get_val(member, :max_ap, 3)
    attack = get_val(member, :attack, 0)
    armor = get_val(member, :armor, 0)
    member_class = get_val(member, :class, "warrior")
    abilities = get_val(member, :abilities, [])
    hp_pct = if max_hp > 0, do: round(hp / max_hp * 100), else: 0

    assigns =
      assigns
      |> assign(:is_dead, is_dead)
      |> assign(:hp, hp)
      |> assign(:max_hp, max_hp)
      |> assign(:ap, ap)
      |> assign(:max_ap, max_ap)
      |> assign(:attack, attack)
      |> assign(:armor, armor)
      |> assign(:member_class, member_class)
      |> assign(:abilities, abilities)
      |> assign(:hp_pct, hp_pct)
      |> assign(:member_id, member_id)

    ~H"""
    <div class={[
      "px-3 py-3 rounded-xl border transition-all duration-300 relative overflow-hidden",
      if(@is_dead, do: "opacity-40 border-slate-800 bg-slate-900/40 grayscale", else: "glass-card"),
      if(@active && !@is_dead, do: class_active_border(@member_class), else: ""),
      if(@active && !@is_dead, do: "active-member", else: ""),
      if(!@active && !@is_dead, do: "border-glass-border bg-slate-800/30 hover:bg-slate-700/40 hover:border-slate-600/50", else: "")
    ]}>
      <%!-- Subtle class-colored gradient overlay --%>
      <div :if={!@is_dead} class={[
        "absolute inset-0 opacity-[0.03] pointer-events-none",
        class_gradient(@member_class)
      ]}></div>

      <div class="relative z-10">
        <%!-- Header: Icon + Name + Active badge --%>
        <div class="flex items-center gap-2.5 mb-2">
          <div class={[
            "w-8 h-8 rounded-lg flex items-center justify-center border text-sm font-black shadow-inner",
            class_icon_style(@member_class, @is_dead)
          ]}>
            <span :if={!@is_dead}>{class_icon_char(@member_class)}</span>
            <span :if={@is_dead} class="text-slate-600">&#x2620;</span>
          </div>
          <div class="flex-1 min-w-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-1.5 min-w-0">
                <span class={[
                  "text-xs font-black tracking-wide truncate",
                  if(@is_dead, do: "text-slate-600 line-through", else: class_name_color(@member_class))
                ]}>
                  {if @char_name, do: @char_name, else: class_display_name(@member_id)}
                </span>
              </div>
              <span
                :if={@active && !@is_dead}
                class={[
                  "text-[8px] font-black px-1.5 py-0.5 rounded-full uppercase tracking-widest flex-shrink-0",
                  class_active_badge(@member_class)
                ]}
              >
                Active
              </span>
            </div>
            <span class={[
              "text-[9px] font-mono uppercase tracking-widest",
              if(@is_dead, do: "text-slate-700", else: "text-slate-500")
            ]}>
              {if @char_name, do: class_display_name(@member_id), else: String.capitalize(to_string(@member_class))}
            </span>
            <%!-- Trait badges --%>
            <div :if={!@is_dead && @member_traits != []} class="flex flex-wrap gap-1 mt-1">
              <%= for trait <- @member_traits do %>
                <span class="text-[8px] font-bold px-1.5 py-0.5 rounded-full bg-amber-500/15 text-amber-400 border border-amber-500/25">
                  {trait}
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- HP Bar --%>
        <div :if={!@is_dead} class="mb-2">
          <div class="w-full h-2 bg-slate-900/80 rounded-full overflow-hidden shadow-inner border border-slate-800/50">
            <div
              class={[
                "h-full rounded-full transition-all duration-500",
                cond do
                  @hp_pct > 60 -> "bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.8)]"
                  @hp_pct > 30 -> "bg-amber-400 shadow-[0_0_8px_rgba(251,191,36,0.8)]"
                  true -> "bg-red-500 shadow-[0_0_8px_rgba(239,68,68,0.8)]"
                end
              ]}
              style={"width: #{@hp_pct}%"}
            ></div>
          </div>
          <div class="flex items-center justify-between mt-0.5">
            <span class="text-[10px] font-mono text-slate-400">
              <span class="text-slate-200 font-semibold">{@hp}</span>/{@max_hp} HP
            </span>
            <div class="flex items-center gap-2">
              <span class="text-[9px] font-mono text-red-400/60">ATK {@attack}</span>
              <span class="text-[9px] font-mono text-cyan-400/60">ARM {@armor}</span>
            </div>
          </div>
        </div>

        <%!-- AP dots --%>
        <div :if={!@is_dead} class="flex items-center gap-1.5 mb-2">
          <span class="text-[9px] font-mono text-slate-500 uppercase tracking-widest mr-1">AP</span>
          <%= for i <- 1..max(@max_ap, 1) do %>
            <div class={[
              "w-2.5 h-2.5 rounded-full border transition-all duration-300",
              if(i <= @ap,
                do: "bg-amber-400 border-amber-300 shadow-[0_0_6px_rgba(251,191,36,0.8)]",
                else: "bg-slate-800 border-slate-700"
              )
            ]}></div>
          <% end %>
        </div>

        <%!-- Abilities --%>
        <div :if={!@is_dead && @abilities != []} class="mb-2">
          <div class="flex flex-wrap gap-1">
            <%= for ability <- @abilities do %>
              <span class={[
                "text-[9px] font-mono px-1.5 py-0.5 rounded border",
                class_ability_style(@member_class)
              ]}>
                {ability}
              </span>
            <% end %>
          </div>
        </div>

        <%!-- Buffs --%>
        <div :if={!@is_dead && @buffs != []} class="space-y-0.5">
          <%= for buff <- @buffs do %>
            <div class="flex items-center justify-between text-[9px] font-mono px-1.5 py-0.5 rounded bg-amber-950/20 border border-amber-500/10">
              <span class="text-amber-300/80">{get_val(buff, :type, "buff")}</span>
              <span class="text-amber-500/50">{get_val(buff, :remaining_turns, 0)}t</span>
            </div>
          <% end %>
        </div>

        <%!-- Taunt indicator --%>
        <div :if={@taunt_active && !@is_dead} class="mt-1.5 px-2 py-1 rounded-md bg-red-950/30 border border-red-500/20 flex items-center gap-1.5">
          <span class="w-1.5 h-1.5 rounded-full bg-red-500 shadow-[0_0_4px_rgba(239,68,68,0.8)]"></span>
          <span class="text-red-400 text-[9px] font-black tracking-widest uppercase">Taunt Active</span>
        </div>

        <%!-- Dead state --%>
        <div :if={@is_dead} class="text-center py-1">
          <span class="text-slate-600 text-[10px] font-mono uppercase tracking-widest">Fallen</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Class Theming Helpers ──────────────────────────────────────

  defp class_icon_char("warrior"), do: "W"
  defp class_icon_char("rogue"), do: "R"
  defp class_icon_char("mage"), do: "M"
  defp class_icon_char("cleric"), do: "C"
  defp class_icon_char(other) when is_binary(other), do: String.first(String.upcase(other))
  defp class_icon_char(_), do: "?"

  defp class_display_name("warrior"), do: "Warrior"
  defp class_display_name("rogue"), do: "Rogue"
  defp class_display_name("mage"), do: "Mage"
  defp class_display_name("cleric"), do: "Cleric"
  defp class_display_name(other) when is_binary(other), do: String.capitalize(other)
  defp class_display_name(_), do: "Unknown"

  defp class_name_color("warrior"), do: "text-red-300"
  defp class_name_color("rogue"), do: "text-emerald-300"
  defp class_name_color("mage"), do: "text-indigo-300"
  defp class_name_color("cleric"), do: "text-amber-300"
  defp class_name_color(_), do: "text-slate-300"

  defp class_icon_style("warrior", false),
    do: "bg-red-950/60 border-red-500/40 text-red-400 shadow-[0_0_8px_rgba(239,68,68,0.2)]"

  defp class_icon_style("rogue", false),
    do: "bg-emerald-950/60 border-emerald-500/40 text-emerald-400 shadow-[0_0_8px_rgba(16,185,129,0.2)]"

  defp class_icon_style("mage", false),
    do: "bg-indigo-950/60 border-indigo-500/40 text-indigo-400 shadow-[0_0_8px_rgba(99,102,241,0.2)]"

  defp class_icon_style("cleric", false),
    do: "bg-amber-950/60 border-amber-500/40 text-amber-400 shadow-[0_0_8px_rgba(251,191,36,0.2)]"

  defp class_icon_style(_, false),
    do: "bg-slate-800 border-slate-600 text-slate-400"

  defp class_icon_style(_, true),
    do: "bg-slate-800 border-slate-700 text-slate-600"

  defp class_active_border("warrior"),
    do: "border-red-500/50 bg-red-950/20 ring-1 ring-red-500/20"

  defp class_active_border("rogue"),
    do: "border-emerald-500/50 bg-emerald-950/20 ring-1 ring-emerald-500/20"

  defp class_active_border("mage"),
    do: "border-indigo-500/50 bg-indigo-950/20 ring-1 ring-indigo-500/20"

  defp class_active_border("cleric"),
    do: "border-amber-500/50 bg-amber-950/20 ring-1 ring-amber-500/20"

  defp class_active_border(_),
    do: "border-slate-600 bg-slate-800/30"

  defp class_active_badge("warrior"),
    do: "bg-red-500/20 text-red-400 border border-red-500/40"

  defp class_active_badge("rogue"),
    do: "bg-emerald-500/20 text-emerald-400 border border-emerald-500/40"

  defp class_active_badge("mage"),
    do: "bg-indigo-500/20 text-indigo-400 border border-indigo-500/40"

  defp class_active_badge("cleric"),
    do: "bg-amber-500/20 text-amber-400 border border-amber-500/40"

  defp class_active_badge(_),
    do: "bg-slate-500/20 text-slate-400 border border-slate-500/40"

  defp class_gradient("warrior"), do: "bg-gradient-to-br from-red-500 to-red-900"
  defp class_gradient("rogue"), do: "bg-gradient-to-br from-emerald-500 to-emerald-900"
  defp class_gradient("mage"), do: "bg-gradient-to-br from-indigo-500 to-indigo-900"
  defp class_gradient("cleric"), do: "bg-gradient-to-br from-amber-500 to-amber-900"
  defp class_gradient(_), do: "bg-gradient-to-br from-slate-500 to-slate-900"

  defp class_ability_style("warrior"),
    do: "bg-red-950/30 border-red-500/15 text-red-400/70"

  defp class_ability_style("rogue"),
    do: "bg-emerald-950/30 border-emerald-500/15 text-emerald-400/70"

  defp class_ability_style("mage"),
    do: "bg-indigo-950/30 border-indigo-500/15 text-indigo-400/70"

  defp class_ability_style("cleric"),
    do: "bg-amber-950/30 border-amber-500/15 text-amber-400/70"

  defp class_ability_style(_),
    do: "bg-slate-800/30 border-slate-600/15 text-slate-400/70"

  defp class_badge_style("warrior"),
    do: "bg-red-500/20 text-red-400 border-red-500/40 shadow-[0_0_8px_rgba(239,68,68,0.2)]"

  defp class_badge_style("rogue"),
    do: "bg-emerald-500/20 text-emerald-400 border-emerald-500/40 shadow-[0_0_8px_rgba(16,185,129,0.2)]"

  defp class_badge_style("mage"),
    do: "bg-indigo-500/20 text-indigo-400 border-indigo-500/40 shadow-[0_0_8px_rgba(99,102,241,0.2)]"

  defp class_badge_style("cleric"),
    do: "bg-amber-500/20 text-amber-400 border-amber-500/40 shadow-[0_0_8px_rgba(251,191,36,0.2)]"

  defp class_badge_style(_),
    do: "bg-slate-700/50 text-slate-400 border-slate-600"

  # ── Enemy Helpers ──────────────────────────────────────────────

  defp enemy_icon(type) when is_binary(type) do
    downcased = String.downcase(type)

    cond do
      String.contains?(downcased, "dragon") -> "D"
      String.contains?(downcased, "skeleton") -> "S"
      String.contains?(downcased, "goblin") -> "G"
      String.contains?(downcased, "orc") -> "O"
      String.contains?(downcased, "troll") -> "T"
      String.contains?(downcased, "lich") -> "L"
      String.contains?(downcased, "slime") -> "~"
      String.contains?(downcased, "spider") -> "X"
      String.contains?(downcased, "bat") -> "B"
      String.contains?(downcased, "rat") -> "r"
      String.contains?(downcased, "wolf") -> "W"
      String.contains?(downcased, "boss") -> "!"
      String.contains?(downcased, "demon") -> "&"
      String.contains?(downcased, "ghost") -> "?"
      String.contains?(downcased, "zombie") -> "Z"
      String.contains?(downcased, "mimic") -> "M"
      true -> String.first(String.upcase(type))
    end
  end

  defp enemy_icon(_), do: "?"

  # ── Combat Log Styling ────────────────────────────────────────

  defp log_entry_style(entry) when is_binary(entry) do
    downcased = String.downcase(entry)

    cond do
      String.contains?(downcased, "heal") or String.contains?(downcased, "restore") ->
        "bg-emerald-950/30 text-emerald-400 border-emerald-500"

      String.contains?(downcased, "buff") or String.contains?(downcased, "shield") or
          String.contains?(downcased, "protect") or String.contains?(downcased, "bless") ->
        "bg-amber-950/30 text-amber-400 border-amber-500"

      String.contains?(downcased, "trap") or String.contains?(downcased, "poison") ->
        "bg-purple-950/30 text-purple-400 border-purple-500"

      String.contains?(downcased, "room") or String.contains?(downcased, "advance") or
          String.contains?(downcased, "enter") or String.contains?(downcased, "descend") ->
        "bg-cyan-950/30 text-cyan-400 border-cyan-500"

      String.contains?(downcased, "attack") or String.contains?(downcased, "strike") or
          String.contains?(downcased, "slash") or String.contains?(downcased, "hit") or
          String.contains?(downcased, "damage") or String.contains?(downcased, "kill") or
          String.contains?(downcased, "defeat") or String.contains?(downcased, "slay") ->
        "bg-red-950/30 text-red-400 border-red-500"

      true ->
        "bg-slate-800/30 text-slate-400 border-slate-600"
    end
  end

  defp log_entry_style(_), do: "bg-slate-800/30 text-slate-400 border-slate-600"

  # ── General Helpers ────────────────────────────────────────────

  defp truncate_name(name, max_len) when is_binary(name) do
    if String.length(name) > max_len do
      String.slice(name, 0, max_len - 1) <> "..."
    else
      name
    end
  end

  defp truncate_name(_, _), do: "???"

  defp rooms_cleared_count(rooms) when is_list(rooms) do
    Enum.count(rooms, fn r -> get_val(r, :cleared, false) end)
  end

  defp rooms_cleared_count(_), do: 0

  # ── Flexible Key Access ────────────────────────────────────────

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_, _, default), do: default
end
