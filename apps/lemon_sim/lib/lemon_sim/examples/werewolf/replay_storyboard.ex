defmodule LemonSim.Examples.Werewolf.ReplayStoryboard do
  @moduledoc """
  Condenses raw Werewolf transcript entries into viewer-friendly replay beats.

  The raw log is useful for debugging but too granular for a watchable replay.
  This module condenses the transcript into phase cards, readable discussion
  moments, explicit night-action reveals, vote beats, elimination reveals, and
  a final result card.
  """

  @default_fps 2
  @default_hold_frames 1

  @type beat :: %{entry: map(), hold_frames: pos_integer()}

  @spec build([map()], keyword()) :: [beat()]
  def build(entries, opts \\ []) do
    players = extract_players_info(entries)
    player_count = map_size(players)

    state = %{
      beats: [],
      prev_phase: nil,
      discussion_context: [],
      last_votes: %{},
      last_night_actions: %{},
      last_elimination_log: [],
      pending_dawn_eliminations: [],
      fps: Keyword.get(opts, :fps, @default_fps),
      hold_multiplier: max(1, Keyword.get(opts, :hold_frames, @default_hold_frames)),
      player_count: player_count,
      players: players
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
          intro_title(entry),
          "The village assembles. Watch the claims, the pile-ons, and the final reveal.",
          intro_lines(state.players),
          "The game is on."
        )
        |> add_beat(state, seconds_to_frames(4.5, state))
        |> Map.put(:prev_phase, phase_of(entry))

      "turn_result" ->
        consume_turn_result(entry, state)

      "game_over" ->
        add_beat(entry, state, seconds_to_frames(6.0, state))

      _ ->
        state
    end
  end

  defp consume_turn_result(entry, state) do
    phase = phase_of(entry)
    detail = get(entry, :detail, %{})
    elimination_log = get(entry, :elimination_log, state.last_elimination_log)
    votes = resolve_votes(detail, state.last_votes)
    night_actions = resolve_night_actions(detail, state.last_night_actions)
    new_elims = new_eliminations(elimination_log, state.last_elimination_log)

    discussion_context =
      if state.prev_phase == "day_discussion" and phase != "day_discussion" do
        []
      else
        state.discussion_context
      end

    pending_dawn_eliminations =
      cond do
        phase == "night" and new_elims != [] ->
          new_elims

        state.prev_phase == "night" and phase == "day_discussion" ->
          state.pending_dawn_eliminations

        true ->
          []
      end

    state =
      %{
        state
        | discussion_context: discussion_context,
          pending_dawn_eliminations: pending_dawn_eliminations
      }
      |> maybe_add_phase_card(entry, phase, elimination_log)
      |> maybe_add_scene_beat(entry, phase, detail, votes, night_actions)
      |> maybe_add_elimination_beat(entry, elimination_log)

    %{
      state
      | prev_phase: phase,
        last_elimination_log: elimination_log,
        last_night_actions: next_night_actions(state, phase, night_actions),
        last_votes: next_votes(state, phase, votes)
    }
  end

  defp maybe_add_elimination_beat(state, entry, elimination_log) do
    elimination_log
    |> new_eliminations(state.last_elimination_log)
    |> Enum.reduce(state, fn elim, acc ->
      player = short_player_name(get(elim, :player, "?"), acc.players)
      role = get(elim, :role, "unknown") |> to_string() |> String.capitalize()
      reason = elimination_reason(get(elim, :reason, ""))
      day = get(elim, :day, get(entry, :day, 1))

      lines =
        case get(elim, :reason, "") do
          "killed" -> ["Day #{day} begins with a body on the ground.", "Role revealed: #{role}."]
          _ -> ["The village locks in its decision.", "Role revealed: #{role}."]
        end

      entry
      |> synthetic_entry("turn_result", phase_of(entry))
      |> with_story_card(
        "#{player} Eliminated",
        "#{player} #{reason}.",
        lines,
        "#{player} #{reason}."
      )
      |> add_beat(acc, seconds_to_frames(4.0, state))
    end)
  end

  defp maybe_add_phase_card(state, entry, phase, elimination_log) do
    if phase == state.prev_phase do
      state
    else
      case phase_card(entry, phase, state, elimination_log) do
        nil -> state
        {card_entry, seconds} -> add_beat(card_entry, state, seconds_to_frames(seconds, state))
      end
    end
  end

  defp maybe_add_scene_beat(state, entry, "night", _detail, _votes, night_actions)
       when is_map(night_actions) do
    night_actions
    |> changed_night_actions(state.last_night_actions)
    |> Enum.reduce(state, fn {player, action}, acc ->
      {title, summary, lines, seconds} = night_action_card(player, action, acc)

      entry
      |> synthetic_entry("turn_result", "night")
      |> with_story_card(title, summary, lines, summary)
      |> put_detail(:focus_night_action, %{player: player, action: action})
      |> add_beat(acc, seconds_to_frames(seconds, acc))
    end)
  end

  defp maybe_add_scene_beat(state, entry, "day_discussion", detail, _votes, _night_actions) do
    statement = detail |> get(:statement, "") |> to_string()
    speaker = detail |> get(:speaker, "") |> to_string()

    if statement == "" do
      state
    else
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
        case recent do
          [] -> "Opening Statement"
          _ -> "The Debate Tightens"
        end

      scene_entry =
        entry
        |> put_detail(:recent_statements, recent)
        |> put_detail(:story_title, story_title)
        |> put_detail(
          :story_footer,
          "#{short_player_name(speaker, state.players)} makes their case."
        )

      updated_context =
        state.discussion_context ++
          [%{speaker: speaker, statement: statement}]

      scene_entry
      |> add_beat(state, discussion_hold_frames(statement, state))
      |> Map.put(:discussion_context, updated_context)
    end
  end

  defp maybe_add_scene_beat(state, entry, "day_voting", _detail, votes, _night_actions)
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

  defp maybe_add_scene_beat(state, _entry, _phase, _detail, _votes, _night_actions), do: state

  defp phase_card(entry, "night", _state, _elimination_log) do
    day = get(entry, :day, 1)

    entry
    |> synthetic_entry("turn_result", "night")
    |> with_story_card(
      "Night #{day}",
      "The village sleeps while hidden roles move in the dark.",
      ["Watch for investigations, protections, and quiet coordination."],
      "Night #{day} begins."
    )
    |> then(&{&1, 3.0})
  end

  defp phase_card(entry, "day_discussion", state, _elimination_log) do
    day = get(entry, :day, 1)
    new_elims = state.pending_dawn_eliminations

    summary =
      case new_elims do
        [] ->
          "Nobody died overnight."

        [elim | _] ->
          "#{short_player_name(get(elim, :player, "?"), state.players)} was found dead."
      end

    lines =
      state.last_night_actions
      |> summarize_night_actions(state.players)
      |> case do
        [] -> ["The village has to reason from reactions and claims alone."]
        items -> items
      end

    entry
    |> synthetic_entry("turn_result", "day_discussion")
    |> with_story_card("Dawn #{day}", summary, lines, "Day #{day} discussion begins.")
    |> then(&{&1, 3.5})
  end

  defp phase_card(entry, "day_voting", _state, _elimination_log) do
    day = get(entry, :day, 1)

    entry
    |> synthetic_entry("turn_result", "day_voting")
    |> with_story_card(
      "Voting: Day #{day}",
      "Talk ends. Every vote now changes the board.",
      ["Watch for momentum, counter-votes, and sudden pile-ons."],
      "Voting begins."
    )
    |> then(&{&1, 2.8})
  end

  defp phase_card(_entry, _phase, _state, _elimination_log), do: nil

  defp discussion_hold_frames(statement, state) do
    word_count = count_words(statement)
    seconds = min(9.0, max(4.8, 3.6 + word_count / 18))
    seconds_to_frames(seconds, state)
  end

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
          "Votes shift around the circle."

        previous_target != nil and previous_target != target ->
          "#{short_player_name(voter, state.players)} flips from #{short_player_name(previous_target, state.players)} to #{short_player_name(target, state.players)}."

        target_count >= majority ->
          "#{short_player_name(voter, state.players)} pushes #{short_player_name(target, state.players)} to majority."

        true ->
          "#{short_player_name(voter, state.players)} votes #{short_player_name(target, state.players)}."
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

  defp summarize_night_actions(night_actions, players) when is_map(night_actions) do
    wolf_targets =
      night_actions
      |> Enum.filter(fn {_player, action} ->
        get(action, :action, "") == "choose_victim"
      end)
      |> Enum.map(fn {_player, action} ->
        short_player_name(get(action, :target, "?"), players)
      end)
      |> Enum.uniq()

    lines =
      []
      |> maybe_append(wolf_line(wolf_targets))
      |> maybe_append(investigation_line(night_actions, players))
      |> maybe_append(protection_line(night_actions, players))

    Enum.take(lines, 3)
  end

  defp summarize_night_actions(_, _), do: []

  defp wolf_line([]), do: nil
  defp wolf_line([target]), do: "The wolves converged on #{target}."

  defp wolf_line(targets) do
    "The wolves split suspicion between #{Enum.join(targets, " and ")}."
  end

  defp investigation_line(actions, players) do
    actions
    |> Enum.find_value(fn {player, action} ->
      if get(action, :action, "") == "investigate" do
        result =
          case get(action, :result, nil) do
            nil -> ""
            value -> " and saw #{String.upcase(to_string(value))}"
          end

        "#{short_player_name(to_string(player), players)} investigated #{short_player_name(get(action, :target, "?"), players)}#{result}."
      end
    end)
  end

  defp protection_line(actions, players) do
    actions
    |> Enum.find_value(fn {player, action} ->
      if get(action, :action, "") == "protect" do
        "#{short_player_name(to_string(player), players)} protected #{short_player_name(get(action, :target, "?"), players)}."
      end
    end)
  end

  defp intro_title(entry) do
    phase =
      entry
      |> get(:world, %{})
      |> get(:phase, "night")

    if phase == "night", do: "Night 1", else: "Werewolf"
  end

  defp intro_lines(players) do
    role_counts =
      players
      |> Enum.reduce(%{}, fn {_player_id, info}, acc ->
        role = info |> get(:role, "unknown") |> to_string()
        Map.update(acc, role, 1, &(&1 + 1))
      end)

    werewolves = Map.get(role_counts, "werewolf", 0)
    seers = Map.get(role_counts, "seer", 0)
    doctors = Map.get(role_counts, "doctor", 0)

    [
      "#{map_size(players)} players enter the village.",
      "#{werewolves} werewolf#{plural_suffix(werewolves)}, #{seers} seer#{plural_suffix(seers)}, #{doctors} doctor#{plural_suffix(doctors)}.",
      "The audience sees the full board. The players do not."
    ]
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  defp elimination_reason("killed"), do: "was killed in the night"
  defp elimination_reason("voted"), do: "was voted out"
  defp elimination_reason(_), do: "left the game"

  defp add_beat(entry, state, hold_frames) do
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

  defp synthetic_entry(entry, type, phase) do
    %{
      type: type,
      step: get(entry, :step, 0),
      day: get(entry, :day, 1),
      phase: phase,
      detail: %{},
      elimination_log: get(entry, :elimination_log, [])
    }
  end

  defp next_night_actions(_state, phase, night_actions)
       when phase == "night" and is_map(night_actions) do
    night_actions
  end

  defp next_night_actions(state, phase, _night_actions) do
    if state.prev_phase == "night" and phase != "night", do: %{}, else: state.last_night_actions
  end

  defp next_votes(_state, "day_voting", votes) when is_map(votes), do: votes

  defp next_votes(state, phase, _votes) do
    if state.prev_phase == "day_voting" and phase != "day_voting", do: %{}, else: state.last_votes
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

  defp phase_of(entry) do
    get(entry, :phase, get(get(entry, :world, %{}), :phase, "night"))
  end

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

  defp resolve_night_actions(detail, previous_night_actions) do
    night_actions = get(detail, :night_actions, nil)
    latest_action = get(detail, :latest_night_action, nil)

    base_actions =
      cond do
        is_map(night_actions) and map_size(night_actions) > 0 ->
          night_actions

        is_map(night_actions) and map_size(previous_night_actions) > 0 and latest_action != nil ->
          previous_night_actions

        is_map(night_actions) ->
          night_actions

        true ->
          previous_night_actions
      end

    case latest_action do
      action when is_map(action) ->
        player = to_string(get(action, :player, ""))

        if player != "" do
          Map.put(base_actions, player, drop_key(action, :player))
        else
          base_actions
        end

      _ ->
        base_actions
    end
  end

  defp changed_night_actions(current, previous) do
    current
    |> Enum.reject(fn {player, action} ->
      lookup(previous, to_string(player)) == action
    end)
    |> Enum.sort_by(fn {player, _action} -> player_sort_key(player) end)
    |> Enum.map(fn {player, action} -> {to_string(player), action} end)
  end

  defp night_action_card(player, action, state) do
    actor = short_player_name(player, state.players)
    role = player_role(state.players, player)

    case get(action, :action, "") do
      "choose_victim" ->
        target = short_player_name(get(action, :target, "?"), state.players)

        {"Werewolf Move", "#{actor} targets #{target}.",
         ["#{actor} is one of the werewolves.", "The audience sees the kill choice immediately."],
         2.8}

      "investigate" ->
        target = short_player_name(get(action, :target, "?"), state.players)
        result = get(action, :result, "unknown") |> to_string() |> String.upcase()

        {"Seer Check", "#{actor} investigates #{target} and sees #{result}.",
         ["#{actor} is the seer.", "This information stays private to the seer inside the game."],
         3.2}

      "protect" ->
        target = short_player_name(get(action, :target, "?"), state.players)

        {"Doctor Cover", "#{actor} protects #{target}.",
         ["#{actor} is the doctor.", "A correct read can erase the wolves' kill."], 2.8}

      "sleep" ->
        {"Night Pass", "#{actor} sleeps through the night.",
         ["#{actor} has no night power to use.", "Role: #{String.capitalize(role)}."], 1.8}

      other ->
        {"Night Action", "#{actor} performs #{other}.", ["Role: #{String.capitalize(role)}."],
         2.2}
    end
  end

  defp player_role(players, player_id) do
    players
    |> lookup(to_string(player_id))
    |> get(:role, "unknown")
    |> to_string()
  end

  defp player_sort_key(player_id), do: to_string(player_id)

  defp drop_key(map, key) when is_map(map) and is_atom(key) do
    map
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
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
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, item), do: list ++ [item]

  defp extract_players_info(entries) do
    case Enum.find(entries, fn e -> get(e, :type, "") == "game_start" end) do
      nil -> %{}
      start -> get(start, :players, %{})
    end
  end

  defp short_player_name(player_id, _players) when is_binary(player_id), do: player_id

  defp short_player_name(other, _players), do: to_string(other)

  defp lookup(map, key) do
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
