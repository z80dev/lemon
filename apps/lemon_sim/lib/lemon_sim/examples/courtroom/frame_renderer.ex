defmodule LemonSim.Examples.Courtroom.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (legal/judicial theme)
  # ---------------------------------------------------------------------------
  @bg "#0d0f14"
  @panel_bg "#161b26"
  @panel_border "#252d3d"

  @gold "#d4af37"
  @gold_dim "#7a6520"

  @text_primary "#e8eaf0"
  @text_secondary "#8892a4"
  @text_dim "#4a5568"

  @prosecution_color "#c0392b"
  @defense_color "#2980b9"
  @witness_color "#27ae60"
  @jury_color "#8e44ad"

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 320
  @evidence_w 280

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
    phase = get(world, "phase", "opening_statements")
    testimony_log = get(world, "testimony_log", [])
    evidence_presented = get(world, "evidence_presented", [])
    objections = get(world, "objections", [])
    verdict_votes = get(world, "verdict_votes", %{})
    case_file = get(world, "case_file", %{})
    winner = get(world, "winner", nil)
    outcome = get(world, "outcome", nil)
    active_actor = get(world, "active_actor_id", nil)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      turn_order: turn_order,
      phase: phase,
      testimony_log: testimony_log,
      evidence_presented: evidence_presented,
      objections: objections,
      verdict_votes: verdict_votes,
      case_file: case_file,
      winner: winner,
      outcome: outcome,
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
      render_evidence_panel(ctx),
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
      text { font-family: 'Georgia', 'Times New Roman', serif; }
      .title { font-family: 'Georgia', serif; font-weight: 700; }
      .label { font-family: sans-serif; font-size: 11px; fill: #{@text_secondary}; }
      .header-text { font-family: sans-serif; fill: #{@text_primary}; }
      .event-text { font-family: 'Georgia', serif; fill: #{@text_primary}; font-style: italic; }
      .player-name { font-family: sans-serif; font-weight: 600; }
      .role-name { font-family: sans-serif; font-weight: 700; }
      .testimony-text { font-family: 'Georgia', serif; font-size: 11px; }
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
    title_text = get(ctx.case_file, "title", get(ctx.case_file, :title, "Courtroom Trial"))

    phase_text =
      if type not in ["init", "verdict"] do
        phase_label(ctx.phase)
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="20" y="38" class="header-text title" font-size="20" fill="#{@gold}">COURT OF LAW</text>\n],
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="16" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(title_text)}</text>\n],
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 200}" y="14" width="130" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 265}" y="32" text-anchor="middle" font-size="11" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(phase_text)}</text>\n]
      else
        ""
      end,
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
        render_player_card(pid, player, idx, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">COURT PARTICIPANTS</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, ctx) do
    y = @header_h + 36 + idx * 110
    role = get(player, "role", get(player, :role, "unknown"))
    is_active = ctx.active_actor == pid
    is_winner = ctx.winner == pid

    color = role_color(role)
    display_name = format_player_name(pid)

    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="104" ] <>
            ~s[fill="#{@gold}" opacity="0.10" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="104" ] <>
            ~s[fill="none" stroke="#{@gold}" stroke-width="2" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="104" ] <>
            ~s[fill="#{color}" opacity="0.07" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="104" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    verdict_text =
      case role do
        "juror" ->
          vote = Map.get(ctx.verdict_votes, pid)

          if vote do
            vote_color = if vote == "guilty", do: @prosecution_color, else: @defense_color

            ~s[<text x="#{@roster_w - 16}" y="#{y + 68}" text-anchor="end" font-size="10" ] <>
              ~s[font-weight="700" fill="#{vote_color}">#{String.upcase(vote)}</text>\n]
          else
            ""
          end

        _ ->
          ""
      end

    winner_badge =
      if is_winner do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 84}" text-anchor="end" font-size="11" ] <>
          ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
      else
        ""
      end

    [
      highlight,
      ~s[<circle cx="22" cy="#{y + 9}" r="7" fill="#{color}" opacity="0.9"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="role-name" font-size="13" fill="#{color}">#{esc(role_label(role))}</text>\n],
      ~s[<text x="36" y="#{y + 30}" class="player-name" font-size="11" fill="#{@text_secondary}">#{esc(display_name)}</text>\n],
      if is_active do
        ~s[<text x="16" y="#{y + 52}" font-size="10" fill="#{color}" font-weight="700">&#x25B6; ACTIVE</text>\n]
      else
        ""
      end,
      verdict_text,
      winner_badge
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "verdict" -> render_verdict_card(ctx)
      _ -> render_testimony_panel(ctx)
    end
  end

  defp render_init_card(%{w: w, h: h, case_file: case_file}) do
    cx = @roster_w + div(w - @roster_w - @evidence_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    title = get(case_file, "title", get(case_file, :title, "Courtroom Trial"))
    description = get(case_file, "description", get(case_file, :description, ""))
    defendant = get(case_file, "defendant", get(case_file, :defendant, "Unknown"))

    [
      ~s[<rect x="#{cx - 300}" y="#{cy - 150}" width="600" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 100}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@gold}">COURT IN SESSION</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 65}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{esc(title)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 35}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">Defendant: #{esc(defendant)}</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{cy - 20}" x2="#{cx + 200}" y2="#{cy - 20}" ] <>
        ~s[stroke="#{@gold_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 5}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_secondary}">#{esc(String.slice(description, 0, 120))}...</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 60}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_dim}">Opening Statements &#xB7; Examination &#xB7; Deliberation &#xB7; Verdict</text>\n]
    ]
  end

  defp render_verdict_card(%{
         w: w,
         h: h,
         outcome: outcome,
         verdict_votes: verdict_votes,
         players: players,
         winner: winner
       }) do
    cx = @roster_w + div(w - @roster_w - @evidence_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    outcome_color =
      case outcome do
        "guilty" -> @prosecution_color
        "not_guilty" -> @defense_color
        _ -> @text_secondary
      end

    outcome_label =
      case outcome do
        "guilty" -> "GUILTY"
        "not_guilty" -> "NOT GUILTY"
        "hung_jury" -> "HUNG JURY"
        _ -> "TRIAL CONCLUDED"
      end

    guilty_count = verdict_votes |> Map.values() |> Enum.count(&(&1 == "guilty"))
    not_guilty_count = verdict_votes |> Map.values() |> Enum.count(&(&1 == "not_guilty"))

    winner_info =
      if winner do
        p = Map.get(players, winner, %{})
        role = get(p, "role", get(p, :role, "unknown"))
        "#{role_label(role)} (#{format_player_name(winner)}) wins"
      else
        "No winner"
      end

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - 160}" width="560" height="320" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{outcome_color}" stroke-width="3" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 110}" text-anchor="middle" class="title" ] <>
        ~s[font-size="14" fill="#{@text_dim}" letter-spacing="3">THE JURY FINDS THE DEFENDANT</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 55}" text-anchor="middle" class="title" ] <>
        ~s[font-size="48" fill="#{outcome_color}" filter="url(#glow)">#{outcome_label}</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{cy - 30}" x2="#{cx + 200}" y2="#{cy - 30}" ] <>
        ~s[stroke="#{outcome_color}" stroke-width="1" opacity="0.5"/>\n],
      ~s[<text x="#{cx - 60}" y="#{cy + 10}" text-anchor="middle" font-size="22" fill="#{@prosecution_color}">#{guilty_count}</text>\n],
      ~s[<text x="#{cx - 60}" y="#{cy + 30}" text-anchor="middle" font-size="11" fill="#{@text_dim}">GUILTY</text>\n],
      ~s[<text x="#{cx + 60}" y="#{cy + 10}" text-anchor="middle" font-size="22" fill="#{@defense_color}">#{not_guilty_count}</text>\n],
      ~s[<text x="#{cx + 60}" y="#{cy + 30}" text-anchor="middle" font-size="11" fill="#{@text_dim}">NOT GUILTY</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 80}" text-anchor="middle" font-size="13" fill="#{@gold}">#{esc(winner_info)}</text>\n]
    ]
  end

  defp render_testimony_panel(%{w: w, h: h, testimony_log: testimony_log, players: players} = ctx) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @evidence_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_entries = Enum.take(testimony_log, -14)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">COURT RECORD</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_entries == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Court is called to order...</text>\n]
      else
        recent_entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          ey = panel_y + 48 + idx * 35
          type = get(entry, "type", get(entry, :type, ""))

          player_id =
            get(
              entry,
              "player_id",
              get(entry, :player_id, get(entry, "asker_id", get(entry, :asker_id, "?")))
            )

          content = get(entry, "content", get(entry, :content, ""))

          player = Map.get(players, player_id, %{})
          role = get(player, "role", get(player, :role, "unknown"))
          color = role_color(role)
          is_recent = idx >= length(recent_entries) - 4
          opacity = if is_recent, do: "1", else: "0.45"
          type_icon = entry_type_icon(type)

          short_content = if is_binary(content), do: String.slice(content, 0, 90), else: ""

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 20}" cy="#{ey + 8}" r="5" fill="#{color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{ey + 12}" font-size="10" font-weight="700" fill="#{color}">#{esc(role_label(role))} #{type_icon}</text>\n],
            ~s[<text x="#{panel_x + 16}" y="#{ey + 28}" class="testimony-text" fill="#{@text_secondary}">#{esc(short_content)}#{if String.length(content || "") > 90, do: "...", else: ""}</text>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, players)
    ]
  end

  defp render_active_indicator(%{active_actor: nil}, _px, _py, _pw, _ph, _players), do: ""

  defp render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, players) do
    actor = ctx.active_actor
    player = Map.get(players, actor, %{})
    role = get(player, "role", get(player, :role, "unknown"))
    color = role_color(role)

    [
      ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
        ~s[fill="#{color}" opacity="0.1" rx="4"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
        ~s[font-size="12" fill="#{color}">#{esc(role_label(role))} (#{esc(format_player_name(actor))}) is speaking...</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Evidence panel (right panel)
  # ---------------------------------------------------------------------------

  defp render_evidence_panel(
         %{
           w: w,
           h: h,
           evidence_presented: evidence_presented,
           case_file: case_file,
           objections: objections
         } = _ctx
       ) do
    panel_x = w - @evidence_w
    panel_h = h - @header_h - @footer_h
    evidence_details = get(case_file, "evidence_details", get(case_file, :evidence_details, %{}))

    sustain_count =
      Enum.count(objections, &(get(&1, "ruling", get(&1, :ruling, "")) == "sustained"))

    overrule_count =
      Enum.count(objections, &(get(&1, "ruling", get(&1, :ruling, "")) == "overruled"))

    evidence_entries =
      evidence_presented
      |> Enum.with_index()
      |> Enum.map(fn {ev_id, idx} ->
        ey = @header_h + 40 + idx * 32
        info = Map.get(evidence_details, ev_id, %{})
        is_incriminating = get(info, "incriminating", get(info, :incriminating, false))
        color = if is_incriminating, do: @prosecution_color, else: @defense_color
        label = String.slice(ev_id, 0, 24)

        [
          ~s[<rect x="#{panel_x + 8}" y="#{ey - 10}" width="#{@evidence_w - 16}" height="24" ] <>
            ~s[fill="#{color}" opacity="0.10" rx="3"/>\n],
          ~s[<circle cx="#{panel_x + 20}" cy="#{ey + 2}" r="4" fill="#{color}"/>\n],
          ~s[<text x="#{panel_x + 32}" y="#{ey + 6}" font-size="10" fill="#{color}">#{esc(label)}</text>\n]
        ]
      end)

    objection_y = @header_h + 40 + max(length(evidence_presented), 1) * 32 + 20

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@evidence_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@evidence_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@evidence_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">EVIDENCE</text>\n],
      if evidence_entries == [] do
        ~s[<text x="#{panel_x + div(@evidence_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No evidence submitted</text>\n]
      else
        evidence_entries
      end,
      # Objections tally
      ~s[<text x="#{panel_x + 12}" y="#{objection_y}" font-size="10" fill="#{@gold_dim}" letter-spacing="1">OBJECTIONS</text>\n],
      ~s[<text x="#{panel_x + 12}" y="#{objection_y + 18}" font-size="10" fill="#{@witness_color}">Sustained: #{sustain_count}</text>\n],
      ~s[<text x="#{panel_x + 12}" y="#{objection_y + 34}" font-size="10" fill="#e74c3c">Overruled: #{overrule_count}</text>\n]
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
        ~s[class="event-text" font-size="15" fill="#{@text_primary}">#{esc(event_text)}</text>\n]
    ]
  end

  defp format_footer_text(ctx) do
    events = ctx.events

    cond do
      ctx.type == "init" ->
        title = get(ctx.case_file, "title", get(ctx.case_file, :title, "Trial"))
        "The court is called to order. #{title} begins."

      ctx.type == "verdict" ->
        outcome_label =
          case ctx.outcome do
            "guilty" -> "GUILTY"
            "not_guilty" -> "NOT GUILTY"
            "hung_jury" -> "HUNG JURY — mistrial declared"
            _ -> "Trial concluded"
          end

        "The jury has reached a verdict: #{outcome_label}"

      has_event?(events, "verdict_reached") ->
        "The jury has completed deliberations."

      has_event?(events, "verdict_cast") ->
        ev = find_event(events, "verdict_cast")
        p = get(ev, "payload", ev || %{})
        juror_id = get(p, "juror_id", "?")
        vote = get(p, "vote", "?")
        "Juror #{format_player_name(juror_id)} votes: #{vote}"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        to_phase = get(p, "to", "?")
        "Court advances to: #{phase_label(to_phase)}"

      has_event?(events, "objection_ruled") ->
        ev = find_event(events, "objection_ruled")
        p = get(ev, "payload", ev || %{})
        ruling = get(p, "ruling", "?")
        "Objection #{ruling}!"

      has_event?(events, "evidence_admitted") ->
        ev = find_event(events, "evidence_admitted")
        p = get(ev, "payload", ev || %{})
        ev_id = get(p, "evidence_id", "?")
        "Evidence admitted: #{ev_id}"

      has_event?(events, "witness_called") ->
        ev = find_event(events, "witness_called")
        p = get(ev, "payload", ev || %{})
        witness = get(p, "witness_id", "?")
        "#{format_player_name(witness)} called to the stand."

      has_event?(events, "statement_recorded") ->
        phase_label(ctx.phase) <> " — statement recorded"

      true ->
        case ctx.phase do
          "opening_statements" -> "Opening statements are being delivered..."
          "prosecution_case" -> "The prosecution is presenting its case..."
          "cross_examination" -> "Defense is cross-examining witnesses..."
          "defense_case" -> "The defense is presenting its case..."
          "defense_cross" -> "Prosecution is cross-examining defense witnesses..."
          "closing_arguments" -> "Closing arguments are underway..."
          "deliberation" -> "The jury is deliberating in private..."
          "verdict" -> "The jury is casting their final votes..."
          _ -> "Court is in session."
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp role_color("prosecution"), do: @prosecution_color
  defp role_color("defense"), do: @defense_color
  defp role_color("witness"), do: @witness_color
  defp role_color("juror"), do: @jury_color
  defp role_color(_), do: @text_secondary

  defp role_label("prosecution"), do: "Prosecution"
  defp role_label("defense"), do: "Defense"
  defp role_label("witness"), do: "Witness"
  defp role_label("juror"), do: "Juror"
  defp role_label(other), do: String.capitalize(to_string(other))

  defp phase_label("opening_statements"), do: "Opening Statements"
  defp phase_label("prosecution_case"), do: "Prosecution's Case"
  defp phase_label("cross_examination"), do: "Cross-Examination"
  defp phase_label("defense_case"), do: "Defense's Case"
  defp phase_label("defense_cross"), do: "Defense Cross-Examination"
  defp phase_label("closing_arguments"), do: "Closing Arguments"
  defp phase_label("deliberation"), do: "Jury Deliberation"
  defp phase_label("verdict"), do: "Verdict"
  defp phase_label(other), do: String.capitalize(to_string(other))

  defp phase_color("opening_statements"), do: "#2980b9"
  defp phase_color("prosecution_case"), do: @prosecution_color
  defp phase_color("cross_examination"), do: "#e67e22"
  defp phase_color("defense_case"), do: @defense_color
  defp phase_color("defense_cross"), do: "#e67e22"
  defp phase_color("closing_arguments"), do: "#2980b9"
  defp phase_color("deliberation"), do: @jury_color
  defp phase_color("verdict"), do: @gold
  defp phase_color(_), do: @text_secondary

  defp entry_type_icon("statement"), do: "&#x1F4DC;"
  defp entry_type_icon("question"), do: "&#x2753;"
  defp entry_type_icon("challenge"), do: "&#x26A0;"
  defp entry_type_icon(_), do: ""

  defp format_player_name(nil), do: "?"
  defp format_player_name("player_" <> n), do: "Player #{n}"
  defp format_player_name("witness_" <> n), do: "Witness #{n}"
  defp format_player_name("juror_" <> n), do: "Juror #{n}"
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
