defmodule LemonSim.Examples.DungeonCrawl.FrameRenderer do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Color palette (dark theme, dungeon stone tones)
  # ---------------------------------------------------------------------------
  @bg "#0a0a0f"
  @panel_bg "#12141e"
  @panel_border "#1e2030"

  @stone "#8e8e9e"
  @stone_dim "#4a4a5a"
  @torch_orange "#e67e22"
  @torch_dim "#7d4e27"

  @warrior_color "#e74c3c"
  @rogue_color "#9b59b6"
  @mage_color "#3498db"
  @cleric_color "#2ecc71"

  @enemy_color "#e74c3c"
  @boss_color "#ff0040"

  @hp_green "#2ecc71"
  @hp_yellow "#f39c12"
  @hp_red "#e74c3c"

  @text_primary "#ecf0f1"
  @text_secondary "#95a5a6"
  @text_dim "#4a5568"

  @victory_gold "#f1c40f"
  @defeat_red "#c0392b"

  # Layout constants
  @header_h 60
  @footer_h 70
  @party_panel_w 320
  @enemy_panel_w 280

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

    party = get(world, "party", %{})
    turn_order = get(world, "turn_order", Map.keys(party) |> Enum.sort())
    enemies = get(world, "enemies", %{})
    rooms = get(world, "rooms", [])
    current_room_index = get(world, "current_room", 0)
    current_room = Enum.at(rooms, current_room_index, %{})
    round = get(world, "round", 1)
    active_actor = get(world, "active_actor_id", nil)
    status = get(world, "status", "in_progress")
    winner = get(world, "winner", nil)
    inventory = get(world, "inventory", [])
    total_rooms = length(rooms)
    rooms_cleared = Enum.count(rooms, fn r -> get(r, "cleared", false) end)

    ctx = %{
      w: w,
      h: h,
      type: type,
      step: step,
      events: events,
      party: party,
      turn_order: turn_order,
      enemies: enemies,
      rooms: rooms,
      current_room_index: current_room_index,
      current_room: current_room,
      round: round,
      active_actor: active_actor,
      status: status,
      winner: winner,
      inventory: inventory,
      total_rooms: total_rooms,
      rooms_cleared: rooms_cleared
    }

    [
      svg_header(ctx),
      svg_defs(),
      svg_style(),
      render_background(ctx),
      render_header_bar(ctx),
      render_party_panel(ctx),
      render_center_content(ctx),
      render_enemy_panel(ctx),
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
      <filter id="torch-glow">
        <feGaussianBlur stdDeviation="6" result="blur"/>
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
      .adventurer-name { font-family: sans-serif; font-weight: 600; }
      .enemy-name { font-family: sans-serif; font-weight: 600; }
      .class-badge { font-family: sans-serif; font-weight: 700; font-size: 10px; }
      .stat-text { font-family: sans-serif; }
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
    room_text =
      if type == "game_over" do
        case ctx.winner do
          "party" -> "DUNGEON CLEARED!"
          _ -> "PARTY DEFEATED"
        end
      else
        room = Enum.at(ctx.rooms, ctx.current_room_index, %{})
        room_name = get(room, "name", "Room #{ctx.current_room_index + 1}")
        "Room #{ctx.current_room_index + 1}/#{ctx.total_rooms}: #{room_name}"
      end

    progress_text = "#{ctx.rooms_cleared}/#{ctx.total_rooms} cleared"

    [
      ~s[<rect x="0" y="0" width="#{w}" height="#{@header_h}" fill="#{@panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{@header_h}" x2="#{w}" y2="#{@header_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      # Torch decorations
      ~s[<circle cx="16" cy="#{div(@header_h, 2)}" r="6" fill="#{@torch_orange}" opacity="0.8" filter="url(#torch-glow)"/>\n],
      ~s[<circle cx="#{w - 16}" cy="#{div(@header_h, 2)}" r="6" fill="#{@torch_orange}" opacity="0.8" filter="url(#torch-glow)"/>\n],
      # Title
      ~s[<text x="40" y="38" class="header-text title" font-size="20" fill="#{@torch_orange}">DUNGEON CRAWL</text>\n],
      # Room info
      ~s[<text x="#{div(w, 2)}" y="38" class="header-text title" font-size="18" ] <>
        ~s[text-anchor="middle" fill="#{@text_primary}">#{esc(room_text)}</text>\n],
      # Round and progress
      ~s[<text x="#{w - 40}" y="28" class="header-text" font-size="12" ] <>
        ~s[text-anchor="end" fill="#{@stone}">Round #{ctx.round}</text>\n],
      ~s[<text x="#{w - 40}" y="46" class="header-text" font-size="11" ] <>
        ~s[text-anchor="end" fill="#{@stone_dim}">#{progress_text}</text>\n],
      # Step
      ~s[<text x="#{w - 40}" y="12" class="header-text" font-size="9" ] <>
        ~s[text-anchor="end" fill="#{@text_dim}">Step #{ctx.step}</text>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Party panel (left)
  # ---------------------------------------------------------------------------

  defp render_party_panel(%{h: h, turn_order: turn_order, party: party} = ctx) do
    panel_h = h - @header_h - @footer_h

    member_cards =
      turn_order
      |> Enum.with_index()
      |> Enum.map(fn {actor_id, idx} ->
        adventurer = Map.get(party, actor_id, %{})
        render_adventurer_card(actor_id, adventurer, idx, ctx)
      end)

    [
      ~s[<rect x="0" y="#{@header_h}" width="#{@party_panel_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{@party_panel_w}" y1="#{@header_h}" x2="#{@party_panel_w}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="0" y="#{@header_h}" width="#{@party_panel_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{div(@party_panel_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@torch_dim}">PARTY</text>\n],
      member_cards
    ]
  end

  defp render_adventurer_card(actor_id, adventurer, idx, ctx) do
    y = @header_h + 36 + idx * 240
    hp = get(adventurer, "hp", 0)
    max_hp = get(adventurer, "max_hp", hp)
    ap = get(adventurer, "ap", 0)
    max_ap = get(adventurer, "max_ap", 2)
    class = get(adventurer, "class", "?")
    char_name = get(adventurer, "name", actor_id)
    is_active = ctx.active_actor == actor_id
    is_dead = hp <= 0

    class_color = class_color(class)
    opacity = if is_dead, do: "0.3", else: "1"

    # HP bar
    hp_pct = if max_hp > 0, do: hp / max_hp, else: 0
    hp_bar_w = @party_panel_w - 40
    hp_fill_w = round(hp_bar_w * hp_pct)

    hp_color =
      cond do
        hp_pct > 0.5 -> @hp_green
        hp_pct > 0.25 -> @hp_yellow
        true -> @hp_red
      end

    # AP dots
    ap_dots = render_ap_dots(ap, max_ap, 16, y + 86)

    # Active highlight
    highlight =
      if is_active and not is_dead do
        ~s[<rect x="4" y="#{y - 4}" width="#{@party_panel_w - 8}" height="235" ] <>
          ~s[fill="#{class_color}" opacity="0.06" rx="6"/>\n] <>
          ~s[<rect x="4" y="#{y - 4}" width="#{@party_panel_w - 8}" height="235" ] <>
          ~s[fill="none" stroke="#{class_color}" stroke-width="1.5" rx="6" opacity="0.5"/>\n]
      else
        ""
      end

    # Class badge
    class_short = String.upcase(String.slice(class, 0, 3))

    # Abilities
    abilities = get(adventurer, "abilities", [])
    ability_text = Enum.join(abilities, " · ")

    [
      highlight,
      ~s[<g opacity="#{opacity}">\n],
      # Class badge circle
      ~s[<circle cx="22" cy="#{y + 10}" r="10" fill="#{class_color}" opacity="0.2"/>\n],
      ~s[<text x="22" y="#{y + 14}" text-anchor="middle" class="class-badge" fill="#{class_color}">#{class_short}</text>\n],
      # Name
      ~s[<text x="40" y="#{y + 14}" class="adventurer-name" font-size="15" fill="#{@text_primary}">#{esc(char_name)}</text>\n],
      if is_active and not is_dead do
        ~s[<text x="#{@party_panel_w - 16}" y="#{y + 14}" text-anchor="end" font-size="10" font-weight="700" fill="#{class_color}" filter="url(#glow)">ACTIVE</text>\n]
      else
        ""
      end,
      if is_dead do
        ~s[<text x="#{@party_panel_w - 16}" y="#{y + 14}" text-anchor="end" font-size="11" font-weight="700" fill="#{@hp_red}">DOWNED</text>\n]
      else
        ""
      end,
      # HP bar
      ~s[<text x="16" y="#{y + 38}" font-size="10" fill="#{@text_secondary}">HP</text>\n],
      ~s[<text x="#{@party_panel_w - 16}" y="#{y + 38}" text-anchor="end" font-size="10" fill="#{hp_color}">#{hp}/#{max_hp}</text>\n],
      ~s[<rect x="16" y="#{y + 44}" width="#{hp_bar_w}" height="10" fill="#{@panel_bg}" rx="4"/>\n],
      ~s[<rect x="16" y="#{y + 44}" width="#{max(hp_fill_w, 0)}" height="10" fill="#{hp_color}" rx="4" opacity="0.85"/>\n],
      # AP
      ~s[<text x="16" y="#{y + 78}" font-size="10" fill="#{@text_secondary}">AP</text>\n],
      ap_dots,
      # Abilities
      ~s[<text x="16" y="#{y + 108}" font-size="9" fill="#{@text_dim}">#{esc(ability_text)}</text>\n],
      ~s[</g>\n]
    ]
  end

  defp render_ap_dots(current_ap, max_ap, x_start, y) do
    Enum.map(0..(max_ap - 1), fn i ->
      cx = x_start + i * 20
      filled = i < current_ap
      fill = if filled, do: @torch_orange, else: @panel_border
      opacity = if filled, do: "0.9", else: "0.4"

      ~s[<circle cx="#{cx}" cy="#{y}" r="7" fill="#{fill}" opacity="#{opacity}"/>\n]
    end)
  end

  # ---------------------------------------------------------------------------
  # Enemy panel (right)
  # ---------------------------------------------------------------------------

  defp render_enemy_panel(%{w: w, h: h, enemies: enemies} = _ctx) do
    panel_x = w - @enemy_panel_w
    panel_h = h - @header_h - @footer_h

    living_enemies =
      enemies
      |> Enum.sort_by(fn {id, _} -> id end)

    enemy_cards =
      living_enemies
      |> Enum.with_index()
      |> Enum.map(fn {{enemy_id, enemy}, idx} ->
        ey = @header_h + 40 + idx * 100
        render_enemy_card(enemy_id, enemy, ey, panel_x)
      end)

    [
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@enemy_panel_w}" height="#{panel_h}" fill="#{@bg}" opacity="0.95"/>\n],
      ~s[<line x1="#{panel_x}" y1="#{@header_h}" x2="#{panel_x}" y2="#{@header_h + panel_h}" stroke="#{@panel_border}" stroke-width="1"/>\n],
      ~s[<rect x="#{panel_x}" y="#{@header_h}" width="#{@enemy_panel_w}" height="28" fill="#{@panel_bg}" opacity="0.6"/>\n],
      ~s[<text x="#{panel_x + div(@enemy_panel_w, 2)}" y="#{@header_h + 19}" text-anchor="middle" ] <>
        ~s[class="header-text" font-size="12" letter-spacing="2" fill="#{@stone_dim}">ENEMIES</text>\n],
      enemy_cards,
      if enemies == %{} do
        ~s[<text x="#{panel_x + div(@enemy_panel_w, 2)}" y="#{@header_h + 60}" text-anchor="middle" ] <>
          ~s[font-size="11" fill="#{@text_dim}">Room cleared!</text>\n]
      else
        ""
      end
    ]
  end

  defp render_enemy_card(enemy_id, enemy, y, panel_x) do
    hp = get(enemy, "hp", 0)
    max_hp = get(enemy, "max_hp", hp)
    enemy_type = get(enemy, "type", enemy_id)
    enemy_status = get(enemy, "status", "alive")
    is_dead = hp <= 0 or enemy_status == "dead"

    is_boss =
      String.contains?(to_string(enemy_type), "boss") or
        String.contains?(to_string(enemy_id), "boss")

    hp_pct = if max_hp > 0, do: hp / max_hp, else: 0
    hp_bar_w = @enemy_panel_w - 32
    hp_fill_w = round(hp_bar_w * hp_pct)

    hp_color =
      cond do
        hp_pct > 0.5 -> @hp_green
        hp_pct > 0.25 -> @hp_yellow
        true -> @hp_red
      end

    name_color = if is_boss, do: @boss_color, else: @enemy_color
    opacity = if is_dead, do: "0.25", else: "1"

    [
      ~s[<g opacity="#{opacity}">\n],
      if is_boss do
        ~s[<rect x="#{panel_x + 8}" y="#{y - 6}" width="#{@enemy_panel_w - 16}" height="92" ] <>
          ~s[fill="#{@boss_color}" opacity="0.04" rx="5"/>\n] <>
          ~s[<rect x="#{panel_x + 8}" y="#{y - 6}" width="#{@enemy_panel_w - 16}" height="92" ] <>
          ~s[fill="none" stroke="#{@boss_color}" stroke-width="1" rx="5" opacity="0.3"/>\n]
      else
        ""
      end,
      ~s[<text x="#{panel_x + 16}" y="#{y + 12}" class="enemy-name" font-size="14" fill="#{name_color}">#{esc(format_entity_name(enemy_type))}</text>\n],
      if is_dead do
        ~s[<text x="#{panel_x + @enemy_panel_w - 16}" y="#{y + 12}" text-anchor="end" font-size="10" fill="#{@text_dim}">DEAD</text>\n]
      else
        ""
      end,
      ~s[<text x="#{panel_x + 16}" y="#{y + 30}" font-size="10" fill="#{@text_secondary}">HP</text>\n],
      ~s[<text x="#{panel_x + @enemy_panel_w - 16}" y="#{y + 30}" text-anchor="end" font-size="10" fill="#{hp_color}">#{hp}/#{max_hp}</text>\n],
      ~s[<rect x="#{panel_x + 16}" y="#{y + 36}" width="#{hp_bar_w}" height="8" fill="#{@panel_bg}" rx="3"/>\n],
      ~s[<rect x="#{panel_x + 16}" y="#{y + 36}" width="#{max(hp_fill_w, 0)}" height="8" fill="#{hp_color}" rx="3" opacity="0.8"/>\n],
      ~s[<text x="#{panel_x + 16}" y="#{y + 60}" font-size="9" fill="#{@text_dim}">ATK: #{get(enemy, "attack", "?")} · ID: #{esc(enemy_id)}</text>\n],
      ~s[</g>\n]
    ]
  end

  # ---------------------------------------------------------------------------
  # Center content
  # ---------------------------------------------------------------------------

  defp render_center_content(ctx) do
    case ctx.type do
      "init" -> render_init_card(ctx)
      "game_over" -> render_game_over_card(ctx)
      _ -> render_dungeon_content(ctx)
    end
  end

  defp render_init_card(%{w: w, h: h} = ctx) do
    cx = @party_panel_w + div(w - @party_panel_w - @enemy_panel_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    party_count = length(ctx.turn_order)
    room_count = ctx.total_rooms

    [
      ~s[<rect x="#{cx - 260}" y="#{cy - 150}" width="520" height="300" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@torch_orange}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 90}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{@torch_orange}">DUNGEON CRAWL</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 60}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">Cooperative Adventure</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 20}" text-anchor="middle" font-size="16" ] <>
        ~s[fill="#{@text_primary}">#{party_count} Adventurers &#xB7; #{room_count} Rooms</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 10}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Classes: Warrior, Rogue, Mage, Cleric</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 40}" text-anchor="middle" font-size="13" ] <>
        ~s[fill="#{@text_secondary}">Survive all rooms to win!</text>\n],
      ~s[<line x1="#{cx - 130}" y1="#{cy + 65}" x2="#{cx + 130}" y2="#{cy + 65}" ] <>
        ~s[stroke="#{@stone_dim}" stroke-width="1"/>\n],
      ~s[<text x="#{cx}" y="#{cy + 86}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Warrior &#xB7; Rogue &#xB7; Mage &#xB7; Cleric</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 106}" text-anchor="middle" font-size="11" ] <>
        ~s[fill="#{@text_dim}">Traps &#xB7; Treasure &#xB7; Boss Room</text>\n]
    ]
  end

  defp render_game_over_card(%{w: w, h: h} = ctx) do
    cx = @party_panel_w + div(w - @party_panel_w - @enemy_panel_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    is_victory = ctx.winner == "party"
    title = if is_victory, do: "DUNGEON CLEARED!", else: "PARTY DEFEATED"
    title_color = if is_victory, do: @victory_gold, else: @defeat_red
    subtitle = if is_victory, do: "The party triumphs!", else: "The darkness claims you..."

    # Show party final status
    party_summary =
      ctx.turn_order
      |> Enum.with_index()
      |> Enum.map(fn {actor_id, idx} ->
        adventurer = Map.get(ctx.party, actor_id, %{})
        hp = get(adventurer, "hp", 0)
        max_hp = get(adventurer, "max_hp", 1)
        char_name = get(adventurer, "name", actor_id)
        class = get(adventurer, "class", "?")
        sy = cy - 60 + 50 + idx * 46
        alive = hp > 0
        color = if alive, do: class_color(class), else: @text_dim
        status_text = if alive, do: "#{hp}/#{max_hp} HP", else: "Downed"

        [
          ~s[<text x="#{cx - 140}" y="#{sy}" font-size="14" fill="#{color}">#{esc(char_name)} (#{class})</text>\n],
          ~s[<text x="#{cx + 140}" y="#{sy}" text-anchor="end" font-size="13" fill="#{color}">#{status_text}</text>\n]
        ]
      end)

    card_h = 120 + length(ctx.turn_order) * 46

    [
      ~s[<rect x="#{cx - 280}" y="#{cy - div(card_h, 2)}" width="560" height="#{card_h}" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{title_color}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 44}" text-anchor="middle" class="title" ] <>
        ~s[font-size="30" fill="#{title_color}" filter="url(#glow)">#{esc(title)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy - div(card_h, 2) + 70}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@text_secondary}">#{esc(subtitle)}</text>\n],
      ~s[<line x1="#{cx - 200}" y1="#{cy - div(card_h, 2) + 80}" x2="#{cx + 200}" y2="#{cy - div(card_h, 2) + 80}" ] <>
        ~s[stroke="#{@panel_border}" stroke-width="1"/>\n],
      party_summary
    ]
  end

  defp render_dungeon_content(ctx) do
    events = ctx.events

    cond do
      has_event?(events, "room_cleared") ->
        render_room_cleared_card(ctx)

      has_event?(events, "room_entered") ->
        render_room_entered_card(ctx)

      has_event?(events, "enemy_killed") ->
        render_combat_action_card(ctx, "enemy_killed")

      has_event?(events, "adventurer_downed") ->
        render_combat_action_card(ctx, "adventurer_downed")

      true ->
        render_combat_state(ctx)
    end
  end

  defp render_room_cleared_card(%{w: w, h: h} = ctx) do
    cx = @party_panel_w + div(w - @party_panel_w - @enemy_panel_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    room_name = get(ctx.current_room, "name", "Room #{ctx.current_room_index + 1}")
    treasure = get(ctx.current_room, "treasure", [])
    treasure_text = if treasure == [], do: "No treasure", else: "#{length(treasure)} items found!"

    [
      ~s[<rect x="#{cx - 220}" y="#{cy - 110}" width="440" height="220" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@victory_gold}" stroke-width="3" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 50}" text-anchor="middle" class="title" ] <>
        ~s[font-size="36" fill="#{@victory_gold}" filter="url(#glow)">ROOM CLEARED!</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 15}" text-anchor="middle" font-size="18" ] <>
        ~s[fill="#{@text_primary}">#{esc(room_name)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 20}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@torch_orange}">#{esc(treasure_text)}</text>\n],
      if ctx.rooms_cleared < ctx.total_rooms do
        ~s[<text x="#{cx}" y="#{cy + 56}" text-anchor="middle" font-size="13" ] <>
          ~s[fill="#{@text_secondary}">Proceeding to next room...</text>\n]
      else
        ~s[<text x="#{cx}" y="#{cy + 56}" text-anchor="middle" font-size="14" ] <>
          ~s[fill="#{@victory_gold}">All rooms cleared!</text>\n]
      end
    ]
  end

  defp render_room_entered_card(%{w: w, h: h} = ctx) do
    cx = @party_panel_w + div(w - @party_panel_w - @enemy_panel_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    room = Enum.at(ctx.rooms, ctx.current_room_index, %{})
    room_name = get(room, "name", "Room #{ctx.current_room_index + 1}")

    enemy_count =
      ctx.enemies |> Map.values() |> Enum.count(fn e -> get(e, "status", "alive") == "alive" end)

    traps = get(room, "traps", [])
    active_traps = Enum.count(traps, fn t -> not get(t, "disarmed", false) end)

    [
      ~s[<rect x="#{cx - 220}" y="#{cy - 100}" width="440" height="200" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{@stone}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 40}" text-anchor="middle" class="title" ] <>
        ~s[font-size="28" fill="#{@stone}">ENTERING ROOM</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 5}" text-anchor="middle" font-size="22" ] <>
        ~s[fill="#{@text_primary}">#{esc(room_name)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 30}" text-anchor="middle" font-size="14" ] <>
        ~s[fill="#{@enemy_color}">#{enemy_count} enemies</text>\n],
      if active_traps > 0 do
        ~s[<text x="#{cx}" y="#{cy + 56}" text-anchor="middle" font-size="13" ] <>
          ~s[fill="#{@hp_yellow}">&#x26A0; #{active_traps} trap(s) detected!</text>\n]
      else
        ~s[<text x="#{cx}" y="#{cy + 56}" text-anchor="middle" font-size="13" ] <>
          ~s[fill="#{@text_dim}">No traps detected</text>\n]
      end
    ]
  end

  defp render_combat_action_card(%{w: w, h: h} = ctx, event_kind) do
    cx = @party_panel_w + div(w - @party_panel_w - @enemy_panel_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    ev = find_event(ctx.events, event_kind)
    payload = get(ev, "payload", ev || %{})

    {title, subtitle, color} =
      case event_kind do
        "enemy_killed" ->
          enemy_id = get(payload, "enemy_id", "?")
          {"ENEMY SLAIN!", esc(format_entity_name(enemy_id)), @hp_green}

        "adventurer_downed" ->
          actor_id = get(payload, "actor_id", "?")
          adventurer = Map.get(ctx.party, actor_id, %{})
          char_name = get(adventurer, "name", actor_id)
          {"ADVENTURER DOWN!", esc(char_name), @defeat_red}
      end

    [
      ~s[<rect x="#{cx - 200}" y="#{cy - 90}" width="400" height="180" ] <>
        ~s[fill="#{@panel_bg}" rx="12" stroke="#{color}" stroke-width="2" opacity="0.95"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 30}" text-anchor="middle" class="title" ] <>
        ~s[font-size="32" fill="#{color}" filter="url(#glow)">#{title}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 10}" text-anchor="middle" font-size="20" ] <>
        ~s[fill="#{@text_primary}">#{subtitle}</text>\n],
      render_mini_combat_log(ctx, cx, cy + 50)
    ]
  end

  defp render_combat_state(%{w: w, h: h} = ctx) do
    cx = @party_panel_w + div(w - @party_panel_w - @enemy_panel_w, 2)
    cy = @header_h + div(h - @header_h - @footer_h, 2)

    active_id = ctx.active_actor
    adventurer = Map.get(ctx.party, active_id, %{})
    char_name = get(adventurer, "name", active_id || "?")
    class = get(adventurer, "class", "?")
    class_color = class_color(class)

    living_enemies =
      ctx.enemies |> Enum.filter(fn {_, e} -> get(e, "status", "alive") == "alive" end)

    enemy_count = length(living_enemies)

    room = Enum.at(ctx.rooms, ctx.current_room_index, %{})
    room_name = get(room, "name", "Room #{ctx.current_room_index + 1}")

    [
      # Room map card
      ~s[<rect x="#{cx - 220}" y="#{cy - 180}" width="440" height="100" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{@panel_border}" stroke-width="1" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 148}" text-anchor="middle" font-size="12" fill="#{@stone_dim}">CURRENT ROOM</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 118}" text-anchor="middle" class="title" font-size="20" fill="#{@stone}">#{esc(room_name)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 98}" text-anchor="middle" font-size="12" fill="#{@enemy_color}">#{enemy_count} enemies remaining</text>\n],
      # Active actor card
      ~s[<rect x="#{cx - 200}" y="#{cy - 64}" width="400" height="90" ] <>
        ~s[fill="#{@panel_bg}" rx="8" stroke="#{class_color}" stroke-width="1.5" opacity="0.9"/>\n],
      ~s[<text x="#{cx}" y="#{cy - 36}" text-anchor="middle" font-size="11" fill="#{@text_dim}">ACTING</text>\n],
      ~s[<text x="#{cx}" y="#{cy - 10}" text-anchor="middle" class="adventurer-name" font-size="22" fill="#{class_color}">#{esc(char_name)}</text>\n],
      ~s[<text x="#{cx}" y="#{cy + 14}" text-anchor="middle" font-size="13" fill="#{@text_secondary}">#{String.capitalize(class)}</text>\n],
      # Inventory bar
      render_inventory_bar(ctx.inventory, cx, cy + 60),
      # Combat log
      render_mini_combat_log(ctx, cx, cy + 100)
    ]
  end

  defp render_mini_combat_log(%{events: events}, cx, y) do
    significant_events =
      events
      |> Enum.filter(fn ev ->
        kind = get(ev, "kind", "")

        kind in [
          "attack_resolved",
          "damage_applied",
          "heal_applied",
          "enemy_killed",
          "adventurer_downed",
          "trap_triggered",
          "trap_disarmed",
          "fireball_resolved",
          "backstab_resolved",
          "buff_applied",
          "item_used"
        ]
      end)
      |> Enum.take(4)

    if significant_events == [] do
      ""
    else
      event_lines =
        significant_events
        |> Enum.with_index()
        |> Enum.map(fn {ev, idx} ->
          ey = y + 16 + idx * 18
          text = format_event_text(ev)

          ~s[<text x="#{cx}" y="#{ey}" text-anchor="middle" font-size="11" fill="#{@text_secondary}">#{esc(text)}</text>\n]
        end)

      [
        ~s[<text x="#{cx}" y="#{y}" text-anchor="middle" font-size="10" fill="#{@text_dim}">Combat log</text>\n],
        event_lines
      ]
    end
  end

  defp render_inventory_bar(inventory, cx, y) do
    if inventory == [] do
      ~s[<text x="#{cx}" y="#{y}" text-anchor="middle" font-size="10" fill="#{@text_dim}">No items in inventory</text>\n]
    else
      item_texts =
        inventory |> Enum.map(fn item -> get(item, "name", "?") end) |> Enum.join(" · ")

      [
        ~s[<text x="#{cx}" y="#{y - 4}" text-anchor="middle" font-size="10" fill="#{@text_dim}">Inventory</text>\n],
        ~s[<text x="#{cx}" y="#{y + 14}" text-anchor="middle" font-size="11" fill="#{@torch_dim}">#{esc(item_texts)}</text>\n]
      ]
    end
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
        "The party enters the dungeon — #{length(ctx.turn_order)} adventurers, #{ctx.total_rooms} rooms to clear"

      ctx.type == "game_over" ->
        if ctx.winner == "party" do
          "The dungeon has been cleared! The party triumphs!"
        else
          "The party has been wiped out. Darkness falls..."
        end

      has_event?(events, "room_cleared") ->
        room_name = get(ctx.current_room, "name", "Room #{ctx.current_room_index + 1}")
        "#{room_name} cleared!"

      has_event?(events, "room_entered") ->
        room = Enum.at(ctx.rooms, ctx.current_room_index, %{})
        room_name = get(room, "name", "Room #{ctx.current_room_index + 1}")
        "Entering #{room_name}..."

      has_event?(events, "enemy_killed") ->
        ev = find_event(events, "enemy_killed")
        p = get(ev, "payload", ev || %{})
        "#{format_entity_name(get(p, "enemy_id", "?"))} has been slain!"

      has_event?(events, "adventurer_downed") ->
        ev = find_event(events, "adventurer_downed")
        p = get(ev, "payload", ev || %{})
        actor_id = get(p, "actor_id", "?")
        adventurer = Map.get(ctx.party, actor_id, %{})
        char_name = get(adventurer, "name", actor_id)
        "#{char_name} has been downed!"

      has_event?(events, "heal_applied") ->
        ev = find_event(events, "heal_applied")
        p = get(ev, "payload", ev || %{})
        target_id = get(p, "target_id", "?")
        amount = get(p, "amount", 0)
        adventurer = Map.get(ctx.party, target_id, %{})
        char_name = get(adventurer, "name", target_id)
        "#{char_name} healed for #{amount} HP"

      has_event?(events, "attack_resolved") ->
        ev = find_event(events, "attack_resolved")
        p = get(ev, "payload", ev || %{})
        attacker_id = get(p, "attacker_id", "?")
        damage = get(p, "damage", 0)
        adventurer = Map.get(ctx.party, attacker_id, %{})
        char_name = get(adventurer, "name", attacker_id)
        "#{char_name} attacks for #{damage} damage"

      has_event?(events, "fireball_resolved") ->
        ev = find_event(events, "fireball_resolved")
        p = get(ev, "payload", ev || %{})
        hits = get(p, "enemies_hit", 0)
        "Fireball hits #{hits} enemies!"

      has_event?(events, "trap_triggered") ->
        ev = find_event(events, "trap_triggered")
        p = get(ev, "payload", ev || %{})
        "#{get(p, "trap_type", "Trap")} triggered — #{get(p, "damage", 0)} damage!"

      has_event?(events, "trap_disarmed") ->
        ev = find_event(events, "trap_disarmed")
        p = get(ev, "payload", ev || %{})

        "#{format_entity_name(get(p, "actor_id", "?"))} disarms the #{get(p, "trap_type", "trap")}!"

      has_event?(events, "round_advanced") ->
        ev = find_event(events, "round_advanced")
        p = get(ev, "payload", ev || %{})
        "Round #{get(p, "round", "?")} begins"

      has_event?(events, "turn_ended") ->
        ev = find_event(events, "turn_ended")
        p = get(ev, "payload", ev || %{})
        next = get(p, "next_actor_id", "?")
        adventurer = Map.get(ctx.party, next, %{})
        char_name = get(adventurer, "name", next)
        "#{char_name}'s turn"

      true ->
        active_id = ctx.active_actor

        if active_id do
          adventurer = Map.get(ctx.party, active_id, %{})
          char_name = get(adventurer, "name", active_id)
          "#{char_name} is deciding..."
        else
          ""
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp class_color("warrior"), do: @warrior_color
  defp class_color("rogue"), do: @rogue_color
  defp class_color("mage"), do: @mage_color
  defp class_color("cleric"), do: @cleric_color
  defp class_color(_), do: @text_secondary

  defp format_entity_name(nil), do: "?"

  defp format_entity_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_entity_name(other), do: to_string(other)

  defp format_event_text(ev) do
    kind = get(ev, "kind", "?")
    p = get(ev, "payload", %{})

    case kind do
      "attack_resolved" ->
        dmg = get(p, "damage", 0)
        target = format_entity_name(get(p, "target_id", "?"))
        "#{target} takes #{dmg} damage"

      "damage_applied" ->
        dmg = get(p, "damage", 0)
        target = format_entity_name(get(p, "target_id", "?"))
        "#{target} takes #{dmg} damage (#{get(p, "remaining_hp", 0)} HP left)"

      "heal_applied" ->
        amt = get(p, "amount", 0)
        target = format_entity_name(get(p, "target_id", "?"))
        "#{target} healed +#{amt} HP"

      "enemy_killed" ->
        "#{format_entity_name(get(p, "enemy_id", "?"))} slain!"

      "adventurer_downed" ->
        "#{format_entity_name(get(p, "actor_id", "?"))} downed!"

      "fireball_resolved" ->
        "Fireball hits #{get(p, "enemies_hit", 0)} enemies"

      "backstab_resolved" ->
        dmg = get(p, "damage", 0)
        target = format_entity_name(get(p, "target_id", "?"))
        "Backstab: #{target} takes #{dmg}"

      "buff_applied" ->
        buff = get(p, "buff", "?")
        target = format_entity_name(get(p, "target_id", "?"))
        "#{target} buffed: #{buff}"

      "trap_triggered" ->
        "Trap: #{get(p, "trap_type", "?")} — #{get(p, "damage", 0)} dmg"

      "trap_disarmed" ->
        "#{format_entity_name(get(p, "actor_id", "?"))} disarms trap"

      "item_used" ->
        item = get(p, "item", "?")
        actor = format_entity_name(get(p, "actor_id", "?"))
        "#{actor} uses #{item}"

      _ ->
        kind
    end
  end

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
