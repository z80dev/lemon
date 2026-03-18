defmodule LemonSim.Examples.StartupIncubator.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (startup / VC theme)
  # ---------------------------------------------------------------------------
  @bg "#0a0d14"
  @panel_bg "#131826"
  @panel_border "#1e2a40"

  @accent "#00d4aa"
  @accent_dim "#1a5c52"

  @text_primary "#e8edf5"
  @text_secondary "#7a8ba0"
  @text_dim "#3d4d60"

  # Player colors (up to 6 players)
  @player_colors ["#e63946", "#457b9d", "#2a9d8f", "#e9c46a", "#a8dadc", "#f4a261"]

  # Sector badge colors
  @sector_colors %{
    "ai" => "#7c3aed",
    "fintech" => "#0891b2",
    "healthtech" => "#059669",
    "edtech" => "#d97706",
    "climatetech" => "#16a34a",
    "ecommerce" => "#dc2626"
  }

  # Layout constants
  @header_h 60
  @footer_h 70
  @sidebar_w 320
  @market_w 280

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
    startups = get(world, "startups", %{})
    investors_map = get(world, "investors", %{})
    turn_order = get(world, "turn_order", Map.keys(players) |> Enum.sort())
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 5)
    phase = get(world, "phase", "pitch")
    market_conditions = get(world, "market_conditions", %{})
    deal_history = get(world, "deal_history", [])
    pitch_log = get(world, "pitch_log", [])
    winner = get(world, "winner", nil)
    active_actor = get(world, "active_actor_id", nil)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      startups: startups,
      investors_map: investors_map,
      turn_order: turn_order,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      market_conditions: market_conditions,
      deal_history: deal_history,
      pitch_log: pitch_log,
      winner: winner,
      active_actor: active_actor
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_sidebar(ctx),
      render_center_content(ctx),
      render_market_panel(ctx),
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
      <linearGradient id="headerGrad" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0%" stop-color="#0a0d14"/>
        <stop offset="100%" stop-color="#131826"/>
      </linearGradient>
    </defs>
    """
  end

  defp svg_style do
    ~s"""
    <style>
      text { font-family: 'Inter', 'Segoe UI', sans-serif; }
      .title { font-weight: 700; }
      .label { font-size: 10px; fill: #{@text_secondary}; }
      .header-text { fill: #{@text_primary}; }
      .event-text { fill: #{@text_primary}; }
      .player-name { font-weight: 600; }
      .metric-val { font-weight: 700; }
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
      if type == "game_over", do: "FINAL RESULTS", else: "Round #{ctx.round}/#{ctx.max_rounds}"

    phase_text =
      if type not in ["init", "game_over"],
        do: String.upcase(String.replace(ctx.phase, "_", " ")),
        else: ""

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="url(#headerGrad)"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@accent}">STARTUP INCUBATOR</text>\n],
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 130}" y="14" width="130" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 195}" y="32" text-anchor="middle" font-size="12" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(phase_text)}</text>\n]
      else
        ""
      end,
      ~s[<text x="#{w - 20}" y="18" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Player sidebar (left panel)
  # ---------------------------------------------------------------------------

  defp render_player_sidebar(%{h: h, turn_order: turn_order, players: players} = ctx) do
    panel_h = h - @header_h - @footer_h

    player_entries =
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {pid, idx} ->
        player = Map.get(players, pid, %{})
        color = Enum.at(@player_colors, idx, "#ecf0f1")
        render_player_card(pid, player, idx, color, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@sidebar_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.98"/>\n],
      ~s[<line x1="#{@sidebar_w}" y1="#{@header_h}" x2="#{@sidebar_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@sidebar_w}" height="28" fill="#{@panel_bg}" opacity="0.7"/>\n],
      ~s[<text x="#{div(@sidebar_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@accent_dim}">PORTFOLIO ROOM</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 160
    role = get(player, "role", "founder")
    is_active = ctx.active_actor == pid
    is_winner = ctx.winner == pid

    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@sidebar_w - 8}" height="154" ] <>
            ~s[fill="#{@accent}" opacity="0.1" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@sidebar_w - 8}" height="154" ] <>
            ~s[fill="none" stroke="#{@accent}" stroke-width="2" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@sidebar_w - 8}" height="154" ] <>
            ~s[fill="#{color}" opacity="0.07" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@sidebar_w - 8}" height="154" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.5"/>\n]

        true ->
          ""
      end

    [
      highlight,
      if role == "founder" do
        render_founder_card(pid, player, idx, color, y, is_winner, ctx)
      else
        render_investor_card(pid, player, idx, color, y, is_winner, ctx)
      end
    ]
  end

  defp render_founder_card(pid, player, idx, color, y, is_winner, ctx) do
    startup = Map.get(ctx.startups, pid, %{})
    sector = get(startup, "sector", get(startup, :sector, "unknown"))
    valuation = get(startup, "valuation", get(startup, :valuation, 0))
    traction = get(startup, "traction", get(startup, :traction, 0))
    employees = get(startup, "employees", get(startup, :employees, 0))
    cash = get(startup, "cash_on_hand", get(startup, :cash_on_hand, 0))
    funding = get(startup, "funding_raised", get(startup, :funding_raised, 0))
    sector_color = Map.get(@sector_colors, sector, @text_secondary)

    idx_str = Enum.at(@player_colors, idx, color)
    _ = idx_str

    [
      ~s[<circle cx="22" cy="#{y + 10}" r="7" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 15}" class="player-name" font-size="13" fill="#{color}">#{esc(pid)}</text>\n],
      ~s[<rect x="#{@sidebar_w - 70}" y="#{y + 2}" width="60" height="16" rx="3" fill="#{sector_color}" opacity="0.25"/>\n],
      ~s[<text x="#{@sidebar_w - 40}" y="#{y + 14}" text-anchor="middle" font-size="9" font-weight="700" fill="#{sector_color}">#{esc(String.upcase(sector))}</text>\n],
      ~s[<text x="16" y="#{y + 38}" font-size="10" fill="#{@text_secondary}">Valuation</text>\n],
      ~s[<text x="#{@sidebar_w - 16}" y="#{y + 38}" text-anchor="end" font-size="12" font-weight="700" fill="#{@text_primary}">$#{format_number(valuation)}</text>\n],
      ~s[<text x="16" y="#{y + 58}" font-size="10" fill="#{@text_secondary}">Traction / Employees</text>\n],
      ~s[<text x="#{@sidebar_w - 16}" y="#{y + 58}" text-anchor="end" font-size="11" fill="#{@text_primary}">#{traction} / #{employees}</text>\n],
      ~s[<text x="16" y="#{y + 78}" font-size="10" fill="#{@text_secondary}">Cash / Raised</text>\n],
      ~s[<text x="#{@sidebar_w - 16}" y="#{y + 78}" text-anchor="end" font-size="11" fill="#{@text_primary}">$#{format_number(cash)} / $#{format_number(funding)}</text>\n],
      if is_winner do
        ~s[<text x="#{@sidebar_w - 16}" y="#{y + 100}" text-anchor="end" font-size="12" ] <>
          ~s[font-weight="700" fill="#{@accent}" filter="url(#glow)">WINNER</text>\n]
      else
        ""
      end
    ]
  end

  defp render_investor_card(pid, _player, idx, color, y, is_winner, ctx) do
    investor = Map.get(ctx.investors_map, pid, %{})
    fund_size = get(investor, "fund_size", get(investor, :fund_size, 0))
    remaining = get(investor, "remaining_capital", get(investor, :remaining_capital, 0))
    portfolio = get(investor, "portfolio", get(investor, :portfolio, []))
    deployed = fund_size - remaining
    pct_deployed = if fund_size > 0, do: round(deployed / fund_size * 100), else: 0

    _ = idx

    bar_w = @sidebar_w - 40
    fill_w = round(bar_w * min(pct_deployed / 100, 1.0))

    [
      ~s[<circle cx="22" cy="#{y + 10}" r="7" fill="#{color}"/>\n],
      ~s[<rect x="30" y="#{y + 3}" width="24" height="14" rx="2" fill="#{color}" opacity="0.2"/>\n],
      ~s[<text x="42" y="#{y + 14}" text-anchor="middle" font-size="8" fill="#{color}">VC</text>\n],
      ~s[<text x="60" y="#{y + 15}" class="player-name" font-size="13" fill="#{color}">#{esc(pid)}</text>\n],
      ~s[<text x="16" y="#{y + 38}" font-size="10" fill="#{@text_secondary}">Fund Size</text>\n],
      ~s[<text x="#{@sidebar_w - 16}" y="#{y + 38}" text-anchor="end" font-size="12" font-weight="700" fill="#{@text_primary}">$#{format_number(fund_size)}</text>\n],
      ~s[<text x="16" y="#{y + 56}" font-size="10" fill="#{@text_secondary}">Capital Deployed #{pct_deployed}%</text>\n],
      ~s[<rect x="16" y="#{y + 62}" width="#{bar_w}" height="8" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="16" y="#{y + 62}" width="#{max(fill_w, 0)}" height="8" fill="#{color}" rx="3" opacity="0.8"/>\n],
      ~s[<text x="16" y="#{y + 86}" font-size="10" fill="#{@text_secondary}">Portfolio: #{length(portfolio)} companies</text>\n],
      if is_winner do
        ~s[<text x="#{@sidebar_w - 16}" y="#{y + 86}" text-anchor="end" font-size="12" ] <>
          ~s[font-weight="700" fill="#{@accent}" filter="url(#glow)">WINNER</text>\n]
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

  defp render_init_card(%{w: w, h: h, turn_order: turn_order}) do
    cx = @sidebar_w + div(w - @sidebar_w - @market_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)
    player_count = length(turn_order)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@accent}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="30" fill="#{@accent}">STARTUP INCUBATOR</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 58}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Multi-Phase Resource Allocation &amp; Coalition Formation</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Players &#xB7; 5 Rounds &#xB7; 5 Phases per Round</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 24}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">Pitch &#xB7; Due Diligence &#xB7; Negotiation &#xB7; Market Event &#xB7; Operations</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 56}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Win by achieving highest startup valuation or portfolio return</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@accent_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 102}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Information asymmetry &#xB7; Bluff &#xB7; Coalition &#xB7; Dominate</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h, turn_order: turn_order, players: players, startups: startups, investors_map: investors_map, winner: winner}) do
    cx = @sidebar_w + div(w - @sidebar_w - @market_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    sorted =
      turn_order
      |> Enum.map(fn pid ->
        player = Map.get(players, pid, %{})
        role = get(player, "role", "founder")

        score =
          if role == "founder" do
            startup = Map.get(startups, pid, %{})
            get(startup, "valuation", get(startup, :valuation, 0))
          else
            investor = Map.get(investors_map, pid, %{})
            Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0))
          end

        {pid, score, role}
      end)
      |> Enum.sort_by(fn {_, score, _} -> -score end)

    card_h = 90 + length(sorted) * 52

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@accent}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 44}" text-anchor="middle" class="title" ] <>
        ~s[font-size="26" fill="#{@accent}">FINAL STANDINGS</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, score, role}, rank} ->
        sy = cy - div(card_h, 2) + 74 + rank * 52
        is_winner = pid == winner
        color = if is_winner, do: @accent, else: @text_primary
        player = Map.get(players, pid, %{})
        _ = player

        role_label = if role == "founder", do: "Founder", else: "Investor"
        score_label = if role == "founder", do: "Val: $#{format_number(score)}", else: "Capital: $#{format_number(score)}"

        [
          if is_winner do
            ~s[<rect x="#{cx - 260}" y="#{sy - 20}" width="520" height="46" ] <>
              ~s[fill="#{@accent}" opacity="0.07" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 8}" font-size="14" fill="#{@text_dim}">##{rank + 1}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 8}" class="player-name" font-size="16" fill="#{color}">#{esc(pid)}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 22}" font-size="9" fill="#{@text_dim}">#{role_label}</text>\n],
          ~s[<text x="#{cx + 100}" y="#{sy + 8}" text-anchor="end" font-size="14" fill="#{color}">#{score_label}</text>\n],
          if is_winner do
            ~s[<text x="#{cx + 240}" y="#{sy + 8}" text-anchor="end" font-size="12" ] <>
              ~s[font-weight="700" fill="#{@accent}" filter="url(#glow)">WINNER</text>\n]
          else
            ""
          end
        ]
      end)
    ]
  end

  defp render_phase_content(ctx) do
    case ctx.phase do
      "pitch" -> render_pitch_panel(ctx)
      "due_diligence" -> render_diligence_panel(ctx)
      "negotiation" -> render_negotiation_panel(ctx)
      "operations" -> render_operations_panel(ctx)
      _ -> render_pitch_panel(ctx)
    end
  end

  defp render_pitch_panel(%{w: w, h: h, pitch_log: pitch_log, players: players} = ctx) do
    panel_x = @sidebar_w + 10
    panel_y = @header_h + 10
    panel_w = w - @sidebar_w - @market_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent = Enum.take(pitch_log, -10)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@accent_dim}">PITCH STAGE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Awaiting pitches...</text>\n]
      else
        recent
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          ey = panel_y + 48 + idx * 54

          founder_id =
            get(entry, "founder_id", get(entry, :founder_id, "?"))

          pitch_text =
            entry
            |> (fn e -> get(e, "pitch_text", get(e, :pitch_text, "")) end).()
            |> truncate(80)

          round_num = get(entry, "round", get(entry, :round, "?"))

          turn_idx =
            Enum.find_index(ctx.turn_order, &(&1 == founder_id)) || 0

          color = Enum.at(@player_colors, turn_idx, @text_secondary)
          startup = Map.get(ctx.startups, founder_id, %{})
          sector = get(startup, "sector", get(startup, :sector, "?"))
          sector_color = Map.get(@sector_colors, sector, @text_secondary)
          _ = players

          [
            ~s[<rect x="#{panel_x + 10}" y="#{ey - 4}" width="#{panel_w - 20}" height="44" ] <>
              ~s[fill="#{color}" opacity="0.05" rx="4"/>\n],
            ~s[<circle cx="#{panel_x + 26}" cy="#{ey + 10}" r="6" fill="#{color}"/>\n],
            ~s[<text x="#{panel_x + 40}" y="#{ey + 14}" font-size="12" font-weight="600" fill="#{color}">#{esc(founder_id)}</text>\n],
            ~s[<rect x="#{panel_x + panel_w - 120}" y="#{ey + 2}" width="60" height="14" rx="3" fill="#{sector_color}" opacity="0.2"/>\n],
            ~s[<text x="#{panel_x + panel_w - 90}" y="#{ey + 13}" text-anchor="middle" font-size="8" fill="#{sector_color}">#{esc(String.upcase(sector))}</text>\n],
            ~s[<text x="#{panel_x + panel_w - 18}" y="#{ey + 14}" text-anchor="end" font-size="10" fill="#{@text_dim}">R#{round_num}</text>\n],
            ~s[<text x="#{panel_x + 40}" y="#{ey + 32}" font-size="11" fill="#{@text_secondary}">#{esc(pitch_text)}</text>\n]
          ]
        end)
      end,
      render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, "pitching...")
    ]
  end

  defp render_diligence_panel(%{w: w, h: h} = ctx) do
    panel_x = @sidebar_w + 10
    panel_y = @header_h + 10
    panel_w = w - @sidebar_w - @market_w - 20
    panel_h = h - @header_h - @footer_h - 20

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@accent_dim}">DUE DILIGENCE</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
        ~s[font-size="12" fill="#{@text_dim}">Investors probing founders — truth is optional.</text>\n],
      render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, "in due diligence...")
    ]
  end

  defp render_negotiation_panel(%{w: w, h: h, deal_history: deal_history, players: players, turn_order: turn_order} = ctx) do
    panel_x = @sidebar_w + 10
    panel_y = @header_h + 10
    panel_w = w - @sidebar_w - @market_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_deals = Enum.take(deal_history, -10)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@accent_dim}">DEAL ROOM</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_deals == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">No deals closed yet</text>\n]
      else
        recent_deals
        |> Enum.with_index()
        |> Enum.map(fn {deal, idx} ->
          dy = panel_y + 48 + idx * 36

          founder_id = get(deal, "founder_id", get(deal, :founder_id, "?"))
          investor_id = get(deal, "investor_id", get(deal, :investor_id, "?"))
          amount = get(deal, "amount", get(deal, :amount, 0))
          equity = get(deal, "equity_pct", get(deal, :equity_pct, 0))
          round_num = get(deal, "round", get(deal, :round, "?"))

          f_idx = Enum.find_index(turn_order, &(&1 == founder_id)) || 0
          i_idx = Enum.find_index(turn_order, &(&1 == investor_id)) || 0
          f_color = Enum.at(@player_colors, f_idx, @text_secondary)
          i_color = Enum.at(@player_colors, i_idx, @text_secondary)
          _ = players

          [
            ~s[<rect x="#{panel_x + 10}" y="#{dy - 2}" width="#{panel_w - 20}" height="28" ] <>
              ~s[fill="#{@accent}" opacity="0.06" rx="3"/>\n],
            ~s[<circle cx="#{panel_x + 26}" cy="#{dy + 12}" r="5" fill="#{i_color}"/>\n],
            ~s[<text x="#{panel_x + 36}" y="#{dy + 16}" font-size="11" fill="#{i_color}">#{esc(investor_id)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{dy + 16}" text-anchor="middle" font-size="10" font-weight="700" fill="#{@accent}">$#{format_number(amount)} / #{equity}%</text>\n],
            ~s[<circle cx="#{panel_x + panel_w - 100}" cy="#{dy + 12}" r="5" fill="#{f_color}"/>\n],
            ~s[<text x="#{panel_x + panel_w - 90}" y="#{dy + 16}" font-size="11" fill="#{f_color}">#{esc(founder_id)}</text>\n],
            ~s[<text x="#{panel_x + panel_w - 18}" y="#{dy + 16}" text-anchor="end" font-size="9" fill="#{@text_dim}">R#{round_num}</text>\n]
          ]
        end)
      end,
      render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, "negotiating...")
    ]
  end

  defp render_operations_panel(%{w: w, h: h} = ctx) do
    panel_x = @sidebar_w + 10
    panel_y = @header_h + 10
    panel_w = w - @sidebar_w - @market_w - 20
    panel_h = h - @header_h - @footer_h - 20

    market_event_log = get(ctx, :market_event_log, [])
    last_event = List.last(market_event_log)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@accent_dim}">OPERATIONS</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if last_event do
        event_name = get(last_event, "name", get(last_event, :name, "Market Event"))
        event_desc = get(last_event, "description", get(last_event, :description, ""))

        [
          ~s[<rect x="#{panel_x + 16}" y="#{panel_y + 48}" width="#{panel_w - 32}" height="60" rx="6" fill="#{@panel_border}" opacity="0.5"/>\n],
          ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 72}" text-anchor="middle" font-size="14" font-weight="700" fill="#{@accent}">#{esc(event_name)}</text>\n],
          ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 92}" text-anchor="middle" font-size="11" fill="#{@text_secondary}">#{esc(truncate(event_desc, 70))}</text>\n]
        ]
      else
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" font-size="12" fill="#{@text_dim}">Allocating resources...</text>\n]
      end,
      render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, "allocating funds...")
    ]
  end

  defp render_active_indicator(%{active_actor: nil}, _px, _py, _pw, _ph, _text), do: ""

  defp render_active_indicator(ctx, panel_x, panel_y, panel_w, panel_h, action_text) do
    actor_id = ctx.active_actor
    turn_idx = Enum.find_index(ctx.turn_order, &(&1 == actor_id)) || 0
    actor_color = Enum.at(@player_colors, turn_idx, @text_secondary)

    [
      ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
        ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
        ~s[font-size="12" fill="#{actor_color}">#{esc(actor_id)} is #{action_text}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Market panel (right)
  # ---------------------------------------------------------------------------

  defp render_market_panel(%{w: w, h: h, market_conditions: conditions} = _ctx) do
    panel_x = w - @market_w
    panel_h = h - @header_h - @footer_h

    sector_list = Map.keys(conditions) |> Enum.sort()

    sector_entries =
      sector_list
      |> Enum.with_index()
      |> Enum.map(fn {sector, idx} ->
        multiplier = Map.get(conditions, sector, 6.0)
        sy = @header_h + 40 + idx * 58
        sector_color = Map.get(@sector_colors, sector, @text_secondary)

        # Bar for multiplier (max ~20x)
        bar_w = @market_w - 40
        fill_pct = min(multiplier / 20.0, 1.0)
        fill_w = round(bar_w * fill_pct)

        [
          ~s[<rect x="#{panel_x + 10}" y="#{sy - 10}" width="#{@market_w - 20}" height="48" ] <>
            ~s[fill="#{sector_color}" opacity="0.06" rx="4"/>\n],
          ~s[<text x="#{panel_x + 16}" y="#{sy + 8}" font-size="12" font-weight="700" fill="#{sector_color}">#{esc(String.upcase(sector))}</text>\n],
          ~s[<text x="#{panel_x + @market_w - 16}" y="#{sy + 8}" text-anchor="end" font-size="12" font-weight="700" fill="#{@text_primary}">#{Float.round(multiplier, 1)}x</text>\n],
          ~s[<rect x="#{panel_x + 16}" y="#{sy + 16}" width="#{bar_w}" height="6" fill="#{@panel_border}" rx="2"/>\n],
          ~s[<rect x="#{panel_x + 16}" y="#{sy + 16}" width="#{max(fill_w, 0)}" height="6" fill="#{sector_color}" rx="2" opacity="0.8"/>\n]
        ]
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@market_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.98"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@market_w}" height="28" fill="#{@panel_bg}" opacity="0.7"/>\n],
      ~s[<text x="#{panel_x + div(@market_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@accent_dim}">MARKET</text>\n],
      sector_entries,
      if conditions == %{} do
        ~s[<text x="#{panel_x + div(@market_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">Awaiting data...</text>\n]
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
        "Game begins: #{length(ctx.turn_order)} players enter the incubator"

      ctx.type == "game_over" ->
        winner = ctx.winner
        "#{winner} wins the Startup Incubator!"

      has_event?(events, "deal_closed") ->
        ev = find_event(events, "deal_closed")
        p = get(ev, "payload", ev || %{})
        founder = get(p, "founder_id", "?")
        investor = get(p, "investor_id", "?")
        amount = get(p, "amount", 0)
        "Deal closed: #{investor} invested $#{format_number(amount)} in #{founder}!"

      has_event?(events, "startups_merged") ->
        ev = find_event(events, "startups_merged")
        p = get(ev, "payload", ev || %{})
        a = get(p, "founder_a_id", "?")
        b = get(p, "founder_b_id", "?")
        "#{a} merges with #{b}!"

      has_event?(events, "market_event_applied") ->
        ev = find_event(events, "market_event_applied")
        p = get(ev, "payload", ev || %{})
        "Market event: #{get(p, "event_name", "unknown")}"

      has_event?(events, "pitch_delivered") ->
        ev = find_event(events, "pitch_delivered")
        p = get(ev, "payload", ev || %{})
        "#{get(p, "founder_id", "?")} delivers their pitch"

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        from = get(p, "from", "?")
        to = get(p, "to", "?")
        "Phase: #{from} -> #{to}"

      true ->
        phase_label =
          case ctx.phase do
            "pitch" -> "Founders pitching their startups..."
            "due_diligence" -> "Investors conducting due diligence..."
            "negotiation" -> "Term sheets being negotiated..."
            "market_event" -> "Market conditions shifting..."
            "operations" -> "Founders allocating resources..."
            _ -> ""
          end

        phase_label
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("pitch"), do: "#7c3aed"
  defp phase_color("due_diligence"), do: "#0891b2"
  defp phase_color("negotiation"), do: "#d97706"
  defp phase_color("market_event"), do: "#dc2626"
  defp phase_color("operations"), do: "#059669"
  defp phase_color(_), do: @text_secondary

  defp format_number(n) when is_number(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_number(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 0) |> trunc()}K"
  end

  defp format_number(n) when is_number(n), do: "#{trunc(n)}"
  defp format_number(n), do: to_string(n)

  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "..."
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
