defmodule LemonSim.Examples.SupplyChain.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (logistics/industrial theme)
  # ---------------------------------------------------------------------------
  @bg "#0a0d14"
  @panel_bg "#111827"
  @panel_border "#1f2937"

  @accent "#10b981"
  @accent_dim "#065f46"

  @text_primary "#f1f5f9"
  @text_secondary "#94a3b8"
  @text_dim "#475569"

  # Tier colors (retailer -> distributor -> factory -> raw_materials)
  @tier_colors ["#3b82f6", "#f59e0b", "#10b981", "#8b5cf6"]

  # Layout constants
  @header_h 60
  @footer_h 70
  @side_panel_w 260

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

    tiers = get(world, "tiers", %{})
    round = get(world, "round", 1)
    max_rounds = get(world, "max_rounds", 20)
    phase = get(world, "phase", "observe")
    demand_history = get(world, "demand_history", [])
    consumer_demand = get(world, "consumer_demand", 0)
    winner = get(world, "winner", nil)
    active_actor = get(world, "active_actor_id", nil)
    message_log = get(world, "message_log", [])
    total_chain_cost = get(world, "total_chain_cost", nil)
    team_bonus = get(world, "team_bonus", false)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      tiers: tiers,
      round: round,
      max_rounds: max_rounds,
      phase: phase,
      demand_history: demand_history,
      consumer_demand: consumer_demand,
      winner: winner,
      active_actor: active_actor,
      message_log: message_log,
      total_chain_cost: total_chain_cost,
      team_bonus: team_bonus
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_supply_chain(ctx),
      render_center_panel(ctx),
      render_metrics_panel(ctx),
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
      <linearGradient id="chain-flow" x1="0%" y1="0%" x2="100%" y2="0%">
        <stop offset="0%" style="stop-color:#3b82f6;stop-opacity:0.6"/>
        <stop offset="33%" style="stop-color:#f59e0b;stop-opacity:0.6"/>
        <stop offset="66%" style="stop-color:#10b981;stop-opacity:0.6"/>
        <stop offset="100%" style="stop-color:#8b5cf6;stop-opacity:0.6"/>
      </linearGradient>
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
      .tier-name { font-family: sans-serif; font-weight: 700; }
      .metric-label { font-family: sans-serif; font-size: 10px; fill: #{@text_secondary}; }
      .metric-value { font-family: sans-serif; font-size: 13px; font-weight: 700; }
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

    demand_text =
      if ctx.consumer_demand > 0 do
        "Consumer Demand: #{ctx.consumer_demand}"
      else
        ""
      end

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="20" y="38" class="header-text title" font-size="22" fill="#{@accent}">SUPPLY CHAIN</text>\n],
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(round_text)}</text>\n],
      if phase_text != "" do
        phase_color = phase_color(ctx.phase)

        ~s[<rect x="#{div(w, 2) + 130}" y="14" width="120" height="26" rx="4" ] <>
          ~s[fill="#{phase_color}" opacity="0.2"/>\n] <>
          ~s[<text x="#{div(w, 2) + 190}" y="32" text-anchor="middle" font-size="12" ] <>
          ~s[font-weight="700" fill="#{phase_color}">#{esc(phase_text)}</text>\n]
      else
        ""
      end,
      if demand_text != "" do
        ~s[<text x="#{w - 20}" y="28" class="header-text" font-size="12" ] <>
          ~s[text-anchor="end" fill="#{@accent}">#{esc(demand_text)}</text>\n]
      else
        ""
      end,
      ~s[<text x="#{w - 20}" y="#{if demand_text != "", do: 48, else: 18}" class="header-text" font-size="10" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Supply chain visualization (center top)
  # ---------------------------------------------------------------------------

  defp render_supply_chain(%{w: w, h: h} = ctx) do
    chain_y = @header_h + 20
    tier_order = ["raw_materials", "factory", "distributor", "retailer"]

    # Chain spans the full width minus side panels
    chain_x_start = @side_panel_w + 20
    chain_x_end = w - @side_panel_w - 20
    chain_usable = chain_x_end - chain_x_start

    tier_w = div(chain_usable, 4)

    tier_boxes =
      tier_order
      |> Enum.with_index()
      |> Enum.map(fn {tier_id, idx} ->
        # Reversed color index: raw_materials is index 3, retailer is 0
        color_idx = 3 - idx
        color = Enum.at(@tier_colors, color_idx, @text_secondary)
        x = chain_x_start + idx * tier_w
        render_tier_box(tier_id, idx, x, chain_y, tier_w, color, ctx)
      end)

    # Draw flow arrows between tiers
    arrows =
      0..2
      |> Enum.map(fn idx ->
        x1 = chain_x_start + (idx + 1) * tier_w - 10
        x2 = chain_x_start + (idx + 1) * tier_w + 10
        ay = chain_y + 60

        ~s[<line x1="#{x1}" y1="#{ay}" x2="#{x2}" y2="#{ay}" stroke="#{@accent_dim}" stroke-width="2" marker-end="url(#arrow)"/>\n]
      end)

    # Flow label
    flow_label =
      ~s[<text x="#{chain_x_start + div(chain_usable, 2)}" y="#{chain_y + 180}" ] <>
        ~s[text-anchor="middle" font-size="10" fill="#{@text_dim}" letter-spacing="2">] <>
        ~s[&#x2190; MATERIAL FLOW &nbsp;&nbsp;&nbsp; ORDER FLOW &#x2192;</text>\n]

    # Consumer demand indicator
    consumer_x = chain_x_end + 20

    consumer =
      ~s[<rect x="#{consumer_x}" y="#{chain_y + 20}" width="#{@side_panel_w - 40}" height="80" ] <>
        ~s[rx="6" fill="#{@panel_bg}" stroke="#{@accent}" stroke-width="1" opacity="0.8"/>\n] <>
        ~s[<text x="#{consumer_x + div(@side_panel_w - 40, 2)}" y="#{chain_y + 48}" text-anchor="middle" ] <>
        ~s[font-size="11" font-weight="700" fill="#{@accent}">CONSUMERS</text>\n] <>
        ~s[<text x="#{consumer_x + div(@side_panel_w - 40, 2)}" y="#{chain_y + 72}" text-anchor="middle" ] <>
        ~s[font-size="24" font-weight="700" fill="#{@text_primary}">#{ctx.consumer_demand}</text>\n] <>
        ~s[<text x="#{consumer_x + div(@side_panel_w - 40, 2)}" y="#{chain_y + 90}" text-anchor="middle" ] <>
        ~s[font-size="10" fill="#{@text_secondary}">units demanded</text>\n]

    _ = h
    [tier_boxes, arrows, flow_label, consumer]
  end

  defp render_tier_box(tier_id, _idx, x, chain_y, tier_w, color, ctx) do
    tiers = ctx.tiers
    tier = Map.get(tiers, tier_id, %{})
    inventory = get(tier, "inventory", get(tier, :inventory, 0))
    backlog = get(tier, "backlog", get(tier, :backlog, 0))
    total_cost = get(tier, "total_cost", get(tier, :total_cost, 0.0))
    safety_stock = get(tier, "safety_stock", get(tier, :safety_stock, 0))
    incoming = get(tier, "incoming_deliveries", get(tier, :incoming_deliveries, []))
    pending_order = get(tier, "pending_order", get(tier, :pending_order, 0))

    incoming_qty =
      Enum.sum(
        Enum.map(incoming, fn d ->
          Map.get(d, :quantity, Map.get(d, "quantity", 0))
        end)
      )

    box_w = tier_w - 20
    box_x = x + 10

    is_active = ctx.active_actor == tier_id
    is_winner = ctx.winner == tier_id

    border_color =
      cond do
        is_winner -> "#f1c40f"
        is_active -> color
        true -> @panel_border
      end

    border_width = if is_active or is_winner, do: "2", else: "1"

    role_label = format_tier_name(tier_id)

    # Inventory bar (out of a visual max of 40 units)
    bar_max = 40
    inv_bar_w = round(min(inventory / bar_max, 1.0) * (box_w - 20))

    [
      if is_winner do
        ~s[<rect x="#{box_x - 2}" y="#{chain_y - 2}" width="#{box_w + 4}" height="164" ] <>
          ~s[fill="#f1c40f" opacity="0.08" rx="8"/>\n]
      else
        ""
      end,
      ~s[<rect x="#{box_x}" y="#{chain_y}" width="#{box_w}" height="160" ] <>
        ~s[rx="6" fill="#{@panel_bg}" stroke="#{border_color}" stroke-width="#{border_width}"/>\n],
      # Tier name
      ~s[<rect x="#{box_x}" y="#{chain_y}" width="#{box_w}" height="28" rx="6" fill="#{color}" opacity="0.2"/>\n],
      ~s[<text x="#{box_x + div(box_w, 2)}" y="#{chain_y + 18}" text-anchor="middle" ] <>
        ~s[class="tier-name" font-size="11" fill="#{color}">#{esc(role_label)}</text>\n],
      # Inventory
      ~s[<text x="#{box_x + 10}" y="#{chain_y + 46}" font-size="10" fill="#{@text_secondary}">Inventory</text>\n],
      ~s[<text x="#{box_x + box_w - 10}" y="#{chain_y + 46}" text-anchor="end" font-size="12" font-weight="700" fill="#{@text_primary}">#{inventory}</text>\n],
      ~s[<rect x="#{box_x + 10}" y="#{chain_y + 52}" width="#{box_w - 20}" height="6" fill="#{@bg}" rx="2"/>\n],
      ~s[<rect x="#{box_x + 10}" y="#{chain_y + 52}" width="#{max(inv_bar_w, 0)}" height="6" fill="#{color}" rx="2" opacity="0.7"/>\n],
      # Safety stock line on bar
      if safety_stock > 0 do
        ss_x = box_x + 10 + round(min(safety_stock / bar_max, 1.0) * (box_w - 20))

        ~s[<line x1="#{ss_x}" y1="#{chain_y + 50}" x2="#{ss_x}" y2="#{chain_y + 60}" stroke="#{@accent}" stroke-width="1" opacity="0.8"/>\n]
      else
        ""
      end,
      # Backlog
      ~s[<text x="#{box_x + 10}" y="#{chain_y + 78}" font-size="10" fill="#{@text_secondary}">Backlog</text>\n],
      ~s[<text x="#{box_x + box_w - 10}" y="#{chain_y + 78}" text-anchor="end" font-size="12" font-weight="700" fill="#{if backlog > 0, do: "#ef4444", else: @text_dim}">#{backlog}</text>\n],
      # In transit
      ~s[<text x="#{box_x + 10}" y="#{chain_y + 98}" font-size="10" fill="#{@text_secondary}">In Transit</text>\n],
      ~s[<text x="#{box_x + box_w - 10}" y="#{chain_y + 98}" text-anchor="end" font-size="11" fill="#{@text_secondary}">#{incoming_qty}</text>\n],
      # Pending order
      if pending_order > 0 do
        ~s[<text x="#{box_x + 10}" y="#{chain_y + 118}" font-size="10" fill="#{@text_secondary}">Pending Order</text>\n] <>
          ~s[<text x="#{box_x + box_w - 10}" y="#{chain_y + 118}" text-anchor="end" font-size="11" fill="#{color}">#{pending_order}</text>\n]
      else
        ""
      end,
      # Total cost
      ~s[<text x="#{box_x + 10}" y="#{chain_y + 142}" font-size="10" fill="#{@text_secondary}">Total Cost</text>\n],
      ~s[<text x="#{box_x + box_w - 10}" y="#{chain_y + 142}" text-anchor="end" font-size="12" font-weight="700" fill="#{cost_color(total_cost)}">#{format_cost(total_cost)}</text>\n],
      if is_winner do
        ~s[<text x="#{box_x + div(box_w, 2)}" y="#{chain_y + 158}" text-anchor="middle" font-size="10" font-weight="700" fill="#f1c40f" filter="url(#glow)">WINNER</text>\n]
      else
        ""
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # Center panel: events and communication log
  # ---------------------------------------------------------------------------

  defp render_center_panel(%{w: w, h: h} = ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "game_over" -> render_game_over_card(ctx)
      _ -> render_event_log(ctx, w, h)
    end
  end

  defp render_init_card(%{w: w, h: h}) do
    cx = div(w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2) + 60

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - 150}" width="560" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@accent}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@accent}">SUPPLY CHAIN</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 58}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Multi-Tier Coordination &#x26; Demand Forecasting</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">4 Tiers &#xB7; Information Asymmetry &#xB7; Bullwhip Effect</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 24}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Win: Lowest total cost across all rounds</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 52}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Team bonus if chain cost stays below threshold</text>\n],
      ~s[<line x1="#{cx - 140}" y1="#{cy + 80}" x2="#{cx + 140}" y2="#{cy + 80}" ] <>
        ~s[stroke="#{@accent_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 104}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Observe &#xB7; Communicate &#xB7; Order &#xB7; Fulfill &#xB7; Account</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h} = ctx) do
    cx = div(w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2) + 60
    tier_order = ["retailer", "distributor", "factory", "raw_materials"]

    sorted =
      tier_order
      |> Enum.map(fn tid ->
        tier = Map.get(ctx.tiers, tid, %{})
        cost = get(tier, "total_cost", get(tier, :total_cost, 0.0))
        {tid, cost}
      end)
      |> Enum.sort_by(fn {_, cost} -> cost end)

    card_h = 100 + length(sorted) * 50
    bonus_text = if ctx.team_bonus, do: " + TEAM BONUS!", else: ""

    chain_text =
      if ctx.total_chain_cost,
        do: "Chain Total: #{format_cost(ctx.total_chain_cost)}#{bonus_text}",
        else: ""

    [
      ~s[<rect x="#{cx - 300}" y="#{cy - div(card_h, 2)}" width="600" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@accent}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@accent}">FINAL STANDINGS</text>\n],
      if chain_text != "" do
        ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 66}" text-anchor="middle" font-size="12" fill="#{@text_secondary}">#{esc(chain_text)}</text>\n]
      else
        ""
      end,
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{tid, cost}, rank} ->
        sy = cy - div(card_h, 2) + 90 + rank * 50
        is_winner = tid == ctx.winner
        color = if is_winner, do: "#f1c40f", else: @text_primary

        color_idx =
          Enum.find_index(["retailer", "distributor", "factory", "raw_materials"], &(&1 == tid)) ||
            0

        tier_color = Enum.at(@tier_colors, color_idx, @text_secondary)

        [
          if is_winner do
            ~s[<rect x="#{cx - 280}" y="#{sy - 18}" width="560" height="44" ] <>
              ~s[fill="#f1c40f" opacity="0.08" rx="4"/>\n]
          else
            ""
          end,
          ~s[<text x="#{cx - 250}" y="#{sy + 6}" font-size="14" fill="#{@text_dim}">##{rank + 1}</text>\n],
          ~s[<circle cx="#{cx - 210}" cy="#{sy + 2}" r="6" fill="#{tier_color}"/>\n],
          ~s[<text x="#{cx - 196}" y="#{sy + 6}" class="tier-name" font-size="16" fill="#{color}">#{esc(format_tier_name(tid))}</text>\n],
          ~s[<text x="#{cx + 120}" y="#{sy + 6}" text-anchor="end" font-size="20" font-weight="700" fill="#{color}">#{esc(format_cost(cost))}</text>\n],
          ~s[<text x="#{cx + 130}" y="#{sy + 6}" font-size="11" fill="#{@text_dim}">total cost</text>\n],
          if is_winner do
            ~s[<text x="#{cx + 260}" y="#{sy + 6}" text-anchor="end" font-size="12" font-weight="700" fill="#f1c40f" filter="url(#glow)">WINNER</text>\n]
          else
            ""
          end
        ]
      end)
    ]
  end

  defp render_event_log(%{w: w, h: h} = ctx, _w, _h) do
    panel_x = @side_panel_w + 20
    panel_y = @header_h + 220
    panel_w = w - @side_panel_w * 2 - 40
    panel_h = h - @header_h - @footer_h - 240

    recent_msgs = Enum.take(ctx.message_log, -10)

    [
      ~s[<rect x="#{panel_x}" y="#{panel_y}" width="#{panel_w}" height="#{panel_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 22}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@accent_dim}">COMMUNICATION LOG</text>\n],
      ~s[<line x1="#{panel_x + 10}" y1="#{panel_y + 30}" x2="#{panel_x + panel_w - 10}" y2="#{panel_y + 30}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      if recent_msgs == [] do
        ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + 70}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">No messages exchanged yet</text>\n]
      else
        recent_msgs
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          my = panel_y + 46 + idx * 32
          from_id = get(msg, "from", get(msg, :from, "?"))
          to_id = get(msg, "to", get(msg, :to, "?"))
          msg_type = get(msg, "type", get(msg, :type, "message"))
          round = get(msg, "round", get(msg, :round, "?"))

          from_idx = tier_index(from_id)
          to_idx = tier_index(to_id)
          from_color = Enum.at(@tier_colors, from_idx, @text_secondary)
          to_color = Enum.at(@tier_colors, to_idx, @text_secondary)

          type_icon = if msg_type == "forecast", do: "&#x1F4CA;", else: "&#x2753;"
          is_recent = idx >= length(recent_msgs) - 3
          opacity = if is_recent, do: "1", else: "0.5"

          [
            ~s[<g opacity="#{opacity}">\n],
            ~s[<circle cx="#{panel_x + 22}" cy="#{my + 8}" r="5" fill="#{from_color}"/>\n],
            ~s[<text x="#{panel_x + 32}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{from_color}">#{esc(format_tier_name(from_id))}</text>\n],
            ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{my + 12}" text-anchor="middle" font-size="10" fill="#{@text_dim}">#{type_icon} Round #{round}</text>\n],
            ~s[<circle cx="#{panel_x + panel_w - 80}" cy="#{my + 8}" r="5" fill="#{to_color}"/>\n],
            ~s[<text x="#{panel_x + panel_w - 68}" y="#{my + 12}" font-size="11" font-weight="600" fill="#{to_color}">#{esc(format_tier_name(to_id))}</text>\n],
            ~s[<line x1="#{panel_x + 16}" y1="#{my + 22}" x2="#{panel_x + panel_w - 16}" y2="#{my + 22}" stroke="#{@panel_border}" stroke-width="1" opacity="0.5"/>\n],
            ~s[</g>\n]
          ]
        end)
      end,
      if ctx.active_actor do
        actor_color = Enum.at(@tier_colors, tier_index(ctx.active_actor), @text_secondary)

        [
          ~s[<rect x="#{panel_x + 10}" y="#{panel_y + panel_h - 42}" width="#{panel_w - 20}" height="28" ] <>
            ~s[fill="#{actor_color}" opacity="0.1" rx="4"/>\n],
          ~s[<text x="#{panel_x + div(panel_w, 2)}" y="#{panel_y + panel_h - 23}" text-anchor="middle" ] <>
            ~s[font-size="12" fill="#{actor_color}">#{esc(format_tier_name(ctx.active_actor))} is deciding...</text>\n]
        ]
      else
        ""
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # Metrics panel (left side)
  # ---------------------------------------------------------------------------

  defp render_metrics_panel(%{h: h, w: w} = ctx) do
    panel_h = h - @header_h - @footer_h
    _ = w

    demand_entries =
      ctx.demand_history
      |> Enum.take(-15)
      |> Enum.with_index()

    spark_h = 60
    spark_w = @side_panel_w - 40

    max_demand = Enum.max(ctx.demand_history ++ [1])

    spark_points =
      demand_entries
      |> Enum.with_index()
      |> Enum.map(fn {{demand, _}, idx} ->
        n = min(length(demand_entries), 15)
        x = 20 + if n > 1, do: round(idx * spark_w / (n - 1)), else: div(spark_w, 2)
        y = @header_h + panel_h - @footer_h - 30 - round(demand / max_demand * spark_h)
        "#{x},#{y}"
      end)
      |> Enum.join(" ")

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@side_panel_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@side_panel_w}" y1="#{@header_h}" x2="#{@side_panel_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@side_panel_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@side_panel_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@accent_dim}">DEMAND TREND</text>\n],
      if length(spark_points |> String.split(" ")) >= 2 do
        [
          ~s[<polyline points="#{spark_points}" fill="none" stroke="#{@accent}" stroke-width="2" opacity="0.7"/>\n],
          ~s[<text x="10" y="#{@header_h + panel_h - @footer_h - 20}" font-size="9" fill="#{@text_dim}">Last #{min(length(ctx.demand_history), 15)} rounds</text>\n]
        ]
      else
        ~s[<text x="#{div(@side_panel_w, 2)}" y="#{@header_h + 80}" text-anchor="middle" font-size="10" fill="#{@text_dim}">No data yet</text>\n]
      end,
      # Cost summary per tier
      render_tier_cost_list(ctx)
    ]
  end

  defp render_tier_cost_list(ctx) do
    tier_order = ["retailer", "distributor", "factory", "raw_materials"]

    tier_order
    |> Enum.with_index()
    |> Enum.map(fn {tier_id, idx} ->
      tier = Map.get(ctx.tiers, tier_id, %{})
      total_cost = get(tier, "total_cost", get(tier, :total_cost, 0.0))
      color = Enum.at(@tier_colors, idx, @text_secondary)
      cy = @header_h + 200 + idx * 50

      [
        ~s[<circle cx="16" cy="#{cy + 8}" r="5" fill="#{color}"/>\n],
        ~s[<text x="26" y="#{cy + 12}" font-size="10" fill="#{color}">#{esc(format_tier_name(tier_id))}</text>\n],
        ~s[<text x="#{@side_panel_w - 10}" y="#{cy + 12}" text-anchor="end" font-size="12" font-weight="700" fill="#{cost_color(total_cost)}">#{esc(format_cost(total_cost))}</text>\n]
      ]
    end)
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
        "Supply chain simulation begins: 4 tiers, 20 rounds, minimize total cost"

      ctx.type == "game_over" ->
        winner = ctx.winner
        bonus = if ctx.team_bonus, do: " (Team bonus earned!)", else: ""
        "#{format_tier_name(winner)} wins with lowest total cost!#{bonus}"

      has_event?(events, "demand_realized") ->
        ev = find_event(events, "demand_realized")
        p = get(ev, "payload", ev || %{})
        demand = get(p, "demand", "?")
        fulfilled = get(p, "fulfilled", "?")
        backlog = get(p, "backlog", 0)

        if backlog > 0 do
          "Consumer demand: #{demand} units | Fulfilled: #{fulfilled} | Backlog: #{backlog} units"
        else
          "Consumer demand: #{demand} units | Fully fulfilled"
        end

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins - observe your inventory"

      has_event?(events, "order_fulfilled") ->
        ev = find_event(events, "order_fulfilled")
        p = get(ev, "payload", ev || %{})
        supplier = get(p, "supplier_id", "?")
        customer = get(p, "customer_id", "?")
        ordered = get(p, "ordered", 0)
        fulfilled_qty = get(p, "fulfilled", 0)

        if ordered == fulfilled_qty do
          "#{format_tier_name(supplier)} fully fulfilled #{format_tier_name(customer)}'s order of #{ordered} units"
        else
          "#{format_tier_name(supplier)} partially fulfilled #{format_tier_name(customer)}: #{fulfilled_qty}/#{ordered} units"
        end

      has_event?(events, "forecast_sent") ->
        ev = find_event(events, "forecast_sent")
        p = get(ev, "payload", ev || %{})
        from = get(p, "sender_id", "?")
        to = get(p, "recipient_id", "?")
        "#{format_tier_name(from)} sent demand forecast to #{format_tier_name(to)}"

      has_event?(events, "costs_assessed") ->
        ev = find_event(events, "costs_assessed")
        p = get(ev, "payload", ev || %{})
        tier = get(p, "tier_id", "?")
        total = get(p, "round_total", 0.0)
        "#{format_tier_name(tier)} incurred #{format_cost(total)} this round"

      has_event?(events, "phase_changed") ->
        ev = find_event(events, "phase_changed")
        p = get(ev, "payload", ev || %{})
        from = get(p, "from", "?")
        to = get(p, "to", "?")
        "Phase transition: #{from} -> #{to}"

      true ->
        case ctx.phase do
          "observe" -> "Tiers observing their inventory..."
          "communicate" -> "Exchanging forecasts and coordination signals..."
          "order" -> "Placing orders to upstream suppliers..."
          _ -> ""
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_color("observe"), do: "#3b82f6"
  defp phase_color("communicate"), do: "#f59e0b"
  defp phase_color("order"), do: "#10b981"
  defp phase_color("fulfill"), do: "#8b5cf6"
  defp phase_color("accounting"), do: "#ec4899"
  defp phase_color(_), do: @text_secondary

  defp cost_color(cost) when is_float(cost) and cost > 200.0, do: "#ef4444"
  defp cost_color(cost) when is_float(cost) and cost > 100.0, do: "#f59e0b"
  defp cost_color(cost) when is_number(cost), do: @text_primary
  defp cost_color(_), do: @text_primary

  defp format_cost(cost) when is_float(cost), do: "$#{Float.round(cost, 1)}"
  defp format_cost(cost) when is_integer(cost), do: "$#{cost}.0"
  defp format_cost(cost), do: "$#{cost}"

  defp format_tier_name("retailer"), do: "Retailer"
  defp format_tier_name("distributor"), do: "Distributor"
  defp format_tier_name("factory"), do: "Factory"
  defp format_tier_name("raw_materials"), do: "Raw Materials"
  defp format_tier_name(nil), do: "?"
  defp format_tier_name(name) when is_binary(name), do: name
  defp format_tier_name(_), do: "?"

  defp tier_index("retailer"), do: 0
  defp tier_index("distributor"), do: 1
  defp tier_index("factory"), do: 2
  defp tier_index("raw_materials"), do: 3
  defp tier_index(_), do: 0

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
