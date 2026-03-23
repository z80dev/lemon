defmodule LemonSim.Examples.MurderMystery.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (gothic mystery theme)
  # ---------------------------------------------------------------------------
  @bg "#0d0a0e"
  @panel_bg "#1a1520"
  @panel_border "#3d2f4a"

  @gold "#d4af37"
  @gold_dim "#7a6520"

  @text_primary "#e2e0f0"
  @text_secondary "#9c8faa"
  @text_dim "#5a4f6a"

  # Player colors (up to 6 players)
  @player_colors ["#c0392b", "#2980b9", "#27ae60", "#f39c12", "#8e44ad", "#16a085"]

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 300
  @clue_map_w 320

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
    rooms = get(world, "rooms", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 5)
    phase = get(world, "phase", "investigation")
    winner = get(world, "winner", nil)
    active_actor = get(world, "active_actor_id", nil)
    interrogation_log = get(world, "interrogation_log", [])
    discussion_log = get(world, "discussion_log", [])
    accusations = get(world, "accusations", [])
    planted_evidence = get(world, "planted_evidence", [])
    destroyed_evidence = get(world, "destroyed_evidence", [])

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      turn_order: turn_order,
      rooms: rooms,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      winner: winner,
      active_actor: active_actor,
      interrogation_log: interrogation_log,
      discussion_log: discussion_log,
      accusations: accusations,
      planted_evidence: planted_evidence,
      destroyed_evidence: destroyed_evidence
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_roster(ctx),
      render_center_content(ctx),
      render_room_map(ctx),
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
      <filter id="subtle-glow">
        <feGaussianBlur stdDeviation="1.5" result="blur"/>
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
      .guest-name { font-family: sans-serif; font-weight: 700; font-style: italic; }
      .room-text { font-family: sans-serif; font-weight: 600; }
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
        "CASE CLOSED"
      else
        "Round #{ctx.round}/#{ctx.max_rounds}"
      end

    phase_text =
      if type not in ["init", "game_over"] do
        phase_label(ctx.phase)
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@gold}">MURDER MYSTERY</text>\n],
      # Round info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      # Phase badge
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 120}" y="14" width="140" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 190}" y="32" text-anchor="middle" font-size="12" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(String.upcase(phase_text))}</text>\n]
      else
        ""
      end,
      # Step counter
      ~s[<text x="#{w - 20}" y="18" class="header-text" font-size="10" ] <>
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
        color = Enum.at(@player_colors, idx, "#e2e0f0")
        render_player_card(pid, player, idx, color, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">SUSPECTS</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 152
    guest_name = get(player, "name", pid)
    alibi = get(player, "alibi", "unknown whereabouts")
    role = get(player, "role", "investigator")
    clues_found = get(player, "clues_found", [])
    clue_count = length(clues_found)
    acc_remaining = get(player, "accusations_remaining", 1)

    is_active = ctx.active_actor == pid
    is_winner_side = winner_side_match?(ctx.winner, role)
    is_game_over = ctx.type == "game_over"

    display_name = format_player_name(pid)

    highlight =
      cond do
        is_game_over and is_winner_side ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="146" ] <>
            ~s[fill="#{@gold}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="146" ] <>
            ~s[fill="none" stroke="#{@gold}" stroke-width="1.5" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="146" ] <>
            ~s[fill="#{color}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="146" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    # Clue progress bar (out of 6 total clues as rough max)
    bar_w = @roster_w - 40
    clue_fill_w = round(bar_w * min(clue_count / 6, 1.0))

    role_color = if role == "killer" and is_game_over, do: "#c0392b", else: color
    role_label = if role == "killer" and is_game_over, do: "KILLER", else: "investigator"
    acc_color = if acc_remaining > 0, do: "#27ae60", else: "#c0392b"

    [
      highlight,
      # Guest name with color dot
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="guest-name" font-size="13" fill="#{color}">#{esc(guest_name)}</text>\n],
      # Player ID
      ~s[<text x="36" y="#{y + 30}" class="player-name" font-size="11" fill="#{@text_secondary}">#{esc(display_name)}</text>\n],
      # Role badge (killer revealed on game over)
      if is_game_over and role == "killer" do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 14}" text-anchor="end" font-size="10" font-weight="700" fill="#{role_color}" filter="url(#glow)">#{role_label}</text>\n]
      else
        ""
      end,
      # Alibi
      ~s[<text x="16" y="#{y + 48}" font-size="9" fill="#{@text_dim}" font-style="italic">#{esc(String.slice(alibi, 0, 32))}</text>\n],
      # Clue count bar
      ~s[<text x="16" y="#{y + 68}" font-size="10" fill="#{@text_secondary}">Clues Found</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 68}" text-anchor="end" font-size="10" fill="#{@gold_dim}">#{clue_count}</text>\n],
      ~s[<rect x="16" y="#{y + 74}" width="#{bar_w}" height="6" fill="#{@panel_bg}" rx="2"/>\n],
      ~s[<rect x="16" y="#{y + 74}" width="#{max(clue_fill_w, 0)}" height="6" fill="#{color}" rx="2" opacity="0.8"/>\n],
      # Accusations remaining
      ~s[<text x="16" y="#{y + 98}" font-size="10" fill="#{@text_secondary}">Accusations: </text>\n] <>
        ~s[<text x="108" y="#{y + 98}" font-size="10" font-weight="700" fill="#{acc_color}">#{acc_remaining}</text>\n]
    ]
  end

  defp winner_side_match?("investigators", "investigator"), do: true
  defp winner_side_match?("killer", "killer"), do: true
  defp winner_side_match?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Center content
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "game_over" -> render_game_over_card(ctx)
      _ -> render_phase_panel(ctx)
    end
  end

  defp render_init_card(%{w: w, h: h, turn_order: turn_order, rooms: rooms}) do
    cx = @roster_w + div(w - @roster_w - @clue_map_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = length(turn_order)
    room_count = map_size(rooms)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@gold}">MURDER MYSTERY</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 58}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">A deduction game of clues, lies, and accusation</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Suspects &#xB7; #{room_count} Rooms</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 24}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Win: Correctly identify the killer, weapon &amp; room</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 54}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Killer wins by surviving all rounds undetected</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@gold_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 102}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Investigate &#xB7; Interrogate &#xB7; Deduce</text>\n]
    ]
  end

  defp render_game_over_card(
         %{w: w, h: h, turn_order: turn_order, winner: winner, players: players} = ctx
       ) do
    cx = @roster_w + div(w - @roster_w - @clue_map_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    sorted =
      turn_order
      |> Enum.map(fn pid ->
        player = Map.get(players, pid, %{})
        clues = length(get(player, "clues_found", []))
        role = get(player, "role", "investigator")
        {pid, clues, role}
      end)
      |> Enum.sort_by(fn {_, clues, _} -> -clues end)

    card_h = 100 + length(sorted) * 50

    winner_title =
      case winner do
        "investigators" -> "INVESTIGATORS WIN"
        "killer" -> "KILLER ESCAPES"
        _ -> "CASE CLOSED"
      end

    winner_color =
      case winner do
        "investigators" -> "#27ae60"
        "killer" -> "#c0392b"
        _ -> @gold
      end

    # Reveal the solution
    solution = get(ctx.players, "solution", %{})
    _ = solution

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{winner_color}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 42}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{winner_color}" filter="url(#glow)">#{esc(winner_title)}</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, clues, role}, rank} ->
        sy = cy - div(card_h, 2) + 78 + rank * 50
        is_winner_side = winner_side_match?(winner, role)
        color = if is_winner_side, do: winner_color, else: @text_primary
        rank_label = "##{rank + 1}"

        player = Map.get(players, pid, %{})
        guest_name = get(player, "name", pid)
        role_tag = if role == "killer", do: " [KILLER]", else: ""

        winner_badge =
          if is_winner_side do
            ~s[<text x="#{cx + 240}" y="#{sy + 6}" text-anchor="end" font-size="12" ] <>
              ~s[font-weight="700" fill="#{winner_color}" filter="url(#glow)">WON</text>\n]
          else
            ""
          end

        [
          if is_winner_side do
            ~s[<rect x="#{cx - 260}" y="#{sy - 18}" width="520" height="44" ] <>
              ~s[fill="#{winner_color}" opacity="0.07" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 240}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">#{rank_label}</text>\n],
          ~s[<text x="#{cx - 200}" y="#{sy + 6}" class="guest-name" font-size="16" fill="#{color}">#{esc(guest_name)}#{esc(role_tag)}</text>\n],
          ~s[<text x="#{cx + 80}" y="#{sy + 6}" text-anchor="end" font-size="20" fill="#{color}">#{clues}</text>\n],
          ~s[<text x="#{cx + 90}" y="#{sy + 6}" font-size="12" fill="#{@text_dim}">clues</text>\n],
          ~s[<text x="#{cx - 200}" y="#{sy + 22}" font-size="9" fill="#{@text_dim}">#{esc(format_player_name(pid))}</text>\n],
          winner_badge
        ]
      end)
    ]
  end

  defp render_phase_panel(ctx) do
    case ctx.phase do
      "investigation" -> render_investigation_panel(ctx)
      "interrogation" -> render_interrogation_panel(ctx)
      "discussion" -> render_discussion_panel(ctx)
      "killer_action" -> render_killer_action_panel(ctx)
      "deduction_vote" -> render_deduction_panel(ctx)
      _ -> render_investigation_panel(ctx)
    end
  end

  defp center_panel_bounds(%{w: w, h: h}) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @clue_map_w - 20
    panel_h = h - @header_h - @footer_h - 20
    {panel_x, panel_y, panel_w, panel_h}
  end

  defp render_investigation_panel(
         %{events: events, turn_order: turn_order, players: players} = ctx
       ) do
    {panel_x, panel_y, panel_w, panel_h} = center_panel_bounds(ctx)

    recent_searches =
      events
      |> Enum.filter(fn ev ->
        kind = get(ev, "kind", get(ev, :kind, ""))
        kind == "room_searched"
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">INVESTIGATION PHASE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_searches == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Suspects searching the mansion...</text>\n]
      else
        recent_searches
        |> Enum.with_index()
        |> Enum.take(12)
        |> Enum.map(fn {ev, idx} ->
          ey = panel_y + 50 + idx * 36
          payload = get(ev, "payload", get(ev, :payload, %{}))
          player_id = get(payload, "player_id", "?")
          room_id = get(payload, "room_id", "?")

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, @text_secondary)
          player = Map.get(players, player_id, %{})
          guest_name = get(player, "name", format_player_name(player_id))

          [
            ~s[<circle cx="#{panel_x + 22}" cy="#{ey + 8}" r="5" fill="#{player_color}"/>\n],
            ~s[<text x="#{panel_x + 34}" y="#{ey + 13}" font-size="12" font-weight="600" fill="#{player_color}">#{esc(guest_name)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{ey + 13}" text-anchor="middle" font-size="11" fill="#{@text_dim}">searched</text>\n],
            ~s[<text x="#{panel_x + panel_w - 16}" y="#{ey + 13}" text-anchor="end" font-size="12" fill="#{@gold}">#{esc(String.capitalize(room_id))}</text>\n]
          ]
        end)
      end,
      # Active player indicator
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is searching...")
    ]
  end

  defp render_interrogation_panel(
         %{interrogation_log: interrogation_log, turn_order: turn_order, players: players} = ctx
       ) do
    {panel_x, panel_y, panel_w, panel_h} = center_panel_bounds(ctx)

    recent_qa =
      interrogation_log
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">INTERROGATION PHASE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_qa == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Awaiting interrogations...</text>\n]
      else
        recent_qa
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          ey = panel_y + 48 + idx * 62

          asker_id = Map.get(entry, "asker_id", "?")
          target_id = Map.get(entry, "target_id", "?")
          question = Map.get(entry, "question", "")
          answer = Map.get(entry, "answer", nil)

          asker_idx = Enum.find_index(turn_order, &(&1 == asker_id)) || 0
          target_idx = Enum.find_index(turn_order, &(&1 == target_id)) || 0
          asker_color = Enum.at(@player_colors, asker_idx, @text_secondary)
          target_color = Enum.at(@player_colors, target_idx, @text_secondary)

          asker_name = get(Map.get(players, asker_id, %{}), "name", format_player_name(asker_id))

          target_name =
            get(Map.get(players, target_id, %{}), "name", format_player_name(target_id))

          [
            ~s[<rect x="#{panel_x + 10}" y="#{ey - 4}" width="#{panel_w - 20}" height="56" ] <>
              ~s[fill="#{@bg}" opacity="0.5" rx="4"/>\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{ey + 10}" r="4" fill="#{asker_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{ey + 15}" font-size="10" font-weight="700" fill="#{asker_color}">#{esc(asker_name)}</text>\n],
            ~s[<text x="#{panel_x + 110}" y="#{ey + 15}" font-size="10" fill="#{@text_dim}">asked</text>\n],
            ~s[<circle cx="#{panel_x + 148}" cy="#{ey + 10}" r="4" fill="#{target_color}"/>\n],
            ~s[<text x="#{panel_x + 158}" y="#{ey + 15}" font-size="10" font-weight="700" fill="#{target_color}">#{esc(target_name)}</text>\n],
            ~s[<text x="#{panel_x + 20}" y="#{ey + 31}" font-size="10" fill="#{@text_secondary}" font-style="italic">Q: #{esc(String.slice(question, 0, 80))}</text>\n],
            if answer do
              ~s[<text x="#{panel_x + 20}" y="#{ey + 47}" font-size="10" fill="#{@text_primary}">A: #{esc(String.slice(answer, 0, 80))}</text>\n]
            else
              ~s[<text x="#{panel_x + 20}" y="#{ey + 47}" font-size="10" fill="#{@text_dim}" font-style="italic">Awaiting answer...</text>\n]
            end
          ]
        end)
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is answering...")
    ]
  end

  defp render_discussion_panel(
         %{discussion_log: discussion_log, turn_order: turn_order, players: players} = ctx
       ) do
    {panel_x, panel_y, panel_w, panel_h} = center_panel_bounds(ctx)

    recent_entries =
      discussion_log
      |> Enum.reverse()
      |> Enum.take(10)
      |> Enum.reverse()

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">DISCUSSION PHASE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_entries == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Discussion not yet started...</text>\n]
      else
        recent_entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          ey = panel_y + 48 + idx * 44

          player_id = Map.get(entry, "player_id", "?")
          entry_type = Map.get(entry, "type", "finding")
          content = Map.get(entry, "content", "")

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, @text_secondary)
          player = Map.get(players, player_id, %{})
          guest_name = get(player, "name", format_player_name(player_id))

          type_color = discussion_type_color(entry_type)

          is_recent = idx >= length(recent_entries) - 3
          opacity = if is_recent, do: "1", else: "0.5"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{ey + 10}" r="5" fill="#{player_color}"/>\n],
            ~s[<text x="#{panel_x + 34}" y="#{ey + 15}" font-size="11" font-weight="600" fill="#{player_color}">#{esc(guest_name)}</text>\n],
            ~s[<text x="#{panel_x + 140}" y="#{ey + 15}" font-size="10" font-weight="700" fill="#{type_color}">#{esc(String.upcase(entry_type))}</text>\n],
            ~s[<text x="#{panel_x + 20}" y="#{ey + 33}" font-size="10" fill="#{@text_secondary}">#{esc(String.slice(content, 0, 90))}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{ey + 40}" x2="#{panel_x + panel_w - 16}" y2="#{ey + 40}" stroke="#{@panel_border}" stroke-width="1" opacity="0.4"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is discussing...")
    ]
  end

  defp render_killer_action_panel(
         %{events: events, turn_order: turn_order, players: _players} = ctx
       ) do
    {panel_x, panel_y, panel_w, panel_h} = center_panel_bounds(ctx)

    action_events =
      events
      |> Enum.filter(fn ev ->
        kind = get(ev, "kind", get(ev, :kind, ""))
        kind in ["evidence_planted", "clue_destroyed"]
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#c0392b" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#c0392b" opacity="0.8">KILLER'S MOVE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#c0392b" stroke-width="1" opacity="0.3"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 70}" text-anchor="middle" ] <>
        ~s[font-size="14" fill="#{@text_secondary}" font-style="italic">The killer acts in secret...</text>\n],
      if action_events != [] do
        action_events
        |> Enum.with_index()
        |> Enum.map(fn {ev, idx} ->
          ey = panel_y + 100 + idx * 40
          kind = get(ev, "kind", get(ev, :kind, ""))
          payload = get(ev, "payload", get(ev, :payload, %{}))
          player_id = get(payload, "player_id", "?")

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, "#c0392b")

          action_text =
            case kind do
              "evidence_planted" ->
                room_id = get(payload, "room_id", "?")
                "Evidence planted in #{String.capitalize(room_id)}"

              "clue_destroyed" ->
                clue_id = get(payload, "clue_id", "?")
                "Clue destroyed: #{clue_id}"

              _ ->
                "Unknown action"
            end

          [
            ~s[<rect x="#{panel_x + 20}" y="#{ey - 6}" width="#{panel_w - 40}" height="30" ] <>
              ~s[fill="#c0392b" opacity="0.08" rx="4"/>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{ey + 13}" text-anchor="middle" ] <>
              ~s[font-size="12" fill="#{player_color}">#{esc(action_text)}</text>\n]
          ]
        end)
      else
        ""
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is acting...", "#c0392b")
    ]
  end

  defp render_deduction_panel(
         %{accusations: accusations, turn_order: turn_order, players: players} = ctx
       ) do
    {panel_x, panel_y, panel_w, panel_h} = center_panel_bounds(ctx)

    recent_accusations =
      accusations
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">DEDUCTION VOTE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_accusations == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Suspects deliberating...</text>\n]
      else
        recent_accusations
        |> Enum.with_index()
        |> Enum.map(fn {accusation, idx} ->
          ay = panel_y + 48 + idx * 54

          player_id = Map.get(accusation, "player_id", "?")
          accused_id = Map.get(accusation, "accused_id", "?")
          weapon = Map.get(accusation, "weapon", "?")
          room_id = Map.get(accusation, "room_id", "?")
          correct = Map.get(accusation, "correct", false)

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, @text_secondary)
          player = Map.get(players, player_id, %{})
          guest_name = get(player, "name", format_player_name(player_id))

          result_color = if correct, do: "#27ae60", else: "#c0392b"
          result_text = if correct, do: "CORRECT", else: "WRONG"
          bg_opacity = if correct, do: "0.12", else: "0.06"
          border_color = if correct, do: "#27ae60", else: "#c0392b"

          [
            ~s[<rect x="#{panel_x + 10}" y="#{ay - 4}" width="#{panel_w - 20}" height="46" ] <>
              ~s[fill="#{border_color}" opacity="#{bg_opacity}" rx="4"/>\n],
            ~s[<circle cx="#{panel_x + 24}" cy="#{ay + 10}" r="5" fill="#{player_color}"/>\n],
            ~s[<text x="#{panel_x + 36}" y="#{ay + 15}" font-size="11" font-weight="700" fill="#{player_color}">#{esc(guest_name)}</text>\n],
            ~s[<text x="#{panel_x + panel_w - 16}" y="#{ay + 15}" text-anchor="end" font-size="11" font-weight="700" fill="#{result_color}">#{result_text}</text>\n],
            ~s[<text x="#{panel_x + 20}" y="#{ay + 35}" font-size="10" fill="#{@text_secondary}">#{esc(accused_id)} &#xB7; #{esc(weapon)} &#xB7; #{esc(room_id)}</text>\n]
          ]
        end)
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is deliberating...")
    ]
  end

  defp render_active_player_bar(
         ctx,
         panel_x,
         panel_y,
         panel_w,
         panel_h,
         action_text,
         color \\ nil
       ) do
    if ctx.active_actor do
      actor_idx = Enum.find_index(ctx.turn_order, &(&1 == ctx.active_actor)) || 0
      actor_color = color || Enum.at(@player_colors, actor_idx, @text_secondary)
      player = Map.get(ctx.players, ctx.active_actor, %{})
      guest_name = get(player, "name", format_player_name(ctx.active_actor))

      [
        ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
          ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{actor_color}">#{esc(guest_name)} #{action_text}</text>\n]
      ]
    else
      ""
    end
  end

  # ---------------------------------------------------------------------------
  # Room map (right panel)
  # ---------------------------------------------------------------------------

  defp render_room_map(%{w: w, h: h, rooms: rooms} = _ctx) do
    panel_x = w - @clue_map_w
    panel_h = h - @header_h - @footer_h

    room_list = [
      "library",
      "ballroom",
      "conservatory",
      "study",
      "kitchen",
      "cellar"
    ]

    room_entries =
      room_list
      |> Enum.with_index()
      |> Enum.map(fn {room_id, idx} ->
        room = Map.get(rooms, room_id, %{})
        room_name = get(room, "name", String.capitalize(room_id))
        clues_present = length(get(room, "clues_present", []))
        searched_by = get(room, "searched_by", [])
        search_count = length(searched_by)

        ry = @header_h + 40 + idx * 80

        clue_color = if clues_present > 0, do: @gold, else: @text_dim
        clue_bg_opacity = if clues_present > 0, do: "0.12", else: "0.04"

        [
          ~s[<rect x="#{panel_x + 8}" y="#{ry - 12}" width="#{@clue_map_w - 16}" height="70" ] <>
            ~s[fill="#{clue_color}" opacity="#{clue_bg_opacity}" rx="6"/>\n],
          ~s[<text x="#{panel_x + div(@clue_map_w, 2)}" y="#{ry + 8}" text-anchor="middle" ] <>
            ~s[font-size="11" font-weight="700" fill="#{clue_color}" letter-spacing="1">#{esc(String.upcase(room_name))}</text>\n],
          ~s[<text x="#{panel_x + div(@clue_map_w, 2)}" y="#{ry + 28}" text-anchor="middle" ] <>
            ~s[font-size="22" font-weight="900" fill="#{clue_color}">#{clues_present}</text>\n],
          ~s[<text x="#{panel_x + div(@clue_map_w, 2)}" y="#{ry + 44}" text-anchor="middle" ] <>
            ~s[font-size="9" fill="#{clue_color}" opacity="0.7">#{if clues_present == 1, do: "clue", else: "clues"}</text>\n],
          if search_count > 0 do
            dots =
              searched_by
              |> Enum.with_index()
              |> Enum.take(6)
              |> Enum.map(fn {pid, i} ->
                cx = panel_x + @clue_map_w - 20 - i * 14

                player_num =
                  case pid do
                    "player_" <> n -> String.to_integer(n) - 1
                    _ -> 0
                  end

                dot_color = Enum.at(@player_colors, player_num, @text_dim)
                ~s[<circle cx="#{cx}" cy="#{ry + 8}" r="5" fill="#{dot_color}" opacity="0.7"/>\n]
              end)

            [dots]
          else
            ""
          end
        ]
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@clue_map_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@clue_map_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@clue_map_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">MANSION ROOMS</text>\n],
      room_entries,
      if rooms == %{} do
        ~s[<text x="#{panel_x + div(@clue_map_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No rooms</text>\n]
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
        "The mystery begins: #{length(ctx.turn_order)} suspects, one killer hiding in plain sight"

      ctx.type == "game_over" ->
        case ctx.winner do
          "investigators" -> "The killer has been unmasked! Justice prevails!"
          "killer" -> "The killer escapes! The case goes cold..."
          _ -> "The case is closed."
        end

      has_event?(events, "accusation_made") ->
        ev = find_event(events, "accusation_made")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        accused_id = get(p, "accused_id", "?")
        correct = get(p, "correct", false)
        player = Map.get(ctx.players, player_id, %{})
        guest_name = get(player, "name", format_player_name(player_id))

        if correct do
          "#{guest_name} correctly accuses #{accused_id} - THE KILLER IS FOUND!"
        else
          "#{guest_name} accuses #{accused_id} - wrong! The investigation continues..."
        end

      has_event?(events, "evidence_planted") ->
        "The killer plants false evidence to mislead the investigators!"

      has_event?(events, "clue_destroyed") ->
        "The killer destroys evidence to cover their tracks!"

      has_event?(events, "room_searched") ->
        ev = find_event(events, "room_searched")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        room_id = get(p, "room_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        guest_name = get(player, "name", format_player_name(player_id))
        "#{guest_name} searches the #{String.capitalize(room_id)}"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        to = get(p, "to", "?")
        "Phase transition: entering #{phase_label(to)}"

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins - new investigation phase"

      true ->
        case ctx.phase do
          "investigation" -> "Suspects fan out across the mansion searching for clues..."
          "interrogation" -> "The questioning begins. Who is lying?"
          "discussion" -> "Suspects share theories and challenge alibis..."
          "killer_action" -> "The killer weighs their options..."
          "deduction_vote" -> "Time to name the killer - who do you accuse?"
          _ -> ""
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("investigation"), do: "#27ae60"
  defp phase_color("interrogation"), do: "#2980b9"
  defp phase_color("discussion"), do: "#f39c12"
  defp phase_color("killer_action"), do: "#c0392b"
  defp phase_color("deduction_vote"), do: "#8e44ad"
  defp phase_color(_), do: @text_secondary

  defp phase_label("investigation"), do: "Investigation"
  defp phase_label("interrogation"), do: "Interrogation"
  defp phase_label("discussion"), do: "Discussion"
  defp phase_label("killer_action"), do: "Killer's Move"
  defp phase_label("deduction_vote"), do: "Deduction Vote"
  defp phase_label(p) when is_binary(p), do: String.capitalize(p)
  defp phase_label(_), do: ""

  defp discussion_type_color("theory"), do: "#2980b9"
  defp discussion_type_color("challenge"), do: "#c0392b"
  defp discussion_type_color(_), do: "#27ae60"

  defp format_player_name(nil), do: "?"
  defp format_player_name("player_" <> n), do: "Player #{n}"
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
