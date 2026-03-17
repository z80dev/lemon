defmodule LemonSim.Examples.Survivor.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (tropical/reality TV theme)
  # ---------------------------------------------------------------------------
  @bg "#0f0a05"
  @panel_bg "#1a150e"
  @panel_border "#2d2518"

  # Tribe colors
  @tala_color "#e67e22"
  @manu_color "#2980b9"
  @solana_color "#8e44ad"

  @alive_color "#2ecc71"
  @eliminated_color "#c0392b"
  @jury_color "#f39c12"

  @idol_color "#f1c40f"
  @immune_color "#3498db"

  @text_primary "#faf5ef"
  @text_secondary "#b8a99a"
  @text_dim "#6b5d4f"

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 310
  @history_w 290

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
    tribes = get(world, "tribes", %{})
    episode = get(world, "episode", 1)
    phase = get(world, "phase", "challenge")
    merged = get(world, "merged", false)
    challenge_winner = get(world, "challenge_winner", nil)
    losing_tribe = get(world, "losing_tribe", nil)
    immune_player = get(world, "immune_player", nil)
    votes = get(world, "votes", %{})
    jury = get(world, "jury", [])
    elimination_log = get(world, "elimination_log", [])
    jury_votes = get(world, "jury_votes", %{})
    ftc_sub_phase = get(world, "ftc_sub_phase", nil)
    winner = get(world, "winner", nil)
    status = get(world, "status", "in_progress")
    statements = get(world, "statements", [])
    whisper_graph = get(world, "whisper_graph", [])
    vote_history = get(world, "vote_history", [])

    # Sorted player list for roster
    player_ids =
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
      player_ids: player_ids,
      tribes: tribes,
      episode: episode,
      phase: phase,
      merged: merged,
      challenge_winner: challenge_winner,
      losing_tribe: losing_tribe,
      immune_player: immune_player,
      votes: votes,
      jury: jury,
      elimination_log: elimination_log,
      jury_votes: jury_votes,
      ftc_sub_phase: ftc_sub_phase,
      winner: winner,
      status: status,
      statements: statements,
      whisper_graph: whisper_graph,
      vote_history: vote_history
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_roster(ctx),
      render_center_content(ctx),
      render_history_panel(ctx),
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
      <filter id="glow-soft">
        <feGaussianBlur stdDeviation="2" result="blur"/>
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
      .phase-text { font-family: sans-serif; font-weight: 700; letter-spacing: 2px; }
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
    phase_label =
      if type == "game_over" do
        "GAME OVER"
      else
        phase_display(ctx.phase)
      end

    episode_text =
      if type == "game_over" do
        "SOLE SURVIVOR CROWNED"
      else
        "Episode #{ctx.episode}"
      end

    tribe_text = tribe_header_text(ctx)

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="24" fill="#{@idol_color}" filter="url(#glow-soft)">SURVIVOR</text>\n],
      # Episode
      ~s[<text x="160" y="38" class="header-text" font-size="16" fill="#{@text_secondary}">#{esc(episode_text)}</text>\n],
      # Phase indicator (center)
      ~s[<text x="#{div(w, 2)}" y="38" class="phase-text" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{phase_color(ctx.phase)}">#{esc(phase_label)}</text>\n],
      # Tribe name(s)
      ~s[<text x="#{w - 20}" y="38" class="header-text" font-size="14" ] <>
        ~s[text-anchor="end" fill="#{@text_secondary}">#{esc(tribe_text)}</text>\n],
      # Step counter
      ~s[<text x="#{w - 20}" y="18" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  defp tribe_header_text(%{merged: true} = ctx) do
    merge_name = get_tribe_name(ctx)
    "Merged: #{merge_name}"
  end

  defp tribe_header_text(%{tribes: tribes}) do
    tribes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(" vs ")
  end

  defp get_tribe_name(%{tribes: tribes}) do
    case Map.keys(tribes) do
      [name] -> name
      [name | _] -> name
      _ -> "Solana"
    end
  end

  # ---------------------------------------------------------------------------
  # Player roster (left panel)
  # ---------------------------------------------------------------------------

  defp render_player_roster(%{h: h, player_ids: player_ids, players: players} = ctx) do
    panel_h = h - @header_h - @footer_h
    card_h = 100
    visible_count = min(length(player_ids), div(panel_h - 36, card_h))

    player_entries =
      player_ids
      |> Enum.take(visible_count)
      |> Enum.with_index()
      |> Enum.map(fn {pid, idx} ->
        player = Map.get(players, pid, %{})
        render_player_card(pid, player, idx, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@text_dim}">PLAYERS</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, ctx) do
    y = @header_h + 36 + idx * 100
    status = get(player, "status", get(player, :status, "alive"))
    tribe = get(player, "tribe", get(player, :tribe, "unknown"))
    has_idol = get(player, "has_idol", get(player, :has_idol, false))
    is_jury = pid in ctx.jury
    is_immune = ctx.immune_player == pid
    is_winner = ctx.winner == pid

    tribe_col = tribe_color(tribe, ctx.merged)
    status_col = status_color(status, is_jury)

    player_challenge_wins = get(player, "challenge_wins", get(player, :challenge_wins, 0))

    # Status label
    status_label =
      cond do
        is_winner -> "WINNER"
        is_jury -> "JURY"
        status == "eliminated" -> "OUT"
        is_immune -> "IMMUNE"
        true -> "ALIVE"
      end

    # Highlight for active / winner
    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="94" ] <>
            ~s[fill="#{@idol_color}" opacity="0.1" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="94" ] <>
            ~s[fill="none" stroke="#{@idol_color}" stroke-width="2" rx="6"/>\n]

        status == "alive" and not is_jury ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="94" ] <>
            ~s[fill="#{tribe_col}" opacity="0.05" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="94" ] <>
            ~s[fill="none" stroke="#{tribe_col}" stroke-width="1" rx="6" opacity="0.4"/>\n]

        true ->
          ""
      end

    opacity = if status == "eliminated" and not is_jury, do: "0.4", else: "1"

    [
      highlight,
      ~s[<g opacity="#{opacity}">\n],
      # Tribe color dot
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{tribe_col}"/>\n],
      # Player name
      ~s[<text x="36" y="#{y + 14}" class="player-name" font-size="14" fill="#{@text_primary}">#{esc(pid)}</text>\n],
      # Status badge
      ~s[<rect x="#{@roster_w - 70}" y="#{y}" width="62" height="18" fill="#{status_col}" opacity="0.2" rx="3"/>\n],
      ~s[<text x="#{@roster_w - 39}" y="#{y + 13}" text-anchor="middle" font-size="10" font-weight="700" fill="#{status_col}">#{status_label}</text>\n],
      # Tribe label
      ~s[<text x="36" y="#{y + 30}" font-size="10" fill="#{tribe_col}">#{esc(tribe)}</text>\n],
      # Idol indicator
      if has_idol do
        ~s[<text x="120" y="#{y + 30}" font-size="10" font-weight="700" fill="#{@idol_color}" filter="url(#glow-soft)">IDOL</text>\n]
      else
        ""
      end,
      # Immune badge
      if is_immune do
        ~s[<text x="170" y="#{y + 30}" font-size="10" font-weight="700" fill="#{@immune_color}">IMMUNE</text>\n]
      else
        ""
      end,
      # Challenge wins
      if player_challenge_wins > 0 do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 30}" text-anchor="end" font-size="10" fill="#{@text_dim}">#{player_challenge_wins}W</text>\n]
      else
        ""
      end,
      # Separator line
      ~s[<line x1="16" y1="#{y + 70}" x2="#{@roster_w - 16}" y2="#{y + 70}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n],
      # Jury vote count for game_over
      if ctx.type == "game_over" and is_jury do
        votes_for =
          ctx.jury_votes
          |> Enum.count(fn {_voter, target} -> target == pid end)

        if votes_for > 0 do
          ~s[<text x="36" y="#{y + 50}" font-size="10" fill="#{@idol_color}">#{votes_for} jury vote#{if votes_for != 1, do: "s", else: ""}</text>\n]
        else
          ""
        end
      else
        ""
      end,
      ~s[</g>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content (phase-specific)
  # ---------------------------------------------------------------------------

  defp render_center_content(%{type: "init"} = ctx), do: render_init_card(ctx)
  defp render_center_content(%{type: "game_over"} = ctx), do: render_game_over_card(ctx)
  defp render_center_content(%{phase: "challenge"} = ctx), do: render_challenge_view(ctx)
  defp render_center_content(%{phase: "strategy"} = ctx), do: render_strategy_view(ctx)
  defp render_center_content(%{phase: "tribal_council"} = ctx), do: render_tribal_council_view(ctx)
  defp render_center_content(%{phase: "final_tribal_council"} = ctx), do: render_ftc_view(ctx)
  defp render_center_content(ctx), do: render_generic_view(ctx)

  defp render_init_card(%{w: w, h: h, players: players, tribes: tribes}) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = map_size(players)
    tribe_names = Map.keys(tribes) |> Enum.sort()

    tribe_lines =
      tribe_names
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        members = Map.get(tribes, name, [])
        ty = cy - 20 + idx * 24
        col = tribe_color(name, false)

        ~s[<text x="#{cx}" y="#{ty}" text-anchor="middle" font-size="14" fill="#{col}">] <>
          ~s[#{esc(name)}: #{esc(Enum.join(members, ", "))}</text>\n]
      end)

    [
      ~s[<rect x="#{cx - 300}" y="#{cy - 160}" width="600" height="320" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@idol_color}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 110}" text-anchor="middle" class="title" ] <>
        ~s[font-size="36" fill="#{@idol_color}" filter="url(#glow-soft)">SURVIVOR</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 80}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Social Strategy Game</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 52}" text-anchor="middle" font-size="15" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Players &#xB7; #{length(tribe_names)} Tribes</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{cy - 36}" x2="#{cx + 200}" y2="#{cy - 36}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      tribe_lines,
      ~s[<line x1="#{cx - 200}" y1="#{cy + 60}" x2="#{cx + 200}" y2="#{cy + 60}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 82}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_dim}">Challenges &#xB7; Whispers &#xB7; Tribal Council &#xB7; Jury</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 106}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_dim}">One Sole Survivor will be crowned.</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h, winner: winner, jury_votes: jury_votes, elimination_log: elimination_log, players: players}) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    # Tally jury votes per finalist
    vote_tally =
      jury_votes
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    finalists =
      vote_tally
      |> Enum.sort_by(fn {_pid, count} -> -count end)

    card_h = 100 + max(length(finalists), 1) * 50 + length(elimination_log) * 20

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@idol_color}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 38}" text-anchor="middle" class="title" ] <>
        ~s[font-size="26" fill="#{@idol_color}" filter="url(#glow-soft)">SOLE SURVIVOR</text>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 66}" text-anchor="middle" font-size="22" ] <>
        ~s[fill="#{@alive_color}">#{esc(winner)}</text>\n],
      ~s[<line x1="#{cx - 180}" y1="#{cy - div(card_h, 2) + 78}" x2="#{cx + 180}" y2="#{cy - div(card_h, 2) + 78}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Jury vote breakdown
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 96}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_dim}">Final Jury Vote</text>\n],
      finalists
      |> Enum.with_index()
      |> Enum.map(fn {{pid, count}, idx} ->
        fy = cy - div(card_h, 2) + 116 + idx * 50
        is_w = pid == winner
        col = if is_w, do: @idol_color, else: @text_secondary
        bar_w = round(200 * count / max(map_size(jury_votes), 1))

        [
          ~s[<text x="#{cx - 240}" y="#{fy + 14}" font-size="14" fill="#{col}">#{esc(pid)}</text>\n],
          ~s[<rect x="#{cx - 10}" y="#{fy}" width="200" height="20" fill="#{@panel_bg}" rx="4"/>\n],
          ~s[<rect x="#{cx - 10}" y="#{fy}" width="#{bar_w}" height="20" fill="#{col}" opacity="0.5" rx="4"/>\n],
          ~s[<text x="#{cx + 200}" y="#{fy + 14}" font-size="13" fill="#{col}">#{count} vote#{if count != 1, do: "s", else: ""}</text>\n]
        ]
      end),
      # Elimination order summary
      if length(elimination_log) > 0 do
        base_y = cy - div(card_h, 2) + 116 + length(finalists) * 50 + 20

        [
          ~s[<text x="#{cx}" y="#{base_y}" text-anchor="middle" font-size="11" fill="#{@text_dim}">Elimination Order</text>\n],
          elimination_log
          |> Enum.with_index()
          |> Enum.map(fn {entry, idx} ->
            player = get(entry, "player", get(entry, :player, "?"))
            ep = get(entry, "episode", get(entry, :episode, "?"))
            ey = base_y + 16 + idx * 18
            _ = players

            ~s[<text x="#{cx}" y="#{ey}" text-anchor="middle" font-size="10" fill="#{@text_dim}">] <>
              ~s[Ep#{ep}: #{esc(player)}</text>\n]
          end)
        ]
      else
        ""
      end
    ]
  end

  defp render_challenge_view(%{w: w, h: h} = ctx) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    challenge_winner = ctx.challenge_winner

    if challenge_winner do
      # Challenge resolved — show results
      render_challenge_results(ctx, cx, cy)
    else
      # Challenge in progress
      render_challenge_in_progress(ctx, cx, cy)
    end
  end

  defp render_challenge_in_progress(%{merged: merged, tribes: tribes} = ctx, cx, cy) do
    phase_label = if merged, do: "INDIVIDUAL CHALLENGE", else: "TRIBAL CHALLENGE"

    tribe_names = Map.keys(tribes) |> Enum.sort()

    tribe_sections =
      tribe_names
      |> Enum.with_index()
      |> Enum.map(fn {tname, idx} ->
        col = tribe_color(tname, ctx.merged)
        tx = cx - 180 + idx * 240

        members =
          Map.get(tribes, tname, [])
          |> Enum.map(fn pid ->
            p = Map.get(ctx.players, pid, %{})
            status = get(p, "status", get(p, :status, "alive"))
            choice = Map.get(get(ctx, :challenge_choices, %{}), pid)
            opacity = if status == "alive", do: "1", else: "0.3"

            choice_text = if choice, do: String.upcase(choice), else: "..."

            ~s[<g opacity="#{opacity}">\n] <>
              ~s[<text x="#{tx}" y="0" text-anchor="middle" font-size="12" fill="#{@text_primary}">#{esc(pid)}</text>\n] <>
              ~s[<text x="#{tx}" y="16" text-anchor="middle" font-size="10" fill="#{@text_secondary}">#{choice_text}</text>\n] <>
              ~s[</g>\n]
          end)

        member_rows =
          members
          |> Enum.with_index()
          |> Enum.map(fn {member_svg, midx} ->
            ~s[<g transform="translate(0, #{midx * 40})">\n#{member_svg}</g>\n]
          end)

        [
          ~s[<text x="#{tx}" y="#{cy - 80}" text-anchor="middle" class="title" font-size="18" fill="#{col}">#{esc(tname)}</text>\n],
          ~s[<line x1="#{tx - 80}" y1="#{cy - 68}" x2="#{tx + 80}" y2="#{cy - 68}" stroke="#{col}" stroke-width="1" opacity="0.5"/>\n],
          ~s[<g transform="translate(0, #{cy - 54})">\n],
          member_rows,
          ~s[</g>\n]
        ]
      end)

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - 120}" width="560" height="240" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@panel_border}" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="phase-text" ] <>
        ~s[font-size="16" fill="#{@text_secondary}">#{phase_label}</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_dim}">physical beats endurance &#xB7; endurance beats puzzle &#xB7; puzzle beats physical</text>\n],
      tribe_sections
    ]
  end

  defp render_challenge_results(%{merged: merged} = ctx, cx, cy) do
    winner = ctx.challenge_winner
    col = tribe_color(winner, merged)

    immune_line =
      if ctx.immune_player do
        ~s[<text x="#{cx}" y="#{cy + 50}" text-anchor="middle" font-size="16" ] <>
          ~s[fill="#{@immune_color}">#{esc(ctx.immune_player)} wins individual immunity!</text>\n]
      else
        ""
      end

    losing_line =
      if ctx.losing_tribe do
        ~s[<text x="#{cx}" y="#{cy + 80}" text-anchor="middle" font-size="14" ] <>
          ~s[fill="#{@eliminated_color}">#{esc(ctx.losing_tribe)} goes to Tribal Council</text>\n]
      else
        ""
      end

    [
      ~s[<rect x="#{cx - 240}" y="#{cy - 120}" width="480" height="240" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{col}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" class="title" ] <>
        ~s[font-size="14" fill="#{@text_secondary}">CHALLENGE WINNER</text>\n],
      ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" class="title" ] <>
        ~s[font-size="36" fill="#{col}" filter="url(#glow-soft)">#{esc(winner)}</text>\n],
      immune_line,
      losing_line
    ]
  end

  defp render_strategy_view(%{w: w, h: h} = ctx) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    recent_statements = Enum.take(ctx.statements, -5)
    recent_whispers = Enum.take(ctx.whisper_graph, -8)

    [
      ~s[<rect x="#{cx - 300}" y="#{@header_h + 10}" width="600" height="#{h - @header_h - @footer_h - 20}" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@panel_border}" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{@header_h + 35}" text-anchor="middle" class="phase-text" ] <>
        ~s[font-size="16" fill="#{@text_secondary}">STRATEGY PHASE</text>\n],
      # Statements section
      ~s[<text x="#{cx - 270}" y="#{@header_h + 62}" font-size="12" fill="#{@text_dim}">PUBLIC STATEMENTS</text>\n],
      recent_statements
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        player = get(entry, "player", get(entry, :player, "?"))
        statement = get(entry, "statement", get(entry, :statement, ""))
        sy = @header_h + 82 + idx * 50
        p = Map.get(ctx.players, player, %{})
        tribe = get(p, "tribe", get(p, :tribe, "unknown"))
        col = tribe_color(tribe, ctx.merged)

        [
          ~s[<circle cx="#{cx - 270}" cy="#{sy + 6}" r="5" fill="#{col}"/>\n],
          ~s[<text x="#{cx - 258}" y="#{sy + 10}" font-size="12" font-weight="700" fill="#{col}">#{esc(player)}</text>\n],
          ~s[<text x="#{cx - 258}" y="#{sy + 26}" font-size="11" fill="#{@text_secondary}">#{esc(truncate(statement, 70))}</text>\n]
        ]
      end),
      # Whisper graph
      ~s[<text x="#{cx + 40}" y="#{@header_h + 62}" font-size="12" fill="#{@text_dim}">WHISPER GRAPH</text>\n],
      recent_whispers
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        from = get(entry, "from", get(entry, :from, "?"))
        to = get(entry, "to", get(entry, :to, "?"))
        wy = @header_h + 82 + idx * 28

        [
          ~s[<text x="#{cx + 40}" y="#{wy + 10}" font-size="11" fill="#{@text_secondary}">] <>
            ~s[#{esc(from)} &#x2192; #{esc(to)}</text>\n]
        ]
      end),
      # Footer note about whisper privacy
      ~s[<text x="#{cx}" y="#{cy + 160}" text-anchor="middle" font-size="10" fill="#{@text_dim}">* Whisper content is private. Only sender and recipient see the message.</text>\n]
    ]
  end

  defp render_tribal_council_view(%{w: w, h: h} = ctx) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    # Check if vote_result event happened
    if has_event?(ctx.events, "vote_result") do
      render_vote_reveal(ctx, cx, cy)
    else
      render_voting_in_progress(ctx, cx, cy)
    end
  end

  defp render_voting_in_progress(ctx, cx, cy) do
    votes_cast = map_size(ctx.votes)
    idol_played = has_event?(ctx.events, "play_idol")

    idol_banner =
      if idol_played do
        idol_event = find_event(ctx.events, "play_idol")
        p = get(idol_event, "payload", idol_event || %{})
        player_id = get(p, "player_id", "?")

        ~s[<rect x="#{cx - 200}" y="#{cy - 150}" width="400" height="36" ] <>
          ~s[fill="#{@idol_color}" opacity="0.2" rx="4"/>\n] <>
          ~s[<text x="#{cx}" y="#{cy - 126}" text-anchor="middle" font-size="14" ] <>
          ~s[font-weight="700" fill="#{@idol_color}" filter="url(#glow-soft)">#{esc(player_id)} plays the Hidden Immunity Idol!</text>\n]
      else
        ""
      end

    [
      ~s[<rect x="#{cx - 240}" y="#{cy - 170}" width="480" height="340" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@panel_border}" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 140}" text-anchor="middle" class="phase-text" ] <>
        ~s[font-size="18" fill="#{@eliminated_color}">TRIBAL COUNCIL</text>\n],
      idol_banner,
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">#{votes_cast} vote#{if votes_cast != 1, do: "s", else: ""} cast</text>\n],
      # Vote tally bars (anonymous parchment style)
      ctx.votes
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.sort_by(fn {_t, vs} -> -length(vs) end)
      |> Enum.take(6)
      |> Enum.with_index()
      |> Enum.map(fn {{target, voters}, idx} ->
        count = length(voters)
        vy = cy - 60 + idx * 42
        bar_w = count * 60

        [
          ~s[<text x="#{cx - 180}" y="#{vy + 14}" font-size="13" fill="#{@text_primary}">#{esc(target)}</text>\n],
          ~s[<rect x="#{cx - 60}" y="#{vy}" width="#{bar_w}" height="22" fill="#{@eliminated_color}" opacity="0.5" rx="3"/>\n],
          ~s[<text x="#{cx - 60 + bar_w + 8}" y="#{vy + 15}" font-size="12" fill="#{@text_secondary}">#{count}</text>\n]
        ]
      end)
    ]
  end

  defp render_vote_reveal(ctx, cx, cy) do
    vote_event = find_event(ctx.events, "vote_result")
    p = get(vote_event, "payload", vote_event || %{})
    eliminated = get(p, "eliminated_id", nil)
    vote_tally = get(p, "vote_tally", %{})

    idol_line =
      if has_event?(ctx.events, "play_idol") do
        idol_event = find_event(ctx.events, "play_idol")
        ip = get(idol_event, "payload", idol_event || %{})
        player_id = get(ip, "player_id", "?")

        ~s[<text x="#{cx}" y="#{cy + 80}" text-anchor="middle" font-size="13" ] <>
          ~s[fill="#{@idol_color}">#{esc(player_id)} played an idol — votes against negated</text>\n]
      else
        ""
      end

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 140}" width="520" height="280" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@eliminated_color}" stroke-width="2" opacity="0.95"/>\n],
      # Vote tally
      ~s[<text x="#{cx}" y="#{cy - 110}" text-anchor="middle" font-size="13" fill="#{@text_dim}">THE TRIBE HAS SPOKEN</text>\n],
      vote_tally
      |> Enum.sort_by(fn {_t, count} -> -count end)
      |> Enum.take(5)
      |> Enum.with_index()
      |> Enum.map(fn {{target, count}, idx} ->
        vy = cy - 80 + idx * 36
        is_elim = target == eliminated
        col = if is_elim, do: @eliminated_color, else: @text_secondary
        bar_w = count * 50

        [
          if is_elim do
            ~s[<rect x="#{cx - 240}" y="#{vy - 4}" width="480" height="32" fill="#{@eliminated_color}" opacity="0.1" rx="3"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 220}" y="#{vy + 16}" font-size="14" fill="#{col}">#{esc(target)}</text>\n],
          ~s[<rect x="#{cx - 60}" y="#{vy + 2}" width="#{bar_w}" height="18" fill="#{col}" opacity="0.4" rx="3"/>\n],
          ~s[<text x="#{cx - 52 + bar_w}" y="#{vy + 16}" font-size="12" fill="#{col}">#{count}</text>\n]
        ]
      end),
      # Eliminated player
      if eliminated do
        [
          ~s[<line x1="#{cx - 200}" y1="#{cy + 60}" x2="#{cx + 200}" y2="#{cy + 60}" stroke="#{@panel_border}" stroke-width="1"/>\n],
          ~s[<text x="#{cx}" y="#{cy + 100}" text-anchor="middle" class="title" ] <>
            ~s[font-size="22" fill="#{@eliminated_color}">#{esc(eliminated)}</text>\n],
          ~s[<text x="#{cx}" y="#{cy + 122}" text-anchor="middle" font-size="13" ] <>
            ~s[fill="#{@text_dim}">voted out of the tribe</text>\n]
        ]
      else
        ~s[<text x="#{cx}" y="#{cy + 80}" text-anchor="middle" font-size="16" fill="#{@text_secondary}">No elimination.</text>\n]
      end,
      idol_line
    ]
  end

  defp render_ftc_view(%{w: w, h: h} = ctx) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    sub_phase = ctx.ftc_sub_phase || "jury_statements"
    jury_statements = get(ctx, :jury_statements, []) || []

    [
      ~s[<rect x="#{cx - 300}" y="#{@header_h + 10}" width="600" height="#{h - @header_h - @footer_h - 20}" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{@solana_color}" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{@header_h + 35}" text-anchor="middle" class="phase-text" ] <>
        ~s[font-size="16" fill="#{@solana_color}">FINAL TRIBAL COUNCIL</text>\n],
      ~s[<text x="#{cx}" y="#{@header_h + 55}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_dim}">#{esc(sub_phase_label(sub_phase))}</text>\n],
      # Jury members list
      ~s[<text x="#{cx - 270}" y="#{@header_h + 80}" font-size="11" fill="#{@text_dim}">JURY</text>\n],
      ctx.jury
      |> Enum.with_index()
      |> Enum.map(fn {juror, idx} ->
        jx = cx - 270 + idx * 80

        ~s[<text x="#{jx}" y="#{@header_h + 98}" font-size="11" fill="#{@jury_color}">#{esc(juror)}</text>\n]
      end),
      # Recent statements
      ~s[<text x="#{cx - 270}" y="#{@header_h + 124}" font-size="11" fill="#{@text_dim}">STATEMENTS</text>\n],
      jury_statements
      |> Enum.take(-6)
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        player = get(entry, "player", get(entry, :player, "?"))
        statement = get(entry, "statement", get(entry, :statement, ""))
        is_plea = get(entry, "type", get(entry, :type, "")) == "final_plea"
        sy = @header_h + 144 + idx * 60
        col = if is_plea, do: @alive_color, else: @jury_color

        [
          ~s[<text x="#{cx - 270}" y="#{sy}" font-size="12" font-weight="700" fill="#{col}">#{esc(player)}#{if is_plea, do: " (plea)", else: ""}</text>\n],
          ~s[<text x="#{cx - 270}" y="#{sy + 18}" font-size="10" fill="#{@text_secondary}">#{esc(truncate(statement, 85))}</text>\n],
          ~s[<line x1="#{cx - 270}" y1="#{sy + 26}" x2="#{cx + 270}" y2="#{sy + 26}" stroke="#{@panel_border}" stroke-width="1" opacity="0.4"/>\n]
        ]
      end),
      # Jury votes (if in voting sub-phase)
      if sub_phase == "jury_voting" and map_size(ctx.jury_votes) > 0 do
        base_y = cy + 80

        [
          ~s[<text x="#{cx}" y="#{base_y}" text-anchor="middle" font-size="12" fill="#{@text_dim}">JURY VOTES CAST: #{map_size(ctx.jury_votes)}/#{length(ctx.jury)}</text>\n]
        ]
      else
        ""
      end,
      ~s[<text x="#{cx}" y="#{h - @footer_h - 20}" text-anchor="middle" font-size="10" fill="#{@text_dim}">The jury will decide the Sole Survivor.</text>\n]
    ]
  end

  defp render_generic_view(%{w: w, h: h, phase: phase}) do
    cx = @roster_w + div(w - @roster_w - @history_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    [
      ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" class="phase-text" ] <>
        ~s[font-size="20" fill="#{@text_secondary}">#{esc(String.upcase(phase))}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # History panel (right panel)
  # ---------------------------------------------------------------------------

  defp render_history_panel(%{w: w, h: h} = ctx) do
    panel_x = w - @history_w
    panel_h = h - @header_h - @footer_h

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@history_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@history_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@history_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@text_dim}">GAME HISTORY</text>\n],
      # Elimination tracker
      ~s[<text x="#{panel_x + 12}" y="#{@header_h + 50}" font-size="11" fill="#{@text_dim}">ELIMINATIONS</text>\n],
      ctx.elimination_log
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        player = get(entry, "player", get(entry, :player, "?"))
        ep = get(entry, "episode", get(entry, :episode, "?"))
        ey = @header_h + 64 + idx * 22
        is_jury = player in ctx.jury

        col = if is_jury, do: @jury_color, else: @eliminated_color

        [
          ~s[<circle cx="#{panel_x + 20}" cy="#{ey + 4}" r="4" fill="#{col}" opacity="0.6"/>\n],
          ~s[<text x="#{panel_x + 30}" y="#{ey + 8}" font-size="11" fill="#{@text_secondary}">Ep#{ep}: #{esc(player)}</text>\n],
          if is_jury do
            ~s[<text x="#{panel_x + @history_w - 12}" y="#{ey + 8}" text-anchor="end" font-size="9" fill="#{@jury_color}">jury</text>\n]
          else
            ""
          end
        ]
      end),
      # Jury list (if any)
      if length(ctx.jury) > 0 do
        jury_base_y = @header_h + 64 + length(ctx.elimination_log) * 22 + 20

        [
          ~s[<line x1="#{panel_x + 10}" y1="#{jury_base_y - 12}" x2="#{panel_x + @history_w - 10}" y2="#{jury_base_y - 12}" stroke="#{@panel_border}" stroke-width="1"/>\n],
          ~s[<text x="#{panel_x + 12}" y="#{jury_base_y}" font-size="11" fill="#{@text_dim}">JURY</text>\n],
          ctx.jury
          |> Enum.with_index()
          |> Enum.map(fn {juror, idx} ->
            jy = jury_base_y + 16 + idx * 20

            ~s[<text x="#{panel_x + 16}" y="#{jy}" font-size="11" fill="#{@jury_color}">#{esc(juror)}</text>\n]
          end)
        ]
      else
        ""
      end,
      # Vote history summary (last 5)
      if length(ctx.vote_history) > 0 do
        base_y = @header_h + 64 + length(ctx.elimination_log) * 22 + length(ctx.jury) * 20 + 56
        recent_votes = Enum.take(ctx.vote_history, -5)

        [
          ~s[<line x1="#{panel_x + 10}" y1="#{base_y - 14}" x2="#{panel_x + @history_w - 10}" y2="#{base_y - 14}" stroke="#{@panel_border}" stroke-width="1"/>\n],
          ~s[<text x="#{panel_x + 12}" y="#{base_y}" font-size="11" fill="#{@text_dim}">VOTE HISTORY</text>\n],
          recent_votes
          |> Enum.with_index()
          |> Enum.map(fn {vote_entry, idx} ->
            voter = get(vote_entry, "voter", get(vote_entry, :voter, "?"))
            target = get(vote_entry, "target", get(vote_entry, :target, "?"))
            vy = base_y + 16 + idx * 18

            ~s[<text x="#{panel_x + 12}" y="#{vy}" font-size="10" fill="#{@text_dim}">] <>
              ~s[#{esc(voter)} &#x2192; #{esc(target)}</text>\n]
          end)
        ]
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
        "Survivor begins. #{map_size(ctx.players)} players, #{map_size(ctx.tribes)} tribes."

      ctx.type == "game_over" ->
        "#{ctx.winner} wins Survivor! Sole Survivor!"

      has_event?(events, "game_over") ->
        ev = find_event(events, "game_over")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Game over!")

      has_event?(events, "vote_result") ->
        ev = find_event(events, "vote_result")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "The tribe has spoken.")

      has_event?(events, "player_eliminated") ->
        ev = find_event(events, "player_eliminated")
        p = get(ev, "payload", ev || %{})
        pid = get(p, "player_id", "?")
        "#{pid} has been voted out."

      has_event?(events, "tribes_merged") ->
        ev = find_event(events, "tribes_merged")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "The tribes have merged!")

      has_event?(events, "challenge_resolved") ->
        ev = find_event(events, "challenge_resolved")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Challenge resolved!")

      has_event?(events, "play_idol") ->
        ev = find_event(events, "play_idol")
        p = get(ev, "payload", ev || %{})
        pid = get(p, "player_id", "?")
        "#{pid} plays the Hidden Immunity Idol!"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Phase changed.")

      has_event?(events, "make_statement") ->
        ev = find_event(events, "make_statement")
        p = get(ev, "payload", ev || %{})
        pid = get(p, "player_id", "?")
        stmt = get(p, "statement", "")
        "#{pid}: \"#{truncate(stmt, 80)}\""

      has_event?(events, "cast_vote") ->
        ev = find_event(events, "cast_vote")
        p = get(ev, "payload", ev || %{})
        voter = get(p, "player_id", "?")
        target = get(p, "target_id", "?")
        "#{voter} casts a vote against #{target}"

      true ->
        phase_display(ctx.phase)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tribe_color(tribe_name, _merged) when is_binary(tribe_name) do
    cond do
      String.downcase(tribe_name) =~ "tala" -> @tala_color
      String.downcase(tribe_name) =~ "manu" -> @manu_color
      String.downcase(tribe_name) =~ "solana" -> @solana_color
      true -> @solana_color
    end
  end

  defp tribe_color(_, _), do: @solana_color

  defp status_color("alive", false), do: @alive_color
  defp status_color("alive", true), do: @jury_color
  defp status_color("eliminated", _), do: @eliminated_color
  defp status_color(_, _), do: @text_secondary

  defp phase_color("challenge"), do: @immune_color
  defp phase_color("strategy"), do: @tala_color
  defp phase_color("tribal_council"), do: @eliminated_color
  defp phase_color("final_tribal_council"), do: @solana_color
  defp phase_color("game_over"), do: @idol_color
  defp phase_color(_), do: @text_secondary

  defp phase_display("challenge"), do: "CHALLENGE"
  defp phase_display("strategy"), do: "STRATEGY"
  defp phase_display("tribal_council"), do: "TRIBAL COUNCIL"
  defp phase_display("final_tribal_council"), do: "FINAL TRIBAL COUNCIL"
  defp phase_display("game_over"), do: "GAME OVER"
  defp phase_display(p), do: String.upcase(p || "")

  defp sub_phase_label("jury_statements"), do: "Jury Questions"
  defp sub_phase_label("finalist_pleas"), do: "Finalist Pleas"
  defp sub_phase_label("jury_voting"), do: "Jury Voting"
  defp sub_phase_label(p), do: String.capitalize(p || "")

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _), do: str || ""

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
