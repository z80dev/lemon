defmodule LemonSim.Examples.IntelNetwork.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.IntelNetwork.{Events, NetworkGraph}

  @max_messages_per_round 2
  @leak_threshold 5

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "send_message" -> apply_send_message(state, event)
      "end_communication" -> apply_end_communication(state, event)
      "submit_analysis" -> apply_submit_analysis(state, event)
      "end_operations" -> apply_end_operations(state, event)
      "propose_operation" -> apply_propose_operation(state, event)
      "mole_action" -> apply_mole_action(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Send Message (Communication Phase) --

  defp apply_send_message(%State{} = state, event) do
    sender_id = fetch(event.payload, :sender_id, "sender_id")
    recipient_id = fetch(event.payload, :recipient_id, "recipient_id")
    content = fetch(event.payload, :content, "content", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communication"),
         :ok <- ensure_active_actor(state.world, sender_id),
         :ok <- ensure_valid_player(state.world, recipient_id),
         :ok <- ensure_different(sender_id, recipient_id),
         :ok <- ensure_adjacent(state.world, sender_id, recipient_id),
         :ok <- ensure_message_quota(state.world, sender_id) do
      round = get(state.world, :round, 1)
      message_log = get(state.world, :message_log, %{})
      edge_key = edge_key(sender_id, recipient_id)
      edge_history = Map.get(message_log, edge_key, [])

      new_msg = %{
        "from" => sender_id,
        "to" => recipient_id,
        "content" => content,
        "round" => round
      }

      updated_log = Map.put(message_log, edge_key, edge_history ++ [new_msg])

      sent_counts = get(state.world, :messages_sent_this_round, %{})
      player_sent = Map.get(sent_counts, sender_id, %{})
      round_count = Map.get(player_sent, round, 0) + 1
      updated_sent = Map.put(sent_counts, sender_id, Map.put(player_sent, round, round_count))

      next_world =
        state.world
        |> Map.put(:message_log, updated_log)
        |> Map.put(:messages_sent_this_round, updated_sent)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.message_delivered(sender_id, recipient_id, content))

      {:ok, next_state, {:decide, "#{sender_id} sent a message to #{recipient_id}, continue communication"}}
    else
      {:error, reason} ->
        reject_action(state, event, sender_id, reason)
    end
  end

  # -- End Communication --

  defp apply_end_communication(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communication"),
         :ok <- ensure_active_actor(state.world, player_id) do
      comm_done = get(state.world, :communication_done, MapSet.new())
      comm_done = MapSet.put(comm_done, player_id)

      next_world = Map.put(state.world, :communication_done, comm_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.communication_ended(player_id))

      all_player_ids = Map.keys(get(next_world, :players, %{}))
      all_done = Enum.all?(all_player_ids, &MapSet.member?(comm_done, &1))

      if all_done do
        next_world2 =
          next_world
          |> Map.put(:phase, "analysis")
          |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
          |> Map.put(:analysis_done, MapSet.new())

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("communication", "analysis"))

        {:ok, next_state2,
         {:decide,
          "all players finished communication, now in analysis phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, comm_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished communication, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Submit Analysis --

  defp apply_submit_analysis(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    notes = fetch(event.payload, :notes, "notes", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "analysis"),
         :ok <- ensure_active_actor(state.world, player_id) do
      analysis_done = get(state.world, :analysis_done, MapSet.new())
      analysis_done = MapSet.put(analysis_done, player_id)

      # Store notes privately
      analysis_notes = get(state.world, :analysis_notes, %{})
      updated_notes = Map.put(analysis_notes, player_id, notes)

      next_world =
        state.world
        |> Map.put(:analysis_done, analysis_done)
        |> Map.put(:analysis_notes, updated_notes)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.analysis_submitted(player_id))

      all_player_ids = Map.keys(get(next_world, :players, %{}))
      all_done = Enum.all?(all_player_ids, &MapSet.member?(analysis_done, &1))

      if all_done do
        next_world2 =
          next_world
          |> Map.put(:phase, "operation")
          |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
          |> Map.put(:operations_done, MapSet.new())

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("analysis", "operation"))

        {:ok, next_state2,
         {:decide,
          "all players finished analysis, now in operation phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, analysis_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished analysis, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Propose Operation --

  defp apply_propose_operation(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    operation_type = fetch(event.payload, :operation_type, "operation_type")
    target_id = fetch(event.payload, :target_id, "target_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "operation"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_operation_type(operation_type),
         :ok <- ensure_valid_operation_target(state.world, player_id, operation_type, target_id) do
      round = get(state.world, :round, 1)
      operations_log = get(state.world, :operations_log, [])

      result = execute_operation(state.world, player_id, operation_type, target_id)

      op_entry = %{
        round: round,
        player_id: player_id,
        operation_type: operation_type,
        target_id: target_id,
        result: result
      }

      next_world =
        apply_operation_effects(state.world, player_id, operation_type, target_id, result)
        |> Map.put(:operations_log, operations_log ++ [op_entry])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(
          Events.operation_completed(player_id, operation_type, target_id, result)
        )

      {:ok, next_state,
       {:decide, "#{player_id} performed #{operation_type} on #{inspect(target_id)}, continue or end operations"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- End Operations --

  defp apply_end_operations(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "operation"),
         :ok <- ensure_active_actor(state.world, player_id) do
      operations_done = get(state.world, :operations_done, MapSet.new())
      operations_done = MapSet.put(operations_done, player_id)

      next_world = Map.put(state.world, :operations_done, operations_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      all_player_ids = Map.keys(get(next_world, :players, %{}))
      all_done = Enum.all?(all_player_ids, &MapSet.member?(operations_done, &1))

      if all_done do
        # Transition to mole_action phase — only the mole acts here
        mole_id = find_mole_id(next_world)

        next_world2 =
          next_world
          |> Map.put(:phase, "mole_action")
          |> Map.put(:active_actor_id, mole_id)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("operation", "mole_action"))

        {:ok, next_state2,
         {:decide,
          "all players finished operations, now mole_action phase for #{mole_id}"}}
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, operations_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished operations, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Mole Action (Hidden) --

  defp apply_mole_action(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    action_type = fetch(event.payload, :action_type, "action_type")
    target_id = fetch(event.payload, :target_id, "target_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "mole_action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_is_mole(state.world, player_id),
         :ok <- ensure_valid_mole_action(action_type) do
      {next_world, mole_events} =
        apply_mole_effects(state.world, player_id, action_type, target_id)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_events(mole_events)

      # After mole acts, advance the round
      {final_world, round_events} = advance_round(next_world)
      {final_world, game_events} = check_victory(final_world)

      next_state2 =
        next_state
        |> State.update_world(fn _ -> final_world end)
        |> State.append_events(round_events)
        |> State.append_events(game_events)

      if get(final_world, :status, "in_progress") != "in_progress" do
        {:ok, next_state2, :skip}
      else
        {:ok, next_state2,
         {:decide,
          "round #{get(final_world, :round, 1)} intel_briefing phase for #{MapHelpers.get_key(final_world, :active_actor_id)}"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Operation Execution --

  defp execute_operation(world, player_id, "share_intel", target_id) do
    adjacency = get(world, :adjacency, %{})
    players = get(world, :players, %{})
    player = Map.get(players, player_id, %{})
    fragments = get(player, :intel_fragments, [])

    cond do
      not NetworkGraph.adjacent?(adjacency, player_id, target_id) ->
        "failed: not adjacent"

      fragments == [] ->
        "failed: no intel to share"

      true ->
        "shared intel with #{target_id}"
    end
  end

  defp execute_operation(world, player_id, "relay_message", target_id) do
    adjacency = get(world, :adjacency, %{})

    if NetworkGraph.adjacent?(adjacency, player_id, target_id) do
      "relayed message through #{player_id} to #{target_id}"
    else
      "failed: not adjacent"
    end
  end

  defp execute_operation(world, player_id, "verify_agent", target_id) do
    adjacency = get(world, :adjacency, %{})
    players = get(world, :players, %{})
    target = Map.get(players, target_id, %{})

    cond do
      not NetworkGraph.adjacent?(adjacency, player_id, target_id) ->
        "failed: not adjacent"

      get(target, :status, "active") != "active" ->
        "failed: agent not active"

      true ->
        # Verification reveals role with 70% accuracy (simplified to always reveal correctly)
        role = get(target, :role, "operative")
        "verification complete: #{target_id} appears #{role}"
    end
  end

  defp execute_operation(world, player_id, "report_suspicion", target_id) do
    adjacency = get(world, :adjacency, %{})

    if NetworkGraph.adjacent?(adjacency, player_id, target_id) do
      "suspicion reported: #{target_id} flagged by #{player_id}"
    else
      "failed: not adjacent (can only report adjacent agents)"
    end
  end

  defp execute_operation(_world, _player_id, _op, _target_id), do: "failed: unknown operation"

  defp apply_operation_effects(world, player_id, "share_intel", target_id, result) do
    if String.starts_with?(result, "shared") do
      players = get(world, :players, %{})
      player = Map.get(players, player_id, %{})
      fragments = get(player, :intel_fragments, [])

      case fragments do
        [] ->
          world

        [fragment | _] ->
          target = Map.get(players, target_id, %{})
          target_fragments = get(target, :intel_fragments, [])

          updated_target =
            if fragment in target_fragments do
              target
            else
              Map.put(target, :intel_fragments, target_fragments ++ [fragment])
            end

          Map.put(world, :players, Map.put(players, target_id, updated_target))
      end
    else
      world
    end
  end

  defp apply_operation_effects(world, player_id, "report_suspicion", target_id, result) do
    if String.starts_with?(result, "suspicion") do
      suspicion_board = get(world, :suspicion_board, %{})
      reports = Map.get(suspicion_board, target_id, [])
      updated = Map.put(suspicion_board, target_id, reports ++ [player_id])
      Map.put(world, :suspicion_board, updated)
    else
      world
    end
  end

  defp apply_operation_effects(world, _player_id, _op, _target_id, _result), do: world

  # -- Mole Effects --

  defp apply_mole_effects(world, mole_id, "leak_intel", _target_id) do
    players = get(world, :players, %{})
    mole = Map.get(players, mole_id, %{})
    mole_fragments = get(mole, :intel_fragments, [])

    case mole_fragments do
      [] ->
        {world, [Events.mole_passed(mole_id)]}

      [fragment | _] ->
        leaked = get(world, :leaked_intel, [])
        next_world = Map.put(world, :leaked_intel, leaked ++ [fragment])
        {next_world, [Events.intel_leaked(mole_id, fragment)]}
    end
  end

  defp apply_mole_effects(world, mole_id, "frame_agent", target_id) when is_binary(target_id) do
    suspicion_board = get(world, :suspicion_board, %{})
    reports = Map.get(suspicion_board, target_id, [])
    # Framing adds a false report attributed to an adjacent operative
    players = get(world, :players, %{})
    adjacency = get(world, :adjacency, %{})
    neighbors = NetworkGraph.local_view(adjacency, mole_id)

    # Pick a neighbor operative to falsely attribute this to
    false_reporter =
      neighbors
      |> Enum.filter(fn n ->
        p = Map.get(players, n, %{})
        get(p, :role, "operative") == "operative"
      end)
      |> List.first()

    if false_reporter do
      updated = Map.put(suspicion_board, target_id, reports ++ [false_reporter])
      {Map.put(world, :suspicion_board, updated), [Events.agent_framed(mole_id, target_id)]}
    else
      {world, [Events.mole_passed(mole_id)]}
    end
  end

  defp apply_mole_effects(world, mole_id, "pass", _target_id) do
    {world, [Events.mole_passed(mole_id)]}
  end

  defp apply_mole_effects(world, mole_id, _action, _target_id) do
    {world, [Events.mole_passed(mole_id)]}
  end

  # -- Round Advancement --

  defp advance_round(world) do
    round = get(world, :round, 1) + 1
    turn_order = get(world, :turn_order, [])
    first_player = List.first(turn_order)

    # Issue new briefing intel for the new round
    {world_with_briefings, briefing_events} = issue_briefings(world, round)

    next_world =
      world_with_briefings
      |> Map.put(:round, round)
      |> Map.put(:phase, "intel_briefing")
      |> Map.put(:active_actor_id, first_player)
      |> Map.put(:communication_done, MapSet.new())
      |> Map.put(:analysis_done, MapSet.new())
      |> Map.put(:operations_done, MapSet.new())
      |> Map.put(:messages_sent_this_round, %{})
      |> Map.put(:briefing_done, MapSet.new())

    all_events =
      briefing_events ++
        [Events.phase_changed("mole_action", "intel_briefing"), Events.round_advanced(round)]

    {next_world, all_events}
  end

  defp issue_briefings(world, round) do
    # Distribute a new round of intel fragments
    players = get(world, :players, %{})
    intel_pool = get(world, :intel_pool, [])

    # Each player gets one new fragment per round if the pool has any
    {updated_players, events} =
      Enum.reduce(Map.keys(players), {players, []}, fn player_id, {p_acc, e_acc} ->
        fragment_index = length(get(world, :operations_log, [])) + round - 1
        fragment_id = Enum.at(intel_pool, rem(fragment_index * 17 + :erlang.phash2(player_id), max(length(intel_pool), 1)))

        if is_binary(fragment_id) do
          player = Map.get(p_acc, player_id, %{})
          existing = get(player, :intel_fragments, [])

          if fragment_id in existing do
            {p_acc, e_acc}
          else
            updated_player = Map.put(player, :intel_fragments, existing ++ [fragment_id])
            {Map.put(p_acc, player_id, updated_player),
             e_acc ++ [Events.briefing_received(player_id, fragment_id)]}
          end
        else
          {p_acc, e_acc}
        end
      end)

    {Map.put(world, :players, updated_players), events}
  end

  # -- Victory Check --

  defp check_victory(world) do
    max_rounds = get(world, :max_rounds, 8)
    round = get(world, :round, 1)
    leaked_intel = get(world, :leaked_intel, [])
    suspicion_board = get(world, :suspicion_board, %{})
    mole_id = find_mole_id(world)

    cond do
      # Mole leaks threshold
      length(leaked_intel) >= @leak_threshold ->
        final_world =
          world
          |> Map.put(:status, "won")
          |> Map.put(:winner, mole_id)

        {final_world, [Events.game_over("mole_leaked_enough", mole_id)]}

      # Final round: check if loyalists identified the mole
      round > max_rounds ->
        mole_votes = Map.get(suspicion_board, mole_id, [])
        total_players = map_size(get(world, :players, %{}))
        majority = div(total_players, 2) + 1

        if length(mole_votes) >= majority do
          # Loyalists win
          {winner_faction} = {"loyalists"}

          final_world =
            world
            |> Map.put(:status, "won")
            |> Map.put(:winner, winner_faction)

          {final_world, [Events.game_over("mole_identified", winner_faction)]}
        else
          # Mole survives
          final_world =
            world
            |> Map.put(:status, "won")
            |> Map.put(:winner, mole_id)

          {final_world, [Events.game_over("mole_survived", mole_id)]}
        end

      true ->
        {world, []}
    end
  end

  # -- Helpers --

  defp find_mole_id(world) do
    players = get(world, :players, %{})

    case Enum.find(players, fn {_id, p} -> get(p, :role, "operative") == "mole" end) do
      {id, _} -> id
      nil -> List.first(Map.keys(players))
    end
  end

  defp advance_to_next_player(world, current_player, done_set) do
    turn_order = get(world, :turn_order, [])
    all_ids = Map.keys(get(world, :players, %{}))

    remaining =
      turn_order
      |> Enum.filter(&(&1 in all_ids))
      |> Enum.reject(&MapSet.member?(done_set, &1))

    next_player =
      case remaining do
        [] -> current_player
        [first | _] -> first
      end

    next_world = Map.put(world, :active_actor_id, next_player)
    {next_world, []}
  end

  # -- Validation --

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :game_over}
  end

  defp ensure_phase(world, expected_phase) do
    if get(world, :phase, nil) == expected_phase,
      do: :ok,
      else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, player_id) do
    if MapHelpers.get_key(world, :active_actor_id) == player_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp ensure_valid_player(world, player_id) do
    players = get(world, :players, %{})

    if Map.has_key?(players, player_id),
      do: :ok,
      else: {:error, :invalid_player}
  end

  defp ensure_different(a, b) do
    if a != b, do: :ok, else: {:error, :cannot_target_self}
  end

  defp ensure_adjacent(world, a, b) do
    adjacency = get(world, :adjacency, %{})

    if NetworkGraph.adjacent?(adjacency, a, b),
      do: :ok,
      else: {:error, :not_adjacent}
  end

  defp ensure_message_quota(world, player_id) do
    round = get(world, :round, 1)
    sent_counts = get(world, :messages_sent_this_round, %{})
    player_sent = Map.get(sent_counts, player_id, %{})
    count = Map.get(player_sent, round, 0)

    if count < @max_messages_per_round,
      do: :ok,
      else: {:error, :message_quota_exceeded}
  end

  defp ensure_valid_operation_type(op)
       when op in ["share_intel", "relay_message", "verify_agent", "report_suspicion"],
       do: :ok

  defp ensure_valid_operation_type(_), do: {:error, :invalid_operation_type}

  defp ensure_valid_operation_target(world, player_id, operation_type, target_id) do
    adjacency = get(world, :adjacency, %{})
    players = get(world, :players, %{})

    cond do
      operation_type in ["share_intel", "relay_message", "verify_agent", "report_suspicion"] ->
        cond do
          not is_binary(target_id) ->
            {:error, :invalid_target}

          not Map.has_key?(players, target_id) ->
            {:error, :invalid_player}

          target_id == player_id ->
            {:error, :cannot_target_self}

          not NetworkGraph.adjacent?(adjacency, player_id, target_id) ->
            {:error, :not_adjacent}

          true ->
            :ok
        end

      true ->
        :ok
    end
  end

  defp ensure_is_mole(world, player_id) do
    players = get(world, :players, %{})
    player = Map.get(players, player_id, %{})

    if get(player, :role, "operative") == "mole",
      do: :ok,
      else: {:error, :not_the_mole}
  end

  defp ensure_valid_mole_action(action) when action in ["leak_intel", "frame_agent", "pass"],
    do: :ok

  defp ensure_valid_mole_action(_), do: {:error, :invalid_mole_action}

  # -- Error handling --

  defp reject_action(%State{} = state, event, player_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(event.kind, to_string(player_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:wrong_phase), do: "wrong phase for this action"
  defp rejection_reason(:not_active_actor), do: "not the active player"
  defp rejection_reason(:invalid_player), do: "invalid player id"
  defp rejection_reason(:cannot_target_self), do: "cannot target yourself"
  defp rejection_reason(:not_adjacent), do: "target is not adjacent in the network"
  defp rejection_reason(:message_quota_exceeded), do: "message quota exceeded (max 2 per round)"
  defp rejection_reason(:invalid_operation_type), do: "invalid operation type"
  defp rejection_reason(:invalid_target), do: "invalid target"
  defp rejection_reason(:not_the_mole), do: "only the mole can perform this action"
  defp rejection_reason(:invalid_mole_action), do: "invalid mole action (use leak_intel/frame_agent/pass)"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  # -- Utility --

  defp edge_key(a, b) do
    [a, b] |> Enum.sort() |> Enum.join("--")
  end
end
