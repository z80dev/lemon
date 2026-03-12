defmodule LemonSim.Examples.Werewolf.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (dark theme)
  # ---------------------------------------------------------------------------
  @bg "#1a1a2e"
  @header_bg "#16213e"
  @footer_bg "#16213e"
  @card_bg "#0f3460"

  @text_primary "#e0e0e0"
  @text_secondary "#a0a0a0"

  # Provider colors
  @color_anthropic "#8B5CF6"
  @color_google "#4285F4"
  @color_openai "#10A37F"
  @color_moonshot "#FF6B35"
  @color_default "#888888"

  # Role colors
  @role_werewolf "#e74c3c"
  @role_seer "#9b59b6"
  @role_doctor "#2ecc71"
  @role_villager "#ecf0f1"

  # Layout constants
  @header_h 70
  @footer_h 80

  # Player seat dimensions
  @avatar_r 30
  @seat_w 130
  @seat_h 110

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Renders a single game log entry as a self-contained SVG string.

  `entry` is a map (string or atom keys) representing one line from the JSONL
  transcript.  Supported entry types: `game_start`, `turn_start`, `turn_result`,
  `game_over`.

  Options:
    * `:width`  - SVG width in pixels (default 1920)
    * `:height` - SVG height in pixels (default 1080)
    * `:players` - player info map from game_start (passed through for
      subsequent frames so every frame knows roles/models)
    * `:elimination_log` - cumulative elimination log
  """
  @spec render_frame(map(), keyword()) :: String.t()
  def render_frame(entry, opts \\ []) do
    w = Keyword.get(opts, :width, 1920)
    h = Keyword.get(opts, :height, 1080)

    players_info = Keyword.get(opts, :players, nil)
    ext_elim_log = Keyword.get(opts, :elimination_log, [])

    entry_type = get(entry, :type, "unknown")

    # Build the unified context that every sub-renderer can use
    ctx = build_context(entry, entry_type, w, h, players_info, ext_elim_log)

    svg_content =
      [
        svg_header(ctx),
        svg_defs(ctx),
        svg_style(),
        render_background(ctx),
        render_header_bar(ctx),
        render_player_seats(ctx),
        render_center_content(ctx),
        render_footer_bar(ctx),
        "</svg>"
      ]
      |> IO.iodata_to_binary()

    svg_content
  end

  @doc """
  Renders a frame and writes it to the given file path.
  """
  @spec render_frame_to_file(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def render_frame_to_file(entry, path, opts \\ []) do
    svg = render_frame(entry, opts)
    File.write(path, svg)
  end

  # ---------------------------------------------------------------------------
  # Context builder
  # ---------------------------------------------------------------------------

  defp build_context(entry, entry_type, w, h, players_info, ext_elim_log) do
    step = get(entry, :step, 0)
    day = get(entry, :day, get_nested_day(entry))
    phase = to_string(get(entry, :phase, get_nested_phase(entry)))
    active_player = get(entry, :active_player, nil)
    model = get(entry, :model, nil)
    detail = get(entry, :detail, %{})
    elimination_log = get(entry, :elimination_log, ext_elim_log)
    winner = get(entry, :winner, nil)

    # Resolve players: from game_start's "players" key, or from opts
    players =
      case entry_type do
        "game_start" -> get(entry, :players, %{})
        "game_over" -> get(entry, :players, players_info || %{})
        _ -> players_info || %{}
      end

    # Build a list of player IDs sorted numerically
    player_ids = resolve_player_ids(players, entry)
    player_count = length(player_ids)

    # Determine dead players from elimination_log
    dead_set = build_dead_set(elimination_log)

    # Oval center for player seats
    center_x = div(w, 2)
    center_y = div(h - @footer_h + @header_h, 2) + 10
    rx = min(div(w, 2) - @seat_w, 620)
    ry = min(div(h - @header_h - @footer_h, 2) - @seat_h + 10, 320)

    %{
      w: w,
      h: h,
      entry_type: entry_type,
      step: step,
      day: day,
      phase: phase,
      active_player: active_player,
      model: model,
      detail: detail,
      players: players,
      player_ids: player_ids,
      player_count: player_count,
      elimination_log: elimination_log,
      dead_set: dead_set,
      winner: winner,
      center_x: center_x,
      center_y: center_y,
      rx: rx,
      ry: ry
    }
  end

  defp get_nested_day(entry) do
    world = get(entry, :world, %{})
    get(world, :day_number, 1)
  end

  defp get_nested_phase(entry) do
    world = get(entry, :world, %{})
    get(world, :phase, "night")
  end

  defp resolve_player_ids(players, entry) do
    ids =
      if map_size(players) > 0 do
        Map.keys(players)
      else
        world = get(entry, :world, %{})
        world_players = get(world, :players, %{})
        Map.keys(world_players)
      end

    ids
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp build_dead_set(elimination_log) when is_list(elimination_log) do
    MapSet.new(elimination_log, fn entry ->
      to_string(get(entry, :player, ""))
    end)
  end

  defp build_dead_set(_), do: MapSet.new()

  # ---------------------------------------------------------------------------
  # SVG skeleton
  # ---------------------------------------------------------------------------

  defp svg_header(%{w: w, h: h}) do
    ~s[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" ] <>
      ~s[width="#{w}" height="#{h}">\n]
  end

  defp svg_defs(ctx) do
    [
      "<defs>\n",
      # Arrow marker for vote lines
      ~s[<marker id="arrowhead" markerWidth="10" markerHeight="7" ] <>
        ~s[refX="10" refY="3.5" orient="auto">\n],
      ~s[  <polygon points="0 0, 10 3.5, 0 7" fill="#{@text_primary}" opacity="0.7"/>\n],
      "</marker>\n",
      # Glow filter for active players
      ~s[<filter id="glow">\n],
      ~s[  <feGaussianBlur stdDeviation="4" result="blur"/>\n],
      ~s[  <feMerge>\n],
      ~s[    <feMergeNode in="blur"/>\n],
      ~s[    <feMergeNode in="SourceGraphic"/>\n],
      ~s[  </feMerge>\n],
      ~s[</filter>\n],
      # Night overlay gradient
      render_phase_gradient(ctx),
      "</defs>\n"
    ]
  end

  defp render_phase_gradient(%{phase: phase}) do
    case phase do
      "night" ->
        [
          ~s[<radialGradient id="phase-overlay" cx="50%" cy="40%" r="60%">\n],
          ~s[  <stop offset="0%" stop-color="#000030" stop-opacity="0.15"/>\n],
          ~s[  <stop offset="100%" stop-color="#000030" stop-opacity="0.45"/>\n],
          ~s[</radialGradient>\n]
        ]

      _ ->
        [
          ~s[<radialGradient id="phase-overlay" cx="50%" cy="40%" r="60%">\n],
          ~s[  <stop offset="0%" stop-color="#3a3000" stop-opacity="0.05"/>\n],
          ~s[  <stop offset="100%" stop-color="#3a3000" stop-opacity="0.1"/>\n],
          ~s[</radialGradient>\n]
        ]
    end
  end

  defp svg_style do
    ~s"""
    <style>
      text { font-family: 'Courier New', Courier, monospace; }
      .title { font-family: sans-serif; font-weight: 700; }
      .label { font-family: sans-serif; font-size: 12px; fill: #{@text_secondary}; }
      .header-text { font-family: sans-serif; fill: #{@text_primary}; }
      .footer-text { font-family: sans-serif; fill: #{@text_primary}; }
      .player-name { font-family: sans-serif; font-weight: 600; font-size: 14px; }
      .model-label { font-family: sans-serif; font-size: 11px; fill: #{@text_secondary}; }
      .role-badge { font-family: sans-serif; font-weight: 700; font-size: 11px; }
      .phase-label { font-family: sans-serif; font-weight: 600; }
      .speech-text { font-family: sans-serif; font-size: 16px; fill: #{@text_primary}; }
      .speech-quote { font-family: sans-serif; font-size: 26px; font-weight: 600; fill: #{@text_primary}; }
      .story-title { font-family: sans-serif; font-size: 18px; font-weight: 700; fill: #f1c40f; }
      .story-summary { font-family: sans-serif; font-size: 26px; font-weight: 700; fill: #{@text_primary}; }
      .story-line { font-family: sans-serif; font-size: 18px; fill: #{@text_secondary}; }
      .center-title { font-family: sans-serif; font-weight: 700; }
      .vote-label { font-family: sans-serif; font-size: 13px; fill: #{@text_primary}; }
      .sidebar-label { font-family: sans-serif; font-size: 12px; font-weight: 700; fill: #{@text_secondary}; text-transform: uppercase; }
      .sidebar-text { font-family: sans-serif; font-size: 13px; fill: #{@text_primary}; }
      .callout-text { font-family: sans-serif; font-size: 20px; font-weight: 700; fill: #ffffff; }
    </style>
    """
  end

  # ---------------------------------------------------------------------------
  # Background
  # ---------------------------------------------------------------------------

  defp render_background(%{w: w, h: h}) do
    [
      ~s[<rect width="#{w}" height="#{h}" fill="#{@bg}"/>\n],
      ~s[<rect width="#{w}" height="#{h}" fill="url(#phase-overlay)"/>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Header bar
  # ---------------------------------------------------------------------------

  defp render_header_bar(ctx) do
    %{w: w, day: day, phase: phase, step: step} = ctx

    phase_text = phase_display(phase)
    phase_color = phase_color(phase)

    [
      # Background
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@header_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" ] <>
        ~s[stroke="#252540" stroke-width="1"/>\n],
      # Title (left)
      ~s[<text x="30" y="44" class="header-text title" font-size="26" ] <>
        ~s[letter-spacing="4" fill="#{@role_werewolf}">WEREWOLF</text>\n],
      # Day + Phase (center)
      ~s[<text x="#{div(w, 2)}" y="36" class="header-text title" font-size="22" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">Day #{day}</text>\n],
      ~s[<text x="#{div(w, 2)}" y="58" class="phase-label" font-size="16" ] <>
        ~s[text-anchor="middle" fill="#{phase_color}">#{esc(phase_text)}</text>\n],
      # Step counter (right)
      ~s[<text x="#{w - 30}" y="44" class="header-text" font-size="16" ] <>
        ~s[text-anchor="end" fill="#{@text_secondary}">Step #{step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Player seats (arranged in oval)
  # ---------------------------------------------------------------------------

  defp render_player_seats(ctx) do
    %{
      player_ids: player_ids,
      player_count: count,
      players: players,
      dead_set: dead_set,
      active_player: active,
      phase: phase,
      center_x: cx,
      center_y: cy,
      rx: rx,
      ry: ry,
      detail: detail
    } = ctx

    # Compute speaker for discussion phase
    speaker =
      if phase == "day_discussion" do
        to_string(get(detail, :speaker, ""))
      else
        nil
      end

    player_ids
    |> Enum.with_index()
    |> Enum.map(fn {player_id, idx} ->
      angle = idx / max(count, 1) * 2 * :math.pi() - :math.pi() / 2
      px = round(cx + rx * :math.cos(angle))
      py = round(cy + ry * :math.sin(angle))

      player_info =
        Map.get(players, player_id) || Map.get(players, String.to_atom(player_id), %{})

      is_dead = MapSet.member?(dead_set, player_id)
      is_active = to_string(active) == player_id
      is_speaker = speaker == player_id

      role = to_string(get(player_info, :role, ""))
      model_str = to_string(get(player_info, :model, ""))
      status = to_string(get(player_info, :status, if(is_dead, do: "dead", else: "alive")))
      is_dead = is_dead or status == "dead"

      show_role = true
      revealed_role = if show_role, do: role, else: nil
      display_name = player_display_name(player_id, player_info)

      render_player_seat(
        px,
        py,
        display_name,
        model_str,
        revealed_role,
        is_dead,
        is_active,
        is_speaker,
        phase
      )
    end)
  end

  defp render_player_seat(
         x,
         y,
         player_label,
         model_str,
         revealed_role,
         is_dead,
         is_active,
         is_speaker,
         phase
       ) do
    provider_color = provider_color(model_str)
    seat_stroke = if revealed_role == "werewolf", do: @role_werewolf, else: provider_color
    short_model = short_model_name(model_str)

    opacity = if is_dead, do: "0.35", else: "1"
    glow_filter = if is_active and not is_dead, do: ~s[ filter="url(#glow)"], else: ""

    [
      ~s[<g transform="translate(#{x}, #{y})" opacity="#{opacity}">\n],

      # Card background
      ~s[  <rect x="#{-div(@seat_w, 2)}" y="#{-div(@seat_h, 2)}" ] <>
        ~s[width="#{@seat_w}" height="#{@seat_h}" rx="8" fill="#{@card_bg}" opacity="0.6" stroke="#{seat_stroke}" stroke-width="2"/>\n],

      # Active/speaker highlight ring
      if is_active and not is_dead do
        ~s[  <circle cx="0" cy="-10" r="#{@avatar_r + 5}" fill="none" ] <>
          ~s[stroke="#{provider_color}" stroke-width="3" opacity="0.8"#{glow_filter}/>\n]
      else
        if is_speaker and not is_dead do
          ~s[  <circle cx="0" cy="-10" r="#{@avatar_r + 5}" fill="none" ] <>
            ~s[stroke="#f1c40f" stroke-width="2" opacity="0.7"/>\n]
        else
          ""
        end
      end,

      # Avatar circle
      if is_dead do
        [
          ~s[  <circle cx="0" cy="-10" r="#{@avatar_r}" fill="#444" stroke="#333" stroke-width="2"/>\n],
          # X overlay
          ~s[  <line x1="-12" y1="-22" x2="12" y2="2" stroke="#{@role_werewolf}" stroke-width="3" opacity="0.8"/>\n],
          ~s[  <line x1="12" y1="-22" x2="-12" y2="2" stroke="#{@role_werewolf}" stroke-width="3" opacity="0.8"/>\n]
        ]
      else
        [
          ~s[  <circle cx="0" cy="-10" r="#{@avatar_r}" fill="#{provider_color}" ] <>
            ~s[stroke="#{darken_color(provider_color)}" stroke-width="2"/>\n],
          # Inner initial letter
          ~s[  <text x="0" y="-3" text-anchor="middle" font-size="18" ] <>
            ~s[font-weight="700" fill="white">#{esc(String.first(player_label) || "?")}</text>\n]
        ]
      end,

      # Player name
      ~s[  <text x="0" y="#{@avatar_r + 8}" text-anchor="middle" ] <>
        ~s[class="player-name" fill="#{@text_primary}">#{esc(player_label)}</text>\n],

      # Model label
      ~s[  <text x="0" y="#{@avatar_r + 22}" text-anchor="middle" ] <>
        ~s[class="model-label">#{esc(short_model)}</text>\n],

      # Role badge (when revealed)
      if revealed_role do
        render_role_badge(0, @avatar_r + 34, revealed_role)
      else
        ""
      end,
      if revealed_role == "werewolf" and not is_dead do
        [
          ~s[  <rect x="#{-div(@seat_w, 2) + 8}" y="#{-div(@seat_h, 2) + 8}" width="44" height="18" rx="9" fill="#{@role_werewolf}" opacity="0.95"/>\n],
          ~s[  <text x="#{-div(@seat_w, 2) + 30}" y="#{-div(@seat_h, 2) + 21}" text-anchor="middle" class="role-badge" fill="white">WOLF</text>\n]
        ]
      else
        ""
      end,

      # Night phase indicator: show subtle action icon for active werewolf/seer/doctor
      if is_active and not is_dead and phase == "night" do
        ~s[  <circle cx="#{@avatar_r - 4}" cy="#{-@avatar_r - 2}" r="6" fill="#f1c40f" opacity="0.9"/>\n]
      else
        ""
      end,
      ~s[</g>\n]
    ]
  end

  defp render_role_badge(x, y, role) do
    {badge_text, badge_color} = role_badge_info(role)

    [
      ~s[  <rect x="#{x - 16}" y="#{y - 10}" width="32" height="16" rx="4" ] <>
        ~s[fill="#{badge_color}" opacity="0.9"/>\n],
      ~s[  <text x="#{x}" y="#{y + 2}" text-anchor="middle" ] <>
        ~s[class="role-badge" fill="white">#{badge_text}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content (phase-specific)
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    %{phase: phase, entry_type: entry_type} = ctx
    detail = ctx.detail

    cond do
      get(detail, :story_card, nil) != nil ->
        render_story_card_center(ctx)

      entry_type == "game_over" or phase == "game_over" ->
        render_game_over_center(ctx)

      phase == "night" ->
        render_night_center(ctx)

      phase == "day_discussion" ->
        render_discussion_center(ctx)

      phase == "day_voting" ->
        render_voting_center(ctx)

      true ->
        ""
    end
  end

  defp render_story_card_center(ctx) do
    %{center_x: cx, center_y: cy, detail: detail} = ctx
    card = get(detail, :story_card, %{})
    title = to_string(get(card, :title, ""))
    summary = to_string(get(card, :summary, ""))
    lines = List.wrap(get(card, :lines, []))

    panel_w = 980
    panel_h = 320
    px = cx - div(panel_w, 2)
    py = cy - div(panel_h, 2)

    [
      ~s[<rect x="#{px}" y="#{py}" width="#{panel_w}" height="#{panel_h}" rx="24" fill="#081426" opacity="0.94" stroke="#2b4a67" stroke-width="2"/>\n],
      ~s[<rect x="#{px + 28}" y="#{py + 28}" width="#{panel_w - 56}" height="42" rx="10" fill="#122743" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{py + 56}" text-anchor="middle" class="story-title">#{esc(title)}</text>\n],
      ~s[<text x="#{cx}" y="#{py + 126}" text-anchor="middle" class="story-summary">#{esc(summary)}</text>\n],
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        ly = py + 184 + idx * 34

        ~s[<text x="#{cx}" y="#{ly}" text-anchor="middle" class="story-line">#{esc(line)}</text>\n]
      end)
    ]
  end

  # -- Night center: Moon icon --

  defp render_night_center(ctx) do
    %{center_x: cx, center_y: cy} = ctx

    [
      # Moon (crescent via two overlapping circles)
      ~s[<circle cx="#{cx}" cy="#{cy - 10}" r="50" fill="#f0e68c" opacity="0.15"/>\n],
      ~s[<circle cx="#{cx + 18}" cy="#{cy - 18}" r="42" fill="#{@bg}"/>\n],
      # Stars
      render_star(cx - 120, cy - 80, 3),
      render_star(cx + 100, cy - 100, 2),
      render_star(cx - 80, cy + 60, 2),
      render_star(cx + 140, cy + 40, 3),
      render_star(cx - 160, cy - 20, 2),
      # Text
      ~s[<text x="#{cx}" y="#{cy + 60}" text-anchor="middle" ] <>
        ~s[class="center-title" font-size="20" fill="#{@text_secondary}" ] <>
        ~s[opacity="0.7">Night falls on the village...</text>\n]
    ]
  end

  defp render_star(x, y, r) do
    ~s[<circle cx="#{x}" cy="#{y}" r="#{r}" fill="#f0e68c" opacity="0.6"/>\n]
  end

  # -- Discussion center: Speech bubble --

  defp render_discussion_center(ctx) do
    %{
      center_x: cx,
      center_y: cy,
      detail: detail,
      player_ids: player_ids,
      player_count: count,
      rx: orx,
      ry: ory
    } = ctx

    statement = to_string(get(detail, :statement, ""))
    speaker = to_string(get(detail, :speaker, ""))
    story_title = to_string(get(detail, :story_title, "Discussion"))
    recent = List.wrap(get(detail, :recent_statements, []))

    if statement == "" do
      # Transition frame: show sun
      render_day_sun(cx, cy)
    else
      panel_w = 1040
      panel_h = 330
      px = cx - div(panel_w, 2)
      py = cy - div(panel_h, 2) - 10
      left_x = px + 42
      current_lines = wrap_text(statement, 52, 7)
      recent = Enum.take(recent, -2)

      # Find speaker position for pointer
      speaker_idx = Enum.find_index(player_ids, fn id -> id == speaker end)

      pointer =
        if speaker_idx do
          angle = speaker_idx / max(count, 1) * 2 * :math.pi() - :math.pi() / 2
          sx = round(cx + orx * :math.cos(angle))
          sy = round(cy + ory * :math.sin(angle))

          # Line from speaker to bubble edge
          ~s[<line x1="#{sx}" y1="#{sy}" x2="#{cx}" y2="#{py + panel_h}" ] <>
            ~s[stroke="#f1c40f" stroke-width="2" opacity="0.4" stroke-dasharray="6,4"/>\n]
        else
          ""
        end

      [
        pointer,
        ~s[<rect x="#{px}" y="#{py}" width="#{panel_w}" height="#{panel_h}" rx="18" fill="#071321" opacity="0.96" stroke="#2e4d6f" stroke-width="2"/>\n],
        ~s[<line x1="#{px + 700}" y1="#{py + 24}" x2="#{px + 700}" y2="#{py + panel_h - 24}" stroke="#21415d" stroke-width="1"/>\n],
        ~s[<text x="#{left_x}" y="#{py + 34}" class="story-title">#{esc(story_title)}</text>\n],
        ~s[<text x="#{left_x}" y="#{py + 66}" class="player-name" font-size="18" fill="#f1c40f">#{esc(player_display_name(speaker, ctx.players))}</text>\n],
        ~s[<text x="#{left_x + 110}" y="#{py + 66}" class="label" font-size="14">speaks</text>\n],
        current_lines
        |> Enum.with_index()
        |> Enum.map(fn {line, i} ->
          ly = py + 112 + i * 32
          ~s[<text x="#{left_x}" y="#{ly}" class="speech-quote">#{esc(line)}</text>\n]
        end),
        ~s[<text x="#{px + 732}" y="#{py + 36}" class="sidebar-label">Recent Claims</text>\n],
        render_recent_statements(px + 732, py + 62, recent, ctx.players)
      ]
    end
  end

  defp render_day_sun(cx, cy) do
    # Simple sun representation
    [
      ~s[<circle cx="#{cx}" cy="#{cy}" r="40" fill="#f1c40f" opacity="0.15"/>\n],
      ~s[<circle cx="#{cx}" cy="#{cy}" r="25" fill="#f1c40f" opacity="0.25"/>\n],
      # Rays
      for i <- 0..7 do
        angle = i * :math.pi() / 4
        x1 = round(cx + 32 * :math.cos(angle))
        y1 = round(cy + 32 * :math.sin(angle))
        x2 = round(cx + 55 * :math.cos(angle))
        y2 = round(cy + 55 * :math.sin(angle))

        ~s[<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" ] <>
          ~s[stroke="#f1c40f" stroke-width="2" opacity="0.2"/>\n]
      end,
      ~s[<text x="#{cx}" y="#{cy + 80}" text-anchor="middle" ] <>
        ~s[class="center-title" font-size="18" fill="#{@text_secondary}" ] <>
        ~s[opacity="0.7">The village awakens for discussion...</text>\n]
    ]
  end

  # -- Voting center: Vote tally with lines --

  defp render_voting_center(ctx) do
    %{
      center_x: cx,
      center_y: cy,
      detail: detail,
      player_ids: player_ids,
      player_count: count,
      rx: orx,
      ry: ory,
      dead_set: dead_set
    } = ctx

    votes = get(detail, :votes, %{})
    vote_summary = to_string(get(detail, :vote_summary, ""))
    highlight_vote = get(detail, :highlight_vote, %{})
    highlight_voter = to_string(get(highlight_vote, :voter, ""))
    highlight_target = to_string(get(highlight_vote, :target, ""))

    if map_size(votes) == 0 do
      [
        ~s[<text x="#{cx}" y="#{cy}" text-anchor="middle" ] <>
          ~s[class="center-title" font-size="22" fill="#{@text_secondary}">] <>
          ~s[Voting begins...</text>\n]
      ]
    else
      # Tally votes (excluding "skip")
      tally =
        votes
        |> Enum.reduce(%{}, fn {_voter, target}, acc ->
          target_str = to_string(target)
          if target_str == "skip", do: acc, else: Map.update(acc, target_str, 1, &(&1 + 1))
        end)

      skip_count =
        votes |> Enum.count(fn {_v, t} -> to_string(t) == "skip" end)

      # Majority threshold
      alive_count = Enum.count(player_ids, fn id -> not MapSet.member?(dead_set, id) end)
      majority = div(alive_count, 2) + 1

      # Draw vote lines from voter to target
      vote_lines =
        votes
        |> Enum.flat_map(fn {voter, target} ->
          voter_str = to_string(voter)
          target_str = to_string(target)

          if target_str == "skip" do
            []
          else
            voter_idx = Enum.find_index(player_ids, fn id -> id == voter_str end)
            target_idx = Enum.find_index(player_ids, fn id -> id == target_str end)

            if voter_idx && target_idx do
              v_angle = voter_idx / max(count, 1) * 2 * :math.pi() - :math.pi() / 2
              t_angle = target_idx / max(count, 1) * 2 * :math.pi() - :math.pi() / 2

              vx = round(cx + orx * :math.cos(v_angle))
              vy = round(cy + ory * :math.sin(v_angle))
              tx = round(cx + orx * :math.cos(t_angle))
              ty = round(cy + ory * :math.sin(t_angle))

              # Shorten the line slightly so it doesn't overlap the avatar
              dx = tx - vx
              dy = ty - vy
              dist = :math.sqrt(dx * dx + dy * dy)
              shorten = min(40, dist * 0.15)
              ratio_start = shorten / max(dist, 1)
              ratio_end = 1.0 - shorten / max(dist, 1)

              sx = round(vx + dx * ratio_start)
              sy = round(vy + dy * ratio_start)
              ex = round(vx + dx * ratio_end)
              ey = round(vy + dy * ratio_end)
              is_highlight = voter_str == highlight_voter and target_str == highlight_target
              stroke_width = if is_highlight, do: "3", else: "1.5"
              opacity = if is_highlight, do: "0.82", else: "0.4"

              [
                ~s[<line x1="#{sx}" y1="#{sy}" x2="#{ex}" y2="#{ey}" ] <>
                  ~s[stroke="#{@role_werewolf}" stroke-width="#{stroke_width}" opacity="#{opacity}" ] <>
                  ~s[marker-end="url(#arrowhead)"/>\n]
              ]
            else
              []
            end
          end
        end)

      # Tally display in center
      sorted_tally =
        tally
        |> Enum.sort_by(fn {_t, c} -> -c end)
        |> Enum.take(6)

      tally_display =
        sorted_tally
        |> Enum.with_index()
        |> Enum.map(fn {{target, vote_count}, idx} ->
          ty = cy - 30 + idx * 28
          bar_w = vote_count * 40
          bar_color = if vote_count >= majority, do: @role_werewolf, else: "#3a6a8e"

          [
            ~s[<rect x="#{cx - 80}" y="#{ty - 12}" width="#{bar_w}" height="18" rx="4" ] <>
              ~s[fill="#{bar_color}" opacity="0.7"/>\n],
            ~s[<text x="#{cx - 90}" y="#{ty + 2}" text-anchor="end" ] <>
              ~s[class="vote-label" font-size="13">#{esc(player_display_name(target, ctx.players))}</text>\n],
            ~s[<text x="#{cx - 80 + bar_w + 8}" y="#{ty + 2}" ] <>
              ~s[class="vote-label" font-size="13" fill="#f1c40f">#{vote_count}</text>\n]
          ]
        end)

      skip_display =
        if skip_count > 0 do
          ty = cy - 30 + length(sorted_tally) * 28

          [
            ~s[<text x="#{cx - 90}" y="#{ty + 2}" text-anchor="end" ] <>
              ~s[class="vote-label" font-size="13" fill="#{@text_secondary}">Skip</text>\n],
            ~s[<text x="#{cx - 80 + 8}" y="#{ty + 2}" ] <>
              ~s[class="vote-label" font-size="13" fill="#{@text_secondary}">#{skip_count}</text>\n]
          ]
        else
          ""
        end

      # Majority line label
      majority_label =
        ~s[<text x="#{cx + 120}" y="#{cy - 50}" text-anchor="middle" ] <>
          ~s[class="label" font-size="11" fill="#{@text_secondary}">Majority: #{majority}</text>\n]

      summary_banner =
        if vote_summary != "" do
          [
            ~s[<rect x="#{cx - 310}" y="#{cy - 168}" width="620" height="40" rx="12" fill="#8c2f39" opacity="0.88"/>\n],
            ~s[<text x="#{cx}" y="#{cy - 141}" text-anchor="middle" class="callout-text">#{esc(vote_summary)}</text>\n]
          ]
        else
          []
        end

      [summary_banner, vote_lines, tally_display, skip_display, majority_label]
    end
  end

  # -- Game Over center: Winner banner --

  defp render_game_over_center(ctx) do
    %{center_x: cx, center_y: cy, winner: winner} = ctx

    winner_str = to_string(winner || "")
    banner_text = String.upcase(winner_str) <> " WIN!"

    banner_color =
      case winner_str do
        "villagers" -> @role_villager
        "werewolves" -> @role_werewolf
        _ -> @text_primary
      end

    bg_color =
      case winner_str do
        "villagers" -> "#1a3a2e"
        "werewolves" -> "#3a1a1e"
        _ -> @card_bg
      end

    banner_w = 500
    banner_h = 80

    [
      # Banner background
      ~s[<rect x="#{cx - div(banner_w, 2)}" y="#{cy - div(banner_h, 2)}" ] <>
        ~s[width="#{banner_w}" height="#{banner_h}" rx="12" ] <>
        ~s[fill="#{bg_color}" stroke="#{banner_color}" stroke-width="3"/>\n],
      # Winner text
      ~s[<text x="#{cx}" y="#{cy + 12}" text-anchor="middle" ] <>
        ~s[class="center-title" font-size="36" fill="#{banner_color}">] <>
        ~s[#{esc(banner_text)}</text>\n],
      # Sub-label
      ~s[<text x="#{cx}" y="#{cy + 60}" text-anchor="middle" ] <>
        ~s[class="label" font-size="14" fill="#{@text_secondary}">] <>
        ~s[All roles revealed</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Footer bar
  # ---------------------------------------------------------------------------

  defp render_footer_bar(ctx) do
    %{w: w, h: h} = ctx
    bar_y = h - @footer_h

    event_text = footer_event_text(ctx)

    [
      ~s[<rect x="0" y="#{bar_y}" width="#{w}" height="#{@footer_h}" fill="#{@footer_bg}"/>\n],
      ~s[<line x1="0" y1="#{bar_y}" x2="#{w}" y2="#{bar_y}" ] <>
        ~s[stroke="#252540" stroke-width="1"/>\n],
      ~s[<text x="#{div(w, 2)}" y="#{bar_y + div(@footer_h, 2) + 6}" text-anchor="middle" ] <>
        ~s[class="footer-text" font-size="18" fill="#{@text_primary}">#{esc(event_text)}</text>\n]
    ]
  end

  defp footer_event_text(ctx) do
    %{
      entry_type: entry_type,
      phase: phase,
      active_player: active,
      detail: detail,
      elimination_log: elim_log,
      winner: winner,
      model: model
    } = ctx

    story_footer = to_string(get(detail, :story_footer, ""))

    if story_footer != "" do
      story_footer
    else
      case entry_type do
        "game_start" ->
          "Game begins with #{ctx.player_count} players"

        "game_over" ->
          winner_str = to_string(winner || "unknown")
          "Game Over - #{String.capitalize(winner_str)} win!"

        "turn_start" ->
          active_str = to_string(active || "?")
          model_short = short_model_name(to_string(model || ""))

          case phase do
            "night" ->
              "#{player_display_name(active_str, ctx.players)} (#{model_short}) acts under cover of night..."

            "day_discussion" ->
              "#{player_display_name(active_str, ctx.players)} (#{model_short}) takes the floor..."

            "day_voting" ->
              "#{player_display_name(active_str, ctx.players)} (#{model_short}) casts their vote..."

            _ ->
              "#{player_display_name(active_str, ctx.players)} (#{model_short}) - #{phase}"
          end

        "turn_result" ->
          # Check for new eliminations
          new_elims = recent_eliminations(elim_log)

          cond do
            new_elims != [] ->
              elim = List.last(new_elims)
              player = to_string(get(elim, :player, "?"))
              role = to_string(get(elim, :role, "?"))
              reason = to_string(get(elim, :reason, "?"))
              reason_text = if reason == "voted", do: "was voted out", else: "was killed"

              "#{player_display_name(player, ctx.players)} #{reason_text}! They were a #{String.capitalize(role)}."

            phase == "day_discussion" ->
              speaker = to_string(get(detail, :speaker, ""))

              if speaker != "",
                do: "#{player_display_name(speaker, ctx.players)} speaks to the village",
                else: "Discussion continues..."

            phase == "day_voting" ->
              votes = get(detail, :votes, %{})
              "#{map_size(votes)} vote(s) cast so far..."

            phase == "night" ->
              "The night progresses..."

            true ->
              ""
          end

        _ ->
          ""
      end
    end
  end

  defp recent_eliminations(log) when is_list(log) and length(log) > 0, do: log
  defp recent_eliminations(_), do: []

  # ---------------------------------------------------------------------------
  # Helpers: text
  # ---------------------------------------------------------------------------

  defp truncate_text(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  defp truncate_text(_, _), do: ""

  defp wrap_text(text, line_len, max_lines) do
    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [current | rest] ->
      if String.length(current) + String.length(word) + 1 <= line_len do
        new = if current == "", do: word, else: current <> " " <> word
        [new | rest]
      else
        [word, current | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(max_lines)
    |> maybe_add_ellipsis(text, line_len, max_lines)
  end

  defp maybe_add_ellipsis(lines, text, line_len, max_lines) do
    estimated_capacity = line_len * max_lines

    if String.length(text) > estimated_capacity and lines != [] do
      List.update_at(lines, -1, fn line ->
        if String.ends_with?(line, "...") do
          line
        else
          String.trim_trailing(line, ".") <> "..."
        end
      end)
    else
      lines
    end
  end

  defp render_recent_statements(x, y, recent, players) do
    recent
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      card_y = y + idx * 108
      speaker = player_display_name(to_string(get(item, :speaker, "?")), players)
      snippet = item |> get(:statement, "") |> to_string() |> truncate_text(110)
      lines = wrap_text(snippet, 34, 4)

      [
        ~s[<rect x="#{x}" y="#{card_y}" width="262" height="88" rx="12" fill="#11253b" opacity="0.92"/>\n],
        ~s[<text x="#{x + 14}" y="#{card_y + 22}" class="sidebar-label" fill="#f1c40f">#{esc(speaker)}</text>\n],
        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, line_idx} ->
          ly = card_y + 42 + line_idx * 16
          ~s[<text x="#{x + 14}" y="#{ly}" class="sidebar-text">#{esc(line)}</text>\n]
        end)
      ]
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers: naming
  # ---------------------------------------------------------------------------

  defp player_display_name(player_id, _players) when is_binary(player_id), do: player_id

  defp player_display_name(other, _players), do: to_string(other)

  defp short_model_name(model_str) when is_binary(model_str) do
    cond do
      String.contains?(model_str, "claude-sonnet-4.6") ->
        "Sonnet 4.6"

      String.contains?(model_str, "claude-sonnet-4") ->
        "Sonnet 4"

      String.contains?(model_str, "claude-opus") ->
        "Opus"

      String.contains?(model_str, "claude-haiku") ->
        "Haiku"

      String.contains?(model_str, "gemini-3-flash") ->
        "Gemini 3 Flash"

      String.contains?(model_str, "gemini-3") ->
        "Gemini 3"

      String.contains?(model_str, "gemini-2") ->
        "Gemini 2"

      String.contains?(model_str, "gpt-5.3-codex-spark") ->
        "Spark"

      String.contains?(model_str, "gpt-5") ->
        "GPT-5"

      String.contains?(model_str, "gpt-4") ->
        "GPT-4"

      String.contains?(model_str, "k2p5") ->
        "Kimi"

      String.contains?(model_str, "kimi") ->
        "Kimi"

      true ->
        # Take the last part after /
        model_str |> String.split("/") |> List.last() |> String.slice(0, 16)
    end
  end

  defp short_model_name(_), do: ""

  # ---------------------------------------------------------------------------
  # Helpers: colors
  # ---------------------------------------------------------------------------

  defp provider_color(model_str) when is_binary(model_str) do
    cond do
      String.contains?(model_str, "claude") or String.contains?(model_str, "anthropic") ->
        @color_anthropic

      String.contains?(model_str, "gemini") or String.contains?(model_str, "google") ->
        @color_google

      String.contains?(model_str, "gpt") or String.contains?(model_str, "openai") or
          String.contains?(model_str, "codex") ->
        @color_openai

      String.contains?(model_str, "kimi") or String.contains?(model_str, "moonshot") or
          String.contains?(model_str, "k2p5") ->
        @color_moonshot

      true ->
        @color_default
    end
  end

  defp provider_color(_), do: @color_default

  defp phase_display("night"), do: "Night"
  defp phase_display("day_discussion"), do: "Discussion"
  defp phase_display("day_voting"), do: "Voting"
  defp phase_display("game_over"), do: "Game Over"
  defp phase_display(other), do: String.capitalize(to_string(other))

  defp phase_color("night"), do: "#7f8cba"
  defp phase_color("day_discussion"), do: "#f1c40f"
  defp phase_color("day_voting"), do: "#e67e22"
  defp phase_color("game_over"), do: @role_werewolf
  defp phase_color(_), do: @text_secondary

  defp role_badge_info("werewolf"), do: {"W", @role_werewolf}
  defp role_badge_info("seer"), do: {"EYE", @role_seer}
  defp role_badge_info("doctor"), do: {"+", @role_doctor}
  defp role_badge_info("villager"), do: {"V", @role_villager}
  defp role_badge_info(_), do: {"?", @color_default}

  defp darken_color(@color_anthropic), do: "#6D3FC4"
  defp darken_color(@color_google), do: "#2A65C4"
  defp darken_color(@color_openai), do: "#0B7A5E"
  defp darken_color(@color_moonshot), do: "#CC5529"
  defp darken_color(_), do: "#555555"

  # ---------------------------------------------------------------------------
  # Helpers: flexible key access
  # ---------------------------------------------------------------------------

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key), default)
      val -> val
    end
  end

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

  defp get(_, _, default), do: default

  # ---------------------------------------------------------------------------
  # Helpers: HTML escaping
  # ---------------------------------------------------------------------------

  defp esc(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp esc(other), do: esc(to_string(other))
end
