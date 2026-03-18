defmodule LemonSim.Examples.Legislature.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (legislative/civic theme)
  # ---------------------------------------------------------------------------
  @bg "#0a0d1a"
  @panel_bg "#111827"
  @panel_border "#1e2d3d"

  @gold "#f0c040"
  @gold_dim "#8a7a30"

  @text_primary "#e2e8f0"
  @text_secondary "#94a3b8"
  @text_dim "#475569"

  # Player colors (up to 7 players)
  @player_colors ["#c0392b", "#2980b9", "#27ae60", "#f39c12", "#8e44ad", "#16a085", "#d35400"]

  # Bill topic colors
  @bill_colors %{
    "infrastructure" => "#f39c12",
    "healthcare" => "#27ae60",
    "defense" => "#c0392b",
    "education" => "#2980b9",
    "environment" => "#16a085"
  }

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 280
  @bills_w 320

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
    bills = get(world, "bills", %{})
    session = get(world, "session", 1)
    max_sessions = get(world, "max_sessions", 3)
    phase = get(world, "phase", "caucus")
    scores = get(world, "scores", %{})
    floor_statements = get(world, "floor_statements", [])
    proposed_amendments = get(world, "proposed_amendments", [])
    message_history = get(world, "message_history", [])
    vote_record = get(world, "vote_record", %{})
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
      bills: bills,
      session: session,
      max_sessions: max_sessions,
      phase: phase,
      scores: scores,
      floor_statements: floor_statements,
      proposed_amendments: proposed_amendments,
      message_history: message_history,
      vote_record: vote_record,
      winner: winner,
      active_actor: active_actor
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_roster(ctx),
      render_center_content(ctx),
      render_bills_panel(ctx),
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
      .faction-name { font-family: sans-serif; font-weight: 700; }
      .bill-text { font-family: sans-serif; }
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
    session_text =
      if type == "game_over" do
        "FINAL RESULTS"
      else
        "Session #{ctx.session}/#{ctx.max_sessions}"
      end

    phase_text =
      if type not in ["init", "game_over"] do
        String.upcase(String.replace(ctx.phase, "_", " "))
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@gold}">LEGISLATURE</text>\n],
      # Session info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(session_text)}</text>\n],
      # Phase badge
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 130}" y="14" width="150" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 205}" y="32" text-anchor="middle" font-size="12" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(phase_text)}</text>\n]
      else
        ""
      end,
      # Step
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
        color = Enum.at(@player_colors, idx, "#e2e8f0")
        render_player_card(pid, player, idx, color, ctx)
      end)

    [
      # Panel background
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">CHAMBER</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 130
    faction = get(player, "faction", pid)
    capital = get(player, "political_capital", get(player, :political_capital, 0))
    is_active = ctx.active_actor == pid
    is_winner = ctx.winner == pid
    score = Map.get(ctx.scores, pid, Map.get(ctx.scores, to_string(pid), 0))

    display_name = format_player_name(pid)

    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="124" ] <>
            ~s[fill="#{@gold}" opacity="0.12" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="124" ] <>
            ~s[fill="none" stroke="#{@gold}" stroke-width="2" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="124" ] <>
            ~s[fill="#{color}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="124" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    # Score bar (out of ~200 max theoretical score)
    bar_w = @roster_w - 40
    score_fill_w = round(bar_w * min(max(score, 0) / 200.0, 1.0))

    [
      highlight,
      # Faction name with color dot
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="faction-name" font-size="13" fill="#{color}">#{esc(faction)}</text>\n],
      # Player id
      ~s[<text x="36" y="#{y + 30}" class="player-name" font-size="11" fill="#{@text_secondary}">(#{esc(display_name)})</text>\n],
      # Score bar
      ~s[<text x="16" y="#{y + 52}" font-size="10" fill="#{@text_secondary}">Score</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 52}" text-anchor="end" font-size="10" fill="#{@gold_dim}">#{score}</text>\n],
      ~s[<rect x="16" y="#{y + 58}" width="#{bar_w}" height="8" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="16" y="#{y + 58}" width="#{max(score_fill_w, 0)}" height="8" fill="#{color}" rx="3" opacity="0.8"/>\n],
      # Capital
      ~s[<text x="16" y="#{y + 82}" font-size="10" fill="#{@text_secondary}">Capital: #{capital}</text>\n],
      # Winner badge
      if is_winner do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 82}" text-anchor="end" font-size="11" ] <>
          ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
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

  defp render_init_card(%{w: w, h: h, turn_order: turn_order, bills: bills}) do
    cx = @roster_w + div(w - @roster_w - @bills_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = length(turn_order)
    bill_count = map_size(bills)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@gold}">LEGISLATURE</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 58}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Multi-Issue Negotiation &#x26; Logrolling</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Legislators &#xB7; #{bill_count} Bills &#xB7; 3 Sessions</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 22}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Win: Highest score across all sessions</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 52}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Caucus &#xB7; Debate &#xB7; Amendment &#xB7; Vote &#xB7; Score</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@gold_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 100}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Negotiate, propose, vote, and win!</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h, turn_order: turn_order, scores: scores, winner: winner, players: players}) do
    cx = @roster_w + div(w - @roster_w - @bills_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    sorted =
      turn_order
      |> Enum.map(fn pid ->
        score = Map.get(scores, pid, Map.get(scores, to_string(pid), 0))
        {pid, score}
      end)
      |> Enum.sort_by(fn {_, score} -> -score end)

    card_h = 80 + length(sorted) * 50

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@gold}">FINAL STANDINGS</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, score}, rank} ->
        sy = cy - div(card_h, 2) + 70 + rank * 50
        is_win = pid == winner
        color = if is_win, do: @gold, else: @text_primary
        rank_label = "##{rank + 1}"

        player = Map.get(players, pid, %{})
        faction = get(player, "faction", pid)

        winner_badge =
          if is_win do
            ~s[<text x="#{cx + 240}" y="#{sy + 6}" text-anchor="end" font-size="12" ] <>
              ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
          else
            ""
          end

        [
          if is_win do
            ~s[<rect x="#{cx - 260}" y="#{sy - 18}" width="520" height="44" ] <>
              ~s[fill="#{@gold}" opacity="0.08" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">#{rank_label}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 6}" class="faction-name" font-size="16" fill="#{color}">#{esc(faction)}</text>\n],
          ~s[<text x="#{cx + 80}" y="#{sy + 6}" text-anchor="end" class="bill-text" font-size="20" fill="#{color}">#{score}</text>\n],
          ~s[<text x="#{cx + 90}" y="#{sy + 6}" font-size="12" fill="#{@text_dim}">pts</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 22}" font-size="9" fill="#{@text_dim}">#{esc(format_player_name(pid))}</text>\n],
          winner_badge
        ]
      end)
    ]
  end

  defp render_phase_content(ctx) do
    case ctx.phase do
      "caucus" -> render_caucus_panel(ctx)
      "floor_debate" -> render_floor_debate_panel(ctx)
      "amendment" -> render_amendment_panel(ctx)
      "amendment_vote" -> render_amendment_vote_panel(ctx)
      "final_vote" -> render_final_vote_panel(ctx)
      _ -> render_caucus_panel(ctx)
    end
  end

  defp render_caucus_panel(%{w: w, h: h, message_history: message_history, turn_order: turn_order, players: players} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @bills_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_messages = Enum.take(message_history, -12)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">CAUCUS ROOM</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_messages == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No messages exchanged yet</text>\n]
      else
        recent_messages
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          my = panel_y + 48 + idx * 34

          from_id = get(msg, "from", get(msg, :from, "?"))
          to_id = get(msg, "to", get(msg, :to, "?"))
          session = get(msg, "session", get(msg, :session, "?"))
          type = get(msg, "type", get(msg, :type, "message"))

          from_idx = Enum.find_index(turn_order, &(&1 == from_id)) || 0
          to_idx = Enum.find_index(turn_order, &(&1 == to_id)) || 0

          from_color = Enum.at(@player_colors, from_idx, @text_secondary)
          to_color = Enum.at(@player_colors, to_idx, @text_secondary)

          from_faction =
            get(Map.get(players, from_id, %{}), "faction", format_player_name(from_id))

          to_faction = get(Map.get(players, to_id, %{}), "faction", format_player_name(to_id))

          is_recent = idx >= length(recent_messages) - 3
          opacity = if is_recent, do: "1", else: "0.5"

          type_icon = if type == "trade", do: "&#x21C4;", else: "&#x2192;"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{my + 8}" r="5" fill="#{from_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{from_color}">#{esc(from_faction)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{my + 12}" text-anchor="middle" font-size="10" fill="#{@text_dim}">#{type_icon} Session #{session}</text>\n],
            ~s[<circle cx="#{panel_x + panel_w - 70}" cy="#{my + 8}" r="5" fill="#{to_color}"/>\n],
            ~s[<text x="#{panel_x + panel_w - 60}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{to_color}">#{esc(to_faction)}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{my + 22}" x2="#{panel_x + panel_w - 16}" y2="#{my + 22}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is caucusing...")
    ]
  end

  defp render_floor_debate_panel(%{w: w, h: h, floor_statements: floor_statements, turn_order: turn_order, players: players} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @bills_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_statements = Enum.take(floor_statements, -8)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">FLOOR DEBATE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_statements == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No speeches delivered yet</text>\n]
      else
        recent_statements
        |> Enum.with_index()
        |> Enum.map(fn {stmt, idx} ->
          sy = panel_y + 48 + idx * 52

          player_id = get(stmt, "player_id", "?")
          bill_id = get(stmt, "bill_id", "?")
          speech = get(stmt, "speech", "")
          speech_preview = String.slice(speech, 0, 80) <> if String.length(speech) > 80, do: "...", else: ""

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, @text_secondary)
          faction = get(Map.get(players, player_id, %{}), "faction", format_player_name(player_id))
          bill_color = Map.get(@bill_colors, bill_id, @text_secondary)

          is_recent = idx >= length(recent_statements) - 2
          opacity = if is_recent, do: "1", else: "0.5"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{sy + 8}" r="5" fill="#{player_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{sy + 12}" font-size="11" font-weight="600" fill="#{player_color}">#{esc(faction)}</text>\n],
            ~s[<text x="#{panel_x + 200}" y="#{sy + 12}" font-size="10" fill="#{bill_color}">on #{esc(bill_id)}</text>\n],
            ~s[<text x="#{panel_x + 16}" y="#{sy + 30}" font-size="10" fill="#{@text_secondary}">#{esc(speech_preview)}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{sy + 44}" x2="#{panel_x + panel_w - 16}" y2="#{sy + 44}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is debating...")
    ]
  end

  defp render_amendment_panel(%{w: w, h: h, proposed_amendments: proposed_amendments, turn_order: turn_order, players: players} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @bills_w - 20
    panel_h = h - @header_h - @footer_h - 20

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">AMENDMENT CHAMBER</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if proposed_amendments == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No amendments proposed yet</text>\n]
      else
        proposed_amendments
        |> Enum.with_index()
        |> Enum.take(10)
        |> Enum.map(fn {amendment, idx} ->
          ay = panel_y + 48 + idx * 44

          proposer = Map.get(amendment, :proposer_id, Map.get(amendment, "proposer_id", "?"))
          bill_id = Map.get(amendment, :bill_id, Map.get(amendment, "bill_id", "?"))
          text = Map.get(amendment, :amendment_text, Map.get(amendment, "amendment_text", ""))
          text_preview = String.slice(text, 0, 70) <> if String.length(text) > 70, do: "...", else: ""

          proposer_idx = Enum.find_index(turn_order, &(&1 == proposer)) || 0
          proposer_color = Enum.at(@player_colors, proposer_idx, @text_secondary)
          faction = get(Map.get(players, proposer, %{}), "faction", format_player_name(proposer))
          bill_color = Map.get(@bill_colors, bill_id, @text_secondary)

          [
            ~s[<circle cx="#{panel_x + 22}" cy="#{ay + 8}" r="5" fill="#{proposer_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{ay + 12}" font-size="11" font-weight="600" fill="#{proposer_color}">#{esc(faction)}</text>\n],
            ~s[<text x="#{panel_x + 200}" y="#{ay + 12}" font-size="10" fill="#{bill_color}">&#x2192; #{esc(bill_id)}</text>\n],
            ~s[<text x="#{panel_x + 16}" y="#{ay + 28}" font-size="10" fill="#{@text_secondary}">#{esc(text_preview)}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{ay + 38}" x2="#{panel_x + panel_w - 16}" y2="#{ay + 38}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n]
          ]
        end)
      end,
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is proposing amendments...")
    ]
  end

  defp render_amendment_vote_panel(%{w: w, h: h, proposed_amendments: proposed_amendments, turn_order: turn_order, players: players} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @bills_w - 20
    panel_h = h - @header_h - @footer_h - 20

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">AMENDMENT VOTE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      proposed_amendments
      |> Enum.with_index()
      |> Enum.take(8)
      |> Enum.map(fn {amendment, idx} ->
        ay = panel_y + 48 + idx * 56

        amendment_id = Map.get(amendment, :id, Map.get(amendment, "id", "?"))
        bill_id = Map.get(amendment, :bill_id, Map.get(amendment, "bill_id", "?"))
        votes = Map.get(amendment, :votes, Map.get(amendment, "votes", %{}))
        passed = Map.get(amendment, :passed, nil)

        yes_count = Enum.count(votes, fn {_k, v} -> v == "yes" end)
        no_count = Enum.count(votes, fn {_k, v} -> v == "no" end)
        bill_color = Map.get(@bill_colors, bill_id, @text_secondary)

        status_text =
          cond do
            passed == true -> "PASSED"
            passed == false -> "FAILED"
            true -> "#{yes_count}Y / #{no_count}N"
          end

        status_color =
          cond do
            passed == true -> "#27ae60"
            passed == false -> "#e74c3c"
            true -> @text_secondary
          end

        [
          ~s[<rect x="#{panel_x + 10}" y="#{ay - 4}" width="#{panel_w - 20}" height="48" fill="#{@panel_bg}" rx="4" opacity="0.5"/>\n],
          ~s[<text x="#{panel_x + 16}" y="#{ay + 12}" font-size="11" font-weight="600" fill="#{@text_primary}">#{esc(amendment_id)}</text>\n],
          ~s[<text x="#{panel_x + 200}" y="#{ay + 12}" font-size="10" fill="#{bill_color}">bill: #{esc(bill_id)}</text>\n],
          ~s[<text x="#{panel_x + panel_w - 16}" y="#{ay + 12}" text-anchor="end" font-size="11" font-weight="700" fill="#{status_color}">#{esc(status_text)}</text>\n],
          ~s[<text x="#{panel_x + 16}" y="#{ay + 30}" font-size="10" fill="#{@text_dim}">Votes: ],
          render_vote_dots(votes, turn_order, panel_x + 75, ay + 26),
          ~s[</text>\n]
        ]
      end),
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is voting on amendments...")
    ]
  end

  defp render_vote_dots(votes, turn_order, _x, _y) do
    Enum.map_join(votes, " ", fn {player_id, vote} ->
      player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
      _color = Enum.at(@player_colors, player_idx, @text_secondary)
      "#{format_player_name(player_id)}:#{vote}"
    end)
  end

  defp render_final_vote_panel(%{w: w, h: h, vote_record: vote_record, turn_order: turn_order, players: players} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @bills_w - 20
    panel_h = h - @header_h - @footer_h - 20

    bill_ids = ["infrastructure", "healthcare", "defense", "education", "environment"]

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">FINAL VOTE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Show vote tallies per bill
      bill_ids
      |> Enum.with_index()
      |> Enum.map(fn {bill_id, idx} ->
        by = panel_y + 48 + idx * 60

        yes_count =
          Enum.count(vote_record, fn {_player, votes} ->
            Map.get(votes, bill_id, "no") == "yes"
          end)

        no_count = map_size(vote_record) - yes_count
        bill_color = Map.get(@bill_colors, bill_id, @text_secondary)
        total = yes_count + no_count
        bar_w = panel_w - 80

        yes_w = if total > 0, do: round(bar_w * yes_count / total), else: 0
        no_w = bar_w - yes_w

        [
          ~s[<text x="#{panel_x + 16}" y="#{by + 14}" font-size="12" font-weight="700" fill="#{bill_color}">#{esc(String.upcase(bill_id))}</text>\n],
          ~s[<text x="#{panel_x + panel_w - 16}" y="#{by + 14}" text-anchor="end" font-size="11" fill="#{@text_secondary}">#{yes_count}Y / #{no_count}N</text>\n],
          ~s[<rect x="#{panel_x + 16}" y="#{by + 22}" width="#{bar_w}" height="14" fill="#{@panel_bg}" rx="3"/>\n],
          if yes_w > 0 do
            ~s[<rect x="#{panel_x + 16}" y="#{by + 22}" width="#{yes_w}" height="14" fill="#27ae60" rx="3" opacity="0.8"/>\n]
          else
            ""
          end,
          if no_w > 0 do
            ~s[<rect x="#{panel_x + 16 + yes_w}" y="#{by + 22}" width="#{no_w}" height="14" fill="#e74c3c" rx="3" opacity="0.6"/>\n]
          else
            ""
          end
        ]
      end),
      render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, "is casting votes...")
    ]
  end

  defp render_active_player_bar(ctx, panel_x, panel_y, panel_w, panel_h, action_text) do
    if ctx.active_actor do
      actor_idx = Enum.find_index(ctx.turn_order, &(&1 == ctx.active_actor)) || 0
      actor_color = Enum.at(@player_colors, actor_idx, @text_secondary)
      actor_faction = get(Map.get(ctx.players, ctx.active_actor, %{}), "faction", format_player_name(ctx.active_actor))

      [
        ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
          ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{actor_color}">#{esc(actor_faction)} #{action_text}</text>\n]
      ]
    else
      ""
    end
  end

  # ---------------------------------------------------------------------------
  # Bills panel (right panel)
  # ---------------------------------------------------------------------------

  defp render_bills_panel(%{w: w, h: h, bills: bills} = _ctx) do
    panel_x = w - @bills_w
    panel_h = h - @header_h - @footer_h

    bill_ids = ["infrastructure", "healthcare", "defense", "education", "environment"]

    bill_entries =
      bill_ids
      |> Enum.with_index()
      |> Enum.map(fn {bill_id, idx} ->
        bill = Map.get(bills, bill_id, Map.get(bills, to_string(bill_id), %{}))
        bx = panel_x + 8
        by = @header_h + 40 + idx * 88

        title = Map.get(bill, :title, Map.get(bill, "title", bill_id))
        title_short = String.slice(title, 0, 26)
        status = Map.get(bill, :status, Map.get(bill, "status", "pending"))
        amendments = Map.get(bill, :amendments, Map.get(bill, "amendments", []))
        lobby_support = Map.get(bill, :lobby_support, Map.get(bill, "lobby_support", %{}))
        total_lobby = lobby_support |> Map.values() |> Enum.sum()

        bill_color = Map.get(@bill_colors, bill_id, @text_secondary)

        status_color =
          case status do
            "passed" -> "#27ae60"
            "failed" -> "#e74c3c"
            _ -> @text_dim
          end

        [
          ~s[<rect x="#{bx}" y="#{by - 10}" width="#{@bills_w - 16}" height="80" fill="#{bill_color}" opacity="#{if status == "pending", do: "0.06", else: "0.12"}" rx="4"/>\n],
          ~s[<circle cx="#{bx + 12}" cy="#{by + 4}" r="5" fill="#{bill_color}" opacity="0.9"/>\n],
          ~s[<text x="#{bx + 22}" y="#{by + 8}" font-size="11" font-weight="700" fill="#{bill_color}">#{esc(title_short)}</text>\n],
          ~s[<text x="#{panel_x + @bills_w - 16}" y="#{by + 8}" text-anchor="end" font-size="10" font-weight="700" fill="#{status_color}">#{esc(String.upcase(status))}</text>\n],
          if total_lobby > 0 do
            ~s[<text x="#{bx + 22}" y="#{by + 28}" font-size="9" fill="#{@text_dim}">Lobby: #{total_lobby} capital</text>\n]
          else
            ""
          end,
          if length(amendments) > 0 do
            ~s[<text x="#{bx + 22}" y="#{by + 44}" font-size="9" fill="#{@text_secondary}">#{length(amendments)} amendment(s)</text>\n]
          else
            ~s[<text x="#{bx + 22}" y="#{by + 44}" font-size="9" fill="#{@text_dim}">No amendments</text>\n]
          end,
          ~s[<line x1="#{bx}" y1="#{by + 62}" x2="#{panel_x + @bills_w - 16}" y2="#{by + 62}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n]
        ]
      end)

    [
      # Panel background
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@bills_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@bills_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@bills_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">BILLS ON FLOOR</text>\n],
      bill_entries,
      if bills == %{} do
        ~s[<text x="#{panel_x + div(@bills_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No bills</text>\n]
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
        "Legislature convenes: #{length(ctx.turn_order)} legislators, #{map_size(ctx.bills)} bills, 3 sessions"

      ctx.type == "game_over" ->
        winner = ctx.winner
        player = Map.get(ctx.players, winner, %{})
        faction = get(player, "faction", format_player_name(winner))
        "#{faction} wins the legislature game!"

      has_event?(events, "game_over") ->
        ev = find_event(events, "game_over")
        p = get(ev, "payload", ev || %{})
        winner = get(p, "winner", "?")
        player = Map.get(ctx.players, winner, %{})
        faction = get(player, "faction", format_player_name(winner))
        "#{faction} wins with the highest score!"

      has_event?(events, "bill_voted") ->
        ev = find_event(events, "bill_voted")
        p = get(ev, "payload", ev || %{})
        bill_id = get(p, "bill_id", "?")
        passed = get(p, "passed", false)
        yes = get(p, "yes_votes", 0)
        no = get(p, "no_votes", 0)
        result = if passed, do: "PASSED", else: "FAILED"
        "Bill #{bill_id} #{result} (#{yes}-#{no})"

      has_event?(events, "amendment_resolved") ->
        ev = find_event(events, "amendment_resolved")
        p = get(ev, "payload", ev || %{})
        bill_id = get(p, "bill_id", "?")
        passed = get(p, "passed", false)
        result = if passed, do: "passed", else: "failed"
        "Amendment to #{bill_id} #{result}"

      has_event?(events, "session_advanced") ->
        ev = find_event(events, "session_advanced")
        p = get(ev, "payload", ev || %{})
        "Session #{get(p, "session", "?")} begins"

      has_event?(events, "amendment_proposed") ->
        ev = find_event(events, "amendment_proposed")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        bill_id = get(p, "bill_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        faction = get(player, "faction", format_player_name(player_id))
        "#{faction} proposes an amendment to #{bill_id}"

      has_event?(events, "speech_delivered") ->
        ev = find_event(events, "speech_delivered")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        bill_id = get(p, "bill_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        faction = get(player, "faction", format_player_name(player_id))
        "#{faction} speaks on #{bill_id}"

      has_event?(events, "trade_proposed") ->
        ev = find_event(events, "trade_proposed")
        p = get(ev, "payload", ev || %{})
        proposer = get(p, "proposer_id", "?")
        player = Map.get(ctx.players, proposer, %{})
        faction = get(player, "faction", format_player_name(proposer))
        bill_a = get(p, "bill_a", "?")
        bill_b = get(p, "bill_b", "?")
        "#{faction} proposes a trade: #{bill_a} for #{bill_b}"

      has_event?(events, "message_delivered") ->
        ev = find_event(events, "message_delivered")
        p = get(ev, "payload", ev || %{})
        sender = get(p, "sender_id", "?")
        recipient = get(p, "recipient_id", "?")
        sender_player = Map.get(ctx.players, sender, %{})
        recipient_player = Map.get(ctx.players, recipient, %{})
        from_faction = get(sender_player, "faction", format_player_name(sender))
        to_faction = get(recipient_player, "faction", format_player_name(recipient))
        "#{from_faction} sends a private message to #{to_faction}"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        to = get(p, "to", "?")
        "Phase: #{String.replace(to, "_", " ")}"

      true ->
        case ctx.phase do
          "caucus" -> "Private caucus in progress..."
          "floor_debate" -> "Floor debate underway..."
          "amendment" -> "Amendment proposals being considered..."
          "amendment_vote" -> "Voting on amendments..."
          "final_vote" -> "Final vote in progress..."
          _ -> ""
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("caucus"), do: "#2980b9"
  defp phase_color("floor_debate"), do: "#f39c12"
  defp phase_color("amendment"), do: "#8e44ad"
  defp phase_color("amendment_vote"), do: "#c0392b"
  defp phase_color("final_vote"), do: "#e74c3c"
  defp phase_color(_), do: @text_secondary

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
