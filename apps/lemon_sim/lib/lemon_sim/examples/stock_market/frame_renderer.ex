defmodule LemonSim.Examples.StockMarket.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (dark theme, financial trading floor)
  # ---------------------------------------------------------------------------
  @bg "#0a0e1a"
  @panel_bg "#111827"
  @panel_border "#1f2937"

  @green "#10b981"
  @red "#ef4444"
  @gold "#f59e0b"
  @blue "#3b82f6"

  @text_primary "#f3f4f6"
  @text_secondary "#9ca3af"
  @text_dim "#4b5563"

  # Player colors (up to 6 players)
  @player_colors ["#ef4444", "#3b82f6", "#10b981", "#f59e0b", "#8b5cf6", "#06b6d4"]

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 300
  @ticker_w 280

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
    stocks = get(world, "stocks", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 10)
    phase = get(world, "phase", "discussion")
    active_actor = get(world, "active_actor_id", nil)
    turn_order = get(world, "turn_order", Map.keys(players) |> Enum.sort())
    market_calls = get(world, "market_calls", [])
    winner = get(world, "winner", nil)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      stocks: stocks,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      active_actor: active_actor,
      turn_order: turn_order,
      market_calls: market_calls,
      winner: winner
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_roster(ctx),
      render_center_content(ctx),
      render_stock_ticker(ctx),
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
      .ticker-text { font-family: sans-serif; font-weight: 700; }
      .price-text { font-family: sans-serif; font-weight: 700; }
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
        "FINAL RESULTS"
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
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@gold}">STOCK EXCHANGE</text>\n],
      # Round info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      # Phase indicator
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<text x="#{div(w, 2)}" y="54" class="header-text" font-size="10" ] <>
          ~s[text-anchor="middle" fill="#{phase_color}" letter-spacing="2">#{esc(phase_text)}</text>\n]
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
        color = Enum.at(@player_colors, idx, @text_primary)
        render_player_card(pid, player, idx, color, ctx)
      end)

    [
      # Panel background
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold}">TRADERS</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 158
    cash = get(player, "cash", 0)
    reputation = get(player, "reputation", 50)
    portfolio = get(player, "portfolio", %{})
    short_book = get(player, "short_book", %{})
    stocks = ctx.stocks
    is_active = ctx.active_actor == pid
    is_winner = ctx.winner == pid

    display_name = format_player_name(pid, player)

    # Calculate portfolio value roughly from holdings
    portfolio_value =
      Enum.reduce(portfolio, 0.0, fn {ticker, shares}, acc ->
        stock = Map.get(stocks, ticker, %{})
        price = get(stock, "price", 0)
        acc + shares * price
      end)

    _total_value_display = trunc(Float.round((cash + portfolio_value) * 1.0, 0))

    # Active/winner highlight
    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="152" ] <>
            ~s[fill="#{@gold}" opacity="0.12" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="152" ] <>
            ~s[fill="none" stroke="#{@gold}" stroke-width="2" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="152" ] <>
            ~s[fill="#{color}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="152" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    # Reputation bar
    rep_pct = reputation / 100
    rep_bar_w = @roster_w - 40
    rep_fill_w = round(rep_bar_w * rep_pct)
    rep_color = if reputation >= 50, do: @green, else: @red

    # Holdings list
    holding_entries =
      portfolio
      |> Enum.filter(fn {_ticker, shares} -> shares > 0 end)
      |> Enum.take(4)
      |> Enum.with_index()
      |> Enum.map(fn {{ticker, shares}, hidx} ->
        hx = 16 + rem(hidx, 2) * 130
        hy = y + 104 + div(hidx, 2) * 16

        ~s[<text x="#{hx}" y="#{hy}" font-size="9" fill="#{@text_secondary}">#{esc(ticker)}: #{shares}</text>\n]
      end)

    short_entries =
      short_book
      |> Enum.filter(fn {_ticker, shares} -> shares > 0 end)
      |> Enum.take(2)
      |> Enum.with_index()
      |> Enum.map(fn {{ticker, shares}, sidx} ->
        sx = 16 + sidx * 130
        sy = y + 136

        ~s[<text x="#{sx}" y="#{sy}" font-size="9" fill="#{@red}" opacity="0.8">SHORT #{esc(ticker)}: #{shares}</text>\n]
      end)

    [
      highlight,
      # Player name with color dot
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="player-name" font-size="14" fill="#{@text_primary}">#{esc(display_name)}</text>\n],
      # Total value
      ~s[<text x="#{@roster_w - 16}" y="#{y + 14}" text-anchor="end" ] <>
        ~s[class="price-text" font-size="14" fill="#{@gold}">${total_value_display}</text>\n],
      # Cash
      ~s[<text x="16" y="#{y + 34}" font-size="10" fill="#{@text_secondary}">Cash</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 34}" text-anchor="end" font-size="10" fill="#{@text_dim}">${Float.round(cash * 1.0, 0) |> trunc()}</text>\n],
      # Reputation bar
      ~s[<text x="16" y="#{y + 54}" font-size="10" fill="#{@text_secondary}">Rep #{reputation}</text>\n],
      ~s[<rect x="16" y="#{y + 60}" width="#{rep_bar_w}" height="6" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="16" y="#{y + 60}" width="#{max(rep_fill_w, 0)}" height="6" fill="#{rep_color}" rx="3" opacity="0.8"/>\n],
      # Holdings header
      ~s[<text x="16" y="#{y + 88}" font-size="10" fill="#{@text_secondary}">Holdings</text>\n],
      holding_entries,
      short_entries,
      # Winner badge
      if is_winner do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 34}" text-anchor="end" ] <>
          ~s[font-size="11" font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
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

  defp render_init_card(%{w: w, h: h, turn_order: turn_order, stocks: stocks}) do
    cx = @roster_w + div(w - @roster_w - @ticker_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)
    player_count = length(turn_order)
    stock_count = map_size(stocks)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      # Title
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@gold}">STOCK EXCHANGE</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Trading Arena &#x26; Market Simulation</text>\n],
      # Info
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Traders &#xB7; #{stock_count} Stocks &#xB7; 10 Rounds</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 20}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Starting Cash: $10,000 each</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 50}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Trade, whisper, persuade, and profit!</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 102}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Buy &#xB7; Sell &#xB7; Short &#xB7; Cover &#xB7; Hold</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 120}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Highest portfolio value wins</text>\n]
    ]
  end

  defp render_game_over_card(%{
         w: w,
         h: h,
         turn_order: turn_order,
         players: players,
         stocks: %{} = stocks,
         winner: winner
       }) do
    cx = @roster_w + div(w - @roster_w - @ticker_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    # Sort players by portfolio value descending
    sorted =
      turn_order
      |> Enum.map(fn pid ->
        player = Map.get(players, pid, %{})
        cash = get(player, "cash", 0)

        portfolio_value =
          player
          |> get("portfolio", %{})
          |> Enum.reduce(0.0, fn {ticker, shares}, acc ->
            stock = Map.get(stocks, ticker, %{})
            price = get(stock, "price", 0)
            acc + shares * price
          end)

        total = cash + portfolio_value
        {pid, Float.round(total * 1.0, 2)}
      end)
      |> Enum.sort_by(fn {_, total} -> -total end)

    card_h = 80 + length(sorted) * 50

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@gold}">FINAL RANKINGS</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, total}, rank} ->
        sy = cy - div(card_h, 2) + 70 + rank * 50
        is_win = pid == winner
        color = if is_win, do: @gold, else: @text_primary
        rank_label = "##{rank + 1}"
        player = Map.get(players, pid, %{})
        display_name = format_player_name(pid, player)

        [
          if is_win do
            ~s[<rect x="#{cx - 260}" y="#{sy - 18}" width="520" height="44" ] <>
              ~s[fill="#{@gold}" opacity="0.08" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">#{rank_label}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 6}" class="player-name" font-size="16" fill="#{color}">#{esc(display_name)}</text>\n],
          ~s[<text x="#{cx + 120}" y="#{sy + 6}" text-anchor="end" class="price-text" font-size="20" fill="#{color}">$#{total}</text>\n],
          if is_win do
            ~s[<text x="#{cx + 240}" y="#{sy + 6}" text-anchor="end" font-size="12" ] <>
              ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
          else
            ""
          end
        ]
      end)
    ]
  end

  defp render_phase_content(%{phase: phase} = ctx) do
    case phase do
      "discussion" -> render_discussion_content(ctx)
      "trading" -> render_trading_content(ctx)
      _ -> render_generic_content(ctx)
    end
  end

  defp render_discussion_content(
         %{w: w, h: h, market_calls: market_calls, players: players, active_actor: active_actor} =
           _ctx
       ) do
    cx = @roster_w + div(w - @roster_w - @ticker_w, 2)
    panel_y = @header_h + 10
    panel_h = h - @header_h - @footer_h - 20

    active_name =
      if active_actor do
        player = Map.get(players, active_actor, %{})
        format_player_name(active_actor, player)
      else
        "—"
      end

    recent_calls = Enum.take(market_calls, -6)
    call_count = length(recent_calls)

    [
      ~s[<rect x="#{cx - 260}" y="#{panel_y}" width="520" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1" opacity="0.9"/>\n],
      # Section header
      ~s[<text x="#{cx}" y="#{panel_y + 26}" text-anchor="middle" class="title" ] <>
        ~s[font-size="16" fill="#{@blue}" letter-spacing="2">MARKET SIGNALS</text>\n],
      # Current speaker
      ~s[<text x="#{cx}" y="#{panel_y + 52}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Speaking:</text>\n],
      ~s[<text x="#{cx}" y="#{panel_y + 72}" text-anchor="middle" class="player-name" ] <>
        ~s[font-size="18" fill="#{@text_primary}">#{esc(active_name)}</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{panel_y + 84}" x2="#{cx + 200}" y2="#{panel_y + 84}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Market calls header
      if call_count > 0 do
        ~s[<text x="#{cx - 200}" y="#{panel_y + 100}" font-size="11" ] <>
          ~s[fill="#{@text_dim}" letter-spacing="1">RECENT CALLS</text>\n]
      else
        ~s[<text x="#{cx}" y="#{panel_y + 110}" text-anchor="middle" font-size="12" ] <>
          ~s[fill="#{@text_dim}">No market calls yet</text>\n]
      end,
      # Recent market calls
      recent_calls
      |> Enum.with_index()
      |> Enum.map(fn {call, idx} ->
        cy2 = panel_y + 116 + idx * 50
        caller = get(call, "player", get(call, :player, "?"))
        caller_player = Map.get(players, caller, %{})
        caller_name = format_player_name(caller, caller_player)
        stock = get(call, "stock", get(call, :stock, "?"))
        stance = get(call, "stance", get(call, :stance, "?"))
        confidence = get(call, "confidence", get(call, :confidence, 0))
        thesis = get(call, "thesis", get(call, :thesis, ""))
        stance_color = if stance == "bullish", do: @green, else: @red
        stance_symbol = if stance == "bullish", do: "▲", else: "▼"

        [
          ~s[<rect x="#{cx - 200}" y="#{cy2 - 4}" width="400" height="44" ] <>
            ~s[fill="#{@bg}" rx="4" opacity="0.6"/>\n],
          ~s[<text x="#{cx - 190}" y="#{cy2 + 12}" font-size="12" fill="#{@text_secondary}">#{esc(caller_name)}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{cy2 + 30}" font-size="11" fill="#{@text_dim}">#{esc(String.slice(thesis || "", 0, 60))}</text>\n],
          ~s[<text x="#{cx + 180}" y="#{cy2 + 12}" text-anchor="end" class="ticker-text" ] <>
            ~s[font-size="13" fill="#{stance_color}">#{esc(stock)} #{stance_symbol} #{confidence}/5</text>\n]
        ]
      end)
    ]
  end

  defp render_trading_content(
         %{w: w, h: h, events: events, players: players, active_actor: active_actor} = _ctx
       ) do
    cx = @roster_w + div(w - @roster_w - @ticker_w, 2)
    panel_y = @header_h + 10
    panel_h = h - @header_h - @footer_h - 20

    active_name =
      if active_actor do
        player = Map.get(players, active_actor, %{})
        format_player_name(active_actor, player)
      else
        "—"
      end

    trade_event = find_event(events, "place_trade")

    [
      ~s[<rect x="#{cx - 260}" y="#{panel_y}" width="520" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{panel_y + 26}" text-anchor="middle" class="title" ] <>
        ~s[font-size="16" fill="#{@gold}" letter-spacing="2">TRADING FLOOR</text>\n],
      ~s[<text x="#{cx}" y="#{panel_y + 52}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Trading:</text>\n],
      ~s[<text x="#{cx}" y="#{panel_y + 72}" text-anchor="middle" class="player-name" ] <>
        ~s[font-size="18" fill="#{@text_primary}">#{esc(active_name)}</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{panel_y + 84}" x2="#{cx + 200}" y2="#{panel_y + 84}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      if trade_event do
        payload = get(trade_event, "payload", trade_event)
        action = get(payload, "action", "?")
        stock = get(payload, "stock", "?")
        quantity = get(payload, "quantity", 0)
        player_id = get(payload, "player_id", "?")
        trader_player = Map.get(players, player_id, %{})
        trader_name = format_player_name(player_id, trader_player)

        action_color =
          case action do
            "buy" -> @green
            "sell" -> @red
            "short" -> @red
            "cover" -> @green
            _ -> @text_secondary
          end

        [
          ~s[<text x="#{cx}" y="#{panel_y + 140}" text-anchor="middle" font-size="13" ] <>
            ~s[fill="#{@text_secondary}">Latest Trade</text>\n],
          ~s[<text x="#{cx}" y="#{panel_y + 170}" text-anchor="middle" class="player-name" ] <>
            ~s[font-size="16" fill="#{@text_primary}">#{esc(trader_name)}</text>\n],
          ~s[<text x="#{cx}" y="#{panel_y + 210}" text-anchor="middle" class="price-text" ] <>
            ~s[font-size="32" fill="#{action_color}" filter="url(#glow)">#{String.upcase(action)}</text>\n],
          ~s[<text x="#{cx}" y="#{panel_y + 245}" text-anchor="middle" font-size="20" ] <>
            ~s[fill="#{@text_primary}">#{quantity} #{esc(stock)}</text>\n]
        ]
      else
        ~s[<text x="#{cx}" y="#{panel_y + 140}" text-anchor="middle" font-size="14" ] <>
          ~s[fill="#{@text_dim}">Awaiting trades...</text>\n]
      end
    ]
  end

  defp render_generic_content(%{w: w, h: h, phase: phase}) do
    cx = @roster_w + div(w - @roster_w - @ticker_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    [
      ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" class="title" ] <>
        ~s[font-size="24" fill="#{@text_secondary}">#{esc(String.upcase(phase))}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Stock ticker (right panel)
  # ---------------------------------------------------------------------------

  defp render_stock_ticker(%{w: w, h: h, stocks: stocks}) do
    panel_x = w - @ticker_w
    panel_h = h - @header_h - @footer_h

    stock_entries =
      stocks
      |> Enum.sort_by(fn {ticker, _} -> ticker end)
      |> Enum.with_index()
      |> Enum.map(fn {{ticker, stock_data}, idx} ->
        sy = @header_h + 40 + idx * 72
        render_stock_row(ticker, stock_data, sy, panel_x)
      end)

    [
      # Panel background
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@ticker_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@ticker_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@ticker_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold}">MARKET PRICES</text>\n],
      stock_entries
    ]
  end

  defp render_stock_row(ticker, stock_data, y, panel_x) do
    price = get(stock_data, "price", get(stock_data, :price, 0))
    history = get(stock_data, "history", get(stock_data, :history, []))
    prev_price = if length(history) >= 2, do: Enum.at(history, -2) || price, else: price
    change = Float.round((price - prev_price) * 1.0, 2)
    change_pct = if prev_price > 0, do: Float.round(change / prev_price * 100.0, 1), else: 0.0

    price_color =
      cond do
        change > 0 -> @green
        change < 0 -> @red
        true -> @text_secondary
      end

    arrow =
      cond do
        change > 0 -> "▲"
        change < 0 -> "▼"
        true -> "—"
      end

    change_str = if change >= 0, do: "+#{change}", else: "#{change}"
    pct_str = if change_pct >= 0, do: "+#{change_pct}%", else: "#{change_pct}%"

    # Mini price bar using history
    bar_entries =
      if length(history) > 1 do
        recent = Enum.take(history, -20)
        max_p = Enum.max(recent, fn -> price end)
        min_p = Enum.min(recent, fn -> price end)
        range = max(max_p - min_p, 0.01)
        bar_w = @ticker_w - 32
        bar_h = 12

        recent
        |> Enum.with_index()
        |> Enum.map(fn {p, i} ->
          seg_w = bar_w / max(length(recent) - 1, 1)
          bx = panel_x + 16 + round(i * seg_w)
          normalized = (p - min_p) / range
          by = y + 58 - round(normalized * bar_h)
          seg_color = if p >= prev_price, do: @green, else: @red

          ~s[<circle cx="#{bx}" cy="#{by}" r="1.5" fill="#{seg_color}" opacity="0.6"/>\n]
        end)
      else
        ""
      end

    [
      ~s[<rect x="#{panel_x + 4}" y="#{y - 4}" width="#{@ticker_w - 8}" height="68" ] <>
        ~s[fill="#{@panel_bg}" rx="4" opacity="0.4"/>\n],
      ~s[<text x="#{panel_x + 16}" y="#{y + 14}" class="ticker-text" font-size="14" fill="#{@text_primary}">#{esc(ticker)}</text>\n],
      ~s[<text x="#{panel_x + @ticker_w - 16}" y="#{y + 14}" text-anchor="end" class="price-text" ] <>
        ~s[font-size="16" fill="#{price_color}">$#{price}</text>\n],
      ~s[<text x="#{panel_x + 16}" y="#{y + 32}" font-size="10" fill="#{price_color}">#{arrow} #{change_str}</text>\n],
      ~s[<text x="#{panel_x + @ticker_w - 16}" y="#{y + 32}" text-anchor="end" font-size="10" fill="#{price_color}">#{pct_str}</text>\n],
      bar_entries
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
        "Stock Exchange opens with #{length(ctx.turn_order)} traders and #{map_size(ctx.stocks)} stocks"

      ctx.type == "game_over" ->
        player = Map.get(ctx.players, ctx.winner, %{})
        winner_name = format_player_name(ctx.winner, player)
        "#{winner_name} wins the Stock Exchange!"

      has_event?(events, "game_over") ->
        "Game over! Final standings recorded."

      has_event?(events, "round_resolved") ->
        ev = find_event(events, "round_resolved")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} resolved — prices updated"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        get(p, "message", "Phase changed to #{get(p, "phase", "?")}")

      has_event?(events, "place_trade") ->
        ev = find_event(events, "place_trade")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        name = format_player_name(player_id, player)
        action = get(p, "action", "?")
        stock = get(p, "stock", "?")
        qty = get(p, "quantity", 0)
        "#{name} #{action}s #{qty} shares of #{stock}"

      has_event?(events, "broadcast_market_call") ->
        ev = find_event(events, "broadcast_market_call")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        name = format_player_name(player_id, player)
        stock = get(p, "stock", "?")
        stance = get(p, "stance", "?")
        "#{name} calls #{stock} #{stance}"

      has_event?(events, "make_statement") ->
        ev = find_event(events, "make_statement")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        name = format_player_name(player_id, player)
        stmt = get(p, "statement", "")
        "#{name}: #{String.slice(stmt, 0, 80)}"

      has_event?(events, "market_news_generated") ->
        ev = find_event(events, "market_news_generated")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} news: #{String.slice(get(p, "news_text", ""), 0, 80)}"

      true ->
        "Round #{ctx.round}/#{ctx.max_rounds} — #{String.capitalize(ctx.phase)} phase"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("discussion"), do: @blue
  defp phase_color("trading"), do: @gold
  defp phase_color("game_over"), do: @gold
  defp phase_color(_), do: @text_secondary

  defp format_player_name(nil, _player), do: "?"

  defp format_player_name(_pid, player) when is_map(player) do
    case get(player, "name", get(player, :name, nil)) do
      nil -> "?"
      name -> name
    end
  end

  defp format_player_name(pid, _), do: pid

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
