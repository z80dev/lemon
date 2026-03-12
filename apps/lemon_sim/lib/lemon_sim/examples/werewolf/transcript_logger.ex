defmodule LemonSim.Examples.Werewolf.TranscriptLogger do
  @moduledoc false

  @spec turn_start_entry(pos_integer(), map(), map()) :: map()
  def turn_start_entry(turn, world, model_assignments) do
    actor_id = get(world, :active_actor_id)
    {model, _key} = Map.get(model_assignments, actor_id, {nil, nil})
    model_name = if model, do: "#{model.provider}/#{model.id}", else: "unknown"

    %{
      type: "turn_start",
      timestamp: now_iso8601(),
      step: turn,
      phase: get(world, :phase),
      day: get(world, :day_number),
      active_player: actor_id,
      model: model_name
    }
  end

  @spec step_meta(map()) :: map()
  def step_meta(world) do
    %{
      phase: get(world, :phase),
      day: get(world, :day_number),
      active_player: get(world, :active_actor_id),
      votes: get(world, :votes, %{}),
      night_actions: get(world, :night_actions, %{})
    }
  end

  @spec turn_result_entry(pos_integer(), map(), map()) :: map()
  def turn_result_entry(turn, step_meta, %{state: %{world: world}} = result)
      when is_map(step_meta) and is_map(world) do
    phase = action_phase(result, step_meta, world)
    day = action_day(step_meta, world)
    detail = detail_for_phase(phase, step_meta, world, result)

    base = %{
      type: "turn_result",
      timestamp: now_iso8601(),
      step: turn,
      phase: phase,
      day: day,
      detail: detail,
      status: get(world, :status),
      elimination_log: get(world, :elimination_log, [])
    }

    maybe_put_transition_metadata(base, step_meta, world)
  end

  def turn_result_entry(turn, _step_meta, world) when is_map(world) do
    phase = get(world, :phase)

    %{
      type: "turn_result",
      timestamp: now_iso8601(),
      step: turn,
      phase: phase,
      day: get(world, :day_number),
      detail: legacy_detail(phase, world),
      status: get(world, :status),
      elimination_log: get(world, :elimination_log, [])
    }
  end

  @spec print_step_summary(map()) :: String.t() | nil
  def print_step_summary(%{decision: decision, state: %{world: world}} = result)
      when is_map(decision) do
    case action_phase(result, %{}, world) do
      "day_discussion" ->
        speaker = actor_from_result(result)
        statement = statement_from_decision(decision)

        if is_binary(statement) and statement != "" do
          ~s{  [#{speaker}]: "#{statement}"}
        end

      "day_voting" ->
        voter = actor_from_result(result)
        target = vote_target_from_decision(decision)

        if is_binary(voter) and is_binary(target) and voter != "" and target != "" do
          "  #{voter} voted for #{target}"
        end

      "game_over" ->
        "  Game over! Winner: #{get(world, :winner)}"

      _ ->
        nil
    end
  end

  def print_step_summary(%{state: %{world: world}}) when is_map(world) do
    case get(world, :phase) do
      "day_discussion" ->
        world
        |> get(:discussion_transcript, [])
        |> List.last()
        |> case do
          nil ->
            nil

          entry ->
            ~s{  [#{get(entry, :player)}]: "#{get(entry, :statement)}"}
        end

      "day_voting" ->
        votes = get(world, :votes, %{})

        if map_size(votes) > 0 do
          {voter, target} = List.last(Enum.to_list(votes))
          "  #{voter} voted for #{target}"
        end

      "game_over" ->
        "  Game over! Winner: #{get(world, :winner)}"

      _ ->
        nil
    end
  end

  def print_step_summary(_result), do: nil

  defp detail_for_phase("day_discussion", step_meta, world, %{decision: decision}) do
    statement = statement_from_decision(decision)
    speaker = Map.get(step_meta, :active_player) || actor_from_result(%{decision: decision})

    if is_binary(statement) and statement != "" do
      %{statement: statement, speaker: speaker}
    else
      transcript = get(world, :discussion_transcript, [])
      last = List.last(transcript)
      if last, do: %{statement: get(last, :statement), speaker: get(last, :player)}, else: %{}
    end
  end

  defp detail_for_phase("day_voting", step_meta, world, %{decision: decision}) do
    latest_vote = vote_from_decision(decision)
    votes = preserve_votes(step_meta, world, latest_vote)

    %{votes: votes}
    |> maybe_put(:latest_vote, latest_vote)
  end

  defp detail_for_phase("night", step_meta, world, %{decision: decision}) do
    latest_action = night_action_from_decision(decision, world)
    night_actions = preserve_night_actions(step_meta, world, latest_action)

    %{night_actions: night_actions}
    |> maybe_put(:latest_night_action, latest_action)
  end

  defp detail_for_phase(_phase, _step_meta, _world, _result), do: %{}

  defp legacy_detail("day_discussion", world) do
    transcript = get(world, :discussion_transcript, [])
    last = List.last(transcript)
    if last, do: %{statement: get(last, :statement), speaker: get(last, :player)}, else: %{}
  end

  defp legacy_detail("day_voting", world), do: %{votes: get(world, :votes, %{})}
  defp legacy_detail("night", world), do: %{night_actions: get(world, :night_actions, %{})}
  defp legacy_detail(_phase, _world), do: %{}

  defp action_phase(%{decision: decision}, step_meta, world) when is_map(decision) do
    case tool_name(decision) do
      "make_statement" ->
        "day_discussion"

      "cast_vote" ->
        "day_voting"

      name when name in ["choose_victim", "investigate_player", "protect_player", "sleep"] ->
        "night"

      _ ->
        Map.get(step_meta, :phase) || get(world, :phase)
    end
  end

  defp action_phase(_result, step_meta, world),
    do: Map.get(step_meta, :phase) || get(world, :phase)

  defp action_day(step_meta, world) do
    previous_day = Map.get(step_meta, :day)
    previous_phase = Map.get(step_meta, :phase)
    next_phase = get(world, :phase)

    cond do
      previous_day == nil ->
        get(world, :day_number)

      previous_phase == "day_voting" and next_phase == "night" ->
        previous_day

      true ->
        previous_day
    end
  end

  defp maybe_put_transition_metadata(entry, step_meta, world) do
    next_phase = get(world, :phase)
    next_day = get(world, :day_number)

    entry
    |> maybe_put(:phase_after, if(next_phase != entry.phase, do: next_phase, else: nil))
    |> maybe_put(:day_after, if(next_day != entry.day, do: next_day, else: nil))
    |> maybe_put(:active_player_after, get(world, :active_actor_id))
    |> maybe_drop_matching(:active_player_after, Map.get(step_meta, :active_player))
  end

  defp statement_from_decision(decision) do
    arguments = Map.get(decision, "arguments", %{})
    get(arguments, :statement)
  end

  defp vote_target_from_decision(decision) do
    arguments = Map.get(decision, "arguments", %{})
    get(arguments, :target_id)
  end

  defp vote_from_decision(decision) do
    voter = actor_from_result(%{decision: decision})
    target = vote_target_from_decision(decision)

    if is_binary(voter) and voter != "" and is_binary(target) and target != "" do
      %{voter: voter, target: target}
    end
  end

  defp preserve_votes(step_meta, world, latest_vote) do
    world_votes = get(world, :votes, %{})
    previous_votes = Map.get(step_meta, :votes, %{})

    base_votes =
      if map_size(world_votes) >= map_size(previous_votes), do: world_votes, else: previous_votes

    case latest_vote do
      %{voter: voter, target: target} -> Map.put(base_votes, voter, target)
      _ -> base_votes
    end
  end

  defp preserve_night_actions(step_meta, world, latest_action) do
    world_actions = get(world, :night_actions, %{})
    previous_actions = Map.get(step_meta, :night_actions, %{})

    base_actions =
      if map_size(world_actions) >= map_size(previous_actions),
        do: world_actions,
        else: previous_actions

    case latest_action do
      %{player: player} = action -> Map.put(base_actions, player, Map.delete(action, :player))
      _ -> base_actions
    end
  end

  defp night_action_from_decision(decision, world) do
    actor = actor_from_result(%{decision: decision})
    arguments = Map.get(decision, "arguments", %{})

    case tool_name(decision) do
      "choose_victim" ->
        target = get(arguments, :victim_id)
        build_night_action(actor, "choose_victim", target: target)

      "investigate_player" ->
        target = get(arguments, :target_id)
        result = investigation_result(world, target)
        build_night_action(actor, "investigate", target: target, result: result)

      "protect_player" ->
        target = get(arguments, :target_id)
        build_night_action(actor, "protect", target: target)

      "sleep" ->
        build_night_action(actor, "sleep")

      _ ->
        nil
    end
  end

  defp build_night_action(player, action, attrs \\ []) do
    if is_binary(player) and player != "" do
      attrs
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{player: player, action: action})
    end
  end

  defp investigation_result(world, target) do
    world
    |> get(:seer_history, [])
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if get(entry, :target) == target, do: get(entry, :role)
    end)
  end

  defp actor_from_result(%{decision: decision}) when is_map(decision) do
    details = Map.get(decision, "result_details", %{})
    event = Map.get(details, "event") || Map.get(details, :event) || %{}
    payload = Map.get(event, "payload") || Map.get(event, :payload) || %{}
    get(payload, :player_id)
  end

  defp actor_from_result(_), do: nil

  defp tool_name(decision) do
    decision
    |> Map.get("tool_name")
    |> case do
      nil -> Map.get(decision, :tool_name)
      value -> value
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_drop_matching(map, _key, nil), do: map

  defp maybe_drop_matching(map, key, value) do
    if Map.get(map, key) == value do
      Map.delete(map, key)
    else
      map
    end
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default

  defp get(map, key) when is_map(map) and is_atom(key) do
    get(map, key, nil)
  end

  defp get(_map, _key), do: nil
end
