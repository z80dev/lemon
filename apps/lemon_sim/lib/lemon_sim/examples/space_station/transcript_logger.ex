defmodule LemonSim.Examples.SpaceStation.TranscriptLogger do
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
      round: get(world, :round),
      active_player: actor_id,
      model: model_name
    }
  end

  @spec step_meta(map()) :: map()
  def step_meta(world) do
    systems = get(world, :systems, %{})

    system_health =
      systems
      |> Enum.sort_by(fn {id, _s} -> id end)
      |> Enum.into(%{}, fn {id, s} -> {id, get(s, :health, 100)} end)

    %{
      phase: get(world, :phase),
      round: get(world, :round),
      active_player: get(world, :active_actor_id),
      votes: get(world, :votes, %{}),
      action_log: get(world, :action_log, %{}),
      system_health: system_health
    }
  end

  @spec turn_result_entry(pos_integer(), map(), map()) :: map()
  def turn_result_entry(turn, step_meta, %{state: %{world: world}} = result)
      when is_map(step_meta) and is_map(world) do
    phase = action_phase(result, step_meta, world)
    round = action_round(step_meta, world)
    detail = detail_for_phase(phase, step_meta, world, result)

    base = %{
      type: "turn_result",
      timestamp: now_iso8601(),
      step: turn,
      phase: phase,
      round: round,
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
      round: get(world, :round),
      detail: legacy_detail(phase, world),
      status: get(world, :status),
      elimination_log: get(world, :elimination_log, [])
    }
  end

  @spec print_step_summary(map()) :: String.t() | nil
  def print_step_summary(%{decision: decision, state: %{world: world}} = result)
      when is_map(decision) do
    case action_phase(result, %{}, world) do
      "action" ->
        actor = actor_from_result(result)
        action = tool_name(decision)
        arguments = Map.get(decision, "arguments", %{})
        system_id = get(arguments, :system_id)

        case action do
          "repair_system" ->
            "  #{actor} repaired #{system_id}"

          "sabotage_system" ->
            "  #{actor} sabotaged #{system_id}"

          "inspect_system" ->
            "  #{actor} inspected #{system_id}"

          "scan_player" ->
            target = get(arguments, :target_id)
            "  #{actor} scanned #{target}"

          "lock_room" ->
            "  #{actor} locked #{system_id}"

          "vent" ->
            "  #{actor} vented"

          "call_emergency_meeting" ->
            "  #{actor} called emergency meeting!"

          _ ->
            nil
        end

      "discussion" ->
        speaker = actor_from_result(result)
        action = tool_name(decision)
        arguments = Map.get(decision, "arguments", %{})

        case action do
          "make_statement" ->
            statement = get(arguments, :statement)

            if is_binary(statement) and statement != "" do
              ~s{  [#{speaker}]: "#{statement}"}
            end

          "ask_question" ->
            target = get(arguments, :target_id)
            question = get(arguments, :question)

            if is_binary(question) and question != "" do
              ~s{  [#{speaker}] asks #{target}: "#{question}"}
            end

          "accuse" ->
            target = get(arguments, :target_id)
            evidence = get(arguments, :evidence)

            if is_binary(evidence) and evidence != "" do
              ~s{  [#{speaker}] ACCUSES #{target}: "#{evidence}"}
            end

          _ ->
            nil
        end

      "voting" ->
        voter = actor_from_result(result)
        target = vote_target_from_decision(decision)

        if is_binary(voter) and is_binary(target) and voter != "" and target != "" do
          "  #{voter} voted for #{target}"
        end

      "report" ->
        systems = get(world, :systems, %{})

        if map_size(systems) > 0 do
          health_str =
            systems
            |> Enum.sort_by(fn {id, _s} -> id end)
            |> Enum.map(fn {id, s} -> "#{id}=#{get(s, :health, "?")}" end)
            |> Enum.join(" ")

          "  Systems: #{health_str}"
        end

      "game_over" ->
        "  Game over! Winner: #{get(world, :winner)}"

      _ ->
        nil
    end
  end

  def print_step_summary(%{state: %{world: world}}) when is_map(world) do
    case get(world, :phase) do
      "discussion" ->
        transcript = get(world, :discussion_transcript, [])

        case List.last(transcript) do
          nil ->
            nil

          entry ->
            speaker = get(entry, :player)
            entry_type = get(entry, :type, "statement")

            case entry_type do
              "question" ->
                target = get(entry, :target)
                question = get(entry, :statement, "")
                ~s{  [#{speaker}] asks #{target}: "#{question}"}

              "accusation" ->
                target = get(entry, :target)
                evidence = get(entry, :statement, "")
                ~s{  [#{speaker}] ACCUSES #{target}: "#{evidence}"}

              _ ->
                ~s{  [#{speaker}]: "#{get(entry, :statement)}"}
            end
        end

      "voting" ->
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

  # -- Phase-specific detail builders --

  defp detail_for_phase("discussion", _step_meta, world, %{decision: decision}) do
    arguments = Map.get(decision, "arguments", %{})
    action = tool_name(decision)
    speaker = actor_from_result(%{decision: decision})

    case action do
      "make_statement" ->
        statement = get(arguments, :statement)

        if is_binary(statement) and statement != "" do
          %{type: "statement", speaker: speaker, statement: statement}
        else
          transcript = get(world, :discussion_transcript, [])
          last = List.last(transcript)
          if last, do: %{statement: get(last, :statement), speaker: get(last, :player)}, else: %{}
        end

      "ask_question" ->
        %{
          type: "question",
          speaker: speaker,
          target: get(arguments, :target_id),
          question: get(arguments, :question)
        }

      "accuse" ->
        %{
          type: "accusation",
          speaker: speaker,
          target: get(arguments, :target_id),
          evidence: get(arguments, :evidence)
        }

      _ ->
        %{}
    end
  end

  defp detail_for_phase("voting", step_meta, world, %{decision: decision}) do
    latest_vote = vote_from_decision(decision)
    votes = preserve_votes(step_meta, world, latest_vote)

    %{votes: votes}
    |> maybe_put(:latest_vote, latest_vote)
  end

  defp detail_for_phase("action", step_meta, world, %{decision: decision}) do
    latest_action = action_from_decision(decision)
    action_log = preserve_action_log(step_meta, world, latest_action)

    %{action_log: action_log}
    |> maybe_put(:latest_action, latest_action)
  end

  defp detail_for_phase(_phase, _step_meta, _world, _result), do: %{}

  defp legacy_detail("discussion", world) do
    transcript = get(world, :discussion_transcript, [])
    last = List.last(transcript)
    if last, do: %{statement: get(last, :statement), speaker: get(last, :player)}, else: %{}
  end

  defp legacy_detail("voting", world), do: %{votes: get(world, :votes, %{})}
  defp legacy_detail("action", world), do: %{action_log: get(world, :action_log, %{})}
  defp legacy_detail(_phase, _world), do: %{}

  # -- Phase detection --

  @action_tools ~w(repair_system sabotage_system inspect_system fake_repair scan_player lock_room vent call_emergency_meeting)
  @discussion_tools ~w(make_statement ask_question accuse)

  defp action_phase(%{decision: decision}, step_meta, world) when is_map(decision) do
    case tool_name(decision) do
      name when name in @discussion_tools ->
        "discussion"

      "cast_vote" ->
        "voting"

      name when name in @action_tools ->
        "action"

      _ ->
        Map.get(step_meta, :phase) || get(world, :phase)
    end
  end

  defp action_phase(_result, step_meta, world),
    do: Map.get(step_meta, :phase) || get(world, :phase)

  defp action_round(step_meta, world) do
    previous_round = Map.get(step_meta, :round)

    if previous_round == nil do
      get(world, :round)
    else
      previous_round
    end
  end

  # -- Transition metadata --

  defp maybe_put_transition_metadata(entry, step_meta, world) do
    next_phase = get(world, :phase)
    next_round = get(world, :round)

    entry
    |> maybe_put(:phase_after, if(next_phase != entry.phase, do: next_phase, else: nil))
    |> maybe_put(:round_after, if(next_round != entry.round, do: next_round, else: nil))
    |> maybe_put(:active_player_after, get(world, :active_actor_id))
    |> maybe_drop_matching(:active_player_after, Map.get(step_meta, :active_player))
  end

  # -- Decision extractors --

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

  defp action_from_decision(decision) do
    actor = actor_from_result(%{decision: decision})
    action = tool_name(decision)
    arguments = Map.get(decision, "arguments", %{})

    if is_binary(actor) and actor != "" and action in @action_tools do
      base = %{player: actor, action: action}
      system_id = get(arguments, :system_id)
      target_id = get(arguments, :target_id)

      base
      |> maybe_put(:system_id, system_id)
      |> maybe_put(:target_id, target_id)
    end
  end

  defp preserve_action_log(step_meta, world, latest_action) do
    world_log = get(world, :action_log, %{})
    previous_log = Map.get(step_meta, :action_log, %{})

    base_log =
      if map_size(world_log) >= map_size(previous_log), do: world_log, else: previous_log

    case latest_action do
      %{player: player} = action -> Map.put(base_log, player, Map.delete(action, :player))
      _ -> base_log
    end
  end

  # -- Shared helpers --

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
