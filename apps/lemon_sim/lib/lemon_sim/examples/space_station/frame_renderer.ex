defmodule LemonSim.Examples.SpaceStation.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (sci-fi theme)
  # ---------------------------------------------------------------------------
  @bg "#070b14"
  @panel_bg "#0d1525"
  @panel_border "#1a2744"

  @green "#22c55e"
  @yellow "#eab308"
  @red "#dc2626"

  @cyan "#06b6d4"
  @purple "#a855f7"

  @text_primary "#e2e8f0"
  @text_secondary "#94a3b8"
  @text_dim "#475569"

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 300
  @systems_w 280

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
    systems = get(world, "systems", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 12)
    phase = get(world, "phase", "action")
    active_actor_id = get(world, "active_actor_id", nil)
    alert_level = get(entry, "alert_level", compute_alert_level(systems))
    meeting_log = get(world, "discussion_transcript", [])
    scan_results = get(world, "scan_results", %{})
    ejected_players = get(world, "ejected_players", [])
    votes = get(world, "votes", %{})
    winner = get(world, "winner", nil)
    elimination_log = get(world, "elimination_log", [])

    # Build sorted player turn order
    turn_order =
      players
      |> Map.keys()
      |> Enum.sort()

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      systems: systems,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      active_actor_id: active_actor_id,
      alert_level: alert_level,
      meeting_log: meeting_log,
      scan_results: scan_results,
      ejected_players: ejected_players,
      votes: votes,
      winner: winner,
      elimination_log: elimination_log,
      turn_order: turn_order
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_roster(ctx),
      render_center_content(ctx),
      render_systems_panel(ctx),
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
      <filter id="glow-red">
        <feGaussianBlur stdDeviation="4" result="blur"/>
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
      .player-name { font-family: sans-serif; font-weight: 600; }
      .system-name { font-family: sans-serif; font-weight: 600; }
      .mono { font-family: 'Courier New', Courier, monospace; }
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
        "GAME OVER"
      else
        "Round #{ctx.round}/#{ctx.max_rounds}"
      end

    phase_text = String.upcase(ctx.phase)

    alert_color = alert_color(ctx.alert_level)

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@cyan}">SPACE STATION</text>\n],
      # Round info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      # Phase badge
      ~s[<rect x="#{div(w, 2) + 80}" y="18" width="100" height="24" rx="4" fill="#{@panel_border}"/>\n],
      ~s[<text x="#{div(w, 2) + 130}" y="35" class="header-text" font-size="11" ] <>
        ~s[text-anchor="middle" fill="#{@cyan}">#{esc(phase_text)}</text>\n],
      # Alert level
      ~s[<text x="#{w - 20}" y="28" class="header-text" font-size="12" ] <>
        ~s[text-anchor="end" fill="#{alert_color}" filter="url(#glow)">ALERT: #{String.upcase(ctx.alert_level || "normal")}</text>\n],
      # Step
      ~s[<text x="#{w - 20}" y="50" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Player roster (left panel)
  # ---------------------------------------------------------------------------

  defp render_player_roster(%{h: h, turn_order: turn_order, players: players} = ctx) do
    panel_h = h - @header_h - @footer_h

    player_entries =
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {pid, idx} ->
        player = Map.get(players, pid, %{})
        render_player_card(pid, player, idx, ctx)
      end)

    [
      # Panel background
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@text_secondary}">CREW ROSTER</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, ctx) do
    y = @header_h + 36 + idx * 112
    role = get(player, "role", get(player, :role, "crew"))
    status = get(player, "status", get(player, :status, "alive"))
    location = get(player, "location", get(player, :location, nil))
    reputation = get(player, "reputation", get(player, :reputation, 0))
    name = get(player, "name", get(player, :name, pid))

    is_active = ctx.active_actor_id == pid
    is_ejected = status == "ejected"
    is_dead = status == "dead"
    is_game_over = ctx.type == "game_over"

    role_badge_color = role_color(role, is_game_over)
    role_display = if is_game_over, do: String.upcase(role), else: role_badge(role)

    status_color =
      cond do
        is_ejected -> @red
        is_dead -> @text_dim
        true -> @green
      end

    opacity = if is_ejected or is_dead, do: "0.45", else: "1"

    highlight =
      if is_active and not is_ejected and not is_dead do
        ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="106" ] <>
          ~s[fill="#{@cyan}" opacity="0.07" rx="6"/>\n] <>
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="106" ] <>
          ~s[fill="none" stroke="#{@cyan}" stroke-width="1.5" rx="6" opacity="0.5"/>\n]
      else
        ""
      end

    # Reputation bar
    rep_pct = max(min((reputation + 100) / 200, 1.0), 0.0)
    rep_bar_w = @roster_w - 40
    rep_fill_w = round(rep_bar_w * rep_pct)
    rep_color = if reputation >= 0, do: @cyan, else: @red

    [
      highlight,
      ~s[<g opacity="#{opacity}">\n],
      # Status dot + name
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{status_color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="player-name" font-size="14" fill="#{@text_primary}">#{esc(name)}</text>\n],
      # Role badge
      ~s[<rect x="#{@roster_w - 90}" y="#{y}" width="82" height="18" rx="4" fill="#{role_badge_color}" opacity="0.2"/>\n],
      ~s[<text x="#{@roster_w - 49}" y="#{y + 13}" text-anchor="middle" font-size="10" ] <>
        ~s[font-weight="700" fill="#{role_badge_color}">#{esc(role_display)}</text>\n],
      # Location
      ~s[<text x="16" y="#{y + 36}" font-size="10" fill="#{@text_secondary}">Location:</text>\n],
      ~s[<text x="76" y="#{y + 36}" font-size="10" fill="#{@cyan}">#{esc(location || "—")}</text>\n],
      # Status text
      ~s[<text x="16" y="#{y + 52}" font-size="10" fill="#{@text_secondary}">Status:</text>\n],
      ~s[<text x="68" y="#{y + 52}" font-size="10" fill="#{status_color}">#{esc(status)}</text>\n],
      # Reputation bar
      ~s[<text x="16" y="#{y + 70}" font-size="10" fill="#{@text_secondary}">Rep: #{reputation}</text>\n],
      ~s[<rect x="16" y="#{y + 76}" width="#{rep_bar_w}" height="6" fill="#{@panel_bg}" rx="2"/>\n],
      ~s[<rect x="16" y="#{y + 76}" width="#{max(rep_fill_w, 0)}" height="6" fill="#{rep_color}" rx="2" opacity="0.8"/>\n],
      ~s[</g>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content (phase-specific)
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "game_over" -> render_game_over_card(ctx)
      _ -> render_phase_content(ctx)
    end
  end

  defp render_init_card(%{w: w, h: h, players: players, systems: systems}) do
    cx = @roster_w + div(w - @roster_w - @systems_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = map_size(players)
    system_count = map_size(systems)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@cyan}" stroke-width="2" opacity="0.95"/>\n],
      # Title
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@cyan}" filter="url(#glow)">SPACE STATION CRISIS</text>\n],
      # Subtitle
      ~s[<text x="#{cx}" y="#{cy - 58}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Social Deduction &#xB7; Find the Saboteur</text>\n],
      # Divider
      ~s[<line x1="#{cx - 140}" y1="#{cy - 40}" x2="#{cx + 140}" y2="#{cy - 40}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Info
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Crew Members &#xB7; #{system_count} Systems</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 20}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">One saboteur hides among the crew</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 50}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Crew: keep all systems above 0 for 12 rounds</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 72}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@red}">Saboteur: destroy any system to win</text>\n],
      # Roles legend
      ~s[<text x="#{cx - 160}" y="#{cy + 110}" font-size="11" fill="#{@cyan}">ENG</text>\n],
      ~s[<text x="#{cx - 130}" y="#{cy + 110}" font-size="11" fill="#{@text_dim}">Engineer</text>\n],
      ~s[<text x="#{cx - 60}" y="#{cy + 110}" font-size="11" fill="#{@yellow}">CPT</text>\n],
      ~s[<text x="#{cx - 30}" y="#{cy + 110}" font-size="11" fill="#{@text_dim}">Captain</text>\n],
      ~s[<text x="#{cx + 50}" y="#{cy + 110}" font-size="11" fill="#{@text_secondary}">CRW</text>\n],
      ~s[<text x="#{cx + 80}" y="#{cy + 110}" font-size="11" fill="#{@text_dim}">Crew</text>\n],
      ~s[<text x="#{cx + 130}" y="#{cy + 110}" font-size="11" fill="#{@purple}">SAB</text>\n],
      ~s[<text x="#{cx + 158}" y="#{cy + 110}" font-size="11" fill="#{@text_dim}">Saboteur</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h, players: players, winner: winner, elimination_log: elimination_log, turn_order: turn_order}) do
    cx = @roster_w + div(w - @roster_w - @systems_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    winner_label =
      case winner do
        "crew" -> "CREW WINS"
        "saboteur" -> "SABOTEUR WINS"
        _ -> "GAME OVER"
      end

    winner_color =
      case winner do
        "crew" -> @green
        "saboteur" -> @red
        _ -> @text_primary
      end

    # Find the saboteur
    saboteur_entry =
      Enum.find(turn_order, fn pid ->
        player = Map.get(players, pid, %{})
        role = get(player, "role", get(player, :role, ""))
        role == "saboteur"
      end)

    saboteur_name =
      if saboteur_entry do
        player = Map.get(players, saboteur_entry, %{})
        get(player, "name", get(player, :name, saboteur_entry))
      else
        "Unknown"
      end

    # Survivors
    survivors =
      Enum.filter(turn_order, fn pid ->
        player = Map.get(players, pid, %{})
        status = get(player, "status", get(player, :status, "alive"))
        status == "alive"
      end)

    survivor_count = length(survivors)

    card_h = 200 + length(elimination_log) * 30

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{winner_color}" stroke-width="2" opacity="0.95"/>\n],
      # Winner banner
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 50}" text-anchor="middle" class="title" ] <>
        ~s[font-size="36" fill="#{winner_color}" filter="url(#glow)">#{esc(winner_label)}</text>\n],
      # Saboteur reveal
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 85}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">The saboteur was:</text>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 108}" text-anchor="middle" font-size="20" ] <>
        ~s[font-weight="700" fill="#{@purple}">#{esc(saboteur_name)}</text>\n],
      # Survivor count
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 138}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">#{survivor_count} crew survived</text>\n],
      # Divider
      ~s[<line x1="#{cx - 200}" y1="#{cy - div(card_h, 2) + 152}" x2="#{cx + 200}" y2="#{cy - div(card_h, 2) + 152}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Elimination log
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 170}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}" letter-spacing="1">EJECTION LOG</text>\n],
      elimination_log
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        ey = cy - div(card_h, 2) + 190 + idx * 30
        player_id = get(entry, "player", get(entry, :player, "?"))
        role = get(entry, "role", get(entry, :role, "?"))
        round_num = get(entry, "round", get(entry, :round, "?"))
        role_c = if role == "saboteur", do: @purple, else: @text_secondary

        [
          ~s[<text x="#{cx - 180}" y="#{ey}" font-size="12" fill="#{@text_primary}">#{esc(player_id)}</text>\n],
          ~s[<text x="#{cx}" y="#{ey}" text-anchor="middle" font-size="11" fill="#{role_c}">#{esc(role)}</text>\n],
          ~s[<text x="#{cx + 180}" y="#{ey}" text-anchor="end" font-size="11" fill="#{@text_dim}">Round #{round_num}</text>\n]
        ]
      end)
    ]
  end

  defp render_phase_content(ctx) do
    case ctx.phase do
      "action" -> render_action_phase(ctx)
      "discussion" -> render_meeting_phase(ctx)
      "voting" -> render_voting_phase(ctx)
      _ -> render_action_phase(ctx)
    end
  end

  defp render_action_phase(%{w: w, h: h, active_actor_id: actor_id, players: players, systems: systems, events: events}) do
    cx = @roster_w + div(w - @roster_w - @systems_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    actor = Map.get(players, actor_id, %{})
    actor_name = get(actor, "name", get(actor, :name, actor_id))
    actor_role = get(actor, "role", get(actor, :role, "crew"))

    # Find the most recent action event
    action_event =
      Enum.find(events, fn ev ->
        kind = get(ev, "kind", "")
        kind in ["repair_system", "sabotage_system", "scan_player", "lock_room",
                 "call_emergency_meeting", "vent", "fake_repair", "inspect_system"]
      end)

    action_text =
      if action_event do
        kind = get(action_event, "kind", "")
        payload = get(action_event, "payload", %{})
        system_id = get(payload, "system_id", "")

        case kind do
          "repair_system" -> "Repaired #{system_id}"
          "sabotage_system" -> "Worked on #{system_id}"
          "fake_repair" -> "Worked on #{system_id}"
          "inspect_system" -> "Inspected #{system_id}"
          "scan_player" -> "Performed scan"
          "lock_room" -> "Locked #{system_id}"
          "call_emergency_meeting" -> "Called emergency meeting"
          "vent" -> "Used ventilation system"
          _ -> kind
        end
      else
        nil
      end

    # Low health systems to highlight
    critical_systems =
      systems
      |> Enum.filter(fn {_id, s} ->
        health = get(s, "health", get(s, :health, 100))
        health <= 30
      end)
      |> Enum.sort_by(fn {_id, s} -> get(s, "health", get(s, :health, 100)) end)
      |> Enum.take(3)

    [
      # Actor card
      ~s[<rect x="#{cx - 220}" y="#{cy - 180}" width="440" height="140" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@cyan}" stroke-width="1.5" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 148}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_dim}" letter-spacing="2">CURRENT TURN</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 112}" text-anchor="middle" class="player-name" ] <>
        ~s[font-size="26" fill="#{@text_primary}">#{esc(actor_name)}</text>\n],
      # Role badge
      role_badge_svg(actor_role, cx, cy - 92),
      # Action
      if action_text do
        [
          ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" font-size="12" ] <>
            ~s[fill="#{@text_secondary}">Action taken:</text>\n],
          ~s[<text x="#{cx}" y="#{cy - 40}" text-anchor="middle" font-size="16" ] <>
            ~s[fill="#{@cyan}">#{esc(action_text)}</text>\n]
        ]
      else
        ~s[<text x="#{cx}" y="#{cy - 50}" text-anchor="middle" font-size="14" ] <>
          ~s[fill="#{@text_dim}">Deciding action...</text>\n]
      end,
      # Critical systems warning
      if critical_systems != [] do
        [
          ~s[<rect x="#{cx - 220}" y="#{cy + 10}" width="440" height="#{30 + length(critical_systems) * 32}" ] <>
            ~s[fill="#{@panel_bg}" rx="10" stroke="#{@red}" stroke-width="1" opacity="0.9"/>\n],
          ~s[<text x="#{cx}" y="#{cy + 30}" text-anchor="middle" font-size="12" ] <>
            ~s[fill="#{@red}" letter-spacing="1">CRITICAL SYSTEMS</text>\n],
          critical_systems
          |> Enum.with_index()
          |> Enum.map(fn {{sys_id, sys_data}, idx} ->
            sy = cy + 52 + idx * 32
            health = get(sys_data, "health", get(sys_data, :health, 100))
            sys_name = get(sys_data, "name", get(sys_data, :name, sys_id))
            bar_w = 200
            fill_w = round(bar_w * health / 100)

            [
              ~s[<text x="#{cx - 190}" y="#{sy}" font-size="12" fill="#{@red}">#{esc(sys_name)}</text>\n],
              ~s[<text x="#{cx + 190}" y="#{sy}" text-anchor="end" font-size="12" fill="#{@red}">#{health}%</text>\n],
              ~s[<rect x="#{cx - 190}" y="#{sy + 4}" width="#{bar_w}" height="8" fill="#{@panel_border}" rx="3"/>\n],
              ~s[<rect x="#{cx - 190}" y="#{sy + 4}" width="#{max(fill_w, 0)}" height="8" fill="#{@red}" rx="3" opacity="0.8"/>\n]
            ]
          end)
        ]
      else
        ""
      end
    ]
  end

  defp render_meeting_phase(%{w: w, h: h, meeting_log: meeting_log, players: players}) do
    cx = @roster_w + div(w - @roster_w - @systems_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)
    panel_w = w - @roster_w - @systems_w - 40

    # Show last 6 discussion entries
    recent = Enum.take(meeting_log, -6)

    [
      ~s[<rect x="#{cx - div(panel_w, 2)}" y="#{@header_h + 20}" width="#{panel_w}" height="#{h - @header_h - @footer_h - 40}" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@yellow}" stroke-width="1.5" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{@header_h + 44}" text-anchor="middle" font-size="14" ] <>
        ~s[font-weight="700" fill="#{@yellow}" letter-spacing="2">EMERGENCY MEETING</text>\n],
      ~s[<line x1="#{cx - div(panel_w, 2) + 20}" y1="#{@header_h + 52}" x2="#{cx + div(panel_w, 2) - 20}" y2="#{@header_h + 52}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent == [] do
        ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" font-size="14" fill="#{@text_dim}">Discussion beginning...</text>\n]
      else
        recent
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          dy = @header_h + 80 + idx * 110
          player_id = get(entry, "player", get(entry, :player, "?"))
          statement = get(entry, "statement", get(entry, :statement, ""))
          entry_type = get(entry, "type", get(entry, :type, "statement"))
          target_id = get(entry, "target", get(entry, :target, nil))

          speaker_name =
            if is_map(players) do
              player = Map.get(players, player_id, %{})
              get(player, "name", get(player, :name, player_id))
            else
              player_id
            end

          label_color =
            case entry_type do
              "accusation" -> @red
              "question" -> @cyan
              _ -> @text_secondary
            end

          type_label =
            case entry_type do
              "accusation" -> "ACCUSES"
              "question" -> "ASKS"
              _ -> "SAYS"
            end

          target_text =
            if target_id && entry_type in ["accusation", "question"] do
              target_player = Map.get(players, target_id, %{})
              target_name = get(target_player, "name", get(target_player, :name, target_id))
              " #{target_name}:"
            else
              ":"
            end

          wrapped = wrap_text(statement, 55)

          [
            ~s[<text x="#{cx - div(panel_w, 2) + 20}" y="#{dy + 16}" font-size="13" ] <>
              ~s[font-weight="700" fill="#{@text_primary}">#{esc(speaker_name)}</text>\n],
            ~s[<text x="#{cx - div(panel_w, 2) + 130}" y="#{dy + 16}" font-size="11" ] <>
              ~s[fill="#{label_color}">#{type_label}#{esc(target_text)}</text>\n],
            wrapped
            |> Enum.with_index()
            |> Enum.map(fn {line, li} ->
              ~s[<text x="#{cx - div(panel_w, 2) + 28}" y="#{dy + 36 + li * 18}" font-size="12" ] <>
                ~s[fill="#{@text_secondary}">#{esc(line)}</text>\n]
            end)
          ]
        end)
      end
    ]
  end

  defp render_voting_phase(%{w: w, h: h, votes: votes, players: players, turn_order: turn_order}) do
    cx = @roster_w + div(w - @roster_w - @systems_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    # Tally votes
    vote_tally =
      votes
      |> Enum.reduce(%{}, fn {_voter, target}, acc ->
        Map.update(acc, target, 1, &(&1 + 1))
      end)

    # Sort candidates by vote count desc
    candidates =
      vote_tally
      |> Enum.sort_by(fn {_pid, count} -> -count end)

    total_votes = map_size(votes)
    living_count = Enum.count(turn_order, fn pid ->
      player = Map.get(players, pid, %{})
      status = get(player, "status", get(player, :status, "alive"))
      status == "alive"
    end)

    [
      ~s[<rect x="#{cx - 250}" y="#{cy - 200}" width="500" height="400" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@red}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 158}" text-anchor="middle" font-size="18" ] <>
        ~s[font-weight="700" fill="#{@red}" letter-spacing="2">VOTE TO EJECT</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 132}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">#{total_votes}/#{living_count} votes cast</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{cy - 118}" x2="#{cx + 200}" y2="#{cy - 118}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      if candidates == [] do
        ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" font-size="14" fill="#{@text_dim}">Awaiting votes...</text>\n]
      else
        candidates
        |> Enum.with_index()
        |> Enum.map(fn {{target_id, count}, idx} ->
          vy = cy - 100 + idx * 56
          target_player = Map.get(players, target_id, %{})
          target_name = get(target_player, "name", get(target_player, :name, target_id))
          bar_max_w = 320
          bar_fill = if total_votes > 0, do: round(bar_max_w * count / total_votes), else: 0

          [
            ~s[<text x="#{cx - 200}" y="#{vy + 16}" font-size="14" fill="#{@text_primary}">#{esc(target_name)}</text>\n],
            ~s[<text x="#{cx + 200}" y="#{vy + 16}" text-anchor="end" font-size="16" font-weight="700" fill="#{@red}">#{count}</text>\n],
            ~s[<rect x="#{cx - 200}" y="#{vy + 22}" width="#{bar_max_w}" height="10" fill="#{@panel_border}" rx="4"/>\n],
            ~s[<rect x="#{cx - 200}" y="#{vy + 22}" width="#{max(bar_fill, 0)}" height="10" fill="#{@red}" rx="4" opacity="0.7"/>\n]
          ]
        end)
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # Systems panel (right panel)
  # ---------------------------------------------------------------------------

  defp render_systems_panel(%{w: w, h: h, systems: systems}) do
    panel_x = w - @systems_w
    panel_h = h - @header_h - @footer_h

    sorted_systems =
      systems
      |> Enum.sort_by(fn {id, _s} -> id end)

    system_entries =
      sorted_systems
      |> Enum.with_index()
      |> Enum.map(fn {{sys_id, sys_data}, idx} ->
        render_system_gauge(sys_id, sys_data, idx, panel_x)
      end)

    [
      # Panel background
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@systems_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@systems_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@systems_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@text_secondary}">SYSTEM HEALTH</text>\n],
      system_entries
    ]
  end

  defp render_system_gauge(sys_id, sys_data, idx, panel_x) do
    y = @header_h + 40 + idx * 112
    health = get(sys_data, "health", get(sys_data, :health, 100))
    decay_rate = get(sys_data, "decay_rate", get(sys_data, :decay_rate, 0))
    sys_name = get(sys_data, "name", get(sys_data, :name, sys_id))

    health_int = round(health)
    bar_w = @systems_w - 40
    fill_w = round(bar_w * health_int / 100)

    health_color =
      cond do
        health_int <= 20 -> @red
        health_int <= 50 -> @yellow
        true -> @green
      end

    is_critical = health_int <= 20

    [
      # Critical pulse effect
      if is_critical do
        ~s[<rect x="#{panel_x + 8}" y="#{y - 4}" width="#{@systems_w - 16}" height="98" ] <>
          ~s[fill="#{@red}" opacity="0.06" rx="6"/>\n]
      else
        ""
      end,
      # System name
      ~s[<text x="#{panel_x + 16}" y="#{y + 14}" class="system-name" font-size="13" fill="#{@text_primary}">#{esc(sys_name)}</text>\n],
      # System ID
      ~s[<text x="#{panel_x + 16}" y="#{y + 30}" font-size="9" fill="#{@text_dim}">#{esc(String.upcase(sys_id))}</text>\n],
      # Health value
      ~s[<text x="#{panel_x + @systems_w - 16}" y="#{y + 14}" text-anchor="end" font-size="16" ] <>
        ~s[font-weight="700" fill="#{health_color}">#{health_int}%</text>\n],
      # Decay rate
      ~s[<text x="#{panel_x + @systems_w - 16}" y="#{y + 30}" text-anchor="end" font-size="10" ] <>
        ~s[fill="#{@text_dim}">-#{decay_rate}/rnd</text>\n],
      # Health bar background
      ~s[<rect x="#{panel_x + 16}" y="#{y + 38}" width="#{bar_w}" height="14" fill="#{@panel_bg}" rx="4"/>\n],
      # Health bar fill
      ~s[<rect x="#{panel_x + 16}" y="#{y + 38}" width="#{max(fill_w, 0)}" height="14" fill="#{health_color}" rx="4" opacity="0.85"/>\n],
      # Critical threshold marker at 20%
      ~s[<line x1="#{panel_x + 16 + round(bar_w * 0.2)}" y1="#{y + 38}" x2="#{panel_x + 16 + round(bar_w * 0.2)}" y2="#{y + 52}" ] <>
        ~s[stroke="#{@red}" stroke-width="1" opacity="0.5" stroke-dasharray="2,2"/>\n],
      # Warning threshold marker at 50%
      ~s[<line x1="#{panel_x + 16 + round(bar_w * 0.5)}" y1="#{y + 38}" x2="#{panel_x + 16 + round(bar_w * 0.5)}" y2="#{y + 52}" ] <>
        ~s[stroke="#{@yellow}" stroke-width="1" opacity="0.4" stroke-dasharray="2,2"/>\n],
      # Status label
      system_status_label(health_int, sys_name, panel_x, y)
    ]
  end

  defp system_status_label(health, _sys_name, panel_x, y) do
    cond do
      health <= 20 ->
        ~s[<text x="#{panel_x + 16}" y="#{y + 78}" font-size="10" font-weight="700" fill="#{@red}" filter="url(#glow-red)">CRITICAL</text>\n]

      health <= 50 ->
        ~s[<text x="#{panel_x + 16}" y="#{y + 78}" font-size="10" fill="#{@yellow}">WARNING</text>\n]

      true ->
        ~s[<text x="#{panel_x + 16}" y="#{y + 78}" font-size="10" fill="#{@green}">NOMINAL</text>\n]
    end
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
        "Space Station Crisis begins — #{map_size(ctx.players)} crew, #{map_size(ctx.systems)} systems"

      ctx.type == "game_over" ->
        case ctx.winner do
          "crew" -> "Crew survives! The saboteur has been defeated."
          "saboteur" -> "Sabotage successful! The station has been destroyed."
          _ -> "Game over."
        end

      has_event?(events, "game_over") ->
        ev = find_event(events, "game_over")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Game over.")

      has_event?(events, "player_ejected") ->
        ev = find_event(events, "player_ejected")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "Someone")
        role = get(p, "role", "unknown")
        "#{player_id} has been ejected! They were #{role}."

      has_event?(events, "vote_result") ->
        ev = find_event(events, "vote_result")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Vote result announced.")

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Phase changed.")

      has_event?(events, "round_resolved") ->
        ev = find_event(events, "round_resolved")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Round resolved.")

      has_event?(events, "repair_system") ->
        ev = find_event(events, "repair_system")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        system_id = get(p, "system_id", "?")
        "#{player_id} repairs #{system_id}"

      has_event?(events, "sabotage_system") ->
        ev = find_event(events, "sabotage_system")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        system_id = get(p, "system_id", "?")
        "#{player_id} works on #{system_id}"

      has_event?(events, "make_statement") ->
        ev = find_event(events, "make_statement")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        statement = get(p, "statement", "")
        short = if String.length(statement) > 80, do: String.slice(statement, 0, 80) <> "...", else: statement
        "#{player_id}: \"#{short}\""

      has_event?(events, "accuse") ->
        ev = find_event(events, "accuse")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        target_id = get(p, "target_id", "?")
        "#{player_id} formally accuses #{target_id}!"

      has_event?(events, "cast_vote") ->
        ev = find_event(events, "cast_vote")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        target_id = get(p, "target_id", "?")
        "#{player_id} votes to eject #{target_id}"

      true ->
        "Round #{ctx.round} — #{String.capitalize(ctx.phase)} phase"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp alert_color("critical"), do: @red
  defp alert_color("warning"), do: @yellow
  defp alert_color(_), do: @green

  defp compute_alert_level(systems) when is_map(systems) do
    min_health =
      systems
      |> Map.values()
      |> Enum.map(fn s ->
        case s do
          %{health: h} -> h
          %{"health" => h} -> h
          _ -> 100
        end
      end)
      |> Enum.min(fn -> 100 end)

    cond do
      min_health <= 20 -> "critical"
      min_health <= 50 -> "warning"
      true -> "normal"
    end
  end

  defp compute_alert_level(_), do: "normal"

  defp role_color("saboteur", true), do: @purple
  defp role_color("engineer", _), do: @cyan
  defp role_color("captain", _), do: @yellow
  defp role_color("saboteur", _), do: @text_secondary
  defp role_color(_, _), do: @text_secondary

  defp role_badge("engineer"), do: "ENG"
  defp role_badge("captain"), do: "CPT"
  defp role_badge("saboteur"), do: "CRW"
  defp role_badge(_), do: "CRW"

  defp role_badge_svg(role, cx, y) do
    color =
      case role do
        "engineer" -> @cyan
        "captain" -> @yellow
        _ -> @text_secondary
      end

    label =
      case role do
        "engineer" -> "ENGINEER"
        "captain" -> "CAPTAIN"
        "saboteur" -> "CREW"
        _ -> "CREW"
      end

    [
      ~s[<rect x="#{cx - 50}" y="#{y}" width="100" height="20" rx="4" fill="#{color}" opacity="0.15"/>\n],
      ~s[<text x="#{cx}" y="#{y + 14}" text-anchor="middle" font-size="11" font-weight="700" fill="#{color}">#{label}</text>\n]
    ]
  end

  defp wrap_text(text, max_chars) when is_binary(text) do
    words = String.split(text, " ")

    {lines, current} =
      Enum.reduce(words, {[], ""}, fn word, {lines, current} ->
        candidate = if current == "", do: word, else: current <> " " <> word

        if String.length(candidate) > max_chars and current != "" do
          {lines ++ [current], word}
        else
          {lines, candidate}
        end
      end)

    if current != "", do: lines ++ [current], else: lines
  end

  defp wrap_text(other, _), do: [to_string(other)]

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
