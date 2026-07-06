defmodule LemonSim.Examples.Poker.FrameRenderer do
  @moduledoc false

  alias LemonSim.Examples.Rendering.FrameChrome
  alias LemonSim.Examples.Poker.Engine.Table

  # ---------------------------------------------------------------------------
  # Color palette (dark theme, felt table)
  # ---------------------------------------------------------------------------
  @bg "#0a100c"
  @panel_bg "#111a14"
  @panel_border "#1f2e24"

  @felt "#0d3b26"
  @felt_edge "#136640"
  @rail "#2b1c10"
  @rail_edge "#4a3018"

  @gold "#f5b942"
  @green "#22c55e"
  @red "#ef4444"

  @text_primary "#f3f4f6"
  @text_secondary "#9ca3af"
  @text_dim "#5b6b63"

  # Seat colors (up to 9 players)
  @player_colors [
    "#ef4444",
    "#3b82f6",
    "#10b981",
    "#f59e0b",
    "#8b5cf6",
    "#06b6d4",
    "#ec4899",
    "#84cc16",
    "#14b8a6"
  ]

  # Layout constants
  @header_h 60
  @footer_h 70
  @standings_w 260
  @info_w 300

  @seat_w 200
  @seat_h 118
  @hole_card_w 28
  @hole_card_h 38

  @board_card_w 50
  @board_card_h 70

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

    table = get(world, "table", %{})
    hand = get(table, "hand", nil)
    status = get(world, "status", "in_progress")

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      world: world,
      table: table,
      hand: hand,
      status: status,
      winner: get(world, "winner", nil),
      winner_ids: get(world, "winner_ids", []),
      game_over_reason: get(world, "game_over_reason", nil),
      completed_hands: get(world, "completed_hands", 0),
      max_hands: get(world, "max_hands", 1),
      players: get(world, "players", %{}),
      current_seat: get(world, "current_seat", nil),
      current_actor_id: get(world, "current_actor_id", nil),
      small_blind: get(table, "small_blind", get(world, "small_blind", 0)),
      big_blind: get(table, "big_blind", get(world, "big_blind", 0)),
      starting_stack: get(world, "starting_stack", 0),
      chip_counts: get(world, "chip_counts", []),
      last_hand_result: get(world, "last_hand_result", nil),
      seat_list: seat_list(get(table, "seats", %{})),
      button_seat: hand && get(hand, "button_seat"),
      small_blind_seat: hand && get(hand, "small_blind_seat"),
      big_blind_seat: hand && get(hand, "big_blind_seat")
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_standings_panel(ctx),
      render_center_content(ctx),
      render_info_panel(ctx),
      render_footer_bar(ctx),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # SVG skeleton
  # ---------------------------------------------------------------------------

  defp svg_header(ctx), do: FrameChrome.svg_header(ctx)

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
      .card-rank { font-family: sans-serif; font-weight: 700; }
    </style>
    """
  end

  # ---------------------------------------------------------------------------
  # Background
  # ---------------------------------------------------------------------------

  defp render_background(ctx), do: FrameChrome.render_background(ctx, @bg)

  # ---------------------------------------------------------------------------
  # Header bar
  # ---------------------------------------------------------------------------

  defp render_header_bar(%{w: w} = ctx) do
    hand_text =
      cond do
        ctx.status == "game_over" -> "FINAL RESULTS"
        true -> "Hand #{ctx.completed_hands + 1}/#{ctx.max_hands}"
      end

    street_text =
      if ctx.hand && ctx.status != "game_over" do
        String.upcase(to_string(get(ctx.hand, "street", "")))
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Title
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@gold}">NO-LIMIT HOLD'EM</text>\n],
      # Hand info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(hand_text)}</text>\n],
      # Street indicator
      if street_text != "" do
        ~s[<text x="#{div(w, 2)}" y="54" class="header-text" font-size="10" ] <>
          ~s[text-anchor="middle" fill="#{street_color(get(ctx.hand, "street"))}" letter-spacing="2">#{esc(street_text)}</text>\n]
      else
        ""
      end,
      # Step counter
      ~s[<text x="#{w - 20}" y="18" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Standings panel (left)
  # ---------------------------------------------------------------------------

  defp render_standings_panel(%{h: h, seat_list: seat_list} = ctx) do
    panel_h = h - @header_h - @footer_h

    ranked = Enum.sort_by(seat_list, &(-&1.stack))

    rows =
      ranked
      |> Enum.with_index()
      |> Enum.map(fn {seat_info, idx} -> render_standings_row(seat_info, idx, ctx) end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@standings_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@standings_w}" y1="#{@header_h}" x2="#{@standings_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@standings_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@standings_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold}">STANDINGS</text>\n],
      rows
    ]
  end

  defp render_standings_row(seat_info, idx, ctx) do
    y = @header_h + 40 + idx * 58
    color = player_color(seat_info.seat)
    is_winner = seat_info.player_id in ctx.winner_ids
    is_acting = ctx.status == "in_progress" and ctx.current_seat == seat_info.seat
    model = model_for(ctx.players, seat_info.player_id)
    delta = seat_info.stack - ctx.starting_stack

    delta_color =
      cond do
        delta > 0 -> @green
        delta < 0 -> @red
        true -> @text_dim
      end

    delta_text = if delta >= 0, do: "+#{delta}", else: "#{delta}"

    highlight =
      cond do
        is_winner ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@standings_w - 8}" height="52" ] <>
            ~s[fill="#{@gold}" opacity="0.1" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@standings_w - 8}" height="52" ] <>
            ~s[fill="none" stroke="#{@gold}" stroke-width="1.5" rx="6"/>\n]

        is_acting ->
          ~s[<rect x="4" y="#{y - 4}" width="#{@standings_w - 8}" height="52" ] <>
            ~s[fill="#{@green}" opacity="0.08" rx="6"/>\n] <>
            ~s[<rect x="4" y="#{y - 4}" width="#{@standings_w - 8}" height="52" ] <>
            ~s[fill="none" stroke="#{@green}" stroke-width="1.5" rx="6" opacity="0.6"/>\n]

        true ->
          ""
      end

    [
      highlight,
      ~s[<circle cx="20" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="34" y="#{y + 14}" class="player-name" font-size="13" fill="#{@text_primary}">#{esc(seat_info.player_id)}</text>\n],
      ~s[<text x="#{@standings_w - 14}" y="#{y + 14}" text-anchor="end" font-size="13" ] <>
        ~s[font-weight="700" fill="#{@gold}">#{seat_info.stack}</text>\n],
      if model do
        ~s[<text x="34" y="#{y + 30}" font-size="9" fill="#{@text_dim}">#{esc(short_model(model))}</text>\n]
      else
        ""
      end,
      ~s[<text x="#{@standings_w - 14}" y="#{y + 30}" text-anchor="end" font-size="9" ] <>
        ~s[fill="#{delta_color}">#{delta_text}</text>\n],
      if is_winner do
        ~s[<text x="34" y="#{y + 44}" font-size="9" font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
      else
        ""
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content
  # ---------------------------------------------------------------------------

  defp render_center_content(%{type: "init"} = ctx), do: render_init_card(ctx)
  defp render_center_content(%{status: "game_over"} = ctx), do: render_game_over_card(ctx)
  defp render_center_content(ctx), do: render_table_view(ctx)

  defp render_init_card(%{w: w, h: h, seat_list: seat_list} = ctx) do
    cx = @standings_w + div(w - @standings_w - @info_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)
    player_count = length(seat_list)

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="30" fill="#{@gold}">NO-LIMIT HOLD'EM</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Multi-Hand Poker Tournament</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Players &#xB7; Blinds #{ctx.small_blind}/#{ctx.big_blind}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 20}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Starting Stack: #{ctx.starting_stack} chips each</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 50}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Up to #{ctx.max_hands} hands will be played</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 102}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Fold &#xB7; Check &#xB7; Call &#xB7; Bet &#xB7; Raise</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 120}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Last stack standing (or biggest stack) wins</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h, seat_list: seat_list} = ctx) do
    cx = @standings_w + div(w - @standings_w - @info_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    sorted = Enum.sort_by(seat_list, &(-&1.stack))
    card_h = 110 + length(sorted) * 46

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="26" fill="#{@gold}">FINAL RESULTS</text>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 62}" text-anchor="middle" font-size="12" ] <>
        ~s[fill="#{@text_dim}">#{esc(reason_label(ctx.game_over_reason))}</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {seat_info, rank} ->
        sy = cy - div(card_h, 2) + 92 + rank * 46
        is_win = seat_info.player_id in ctx.winner_ids
        color = if is_win, do: @gold, else: @text_primary
        rank_label = "##{rank + 1}"

        [
          if is_win do
            ~s[<rect x="#{cx - 260}" y="#{sy - 18}" width="520" height="40" ] <>
              ~s[fill="#{@gold}" opacity="0.08" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">#{rank_label}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 6}" class="player-name" font-size="16" fill="#{color}">#{esc(seat_info.player_id)}</text>\n],
          ~s[<text x="#{cx + 120}" y="#{sy + 6}" text-anchor="end" class="card-rank" font-size="18" fill="#{color}">#{seat_info.stack}</text>\n],
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

  # ---------------------------------------------------------------------------
  # Table view (felt oval + seats + board + pot)
  # ---------------------------------------------------------------------------

  defp render_table_view(%{w: w, h: h} = ctx) do
    avail_w = w - @standings_w - @info_w
    avail_h = h - @header_h - @footer_h - 40

    cx = @standings_w + div(avail_w, 2)
    cy = @header_h + 40 + div(avail_h, 2)
    # Keep seat boxes (centered on the ellipse at radius rx/ry) clear of the
    # side panels and header/footer: subtract half the box footprint plus a
    # small margin from the available half-extents.
    rx = max(div(avail_w, 2) - div(@seat_w, 2) - 10, 60)
    ry = max(div(avail_h, 2) - div(@seat_h, 2) - 10, 60)

    [
      render_hand_headline(ctx, cx),
      render_felt(cx, cy, rx, ry),
      render_board_and_pot(ctx, cx, cy),
      render_seats(ctx, cx, cy, rx, ry),
      render_hand_result_overlay(ctx, cx, cy)
    ]
  end

  defp render_hand_headline(%{hand: nil}, _cx), do: ""

  defp render_hand_headline(%{hand: hand}, cx) do
    hand_id = get(hand, "id", "?")
    street = get(hand, "street", "")

    ~s[<text x="#{cx}" y="#{@header_h + 30}" text-anchor="middle" class="header-text title" ] <>
      ~s[font-size="15" fill="#{@text_secondary}">Hand ##{hand_id} &#xB7; #{esc(String.capitalize(to_string(street)))}</text>\n]
  end

  defp render_felt(cx, cy, rx, ry) do
    [
      ~s[<ellipse cx="#{cx}" cy="#{cy}" rx="#{rx + 22}" ry="#{ry + 22}" ] <>
        ~s[fill="#{@rail}" stroke="#{@rail_edge}" stroke-width="4"/>\n],
      ~s[<ellipse cx="#{cx}" cy="#{cy}" rx="#{rx}" ry="#{ry}" ] <>
        ~s[fill="#{@felt}" stroke="#{@felt_edge}" stroke-width="3"/>\n]
    ]
  end

  defp render_board_and_pot(%{hand: nil}, _cx, _cy), do: ""

  defp render_board_and_pot(%{hand: hand}, cx, cy) do
    board = get(hand, "board", [])
    slots = board ++ List.duplicate(nil, max(5 - length(board), 0))
    gap = 8
    total_w = 5 * @board_card_w + 4 * gap
    start_x = cx - div(total_w, 2)
    card_y = cy - div(@board_card_h, 2) - 14

    card_entries =
      slots
      |> Enum.with_index()
      |> Enum.map(fn {card, idx} ->
        x = start_x + idx * (@board_card_w + gap)
        render_card(x, card_y, @board_card_w, @board_card_h, card)
      end)

    pot = get(hand, "pot", 0)
    to_call = get(hand, "to_call", 0)

    [
      card_entries,
      ~s[<text x="#{cx}" y="#{card_y + @board_card_h + 30}" text-anchor="middle" ] <>
        ~s[class="card-rank" font-size="20" fill="#{@gold}">POT #{pot}</text>\n],
      if to_call && to_call > 0 do
        ~s[<text x="#{cx}" y="#{card_y + @board_card_h + 50}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_secondary}">to call #{to_call}</text>\n]
      else
        ""
      end
    ]
  end

  defp render_seats(%{seat_list: seat_list} = ctx, cx, cy, rx, ry) do
    n = max(length(seat_list), 1)

    seat_list
    |> Enum.with_index()
    |> Enum.map(fn {seat_info, idx} ->
      angle_deg = 90 + idx * (360 / n)
      rad = angle_deg * :math.pi() / 180
      x = round(cx + rx * :math.cos(rad))
      y = round(cy + ry * :math.sin(rad))
      render_seat_box(seat_info, x, y, ctx)
    end)
  end

  defp render_seat_box(seat_info, x, y, ctx) do
    box_x = x - div(@seat_w, 2)
    box_y = y - div(@seat_h, 2)
    color = player_color(seat_info.seat)

    hand_player = hand_player_at(ctx.hand, seat_info.seat)
    position = seat_position(seat_info.seat, ctx)

    is_acting =
      ctx.status == "in_progress" and ctx.hand != nil and
        get(ctx.hand, "acting_seat") == seat_info.seat

    folded = !!(hand_player && get(hand_player, "folded", false))
    all_in = !!(hand_player && get(hand_player, "all_in", false))
    committed = (hand_player && get(hand_player, "committed_round", 0)) || 0
    hole_cards = (hand_player && get(hand_player, "hole_cards", [])) || []
    model = model_for(ctx.players, seat_info.player_id)
    is_button = ctx.button_seat == seat_info.seat

    dim? = folded or seat_info.status in ["busted", "sitting_out"]
    opacity = if dim?, do: "0.55", else: "1"

    border_color =
      cond do
        is_acting -> @green
        true -> @panel_border
      end

    border_w = if is_acting, do: "2.5", else: "1"
    glow = if is_acting, do: ~s[ filter="url(#glow)"], else: ""

    [
      ~s[<g opacity="#{opacity}">\n],
      ~s[<rect x="#{box_x}" y="#{box_y}" width="#{@seat_w}" height="#{@seat_h}" rx="8" ] <>
        ~s[fill="#{@panel_bg}" stroke="#{border_color}" stroke-width="#{border_w}"#{glow}/>\n],
      # Seat number + position pill
      ~s[<circle cx="#{box_x + 14}" cy="#{box_y + 14}" r="6" fill="#{color}"/>\n],
      if position do
        ~s[<rect x="#{box_x + 26}" y="#{box_y + 6}" width="46" height="16" rx="8" fill="#{@gold}" opacity="0.15"/>\n] <>
          ~s[<text x="#{box_x + 49}" y="#{box_y + 18}" text-anchor="middle" font-size="10" ] <>
          ~s[font-weight="700" fill="#{@gold}">#{esc(position)}</text>\n]
      else
        ""
      end,
      # Dealer button marker
      if is_button do
        ~s[<circle cx="#{box_x + @seat_w - 14}" cy="#{box_y + 14}" r="11" fill="#{@gold}"/>\n] <>
          ~s[<text x="#{box_x + @seat_w - 14}" y="#{box_y + 18}" text-anchor="middle" ] <>
          ~s[font-size="11" font-weight="700" fill="#0a100c">D</text>\n]
      else
        ""
      end,
      # Player name
      ~s[<text x="#{box_x + 12}" y="#{box_y + 38}" class="player-name" font-size="15" fill="#{@text_primary}">#{esc(seat_info.player_id)}</text>\n],
      if model do
        ~s[<text x="#{box_x + 12}" y="#{box_y + 52}" font-size="9" fill="#{@text_dim}">#{esc(short_model(model))}</text>\n]
      else
        ""
      end,
      # Stack
      ~s[<text x="#{box_x + @seat_w - 12}" y="#{box_y + 38}" text-anchor="end" ] <>
        ~s[class="card-rank" font-size="15" fill="#{@gold}">#{seat_info.stack}</text>\n],
      # Hole cards
      render_hole_cards(hole_cards, box_x + 12, box_y + 60),
      # Bet chip
      if committed > 0 do
        ~s[<text x="#{box_x + @seat_w - 12}" y="#{box_y + @seat_h - 10}" text-anchor="end" ] <>
          ~s[font-size="11" fill="#{@gold}">bet #{committed}</text>\n]
      else
        ""
      end,
      # Status badges
      cond do
        folded ->
          ~s[<text x="#{box_x + 12}" y="#{box_y + @seat_h - 10}" font-size="10" ] <>
            ~s[font-weight="700" fill="#{@text_dim}">FOLDED</text>\n]

        all_in ->
          ~s[<text x="#{box_x + 12}" y="#{box_y + @seat_h - 10}" font-size="10" ] <>
            ~s[font-weight="700" fill="#{@red}">ALL-IN</text>\n]

        seat_info.status == "busted" ->
          ~s[<text x="#{box_x + 12}" y="#{box_y + @seat_h - 10}" font-size="10" ] <>
            ~s[font-weight="700" fill="#{@text_dim}">BUSTED</text>\n]

        seat_info.status == "sitting_out" ->
          ~s[<text x="#{box_x + 12}" y="#{box_y + @seat_h - 10}" font-size="10" ] <>
            ~s[font-weight="700" fill="#{@text_dim}">SITTING OUT</text>\n]

        true ->
          ""
      end,
      ~s[</g>\n]
    ]
  end

  defp render_hole_cards([], _x, _y), do: ""

  defp render_hole_cards(cards, x, y) do
    cards
    |> Enum.with_index()
    |> Enum.map(fn {card, idx} ->
      cx = x + idx * (@hole_card_w + 6)
      render_card(cx, y, @hole_card_w, @hole_card_h, card)
    end)
  end

  # ---------------------------------------------------------------------------
  # Hand result overlay (shown on the frame where a hand just completed)
  # ---------------------------------------------------------------------------

  defp render_hand_result_overlay(ctx, cx, cy) do
    case find_event(ctx.events, "hand_completed") do
      nil -> ""
      event -> render_hand_result_panel(get(event, "payload", %{}), ctx, cx, cy)
    end
  end

  defp render_hand_result_panel(payload, ctx, cx, cy) do
    hand_id = get(payload, "hand_id", "?")
    ended_by = get(payload, "ended_by", "showdown")
    board = get(payload, "board", [])
    winners = get(payload, "winners", [])
    showdown = get(payload, "showdown", %{})

    showdown_rows = Enum.sort_by(showdown, fn {seat, _info} -> to_seat_int(seat) end)
    panel_h = 130 + max(length(showdown_rows), 1) * 26
    panel_w = 620

    [
      ~s[<rect x="#{cx - div(panel_w, 2)}" y="#{cy - div(panel_h, 2)}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" opacity="0.96" rx="12" stroke="#{@gold}" stroke-width="2"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(panel_h, 2) + 32}" text-anchor="middle" class="title" ] <>
        ~s[font-size="20" fill="#{@gold}">HAND ##{hand_id} COMPLETE &#xB7; #{esc(ended_by_label(ended_by))}</text>\n],
      render_overlay_board(board, cx, cy - div(panel_h, 2) + 44),
      ~s[<text x="#{cx}" y="#{cy - div(panel_h, 2) + 108}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_primary}">#{esc(winners_text(winners, ctx.players))}</text>\n],
      showdown_rows
      |> Enum.with_index()
      |> Enum.map(fn {{seat, info}, idx} ->
        sy = cy - div(panel_h, 2) + 130 + idx * 26
        player_id = seat_player_id(ctx.table, seat)
        category = format_category(get(info, "category"))
        hole_cards = get(info, "hole_cards", [])

        [
          ~s[<text x="#{cx - div(panel_w, 2) + 24}" y="#{sy}" font-size="12" fill="#{@text_secondary}">#{esc(player_id)}</text>\n],
          render_overlay_mini_cards(hole_cards, cx - div(panel_w, 2) + 160, sy - 10),
          ~s[<text x="#{cx + div(panel_w, 2) - 24}" y="#{sy}" text-anchor="end" font-size="11" ] <>
            ~s[fill="#{@text_dim}">#{esc(category)}</text>\n]
        ]
      end)
    ]
  end

  defp render_overlay_board([], _cx, _y), do: ""

  defp render_overlay_board(board, cx, y) do
    card_w = 34
    card_h = 46
    gap = 6
    total_w = length(board) * card_w + max(length(board) - 1, 0) * gap
    start_x = cx - div(total_w, 2)

    board
    |> Enum.with_index()
    |> Enum.map(fn {card, idx} ->
      render_card(start_x + idx * (card_w + gap), y, card_w, card_h, card)
    end)
  end

  defp render_overlay_mini_cards(cards, x, y) do
    cards
    |> Enum.with_index()
    |> Enum.map(fn {card, idx} ->
      render_card(x + idx * 22, y, 18, 24, card)
    end)
  end

  defp winners_text([], _players), do: "No winners recorded."

  defp winners_text(winners, _players) when is_list(winners) do
    winners
    |> Enum.map(fn w -> "#{get(w, "player_id", "?")} +#{get(w, "amount", 0)}" end)
    |> Enum.join(", ")
  end

  defp winners_text(_winners, _players), do: ""

  # ---------------------------------------------------------------------------
  # Info panel (right)
  # ---------------------------------------------------------------------------

  defp render_info_panel(%{w: w, h: h} = ctx) do
    panel_x = w - @info_w
    panel_h = h - @header_h - @footer_h

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@info_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@info_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@info_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold}">TABLE INFO</text>\n],
      render_table_info(ctx, panel_x),
      render_turn_events(ctx, panel_x)
    ]
  end

  defp render_table_info(ctx, panel_x) do
    y0 = @header_h + 50

    [
      ~s[<text x="#{panel_x + 16}" y="#{y0}" font-size="11" fill="#{@text_secondary}">Blinds #{ctx.small_blind}/#{ctx.big_blind}</text>\n],
      if ctx.hand do
        [
          ~s[<text x="#{panel_x + 16}" y="#{y0 + 20}" font-size="11" fill="#{@text_secondary}">Pot #{get(ctx.hand, "pot", 0)}</text>\n],
          ~s[<text x="#{panel_x + 16}" y="#{y0 + 40}" font-size="11" fill="#{@text_secondary}">Min raise #{get(ctx.hand, "min_raise", 0)}</text>\n]
        ]
      else
        ~s[<text x="#{panel_x + 16}" y="#{y0 + 20}" font-size="11" fill="#{@text_dim}">No hand in progress</text>\n]
      end,
      ~s[<line x1="#{panel_x + 12}" y1="#{y0 + 56}" x2="#{panel_x + @info_w - 12}" y2="#{y0 + 56}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + 16}" y="#{y0 + 76}" font-size="11" letter-spacing="1" fill="#{@text_dim}">THIS TURN</text>\n]
    ]
  end

  defp render_turn_events(ctx, panel_x) do
    lines =
      ctx.events
      |> Enum.map(&describe_event(&1, ctx.players))
      |> Enum.reject(&is_nil/1)

    lines =
      if lines == [] do
        ["No new events this frame."]
      else
        lines
      end

    y0 = @header_h + 142

    lines
    |> Enum.take(10)
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      wrap_lines(line, 38)
      |> Enum.with_index()
      |> Enum.map(fn {wrapped, wrap_idx} ->
        y = y0 + idx * 40 + wrap_idx * 14

        ~s[<text x="#{panel_x + 16}" y="#{y}" font-size="10" fill="#{@text_secondary}">#{esc(wrapped)}</text>\n]
      end)
    end)
  end

  defp wrap_lines(text, width) when is_binary(text) do
    if String.length(text) <= width do
      [text]
    else
      [String.slice(text, 0, width - 3) <> "...", String.slice(text, (width - 1)..-1//1)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(2)
    end
  end

  defp wrap_lines(text, _width), do: [to_string(text)]

  # ---------------------------------------------------------------------------
  # Footer bar
  # ---------------------------------------------------------------------------

  defp render_footer_bar(ctx) do
    FrameChrome.render_footer_bar(ctx,
      footer_h: @footer_h,
      panel_bg: @panel_bg,
      panel_border: @panel_border,
      text_primary: @text_primary,
      event_text: format_footer_text(ctx)
    )
  end

  defp format_footer_text(ctx) do
    events = ctx.events

    cond do
      ctx.type == "init" ->
        "No-Limit Hold'em begins with #{length(ctx.seat_list)} players"

      ctx.status == "game_over" ->
        winner_text =
          case ctx.winner_ids do
            [] -> "no winner recorded"
            ids -> Enum.join(ids, ", ")
          end

        "Game over (#{reason_label(ctx.game_over_reason)}) — #{winner_text}"

      has_event?(events, "game_over") ->
        ev = find_event(events, "game_over")
        p = get(ev, "payload", ev || %{})
        "Game over (#{reason_label(get(p, "reason"))})"

      has_event?(events, "hand_completed") ->
        ev = find_event(events, "hand_completed")
        p = get(ev, "payload", ev || %{})

        "Hand ##{get(p, "hand_id", "?")} ends (#{ended_by_label(get(p, "ended_by"))}) — #{winners_text(get(p, "winners", []), ctx.players)}"

      has_event?(events, "poker_action") ->
        ev = find_event(events, "poker_action")
        p = get(ev, "payload", ev || %{})
        describe_action(p)

      has_event?(events, "hand_started") ->
        ev = find_event(events, "hand_started")
        p = get(ev, "payload", ev || %{})
        "Hand ##{get(p, "hand_id", "?")} begins — BTN #{get(p, "button_player_id", "?")}"

      has_event?(events, "action_rejected") ->
        ev = find_event(events, "action_rejected")
        p = get(ev, "payload", ev || %{})
        "#{get(p, "player_id", "?")}: action rejected — #{get(p, "message", "?")}"

      true ->
        street = ctx.hand && get(ctx.hand, "street")

        if street,
          do: "#{String.capitalize(to_string(street))} action continues",
          else: "Table in progress"
    end
  end

  # ---------------------------------------------------------------------------
  # Event descriptions (turn-events panel)
  # ---------------------------------------------------------------------------

  defp describe_event(%{"kind" => "poker_action", "payload" => p}, _players),
    do: describe_action(p)

  defp describe_event(%{"kind" => "hand_completed", "payload" => p}, players) do
    "Hand ##{get(p, "hand_id", "?")} ends (#{ended_by_label(get(p, "ended_by"))}) — " <>
      winners_text(get(p, "winners", []), players)
  end

  defp describe_event(%{"kind" => "hand_started", "payload" => p}, _players) do
    "Hand ##{get(p, "hand_id", "?")} begins — BTN #{get(p, "button_player_id", "?")} / " <>
      "SB #{get(p, "small_blind_player_id", "?")} / BB #{get(p, "big_blind_player_id", "?")}"
  end

  defp describe_event(%{"kind" => "game_over", "payload" => p}, _players) do
    winners = get(p, "winner_ids", [])
    "Game over (#{reason_label(get(p, "reason"))}) — #{Enum.join(winners, ", ")}"
  end

  defp describe_event(%{"kind" => "action_rejected", "payload" => p}, _players) do
    "#{get(p, "player_id", "?")}: rejected — #{get(p, "message", "?")}"
  end

  defp describe_event(%{"kind" => "player_note", "payload" => p}, _players) do
    "#{get(p, "player_id", "?")} jots a private note"
  end

  defp describe_event(_event, _players), do: nil

  defp describe_action(p) do
    player_id = get(p, "player_id", "?")
    action = get(p, "action", "?")
    amount = get(p, "amount")
    street = get(p, "street")

    verb = action_verb(action, amount)
    suffix = if street, do: " (#{String.capitalize(to_string(street))})", else: ""
    "#{player_id} #{verb}#{suffix}"
  end

  defp action_verb("fold", _amount), do: "folds"
  defp action_verb("check", _amount), do: "checks"
  defp action_verb("call", amount) when is_integer(amount), do: "calls #{amount}"
  defp action_verb("call", _amount), do: "calls"
  defp action_verb("bet", amount) when is_integer(amount), do: "bets #{amount}"
  defp action_verb("raise", amount) when is_integer(amount), do: "raises to #{amount}"
  defp action_verb(action, _amount), do: to_string(action)

  # ---------------------------------------------------------------------------
  # Cards
  # ---------------------------------------------------------------------------

  @rank_display %{
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7",
    "eight" => "8",
    "nine" => "9",
    "ten" => "T",
    "jack" => "J",
    "queen" => "Q",
    "king" => "K",
    "ace" => "A"
  }

  @short_suit_names %{"c" => "clubs", "d" => "diamonds", "h" => "hearts", "s" => "spades"}
  @red_suits ["hearts", "diamonds"]

  defp render_card(x, y, w, h, nil) do
    ~s[<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" rx="4" ] <>
      ~s[fill="none" stroke="#{@panel_border}" stroke-width="1" stroke-dasharray="3,3" opacity="0.5"/>\n]
  end

  defp render_card(x, y, w, h, card) do
    {rank, suit_symbol, red?} = card_parts(card)
    color = if red?, do: @red, else: "#111827"

    [
      ~s[<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" rx="4" ] <>
        ~s[fill="#ffffff" stroke="#d1d5db" stroke-width="1"/>\n],
      ~s[<text x="#{x + w / 2}" y="#{y + h * 0.44}" text-anchor="middle" class="card-rank" ] <>
        ~s[font-size="#{card_font_size(h)}" fill="#{color}">#{rank}</text>\n],
      ~s[<text x="#{x + w / 2}" y="#{y + h * 0.84}" text-anchor="middle" ] <>
        ~s[font-size="#{card_font_size(h) - 2}" fill="#{color}">#{suit_symbol}</text>\n]
    ]
  end

  defp card_font_size(h) when h >= 60, do: 22
  defp card_font_size(h) when h >= 40, do: 15
  defp card_font_size(_h), do: 11

  defp card_parts(%{"rank" => rank, "suit" => suit}) do
    {Map.get(@rank_display, rank, "?"), suit_symbol(suit), suit in @red_suits}
  end

  defp card_parts(short) when is_binary(short) and byte_size(short) == 2 do
    <<rank_char::binary-size(1), suit_char::binary-size(1)>> = short
    suit = Map.get(@short_suit_names, String.downcase(suit_char), "?")
    {String.upcase(rank_char), suit_symbol(suit), suit in @red_suits}
  end

  defp card_parts(_card), do: {"?", "?", false}

  defp suit_symbol("clubs"), do: "&#x2663;"
  defp suit_symbol("diamonds"), do: "&#x2666;"
  defp suit_symbol("hearts"), do: "&#x2665;"
  defp suit_symbol("spades"), do: "&#x2660;"
  defp suit_symbol(_), do: "?"

  # ---------------------------------------------------------------------------
  # Seats / positions / players
  # ---------------------------------------------------------------------------

  defp seat_list(seats) when is_map(seats) do
    seats
    |> Enum.map(fn {seat_key, seat_data} ->
      %{
        seat: to_seat_int(seat_key),
        player_id: get(seat_data, "player_id", "?"),
        stack: get(seat_data, "stack", 0),
        status: get(seat_data, "status", "active")
      }
    end)
    |> Enum.sort_by(& &1.seat)
  end

  defp seat_list(_seats), do: []

  defp to_seat_int(seat) when is_integer(seat), do: seat

  defp to_seat_int(seat) when is_binary(seat) do
    case Integer.parse(seat) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_seat_int(_seat), do: 0

  defp hand_player_at(nil, _seat), do: nil

  defp hand_player_at(hand, seat) do
    hand
    |> get("players", %{})
    |> Map.get(to_string(seat))
  end

  defp seat_position(_seat, %{hand: nil}), do: nil

  defp seat_position(seat, %{hand: hand}) do
    button = get(hand, "button_seat")
    sb = get(hand, "small_blind_seat")
    bb = get(hand, "big_blind_seat")

    active =
      hand
      |> get("players", %{})
      |> Map.keys()
      |> Enum.map(&to_seat_int/1)
      |> Enum.sort()

    Table.position_label(seat, button, sb, bb, active)
  end

  defp seat_player_id(table, seat) do
    seats = get(table, "seats", %{})

    case Map.get(seats, to_string(seat)) do
      nil -> "seat #{seat}"
      seat_data -> get(seat_data, "player_id", "seat #{seat}")
    end
  end

  defp model_for(players, player_id) when is_map(players) do
    players
    |> Map.get(player_id, %{})
    |> get("model", nil)
  end

  defp model_for(_players, _player_id), do: nil

  defp player_color(seat) when is_integer(seat) do
    Enum.at(@player_colors, rem(max(seat - 1, 0), length(@player_colors)), @text_primary)
  end

  defp player_color(_seat), do: @text_primary

  defp short_model(model) when is_binary(model) do
    model
    |> String.split("/")
    |> List.last()
    |> String.replace("-preview", "")
  end

  defp short_model(_model), do: ""

  # ---------------------------------------------------------------------------
  # Labels
  # ---------------------------------------------------------------------------

  defp street_color("preflop"), do: "#3b82f6"
  defp street_color("flop"), do: "#22c55e"
  defp street_color("turn"), do: "#f59e0b"
  defp street_color("river"), do: "#a855f7"
  defp street_color(_), do: @text_secondary

  defp ended_by_label("fold"), do: "won by fold"
  defp ended_by_label("showdown"), do: "showdown"
  defp ended_by_label(_), do: "complete"

  defp reason_label("last_player_standing"), do: "last player standing"
  defp reason_label(:last_player_standing), do: "last player standing"
  defp reason_label("hand_limit"), do: "hand limit reached"
  defp reason_label(:hand_limit), do: "hand limit reached"
  defp reason_label("table_stalled"), do: "table stalled"
  defp reason_label(:table_stalled), do: "table stalled"
  defp reason_label(nil), do: "in progress"
  defp reason_label(other), do: to_string(other)

  defp format_category(nil), do: ""

  defp format_category(category) do
    category
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp get(map, key, default \\ nil)

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
