defmodule LemonSimUi.Live.Components.SkirmishBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    map_data = MapHelpers.get_key(world, :map) || %{}
    width = MapHelpers.get_key(map_data, :width) || 5
    height = MapHelpers.get_key(map_data, :height) || 5
    cover_tiles = MapHelpers.get_key(map_data, :cover) || []
    wall_tiles = MapHelpers.get_key(map_data, :walls) || []
    water_tiles = MapHelpers.get_key(map_data, :water) || []
    high_ground_tiles = MapHelpers.get_key(map_data, :high_ground) || []
    units = MapHelpers.get_key(world, :units) || %{}
    active_actor = MapHelpers.get_key(world, :active_actor_id)
    round = MapHelpers.get_key(world, :round) || 1
    phase = MapHelpers.get_key(world, :phase) || "main"
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    kill_feed = MapHelpers.get_key(world, :kill_feed) || []

    # Adaptive tile sizing
    tile_size =
      cond do
        width > 15 or height > 15 -> 28
        width > 10 or height > 10 -> 36
        true -> 48
      end

    # Build terrain sets
    cover_set = MapSet.new(cover_tiles, fn c -> {get_coord(c, :x), get_coord(c, :y)} end)
    wall_set = MapSet.new(wall_tiles, fn c -> {get_coord(c, :x), get_coord(c, :y)} end)
    water_set = MapSet.new(water_tiles, fn c -> {get_coord(c, :x), get_coord(c, :y)} end)
    high_ground_set = MapSet.new(high_ground_tiles, fn c -> {get_coord(c, :x), get_coord(c, :y)} end)

    # Build position lookup for units (alive + dead)
    unit_positions = build_unit_positions(units)

    # Active unit data
    active_unit_data = if active_actor, do: Map.get(units, active_actor), else: nil

    # Compute valid move tiles for active unit when interactive
    valid_moves =
      if assigns.interactive && active_unit_data && status == "in_progress" do
        compute_valid_moves(active_actor, active_unit_data, unit_positions, wall_set, width, height)
      else
        MapSet.new()
      end

    # Compute attackable targets for active unit when interactive
    attackable_targets =
      if assigns.interactive && active_unit_data && status == "in_progress" do
        compute_attackable_targets(active_actor, active_unit_data, units)
      else
        []
      end

    # Split units by team
    red_units =
      units
      |> Enum.filter(fn {_id, u} -> get_val(u, :team, "") == "red" end)
      |> Enum.sort_by(fn {id, _u} -> id end)

    blue_units =
      units
      |> Enum.filter(fn {_id, u} -> get_val(u, :team, "") == "blue" end)
      |> Enum.sort_by(fn {id, _u} -> id end)

    # Recent kill feed (last 8)
    recent_feed = Enum.take(kill_feed, 8)

    assigns =
      assigns
      |> assign(:width, width)
      |> assign(:height, height)
      |> assign(:tile_size, tile_size)
      |> assign(:cover_set, cover_set)
      |> assign(:wall_set, wall_set)
      |> assign(:water_set, water_set)
      |> assign(:high_ground_set, high_ground_set)
      |> assign(:unit_positions, unit_positions)
      |> assign(:units, units)
      |> assign(:active_actor, active_actor)
      |> assign(:active_unit_data, active_unit_data)
      |> assign(:round, round)
      |> assign(:phase, phase)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:valid_moves, valid_moves)
      |> assign(:attackable_targets, attackable_targets)
      |> assign(:red_units, red_units)
      |> assign(:blue_units, blue_units)
      |> assign(:recent_feed, recent_feed)

    ~H"""
    <div class="relative font-sans">
      <%!-- Inline styles for animations and patterns --%>
      <style>
        @keyframes pulse-glow-red {
          0%, 100% { box-shadow: 0 0 10px rgba(239, 68, 68, 0.4), inset 0 0 5px rgba(239, 68, 68, 0.2); }
          50% { box-shadow: 0 0 20px rgba(239, 68, 68, 0.8), inset 0 0 10px rgba(239, 68, 68, 0.4); }
        }
        @keyframes pulse-glow-blue {
          0%, 100% { box-shadow: 0 0 10px rgba(6, 182, 212, 0.4), inset 0 0 5px rgba(6, 182, 212, 0.2); }
          50% { box-shadow: 0 0 20px rgba(6, 182, 212, 0.8), inset 0 0 10px rgba(6, 182, 212, 0.4); }
        }
        .active-unit-red { animation: pulse-glow-red 2s cubic-bezier(0.4, 0, 0.6, 1) infinite; border-color: rgba(239, 68, 68, 0.8) !important; }
        .active-unit-blue { animation: pulse-glow-blue 2s cubic-bezier(0.4, 0, 0.6, 1) infinite; border-color: rgba(6, 182, 212, 0.8) !important; }
        @keyframes slide-in-right {
          from { transform: translateX(40px); opacity: 0; }
          to { transform: translateX(0); opacity: 1; }
        }
        .kill-feed-enter { animation: slide-in-right 0.3s ease-out; }
        @keyframes victory-pulse {
          0%, 100% { transform: scale(1); text-shadow: 0 0 20px rgba(255,255,255,0.5); }
          50% { transform: scale(1.02); text-shadow: 0 0 40px rgba(255,255,255,0.8); }
        }
        .victory-banner { animation: victory-pulse 2s ease-in-out infinite; }
        .wall-pattern {
          background-image: repeating-linear-gradient(
            45deg,
            transparent,
            transparent 3px,
            rgba(255, 255, 255, 0.05) 3px,
            rgba(255, 255, 255, 0.05) 6px
          );
        }
        .water-pattern {
          background-image: repeating-linear-gradient(
            180deg,
            transparent,
            transparent 4px,
            rgba(6, 182, 212, 0.1) 4px,
            rgba(6, 182, 212, 0.1) 6px
          );
          animation: water-flow 4s linear infinite;
        }
        @keyframes valid-move-pulse {
          0%, 100% { background-color: rgba(16, 185, 129, 0.1); box-shadow: inset 0 0 5px rgba(16, 185, 129, 0.2); }
          50% { background-color: rgba(16, 185, 129, 0.25); box-shadow: inset 0 0 15px rgba(16, 185, 129, 0.4); }
        }
        .valid-move-tile { animation: valid-move-pulse 1.5s ease-in-out infinite; }
      </style>

      <%!-- Status Bar --%>
      <div class="mb-4 px-4 py-3 rounded-xl glass-panel relative overflow-hidden flex items-center justify-between shadow-neon-blue">
        <div class="absolute inset-0 bg-gradient-to-r from-cyan-500/10 via-transparent to-red-500/10 opacity-30 pointer-events-none"></div>
        <div :if={@game_status == "in_progress"} class="flex items-center justify-between text-sm w-full relative z-10">
          <div class="flex items-center gap-4">
            <span class="text-cyan-500 font-mono text-xs tracking-widest uppercase font-bold">Round</span>
            <span class="text-white font-black text-lg tabular-nums text-glow-cyan">{@round}</span>
            <span class="w-px h-5 bg-glass-border"></span>
            <span class="text-slate-500 font-mono text-xs tracking-widest uppercase font-bold">Phase</span>
            <span class="text-slate-200 font-semibold tracking-wider">{@phase}</span>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-slate-500 text-xs font-mono uppercase tracking-widest font-bold">Active:</span>
            <span class={[
              "px-3 py-1 rounded-md text-xs font-black tracking-wider shadow-sm",
              active_actor_badge(@active_actor, @units)
            ]}>
              {format_unit_label(@active_actor, @units)}
            </span>
          </div>
        </div>
      </div>

      <%!-- Main Layout: Left Roster | Board | Right Roster + Kill Feed --%>
      <div class="flex gap-4 items-start">

        <%!-- Left Panel: Red Team Roster --%>
        <div class="w-48 flex-shrink-0 space-y-2">
          <div class="flex items-center gap-2 px-3 py-2 rounded-xl bg-red-950/40 border border-red-500/20 shadow-[0_0_15px_rgba(239,68,68,0.1)]">
            <div class="w-2.5 h-2.5 rounded-full bg-red-500 shadow-[0_0_8px_rgba(239,68,68,1)]"></div>
            <span class="text-red-400 text-xs font-black tracking-widest uppercase text-glow-red">Red Team</span>
          </div>
          <div class="space-y-1.5 p-1">
            <%= for {unit_id, unit} <- @red_units do %>
              <.roster_card
                unit_id={unit_id}
                unit={unit}
                active={unit_id == @active_actor}
                team="red"
              />
            <% end %>
          </div>
        </div>

        <%!-- Center: The Grid Board --%>
        <div class="flex flex-col items-center">
          <div class="relative">
            <%!-- Column headers --%>
            <div class="flex" style={"margin-left: #{@tile_size - 8}px"}>
              <%= for x <- 0..(@width - 1) do %>
                <div
                  class="text-center text-gray-600 font-mono text-[9px]"
                  style={"width: #{@tile_size + 2}px"}
                >
                  {x}
                </div>
              <% end %>
            </div>

            <div class="flex">
              <%!-- Row headers --%>
              <div class="flex flex-col" style={"margin-top: 1px"}>
                <%= for y <- 0..(@height - 1) do %>
                  <div
                    class="flex items-center justify-center text-gray-600 font-mono text-[9px]"
                    style={"width: #{@tile_size - 10}px; height: #{@tile_size + 2}px"}
                  >
                    {y}
                  </div>
                <% end %>
              </div>

              <%!-- Grid --%>
              <div
                class="grid gap-px bg-slate-800/80 rounded-xl overflow-hidden border border-glass-border shadow-glass relative z-10 backdrop-blur-sm p-1"
                style={"grid-template-columns: repeat(#{@width}, #{@tile_size}px); grid-auto-rows: #{@tile_size}px"}
              >
                <%= for y <- 0..(@height - 1) do %>
                  <%= for x <- 0..(@width - 1) do %>
                    <% terrain = tile_terrain(x, y, @cover_set, @wall_set, @water_set, @high_ground_set) %>
                    <% unit_here = Map.get(@unit_positions, {x, y}) %>
                    <% is_valid_move = MapSet.member?(@valid_moves, {x, y}) %>
                    <% is_wall = terrain == :wall %>
                    <% clickable = @interactive && is_valid_move && is_nil(unit_here) && @game_status == "in_progress" %>
                    <div
                      class={[
                        "relative flex items-center justify-center transition-all duration-300 rounded-md",
                        terrain_bg(terrain),
                        if(terrain == :wall, do: "wall-pattern", else: ""),
                        if(terrain == :water, do: "water-pattern", else: ""),
                        if(is_valid_move && is_nil(unit_here), do: "valid-move-tile ring-1 ring-inset ring-emerald-400/50 shadow-[0_0_10px_rgba(16,185,129,0.2)_inset]", else: ""),
                        if(clickable, do: "cursor-pointer hover:ring-2 hover:ring-emerald-400/80 hover:shadow-[0_0_15px_rgba(16,185,129,0.5)_inset] hover:scale-[0.98]", else: "")
                      ]}
                      phx-click={if clickable, do: "human_move_to"}
                      phx-value-x={x}
                      phx-value-y={y}
                    >
                      <%!-- Terrain icon overlays --%>
                      <div
                        :if={terrain == :cover && is_nil(unit_here)}
                        class="absolute inset-0 flex items-center justify-center text-gray-600 pointer-events-none"
                        style={"font-size: #{max(10, @tile_size - 30)}px"}
                      >
                        &#x25A9;
                      </div>
                      <div
                        :if={terrain == :high_ground && is_nil(unit_here)}
                        class="absolute inset-0 flex items-center justify-center pointer-events-none"
                        style={"font-size: #{max(8, @tile_size - 32)}px"}
                      >
                        <span class="text-amber-700/60 font-bold">&uarr;</span>
                      </div>
                      <div
                        :if={terrain == :water && is_nil(unit_here)}
                        class="absolute inset-0 flex items-center justify-center pointer-events-none"
                        style={"font-size: #{max(8, @tile_size - 34)}px"}
                      >
                        <span class="text-blue-700/40">~</span>
                      </div>
                      <div
                        :if={is_wall}
                        class="absolute inset-0 flex items-center justify-center pointer-events-none"
                      >
                        <div class="absolute inset-x-0 bottom-0 h-1/2 bg-gradient-to-t from-slate-900/50 to-transparent"></div>
                      </div>

                      <%!-- Unit rendering --%>
                      <%= if unit_here do %>
                        <% u = unit_here.data %>
                        <% is_dead = get_val(u, :status, "alive") == "dead" %>
                        <% is_active = unit_here.id == @active_actor %>
                        <% team = get_val(u, :team, "") %>
                        <% has_cover = get_val(u, :cover?, false) %>
                        <div class={[
                          "flex flex-col items-center gap-0 z-10",
                          if(is_dead, do: "opacity-40", else: "")
                        ]}>
                          <%!-- Unit circle --%>
                          <div
                            class={[
                              "rounded-full flex items-center justify-center font-bold border-2 relative transition-all duration-300",
                              unit_circle_classes(team, is_dead),
                              if(is_active && !is_dead, do: "active-unit-#{team}", else: ""),
                              if(is_active && !is_dead, do: "ring-2 ring-offset-2 ring-offset-slate-900 ring-white/80 scale-110 z-20", else: "z-10 shadow-lg")
                            ]}
                            style={"width: #{circle_size(@tile_size)}px; height: #{circle_size(@tile_size)}px; font-size: #{max(8, circle_size(@tile_size) - 10)}px; line-height: 1"}
                          >
                            <span :if={!is_dead} class={[unit_icon_class(get_val(u, :class, "soldier")), "drop-shadow-md"]}>
                              {unit_icon_char(get_val(u, :class, "soldier"))}
                            </span>
                            <span :if={is_dead} class="text-slate-500">X</span>

                            <%!-- Cover shield indicator --%>
                            <div
                              :if={has_cover && !is_dead}
                              class="absolute -top-1.5 -right-1.5 w-4 h-4 rounded-full bg-slate-900 border-2 border-cyan-400 flex items-center justify-center shadow-neon-cyan"
                            >
                              <span class="text-cyan-400 text-[8px] font-black leading-none pb-0.5">S</span>
                            </div>
                          </div>

                          <%!-- HP bar --%>
                          <div
                            :if={!is_dead}
                            class="bg-gray-700/80 rounded-full overflow-hidden mt-0.5"
                            style={"width: #{min(@tile_size - 8, 36)}px; height: 3px"}
                          >
                            <div
                              class={hp_bar_color(unit_here)}
                              style={"width: #{hp_percent(unit_here)}%"}
                            ></div>
                          </div>

                          <%!-- AP dots --%>
                          <div :if={!is_dead} class="flex gap-px mt-px">
                            <%= for i <- 1..(get_val(u, :max_ap, 2)) do %>
                              <div class={[
                                "rounded-full",
                                if(i <= get_val(u, :ap, 0), do: "bg-yellow-400", else: "bg-gray-600/60")
                              ]} style="width: 4px; height: 4px"></div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Legend --%>
          <div class="flex flex-wrap justify-center gap-x-4 gap-y-1 mt-3 text-[10px] text-gray-500">
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded bg-gray-900 border border-gray-700"></div>
              <span>Empty</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded bg-gray-800 border border-gray-600">
                <span class="text-[6px] text-gray-500 flex items-center justify-center h-full">&#x25A9;</span>
              </div>
              <span>Cover</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded bg-gray-700 wall-pattern border border-gray-600"></div>
              <span>Wall</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded bg-blue-950/60 water-pattern border border-blue-900/30"></div>
              <span>Water (2 AP)</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded bg-amber-950/30 border border-amber-800/30"></div>
              <span>High Ground</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded-full bg-red-500/80 border border-red-400"></div>
              <span>Red</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-3 h-3 rounded-full bg-blue-500/80 border border-blue-400"></div>
              <span>Blue</span>
            </div>
          </div>

          <%!-- Interactive Controls --%>
          <div :if={@interactive && @game_status == "in_progress" && @active_unit_data} class="mt-4 w-full">
            <div class="glass-panel rounded-xl border border-cyan-500/30 p-4 shadow-neon-cyan relative overflow-hidden">
              <div class="absolute top-0 right-0 w-32 h-32 bg-cyan-500/10 rounded-full blur-3xl -mr-16 -mt-16 pointer-events-none"></div>
              <div class="text-[10px] text-cyan-400 uppercase tracking-widest font-black mb-3 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 shadow-[0_0_8px_rgba(6,182,212,1)]"></span>
                TACTICAL COMMANDS
              </div>
              <div class="flex flex-wrap gap-2.5 relative z-10">
                <%!-- End Turn --%>
                <button
                  phx-click="human_action"
                  phx-value-action="end_turn"
                  class="glass-button px-4 py-2 text-xs font-bold rounded-lg uppercase tracking-wider"
                >
                  End Turn
                </button>

                <%!-- Take Cover --%>
                <button
                  phx-click="human_action"
                  phx-value-action="take_cover"
                  class="px-4 py-2 text-xs font-bold rounded-lg uppercase tracking-wider bg-gradient-to-r from-cyan-900/60 to-blue-900/60 text-cyan-300 border border-cyan-500/50 hover:from-cyan-800/80 hover:to-blue-800/80 hover:text-white transition-all shadow-[0_0_10px_rgba(6,182,212,0.2)] hover:shadow-[0_0_15px_rgba(6,182,212,0.4)]"
                >
                  Take Cover
                </button>

                <%!-- Heal (medic only, when adjacent ally wounded) --%>
                <button
                  :if={get_val(@active_unit_data, :class, "") == "medic"}
                  phx-click="human_action"
                  phx-value-action="heal"
                  class="px-4 py-2 text-xs font-bold rounded-lg uppercase tracking-wider bg-gradient-to-r from-emerald-900/60 to-green-900/60 text-emerald-300 border border-emerald-500/50 hover:from-emerald-800/80 hover:to-green-800/80 hover:text-white transition-all shadow-[0_0_10px_rgba(16,185,129,0.2)] hover:shadow-[0_0_15px_rgba(16,185,129,0.4)]"
                >
                  Heal Ally
                </button>

                <%!-- Sprint (scout only) --%>
                <button
                  :if={get_val(@active_unit_data, :class, "") == "scout"}
                  phx-click="human_action"
                  phx-value-action="sprint"
                  class="px-4 py-2 text-xs font-bold rounded-lg uppercase tracking-wider bg-gradient-to-r from-purple-900/60 to-fuchsia-900/60 text-purple-300 border border-purple-500/50 hover:from-purple-800/80 hover:to-fuchsia-800/80 hover:text-white transition-all shadow-[0_0_10px_rgba(168,85,247,0.2)] hover:shadow-[0_0_15px_rgba(168,85,247,0.4)]"
                >
                  Dash
                </button>

                <%!-- Attack buttons for each target in range --%>
                <%= for target_id <- @attackable_targets do %>
                  <% target_unit = Map.get(@units, target_id) %>
                  <button
                    phx-click="human_attack"
                    phx-value-target={target_id}
                    class="px-4 py-2 text-xs font-bold rounded-lg uppercase tracking-wider bg-gradient-to-r from-red-900/60 to-rose-900/60 text-red-300 border border-red-500/50 hover:from-red-800/80 hover:to-rose-800/80 hover:text-white transition-all shadow-[0_0_10px_rgba(239,68,68,0.2)] hover:shadow-[0_0_15px_rgba(239,68,68,0.4)] relative overflow-hidden group"
                  >
                    <div class="absolute inset-0 bg-gradient-to-r from-red-500/20 to-transparent -translate-x-full group-hover:animate-[slide-in-right_0.5s_forwards]"></div>
                    <span class="relative z-10 flex items-center gap-1.5">
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
                        <path fill-rule="evenodd" d="M11.3 1.046A1 1 0 0112 2v5h4a1 1 0 01.82 1.573l-7 10A1 1 0 018 18v-5H4a1 1 0 01-.82-1.573l7-10a1 1 0 011.12-.38z" clip-rule="evenodd" />
                      </svg>
                      STRIKE {target_id}
                      <span :if={target_unit} class="text-red-400/70 ml-1 text-[10px]">
                        [{class_label(get_val(target_unit, :class, ""))}]
                      </span>
                    </span>
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Right Panel: Blue Team Roster + Kill Feed --%>
        <div class="w-48 flex-shrink-0 flex flex-col gap-5">
          <%!-- Blue Team Roster --%>
          <div class="space-y-2">
            <div class="flex items-center gap-2 px-3 py-2 rounded-xl bg-cyan-950/40 border border-cyan-500/20 shadow-[0_0_15px_rgba(6,182,212,0.1)]">
              <div class="w-2.5 h-2.5 rounded-full bg-cyan-500 shadow-[0_0_8px_rgba(6,182,212,1)]"></div>
              <span class="text-cyan-400 text-xs font-black tracking-widest uppercase text-glow-cyan">Blue Team</span>
            </div>
            <div class="space-y-1.5 p-1">
              <%= for {unit_id, unit} <- @blue_units do %>
                <.roster_card
                  unit_id={unit_id}
                  unit={unit}
                  active={unit_id == @active_actor}
                  team="blue"
                />
              <% end %>
            </div>
          </div>

          <%!-- Kill Feed --%>
          <div :if={@recent_feed != []} class="space-y-1.5 glass-card rounded-xl p-2">
            <div class="flex items-center gap-2 px-2 py-1.5 border-b border-glass-border">
              <span class="text-slate-400 text-[10px] font-black tracking-widest uppercase">Combat Log</span>
            </div>
            <div class="space-y-1 max-h-64 overflow-y-auto custom-scrollbar pr-1 pt-1">
              <%= for entry <- @recent_feed do %>
                <div class={[
                  "px-2 py-1.5 rounded text-[10px] leading-snug kill-feed-enter border font-mono shadow-sm",
                  feed_entry_classes(entry)
                ]}>
                  {get_val(entry, :message, "")}
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%!-- Victory Overlay --%>
      <div
        :if={@game_status == "won" && @winner}
        class="absolute inset-0 z-50 flex items-center justify-center bg-slate-950/80 rounded-2xl backdrop-blur-xl border border-glass-border victory-overlay overflow-hidden"
      >
        <div class="absolute inset-0 bg-[radial-gradient(circle_at_center,rgba(59,130,246,0.1)_0%,transparent_70%)] pointer-events-none"></div>
        <div class="text-center p-12 space-y-8 victory-banner relative z-10">
          <div class={[
            "text-6xl font-black tracking-tighter uppercase drop-shadow-[0_0_15px_rgba(255,255,255,0.3)]",
            if(@winner == "red", do: "text-red-400 text-glow-red", else: "text-cyan-400 text-glow-cyan")
          ]}>
            {String.upcase(@winner || "")} TEAM WINS
          </div>
          <div class="flex justify-center gap-12 text-sm text-slate-300">
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-glass-border shadow-lg">
              <div class="text-4xl font-black text-white drop-shadow-md">{count_alive_units(@units, @winner)}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Units Out</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-glass-border shadow-lg">
              <div class="text-4xl font-black text-white drop-shadow-md">{@round}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">Rounds</div>
            </div>
            <div class="text-center glass-panel px-6 py-4 rounded-xl border border-glass-border shadow-lg">
              <div class="text-4xl font-black text-white drop-shadow-md">{count_kills(@units, @winner)}</div>
              <div class="text-[10px] uppercase tracking-widest text-slate-400 mt-1 font-bold">KIA</div>
            </div>
          </div>
          <div class={[
            "w-full h-px rounded-full mt-8 shadow-[0_0_10px_currentColor]",
            if(@winner == "red", do: "bg-gradient-to-r from-transparent via-red-500 to-transparent", else: "bg-gradient-to-r from-transparent via-cyan-500 to-transparent")
          ]}></div>
        </div>
      </div>
    </div>
    """
  end

  # ── Roster Card Component ──────────────────────────────────────────

  attr :unit_id, :string, required: true
  attr :unit, :map, required: true
  attr :active, :boolean, default: false
  attr :team, :string, required: true

  defp roster_card(assigns) do
    unit = assigns.unit
    is_dead = get_val(unit, :status, "alive") == "dead"
    hp = get_val(unit, :hp, 0)
    max_hp = get_val(unit, :max_hp, 1)
    ap = get_val(unit, :ap, 0)
    max_ap = get_val(unit, :max_ap, 2)
    hp_pct = if max_hp > 0, do: round(hp / max_hp * 100), else: 0
    unit_class = get_val(unit, :class, "soldier")

    assigns =
      assigns
      |> assign(:is_dead, is_dead)
      |> assign(:hp, hp)
      |> assign(:max_hp, max_hp)
      |> assign(:ap, ap)
      |> assign(:max_ap, max_ap)
      |> assign(:hp_pct, hp_pct)
      |> assign(:unit_class, unit_class)

    ~H"""
    <div class={[
      "px-3 py-2 rounded-lg border transition-all duration-300 text-xs shadow-sm relative overflow-hidden group/card",
      if(@is_dead, do: "opacity-40 border-slate-800 bg-slate-900/40 grayscale", else: "glass-card"),
      if(@active && !@is_dead, do: roster_active_border(@team), else: ""),
      if(!@active && !@is_dead, do: "border-glass-border bg-slate-800/30 hover:bg-slate-700/40 hover:border-slate-600/50", else: "")
    ]}>
      <div class="absolute inset-0 bg-gradient-to-br from-white/5 to-transparent opacity-0 group-hover/card:opacity-100 transition-opacity pointer-events-none"></div>
      <div class="flex items-center gap-2.5 relative z-10">
        <%!-- Class icon --%>
        <div class={[
          "w-7 h-7 rounded-md flex items-center justify-center text-sm font-black border shadow-inner",
          roster_icon_classes(@team, @is_dead)
        ]}>
          <span :if={!@is_dead} class={[unit_icon_class(@unit_class), "drop-shadow-md"]}>
            {unit_icon_char(@unit_class)}
          </span>
          <span :if={@is_dead} class="text-slate-600 font-normal">X</span>
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between mb-0.5">
            <span class={[
              "font-mono text-[11px] font-bold truncate tracking-wide",
              if(@is_dead, do: "text-slate-600 line-through decoration-slate-700 decoration-2", else: "text-slate-200")
            ]}>
              {@unit_id}
            </span>
            <span class={[
              "text-[9px] font-bold px-1.5 py-0.5 rounded uppercase tracking-widest",
              if(@is_dead, do: "text-slate-600 bg-slate-900", else: "text-slate-400 bg-slate-900/60 border border-slate-700/50")
            ]}>
              {class_label(@unit_class)}
            </span>
          </div>
          <%!-- HP bar --%>
          <div :if={!@is_dead} class="w-full h-1.5 bg-slate-900/80 rounded-full overflow-hidden mt-1 shadow-inner border border-slate-800/50">
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
          <%!-- Stats row --%>
          <div :if={!@is_dead} class="flex items-center justify-between mt-1">
            <span class="text-[10px] font-mono text-slate-400 font-semibold"><span class="text-slate-200">{@hp}</span>/{@max_hp} HP</span>
            <div class="flex gap-1">
              <%= for i <- 1..@max_ap do %>
                <div class={[
                  "w-2 h-2 rounded-full border border-slate-900",
                  if(i <= @ap, do: "bg-cyan-400 shadow-[0_0_5px_rgba(34,211,238,0.8)]", else: "bg-slate-700/50")
                ]}></div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Position & Unit Builders ───────────────────────────────────────

  defp build_unit_positions(units) do
    Enum.reduce(units, %{}, fn {unit_id, unit}, acc ->
      pos = get_val(unit, :pos, %{})
      x = get_val(pos, :x, nil)
      y = get_val(pos, :y, nil)

      if x && y do
        Map.put(acc, {x, y}, %{id: unit_id, data: unit})
      else
        acc
      end
    end)
  end

  # ── Terrain Classification ────────────────────────────────────────

  defp tile_terrain(x, y, cover_set, wall_set, water_set, high_ground_set) do
    cond do
      MapSet.member?(wall_set, {x, y}) -> :wall
      MapSet.member?(water_set, {x, y}) -> :water
      MapSet.member?(high_ground_set, {x, y}) -> :high_ground
      MapSet.member?(cover_set, {x, y}) -> :cover
      true -> :empty
    end
  end

  defp terrain_bg(:empty), do: "bg-slate-900/60"
  defp terrain_bg(:cover), do: "bg-slate-800/80 border border-slate-700/50 shadow-inner"
  defp terrain_bg(:wall), do: "bg-slate-800/90 border border-slate-700"
  defp terrain_bg(:water), do: "bg-blue-900/30 border border-blue-500/10 shadow-[0_0_15px_rgba(59,130,246,0.1)_inset]"
  defp terrain_bg(:high_ground), do: "bg-slate-700/50 border border-slate-600 shadow-[0_2px_10px_rgba(0,0,0,0.5)] z-10"

  # ── Unit Visuals ──────────────────────────────────────────────────

  defp circle_size(tile_size) when tile_size >= 48, do: 26
  defp circle_size(tile_size) when tile_size >= 36, do: 20
  defp circle_size(_), do: 16

  defp unit_circle_classes(team, true = _is_dead) do
    case team do
      "red" -> "bg-slate-800 border-slate-700 text-slate-600"
      "blue" -> "bg-slate-800 border-slate-700 text-slate-600"
      _ -> "bg-slate-800 border-slate-700 text-slate-600"
    end
  end

  defp unit_circle_classes(team, false = _is_dead) do
    case team do
      "red" -> "bg-red-500 border-red-400 text-white shadow-[0_0_10px_rgba(239,68,68,0.5)] font-sans"
      "blue" -> "bg-cyan-500 border-cyan-400 text-white shadow-[0_0_10px_rgba(6,182,212,0.5)] font-sans"
      _ -> "bg-slate-500 border-slate-400 text-white font-sans"
    end
  end

  defp unit_icon_char("scout"), do: "S"
  defp unit_icon_char("soldier"), do: "+"
  defp unit_icon_char("heavy"), do: "H"
  defp unit_icon_char("sniper"), do: "T"
  defp unit_icon_char("medic"), do: "M"
  defp unit_icon_char(_), do: "+"

  defp unit_icon_class("scout"), do: "italic"
  defp unit_icon_class("heavy"), do: "font-black"
  defp unit_icon_class("medic"), do: "font-bold"
  defp unit_icon_class(_), do: "font-bold"

  defp class_label("scout"), do: "Scout"
  defp class_label("soldier"), do: "Soldier"
  defp class_label("heavy"), do: "Heavy"
  defp class_label("sniper"), do: "Sniper"
  defp class_label("medic"), do: "Medic"
  defp class_label(other) when is_binary(other), do: String.capitalize(other)
  defp class_label(_), do: "Unit"

  # ── HP/AP Rendering ───────────────────────────────────────────────

  defp hp_bar_color(%{data: unit}) do
    pct = hp_percent(%{data: unit})

    color =
      cond do
        pct > 60 -> "bg-emerald-500"
        pct > 30 -> "bg-amber-500"
        true -> "bg-red-500"
      end

    "h-full rounded-full transition-all #{color}"
  end

  defp hp_percent(%{data: unit}) do
    hp = get_val(unit, :hp, 0)
    max_hp = get_val(unit, :max_hp, 1)
    if max_hp > 0, do: round(hp / max_hp * 100), else: 0
  end

  # ── Interactive: Valid Moves ──────────────────────────────────────

  defp compute_valid_moves(unit_id, unit_data, unit_positions, wall_set, width, height) do
    pos = get_val(unit_data, :pos, %{})
    ux = get_val(pos, :x, 0)
    uy = get_val(pos, :y, 0)
    ap = get_val(unit_data, :ap, 0)

    if ap <= 0 do
      MapSet.new()
    else
      # Adjacent tiles (4-directional) that are not walls or occupied by other units
      [{0, -1}, {0, 1}, {-1, 0}, {1, 0}]
      |> Enum.map(fn {dx, dy} -> {ux + dx, uy + dy} end)
      |> Enum.filter(fn {nx, ny} ->
        nx >= 0 && ny >= 0 && nx < width && ny < height &&
          not MapSet.member?(wall_set, {nx, ny}) &&
          (is_nil(Map.get(unit_positions, {nx, ny})) ||
             Map.get(unit_positions, {nx, ny}).id == unit_id)
      end)
      |> MapSet.new()
    end
  end

  # ── Interactive: Attackable Targets ───────────────────────────────

  defp compute_attackable_targets(active_id, active_data, units) do
    active_pos = get_val(active_data, :pos, %{})
    ax = get_val(active_pos, :x, 0)
    ay = get_val(active_pos, :y, 0)
    attack_range = get_val(active_data, :attack_range, 2)
    active_team = get_val(active_data, :team, "")
    active_ap = get_val(active_data, :ap, 0)

    if active_ap <= 0 do
      []
    else
      units
      |> Enum.filter(fn {uid, u} ->
        uid != active_id &&
          get_val(u, :team, "") != active_team &&
          get_val(u, :status, "alive") != "dead"
      end)
      |> Enum.filter(fn {_uid, u} ->
        pos = get_val(u, :pos, %{})
        tx = get_val(pos, :x, 0)
        ty = get_val(pos, :y, 0)
        abs(tx - ax) + abs(ty - ay) <= attack_range
      end)
      |> Enum.map(fn {uid, _u} -> uid end)
      |> Enum.sort()
    end
  end

  # ── Status Bar Helpers ────────────────────────────────────────────

  defp active_actor_badge(actor_id, units) do
    unit = if actor_id, do: Map.get(units, actor_id), else: nil

    if unit do
      case get_val(unit, :team, "") do
        "red" -> "bg-red-500/20 text-red-400 border border-red-500/40 shadow-[0_0_8px_rgba(239,68,68,0.3)]"
        "blue" -> "bg-cyan-500/20 text-cyan-400 border border-cyan-500/40 shadow-[0_0_8px_rgba(6,182,212,0.3)]"
        _ -> "bg-slate-700/50 text-slate-400 border border-slate-600"
      end
    else
      "bg-slate-700/50 text-slate-400 border border-slate-600"
    end
  end

  defp format_unit_label(nil, _units), do: "--"

  defp format_unit_label(actor_id, units) do
    unit = Map.get(units, actor_id)

    if unit do
      class = get_val(unit, :class, "")
      "#{actor_id} (#{class_label(class)})"
    else
      actor_id
    end
  end

  # ── Roster Card Helpers ───────────────────────────────────────────

  defp roster_active_border("red"), do: "border-red-500/50 bg-red-950/30 ring-1 ring-red-500/20"
  defp roster_active_border("blue"), do: "border-blue-500/50 bg-blue-950/30 ring-1 ring-blue-500/20"
  defp roster_active_border(_), do: "border-gray-600 bg-gray-800/40"

  defp roster_icon_classes("red", false), do: "bg-red-500/80 border-red-400 text-white"
  defp roster_icon_classes("blue", false), do: "bg-blue-500/80 border-blue-400 text-white"
  defp roster_icon_classes(_, false), do: "bg-gray-500/80 border-gray-400 text-white"
  defp roster_icon_classes(_, true), do: "bg-gray-700 border-gray-600 text-gray-500"

  # ── Kill Feed Helpers ─────────────────────────────────────────────

  defp feed_entry_classes(entry) do
    case get_val(entry, :type, "hit") do
      "kill" -> "bg-red-950/40 text-red-400 border-red-500 border-l-4"
      "hit" -> "bg-amber-950/30 text-amber-400 border-amber-500/50 border-l-2"
      "miss" -> "bg-slate-800/30 text-slate-400 border-slate-600/30 border-l"
      "heal" -> "bg-emerald-950/30 text-emerald-400 border-emerald-500 border-l-2"
      _ -> "bg-slate-800/30 text-slate-400 border-slate-600/30 border-l"
    end
  end

  # ── Victory Screen Helpers ────────────────────────────────────────

  defp count_alive_units(units, team) do
    units
    |> Enum.count(fn {_id, u} ->
      get_val(u, :team, "") == team && get_val(u, :status, "alive") != "dead"
    end)
  end

  defp count_kills(units, winning_team) do
    losing_team = if winning_team == "red", do: "blue", else: "red"

    units
    |> Enum.count(fn {_id, u} ->
      get_val(u, :team, "") == losing_team && get_val(u, :status, "alive") == "dead"
    end)
  end

  # ── Flexible Key Access ───────────────────────────────────────────

  defp get_coord(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), 0))
  end

  defp get_coord(_, _), do: 0

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_, _, default), do: default
end
