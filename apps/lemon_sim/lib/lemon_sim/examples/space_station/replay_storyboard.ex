defmodule LemonSim.Examples.SpaceStation.ReplayStoryboard do
  @moduledoc """
  Condenses raw Space Station transcript entries into viewer-friendly replay beats.

  The raw log is useful for debugging but too granular for a watchable replay.
  This module condenses the transcript into phase cards, readable discussion
  moments, action reveals, vote beats, ejection reveals, crisis events,
  system health milestones, and a final result card.
  """

  @default_fps 2
  @default_hold_frames 1

  @type beat :: %{entry: map(), hold_frames: pos_integer()}

  @spec build([map()], keyword()) :: [beat()]
  def build(entries, opts \\ []) do
    players = extract_players_info(entries)
    player_count = map_size(players)
    systems = extract_systems_info(entries)

    state = %{
      beats: [],
      prev_phase: nil,
      prev_round: nil,
      discussion_context: [],
      last_votes: %{},
      last_action_log: %{},
      last_elimination_log: [],
      alerted_critical: MapSet.new(),
      alerted_destroyed: MapSet.new(),
      fps: Keyword.get(opts, :fps, @default_fps),
      hold_multiplier: max(1, Keyword.get(opts, :hold_frames, @default_hold_frames)),
      player_count: player_count,
      players: players,
      systems: systems
    }

    entries
    |> Enum.reduce(state, &consume_entry/2)
    |> Map.fetch!(:beats)
    |> Enum.reverse()
  end

  defp consume_entry(entry, state) do
    case get(entry, :type, "") do
      "game_start" ->
        entry
        |> with_story_card(
          "Space Station",
          "The crew must keep the station alive. One among them is a saboteur.",
          intro_lines(state.players, state.systems),
          "The mission begins."
        )
        |> add_beat(state, seconds_to_frames(4.5, state))
        |> Map.put(:prev_phase, phase_of(entry))
        |> Map.put(:prev_round, round_of(entry))

      "turn_result" ->
        consume_turn_result(entry, state)

      "game_over" ->
        consume_game_over(entry, state)

      _ ->
        state
    end
  end

  defp consume_turn_result(entry, state) do
    phase = phase_of(entry)
    round = round_of(entry)
    detail = get(entry, :detail, %{})
    elimination_log = get(entry, :elimination_log, state.last_elimination_log)
    action_log = resolve_action_log(detail, state.last_action_log)
    votes = resolve_votes(detail, state.last_votes)

    # Reset discussion context on phase change away from discussion
    discussion_context =
      if state.prev_phase == "discussion" and phase != "discussion" do
        []
      else
        state.discussion_context
      end

    state = %{state | discussion_context: discussion_context}

    # Detect system health changes for milestone alerts
    system_health = get(detail, :system_health, nil)

    state =
      state
      |> maybe_add_round_card(entry, round)
      |> maybe_add_phase_card(entry, phase)
      |> maybe_add_crisis_beat(entry)
      |> maybe_add_scene_beat(entry, phase, detail, votes, action_log)
      |> maybe_add_ejection_beat(entry, elimination_log)
      |> maybe_add_system_milestone(entry, system_health)

    %{
      state
      | prev_phase: phase,
        prev_round: round,
        last_elimination_log: elimination_log,
        last_action_log: next_action_log(state, phase, action_log),
        last_votes: next_votes(state, phase, votes)
    }
  end

  defp consume_game_over(entry, state) do
    winner = get(entry, :winner, "unknown")
    players_info = get(entry, :players, state.players)

    {title, summary} =
      case winner do
        "crew" ->
          {"Crew Wins!", "The station is saved. The crew held the line."}

        "saboteur" ->
          {"Saboteur Wins!", "The station has fallen. The saboteur prevails."}

        _ ->
          {"Game Over", "The mission has ended."}
      end

    # Build final system health lines
    system_lines =
      state.systems
      |> Enum.sort_by(fn {id, _s} -> id end)
      |> Enum.map(fn {id, s} ->
        name = get(s, :name, id)
        "#{name}: #{get(s, :health, "?")} HP"
      end)
      |> Enum.take(4)

    # Build role reveal lines
    role_lines =
      players_info
      |> Enum.sort_by(fn {id, _p} -> id end)
      |> Enum.map(fn {id, p} ->
        role = get(p, :role, "unknown") |> to_string() |> String.capitalize()
        status = get(p, :status, "alive") |> to_string()
        suffix = if status == "ejected", do: " (ejected)", else: ""
        "#{id}: #{role}#{suffix}"
      end)
      |> Enum.take(4)

    lines = (system_lines ++ role_lines) |> Enum.take(4)

    entry
    |> with_story_card(title, summary, lines, summary)
    |> add_beat(state, seconds_to_frames(5.0, state))
  end

  # -- Round card --

  defp maybe_add_round_card(state, entry, round) do
    if round != state.prev_round and round != nil do
      entry
      |> synthetic_entry("turn_result", phase_of(entry), round)
      |> with_story_card(
        "Round #{round}",
        "A new round begins aboard the station.",
        ["Each crew member takes an action. The saboteur moves in secret."],
        "Round #{round} begins."
      )
      |> add_beat(state, seconds_to_frames(2.5, state))
    else
      state
    end
  end

  # -- Phase card --

  defp maybe_add_phase_card(state, entry, phase) do
    if phase == state.prev_phase do
      state
    else
      case phase_card(entry, phase, state) do
        nil -> state
        {card_entry, seconds} -> add_beat(card_entry, state, seconds_to_frames(seconds, state))
      end
    end
  end

  defp phase_card(entry, "action", _state) do
    round = round_of(entry)

    entry
    |> synthetic_entry("turn_result", "action", round)
    |> with_story_card(
      "Action Phase",
      "Crew members disperse across the station to work on systems.",
      ["Repairs, scans, and sabotage all happen now."],
      "Action phase begins."
    )
    |> then(&{&1, 2.5})
  end

  defp phase_card(entry, "report", _state) do
    round = round_of(entry)

    entry
    |> synthetic_entry("turn_result", "report", round)
    |> with_story_card(
      "Report Phase",
      "Actions resolved. Reviewing system status.",
      ["System health updates are now visible to all crew."],
      "Report phase."
    )
    |> then(&{&1, 2.0})
  end

  defp phase_card(entry, "discussion", _state) do
    round = round_of(entry)

    entry
    |> synthetic_entry("turn_result", "discussion", round)
    |> with_story_card(
      "Discussion",
      "The crew gathers to share observations and suspicions.",
      ["Accusations, questions, and defenses are on the table."],
      "Discussion begins."
    )
    |> then(&{&1, 2.8})
  end

  defp phase_card(entry, "voting", _state) do
    round = round_of(entry)

    entry
    |> synthetic_entry("turn_result", "voting", round)
    |> with_story_card(
      "Voting",
      "Talk ends. The crew votes on who to eject.",
      ["A majority is needed to eject. Watch for coalitions and holdouts."],
      "Voting begins."
    )
    |> then(&{&1, 2.8})
  end

  defp phase_card(_entry, _phase, _state), do: nil

  # -- Crisis beat --

  defp maybe_add_crisis_beat(state, entry) do
    phase_after = get(entry, :phase_after, nil)
    round_after = get(entry, :round_after, nil)
    detail = get(entry, :detail, %{})
    crisis = get(detail, :crisis, nil)

    # Check if entry itself contains crisis info
    crisis = crisis || get(entry, :active_crisis, nil)

    if crisis != nil do
      crisis_type = get(crisis, :type, get(crisis, :name, "Unknown Crisis"))
      crisis_name = get(crisis, :name, String.capitalize(to_string(crisis_type)))

      description =
        get(crisis, :description, get(crisis, :announcement, "A crisis strikes the station!"))

      round = round_after || round_of(entry)

      entry
      |> synthetic_entry("turn_result", phase_after || phase_of(entry), round)
      |> with_story_card(
        "Crisis Event",
        crisis_name,
        [truncate_text(description, 120)],
        "#{crisis_name}!"
      )
      |> put_detail(:crisis, crisis)
      |> add_beat(state, seconds_to_frames(3.0, state))
    else
      state
    end
  end

  # -- Scene beats --

  defp maybe_add_scene_beat(state, entry, "action", detail, _votes, _action_log) do
    latest_action = get(detail, :latest_action, nil)

    if latest_action != nil do
      player = get(latest_action, :player, "?")
      action = get(latest_action, :action, "unknown")
      system_id = get(latest_action, :system_id, nil)
      target_id = get(latest_action, :target_id, nil)

      {title, summary, lines, seconds} =
        action_reveal_card(player, action, system_id, target_id, state)

      entry
      |> put_detail(:focus_action, latest_action)
      |> put_detail(:story_title, title)
      |> with_story_card(title, summary, lines, summary)
      |> add_beat(state, seconds_to_frames(seconds, state))
    else
      # Fall back to action_log changes
      action_log = get(detail, :action_log, %{})

      action_log
      |> changed_actions(state.last_action_log)
      |> Enum.reduce(state, fn {player, action_entry}, acc ->
        action = get(action_entry, :action, "unknown")
        system_id = get(action_entry, :system, nil)
        target = get(action_entry, :target, nil)

        {title, summary, lines, seconds} =
          action_reveal_card(player, action, system_id, target, acc)

        entry
        |> synthetic_entry("turn_result", "action", round_of(entry))
        |> with_story_card(title, summary, lines, summary)
        |> put_detail(:focus_action, %{player: player, action: action})
        |> add_beat(acc, seconds_to_frames(seconds, acc))
      end)
    end
  end

  defp maybe_add_scene_beat(state, entry, "discussion", detail, _votes, _action_log) do
    # Handle different discussion entry types
    disc_type = get(detail, :type, "statement")
    speaker = get(detail, :speaker, "")
    statement = get(detail, :statement, get(detail, :question, get(detail, :evidence, "")))

    if to_string(statement) == "" do
      state
    else
      statement_str = to_string(statement)
      speaker_str = to_string(speaker)

      recent =
        state.discussion_context
        |> Enum.take(-2)
        |> Enum.map(fn item ->
          %{
            speaker: item.speaker,
            statement: truncate_text(item.statement, 140)
          }
        end)

      story_title =
        case disc_type do
          "accusation" ->
            target = get(detail, :target, "?")
            "#{speaker_str} Accuses #{target}"

          "question" ->
            target = get(detail, :target, "?")
            "#{speaker_str} Questions #{target}"

          _ ->
            case recent do
              [] -> "Opening Statement"
              _ -> "The Debate Continues"
            end
        end

      scene_entry =
        entry
        |> put_detail(:recent_statements, recent)
        |> put_detail(:story_title, story_title)
        |> put_detail(
          :story_footer,
          "#{speaker_str} speaks."
        )

      updated_context =
        state.discussion_context ++
          [%{speaker: speaker_str, statement: statement_str}]

      scene_entry
      |> add_beat(state, discussion_hold_frames(statement_str, state))
      |> Map.put(:discussion_context, updated_context)
    end
  end

  defp maybe_add_scene_beat(state, entry, "voting", _detail, votes, _action_log)
       when is_map(votes) do
    if map_size(votes) == 0 do
      state
    else
      {summary, voter, target, target_count, majority} =
        vote_summary(votes, state.last_votes, state, entry)

      seconds =
        if target_count >= majority do
          4.0
        else
          2.8
        end

      scene_entry =
        entry
        |> put_detail(:vote_summary, summary)
        |> put_detail(:highlight_vote, %{voter: voter, target: target})
        |> put_detail(:story_footer, summary)

      add_beat(scene_entry, state, seconds_to_frames(seconds, state))
    end
  end

  defp maybe_add_scene_beat(state, _entry, _phase, _detail, _votes, _action_log), do: state

  # -- Ejection beat --

  defp maybe_add_ejection_beat(state, entry, elimination_log) do
    elimination_log
    |> new_eliminations(state.last_elimination_log)
    |> Enum.reduce(state, fn elim, acc ->
      player = get(elim, :player, "?") |> to_string()
      role = get(elim, :role, "unknown") |> to_string() |> String.capitalize()
      round = get(elim, :round, round_of(entry))

      lines = [
        "Round #{round}: the crew locks in its decision.",
        "Role revealed: #{role}."
      ]

      entry
      |> synthetic_entry("turn_result", phase_of(entry), round)
      |> with_story_card(
        "#{player} Ejected",
        "#{player} has been ejected from the station.",
        lines,
        "#{player} was a #{role}."
      )
      |> add_beat(acc, seconds_to_frames(4.0, state))
    end)
  end

  # -- System health milestones --

  defp maybe_add_system_milestone(state, _entry, nil), do: state

  defp maybe_add_system_milestone(state, entry, system_health) when is_map(system_health) do
    Enum.reduce(system_health, state, fn {sys_id, health}, acc ->
      sys_id_str = to_string(sys_id)
      health_val = if is_integer(health), do: health, else: 100

      cond do
        health_val <= 0 and not MapSet.member?(acc.alerted_destroyed, sys_id_str) ->
          name = system_display_name(sys_id_str)

          beat_entry =
            entry
            |> synthetic_entry("turn_result", phase_of(entry), round_of(entry))
            |> with_story_card(
              "System Destroyed",
              "#{name} has been destroyed!",
              ["The station cannot survive this failure."],
              "#{name} is gone."
            )

          acc
          |> add_beat_entry(beat_entry, seconds_to_frames(3.0, acc))
          |> Map.update!(:alerted_destroyed, &MapSet.put(&1, sys_id_str))

        health_val > 0 and health_val <= 30 and
            not MapSet.member?(acc.alerted_critical, sys_id_str) ->
          name = system_display_name(sys_id_str)

          beat_entry =
            entry
            |> synthetic_entry("turn_result", phase_of(entry), round_of(entry))
            |> with_story_card(
              "System Critical",
              "#{name} is at #{health_val} HP!",
              ["This system is dangerously low. Immediate repairs needed."],
              "#{name} critical!"
            )

          acc
          |> add_beat_entry(beat_entry, seconds_to_frames(2.5, acc))
          |> Map.update!(:alerted_critical, &MapSet.put(&1, sys_id_str))

        true ->
          acc
      end
    end)
  end

  defp maybe_add_system_milestone(state, _entry, _other), do: state

  # -- Action reveal cards --

  defp action_reveal_card(player, action, system_id, target_id, state) do
    player_str = to_string(player)
    role = player_role(state.players, player_str)
    system_name = if system_id, do: system_display_name(system_id), else: nil

    case action do
      "repair" ->
        {"Repair", "#{player_str} repairs #{system_name}.",
         [
           "#{player_str} works on the #{system_name} system.",
           "Role: #{String.capitalize(role)}."
         ], 2.5}

      a when a in ["sabotage", "sabotage_system"] ->
        {"Sabotage!", "#{player_str} sabotages #{system_name}.",
         [
           "#{player_str} is the saboteur.",
           "The audience sees the sabotage — the crew does not."
         ], 3.0}

      a when a in ["fake_repair", "fake_repair_system"] ->
        {"Fake Repair", "#{player_str} pretends to repair #{system_name}.",
         ["#{player_str} is the saboteur.", "The repair is a deception."], 2.8}

      "scan" ->
        target_str = if target_id, do: to_string(target_id), else: "?"

        {"Scanner Check", "#{player_str} scans #{target_str}.",
         ["#{player_str} is the engineer.", "Scan results stay private."], 2.8}

      a when a in ["lock", "lock_room"] ->
        {"Room Locked", "#{player_str} locks #{system_name}.",
         ["#{player_str} is the captain.", "No sabotage can occur here this round."], 2.5}

      "vent" ->
        {"Vent!", "#{player_str} moves through the vents.",
         ["#{player_str} is the saboteur.", "No location recorded this round."], 2.5}

      "emergency_meeting" ->
        {"Emergency Meeting!", "#{player_str} calls an emergency meeting!",
         ["#{player_str} is the captain.", "The crew assembles immediately."], 3.0}

      _ ->
        {"Action", "#{player_str} acts.", ["Role: #{String.capitalize(role)}."], 2.0}
    end
  end

  # -- Discussion timing --

  defp discussion_hold_frames(statement, state) do
    word_count = count_words(statement)
    seconds = min(9.0, max(4.8, 3.6 + word_count / 18))
    seconds_to_frames(seconds, state)
  end

  # -- Vote summary --

  defp vote_summary(votes, previous_votes, state, entry) do
    {voter, target, previous_target} = changed_vote(previous_votes, votes)

    tally =
      Enum.reduce(votes, %{}, fn {_vote_voter, vote_target}, acc ->
        target_str = to_string(vote_target)

        if target_str == "skip" do
          acc
        else
          Map.update(acc, target_str, 1, &(&1 + 1))
        end
      end)

    target_count = Map.get(tally, target, 0)
    alive_count = max(1, state.player_count - length(get(entry, :elimination_log, [])))
    majority = div(alive_count, 2) + 1

    summary =
      cond do
        voter == "" ->
          "Votes shift around the table."

        target == "skip" ->
          "#{voter} votes to skip."

        previous_target != nil and previous_target != target ->
          "#{voter} flips from #{previous_target} to #{target}."

        target_count >= majority ->
          "#{voter} pushes #{target} to majority."

        true ->
          "#{voter} votes for #{target}."
      end

    {summary, voter, target, target_count, majority}
  end

  defp changed_vote(previous_votes, votes) do
    Enum.find_value(votes, {"", "", nil}, fn {voter, target} ->
      voter_str = to_string(voter)
      target_str = to_string(target)
      previous_target = lookup(previous_votes, voter_str)

      if previous_target != target_str do
        {voter_str, target_str, previous_target}
      end
    end)
  end

  # -- Intro --

  defp intro_lines(players, systems) do
    role_counts =
      players
      |> Enum.reduce(%{}, fn {_id, info}, acc ->
        role = info |> get(:role, "unknown") |> to_string()
        Map.update(acc, role, 1, &(&1 + 1))
      end)

    saboteurs = Map.get(role_counts, "saboteur", 0)
    system_count = map_size(systems)

    [
      "#{map_size(players)} crew members. #{system_count} systems to maintain.",
      "#{saboteurs} saboteur#{plural_suffix(saboteurs)} hidden among the crew.",
      "The audience sees all. The crew sees only what they can deduce."
    ]
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  # -- Resolve incremental updates --

  defp resolve_votes(detail, previous_votes) do
    votes = get(detail, :votes, nil)
    latest_vote = get(detail, :latest_vote, nil)

    base_votes =
      cond do
        is_map(votes) and map_size(votes) > 0 -> votes
        is_map(votes) and map_size(previous_votes) > 0 and latest_vote != nil -> previous_votes
        is_map(votes) -> votes
        true -> previous_votes
      end

    case latest_vote do
      vote when is_map(vote) ->
        voter = to_string(get(vote, :voter, ""))
        target = to_string(get(vote, :target, ""))

        if voter != "" and target != "" do
          Map.put(base_votes, voter, target)
        else
          base_votes
        end

      _ ->
        base_votes
    end
  end

  defp resolve_action_log(detail, previous_log) do
    action_log = get(detail, :action_log, nil)
    latest_action = get(detail, :latest_action, nil)

    base_log =
      cond do
        is_map(action_log) and map_size(action_log) > 0 -> action_log
        is_map(action_log) and map_size(previous_log) > 0 and latest_action != nil -> previous_log
        is_map(action_log) -> action_log
        true -> previous_log
      end

    case latest_action do
      action when is_map(action) ->
        player = to_string(get(action, :player, ""))

        if player != "" do
          Map.put(base_log, player, Map.delete(action, :player))
        else
          base_log
        end

      _ ->
        base_log
    end
  end

  defp changed_actions(current, previous) do
    current
    |> Enum.reject(fn {player, action} ->
      lookup(previous, to_string(player)) == action
    end)
    |> Enum.sort_by(fn {player, _} -> to_string(player) end)
    |> Enum.map(fn {player, action} -> {to_string(player), action} end)
  end

  defp next_action_log(_state, "action", action_log) when is_map(action_log), do: action_log

  defp next_action_log(state, phase, _action_log) do
    if state.prev_phase == "action" and phase != "action", do: %{}, else: state.last_action_log
  end

  defp next_votes(_state, "voting", votes) when is_map(votes), do: votes

  defp next_votes(state, phase, _votes) do
    if state.prev_phase == "voting" and phase != "voting", do: %{}, else: state.last_votes
  end

  defp new_eliminations(current, previous) do
    previous_players =
      previous
      |> List.wrap()
      |> MapSet.new(fn item -> to_string(get(item, :player, "")) end)

    current
    |> List.wrap()
    |> Enum.reject(fn item ->
      MapSet.member?(previous_players, to_string(get(item, :player, "")))
    end)
  end

  # -- Helpers --

  defp add_beat(entry, state, hold_frames) do
    beat = %{entry: entry, hold_frames: max(1, hold_frames)}
    %{state | beats: [beat | state.beats]}
  end

  defp add_beat_entry(state, entry, hold_frames) do
    beat = %{entry: entry, hold_frames: max(1, hold_frames)}
    %{state | beats: [beat | state.beats]}
  end

  defp with_story_card(entry, title, summary, lines, footer) do
    entry
    |> put_detail(:story_card, %{title: title, summary: summary, lines: Enum.take(lines, 4)})
    |> put_detail(:story_footer, footer)
  end

  defp put_detail(entry, key, value) do
    detail = get(entry, :detail, %{})
    Map.put(entry, :detail, Map.put(detail, key, value))
  end

  defp synthetic_entry(entry, type, phase, round) do
    %{
      type: type,
      step: get(entry, :step, 0),
      round: round || get(entry, :round, 1),
      phase: phase,
      detail: %{},
      elimination_log: get(entry, :elimination_log, [])
    }
  end

  defp phase_of(entry) do
    get(entry, :phase, get(get(entry, :world, %{}), :phase, "action"))
  end

  defp round_of(entry) do
    get(entry, :round, get(get(entry, :world, %{}), :round, 1))
  end

  defp seconds_to_frames(seconds, state) do
    seconds
    |> Kernel.*(state.fps)
    |> Kernel.*(state.hold_multiplier)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  defp count_words(text) do
    text
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp truncate_text(text, max_len) do
    text = to_string(text)

    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  defp extract_players_info(entries) do
    case Enum.find(entries, fn e -> get(e, :type, "") == "game_start" end) do
      nil -> %{}
      start -> get(start, :players, %{})
    end
  end

  defp extract_systems_info(entries) do
    case Enum.find(entries, fn e -> get(e, :type, "") == "game_start" end) do
      nil ->
        %{}

      start ->
        world = get(start, :world, %{})
        get(world, :systems, %{})
    end
  end

  defp player_role(players, player_id) do
    players
    |> lookup(to_string(player_id))
    |> get(:role, "unknown")
    |> to_string()
  end

  defp system_display_name(nil), do: "unknown"
  defp system_display_name("o2"), do: "Oxygen"
  defp system_display_name("power"), do: "Reactor Power"
  defp system_display_name("hull"), do: "Hull Integrity"
  defp system_display_name("comms"), do: "Communications"
  defp system_display_name("nav"), do: "Navigation"
  defp system_display_name("medbay"), do: "Medical Bay"
  defp system_display_name("shields"), do: "Shield Array"
  defp system_display_name(other), do: to_string(other)

  defp lookup(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end

      value ->
        value
    end
  end

  defp lookup(_, _), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key), default)
      value -> value
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

      value ->
        value
    end
  end

  defp get(_map, _key, default), do: default
end
