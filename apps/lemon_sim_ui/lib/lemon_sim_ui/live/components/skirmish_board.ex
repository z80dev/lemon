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
    <div class="relative">
      <%!-- Inline styles for animations and patterns --%>
      <style>
        @keyframes pulse-glow-red {
          0%, 100% { box-shadow: 0 0 4px 1px rgba(239, 68, 68, 0.4); }
          50% { box-shadow: 0 0 12px 4px rgba(239, 68, 68, 0.7); }
        }
        @keyframes pulse-glow-blue {
          0%, 100% { box-shadow: 0 0 4px 1px rgba(59, 130, 246, 0.4); }
          50% { box-shadow: 0 0 12px 4px rgba(59, 130, 246, 0.7); }
        }
        .active-unit-red { animation: pulse-glow-red 2s ease-in-out infinite; }
        .active-unit-blue { animation: pulse-glow-blue 2s ease-in-out infinite; }
        @keyframes slide-in-right {
          from { transform: translateX(40px); opacity: 0; }
          to { transform: translateX(0); opacity: 1; }
        }
        .kill-feed-enter { animation: slide-in-right 0.3s ease-out; }
        @keyframes victory-pulse {
          0%, 100% { transform: scale(1); }
          50% { transform: scale(1.02); }
        }
        .victory-banner { animation: victory-pulse 2s ease-in-out infinite; }
        .wall-pattern {
          background-image: repeating-linear-gradient(
            45deg,
            transparent,
            transparent 3px,
            rgba(107, 114, 128, 0.3) 3px,
            rgba(107, 114, 128, 0.3) 6px
          );
        }
        .water-pattern {
          background-image: repeating-linear-gradient(
            180deg,
            transparent,
            transparent 4px,
            rgba(96, 165, 250, 0.08) 4px,
            rgba(96, 165, 250, 0.08) 6px
          );
        }
        @keyframes valid-move-pulse {
          0%, 100% { background-color: rgba(34, 197, 94, 0.12); }
          50% { background-color: rgba(34, 197, 94, 0.25); }
        }
        .valid-move-tile { animation: valid-move-pulse 1.5s ease-in-out infinite; }
      </style>

      <%!-- Status Bar --%>
      <div class="mb-3 px-3 py-2 rounded-lg bg-gray-800/80 border border-gray-700/50">
        <div :if={@game_status == "in_progress"} class="flex items-center justify-between text-sm">
          <div class="flex items-center gap-3">
            <span class="text-gray-500 font-mono text-xs tracking-wider uppercase">Round</span>
            <span class="text-white font-bold tabular-nums">{@round}</span>
            <span class="w-px h-4 bg-gray-700"></span>
            <span class="text-gray-500 font-mono text-xs tracking-wider uppercase">Phase</span>
            <span class="text-gray-300">{@phase}</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-gray-500 text-xs">Active:</span>
            <span class={[
              "px-2 py-0.5 rounded text-xs font-bold",
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
        <div class="w-48 flex-shrink-0 space-y-1.5">
          <div class="flex items-center gap-2 px-2 py-1.5 rounded-t-lg bg-red-950/40 border border-red-900/30">
            <div class="w-2 h-2 rounded-full bg-red-500"></div>
            <span class="text-red-400 text-xs font-bold tracking-wider uppercase">Red Team</span>
          </div>
          <%= for {unit_id, unit} <- @red_units do %>
            <.roster_card
              unit_id={unit_id}
              unit={unit}
              active={unit_id == @active_actor}
              team="red"
            />
          <% end %>
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
                class="grid gap-px bg-gray-800 rounded-lg overflow-hidden border border-gray-700/50 shadow-xl shadow-black/40"
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
                        "relative flex items-center justify-center transition-colors duration-150",
                        terrain_bg(terrain),
                        if(terrain == :wall, do: "wall-pattern", else: ""),
                        if(terrain == :water, do: "water-pattern", else: ""),
                        if(is_valid_move && is_nil(unit_here), do: "valid-move-tile ring-1 ring-inset ring-green-500/40", else: ""),
                        if(clickable, do: "cursor-pointer hover:ring-2 hover:ring-green-400/60", else: "")
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
                        <span class="text-gray-600 font-bold" style={"font-size: #{max(10, @tile_size - 26)}px"}>&#x2588;</span>
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
                              "rounded-full flex items-center justify-center font-bold border-2 relative",
                              unit_circle_classes(team, is_dead),
                              if(is_active && !is_dead, do: "active-unit-#{team}", else: ""),
                              if(is_active && !is_dead, do: "ring-2 ring-offset-1 ring-offset-gray-900 ring-yellow-400/80", else: "")
                            ]}
                            style={"width: #{circle_size(@tile_size)}px; height: #{circle_size(@tile_size)}px; font-size: #{max(8, circle_size(@tile_size) - 10)}px; line-height: 1"}
                          >
                            <span :if={!is_dead} class={unit_icon_class(get_val(u, :class, "soldier"))}>
                              {unit_icon_char(get_val(u, :class, "soldier"))}
                            </span>
                            <span :if={is_dead} class="text-gray-400">X</span>

                            <%!-- Cover shield indicator --%>
                            <div
                              :if={has_cover && !is_dead}
                              class="absolute -top-1 -right-1 w-3 h-3 rounded-full bg-gray-800 border border-green-500/60 flex items-center justify-center"
                            >
                              <span class="text-green-400 text-[6px] font-bold leading-none">S</span>
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
          <div :if={@interactive && @game_status == "in_progress" && @active_unit_data} class="mt-3 w-full">
            <div class="bg-gray-800/60 rounded-lg border border-gray-700/40 p-3">
              <div class="text-[10px] text-gray-500 uppercase tracking-wider font-bold mb-2">Actions</div>
              <div class="flex flex-wrap gap-2">
                <%!-- End Turn --%>
                <button
                  phx-click="human_action"
                  phx-value-action="end_turn"
                  class="px-3 py-1.5 text-xs rounded-md bg-gray-700 text-gray-300 hover:bg-gray-600 hover:text-white transition-all border border-gray-600/50 shadow-sm"
                >
                  End Turn
                </button>

                <%!-- Take Cover --%>
                <button
                  phx-click="human_action"
                  phx-value-action="take_cover"
                  class="px-3 py-1.5 text-xs rounded-md bg-emerald-900/40 text-emerald-400 hover:bg-emerald-800/50 hover:text-emerald-300 transition-all border border-emerald-700/30 shadow-sm"
                >
                  Take Cover
                </button>

                <%!-- Heal (medic only, when adjacent ally wounded) --%>
                <button
                  :if={get_val(@active_unit_data, :class, "") == "medic"}
                  phx-click="human_action"
                  phx-value-action="heal"
                  class="px-3 py-1.5 text-xs rounded-md bg-green-900/40 text-green-400 hover:bg-green-800/50 hover:text-green-300 transition-all border border-green-700/30 shadow-sm"
                >
                  Heal Ally
                </button>

                <%!-- Sprint (scout only) --%>
                <button
                  :if={get_val(@active_unit_data, :class, "") == "scout"}
                  phx-click="human_action"
                  phx-value-action="sprint"
                  class="px-3 py-1.5 text-xs rounded-md bg-cyan-900/40 text-cyan-400 hover:bg-cyan-800/50 hover:text-cyan-300 transition-all border border-cyan-700/30 shadow-sm"
                >
                  Sprint
                </button>

                <%!-- Attack buttons for each target in range --%>
                <%= for target_id <- @attackable_targets do %>
                  <% target_unit = Map.get(@units, target_id) %>
                  <button
                    phx-click="human_attack"
                    phx-value-target={target_id}
                    class="px-3 py-1.5 text-xs rounded-md bg-red-900/40 text-red-400 hover:bg-red-800/50 hover:text-red-300 transition-all border border-red-700/30 shadow-sm"
                  >
                    Attack {target_id}
                    <span :if={target_unit} class="text-gray-500 ml-1">
                      ({class_label(get_val(target_unit, :class, ""))})
                    </span>
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Right Panel: Blue Team Roster + Kill Feed --%>
        <div class="w-48 flex-shrink-0 flex flex-col gap-4">
          <%!-- Blue Team Roster --%>
          <div class="space-y-1.5">
            <div class="flex items-center gap-2 px-2 py-1.5 rounded-t-lg bg-blue-950/40 border border-blue-900/30">
              <div class="w-2 h-2 rounded-full bg-blue-500"></div>
              <span class="text-blue-400 text-xs font-bold tracking-wider uppercase">Blue Team</span>
            </div>
            <%= for {unit_id, unit} <- @blue_units do %>
              <.roster_card
                unit_id={unit_id}
                unit={unit}
                active={unit_id == @active_actor}
                team="blue"
              />
            <% end %>
          </div>

          <%!-- Kill Feed --%>
          <div :if={@recent_feed != []} class="space-y-1">
            <div class="flex items-center gap-2 px-2 py-1.5 rounded-t-lg bg-gray-800/60 border border-gray-700/30">
              <span class="text-gray-500 text-[10px] font-bold tracking-wider uppercase">Combat Log</span>
            </div>
            <div class="space-y-0.5 max-h-64 overflow-y-auto">
              <%= for entry <- @recent_feed do %>
                <div class={[
                  "px-2 py-1 rounded text-[10px] leading-snug kill-feed-enter border-l-2",
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
        class="absolute inset-0 z-50 flex items-center justify-center bg-black/70 rounded-lg backdrop-blur-sm"
      >
        <div class="text-center p-8 space-y-4 victory-banner">
          <div class={[
            "text-4xl font-black tracking-tight",
            if(@winner == "red", do: "text-red-400", else: "text-blue-400")
          ]}>
            {String.upcase(@winner || "")} TEAM WINS!
          </div>
          <div class="flex justify-center gap-8 text-sm text-gray-400">
            <div class="text-center">
              <div class="text-2xl font-bold text-white">{count_alive_units(@units, @winner)}</div>
              <div class="text-[10px] uppercase tracking-wider text-gray-500">Units Remaining</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-white">{@round}</div>
              <div class="text-[10px] uppercase tracking-wider text-gray-500">Rounds Lasted</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-white">{count_kills(@units, @winner)}</div>
              <div class="text-[10px] uppercase tracking-wider text-gray-500">Enemy Eliminated</div>
            </div>
          </div>
          <div class={[
            "w-full h-1 rounded-full mt-4",
            if(@winner == "red", do: "bg-gradient-to-r from-transparent via-red-500 to-transparent", else: "bg-gradient-to-r from-transparent via-blue-500 to-transparent")
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
      "px-2 py-1.5 rounded-md border transition-all text-xs",
      if(@is_dead, do: "opacity-40 border-gray-800 bg-gray-900/40", else: ""),
      if(@active && !@is_dead, do: roster_active_border(@team), else: ""),
      if(!@active && !@is_dead, do: "border-gray-800/50 bg-gray-900/30", else: "")
    ]}>
      <div class="flex items-center gap-1.5">
        <%!-- Class icon --%>
        <div class={[
          "w-5 h-5 rounded-full flex items-center justify-center text-[9px] font-bold border",
          roster_icon_classes(@team, @is_dead)
        ]}>
          <span :if={!@is_dead} class={unit_icon_class(@unit_class)}>
            {unit_icon_char(@unit_class)}
          </span>
          <span :if={@is_dead} class="text-gray-500">X</span>
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between">
            <span class={[
              "font-mono text-[10px] truncate",
              if(@is_dead, do: "text-gray-600 line-through", else: "text-gray-300")
            ]}>
              {@unit_id}
            </span>
            <span class={[
              "text-[9px] ml-1",
              if(@is_dead, do: "text-gray-600", else: "text-gray-500")
            ]}>
              {class_label(@unit_class)}
            </span>
          </div>
          <%!-- HP bar --%>
          <div :if={!@is_dead} class="w-full h-1.5 bg-gray-700/60 rounded-full overflow-hidden mt-0.5">
            <div
              class={[
                "h-full rounded-full transition-all",
                cond do
                  @hp_pct > 60 -> "bg-emerald-500"
                  @hp_pct > 30 -> "bg-amber-500"
                  true -> "bg-red-500"
                end
              ]}
              style={"width: #{@hp_pct}%"}
            ></div>
          </div>
          <%!-- Stats row --%>
          <div :if={!@is_dead} class="flex items-center justify-between mt-0.5">
            <span class="text-[9px] text-gray-500">{@hp}/{@max_hp} HP</span>
            <div class="flex gap-px">
              <%= for i <- 1..@max_ap do %>
                <div class={[
                  "w-1.5 h-1.5 rounded-full",
                  if(i <= @ap, do: "bg-yellow-400", else: "bg-gray-600/50")
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

  defp terrain_bg(:empty), do: "bg-gray-900"
  defp terrain_bg(:cover), do: "bg-gray-850 bg-gray-800/70 border border-gray-700/30"
  defp terrain_bg(:wall), do: "bg-gray-700"
  defp terrain_bg(:water), do: "bg-blue-950/60"
  defp terrain_bg(:high_ground), do: "bg-amber-950/30 border border-amber-800/20"

  # ── Unit Visuals ──────────────────────────────────────────────────

  defp circle_size(tile_size) when tile_size >= 48, do: 26
  defp circle_size(tile_size) when tile_size >= 36, do: 20
  defp circle_size(_), do: 16

  defp unit_circle_classes(team, true = _is_dead) do
    case team do
      "red" -> "bg-gray-700 border-gray-600 text-gray-400"
      "blue" -> "bg-gray-700 border-gray-600 text-gray-400"
      _ -> "bg-gray-700 border-gray-600 text-gray-400"
    end
  end

  defp unit_circle_classes(team, false = _is_dead) do
    case team do
      "red" -> "bg-red-500/90 border-red-400 text-white shadow-sm shadow-red-500/30"
      "blue" -> "bg-blue-500/90 border-blue-400 text-white shadow-sm shadow-blue-500/30"
      _ -> "bg-gray-500/90 border-gray-400 text-white"
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
        "red" -> "bg-red-500/20 text-red-400 border border-red-500/30"
        "blue" -> "bg-blue-500/20 text-blue-400 border border-blue-500/30"
        _ -> "bg-gray-700 text-gray-400 border border-gray-600"
      end
    else
      "bg-gray-700 text-gray-400 border border-gray-600"
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
      "kill" -> "bg-red-950/30 text-red-400 border-red-500/50"
      "hit" -> "bg-amber-950/20 text-amber-400/80 border-amber-500/40"
      "miss" -> "bg-gray-800/30 text-gray-500 border-gray-600/30"
      "heal" -> "bg-green-950/20 text-green-400/80 border-green-500/40"
      _ -> "bg-gray-800/30 text-gray-400 border-gray-600/30"
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
