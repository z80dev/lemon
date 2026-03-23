defmodule LemonSim.Examples.Skirmish.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (dark theme)
  # ---------------------------------------------------------------------------
  @bg "#0f0f1a"
  @grid_bg "#1a1a2e"
  @grid_line "#252540"
  @tile_empty "#16213e"
  @tile_cover "#2c3e50"
  @tile_wall "#34495e"
  @tile_water "#1a3a5c"
  @tile_high "#3d3520"

  @red "#e74c3c"
  @red_dark "#c0392b"
  @red_light "#fadbd8"
  @blue "#3498db"
  @blue_dark "#2980b9"
  @blue_light "#d4e6f1"

  @text_primary "#ecf0f1"
  @text_secondary "#95a5a6"

  @hp_green "#2ecc71"
  @hp_amber "#f39c12"
  @hp_red "#e74c3c"

  @ap_filled "#f1c40f"
  @ap_empty "#34495e"

  @header_bg "#16213e"
  @event_bg "#16213e"

  # Layout constants
  @header_h 60
  @event_h 80
  @roster_w 180

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Renders a single game log entry as a self-contained SVG string.

  `entry` is a map with string keys: "world", "step", "round", "active_actor",
  "events" (as produced by `GameLog` and decoded from JSON).

  Options:
    * `:width`  - SVG width in pixels (default 1920)
    * `:height` - SVG height in pixels (default 1080)
  """
  @spec render_frame(map(), keyword()) :: String.t()
  def render_frame(entry, opts \\ []) do
    w = Keyword.get(opts, :width, 1920)
    h = Keyword.get(opts, :height, 1080)

    world = get(entry, "world", %{})
    step = get(entry, "step", 0)
    round = get(entry, "round", 0)
    active_actor = get(entry, "active_actor", nil)
    events = get(entry, "events", [])

    map_data = get(world, "map", %{})
    units = get(world, "units", %{})
    grid_w = get(map_data, "width", 10)
    grid_h = get(map_data, "height", 10)

    # Available area for the grid (between roster panels, below header, above event bar)
    avail_w = w - @roster_w * 2
    avail_h = h - @header_h - @event_h

    tile_size = min(div(avail_w - grid_w - 40, grid_w), div(avail_h - grid_h - 40, grid_h))
    tile_size = max(tile_size, 10)

    total_grid_w = grid_w * (tile_size + 1) - 1
    total_grid_h = grid_h * (tile_size + 1) - 1

    grid_x = @roster_w + div(avail_w - total_grid_w, 2)
    grid_y = @header_h + div(avail_h - total_grid_h, 2)

    ctx = %{
      w: w,
      h: h,
      world: world,
      map: map_data,
      units: units,
      step: step,
      round: round,
      active_actor: active_actor,
      events: events,
      grid_w: grid_w,
      grid_h: grid_h,
      tile_size: tile_size,
      grid_x: grid_x,
      grid_y: grid_y,
      total_grid_w: total_grid_w,
      total_grid_h: total_grid_h
    }

    svg_content =
      [
        svg_header(ctx),
        svg_style(),
        render_background(ctx),
        render_header_bar(ctx),
        render_grid(ctx),
        render_units_on_grid(ctx),
        render_action_indicators(ctx),
        render_roster(:red, ctx),
        render_roster(:blue, ctx),
        render_event_bar(ctx),
        "</svg>"
      ]
      |> IO.iodata_to_binary()

    svg_content
  end

  @doc """
  Renders a frame and writes it to the given file path.
  """
  @spec render_frame_to_file(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def render_frame_to_file(entry, path, opts \\ []) do
    svg = render_frame(entry, opts)
    File.write(path, svg)
  end

  # ---------------------------------------------------------------------------
  # SVG skeleton
  # ---------------------------------------------------------------------------

  defp svg_header(%{w: w, h: h}) do
    ~s[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" ] <>
      ~s[width="#{w}" height="#{h}">\n]
  end

  defp svg_style do
    ~s"""
    <style>
      text { font-family: 'Courier New', Courier, monospace; }
      .title { font-family: sans-serif; font-weight: 700; }
      .label { font-family: sans-serif; font-size: 11px; fill: #{@text_secondary}; }
      .unit-letter { font-family: sans-serif; font-weight: 700; fill: white; }
      .header-text { font-family: sans-serif; fill: #{@text_primary}; }
      .event-text { font-family: sans-serif; fill: #{@text_primary}; }
      .roster-name { font-family: sans-serif; font-size: 12px; }
      .coord-label { font-family: monospace; font-size: 10px; fill: #{@text_secondary}; }
    </style>
    """
  end

  # ---------------------------------------------------------------------------
  # Background
  # ---------------------------------------------------------------------------

  defp render_background(%{w: w, h: h}) do
    ~s[<rect width="#{w}" height="#{h}" fill="#{@bg}"/>\n]
  end

  # ---------------------------------------------------------------------------
  # Header bar
  # ---------------------------------------------------------------------------

  defp render_header_bar(%{w: w, round: round, step: step, active_actor: actor, units: units}) do
    actor_str = to_string(actor || "---")

    unit_info =
      case Map.get(units, actor_str) do
        nil -> actor_str
        unit -> "#{actor_str} (#{class_display(get(unit, "class", ""))})"
      end

    team = actor_team(units, actor_str)
    team_color = team_color(team)

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@header_bg}"/>\n],
      ~s[<text x="20" y="38" class="header-text" font-size="14" ] <>
        ~s[letter-spacing="2" fill="#{@text_secondary}">LEMON SKIRMISH</text>\n],
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="20" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">],
      ~s[Round #{round} &#xB7; Step #{step}],
      ~s[</text>\n],
      ~s[<text x="#{w - 20}" y="38" class="header-text" font-size="16" ] <>
        ~s[text-anchor="end" fill="#{team_color}">#{esc(unit_info)}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Grid
  # ---------------------------------------------------------------------------

  defp render_grid(ctx) do
    %{
      grid_x: gx,
      grid_y: gy,
      total_grid_w: tw,
      total_grid_h: th,
      grid_w: cols,
      grid_h: rows,
      tile_size: ts,
      map: map_data
    } = ctx

    cover_set = pos_set(get(map_data, "cover", []))
    wall_set = pos_set(get(map_data, "walls", []))
    water_set = pos_set(get(map_data, "water", []))
    high_set = pos_set(get(map_data, "high_ground", []))

    grid_bg =
      ~s[<rect x="#{gx - 2}" y="#{gy - 2}" width="#{tw + 4}" ] <>
        ~s[height="#{th + 4}" fill="#{@grid_bg}" rx="3"/>\n]

    coord_labels_x =
      for col <- 0..(cols - 1) do
        cx = gx + col * (ts + 1) + div(ts, 2)
        ~s[<text x="#{cx}" y="#{gy - 6}" class="coord-label" text-anchor="middle">#{col}</text>\n]
      end

    coord_labels_y =
      for row <- 0..(rows - 1) do
        cy = gy + row * (ts + 1) + div(ts, 2) + 4
        ~s[<text x="#{gx - 8}" y="#{cy}" class="coord-label" text-anchor="end">#{row}</text>\n]
      end

    tiles =
      for row <- 0..(rows - 1), col <- 0..(cols - 1) do
        tx = gx + col * (ts + 1)
        ty = gy + row * (ts + 1)
        key = {col, row}

        cond do
          MapSet.member?(wall_set, key) -> render_wall_tile(tx, ty, ts)
          MapSet.member?(water_set, key) -> render_water_tile(tx, ty, ts)
          MapSet.member?(cover_set, key) -> render_cover_tile(tx, ty, ts)
          MapSet.member?(high_set, key) -> render_high_ground_tile(tx, ty, ts)
          true -> render_empty_tile(tx, ty, ts)
        end
      end

    grid_lines =
      [
        for col <- 1..(cols - 1) do
          lx = gx + col * (ts + 1) - 1

          ~s[<line x1="#{lx}" y1="#{gy}" x2="#{lx}" y2="#{gy + th}" ] <>
            ~s[stroke="#{@grid_line}" stroke-width="1"/>\n]
        end,
        for row <- 1..(rows - 1) do
          ly = gy + row * (ts + 1) - 1

          ~s[<line x1="#{gx}" y1="#{ly}" x2="#{gx + tw}" y2="#{ly}" ] <>
            ~s[stroke="#{@grid_line}" stroke-width="1"/>\n]
        end
      ]

    [grid_bg, coord_labels_x, coord_labels_y, tiles, grid_lines]
  end

  defp render_empty_tile(x, y, s) do
    ~s[<rect x="#{x}" y="#{y}" width="#{s}" height="#{s}" fill="#{@tile_empty}"/>\n]
  end

  defp render_cover_tile(x, y, s) do
    # Rock/barrier shape inside
    cx = x + div(s, 2)
    cy = y + div(s, 2)
    r = max(div(s, 5), 3)

    [
      ~s[<rect x="#{x}" y="#{y}" width="#{s}" height="#{s}" fill="#{@tile_cover}"/>\n],
      ~s[<circle cx="#{cx - r}" cy="#{cy + r}" r="#{r}" fill="#3d5166" opacity="0.7"/>\n],
      ~s[<circle cx="#{cx + div(r, 2)}" cy="#{cy}" r="#{max(r - 1, 2)}" fill="#3d5166" opacity="0.7"/>\n]
    ]
  end

  defp render_wall_tile(x, y, s) do
    # Diagonal line pattern
    [
      ~s[<rect x="#{x}" y="#{y}" width="#{s}" height="#{s}" fill="#{@tile_wall}"/>\n],
      ~s[<line x1="#{x}" y1="#{y + s}" x2="#{x + s}" y2="#{y}" ] <>
        ~s[stroke="#4a6274" stroke-width="1" opacity="0.5"/>\n],
      ~s[<line x1="#{x}" y1="#{y + div(s, 2)}" x2="#{x + div(s, 2)}" y2="#{y}" ] <>
        ~s[stroke="#4a6274" stroke-width="1" opacity="0.5"/>\n],
      ~s[<line x1="#{x + div(s, 2)}" y1="#{y + s}" x2="#{x + s}" y2="#{y + div(s, 2)}" ] <>
        ~s[stroke="#4a6274" stroke-width="1" opacity="0.5"/>\n]
    ]
  end

  defp render_water_tile(x, y, s) do
    # Wavy horizontal lines
    m = div(s, 4)

    [
      ~s[<rect x="#{x}" y="#{y}" width="#{s}" height="#{s}" fill="#{@tile_water}"/>\n],
      for i <- 1..3 do
        wy = y + i * m

        ~s[<path d="M#{x + 2},#{wy} Q#{x + div(s, 4)},#{wy - 3} #{x + div(s, 2)},#{wy} ] <>
          ~s[Q#{x + 3 * div(s, 4)},#{wy + 3} #{x + s - 2},#{wy}" ] <>
          ~s[stroke="#2a6a9c" stroke-width="1" fill="none" opacity="0.6"/>\n]
      end
    ]
  end

  defp render_high_ground_tile(x, y, s) do
    # Small up-arrow
    cx = x + div(s, 2)
    cy = y + div(s, 2)
    a = max(div(s, 6), 3)

    [
      ~s[<rect x="#{x}" y="#{y}" width="#{s}" height="#{s}" fill="#{@tile_high}"/>\n],
      ~s[<polygon points="#{cx},#{cy - a} #{cx - a},#{cy + a} #{cx + a},#{cy + a}" ] <>
        ~s[fill="#5a5030" opacity="0.7"/>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Units on the grid
  # ---------------------------------------------------------------------------

  defp render_units_on_grid(ctx) do
    %{units: units, tile_size: ts, grid_x: gx, grid_y: gy, active_actor: active} = ctx

    units
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {unit_id, unit} ->
      pos = get(unit, "pos", %{})
      ux = get(pos, "x", 0)
      uy = get(pos, "y", 0)

      tx = gx + ux * (ts + 1)
      ty = gy + uy * (ts + 1)
      cx = tx + div(ts, 2)
      cy = ty + div(ts, 2) - 4

      status = get(unit, "status", "alive")
      team = get(unit, "team", "red")
      class = get(unit, "class", "soldier")
      hp = get(unit, "hp", 0)
      max_hp = get(unit, "max_hp", 1)
      ap = get(unit, "ap", 0)
      max_ap = get(unit, "max_ap", 2)
      has_cover = get(unit, "cover?", false) || get(unit, "cover", false)
      is_active = to_string(active) == unit_id

      r = max(div(ts, 3), 8)

      if status == "dead" do
        render_dead_unit(cx, cy, r, ts, tx)
      else
        render_alive_unit(
          cx,
          cy,
          r,
          ts,
          tx,
          team,
          class,
          hp,
          max_hp,
          ap,
          max_ap,
          has_cover,
          is_active
        )
      end
    end)
  end

  defp render_dead_unit(cx, cy, r, ts, _tx) do
    [
      ~s[<g opacity="0.3">\n],
      ~s[<circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="#555" stroke="#444" stroke-width="2"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 5}" text-anchor="middle" class="unit-letter" ] <>
        ~s[font-size="#{max(div(ts, 4), 10)}">X</text>\n],
      ~s[</g>\n]
    ]
  end

  defp render_alive_unit(
         cx,
         cy,
         r,
         ts,
         tx,
         team,
         class,
         hp,
         max_hp,
         ap,
         max_ap,
         has_cover,
         is_active
       ) do
    fill = team_color(team)
    stroke = team_dark(team)
    light = team_light(team)
    letter = class_letter(class)

    hp_bar_w = max(ts - 12, 10)
    hp_bar_h = max(div(ts, 12), 3)
    hp_pct = if max_hp > 0, do: hp / max_hp, else: 0
    hp_color = hp_bar_color(hp_pct)
    hp_fill_w = round(hp_bar_w * hp_pct)

    hp_bar_x = tx + div(ts - hp_bar_w, 2)
    hp_bar_y = cy + r + 4

    ap_dot_r = max(div(ts, 16), 2)
    ap_total_w = max_ap * (ap_dot_r * 2 + 3) - 3
    ap_start_x = cx - div(ap_total_w, 2) + ap_dot_r
    ap_y = hp_bar_y + hp_bar_h + ap_dot_r + 3

    [
      # Active glow ring
      if is_active do
        ~s[<circle cx="#{cx}" cy="#{cy}" r="#{r + 3}" fill="none" ] <>
          ~s[stroke="#{light}" stroke-width="3" opacity="0.8"/>\n]
      else
        ""
      end,
      # Cover indicator
      if has_cover do
        ~s(<text x="#{cx}" y="#{cy - r - 3}" text-anchor="middle" ) <>
          ~s(font-size="#{max(div(ts, 6), 8)}" fill="#{@text_secondary}">[C]</text>\n)
      else
        ""
      end,
      # Unit circle
      ~s[<circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="#{fill}" ] <>
        ~s[stroke="#{stroke}" stroke-width="2"/>\n],
      # Class letter
      ~s[<text x="#{cx}" y="#{cy + max(div(ts, 8), 5)}" text-anchor="middle" ] <>
        ~s[class="unit-letter" font-size="#{max(div(ts, 4), 10)}">#{letter}</text>\n],
      # HP bar background
      ~s[<rect x="#{hp_bar_x}" y="#{hp_bar_y}" width="#{hp_bar_w}" height="#{hp_bar_h}" ] <>
        ~s[fill="#1a1a2e" rx="1"/>\n],
      # HP bar fill
      ~s[<rect x="#{hp_bar_x}" y="#{hp_bar_y}" width="#{hp_fill_w}" height="#{hp_bar_h}" ] <>
        ~s[fill="#{hp_color}" rx="1"/>\n],
      # AP dots
      for i <- 0..(max_ap - 1) do
        dot_cx = ap_start_x + i * (ap_dot_r * 2 + 3)
        dot_fill = if i < ap, do: @ap_filled, else: @ap_empty

        ~s[<circle cx="#{dot_cx}" cy="#{ap_y}" r="#{ap_dot_r}" fill="#{dot_fill}"/>\n]
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # Action indicators (attack lines, movement trails)
  # ---------------------------------------------------------------------------

  defp render_action_indicators(ctx) do
    %{events: events, units: units, tile_size: ts, grid_x: gx, grid_y: gy} = ctx

    events
    |> Enum.flat_map(fn event ->
      kind = get(event, "kind", get(event, "type", ""))
      payload = get(event, "payload", event)

      case kind do
        "attack_resolved" ->
          render_attack_indicator(payload, units, ts, gx, gy)

        "unit_moved" ->
          render_move_indicator(payload, ts, gx, gy)

        "unit_sprinted" ->
          render_move_indicator(payload, ts, gx, gy)

        _ ->
          []
      end
    end)
  end

  defp render_attack_indicator(payload, units, ts, gx, gy) do
    attacker_id = get(payload, "attacker_id", nil)
    target_id = get(payload, "target_id", nil)
    hit = get(payload, "hit", false)

    attacker_pos = unit_pos(units, attacker_id)
    target_pos = unit_pos(units, target_id)

    if attacker_pos && target_pos do
      ax = gx + get(attacker_pos, "x", 0) * (ts + 1) + div(ts, 2)
      ay = gy + get(attacker_pos, "y", 0) * (ts + 1) + div(ts, 2)
      tx_coord = gx + get(target_pos, "x", 0) * (ts + 1) + div(ts, 2)
      ty_coord = gy + get(target_pos, "y", 0) * (ts + 1) + div(ts, 2)

      if hit do
        [
          ~s[<line x1="#{ax}" y1="#{ay}" x2="#{tx_coord}" y2="#{ty_coord}" ] <>
            ~s[stroke="#e74c3c" stroke-width="2" opacity="0.7"/>\n],
          render_explosion(tx_coord, ty_coord, max(div(ts, 4), 6))
        ]
      else
        [
          ~s[<line x1="#{ax}" y1="#{ay}" x2="#{tx_coord}" y2="#{ty_coord}" ] <>
            ~s[stroke="#666" stroke-width="1" stroke-dasharray="4,4" opacity="0.5"/>\n]
        ]
      end
    else
      []
    end
  end

  defp render_explosion(cx, cy, r) do
    # Simple star/explosion shape
    points =
      for i <- 0..7 do
        angle = i * :math.pi() / 4
        outer = if rem(i, 2) == 0, do: r, else: r * 0.5
        px = round(cx + outer * :math.cos(angle))
        py = round(cy + outer * :math.sin(angle))
        "#{px},#{py}"
      end
      |> Enum.join(" ")

    ~s[<polygon points="#{points}" fill="#f39c12" opacity="0.8"/>\n]
  end

  defp render_move_indicator(payload, ts, gx, gy) do
    x = get(payload, "x", nil)
    y = get(payload, "y", nil)

    if x && y do
      tx = gx + x * (ts + 1) + div(ts, 2)
      ty = gy + y * (ts + 1) + div(ts, 2)
      r = max(div(ts, 3), 6)

      [
        ~s[<circle cx="#{tx}" cy="#{ty}" r="#{r + 5}" fill="none" ] <>
          ~s[stroke="#{@text_secondary}" stroke-width="1" ] <>
          ~s[stroke-dasharray="3,3" opacity="0.4"/>\n]
      ]
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Roster panels
  # ---------------------------------------------------------------------------

  defp render_roster(team, ctx) do
    %{w: w, h: h, units: units, active_actor: active} = ctx
    team_str = Atom.to_string(team)

    team_units =
      units
      |> Enum.filter(fn {_id, u} -> get(u, "team", "") == team_str end)
      |> Enum.sort_by(fn {id, _} -> id end)

    panel_x = if team == :red, do: 0, else: w - @roster_w
    panel_y = @header_h
    panel_h = h - @header_h - @event_h

    color = team_color(team_str)
    dark = team_dark(team_str)

    header_label = if team == :red, do: "RED TEAM", else: "BLUE TEAM"

    [
      # Panel background
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{@roster_w}" ] <>
        ~s[height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      # Team header
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{@roster_w}" height="28" ] <>
        ~s[fill="#{dark}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@roster_w, 2)}" y="#{panel_y + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{color}">#{header_label}</text>\n],
      # Unit entries
      team_units
      |> Enum.with_index()
      |> Enum.map(fn {{unit_id, unit}, idx} ->
        entry_y = panel_y + 36 + idx * 56
        render_roster_entry(panel_x, entry_y, unit_id, unit, active, color, dark)
      end)
    ]
  end

  defp render_roster_entry(px, y, unit_id, unit, active, color, dark) do
    status = get(unit, "status", "alive")
    class = get(unit, "class", "soldier")
    hp = get(unit, "hp", 0)
    max_hp = get(unit, "max_hp", 1)
    is_active = to_string(active) == unit_id
    is_dead = status == "dead"

    name = "#{unit_id}"
    class_label = class_display(class)
    opacity = if is_dead, do: "0.4", else: "1"
    text_decoration = if is_dead, do: "line-through", else: "none"

    hp_pct = if max_hp > 0, do: hp / max_hp, else: 0
    hp_color = hp_bar_color(hp_pct)
    bar_w = @roster_w - 24
    bar_fill_w = round(bar_w * hp_pct)

    [
      # Active highlight
      if is_active do
        ~s[<rect x="#{px + 2}" y="#{y - 4}" width="#{@roster_w - 4}" height="52" ] <>
          ~s[fill="#{dark}" opacity="0.3" rx="3"/>\n]
      else
        ""
      end,
      ~s[<g opacity="#{opacity}">\n],
      ~s[<text x="#{px + 12}" y="#{y + 14}" class="roster-name" ] <>
        ~s[fill="#{color}" text-decoration="#{text_decoration}">#{esc(name)}</text>\n],
      ~s[<text x="#{px + @roster_w - 12}" y="#{y + 14}" class="roster-name" ] <>
        ~s[text-anchor="end" fill="#{@text_secondary}" ] <>
        ~s[text-decoration="#{text_decoration}">#{esc(class_label)}</text>\n],
      # HP bar
      ~s[<rect x="#{px + 12}" y="#{y + 22}" width="#{bar_w}" height="6" ] <>
        ~s[fill="#1a1a2e" rx="2"/>\n],
      ~s[<rect x="#{px + 12}" y="#{y + 22}" width="#{bar_fill_w}" height="6" ] <>
        ~s[fill="#{hp_color}" rx="2"/>\n],
      ~s[<text x="#{px + 12 + bar_w + 2}" y="#{y + 28}" font-size="9" ] <>
        ~s[fill="#{@text_secondary}">#{hp}/#{max_hp}</text>\n],
      if is_dead do
        ~s[<text x="#{px + div(@roster_w, 2)}" y="#{y + 44}" text-anchor="middle" ] <>
          ~s[font-size="10" fill="#{@hp_red}">ELIMINATED</text>\n]
      else
        ""
      end,
      ~s[</g>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Event bar
  # ---------------------------------------------------------------------------

  defp render_event_bar(ctx) do
    %{w: w, h: h, events: events, units: units} = ctx
    bar_y = h - @event_h

    event_text = format_event_text(events, units)

    [
      ~s[<rect x="0" y="#{bar_y}" width="#{w}" height="#{@event_h}" fill="#{@event_bg}"/>\n],
      ~s[<line x1="0" y1="#{bar_y}" x2="#{w}" y2="#{bar_y}" ] <>
        ~s[stroke="#{@grid_line}" stroke-width="1"/>\n],
      ~s[<text x="#{div(w, 2)}" y="#{bar_y + div(@event_h, 2) + 6}" text-anchor="middle" ] <>
        ~s[class="event-text" font-size="18" fill="#{@text_primary}">#{esc(event_text)}</text>\n]
    ]
  end

  defp format_event_text(events, units) when is_list(events) do
    # Find the most impactful event (prioritized)
    event = pick_display_event(events)

    if event do
      kind = get(event, "kind", get(event, "type", ""))
      payload = get(event, "payload", event)
      format_single_event(kind, payload, units)
    else
      ""
    end
  end

  defp format_event_text(_, _), do: ""

  defp pick_display_event(events) do
    priority = %{
      "game_over" => 0,
      "unit_died" => 1,
      "attack_resolved" => 2,
      "heal_applied" => 3,
      "unit_sprinted" => 4,
      "unit_moved" => 5,
      "cover_applied" => 6
    }

    events
    |> Enum.filter(fn e ->
      kind = get(e, "kind", get(e, "type", ""))
      Map.has_key?(priority, kind)
    end)
    |> Enum.min_by(
      fn e ->
        kind = get(e, "kind", get(e, "type", ""))
        Map.get(priority, kind, 99)
      end,
      fn -> nil end
    )
  end

  defp format_single_event("attack_resolved", payload, units) do
    attacker = get(payload, "attacker_id", "?")
    target = get(payload, "target_id", "?")
    hit = get(payload, "hit", false)
    damage = get(payload, "damage", 0)

    a_class = unit_class_display(units, attacker)
    t_class = unit_class_display(units, target)

    if hit do
      "#{attacker} (#{a_class}) attacks #{target} (#{t_class}) - HIT for #{damage} damage!"
    else
      "#{attacker} (#{a_class}) attacks #{target} (#{t_class}) - MISS!"
    end
  end

  defp format_single_event("unit_died", payload, units) do
    unit_id = get(payload, "unit_id", "?")
    cls = unit_class_display(units, unit_id)
    "#{unit_id} (#{cls}) has been eliminated!"
  end

  defp format_single_event("heal_applied", payload, units) do
    healer = get(payload, "healer_id", "?")
    target = get(payload, "target_id", "?")
    amount = get(payload, "amount", 0)
    h_class = unit_class_display(units, healer)
    t_class = unit_class_display(units, target)
    "#{healer} (#{h_class}) heals #{target} (#{t_class}) for #{amount} HP"
  end

  defp format_single_event("unit_moved", payload, _units) do
    unit_id = get(payload, "unit_id", "?")
    x = get(payload, "x", "?")
    y = get(payload, "y", "?")
    "#{unit_id} moves to (#{x},#{y})"
  end

  defp format_single_event("unit_sprinted", payload, _units) do
    unit_id = get(payload, "unit_id", "?")
    x = get(payload, "x", "?")
    y = get(payload, "y", "?")
    "#{unit_id} sprints to (#{x},#{y})"
  end

  defp format_single_event("cover_applied", payload, _units) do
    unit_id = get(payload, "unit_id", "?")
    "#{unit_id} takes cover"
  end

  defp format_single_event("game_over", payload, _units) do
    winner = get(payload, "winner", get(payload, "message", ""))

    if is_binary(winner) and String.length(winner) > 0 do
      "#{String.upcase(winner)} TEAM WINS!"
    else
      "GAME OVER!"
    end
  end

  defp format_single_event(_, _, _), do: ""

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Flexible key access: tries string key first, then atom.
  defp get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, String.to_existing_atom(key), default)
      val -> val
    end
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key), default)
      val -> val
    end
  end

  defp get(_, _, default), do: default

  defp pos_set(positions) when is_list(positions) do
    MapSet.new(positions, fn p ->
      {get(p, "x", get(p, :x, 0)), get(p, "y", get(p, :y, 0))}
    end)
  end

  defp pos_set(_), do: MapSet.new()

  defp team_color("red"), do: @red
  defp team_color("blue"), do: @blue
  defp team_color(:red), do: @red
  defp team_color(:blue), do: @blue
  defp team_color(_), do: @text_primary

  defp team_dark("red"), do: @red_dark
  defp team_dark("blue"), do: @blue_dark
  defp team_dark(:red), do: @red_dark
  defp team_dark(:blue), do: @blue_dark
  defp team_dark(_), do: @text_secondary

  defp team_light("red"), do: @red_light
  defp team_light("blue"), do: @blue_light
  defp team_light(:red), do: @red_light
  defp team_light(:blue), do: @blue_light
  defp team_light(_), do: @text_primary

  defp class_letter("scout"), do: "S"
  defp class_letter("soldier"), do: "+"
  defp class_letter("heavy"), do: "H"
  defp class_letter("sniper"), do: "T"
  defp class_letter("medic"), do: "M"
  defp class_letter(_), do: "?"

  defp class_display("scout"), do: "Scout"
  defp class_display("soldier"), do: "Soldier"
  defp class_display("heavy"), do: "Heavy"
  defp class_display("sniper"), do: "Sniper"
  defp class_display("medic"), do: "Medic"
  defp class_display(other) when is_binary(other), do: String.capitalize(other)
  defp class_display(_), do: "Unknown"

  defp hp_bar_color(pct) when pct > 0.6, do: @hp_green
  defp hp_bar_color(pct) when pct > 0.3, do: @hp_amber
  defp hp_bar_color(_), do: @hp_red

  defp actor_team(units, actor_id) when is_binary(actor_id) do
    case Map.get(units, actor_id) do
      nil -> nil
      unit -> get(unit, "team", nil)
    end
  end

  defp actor_team(_, _), do: nil

  defp unit_pos(units, unit_id) when is_binary(unit_id) do
    case Map.get(units, unit_id) do
      nil -> nil
      unit -> get(unit, "pos", nil)
    end
  end

  defp unit_pos(_, _), do: nil

  defp unit_class_display(units, unit_id) when is_binary(unit_id) do
    case Map.get(units, unit_id) do
      nil -> "Unknown"
      unit -> class_display(get(unit, "class", ""))
    end
  end

  defp unit_class_display(_, _), do: "Unknown"

  defp esc(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp esc(other), do: esc(to_string(other))
end
