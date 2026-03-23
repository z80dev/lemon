defmodule LemonSim.Examples.IntelNetwork.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (spy/cyber theme)
  # ---------------------------------------------------------------------------
  @bg "#080c10"
  @panel_bg "#0f1520"
  @panel_border "#1e2d40"

  @cyan "#00d4ff"
  @cyan_dim "#0a5f6e"

  @text_primary "#e0eaf4"
  @text_secondary "#7a9ab5"
  @text_dim "#334455"

  # Player colors (up to 8 agents)
  @player_colors [
    "#00d4ff",
    "#27ae60",
    "#f39c12",
    "#e74c3c",
    "#8e44ad",
    "#16a085",
    "#2980b9",
    "#c0392b"
  ]

  @mole_color "#ff4757"

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 320
  @net_w 280

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
    adjacency = get(world, "adjacency", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 8)
    phase = get(world, "phase", "intel_briefing")
    message_log = get(world, "message_log", %{})
    suspicion_board = get(world, "suspicion_board", %{})
    operations_log = get(world, "operations_log", [])
    leaked_intel = get(world, "leaked_intel", [])
    intel_pool = get(world, "intel_pool", [])
    winner = get(world, "winner", nil)
    active_actor = get(world, "active_actor_id", nil)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      turn_order: turn_order,
      adjacency: adjacency,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      message_log: message_log,
      suspicion_board: suspicion_board,
      operations_log: operations_log,
      leaked_intel: leaked_intel,
      intel_pool: intel_pool,
      winner: winner,
      active_actor: active_actor
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_agent_roster(ctx),
      render_center_content(ctx),
      render_network_panel(ctx),
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
      <filter id="mole-glow">
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
      .agent-name { font-family: sans-serif; font-weight: 600; }
      .codename { font-family: 'Courier New', Courier, monospace; font-weight: 700; }
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
        "DEBRIEF"
      else
        "Round #{ctx.round}/#{ctx.max_rounds}"
      end

    phase_text =
      if type not in ["init", "game_over"] do
        ctx.phase |> String.replace("_", " ") |> String.upcase()
      else
        ""
      end

    leaked_count = length(ctx.leaked_intel)

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="20" fill="#{@cyan}">INTELLIGENCE NETWORK</text>\n],
      # Round info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      # Phase badge
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 130}" y="14" width="140" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 200}" y="32" text-anchor="middle" font-size="11" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(phase_text)}</text>\n]
      else
        ""
      end,
      # Leaked intel counter
      if leaked_count > 0 do
        ~s[<text x="#{w - 20}" y="28" class="header-text" font-size="12" ] <>
          ~s[text-anchor="end" fill="#{@mole_color}">LEAKED: #{leaked_count}/5</text>\n]
      else
        ~s[<text x="#{w - 20}" y="28" class="header-text" font-size="10" ] <>
          ~s[text-anchor="end" fill="#{@text_dim}">LEAKED: 0/5</text>\n]
      end,
      # Step
      ~s[<text x="#{w - 20}" y="50" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Agent roster (left panel)
  # ---------------------------------------------------------------------------

  defp render_agent_roster(%{h: h, turn_order: turn_order, players: players} = ctx) do
    panel_h = h - @header_h - @footer_h

    agent_entries =
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {pid, idx} ->
        player = Map.get(players, pid, %{})
        color = Enum.at(@player_colors, idx, @text_primary)
        render_agent_card(pid, player, idx, color, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@cyan_dim}">FIELD AGENTS</text>\n],
      agent_entries
    ]
  end

  defp render_agent_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 118
    codename = get(player, "codename", format_player_name(pid))
    role = get(player, "role", "operative")
    fragments = get(player, "intel_fragments", [])
    fragment_count = if is_list(fragments), do: length(fragments), else: 0
    is_active = ctx.active_actor == pid
    is_winner = ctx.winner == pid or (role == "operative" and ctx.winner == "loyalists")
    is_mole = role == "mole"

    # Show mole indicator only in game_over frame or if role is revealed
    reveal_mole = ctx.type == "game_over" and is_mole

    suspicion_count = length(Map.get(ctx.suspicion_board, pid, []))

    display_color = if reveal_mole, do: @mole_color, else: color

    highlight =
      cond do
        is_winner and is_mole ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="112" ] <>
            ~s[fill="#{@mole_color}" opacity="0.15" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="112" ] <>
            ~s[fill="none" stroke="#{@mole_color}" stroke-width="2" rx="6"/>\n]

        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="112" ] <>
            ~s[fill="#{@cyan}" opacity="0.1" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="112" ] <>
            ~s[fill="none" stroke="#{@cyan}" stroke-width="2" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="112" ] <>
            ~s[fill="#{display_color}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="112" ] <>
            ~s[fill="none" stroke="#{display_color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    intel_pool_size = length(ctx.intel_pool)
    bar_w = @roster_w - 40

    intel_fill_w =
      if intel_pool_size > 0,
        do: round(bar_w * min(fragment_count / intel_pool_size, 1.0)),
        else: 0

    [
      highlight,
      ~s[<g>\n],
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{display_color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="codename" font-size="13" fill="#{display_color}">#{esc(codename)}</text>\n],
      if reveal_mole do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 14}" text-anchor="end" font-size="10" font-weight="700" ] <>
          ~s[fill="#{@mole_color}" filter="url(#mole-glow)">MOLE</text>\n]
      else
        ~s[<text x="#{@roster_w - 16}" y="#{y + 14}" text-anchor="end" font-size="10" ] <>
          ~s[fill="#{@text_dim}">#{esc(format_player_name(pid))}</text>\n]
      end,
      # Intel bar
      ~s[<text x="16" y="#{y + 36}" font-size="10" fill="#{@text_secondary}">Intel</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 36}" text-anchor="end" font-size="10" fill="#{@cyan_dim}">#{fragment_count}/#{intel_pool_size}</text>\n],
      ~s[<rect x="16" y="#{y + 42}" width="#{bar_w}" height="7" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="16" y="#{y + 42}" width="#{max(intel_fill_w, 0)}" height="7" fill="#{display_color}" rx="3" opacity="0.8"/>\n],
      # Suspicion bar
      ~s[<text x="16" y="#{y + 66}" font-size="10" fill="#{@text_secondary}">Suspicion</text>\n],
      if suspicion_count > 0 do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 66}" text-anchor="end" font-size="10" fill="#{@mole_color}">#{suspicion_count} reports</text>\n]
      else
        ~s[<text x="#{@roster_w - 16}" y="#{y + 66}" text-anchor="end" font-size="10" fill="#{@text_dim}">none</text>\n]
      end,
      # Winner/active badge
      status_badge(pid, is_mole, is_winner, is_active, ctx.type, y, display_color),
      ~s[</g>\n]
    ]
  end

  defp status_badge(_pid, _is_mole, true, _is_active, "game_over", y, color) do
    ~s[<text x="#{@roster_w - 16}" y="#{y + 88}" text-anchor="end" font-size="11" ] <>
      ~s[font-weight="700" fill="#{color}" filter="url(#glow)">WINNER</text>\n]
  end

  defp status_badge(_pid, _is_mole, _is_winner, true, _type, y, color) do
    ~s[<text x="#{@roster_w - 16}" y="#{y + 88}" text-anchor="end" font-size="10" ] <>
      ~s[fill="#{color}" opacity="0.7">ACTIVE</text>\n]
  end

  defp status_badge(_pid, _is_mole, _is_winner, _is_active, _type, _y, _color), do: ""

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

  defp render_init_card(%{w: w, h: h, turn_order: turn_order}) do
    cx = @roster_w + div(w - @roster_w - @net_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = length(turn_order)

    [
      ~s[<rect x="#{cx - 240}" y="#{cy - 150}" width="480" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@cyan}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@cyan}">INTELLIGENCE NETWORK</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 58}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Compartmentalized information &#x26; trust chains</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 20}" text-anchor="middle" font-size="15" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Agents &#xB7; Cell Network Topology</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 14}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">One agent is the mole — survive or be discovered</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 44}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">Mole wins: survive undetected OR leak 5+ fragments</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 74}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">Loyalists win: majority vote identifies the mole</text>\n],
      ~s[<line x1="#{cx - 120}" y1="#{cy + 102}" x2="#{cx + 120}" y2="#{cy + 102}" ] <>
        ~s[stroke="#{@cyan_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 124}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Briefing &#xB7; Communication &#xB7; Analysis &#xB7; Operation &#xB7; Mole Action</text>\n]
    ]
  end

  defp render_game_over_card(
         %{w: w, h: h, turn_order: turn_order, players: players, winner: winner} = ctx
       ) do
    cx = @roster_w + div(w - @roster_w - @net_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    mole_id = find_mole_id(players)
    loyalists_won = winner == "loyalists"

    sorted =
      turn_order
      |> Enum.map(fn pid ->
        player = Map.get(players, pid, %{})
        fragments = length(get(player, "intel_fragments", []))
        role = get(player, "role", "operative")
        {pid, fragments, role}
      end)
      |> Enum.sort_by(fn {_, fragments, _} -> -fragments end)

    card_h = 100 + length(sorted) * 48

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@cyan}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 36}" text-anchor="middle" class="title" ] <>
        ~s[font-size="24" fill="#{@cyan}">MISSION COMPLETE</text>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 60}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{if loyalists_won, do: @cyan, else: @mole_color}">#{if loyalists_won, do: "NETWORK STANDS — MOLE IDENTIFIED", else: "NETWORK COMPROMISED"}</text>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 80}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">Leaked Intel: #{length(ctx.leaked_intel)}/5</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, fragments, role}, rank} ->
        sy = cy - div(card_h, 2) + 96 + rank * 48
        is_mole_player = pid == mole_id
        display_color = if is_mole_player, do: @mole_color, else: @cyan
        player_idx = Enum.find_index(turn_order, &(&1 == pid)) || 0

        player_color =
          if is_mole_player,
            do: @mole_color,
            else: Enum.at(@player_colors, player_idx, @text_primary)

        player = Map.get(players, pid, %{})
        codename = get(player, "codename", format_player_name(pid))

        [
          if is_mole_player do
            ~s[<rect x="#{cx - 260}" y="#{sy - 16}" width="520" height="40" ] <>
              ~s[fill="#{@mole_color}" opacity="0.1" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 4}" font-size="11" fill="#{@text_dim}">##{rank + 1}</text>\n],
          ~s[<circle cx="#{cx - 195}" cy="#{sy}" r="5" fill="#{player_color}"/>\n],
          ~s[<text x="#{cx - 180}" y="#{sy + 5}" class="codename" font-size="14" fill="#{display_color}">#{esc(codename)}</text>\n],
          ~s[<text x="#{cx + 60}" y="#{sy + 5}" text-anchor="end" font-size="16" fill="#{display_color}">#{fragments}</text>\n],
          ~s[<text x="#{cx + 70}" y="#{sy + 5}" font-size="10" fill="#{@text_dim}">fragments</text>\n],
          if is_mole_player do
            ~s[<text x="#{cx + 220}" y="#{sy + 5}" text-anchor="end" font-size="12" font-weight="700" fill="#{@mole_color}" filter="url(#mole-glow)">THE MOLE</text>\n]
          else
            ~s[<text x="#{cx + 220}" y="#{sy + 5}" text-anchor="end" font-size="11" fill="#{@text_secondary}">operative</text>\n]
          end
        ]
      end)
    ]
  end

  defp render_phase_content(ctx) do
    case ctx.phase do
      "intel_briefing" -> render_briefing_panel(ctx)
      "communication" -> render_communication_panel(ctx)
      "analysis" -> render_analysis_panel(ctx)
      "operation" -> render_operations_panel(ctx)
      "mole_action" -> render_mole_action_panel(ctx)
      _ -> render_briefing_panel(ctx)
    end
  end

  defp render_briefing_panel(%{w: w, h: h} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @net_w - 20
    panel_h = h - @header_h - @footer_h - 20

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@cyan_dim}">INTEL BRIEFING</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
        ~s[font-size="12" fill="#{@text_dim}">Agents receiving new intel assignments...</text>\n],
      if ctx.active_actor do
        actor_idx = Enum.find_index(ctx.turn_order, &(&1 == ctx.active_actor)) || 0
        actor_color = Enum.at(@player_colors, actor_idx, @text_secondary)
        actor_player = Map.get(ctx.players, ctx.active_actor, %{})
        actor_codename = get(actor_player, "codename", format_player_name(ctx.active_actor))

        [
          ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
            ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
          ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
            ~s[font-size="12" fill="#{actor_color}">#{esc(actor_codename)} acknowledging briefing...</text>\n]
        ]
      else
        ""
      end
    ]
  end

  defp render_communication_panel(
         %{w: w, h: h, message_log: message_log, turn_order: turn_order, players: players} = ctx
       ) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @net_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_messages =
      message_log
      |> Map.values()
      |> List.flatten()
      |> Enum.sort_by(fn m -> get(m, "round", 0) end)
      |> Enum.take(-12)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@cyan_dim}">SECURE TRANSMISSIONS</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_messages == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No transmissions yet</text>\n]
      else
        recent_messages
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          my = panel_y + 48 + idx * 32

          from_id = get(msg, "from", "?")
          to_id = get(msg, "to", "?")
          round = get(msg, "round", "?")

          from_idx = Enum.find_index(turn_order, &(&1 == from_id)) || 0
          to_idx = Enum.find_index(turn_order, &(&1 == to_id)) || 0

          from_color = Enum.at(@player_colors, from_idx, @text_secondary)
          to_color = Enum.at(@player_colors, to_idx, @text_secondary)

          from_codename =
            get(Map.get(players, from_id, %{}), "codename", format_player_name(from_id))

          to_codename = get(Map.get(players, to_id, %{}), "codename", format_player_name(to_id))

          is_recent = idx >= length(recent_messages) - 3
          opacity = if is_recent, do: "1", else: "0.5"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{my + 8}" r="5" fill="#{from_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{from_color}">#{esc(from_codename)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{my + 12}" text-anchor="middle" font-size="10" fill="#{@text_dim}">&#x25BA; R#{round}</text>\n],
            ~s[<circle cx="#{panel_x + panel_w - 70}" cy="#{my + 8}" r="5" fill="#{to_color}"/>\n],
            ~s[<text x="#{panel_x + panel_w - 60}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{to_color}">#{esc(to_codename)}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{my + 22}" x2="#{panel_x + panel_w - 16}" y2="#{my + 22}" stroke="#{@panel_border}" stroke-width="1" opacity="0.4"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      active_agent_bar(ctx, panel_x, panel_y, panel_w, panel_h, "transmitting...")
    ]
  end

  defp render_analysis_panel(%{w: w, h: h} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @net_w - 20
    panel_h = h - @header_h - @footer_h - 20

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@cyan_dim}">FIELD ANALYSIS</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
        ~s[font-size="12" fill="#{@text_dim}">Agents recording private assessment notes...</text>\n],
      active_agent_bar(ctx, panel_x, panel_y, panel_w, panel_h, "analyzing intel...")
    ]
  end

  defp render_operations_panel(
         %{w: w, h: h, operations_log: operations_log, turn_order: turn_order, players: players} =
           ctx
       ) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @net_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_ops = Enum.take(operations_log, -12)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@cyan_dim}">OPERATIONS LOG</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_ops == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No operations logged</text>\n]
      else
        recent_ops
        |> Enum.with_index()
        |> Enum.map(fn {op, idx} ->
          oy = panel_y + 48 + idx * 28
          player_id = get(op, :player_id, get(op, "player_id", "?"))
          op_type = get(op, :operation_type, get(op, "operation_type", "?"))
          target = get(op, :target_id, get(op, "target_id", "?"))

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, @text_secondary)
          player_data = Map.get(players, player_id, %{})
          codename = get(player_data, "codename", format_player_name(player_id))
          op_color = operation_color(op_type)
          op_arrow = operation_icon(op_type)

          [
            ~s[<circle cx="#{panel_x + 22}" cy="#{oy + 8}" r="4" fill="#{player_color}" opacity="0.8"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{oy + 12}" font-size="10" fill="#{player_color}">#{esc(codename)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{oy + 12}" text-anchor="middle" font-size="10" font-weight="700" fill="#{op_color}">#{op_arrow} #{esc(String.upcase(String.replace(op_type, "_", " ")))}</text>\n],
            ~s[<text x="#{panel_x + panel_w - 16}" y="#{oy + 12}" text-anchor="end" font-size="10" fill="#{@text_secondary}">#{esc(inspect(target))}</text>\n]
          ]
        end)
      end,
      active_agent_bar(ctx, panel_x, panel_y, panel_w, panel_h, "performing operations...")
    ]
  end

  defp render_mole_action_panel(%{w: w, h: h, leaked_intel: leaked_intel} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @net_w - 20
    panel_h = h - @header_h - @footer_h - 20

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@mole_color}" stroke-width="1" opacity="0.8"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@mole_color}">CLANDESTINE OPERATION</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@mole_color}" stroke-width="1" opacity="0.3"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
        ~s[font-size="14" fill="#{@mole_color}">The mole is acting in secret...</text>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 110}" text-anchor="middle" ] <>
        ~s[font-size="11" fill="#{@text_dim}">Loyal operatives cannot see this activity</text>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 150}" text-anchor="middle" ] <>
        ~s[font-size="12" fill="#{@text_secondary}">Intel leaked so far: #{length(leaked_intel)}/5</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Network panel (right panel)
  # ---------------------------------------------------------------------------

  defp render_network_panel(
         %{w: w, h: h, adjacency: adjacency, turn_order: turn_order, players: players} = ctx
       ) do
    panel_x = w - @net_w
    panel_h = h - @header_h - @footer_h

    agent_entries =
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {pid, idx} ->
        player = Map.get(players, pid, %{})
        color = Enum.at(@player_colors, idx, @text_primary)
        neighbors = Map.get(adjacency, pid, [])
        suspicion = length(Map.get(ctx.suspicion_board, pid, []))

        ny = @header_h + 40 + idx * 28
        is_mole = get(player, "role", "operative") == "mole" and ctx.type == "game_over"
        display_color = if is_mole, do: @mole_color, else: color
        codename = get(player, "codename", format_player_name(pid))

        [
          ~s[<rect x="#{panel_x + 8}" y="#{ny - 10}" width="#{@net_w - 16}" height="22" ] <>
            ~s[fill="#{display_color}" opacity="#{if ctx.active_actor == pid, do: "0.15", else: "0.06"}" rx="3"/>\n],
          ~s[<circle cx="#{panel_x + 20}" cy="#{ny + 2}" r="4" fill="#{display_color}"/>\n],
          ~s[<text x="#{panel_x + 30}" y="#{ny + 6}" font-size="10" fill="#{display_color}">#{esc(codename)}</text>\n],
          ~s[<text x="#{panel_x + @net_w - 16}" y="#{ny + 6}" text-anchor="end" font-size="9" fill="#{@text_dim}">#{length(neighbors)} conn</text>\n],
          if suspicion > 0 do
            ~s[<circle cx="#{panel_x + @net_w - 26}" cy="#{ny + 2}" r="4" fill="#{@mole_color}" opacity="0.7"/>\n] <>
              ~s[<text x="#{panel_x + @net_w - 26}" y="#{ny + 6}" text-anchor="middle" font-size="8" font-weight="700" fill="#{@bg}">#{suspicion}</text>\n]
          else
            ""
          end
        ]
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@net_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@net_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@net_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@cyan_dim}">NETWORK NODES</text>\n],
      agent_entries,
      if map_size(adjacency) == 0 do
        ~s[<text x="#{panel_x + div(@net_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No network</text>\n]
      else
        ""
      end
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
        player_count = length(ctx.turn_order)
        "#{player_count} agents deployed — one is the mole. Trust no one."

      ctx.type == "game_over" ->
        mole_id = find_mole_id(ctx.players)
        players = ctx.players
        player = Map.get(players, mole_id, %{})
        codename = get(player, "codename", format_player_name(mole_id))

        if ctx.winner == "loyalists" do
          "Network secured! #{codename} was the mole — identified by majority vote."
        else
          "Network compromised! The mole #{codename} evaded detection."
        end

      has_event?(events, "intel_leaked") ->
        ev = find_event(events, "intel_leaked")
        p = get(ev, "payload", ev || %{})
        fragment = get(p, "fragment_id", "unknown fragment")
        "ALERT: Intel #{fragment} has been leaked to the adversary!"

      has_event?(events, "agent_framed") ->
        ev = find_event(events, "agent_framed")
        p = get(ev, "payload", ev || %{})
        target = get(p, "target_id", "?")
        "Mole planted false evidence against #{target}"

      has_event?(events, "suspicion_flagged") ->
        ev = find_event(events, "suspicion_flagged")
        p = get(ev, "payload", ev || %{})
        suspect = get(p, "suspect_id", "?")
        "Suspicion reported against agent #{suspect}"

      has_event?(events, "operation_completed") ->
        ev = find_event(events, "operation_completed")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        op_type = get(p, "operation_type", "?")
        "#{format_player_name(player_id)} performed #{String.replace(op_type, "_", " ")}"

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins — new intel briefing phase"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        from = get(p, "from", "?") |> String.replace("_", " ")
        to = get(p, "to", "?") |> String.replace("_", " ")
        "Phase transition: #{from} -> #{to}"

      has_event?(events, "message_delivered") ->
        ev = find_event(events, "message_delivered")
        p = get(ev, "payload", ev || %{})
        sender = get(p, "sender_id", "?")
        recipient = get(p, "recipient_id", "?")
        "Encrypted message: #{format_player_name(sender)} -> #{format_player_name(recipient)}"

      true ->
        case ctx.phase do
          "intel_briefing" -> "Distributing classified intel assignments..."
          "communication" -> "Secure communications in progress..."
          "analysis" -> "Agents conducting private analysis..."
          "operation" -> "Operations being planned and executed..."
          "mole_action" -> "Clandestine activity detected..."
          _ -> ""
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp active_agent_bar(ctx, panel_x, panel_y, panel_w, panel_h, action) do
    if ctx.active_actor do
      actor_idx = Enum.find_index(ctx.turn_order, &(&1 == ctx.active_actor)) || 0
      actor_color = Enum.at(@player_colors, actor_idx, @text_secondary)
      actor_player = Map.get(ctx.players, ctx.active_actor, %{})
      actor_codename = get(actor_player, "codename", format_player_name(ctx.active_actor))

      [
        ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
          ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{actor_color}">#{esc(actor_codename)} is #{action}</text>\n]
      ]
    else
      ""
    end
  end

  defp find_mole_id(players) do
    case Enum.find(players, fn {_id, p} -> get(p, "role", "operative") == "mole" end) do
      {id, _} -> id
      nil -> nil
    end
  end

  defp phase_color("intel_briefing"), do: "#2980b9"
  defp phase_color("communication"), do: "#00d4ff"
  defp phase_color("analysis"), do: "#f39c12"
  defp phase_color("operation"), do: "#27ae60"
  defp phase_color("mole_action"), do: @mole_color
  defp phase_color(_), do: @text_secondary

  defp operation_color("share_intel"), do: "#27ae60"
  defp operation_color("relay_message"), do: "#2980b9"
  defp operation_color("verify_agent"), do: "#f39c12"
  defp operation_color("report_suspicion"), do: @mole_color
  defp operation_color(_), do: @text_secondary

  defp operation_icon("share_intel"), do: "&#x2B06;"
  defp operation_icon("relay_message"), do: "&#x21C4;"
  defp operation_icon("verify_agent"), do: "&#x2714;"
  defp operation_icon("report_suspicion"), do: "&#x26A0;"
  defp operation_icon(_), do: "&#x3F;"

  defp format_player_name(nil), do: "?"
  defp format_player_name("agent_" <> n), do: "Agent #{n}"
  defp format_player_name(name) when is_binary(name), do: name
  defp format_player_name(_), do: "?"

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
