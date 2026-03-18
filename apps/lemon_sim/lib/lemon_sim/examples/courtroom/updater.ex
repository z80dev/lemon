defmodule LemonSim.Examples.Courtroom.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.Courtroom.Events

  @phases [
    "opening_statements",
    "prosecution_case",
    "cross_examination",
    "defense_case",
    "defense_cross",
    "closing_arguments",
    "deliberation",
    "verdict"
  ]

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "make_statement" -> apply_make_statement(state, event)
      "call_witness" -> apply_call_witness(state, event)
      "ask_question" -> apply_ask_question(state, event)
      "present_evidence" -> apply_present_evidence(state, event)
      "object" -> apply_object(state, event)
      "challenge_testimony" -> apply_challenge_testimony(state, event)
      "jury_discuss" -> apply_jury_discuss(state, event)
      "take_note" -> apply_take_note(state, event)
      "cast_verdict" -> apply_cast_verdict(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Make Statement (opening/closing) --

  defp apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement", "")

    valid_phases = ["opening_statements", "closing_arguments"]

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, valid_phases),
         :ok <- ensure_active_actor(state.world, player_id) do
      phase = get(state.world, :phase)
      testimony_log = get(state.world, :testimony_log, [])

      entry = %{
        "phase" => phase,
        "player_id" => player_id,
        "type" => "statement",
        "content" => statement
      }

      next_world =
        state.world
        |> Map.put(:testimony_log, testimony_log ++ [entry])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.statement_recorded(player_id, phase, statement))

      {next_world2, advance_events} = advance_turn_or_phase(next_world, player_id)

      next_state2 =
        next_state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_events(advance_events)

      {:ok, next_state2,
       {:decide, "#{player_id} made a statement, next: #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Call Witness --

  defp apply_call_witness(%State{} = state, event) do
    caller_id = fetch(event.payload, :caller_id, "caller_id")
    witness_id = fetch(event.payload, :witness_id, "witness_id")

    valid_phases = ["prosecution_case", "defense_case"]

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, valid_phases),
         :ok <- ensure_active_actor(state.world, caller_id),
         :ok <- ensure_valid_witness(state.world, witness_id) do
      next_world = Map.put(state.world, :current_witness_id, witness_id)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.witness_called(caller_id, witness_id))

      {:ok, next_state, {:decide, "#{caller_id} called witness #{witness_id}"}}
    else
      {:error, reason} ->
        reject_action(state, event, caller_id, reason)
    end
  end

  # -- Ask Question --

  defp apply_ask_question(%State{} = state, event) do
    asker_id = fetch(event.payload, :asker_id, "asker_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    question = fetch(event.payload, :question, "question", "")

    valid_phases = ["prosecution_case", "cross_examination", "defense_case", "defense_cross"]

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, valid_phases),
         :ok <- ensure_active_actor(state.world, asker_id),
         :ok <- ensure_valid_target_player(state.world, target_id) do
      phase = get(state.world, :phase)
      testimony_log = get(state.world, :testimony_log, [])

      entry = %{
        "phase" => phase,
        "asker_id" => asker_id,
        "target_id" => target_id,
        "type" => "question",
        "content" => question
      }

      next_world = Map.put(state.world, :testimony_log, testimony_log ++ [entry])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.question_answered(asker_id, target_id, question))

      {next_world2, advance_events} = advance_turn_or_phase(next_world, asker_id)

      next_state2 =
        next_state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_events(advance_events)

      {:ok, next_state2,
       {:decide, "#{asker_id} questioned #{target_id}, next: #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
    else
      {:error, reason} ->
        reject_action(state, event, asker_id, reason)
    end
  end

  # -- Present Evidence --

  defp apply_present_evidence(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    evidence_id = fetch(event.payload, :evidence_id, "evidence_id")

    valid_phases = ["prosecution_case", "defense_case"]

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, valid_phases),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_evidence(state.world, evidence_id) do
      evidence_presented = get(state.world, :evidence_presented, [])

      next_world =
        if evidence_id in evidence_presented do
          state.world
        else
          Map.put(state.world, :evidence_presented, evidence_presented ++ [evidence_id])
        end

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.evidence_admitted(player_id, evidence_id))

      {:ok, next_state, {:decide, "#{player_id} presented evidence: #{evidence_id}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Object --

  defp apply_object(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    reason = fetch(event.payload, :reason, "reason", "")

    valid_phases = [
      "prosecution_case",
      "cross_examination",
      "defense_case",
      "defense_cross"
    ]

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, valid_phases),
         :ok <- ensure_valid_player(state.world, player_id) do
      objections = get(state.world, :objections, [])
      # Simple rule: objections are sustained if reason is longer and articulate
      ruling = if String.length(reason) > 20, do: "sustained", else: "overruled"

      new_objection = %{
        "player_id" => player_id,
        "reason" => reason,
        "ruling" => ruling,
        "phase" => get(state.world, :phase)
      }

      next_world = Map.put(state.world, :objections, objections ++ [new_objection])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.objection_ruled(player_id, reason, ruling))

      {:ok, next_state, {:decide, "#{player_id} objected: #{ruling}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Challenge Testimony --

  defp apply_challenge_testimony(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    witness_id = fetch(event.payload, :witness_id, "witness_id")
    challenge = fetch(event.payload, :challenge, "challenge", "")

    valid_phases = ["cross_examination", "defense_cross"]

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, valid_phases),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_witness(state.world, witness_id) do
      phase = get(state.world, :phase)
      testimony_log = get(state.world, :testimony_log, [])

      entry = %{
        "phase" => phase,
        "player_id" => player_id,
        "witness_id" => witness_id,
        "type" => "challenge",
        "content" => challenge
      }

      next_world = Map.put(state.world, :testimony_log, testimony_log ++ [entry])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.testimony_challenged(player_id, witness_id))

      {next_world2, advance_events} = advance_turn_or_phase(next_world, player_id)

      next_state2 =
        next_state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_events(advance_events)

      {:ok, next_state2,
       {:decide, "#{player_id} challenged #{witness_id}'s testimony"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Jury Discuss --

  defp apply_jury_discuss(%State{} = state, event) do
    juror_id = fetch(event.payload, :juror_id, "juror_id")
    argument = fetch(event.payload, :argument, "argument", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "deliberation"),
         :ok <- ensure_active_actor(state.world, juror_id),
         :ok <- ensure_is_juror(state.world, juror_id) do
      next_state =
        state
        |> State.append_event(event)
        |> State.append_event(Events.juror_discussed(juror_id, argument))

      {next_world2, advance_events} = advance_turn_or_phase(state.world, juror_id)

      next_state2 =
        next_state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_events(advance_events)

      {:ok, next_state2,
       {:decide, "#{juror_id} discussed in deliberation, next: #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
    else
      {:error, reason} ->
        reject_action(state, event, juror_id, reason)
    end
  end

  # -- Take Note --

  defp apply_take_note(%State{} = state, event) do
    juror_id = fetch(event.payload, :juror_id, "juror_id")
    note = fetch(event.payload, :note, "note", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "deliberation"),
         :ok <- ensure_is_juror(state.world, juror_id) do
      jury_notes = get(state.world, :jury_notes, %{})
      juror_notes = Map.get(jury_notes, juror_id, [])
      updated_notes = Map.put(jury_notes, juror_id, juror_notes ++ [note])

      next_world = Map.put(state.world, :jury_notes, updated_notes)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.juror_noted(juror_id, note))

      {:ok, next_state, {:decide, "#{juror_id} took a note"}}
    else
      {:error, reason} ->
        reject_action(state, event, juror_id, reason)
    end
  end

  # -- Cast Verdict --

  defp apply_cast_verdict(%State{} = state, event) do
    juror_id = fetch(event.payload, :juror_id, "juror_id")
    vote = fetch(event.payload, :vote, "vote", "not_guilty")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "verdict"),
         :ok <- ensure_active_actor(state.world, juror_id),
         :ok <- ensure_is_juror(state.world, juror_id),
         :ok <- ensure_valid_vote(vote),
         :ok <- ensure_not_voted(state.world, juror_id) do
      verdict_votes = get(state.world, :verdict_votes, %{})
      updated_votes = Map.put(verdict_votes, juror_id, vote)

      next_world = Map.put(state.world, :verdict_votes, updated_votes)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.verdict_cast(juror_id, vote))

      # Check if all jurors have voted
      juror_ids = juror_player_ids(next_world)
      all_voted = Enum.all?(juror_ids, &Map.has_key?(updated_votes, &1))

      if all_voted do
        {final_world, result_events} = resolve_verdict(next_world, updated_votes)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> final_world end)
          |> State.append_events(result_events)

        {:ok, next_state2, :skip}
      else
        # Advance to next juror
        {next_world2, advance_events} = advance_to_next_juror(next_world, juror_id)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_events(advance_events)

        {:ok, next_state2,
         {:decide, "#{juror_id} voted #{vote}, awaiting remaining jurors"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, juror_id, reason)
    end
  end

  # -- Verdict resolution --

  defp resolve_verdict(world, votes) do
    guilty_count = votes |> Map.values() |> Enum.count(&(&1 == "guilty"))
    not_guilty_count = votes |> Map.values() |> Enum.count(&(&1 == "not_guilty"))
    total = map_size(votes)
    majority = div(total, 2) + 1

    outcome =
      cond do
        guilty_count >= majority -> "guilty"
        not_guilty_count >= majority -> "not_guilty"
        true -> "hung_jury"
      end

    # Prosecution wins on guilty, defense wins otherwise
    winner =
      cond do
        outcome == "guilty" -> get_prosecution_id(world)
        true -> get_defense_id(world)
      end

    final_world =
      world
      |> Map.put(:status, "complete")
      |> Map.put(:winner, winner)
      |> Map.put(:outcome, outcome)

    events = [
      Events.verdict_reached(outcome, votes),
      Events.game_over(outcome, winner)
    ]

    {final_world, events}
  end

  # -- Phase advancement --

  defp advance_turn_or_phase(world, current_actor_id) do
    phase = get(world, :phase)
    turn_order = get(world, :turn_order, [])
    actors_in_phase = get(world, :actors_in_phase, turn_order)

    done_set = get(world, :phase_done, MapSet.new())
    done_set = MapSet.put(done_set, current_actor_id)

    remaining =
      actors_in_phase
      |> Enum.reject(&MapSet.member?(done_set, &1))

    case remaining do
      [] ->
        # All actors done — advance to next phase
        {next_world, events} = advance_phase(world, phase)
        {Map.put(next_world, :phase_done, MapSet.new()), events}

      [next | _] ->
        next_world =
          world
          |> Map.put(:active_actor_id, next)
          |> Map.put(:phase_done, done_set)

        {next_world, []}
    end
  end

  defp advance_phase(world, current_phase) do
    next_phase = next_phase_after(current_phase)

    case next_phase do
      nil ->
        # Should not happen — verdict handles game over separately
        {world, []}

      phase ->
        actors = actors_for_phase(world, phase)

        next_world =
          world
          |> Map.put(:phase, phase)
          |> Map.put(:actors_in_phase, actors)
          |> Map.put(:active_actor_id, List.first(actors))
          |> Map.put(:phase_done, MapSet.new())
          |> Map.put(:current_witness_id, nil)

        {next_world, [Events.phase_changed(current_phase, phase)]}
    end
  end

  defp next_phase_after(phase) do
    idx = Enum.find_index(@phases, &(&1 == phase))

    if idx && idx + 1 < length(@phases) do
      Enum.at(@phases, idx + 1)
    else
      nil
    end
  end

  defp actors_for_phase(world, phase) do
    players = get(world, :players, %{})

    case phase do
      p when p in ["opening_statements", "closing_arguments"] ->
        [get_prosecution_id(world), get_defense_id(world)]
        |> Enum.reject(&is_nil/1)

      "prosecution_case" ->
        [get_prosecution_id(world)] |> Enum.reject(&is_nil/1)

      "cross_examination" ->
        [get_defense_id(world)] |> Enum.reject(&is_nil/1)

      "defense_case" ->
        [get_defense_id(world)] |> Enum.reject(&is_nil/1)

      "defense_cross" ->
        [get_prosecution_id(world)] |> Enum.reject(&is_nil/1)

      "deliberation" ->
        players
        |> Enum.filter(fn {_id, info} -> get(info, :role) == "juror" end)
        |> Enum.map(fn {id, _} -> id end)
        |> Enum.sort()

      "verdict" ->
        juror_player_ids(world)

      _ ->
        []
    end
  end

  defp advance_to_next_juror(world, current_juror_id) do
    juror_ids = juror_player_ids(world)
    verdict_votes = get(world, :verdict_votes, %{})

    remaining =
      juror_ids
      |> Enum.reject(&Map.has_key?(verdict_votes, &1))
      |> Enum.reject(&(&1 == current_juror_id))

    case remaining do
      [] ->
        {world, []}

      [next | _] ->
        {Map.put(world, :active_actor_id, next), []}
    end
  end

  # -- Player helpers --

  defp get_prosecution_id(world) do
    players = get(world, :players, %{})

    players
    |> Enum.find_value(fn {id, info} ->
      if get(info, :role) == "prosecution", do: id, else: nil
    end)
  end

  defp get_defense_id(world) do
    players = get(world, :players, %{})

    players
    |> Enum.find_value(fn {id, info} ->
      if get(info, :role) == "defense", do: id, else: nil
    end)
  end

  defp juror_player_ids(world) do
    players = get(world, :players, %{})

    players
    |> Enum.filter(fn {_id, info} -> get(info, :role) == "juror" end)
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.sort()
  end

  # -- Validation --

  defp ensure_in_progress(world) do
    if get(world, :status) == "in_progress",
      do: :ok,
      else: {:error, :game_over}
  end

  defp ensure_phase(world, expected_phase) do
    if get(world, :phase) == expected_phase,
      do: :ok,
      else: {:error, :wrong_phase}
  end

  defp ensure_phase_in(world, phases) do
    if get(world, :phase) in phases,
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

  defp ensure_valid_witness(world, witness_id) do
    players = get(world, :players, %{})

    case Map.get(players, witness_id) do
      nil -> {:error, :invalid_player}
      info -> if get(info, :role) == "witness", do: :ok, else: {:error, :not_a_witness}
    end
  end

  defp ensure_valid_target_player(world, target_id) do
    players = get(world, :players, %{})

    if Map.has_key?(players, target_id),
      do: :ok,
      else: {:error, :invalid_player}
  end

  defp ensure_valid_evidence(world, evidence_id) do
    case_file = get(world, :case_file, %{})
    evidence_list = get(case_file, :evidence_list, [])

    if evidence_id in evidence_list,
      do: :ok,
      else: {:error, :invalid_evidence}
  end

  defp ensure_is_juror(world, player_id) do
    players = get(world, :players, %{})

    case Map.get(players, player_id) do
      nil -> {:error, :invalid_player}
      info -> if get(info, :role) == "juror", do: :ok, else: {:error, :not_a_juror}
    end
  end

  defp ensure_valid_vote(vote) when vote in ["guilty", "not_guilty"], do: :ok
  defp ensure_valid_vote(_), do: {:error, :invalid_vote}

  defp ensure_not_voted(world, juror_id) do
    verdict_votes = get(world, :verdict_votes, %{})

    if Map.has_key?(verdict_votes, juror_id),
      do: {:error, :already_voted},
      else: :ok
  end

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

  defp rejection_reason(:game_over), do: "trial already concluded"
  defp rejection_reason(:wrong_phase), do: "wrong phase for this action"
  defp rejection_reason(:not_active_actor), do: "not the active actor"
  defp rejection_reason(:invalid_player), do: "invalid player id"
  defp rejection_reason(:not_a_witness), do: "that player is not a witness"
  defp rejection_reason(:not_a_juror), do: "that player is not a juror"
  defp rejection_reason(:invalid_evidence), do: "that evidence item does not exist in the case file"
  defp rejection_reason(:invalid_vote), do: "invalid vote (use guilty or not_guilty)"
  defp rejection_reason(:already_voted), do: "you have already cast your verdict"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"
end
