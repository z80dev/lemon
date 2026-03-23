defmodule LemonSim.Examples.Auction.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (dark theme, warm auction house tones)
  # ---------------------------------------------------------------------------
  @bg "#0f0f1a"
  @panel_bg "#16213e"
  @panel_border "#252540"

  @gold "#f1c40f"
  # @gold_dark "#d4ac0d"
  @gold_dim "#8a7d3b"

  @gem_color "#e74c3c"
  @artifact_color "#9b59b6"
  @scroll_color "#3498db"

  @text_primary "#ecf0f1"
  @text_secondary "#95a5a6"
  @text_dim "#5a6068"

  @sold_green "#2ecc71"
  @unsold_red "#e74c3c"

  # Player colors (up to 6 players)
  @player_colors ["#e74c3c", "#3498db", "#2ecc71", "#f39c12", "#9b59b6", "#1abc9c"]

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 300
  @log_w 280

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
    current_item = get(world, "current_item", %{})
    high_bid = get(world, "high_bid", 0)
    high_bidder = get(world, "high_bidder", nil)
    active_bidders = get(world, "active_bidders", [])
    bid_history = get(world, "bid_history", [])
    auction_results = get(world, "auction_results", [])
    current_round = get(world, "current_round", 1)
    max_rounds = get(world, "max_rounds", 8)
    active_actor = get(world, "active_actor_id", nil)
    scores = get(world, "scores", %{})
    winner = get(world, "winner", nil)
    schedule = get(world, "auction_schedule", [])

    # Count total items and current item position
    total_items = length(schedule)
    items_done = length(auction_results)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      players: players,
      turn_order: turn_order,
      current_item: current_item,
      high_bid: high_bid,
      high_bidder: high_bidder,
      active_bidders: active_bidders,
      bid_history: bid_history,
      auction_results: auction_results,
      current_round: current_round,
      max_rounds: max_rounds,
      active_actor: active_actor,
      scores: scores,
      winner: winner,
      total_items: total_items,
      items_done: items_done
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_player_roster(ctx),
      render_center_content(ctx),
      render_auction_log(ctx),
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
      .item-name { font-family: sans-serif; font-weight: 700; }
      .bid-amount { font-family: sans-serif; font-weight: 700; }
      .score-text { font-family: sans-serif; }
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
        "Round #{ctx.current_round}/#{ctx.max_rounds}"
      end

    item_text =
      if type != "game_over" and ctx.total_items > 0 do
        "Item #{min(ctx.items_done + 1, ctx.total_items)}/#{ctx.total_items}"
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@gold}">AUCTION HOUSE</text>\n],
      # Round info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      # Item counter
      ~s[<text x="#{w - 20}" y="38" class="header-text" font-size="14" ] <>
        ~s[text-anchor="end" fill="#{@text_secondary}">#{esc(item_text)}</text>\n],
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
        color = Enum.at(@player_colors, idx, "#ecf0f1")
        render_player_card(pid, player, idx, color, ctx)
      end)

    [
      # Panel background
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@roster_w}" y1="#{@header_h}" x2="#{@roster_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="0" y="#{@header_h}" width="#{@roster_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@roster_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">PLAYERS</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 148
    gold = get(player, "gold", 0)
    items = get(player, "items", [])
    is_active = ctx.active_actor == pid
    is_high_bidder = ctx.high_bidder == pid
    is_bidding = pid in ctx.active_bidders
    is_winner = ctx.winner == pid

    display_name = format_player_name(pid)

    # Active/high bidder highlight
    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="142" ] <>
            ~s[fill="#{@gold}" opacity="0.12" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="142" ] <>
            ~s[fill="none" stroke="#{@gold}" stroke-width="2" rx="6"/>\n]

        is_active ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="142" ] <>
            ~s[fill="#{color}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@roster_w - 8}" height="142" ] <>
            ~s[fill="none" stroke="#{color}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    opacity = if is_bidding or ctx.type in ["init", "game_over"], do: "1", else: "0.4"

    # Gold bar
    gold_pct = gold / 100
    gold_bar_w = @roster_w - 40
    gold_fill_w = round(gold_bar_w * gold_pct)

    # Item badges
    item_badges = render_item_badges(items, y + 94, 16)

    # Score display for game_over
    score_line =
      if ctx.type == "game_over" do
        score = Map.get(ctx.scores, pid, %{})
        total = get(score, "total", 0)

        ~s[<text x="#{@roster_w - 16}" y="#{y + 14}" text-anchor="end" ] <>
          ~s[class="score-text" font-size="16" font-weight="700" fill="#{@gold}">#{total} pts</text>\n]
      else
        ""
      end

    # High bidder badge
    high_badge =
      if is_high_bidder and ctx.type != "game_over" do
        ~s[<text x="#{@roster_w - 16}" y="#{y + 14}" text-anchor="end" ] <>
          ~s[font-size="11" font-weight="700" fill="#{@gold}" filter="url(#glow)">HIGH BID</text>\n]
      else
        ""
      end

    [
      highlight,
      ~s[<g opacity="#{opacity}">\n],
      # Player name with color dot
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="player-name" font-size="14" fill="#{@text_primary}">#{esc(display_name)}</text>\n],
      high_badge,
      score_line,
      # Gold bar
      ~s[<text x="16" y="#{y + 36}" font-size="10" fill="#{@text_secondary}">Gold</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 36}" text-anchor="end" font-size="10" fill="#{@gold_dim}">#{gold}</text>\n],
      ~s[<rect x="16" y="#{y + 42}" width="#{gold_bar_w}" height="8" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="16" y="#{y + 42}" width="#{max(gold_fill_w, 0)}" height="8" fill="#{@gold}" rx="3" opacity="0.8"/>\n],
      # Items header
      ~s[<text x="16" y="#{y + 68}" font-size="10" fill="#{@text_secondary}">Items (#{length(items)})</text>\n],
      item_badges,
      # Score breakdown for game_over
      if ctx.type == "game_over" do
        score = Map.get(ctx.scores, pid, %{})
        iv = get(score, "item_value", 0)
        sb = get(score, "set_bonus", 0)
        gb = get(score, "gold_bonus", 0)
        ob = get(score, "objective_bonus", 0)

        ~s[<text x="16" y="#{y + 130}" font-size="9" fill="#{@text_dim}">] <>
          ~s[items:#{iv} sets:#{sb} gold:#{gb} obj:#{ob}</text>\n]
      else
        ""
      end,
      ~s[</g>\n]
    ]
  end

  defp render_item_badges(items, y, x_start) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      category = get(item, "category", "unknown")
      name = get(item, "name", "?")
      color = category_color(category)
      short = String.first(name) || "?"
      # Wrap to next row after 8 items
      row = div(idx, 8)
      col = rem(idx, 8)
      bx = x_start + col * 28
      by = y + row * 22

      [
        ~s[<rect x="#{bx}" y="#{by}" width="22" height="18" fill="#{color}" opacity="0.25" rx="3"/>\n],
        ~s[<text x="#{bx + 11}" y="#{by + 13}" text-anchor="middle" font-size="10" font-weight="700" fill="#{color}">#{esc(short)}</text>\n],
        ~s[<title>#{esc(name)} (#{category})</title>\n]
      ]
    end)
  end

  # ---------------------------------------------------------------------------
  # Center content
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "game_over" -> render_game_over_card(ctx)
      _ -> render_bidding_content(ctx)
    end
  end

  defp render_init_card(%{w: w, h: h, turn_order: turn_order, total_items: total_items}) do
    cx = @roster_w + div(w - @roster_w - @log_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = length(turn_order)

    [
      # Large centered card
      ~s[<rect x="#{cx - 240}" y="#{cy - 140}" width="480" height="280" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      # Title
      ~s[<text x="#{cx}" y="#{cy - 80}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@gold}">AUCTION HOUSE</text>\n],
      # Subtitle
      ~s[<text x="#{cx}" y="#{cy - 50}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Economics &#x26; Strategy Game</text>\n],
      # Info
      ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Players &#xB7; #{total_items} Items &#xB7; 8 Rounds</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 30}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Starting Gold: 100 each</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 60}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Collect items, complete objectives, win!</text>\n],
      # Decorative line
      ~s[<line x1="#{cx - 120}" y1="#{cy + 90}" x2="#{cx + 120}" y2="#{cy + 90}" ] <>
        ~s[stroke="#{@gold_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 112}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Gems &#xB7; Artifacts &#xB7; Scrolls</text>\n]
    ]
  end

  defp render_game_over_card(%{
         w: w,
         h: h,
         turn_order: turn_order,
         scores: scores,
         winner: winner,
         players: players
       }) do
    cx = @roster_w + div(w - @roster_w - @log_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    # Sort players by score descending
    sorted =
      turn_order
      |> Enum.map(fn pid ->
        score = Map.get(scores, pid, %{})
        {pid, get(score, "total", 0)}
      end)
      |> Enum.sort_by(fn {_, total} -> -total end)

    card_h = 80 + length(sorted) * 50

    [
      # Card background
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      # Title
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@gold}">FINAL SCORES</text>\n],
      # Player scores
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, total}, rank} ->
        sy = cy - div(card_h, 2) + 70 + rank * 50
        is_winner = pid == winner
        color = if is_winner, do: @gold, else: @text_primary
        rank_label = "##{rank + 1}"

        player = Map.get(players, pid, %{})
        items = get(player, "items", [])
        score = Map.get(scores, pid, %{})
        iv = get(score, "item_value", 0)
        sb = get(score, "set_bonus", 0)
        gb = get(score, "gold_bonus", 0)
        ob = get(score, "objective_bonus", 0)

        winner_badge =
          if is_winner do
            ~s[<text x="#{cx + 240}" y="#{sy + 6}" text-anchor="end" font-size="12" ] <>
              ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
          else
            ""
          end

        [
          # Highlight for winner
          if is_winner do
            ~s[<rect x="#{cx - 260}" y="#{sy - 18}" width="520" height="44" ] <>
              ~s[fill="#{@gold}" opacity="0.08" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">#{rank_label}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 6}" class="player-name" font-size="16" fill="#{color}">#{esc(format_player_name(pid))}</text>\n],
          ~s[<text x="#{cx + 100}" y="#{sy + 6}" text-anchor="end" class="bid-amount" font-size="20" fill="#{color}">#{total}</text>\n],
          ~s[<text x="#{cx + 110}" y="#{sy + 6}" font-size="12" fill="#{@text_dim}">pts</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 22}" font-size="9" fill="#{@text_dim}">] <>
            ~s[items:#{iv} sets:#{sb} gold:#{gb} obj:#{ob} &#xB7; #{length(items)} items won</text>\n],
          winner_badge
        ]
      end)
    ]
  end

  defp render_bidding_content(ctx) do
    events = ctx.events

    cond do
      has_event?(events, "item_won") -> render_sold_card(ctx)
      has_event?(events, "item_unsold") -> render_unsold_card(ctx)
      true -> render_active_auction(ctx)
    end
  end

  defp render_sold_card(ctx) do
    %{w: w, h: h, events: events} = ctx
    cx = @roster_w + div(w - @roster_w - @log_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    # Get the won item info from events or latest auction result
    won_event = find_event(events, "item_won")
    payload = get(won_event, "payload", won_event || %{})

    item_name = get(payload, "item", "Unknown")
    price = get(payload, "price", 0)
    winner_id = get(payload, "player_id", "?")
    category = get(payload, "category", "unknown")

    [
      # Large "SOLD!" card
      ~s[<rect x="#{cx - 220}" y="#{cy - 120}" width="440" height="240" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@sold_green}" stroke-width="3" opacity="0.95"/>\n],
      # SOLD banner
      ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" class="title" ] <>
        ~s[font-size="48" fill="#{@sold_green}" filter="url(#glow)">SOLD!</text>\n],
      # Item name with category color
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" class="item-name" ] <>
        ~s[font-size="24" fill="#{category_color(category)}">#{esc(item_name)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 14}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">#{String.capitalize(category)}</text>\n],
      # Divider
      ~s[<line x1="#{cx - 100}" y1="#{cy + 30}" x2="#{cx + 100}" y2="#{cy + 30}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Winner and price
      ~s[<text x="#{cx}" y="#{cy + 60}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">Won by #{esc(format_player_name(winner_id))}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 92}" text-anchor="middle" class="bid-amount" ] <>
        ~s[font-size="28" fill="#{@gold}">#{price} gold</text>\n]
    ]
  end

  defp render_unsold_card(%{w: w, h: h, current_item: item}) do
    cx = @roster_w + div(w - @roster_w - @log_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    item_name = get(item, "name", "Unknown")
    category = get(item, "category", "unknown")

    [
      ~s[<rect x="#{cx - 200}" y="#{cy - 100}" width="400" height="200" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@unsold_red}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 30}" text-anchor="middle" class="title" ] <>
        ~s[font-size="36" fill="#{@unsold_red}">NO SALE</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 10}" text-anchor="middle" class="item-name" ] <>
        ~s[font-size="20" fill="#{category_color(category)}">#{esc(item_name)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 40}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">No bids placed</text>\n]
    ]
  end

  defp render_active_auction(ctx) do
    %{
      w: w,
      h: h,
      current_item: item,
      high_bid: high_bid,
      high_bidder: high_bidder,
      active_bidders: active_bidders,
      bid_history: bid_history,
      turn_order: turn_order
    } = ctx

    cx = @roster_w + div(w - @roster_w - @log_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    item_name = get(item, "name", "Unknown")
    category = get(item, "category", "unknown")
    base_value = get(item, "base_value", 0)
    cat_color = category_color(category)

    [
      # Item card
      ~s[<rect x="#{cx - 200}" y="#{cy - 180}" width="400" height="160" ] <>
        ~s[fill="#{@panel_bg}" rx="10" stroke="#{cat_color}" stroke-width="2" opacity="0.9"/>\n],
      # Category badge
      ~s[<circle cx="#{cx}" cy="#{cy - 138}" r="16" fill="#{cat_color}" opacity="0.2"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 132}" text-anchor="middle" font-size="14" font-weight="700" ] <>
        ~s[fill="#{cat_color}">#{category_icon(category)}</text>\n],
      # Item name
      ~s[<text x="#{cx}" y="#{cy - 95}" text-anchor="middle" class="item-name" ] <>
        ~s[font-size="28" fill="#{@text_primary}">#{esc(item_name)}</text>\n],
      # Category label
      ~s[<text x="#{cx}" y="#{cy - 72}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{cat_color}">#{String.capitalize(category)}</text>\n],
      # Base value
      ~s[<text x="#{cx}" y="#{cy - 45}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_secondary}">Base Value: #{base_value}</text>\n],

      # Current bid display
      if high_bid > 0 do
        [
          ~s[<text x="#{cx}" y="#{cy + 10}" text-anchor="middle" font-size="13" ] <>
            ~s[fill="#{@text_secondary}">Current Bid</text>\n],
          ~s[<text x="#{cx}" y="#{cy + 52}" text-anchor="middle" class="bid-amount" ] <>
            ~s[font-size="48" fill="#{@gold}" filter="url(#glow)">#{high_bid}</text>\n],
          ~s[<text x="#{cx}" y="#{cy + 72}" text-anchor="middle" font-size="14" ] <>
            ~s[fill="#{@text_secondary}">by #{esc(format_player_name(high_bidder))}</text>\n]
        ]
      else
        [
          ~s[<text x="#{cx}" y="#{cy + 30}" text-anchor="middle" font-size="16" ] <>
            ~s[fill="#{@text_dim}">Opening bid...</text>\n]
        ]
      end,

      # Active bidders indicator
      render_bidder_dots(turn_order, active_bidders, high_bidder, cx, cy + 110),

      # Recent bid history (last 5)
      render_bid_history(bid_history, cx, cy + 145)
    ]
  end

  defp render_bidder_dots(turn_order, active_bidders, high_bidder, cx, y) do
    count = length(turn_order)
    total_w = count * 40 - 10
    start_x = cx - div(total_w, 2)

    [
      ~s[<text x="#{cx}" y="#{y - 10}" text-anchor="middle" font-size="10" ] <>
        ~s[fill="#{@text_dim}">Active Bidders</text>\n],
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {pid, idx} ->
        dx = start_x + idx * 40
        is_active = pid in active_bidders
        is_high = pid == high_bidder
        color = Enum.at(@player_colors, idx, "#ecf0f1")

        dot_color = if is_active, do: color, else: @text_dim
        opacity = if is_active, do: "1", else: "0.3"
        r = if is_high, do: "10", else: "8"

        [
          if is_high do
            ~s[<circle cx="#{dx + 15}" cy="#{y + 8}" r="13" fill="none" ] <>
              ~s[stroke="#{@gold}" stroke-width="2" opacity="0.7"/>\n]
          else
            ""
          end,
          ~s[<circle cx="#{dx + 15}" cy="#{y + 8}" r="#{r}" fill="#{dot_color}" opacity="#{opacity}"/>\n],
          ~s[<text x="#{dx + 15}" y="#{y + 26}" text-anchor="middle" font-size="8" ] <>
            ~s[fill="#{@text_dim}" opacity="#{opacity}">P#{idx + 1}</text>\n]
        ]
      end)
    ]
  end

  defp render_bid_history(bid_history, cx, y) do
    recent = Enum.take(bid_history, -5)

    if recent == [] do
      ""
    else
      [
        ~s[<text x="#{cx}" y="#{y}" text-anchor="middle" font-size="10" ] <>
          ~s[fill="#{@text_dim}">Bid History</text>\n],
        recent
        |> Enum.with_index()
        |> Enum.map(fn {bid_entry, idx} ->
          {bidder, amount} = parse_bid_entry(bid_entry)
          by = y + 16 + idx * 16
          is_latest = idx == length(recent) - 1
          fill = if is_latest, do: @gold, else: @text_secondary

          ~s[<text x="#{cx}" y="#{by}" text-anchor="middle" font-size="11" fill="#{fill}">] <>
            ~s[#{esc(format_player_name(bidder))}: #{amount}g</text>\n]
        end)
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Auction log (right panel)
  # ---------------------------------------------------------------------------

  defp render_auction_log(%{w: w, h: h, auction_results: results}) do
    panel_x = w - @log_w
    panel_h = h - @header_h - @footer_h

    result_entries =
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, idx} ->
        ry = @header_h + 40 + idx * 40
        item_name = get(result, "item", "?")
        category = get(result, "category", "unknown")
        winner_id = get(result, "winner", nil)
        price = get(result, "price", 0)

        cat_color = category_color(category)

        if winner_id do
          [
            ~s[<circle cx="#{panel_x + 16}" cy="#{ry + 4}" r="4" fill="#{cat_color}" opacity="0.6"/>\n],
            ~s[<text x="#{panel_x + 26}" y="#{ry + 8}" font-size="11" fill="#{@text_primary}">#{esc(item_name)}</text>\n],
            ~s[<text x="#{panel_x + @log_w - 12}" y="#{ry + 8}" text-anchor="end" font-size="10" fill="#{@gold_dim}">#{price}g</text>\n],
            ~s[<text x="#{panel_x + 26}" y="#{ry + 22}" font-size="9" fill="#{@text_dim}">] <>
              ~s[&#x2192; #{esc(format_player_name(winner_id))}</text>\n]
          ]
        else
          [
            ~s[<circle cx="#{panel_x + 16}" cy="#{ry + 4}" r="4" fill="#{@text_dim}" opacity="0.4"/>\n],
            ~s[<text x="#{panel_x + 26}" y="#{ry + 8}" font-size="11" fill="#{@text_dim}" ] <>
              ~s[text-decoration="line-through">#{esc(item_name)}</text>\n],
            ~s[<text x="#{panel_x + @log_w - 12}" y="#{ry + 8}" text-anchor="end" font-size="9" ] <>
              ~s[fill="#{@unsold_red}" opacity="0.6">unsold</text>\n]
          ]
        end
      end)

    [
      # Panel background
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@log_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@log_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@log_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">AUCTION LOG</text>\n],
      result_entries,
      # Empty state
      if results == [] do
        ~s[<text x="#{panel_x + div(@log_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No items sold yet</text>\n]
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
        "Game begins with #{length(ctx.turn_order)} players and #{ctx.total_items} items"

      ctx.type == "game_over" ->
        "#{format_player_name(ctx.winner)} wins the auction house!"

      has_event?(events, "item_won") ->
        ev = find_event(events, "item_won")
        p = get(ev, "payload", ev || %{})

        "#{format_player_name(get(p, "player_id", "?"))} wins #{get(p, "item", "?")} for #{get(p, "price", 0)} gold!"

      has_event?(events, "item_unsold") ->
        ev = find_event(events, "item_unsold")
        p = get(ev, "payload", ev || %{})
        "#{get(p, "item", "Item")} goes unsold - no bids placed"

      has_event?(events, "auction_started") ->
        ev = find_event(events, "auction_started")
        p = get(ev, "payload", ev || %{})

        "Now auctioning: #{get(p, "item", "?")} (#{get(p, "category", "?")}, base value #{get(p, "base_value", 0)})"

      has_event?(events, "bid_accepted") ->
        ev = find_event(events, "bid_accepted")
        p = get(ev, "payload", ev || %{})

        "#{format_player_name(get(p, "player_id", "?"))} bids #{get(p, "amount", 0)} gold on #{get(p, "item", "?")}"

      has_event?(events, "player_passed") ->
        ev = find_event(events, "player_passed")
        p = get(ev, "payload", ev || %{})
        "#{format_player_name(get(p, "player_id", "?"))} passes"

      has_event?(events, "round_started") ->
        ev = find_event(events, "round_started")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins"

      true ->
        item_name = get(ctx.current_item, "name", "")
        if item_name != "", do: "Bidding on #{item_name}...", else: ""
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp category_color("gem"), do: @gem_color
  defp category_color("artifact"), do: @artifact_color
  defp category_color("scroll"), do: @scroll_color
  defp category_color(_), do: @text_secondary

  defp category_icon("gem"), do: "GEM"
  defp category_icon("artifact"), do: "ART"
  defp category_icon("scroll"), do: "SCR"
  defp category_icon(_), do: "?"

  # Bid entries may be tuples {player, amount} or lists [player, amount] (from JSON)
  defp parse_bid_entry({bidder, amount}), do: {bidder, amount}
  defp parse_bid_entry([bidder, amount]), do: {bidder, amount}
  defp parse_bid_entry(%{"player_id" => b, "amount" => a}), do: {b, a}
  defp parse_bid_entry(_), do: {"?", 0}

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
