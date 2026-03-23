defmodule LemonSim.Examples.Diplomacy.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (medieval/strategic theme)
  # ---------------------------------------------------------------------------
  @bg "#0c0f0a"
  @panel_bg "#1a1f14"
  @panel_border "#2d3328"

  @gold "#f1c40f"
  @gold_dim "#8a7d3b"

  @text_primary "#ecf0f1"
  @text_secondary "#95a5a6"
  @text_dim "#5a6068"

  # Player colors (up to 6 players)
  @player_colors ["#c0392b", "#2980b9", "#27ae60", "#f39c12", "#8e44ad", "#16a085"]

  # Layout constants
  @header_h 60
  @footer_h 70
  @roster_w 300
  @map_w 300

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
    territories = get(world, "territories", %{})
    adjacency = get(world, "adjacency", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 10)
    phase = get(world, "phase", "diplomacy")
    pending_orders = get(world, "pending_orders", %{})
    message_history = get(world, "message_history", [])
    capture_history = get(world, "capture_history", [])
    order_history = get(world, "order_history", [])
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
      territories: territories,
      adjacency: adjacency,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      pending_orders: pending_orders,
      message_history: message_history,
      capture_history: capture_history,
      order_history: order_history,
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
      render_territory_map(ctx),
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
      .territory-text { font-family: sans-serif; }
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
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@gold}">DIPLOMACY</text>\n],
      # Round info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      # Phase badge
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 120}" y="14" width="100" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 170}" y="32" text-anchor="middle" font-size="12" ] <>
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
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">WAR ROOM</text>\n],
      player_entries
    ]
  end

  defp render_player_card(pid, player, idx, color, ctx) do
    y = @header_h + 36 + idx * 148
    faction = get(player, "faction", pid)
    status = get(player, "status", "alive")
    leader_name = get(player, "name", pid)
    is_active = ctx.active_actor == pid
    is_winner = ctx.winner == pid
    is_eliminated = status == "eliminated"

    # Count territories and armies
    {territory_count, army_count} =
      Enum.reduce(ctx.territories, {0, 0}, fn {_name, info}, {tc, ac} ->
        if get(info, "owner", nil) == pid do
          {tc + 1, ac + get(info, "armies", 0)}
        else
          {tc, ac}
        end
      end)

    display_name = format_player_name(pid)

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

    opacity = if is_eliminated, do: "0.35", else: "1"

    # Territory bar (out of 7 win threshold)
    bar_w = @roster_w - 40
    terr_fill_w = round(bar_w * min(territory_count / 7, 1.0))

    [
      highlight,
      ~s[<g opacity="#{opacity}">\n],
      # Faction name with color dot
      ~s[<circle cx="22" cy="#{y + 9}" r="6" fill="#{color}"/>\n],
      ~s[<text x="36" y="#{y + 14}" class="faction-name" font-size="13" fill="#{color}">#{esc(faction)}</text>\n],
      # Leader name
      ~s[<text x="36" y="#{y + 30}" class="player-name" font-size="11" fill="#{@text_secondary}">#{esc(leader_name)} (#{esc(display_name)})</text>\n],
      # Territory bar
      ~s[<text x="16" y="#{y + 52}" font-size="10" fill="#{@text_secondary}">Territories</text>\n],
      ~s[<text x="#{@roster_w - 16}" y="#{y + 52}" text-anchor="end" font-size="10" fill="#{@gold_dim}">#{territory_count}/7</text>\n],
      ~s[<rect x="16" y="#{y + 58}" width="#{bar_w}" height="8" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="16" y="#{y + 58}" width="#{max(terr_fill_w, 0)}" height="8" fill="#{color}" rx="3" opacity="0.8"/>\n],
      # Army count
      ~s[<text x="16" y="#{y + 84}" font-size="10" fill="#{@text_secondary}">Armies: #{army_count}</text>\n],
      # Status
      status_badge(pid, status, is_winner, y, color),
      ~s[</g>\n]
    ]
  end

  defp status_badge(_pid, "eliminated", _is_winner, y, _color) do
    ~s[<text x="#{@roster_w - 16}" y="#{y + 84}" text-anchor="end" font-size="10" ] <>
      ~s[font-weight="700" fill="#e74c3c">ELIMINATED</text>\n]
  end

  defp status_badge(_pid, _status, true, y, _color) do
    ~s[<text x="#{@roster_w - 16}" y="#{y + 84}" text-anchor="end" font-size="11" ] <>
      ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
  end

  defp status_badge(_pid, _status, _is_winner, _y, _color), do: ""

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

  defp render_init_card(%{w: w, h: h, turn_order: turn_order, territories: territories}) do
    cx = @roster_w + div(w - @roster_w - @map_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    player_count = length(turn_order)
    territory_count = map_size(territories)

    [
      ~s[<rect x="#{cx - 240}" y="#{cy - 140}" width="480" height="280" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 80}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@gold}">DIPLOMACY</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 50}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Territory Control &#x26; Alliance Game</text>\n],
      ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{player_count} Players &#xB7; #{territory_count} Territories</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 30}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Win: Control 7+ territories</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 60}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Negotiate, scheme, and conquer!</text>\n],
      ~s[<line x1="#{cx - 120}" y1="#{cy + 90}" x2="#{cx + 120}" y2="#{cy + 90}" ] <>
        ~s[stroke="#{@gold_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 112}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Diplomacy &#xB7; Orders &#xB7; Resolution</text>\n]
    ]
  end

  defp render_game_over_card(%{
         w: w,
         h: h,
         turn_order: turn_order,
         territories: territories,
         winner: winner,
         players: players
       }) do
    cx = @roster_w + div(w - @roster_w - @map_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    sorted =
      turn_order
      |> Enum.map(fn pid ->
        count =
          Enum.count(territories, fn {_name, info} -> get(info, "owner", nil) == pid end)

        {pid, count}
      end)
      |> Enum.sort_by(fn {_, count} -> -count end)

    card_h = 80 + length(sorted) * 50

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@gold}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@gold}">FINAL STANDINGS</text>\n],
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{pid, count}, rank} ->
        sy = cy - div(card_h, 2) + 70 + rank * 50
        is_winner = pid == winner
        color = if is_winner, do: @gold, else: @text_primary
        rank_label = "##{rank + 1}"

        player = Map.get(players, pid, %{})
        faction = get(player, "faction", pid)

        winner_badge =
          if is_winner do
            ~s[<text x="#{cx + 240}" y="#{sy + 6}" text-anchor="end" font-size="12" ] <>
              ~s[font-weight="700" fill="#{@gold}" filter="url(#glow)">WINNER</text>\n]
          else
            ""
          end

        [
          if is_winner do
            ~s[<rect x="#{cx - 260}" y="#{sy - 18}" width="520" height="44" ] <>
              ~s[fill="#{@gold}" opacity="0.08" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 230}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">#{rank_label}</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 6}" class="faction-name" font-size="16" fill="#{color}">#{esc(faction)}</text>\n],
          ~s[<text x="#{cx + 80}" y="#{sy + 6}" text-anchor="end" class="territory-text" font-size="20" fill="#{color}">#{count}</text>\n],
          ~s[<text x="#{cx + 90}" y="#{sy + 6}" font-size="12" fill="#{@text_dim}">territories</text>\n],
          ~s[<text x="#{cx - 190}" y="#{sy + 22}" font-size="9" fill="#{@text_dim}">#{esc(format_player_name(pid))}</text>\n],
          winner_badge
        ]
      end)
    ]
  end

  defp render_phase_content(ctx) do
    case ctx.phase do
      "diplomacy" -> render_diplomacy_panel(ctx)
      "orders" -> render_orders_panel(ctx)
      "resolution" -> render_resolution_panel(ctx)
      _ -> render_diplomacy_panel(ctx)
    end
  end

  defp render_diplomacy_panel(
         %{w: w, h: h, message_history: message_history, turn_order: turn_order, players: players} =
           ctx
       ) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    recent_messages = Enum.take(message_history, -12)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">DIPLOMATIC EXCHANGES</text>\n],
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
          round = get(msg, "round", get(msg, :round, "?"))

          from_idx = Enum.find_index(turn_order, &(&1 == from_id)) || 0
          to_idx = Enum.find_index(turn_order, &(&1 == to_id)) || 0

          from_color = Enum.at(@player_colors, from_idx, @text_secondary)
          to_color = Enum.at(@player_colors, to_idx, @text_secondary)

          from_faction =
            get(Map.get(players, from_id, %{}), "faction", format_player_name(from_id))

          to_faction = get(Map.get(players, to_id, %{}), "faction", format_player_name(to_id))

          is_recent = idx >= length(recent_messages) - 3
          opacity = if is_recent, do: "1", else: "0.5"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{my + 8}" r="5" fill="#{from_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{from_color}">#{esc(from_faction)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{my + 12}" text-anchor="middle" font-size="10" fill="#{@text_dim}">&#x2192; Round #{round}</text>\n],
            ~s[<circle cx="#{panel_x + panel_w - 70}" cy="#{my + 8}" r="5" fill="#{to_color}"/>\n],
            ~s[<text x="#{panel_x + panel_w - 60}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{to_color}">#{esc(to_faction)}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{my + 22}" x2="#{panel_x + panel_w - 16}" y2="#{my + 22}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      # Active player indicator
      if ctx.active_actor do
        actor_idx = Enum.find_index(turn_order, &(&1 == ctx.active_actor)) || 0
        actor_color = Enum.at(@player_colors, actor_idx, @text_secondary)

        actor_faction =
          get(
            Map.get(players, ctx.active_actor, %{}),
            "faction",
            format_player_name(ctx.active_actor)
          )

        [
          ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
            ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
          ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
            ~s[font-size="12" fill="#{actor_color}">#{esc(actor_faction)} is negotiating...</text>\n]
        ]
      else
        ""
      end
    ]
  end

  defp render_orders_panel(
         %{w: w, h: h, pending_orders: pending_orders, turn_order: turn_order, players: players} =
           ctx
       ) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    all_orders =
      Enum.flat_map(pending_orders, fn {player_id, player_orders} ->
        Enum.map(player_orders, fn {_terr, order} ->
          Map.put(order, "player_id", player_id)
        end)
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">PENDING ORDERS</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if all_orders == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Awaiting orders...</text>\n]
      else
        all_orders
        |> Enum.with_index()
        |> Enum.take(15)
        |> Enum.map(fn {order, idx} ->
          oy = panel_y + 48 + idx * 30
          player_id = get(order, "player_id", "?")
          army_terr = get(order, "army_territory", "?")
          order_type = get(order, "order_type", "?")
          target_terr = get(order, "target_territory", "?")

          player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
          player_color = Enum.at(@player_colors, player_idx, @text_secondary)
          type_color = order_type_color(order_type)
          arrow = order_type_arrow(order_type)

          [
            ~s[<circle cx="#{panel_x + 22}" cy="#{oy + 8}" r="4" fill="#{player_color}" opacity="0.8"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{oy + 12}" font-size="10" fill="#{@text_secondary}">#{esc(army_terr)}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{oy + 12}" text-anchor="middle" font-size="10" font-weight="700" fill="#{type_color}">#{arrow} #{esc(String.upcase(order_type))}</text>\n],
            ~s[<text x="#{panel_x + panel_w - 16}" y="#{oy + 12}" text-anchor="end" font-size="10" fill="#{@text_secondary}">#{esc(target_terr)}</text>\n]
          ]
        end)
      end,
      # Active player
      if ctx.active_actor do
        actor_idx = Enum.find_index(turn_order, &(&1 == ctx.active_actor)) || 0
        actor_color = Enum.at(@player_colors, actor_idx, @text_secondary)

        actor_faction =
          get(
            Map.get(players, ctx.active_actor, %{}),
            "faction",
            format_player_name(ctx.active_actor)
          )

        [
          ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
            ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
          ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
            ~s[font-size="12" fill="#{actor_color}">#{esc(actor_faction)} is issuing orders...</text>\n]
        ]
      else
        ""
      end
    ]
  end

  defp render_resolution_panel(
         %{
           w: w,
           h: h,
           events: events,
           capture_history: capture_history,
           players: players,
           turn_order: turn_order
         } = _ctx
       ) do
    panel_x = @roster_w + 10
    panel_y = @header_h + 10
    panel_w = w - @roster_w - @map_w - 20
    panel_h = h - @header_h - @footer_h - 20

    # Show recent battle results from events
    battle_events =
      events
      |> Enum.filter(fn ev ->
        kind = get(ev, "kind", get(ev, :kind, ""))
        kind in ["territory_captured", "bounce", "move_resolved"]
      end)
      |> Enum.take(10)

    recent_captures = Enum.take(capture_history, -6)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="13" letter-spacing="2" fill="#{@gold_dim}">RESOLUTION</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 32}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 32}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if battle_events == [] and recent_captures == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 80}" text-anchor="middle" ] <>
          ~s[font-size="12" fill="#{@text_dim}">Resolving orders...</text>\n]
      else
        [
          battle_events
          |> Enum.with_index()
          |> Enum.map(fn {ev, idx} ->
            ey = panel_y + 48 + idx * 32
            kind = get(ev, "kind", get(ev, :kind, ""))
            payload = get(ev, "payload", get(ev, :payload, %{}))

            render_resolution_event(kind, payload, ey, panel_x, panel_w, players, turn_order)
          end),
          if recent_captures != [] do
            cap_y = panel_y + panel_h - length(recent_captures) * 30 - 10

            [
              ~s[<text x="#{panel_x + 16}" y="#{cap_y - 10}" font-size="10" fill="#{@gold_dim}" letter-spacing="1">CAPTURES THIS GAME</text>\n],
              recent_captures
              |> Enum.with_index()
              |> Enum.map(fn {cap, idx} ->
                cy = cap_y + idx * 26
                territory = get(cap, :territory, get(cap, "territory", "?"))
                attacker = get(cap, :attacker, get(cap, "attacker", "?"))
                round = get(cap, :round, get(cap, "round", "?"))

                atk_idx = Enum.find_index(turn_order, &(&1 == attacker)) || 0
                atk_color = Enum.at(@player_colors, atk_idx, @text_secondary)

                ~s[<text x="#{panel_x + 16}" y="#{cy + 12}" font-size="10" fill="#{atk_color}">] <>
                  ~s[#{esc(format_player_name(attacker))} captures #{esc(territory)} (Round #{round})</text>\n]
              end)
            ]
          else
            ""
          end
        ]
      end
    ]
  end

  defp render_resolution_event(
         "territory_captured",
         payload,
         y,
         panel_x,
         panel_w,
         players,
         turn_order
       ) do
    territory = get(payload, "territory", "?")
    new_owner = get(payload, "new_owner", "?")
    old_owner = get(payload, "old_owner", nil)

    new_idx = Enum.find_index(turn_order, &(&1 == new_owner)) || 0
    new_color = Enum.at(@player_colors, new_idx, @text_secondary)
    new_faction = get(Map.get(players, new_owner, %{}), "faction", format_player_name(new_owner))

    old_text =
      if old_owner do
        old_faction =
          get(Map.get(players, old_owner, %{}), "faction", format_player_name(old_owner))

        " from #{old_faction}"
      else
        " (uncontested)"
      end

    [
      ~s[<rect x="#{panel_x + 10}" y="#{y - 2}" width="#{panel_w - 20}" height="24" ] <>
        ~s[fill="#{new_color}" opacity="0.08" rx="3"/>\n],
      ~s[<text x="#{panel_x + 16}" y="#{y + 14}" font-size="11" font-weight="700" fill="#{new_color}">] <>
        ~s[CAPTURE: #{esc(territory)}#{esc(old_text)} &#x2192; #{esc(new_faction)}</text>\n]
    ]
  end

  defp render_resolution_event("bounce", payload, y, panel_x, _panel_w, _players, _turn_order) do
    territory = get(payload, "territory", "?")

    [
      ~s[<text x="#{panel_x + 16}" y="#{y + 14}" font-size="11" fill="#{@text_dim}">] <>
        ~s[BOUNCE at #{esc(territory)} - no change</text>\n]
    ]
  end

  defp render_resolution_event(
         "move_resolved",
         payload,
         y,
         panel_x,
         _panel_w,
         players,
         turn_order
       ) do
    player_id = get(payload, "player_id", "?")
    from = get(payload, "from", "?")
    to = get(payload, "to", "?")
    success = get(payload, "success", false)

    player_idx = Enum.find_index(turn_order, &(&1 == player_id)) || 0
    player_color = Enum.at(@player_colors, player_idx, @text_secondary)
    faction = get(Map.get(players, player_id, %{}), "faction", format_player_name(player_id))
    result = if success, do: "SUCCESS", else: "REPELLED"
    result_color = if success, do: "#27ae60", else: "#e74c3c"

    [
      ~s[<text x="#{panel_x + 16}" y="#{y + 14}" font-size="10" fill="#{player_color}">] <>
        ~s[#{esc(faction)}: #{esc(from)} &#x2192; #{esc(to)} </text>\n],
      ~s[<text x="#{panel_x + 280}" y="#{y + 14}" font-size="10" font-weight="700" fill="#{result_color}">#{result}</text>\n]
    ]
  end

  defp render_resolution_event(_kind, _payload, _y, _panel_x, _panel_w, _players, _turn_order),
    do: ""

  # ---------------------------------------------------------------------------
  # Territory map (right panel)
  # ---------------------------------------------------------------------------

  defp render_territory_map(
         %{w: w, h: h, territories: territories, turn_order: turn_order} = _ctx
       ) do
    panel_x = w - @map_w
    panel_h = h - @header_h - @footer_h

    territory_names = territories |> Map.keys() |> Enum.sort()

    territory_entries =
      territory_names
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        info = Map.get(territories, name, %{})
        owner = get(info, "owner", get(info, :owner, nil))
        armies = get(info, "armies", get(info, :armies, 0))

        ty = @header_h + 40 + idx * 28

        {owner_color, owner_opacity} =
          if owner do
            owner_idx = Enum.find_index(turn_order, &(&1 == owner)) || 0
            {Enum.at(@player_colors, owner_idx, @text_secondary), "1"}
          else
            {@text_dim, "0.5"}
          end

        [
          ~s[<rect x="#{panel_x + 8}" y="#{ty - 10}" width="#{@map_w - 16}" height="22" ] <>
            ~s[fill="#{owner_color}" opacity="#{if owner, do: "0.12", else: "0.04"}" rx="3"/>\n],
          ~s[<circle cx="#{panel_x + 20}" cy="#{ty + 2}" r="4" fill="#{owner_color}" opacity="#{owner_opacity}"/>\n],
          ~s[<text x="#{panel_x + 32}" y="#{ty + 6}" font-size="10" fill="#{owner_color}" opacity="#{owner_opacity}">#{esc(name)}</text>\n],
          if armies > 0 do
            ~s[<text x="#{panel_x + @map_w - 16}" y="#{ty + 6}" text-anchor="end" font-size="10" font-weight="700" fill="#{owner_color}" opacity="#{owner_opacity}">#{armies}</text>\n]
          else
            ~s[<text x="#{panel_x + @map_w - 16}" y="#{ty + 6}" text-anchor="end" font-size="9" fill="#{@text_dim}">-</text>\n]
          end
        ]
      end)

    [
      # Panel background
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@map_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Panel title
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@map_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@map_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@gold_dim}">TERRITORIES</text>\n],
      territory_entries,
      # Empty state
      if territories == %{} do
        ~s[<text x="#{panel_x + div(@map_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No territories</text>\n]
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
        "Game begins: #{length(ctx.turn_order)} players vie for control of #{map_size(ctx.territories)} territories"

      ctx.type == "game_over" ->
        winner = ctx.winner
        player = Map.get(ctx.players, winner, %{})
        faction = get(player, "faction", format_player_name(winner))
        "#{faction} wins the diplomacy game!"

      has_event?(events, "territory_captured") ->
        ev = find_event(events, "territory_captured")
        p = get(ev, "payload", ev || %{})
        new_owner = get(p, "new_owner", "?")
        territory = get(p, "territory", "?")
        player = Map.get(ctx.players, new_owner, %{})
        faction = get(player, "faction", format_player_name(new_owner))
        "#{faction} captures #{territory}!"

      has_event?(events, "bounce") ->
        ev = find_event(events, "bounce")
        p = get(ev, "payload", ev || %{})
        "Contested battle at #{get(p, "territory", "?")} ends in a bounce!"

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins - new diplomacy phase"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        from = get(p, "from", "?")
        to = get(p, "to", "?")
        "Phase transition: #{from} -> #{to}"

      has_event?(events, "orders_submitted") ->
        ev = find_event(events, "orders_submitted")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        faction = get(player, "faction", format_player_name(player_id))
        "#{faction} submits orders"

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

      has_event?(events, "diplomacy_ended") ->
        ev = find_event(events, "diplomacy_ended")
        p = get(ev, "payload", ev || %{})
        player_id = get(p, "player_id", "?")
        player = Map.get(ctx.players, player_id, %{})
        faction = get(player, "faction", format_player_name(player_id))
        "#{faction} concludes diplomacy"

      true ->
        phase_text =
          case ctx.phase do
            "diplomacy" -> "Diplomatic negotiations underway..."
            "orders" -> "Orders being issued..."
            "resolution" -> "Resolving all orders simultaneously..."
            _ -> ""
          end

        phase_text
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("diplomacy"), do: "#2980b9"
  defp phase_color("orders"), do: "#f39c12"
  defp phase_color("resolution"), do: "#c0392b"
  defp phase_color(_), do: @text_secondary

  defp order_type_color("move"), do: "#c0392b"
  defp order_type_color("hold"), do: "#27ae60"
  defp order_type_color("support"), do: "#2980b9"
  defp order_type_color(_), do: @text_secondary

  defp order_type_arrow("move"), do: "&#x2192;"
  defp order_type_arrow("hold"), do: "&#x25A0;"
  defp order_type_arrow("support"), do: "&#x2295;"
  defp order_type_arrow(_), do: "&#x3F;"

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
