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
    units = MapHelpers.get_key(world, :units) || %{}
    active_actor = MapHelpers.get_key(world, :active_actor_id)
    round = MapHelpers.get_key(world, :round) || 1
    phase = MapHelpers.get_key(world, :phase) || "main"
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)

    # Build position lookup for units
    unit_positions = build_unit_positions(units)

    # Build cover set
    cover_set = MapSet.new(cover_tiles, fn c -> {get_coord(c, :x), get_coord(c, :y)} end)

    # Build visibility sets for both teams
    red_visible = visible_tiles_for_team(units, "red", width, height)
    blue_visible = visible_tiles_for_team(units, "blue", width, height)

    assigns =
      assigns
      |> assign(:width, width)
      |> assign(:height, height)
      |> assign(:cover_set, cover_set)
      |> assign(:unit_positions, unit_positions)
      |> assign(:units, units)
      |> assign(:active_actor, active_actor)
      |> assign(:round, round)
      |> assign(:phase, phase)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:red_visible, red_visible)
      |> assign(:blue_visible, blue_visible)

    ~H"""
    <div class="flex flex-col items-center gap-4">
      <div class="text-center">
        <div :if={@game_status == "in_progress"} class="flex items-center gap-3 text-sm">
          <span class="text-gray-400">Round {@round}</span>
          <span class="text-gray-600">|</span>
          <span class="text-gray-400">Phase: {@phase}</span>
          <span class="text-gray-600">|</span>
          <span class={actor_color(@active_actor, @units)}>
            {@active_actor}
          </span>
        </div>
        <div :if={@game_status == "won"} class="text-lg font-semibold">
          <span class={team_color(@winner)}>{@winner}</span> wins!
        </div>
      </div>

      <div class="relative">
        <!-- Grid -->
        <div
          class="grid gap-0.5 bg-gray-800 p-1 rounded-xl"
          style={"grid-template-columns: repeat(#{@width}, 1fr)"}
        >
          <%= for y <- 0..(@height - 1) do %>
            <%= for x <- 0..(@width - 1) do %>
              <% is_cover = MapSet.member?(@cover_set, {x, y}) %>
              <% unit_here = Map.get(@unit_positions, {x, y}) %>
              <% in_red_fog = not MapSet.member?(@red_visible, {x, y}) %>
              <% in_blue_fog = not MapSet.member?(@blue_visible, {x, y}) %>
              <div
                class={[
                  "w-16 h-16 rounded-md relative flex items-center justify-center transition-all",
                  tile_bg(is_cover, unit_here),
                  if(@interactive && is_nil(unit_here) && @game_status == "in_progress",
                    do: "cursor-pointer hover:ring-1 hover:ring-blue-500",
                    else: "")
                ]}
                phx-click={if @interactive && is_nil(unit_here) && @game_status == "in_progress", do: "human_move_to"}
                phx-value-x={x}
                phx-value-y={y}
              >
                <!-- Cover indicator -->
                <div :if={is_cover} class="absolute top-0.5 right-0.5 text-[8px] text-gray-500">
                  &#x25A8;
                </div>

                <!-- Fog overlays -->
                <div :if={in_red_fog} class="absolute inset-0 rounded-md border border-red-900/30 bg-red-950/20 pointer-events-none"></div>
                <div :if={in_blue_fog} class="absolute inset-0 rounded-md border border-blue-900/30 bg-blue-950/20 pointer-events-none"></div>
                <div :if={in_red_fog && in_blue_fog} class="absolute inset-0 rounded-md fog-overlay pointer-events-none"></div>

                <!-- Unit -->
                <div :if={unit_here} class={[
                  "flex flex-col items-center gap-0.5",
                  if(unit_here.id == @active_actor, do: "active-unit", else: "")
                ]}>
                  <div class={[
                    "w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold border-2",
                    unit_style(unit_here)
                  ]}>
                    {unit_icon(unit_here)}
                  </div>
                  <!-- HP bar -->
                  <div class="w-10 h-1.5 bg-gray-700 rounded-full overflow-hidden">
                    <div
                      class={hp_bar_color(unit_here)}
                      style={"width: #{hp_percent(unit_here)}%"}
                    ></div>
                  </div>
                  <!-- AP dots -->
                  <div class="flex gap-0.5">
                    <%= for i <- 1..(get_val(unit_here.data, :max_ap, 2)) do %>
                      <div class={[
                        "w-1.5 h-1.5 rounded-full",
                        if(i <= get_val(unit_here.data, :ap, 0), do: "bg-yellow-400", else: "bg-gray-600")
                      ]}></div>
                    <% end %>
                  </div>
                </div>

                <!-- Coordinates -->
                <div class="absolute bottom-0.5 left-0.5 text-[7px] text-gray-600">
                  {x},{y}
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <!-- Legend -->
      <div class="flex gap-4 text-xs text-gray-500">
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 rounded-full bg-red-500/80 border border-red-400"></div> Red team
        </div>
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 rounded-full bg-blue-500/80 border border-blue-400"></div> Blue team
        </div>
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 bg-gray-600 rounded"></div> Cover
        </div>
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 bg-red-950/40 border border-red-900/30 rounded"></div> Red fog
        </div>
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 bg-blue-950/40 border border-blue-900/30 rounded"></div> Blue fog
        </div>
      </div>

      <!-- Unit stats table -->
      <div class="w-full max-w-lg">
        <table class="w-full text-xs text-gray-400">
          <thead>
            <tr class="border-b border-gray-800">
              <th class="py-1 text-left font-medium">Unit</th>
              <th class="py-1 text-left font-medium">Team</th>
              <th class="py-1 text-left font-medium">HP</th>
              <th class="py-1 text-left font-medium">AP</th>
              <th class="py-1 text-left font-medium">Pos</th>
              <th class="py-1 text-left font-medium">Status</th>
            </tr>
          </thead>
          <tbody>
            <%= for {unit_id, unit} <- Enum.sort(@units) do %>
              <tr class={[
                "border-b border-gray-800/50",
                if(unit_id == @active_actor, do: "text-white", else: "")
              ]}>
                <td class="py-1 font-mono">{unit_id}</td>
                <td class={["py-1", team_color(get_val(unit, :team, ""))]}>{get_val(unit, :team, "?")}</td>
                <td class="py-1">{get_val(unit, :hp, 0)}/{get_val(unit, :max_hp, 0)}</td>
                <td class="py-1">{get_val(unit, :ap, 0)}/{get_val(unit, :max_ap, 0)}</td>
                <td class="py-1">
                  <% pos = get_val(unit, :pos, %{}) %>
                  ({get_val(pos, :x, "?")},{get_val(pos, :y, "?")})
                </td>
                <td class={["py-1", status_color_unit(get_val(unit, :status, "alive"))]}>{get_val(unit, :status, "alive")}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <!-- Interactive controls -->
      <div :if={@interactive && @game_status == "in_progress"} class="flex gap-2">
        <button
          phx-click="human_action"
          phx-value-action="end_turn"
          class="px-3 py-1.5 text-xs rounded-lg bg-gray-700 text-gray-300 hover:bg-gray-600 transition"
        >
          End Turn
        </button>
        <button
          phx-click="human_action"
          phx-value-action="take_cover"
          class="px-3 py-1.5 text-xs rounded-lg bg-gray-700 text-gray-300 hover:bg-gray-600 transition"
        >
          Take Cover
        </button>
      </div>
    </div>
    """
  end

  defp build_unit_positions(units) do
    Enum.reduce(units, %{}, fn {unit_id, unit}, acc ->
      pos = get_val(unit, :pos, %{})
      x = get_val(pos, :x, nil)
      y = get_val(pos, :y, nil)

      if x && y && get_val(unit, :status, "alive") != "dead" do
        Map.put(acc, {x, y}, %{id: unit_id, data: unit})
      else
        acc
      end
    end)
  end

  defp visible_tiles_for_team(units, team, width, height) do
    # Simple visibility: tiles within attack_range + 1 of alive team units
    units
    |> Enum.filter(fn {_id, u} ->
      get_val(u, :team, "") == team && get_val(u, :status, "alive") != "dead"
    end)
    |> Enum.flat_map(fn {_id, u} ->
      pos = get_val(u, :pos, %{})
      ux = get_val(pos, :x, 0)
      uy = get_val(pos, :y, 0)
      range = get_val(u, :attack_range, 2) + 1

      for x <- max(0, ux - range)..min(width - 1, ux + range),
          y <- max(0, uy - range)..min(height - 1, uy + range),
          abs(x - ux) + abs(y - uy) <= range do
        {x, y}
      end
    end)
    |> MapSet.new()
  end

  defp tile_bg(true, _), do: "bg-gray-700"
  defp tile_bg(_, _), do: "bg-gray-900"

  defp unit_style(%{data: unit}) do
    team = get_val(unit, :team, "")
    status = get_val(unit, :status, "alive")

    if status == "dead" do
      "bg-gray-700 border-gray-600 opacity-50"
    else
      case team do
        "red" -> "bg-red-500/80 border-red-400 text-white"
        "blue" -> "bg-blue-500/80 border-blue-400 text-white"
        _ -> "bg-gray-500/80 border-gray-400 text-white"
      end
    end
  end

  defp unit_icon(%{data: unit}) do
    if get_val(unit, :cover?, false), do: "\u{1F6E1}", else: "\u{2694}"
  end

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

  defp actor_color(actor_id, units) do
    unit = Map.get(units, actor_id)

    if unit do
      team_color(get_val(unit, :team, ""))
    else
      "text-gray-400"
    end
  end

  defp team_color("red"), do: "text-red-400"
  defp team_color("blue"), do: "text-blue-400"
  defp team_color(_), do: "text-gray-400"

  defp status_color_unit("alive"), do: "text-emerald-400"
  defp status_color_unit("dead"), do: "text-red-400"
  defp status_color_unit(_), do: "text-gray-400"

  defp get_coord(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), 0))
  end

  defp get_coord(_, _), do: 0

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_, _, default), do: default
end
