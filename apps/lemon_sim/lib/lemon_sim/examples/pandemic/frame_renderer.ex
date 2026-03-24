defmodule LemonSim.Examples.Pandemic.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (pandemic/crisis theme)
  # ---------------------------------------------------------------------------
  @bg "#060d0d"
  @panel_bg "#0c1a1a"
  @panel_border "#1a3333"

  @teal "#1abc9c"
  @teal_dim "#0e6655"

  @text_primary "#e8f5f5"
  @text_secondary "#7fb3b3"
  @text_dim "#3d6666"

  # Governor colors (up to 6 governors)
  @governor_colors ["#3498db", "#9b59b6", "#1abc9c", "#e74c3c", "#f39c12", "#e91e63"]

  # Severity colors
  @sev_critical "#c0392b"
  @sev_high "#e67e22"
  @sev_medium "#f39c12"
  @sev_safe "#27ae60"

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 300
  @map_w 300

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec render_frame(map(), keyword()) :: String.t()
  def render_frame(entry, opts \\ []) do
    w = Keyword.get(opts, :width, 1920)
    h = Keyword.get(opts, :height, 1080)

    world = get(entry, "world", %{})
    type = get(entry, "type", "step")
    step = get(entry, "step", 0)
    events = get(entry, "events", [])

    players = get(world, "players", %{})
    turn_order = get(world, "turn_order", Map.keys(players) |> Enum.sort())
    regions = get(world, "regions", %{})
    travel_routes = get(world, "travel_routes", %{})
    disease = get(world, "disease", %{})
    resource_pool = get(world, "resource_pool", %{})
    public_stats = get(world, "public_stats", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 12)
    phase = get(world, "phase", "intelligence")
    comm_history = get(world, "comm_history", [])
    hoarding_log = get(world, "hoarding_log", [])
    winner = get(world, "winner", nil)
    status = get(world, "status", "in_progress")
    active_actor = get(world, "active_actor_id", nil)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      turn_order: turn_order,
      regions: regions,
      travel_routes: travel_routes,
      disease: disease,
      resource_pool: resource_pool,
      public_stats: public_stats,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      comm_history: comm_history,
      hoarding_log: hoarding_log,
      winner: winner,
      status: status,
      active_actor: active_actor
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_governor_roster(ctx),
      render_center_content(ctx),
      render_region_map(ctx),
      render_footer_bar(ctx),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # SVG skeleton
  # ---------------------------------------------------------------------------

  defp svg_header(%{w: w, h: h}) do
    ~s[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" ] <>
      ~s[width="#{w}" height="#{h}">\n]
  end

  defp svg_defs do
    ~s"""
    <defs>
      <filter id="glow">
        <feGaussianBlur stdDeviation="3" result="blur"/>
        <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
      </filter>
      <filter id="crisis-glow">
        <feGaussianBlur stdDeviation="5" result="blur"/>
        <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
      </filter>
    </defs>
    """
  end

  defp svg_style do
    ~s"""
    <style>
      text { font-family: 'Courier New', Courier, monospace; }
      .title { font-family: sans-serif; font-weight: 700; }
      .label { font-family: sans-serif; font-size: 11px; fill: #{@text_secondary}; }
      .header-text { font-family: sans-serif; fill: #{@text_primary}; }
      .event-text { font-family: sans-serif; fill: #{@text_primary}; }
      .governor-name { font-family: sans-serif; font-weight: 600; }
      .region-text { font-family: sans-serif; }
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

  defp render_header_bar(%{w: w, type: type} = ctx) do
    round_text =
      if type == "game_over" do
        if ctx.status == "won", do: "TEAM VICTORY", else: "TEAM DEFEAT"
      else
        "Round #{ctx.round}/#{ctx.max_rounds}"
      end

    phase_text =
      if type not in ["init", "game_over"] do
        String.upcase(ctx.phase)
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@teal}">PANDEMIC RESPONSE</text>\n],
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 130}" y="14" width="120" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 190}" y="32" text-anchor="middle" font-size="11" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(phase_text)}</text>\n]
      else
        ""
      end,
      ~s[<text x="#{w - 20}" y="18" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Governor roster (left panel)
  # ---------------------------------------------------------------------------

  defp render_governor_roster(%{h: h, turn_order: turn_order, players: players} = ctx) do
    panel_h = h - @header_h - @footer_h

    governor_entries =
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {gid, idx} ->
        player = Map.get(players, gid, %{})
        color = Enum.at(@governor_colors, idx, "#e8f5f5")
        render_governor_card(gid, player, idx, color, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@teal_dim}">GOVERNORS</text>\n],
      governor_entries
    ]
  end

  defp render_governor_card(gid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 130
    region_id = get(player, "region", gid)
    resources = get(player, "resources", %{})
    vaccines = get(resources, "vaccines", 0)
    funding = get(resources, "funding", 0)
    medical_teams = get(resources, "medical_teams", 0)
    is_active = ctx.active_actor == gid
    region = Map.get(ctx.regions, region_id, %{})
    pop = get(region, "population", 1)
    dead = get(region, "dead", 0)
    infected = get(region, "infected", 0)
    quarantined = get(region, "quarantined", false)
    death_rate = if pop > 0, do: Float.round(dead / pop * 100, 2), else: 0.0
    sev_color = severity_color(death_rate)

    highlight =
      cond do
        is_active and ctx.status == "in_progress" ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="124" ] <>
            ~s[fill="#{color}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="124" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    death_bar_w = @roster_w - 40
    death_fill_w = round(death_bar_w * min(death_rate / 10.0, 1.0))

    [
      highlight,
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="governor-name" font-size="13" fill="#{color}">#{esc(format_governor_name(gid))}</text>\n],
      ~s[<text x="36" y="#{y + 29}" font-size="10" fill="#{@text_secondary}">Region: #{esc(region_id)}#{if quarantined, do: " [QUAR]", else: ""}</text>\n],
      ~s[<text x="16" y="#{y + 50}" font-size="10" fill="#{@text_secondary}">Death Rate</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 50}" text-anchor="end" font-size="10" fill="#{sev_color}">#{death_rate}%</text>\n],
      ~s[<rect x="16" y="#{y + 56}" width="#{death_bar_w}" height="6" fill="#{@panel_bg}" rx="2"/>\n],
      ~s[<rect x="16" y="#{y + 56}" width="#{max(death_fill_w, 0)}" height="6" fill="#{sev_color}" rx="2" opacity="0.8"/>\n],
      ~s[<text x="16" y="#{y + 78}" font-size="9" fill="#{@text_secondary}">] <>
        ~s[VAX:#{format_stat(vaccines)} F:#{funding} MED:#{medical_teams}</text>\n],
      ~s[<text x="16" y="#{y + 92}" font-size="9" fill="#{@text_dim}">] <>
        ~s[INF:#{format_stat(infected)} DEAD:#{format_stat(dead)}</text>\n],
      if ctx.winner == "team" and ctx.status == "won" do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 92}" text-anchor="end" font-size="10" ] <>
          ~s[font-weight="700" fill="#{@teal}" filter="url(#glow)">WON</text>\n]
      else
        ""
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "game_over" -> render_game_over_card(ctx)
      _ -> render_phase_content(ctx)
    end
  end

  defp render_init_card(%{w: w, h: h, turn_order: turn_order, regions: regions}) do
    cx = @roster_w + div(w - @roster_w - @map_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    governor_count = length(turn_order)
    region_count = map_size(regions)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@teal}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="30" fill="#{@teal}">PANDEMIC RESPONSE</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 55}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Cooperative Crisis Management Simulation</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{governor_count} Governors &#xB7; #{region_count} Regions</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 20}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Win: Keep deaths below 10% of total population</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 50}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Coordinate intelligence, resources, and containment</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@teal_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 100}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Intel &#xB7; Comms &#xB7; Resources &#xB7; Local Action &#xB7; Spread</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h, status: status, regions: regions, winner: _winner}) do
    cx = @roster_w + div(w - @roster_w - @map_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    won = status == "won"
    outcome_color = if won, do: @sev_safe, else: @sev_critical
    outcome_text = if won, do: "TEAM VICTORY", else: "TEAM DEFEAT"

    total_pop = Enum.sum(Enum.map(regions, fn {_, r} -> get(r, "population", 0) end))
    total_dead = Enum.sum(Enum.map(regions, fn {_, r} -> get(r, "dead", 0) end))
    total_infected = Enum.sum(Enum.map(regions, fn {_, r} -> get(r, "infected", 0) end))
    death_rate = if total_pop > 0, do: Float.round(total_dead / total_pop * 100, 2), else: 0.0

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 160}" width="520" height="320" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{outcome_color}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 110}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{outcome_color}" filter="url(#glow)">#{outcome_text}</text>\n],
      if won do
        ~s[<text x="#{cx}" y="#{cy - 75}" text-anchor="middle" font-size="14" fill="#{@text_secondary}">The team successfully contained the pandemic!</text>\n]
      else
        ~s[<text x="#{cx}" y="#{cy - 75}" text-anchor="middle" font-size="14" fill="#{@text_secondary}">The pandemic overwhelmed global defenses.</text>\n]
      end,
      ~s[<rect x="#{cx - 200}" y="#{cy - 40}" width="180" height="80" fill="#{outcome_color}" opacity="0.06" rx="6"/>\n],
      ~s[<text x="#{cx - 110}" y="#{cy - 14}" text-anchor="middle" font-size="11" fill="#{@text_dim}">TOTAL DEATHS</text>\n],
      ~s[<text x="#{cx - 110}" y="#{cy + 20}" text-anchor="middle" font-size="24" font-weight="700" fill="#{outcome_color}">#{format_stat(total_dead)}</text>\n],
      ~s[<rect x="#{cx + 20}" y="#{cy - 40}" width="180" height="80" fill="#{outcome_color}" opacity="0.06" rx="6"/>\n],
      ~s[<text x="#{cx + 110}" y="#{cy - 14}" text-anchor="middle" font-size="11" fill="#{@text_dim}">DEATH RATE</text>\n],
      ~s[<text x="#{cx + 110}" y="#{cy + 20}" text-anchor="middle" font-size="24" font-weight="700" fill="#{outcome_color}">#{death_rate}%</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 80}" text-anchor="middle" font-size="12" fill="#{@text_dim}">Population: #{format_stat(total_pop)} &#xB7; Infected: #{format_stat(total_infected)}</text>\n]
    ]
  end

  defp render_phase_content(ctx) do
    case ctx.phase do
      "intelligence" -> render_intelligence_panel(ctx)
      "communication" -> render_communication_panel(ctx)
      "resource_allocation" -> render_allocation_panel(ctx)
      "local_action" -> render_local_action_panel(ctx)
      _ -> render_intelligence_panel(ctx)
    end
  end

  defp render_intelligence_panel(%{w: w, h: h, regions: regions} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    # Show global infection summary
    total_infected = Enum.sum(Enum.map(regions, fn {_, r} -> get(r, "infected", 0) end))
    total_dead = Enum.sum(Enum.map(regions, fn {_, r} -> get(r, "dead", 0) end))
    total_pop = Enum.sum(Enum.map(regions, fn {_, r} -> get(r, "population", 0) end))
    death_threshold = trunc(total_pop * 0.10)
    death_rate = if total_pop > 0, do: Float.round(total_dead / total_pop * 100, 2), else: 0.0
    sev_color = severity_color(death_rate)

    disease = ctx.disease
    spread_rate = Float.round(get(disease, "spread_rate", 0.18), 4)
    research = get(disease, "research_progress", 0)

    [
      panel_bg(panel_x, panel_y, panel_w, panel_h),
      panel_title("INTELLIGENCE BRIEFING", panel_x, panel_y, panel_w),
      ~s[<text x="#{panel_x + 16}" y="#{panel_y + 58}" font-size="12" fill="#{@teal}">Global Situation Overview</text>\n],
      ~s[<text x="#{panel_x + 16}" y="#{panel_y + 80}" font-size="11" fill="#{@text_secondary}">Total Population: #{format_stat(total_pop)}</text>\n],
      ~s[<text x="#{panel_x + 16}" y="#{panel_y + 98}" font-size="11" fill="#{@sev_high}">Active Infections: #{format_stat(total_infected)}</text>\n],
      ~s[<text x="#{panel_x + 16}" y="#{panel_y + 116}" font-size="11" fill="#{sev_color}">Total Deaths: #{format_stat(total_dead)} / #{format_stat(death_threshold)} threshold</text>\n],
      ~s[<text x="#{panel_x + 16}" y="#{panel_y + 134}" font-size="11" fill="#{@text_secondary}">Disease Spread Rate: #{spread_rate} &#xB7; Research: #{research} pts</text>\n],
      active_actor_footer(ctx, panel_x, panel_y, panel_w, panel_h, "is gathering intelligence...")
    ]
  end

  defp render_communication_panel(%{w: w, h: h, comm_history: comm_history} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent = Enum.take(comm_history, -12)

    [
      panel_bg(panel_x, panel_y, panel_w, panel_h),
      panel_title("COMMUNICATIONS LOG", panel_x, panel_y, panel_w),
      if recent == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No communications exchanged yet</text>\n]
      else
        recent
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          my = panel_y + 48 + idx * 32
          from_id = get(msg, "from", get(msg, :from, "?"))
          to_id = get(msg, "to", get(msg, :to, "?"))
          msg_type = get(msg, "type", get(msg, :type, "data"))
          round_num = get(msg, "round", get(msg, :round, "?"))

          from_idx = Enum.find_index(ctx.turn_order, &(&1 == from_id)) || 0
          to_idx = Enum.find_index(ctx.turn_order, &(&1 == to_id)) || 0
          from_color = Enum.at(@governor_colors, from_idx, @text_secondary)
          to_color = Enum.at(@governor_colors, to_idx, @text_secondary)
          type_label = if msg_type == "help_request", do: "HELP", else: "DATA"
          type_color = if msg_type == "help_request", do: @sev_high, else: @teal
          is_recent = idx >= length(recent) - 3
          opacity = if is_recent, do: "1", else: "0.5"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s(<text x="#{panel_x + 16}" y="#{my + 12}" font-size="9" font-weight="700" fill="#{type_color}">[#{type_label}]</text>\n),
            ~s[<circle cx="#{panel_x + 70}" cy="#{my + 8}" r="4" fill="#{from_color}"/>\n],
            ~s[<text x="#{panel_x + 80}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{from_color}">#{esc(format_governor_name(from_id))}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{my + 12}" text-anchor="middle" font-size="10" fill="#{@text_dim}">&#x2192; R#{round_num}</text>\n],
            ~s[<circle cx="#{panel_x + panel_w - 80}" cy="#{my + 8}" r="4" fill="#{to_color}"/>\n],
            ~s[<text x="#{panel_x + panel_w - 70}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{to_color}">#{esc(format_governor_name(to_id))}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{my + 20}" x2="#{panel_x + panel_w - 16}" y2="#{my + 20}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      active_actor_footer(ctx, panel_x, panel_y, panel_w, panel_h, "is communicating...")
    ]
  end

  defp render_allocation_panel(%{w: w, h: h, resource_pool: resource_pool} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    vaccines = get(resource_pool, "vaccines", 0)
    funding = get(resource_pool, "funding", 0)
    medical_teams = get(resource_pool, "medical_teams", 0)

    [
      panel_bg(panel_x, panel_y, panel_w, panel_h),
      panel_title("RESOURCE ALLOCATION", panel_x, panel_y, panel_w),
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 62}" text-anchor="middle" font-size="13" fill="#{@teal}">Shared Resource Pool</text>\n],
      # Vaccines
      ~s[<rect x="#{panel_x + 20}" y="#{panel_y + 78}" width="#{div(panel_w - 40, 3) - 10}" height="70" fill="#{@sev_safe}" opacity="0.06" rx="6"/>\n],
      ~s[<text x="#{panel_x + 20 + div(div(panel_w - 40, 3) - 10, 2)}" y="#{panel_y + 100}" text-anchor="middle" font-size="10" fill="#{@text_dim}">VACCINES</text>\n],
      ~s[<text x="#{panel_x + 20 + div(div(panel_w - 40, 3) - 10, 2)}" y="#{panel_y + 128}" text-anchor="middle" font-size="20" font-weight="700" fill="#{@sev_safe}">#{format_stat(vaccines)}</text>\n],
      # Funding
      ~s[<rect x="#{panel_x + 20 + div(panel_w - 40, 3)}" y="#{panel_y + 78}" width="#{div(panel_w - 40, 3) - 10}" height="70" fill="#{@sev_medium}" opacity="0.06" rx="6"/>\n],
      ~s[<text x="#{panel_x + 20 + div(panel_w - 40, 3) + div(div(panel_w - 40, 3) - 10, 2)}" y="#{panel_y + 100}" text-anchor="middle" font-size="10" fill="#{@text_dim}">FUNDING</text>\n],
      ~s[<text x="#{panel_x + 20 + div(panel_w - 40, 3) + div(div(panel_w - 40, 3) - 10, 2)}" y="#{panel_y + 128}" text-anchor="middle" font-size="20" font-weight="700" fill="#{@sev_medium}">#{funding}</text>\n],
      # Medical teams
      ~s[<rect x="#{panel_x + 20 + div(panel_w - 40, 3) * 2}" y="#{panel_y + 78}" width="#{div(panel_w - 40, 3) - 10}" height="70" fill="#{@teal}" opacity="0.06" rx="6"/>\n],
      ~s[<text x="#{panel_x + 20 + div(panel_w - 40, 3) * 2 + div(div(panel_w - 40, 3) - 10, 2)}" y="#{panel_y + 100}" text-anchor="middle" font-size="10" fill="#{@text_dim}">MED TEAMS</text>\n],
      ~s[<text x="#{panel_x + 20 + div(panel_w - 40, 3) * 2 + div(div(panel_w - 40, 3) - 10, 2)}" y="#{panel_y + 128}" text-anchor="middle" font-size="20" font-weight="700" fill="#{@teal}">#{medical_teams}</text>\n],
      active_actor_footer(ctx, panel_x, panel_y, panel_w, panel_h, "is allocating resources...")
    ]
  end

  defp render_local_action_panel(%{w: w, h: h, events: events} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    action_events =
      events
      |> Enum.filter(fn ev ->
        kind = get(ev, "kind", get(ev, :kind, ""))

        kind in [
          "spread_occurred",
          "deaths_recorded",
          "vaccinate",
          "quarantine_zone",
          "build_hospital",
          "fund_research"
        ]
      end)
      |> Enum.take(10)

    [
      panel_bg(panel_x, panel_y, panel_w, panel_h),
      panel_title("LOCAL ACTIONS", panel_x, panel_y, panel_w),
      if action_events == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Governors are taking local action...</text>\n]
      else
        action_events
        |> Enum.with_index()
        |> Enum.map(fn {ev, idx} ->
          ey = panel_y + 52 + idx * 30
          kind = get(ev, "kind", get(ev, :kind, ""))
          payload = get(ev, "payload", get(ev, :payload, %{}))
          render_action_event(kind, payload, ey, panel_x, panel_w)
        end)
      end,
      active_actor_footer(ctx, panel_x, panel_y, panel_w, panel_h, "is taking local action...")
    ]
  end

  defp render_action_event("deaths_recorded", payload, y, panel_x, panel_w) do
    region_id = get(payload, "region_id", "?")
    deaths = get(payload, "deaths", 0)

    [
      ~s[<rect x="#{panel_x + 10}" y="#{y - 2}" width="#{panel_w - 20}" height="22" ] <>
        ~s[fill="#{@sev_critical}" opacity="0.06" rx="3"/>\n],
      ~s[<text x="#{panel_x + 16}" y="#{y + 13}" font-size="11" font-weight="700" fill="#{@sev_critical}">] <>
        ~s[DEATHS: #{esc(region_id)} +#{format_stat(deaths)}</text>\n]
    ]
  end

  defp render_action_event("spread_occurred", payload, y, panel_x, _panel_w) do
    region_id = get(payload, "region_id", "?")
    new_infections = get(payload, "new_infections", 0)

    ~s[<text x="#{panel_x + 16}" y="#{y + 13}" font-size="10" fill="#{@sev_high}">] <>
      ~s[SPREAD: #{esc(region_id)} +#{format_stat(new_infections)} new infections</text>\n]
  end

  defp render_action_event(_kind, _payload, _y, _panel_x, _panel_w), do: ""

  # ---------------------------------------------------------------------------
  # Region map (right panel)
  # ---------------------------------------------------------------------------

  defp render_region_map(%{w: w, h: h, regions: regions} = _ctx) do
    panel_x = w - @map_w
    panel_h = h - @header_h - @footer_h

    region_names = ["northvale", "central_hub", "highland", "westport", "southshore", "eastlands"]

    region_entries =
      region_names
      |> Enum.with_index()
      |> Enum.map(fn {region_id, idx} ->
        region = Map.get(regions, region_id, %{})
        pop = get(region, "population", 1)
        infected = get(region, "infected", 0)
        dead = get(region, "dead", 0)
        quarantined = get(region, "quarantined", false)
        hospitals = get(region, "hospitals", 1)
        infection_rate = if pop > 0, do: Float.round(infected / pop * 100, 1), else: 0.0
        sev_color = infection_severity_color(infection_rate)

        ry = @header_h + 40 + idx * 62

        [
          ~s[<rect x="#{panel_x + 8}" y="#{ry - 12}" width="#{@map_w - 16}" height="56" ] <>
            ~s[fill="#{sev_color}" opacity="0.06" rx="4"/>\n],
          ~s[<rect x="#{panel_x + 8}" y="#{ry - 12}" width="#{@map_w - 16}" height="56" ] <>
            ~s[fill="none" stroke="#{sev_color}" opacity="0.15" rx="4" stroke-width="1"/>\n],
          ~s[<text x="#{panel_x + 18}" y="#{ry + 4}" font-size="11" font-weight="700" fill="#{sev_color}">#{esc(String.upcase(region_id))}</text>\n],
          if quarantined do
            ~s[<text x="#{panel_x + @map_w - 18}" y="#{ry + 4}" text-anchor="end" font-size="8" font-weight="700" fill="#{@teal}">QUAR</text>\n]
          else
            ~s[<text x="#{panel_x + @map_w - 18}" y="#{ry + 4}" text-anchor="end" font-size="9" fill="#{@text_dim}">H:#{hospitals}</text>\n]
          end,
          ~s[<text x="#{panel_x + 18}" y="#{ry + 20}" font-size="9" fill="#{@sev_high}">INF: #{format_stat(infected)}</text>\n],
          ~s[<text x="#{panel_x + 18}" y="#{ry + 34}" font-size="9" fill="#{@text_dim}">DEAD: #{format_stat(dead)}</text>\n],
          ~s[<text x="#{panel_x + @map_w - 18}" y="#{ry + 34}" text-anchor="end" font-size="10" font-weight="700" fill="#{sev_color}">#{infection_rate}%</text>\n]
        ]
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@map_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@map_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@map_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@teal_dim}">REGIONS</text>\n],
      region_entries
    ]
  end

  # ---------------------------------------------------------------------------
  # Footer bar
  # ---------------------------------------------------------------------------

  defp render_footer_bar(%{w: w, h: h} = ctx) do
    bar_y = h - @footer_h
    event_text = format_footer_text(ctx)

    [
      ~s[<rect x="0" y="#{bar_y}" width="#{w}" height="#{@footer_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{bar_y}" x2="#{w}" y2="#{bar_y}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{div(w, 2)}" y="#{bar_y + div(@footer_h, 2) + 5}" text-anchor="middle" ] <>
        ~s[class="event-text" font-size="16" fill="#{@text_primary}">#{esc(event_text)}</text>\n]
    ]
  end

  defp format_footer_text(ctx) do
    events = ctx.events

    cond do
      ctx.type == "init" ->
        "Pandemic outbreak detected — #{length(ctx.turn_order)} governors mobilizing response"

      ctx.type == "game_over" and ctx.status == "won" ->
        "Team Victory — pandemic successfully contained!"

      ctx.type == "game_over" ->
        "Team Defeat — the pandemic overwhelmed global defenses"

      has_event?(events, "game_over") ->
        ev = find_event(events, "game_over")
        p = get(ev, "payload", ev || %{})
        reason = get(p, "reason", "game over")
        "Game Over: #{reason}"

      has_event?(events, "deaths_recorded") ->
        ev = find_event(events, "deaths_recorded")
        p = get(ev, "payload", ev || %{})
        region = get(p, "region_id", "?")
        deaths = get(p, "deaths", 0)
        "Deaths recorded in #{region}: +#{format_stat(deaths)}"

      has_event?(events, "spread_occurred") ->
        ev = find_event(events, "spread_occurred")
        p = get(ev, "payload", ev || %{})
        region = get(p, "region_id", "?")
        new_cases = get(p, "new_infections", 0)
        "Disease spreads to #{region}: +#{format_stat(new_cases)} infections"

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins — new intelligence phase"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        "Phase transition: #{get(p, "from", "?")} -> #{get(p, "to", "?")}"

      has_event?(events, "data_shared") ->
        ev = find_event(events, "data_shared")
        p = get(ev, "payload", ev || %{})
        from = get(p, "from_id", "?")
        to = get(p, "to_id", "?")
        "#{format_governor_name(from)} shared data with #{format_governor_name(to)}"

      true ->
        phase_text =
          case ctx.phase do
            "intelligence" -> "Governors gathering regional intelligence..."
            "communication" -> "Governors coordinating response..."
            "resource_allocation" -> "Allocating resources from shared pool..."
            "local_action" -> "Deploying local countermeasures..."
            _ -> ""
          end

        phase_text
    end
  end

  # ---------------------------------------------------------------------------
  # Shared panel helpers
  # ---------------------------------------------------------------------------

  defp panel_bg(x, y, w, h) do
    ~s[<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n]
  end

  defp panel_title(title, panel_x, panel_y, panel_w) do
    [
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@teal_dim}">#{esc(title)}</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n]
    ]
  end

  defp active_actor_footer(ctx, panel_x, panel_y, panel_w, panel_h, action_text) do
    if ctx.active_actor do
      actor_idx = Enum.find_index(ctx.turn_order, &(&1 == ctx.active_actor)) || 0
      actor_color = Enum.at(@governor_colors, actor_idx, @text_secondary)

      [
        ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
          ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{actor_color}">#{esc(format_governor_name(ctx.active_actor))} #{action_text}</text>\n]
      ]
    else
      ""
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("intelligence"), do: "#3498db"
  defp phase_color("communication"), do: "#9b59b6"
  defp phase_color("resource_allocation"), do: "#f39c12"
  defp phase_color("local_action"), do: "#1abc9c"
  defp phase_color(_), do: @text_secondary

  defp severity_color(rate) when rate >= 5.0, do: @sev_critical
  defp severity_color(rate) when rate >= 2.0, do: @sev_high
  defp severity_color(rate) when rate >= 0.5, do: @sev_medium
  defp severity_color(_), do: @sev_safe

  defp infection_severity_color(rate) when rate >= 15.0, do: @sev_critical
  defp infection_severity_color(rate) when rate >= 5.0, do: @sev_high
  defp infection_severity_color(rate) when rate >= 1.0, do: @sev_medium
  defp infection_severity_color(_), do: @sev_safe

  defp format_governor_name(nil), do: "?"
  defp format_governor_name("governor_" <> n), do: "Governor #{n}"
  defp format_governor_name(name) when is_binary(name), do: name
  defp format_governor_name(_), do: "?"

  defp format_stat(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_stat(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_stat(n) when is_number(n), do: to_string(trunc(n))
  defp format_stat(nil), do: "0"
  defp format_stat(other), do: to_string(other)

  defp has_event?(events, kind) when is_list(events) do
    Enum.any?(events, fn
      %{"kind" => k} -> k == kind
      %{kind: k} -> to_string(k) == kind
      _ -> false
    end)
  end

  defp has_event?(_, _), do: false

  defp find_event(events, kind) when is_list(events) do
    Enum.find(events, fn
      %{"kind" => k} -> k == kind
      %{kind: k} -> to_string(k) == kind
      _ -> false
    end)
  end

  defp find_event(_, _), do: nil

  defp get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          ArgumentError -> default
        end

      val ->
        val
    end
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_, _, default), do: default

  defp esc(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp esc(other), do: esc(to_string(other))
end
