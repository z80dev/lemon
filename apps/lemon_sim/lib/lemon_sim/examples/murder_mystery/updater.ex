defmodule LemonSim.Examples.MurderMystery.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2, reject_action: 4]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.MurderMystery.Events

  @phases ~w(investigation interrogation discussion killer_action deduction_vote)

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "search_room" -> apply_search_room(state, event)
      "ask_player" -> apply_ask_player(state, event)
      "answer_question" -> apply_answer_question(state, event)
      "share_finding" -> apply_discussion(state, event, "finding")
      "make_theory" -> apply_discussion(state, event, "theory")
      "challenge_alibi" -> apply_discussion(state, event, "challenge")
      "end_discussion" -> apply_end_discussion(state, event)
      "plant_evidence" -> apply_plant_evidence(state, event)
      "destroy_clue" -> apply_destroy_clue(state, event)
      "killer_do_nothing" -> apply_killer_do_nothing(state, event)
      "make_accusation" -> apply_make_accusation(state, event)
      "skip_accusation" -> apply_skip_accusation(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Search Room --

  defp apply_search_room(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    room_id = fetch(event.payload, :room_id, "room_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "investigation"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_room(state.world, room_id),
         :ok <- ensure_not_already_searched_this_round(state.world, player_id) do
      rooms = get(state.world, :rooms, %{})
      room = Map.get(rooms, room_id, %{})
      clues_present = get(room, :clues_present, [])

      players = get(state.world, :players, %{})
      player = Map.get(players, player_id, %{})
      current_clues = get(player, :clues_found, [])
      new_clues = Enum.reject(clues_present, &(&1 in current_clues))

      updated_player = Map.put(player, :clues_found, current_clues ++ new_clues)
      updated_room =
        room
        |> Map.put(:searched_by, (get(room, :searched_by, []) ++ [player_id]) |> Enum.uniq())

      updated_players = Map.put(players, player_id, updated_player)
      updated_rooms = Map.put(rooms, room_id, updated_room)

      searched_this_round = get(state.world, :searched_this_round, MapSet.new())
      searched_this_round = MapSet.put(searched_this_round, player_id)

      next_world =
        state.world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:players, updated_players)
        |> Map.put(:searched_this_round, searched_this_round)

      clue_events = Enum.map(new_clues, &Events.clue_found(player_id, room_id, &1))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.room_searched(player_id, room_id))
        |> State.append_events(clue_events)

      {next_world2, prompt} = advance_investigation(next_world, player_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      clue_summary =
        if length(new_clues) > 0 do
          "found #{length(new_clues)} clue(s) in #{room_id}"
        else
          "no new clues in #{room_id}"
        end

      {:ok, next_state2, {:decide, "#{player_id} searched #{room_id}: #{clue_summary}. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Ask Player --

  defp apply_ask_player(%State{} = state, event) do
    asker_id = fetch(event.payload, :asker_id, "asker_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    question = fetch(event.payload, :question, "question", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "interrogation"),
         :ok <- ensure_active_actor(state.world, asker_id),
         :ok <- ensure_valid_player(state.world, target_id),
         :ok <- ensure_different_players(asker_id, target_id),
         :ok <- ensure_not_asked_this_round(state.world, asker_id) do
      asked_this_round = get(state.world, :asked_this_round, MapSet.new())
      asked_this_round = MapSet.put(asked_this_round, asker_id)

      log_entry = %{
        "round" => get(state.world, :round, 1),
        "asker_id" => asker_id,
        "target_id" => target_id,
        "question" => question,
        "answer" => nil
      }

      interrogation_log = get(state.world, :interrogation_log, [])

      next_world =
        state.world
        |> Map.put(:interrogation_log, interrogation_log ++ [log_entry])
        |> Map.put(:asked_this_round, asked_this_round)
        |> Map.put(:active_actor_id, target_id)
        |> Map.put(:pending_question, log_entry)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.question_logged(asker_id, target_id, question))

      {:ok, next_state, {:decide, "#{asker_id} asked #{target_id}: #{question}. #{target_id} must answer."}}
    else
      {:error, reason} ->
        reject_action(state, event, asker_id, reason)
    end
  end

  # -- Answer Question --

  defp apply_answer_question(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    answer = fetch(event.payload, :answer, "answer", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "interrogation"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_pending_question(state.world, player_id) do
      pending = get(state.world, :pending_question, %{})
      question = Map.get(pending, "question", "")
      asker_id = Map.get(pending, "asker_id", "")

      # Update the last log entry with the answer
      interrogation_log = get(state.world, :interrogation_log, [])
      updated_log =
        interrogation_log
        |> Enum.reverse()
        |> case do
          [last | rest] -> [Map.put(last, "answer", answer) | rest]
          [] -> []
        end
        |> Enum.reverse()

      next_world =
        state.world
        |> Map.put(:interrogation_log, updated_log)
        |> Map.put(:pending_question, nil)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.answer_logged(player_id, question, answer))

      {next_world2, prompt} = advance_interrogation(next_world, asker_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, "#{player_id} answered: #{answer}. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Discussion phase --

  defp apply_discussion(%State{} = state, event, disc_type) do
    player_id = fetch(event.payload, :player_id, "player_id")

    content =
      case disc_type do
        "finding" -> fetch(event.payload, :finding, "finding", "")
        "theory" -> fetch(event.payload, :theory, "theory", "")
        "challenge" ->
          target = fetch(event.payload, :target_id, "target_id", "")
          reason = fetch(event.payload, :reason, "reason", "")
          "#{target}: #{reason}"
      end

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id) do
      round = get(state.world, :round, 1)
      discussion_log = get(state.world, :discussion_log, [])

      entry = %{
        "round" => round,
        "player_id" => player_id,
        "type" => disc_type,
        "content" => content
      }

      next_world = Map.put(state.world, :discussion_log, discussion_log ++ [entry])

      turn_order = get(state.world, :turn_order, [])
      next_player = next_in_turn_order(turn_order, player_id)

      {next_world2, prompt} =
        if next_player do
          {Map.put(next_world, :active_actor_id, next_player),
           "#{next_player}'s turn to discuss"}
        else
          # All players had a chance - transition to killer_action
          transition_to_killer_action(next_world)
        end

      next_state =
        state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{player_id} shared #{disc_type}. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_end_discussion(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id) do
      discussion_done = get(state.world, :discussion_done, MapSet.new())
      discussion_done = MapSet.put(discussion_done, player_id)

      next_world = Map.put(state.world, :discussion_done, discussion_done)

      turn_order = get(state.world, :turn_order, [])
      next_player = next_in_turn_order(turn_order, player_id)

      {next_world2, prompt} =
        if next_player do
          {Map.put(next_world, :active_actor_id, next_player),
           "#{next_player}'s turn to discuss"}
        else
          transition_to_killer_action(next_world)
        end

      next_state =
        state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{player_id} ended discussion. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Killer Action --

  defp apply_plant_evidence(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    room_id = fetch(event.payload, :room_id, "room_id")
    clue_type = fetch(event.payload, :clue_type, "clue_type", "fingerprint")

    players = get(state.world, :players, %{})
    player = Map.get(players, player_id, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "killer_action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_room(state.world, room_id),
         :ok <- ensure_is_killer(players, player_id) do
      # Generate a unique clue id
      clue_id = "planted_#{room_id}_#{:erlang.phash2(:erlang.monotonic_time())}"

      # Pick a non-killer to frame
      killer_id = player_id
      non_killers = players |> Map.keys() |> Enum.reject(&(&1 == killer_id))
      points_to = Enum.at(non_killers, rem(System.system_time(:second), max(length(non_killers), 1)))

      new_clue = %{
        clue_id: clue_id,
        clue_type: clue_type,
        room_id: room_id,
        points_to: points_to,
        is_false: true
      }

      rooms = get(state.world, :rooms, %{})
      room = Map.get(rooms, room_id, %{})
      clues_present = get(room, :clues_present, [])
      updated_room = Map.put(room, :clues_present, clues_present ++ [clue_id])
      updated_rooms = Map.put(rooms, room_id, updated_room)

      evidence = get(state.world, :evidence, %{})
      updated_evidence = Map.put(evidence, clue_id, new_clue)

      planted_evidence = get(state.world, :planted_evidence, [])

      next_world =
        state.world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:evidence, updated_evidence)
        |> Map.put(:planted_evidence, planted_evidence ++ [clue_id])

      {next_world2, prompt} = transition_to_deduction(next_world)

      next_state =
        state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_event(event)
        |> State.append_event(Events.evidence_planted(player_id, clue_id))

      {:ok, next_state, {:decide, "#{player_id} planted evidence in #{room_id}. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_destroy_clue(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    room_id = fetch(event.payload, :room_id, "room_id")
    clue_id = fetch(event.payload, :clue_id, "clue_id")

    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "killer_action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_room(state.world, room_id),
         :ok <- ensure_is_killer(players, player_id),
         :ok <- ensure_clue_in_room(state.world, room_id, clue_id) do
      rooms = get(state.world, :rooms, %{})
      room = Map.get(rooms, room_id, %{})
      clues_present = get(room, :clues_present, [])
      updated_room = Map.put(room, :clues_present, List.delete(clues_present, clue_id))
      updated_rooms = Map.put(rooms, room_id, updated_room)

      destroyed_evidence = get(state.world, :destroyed_evidence, [])

      next_world =
        state.world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:destroyed_evidence, destroyed_evidence ++ [clue_id])

      {next_world2, prompt} = transition_to_deduction(next_world)

      next_state =
        state
        |> State.update_world(fn _ -> next_world2 end)
        |> State.append_event(event)
        |> State.append_event(Events.clue_destroyed(player_id, clue_id))

      {:ok, next_state, {:decide, "#{player_id} destroyed clue #{clue_id}. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_killer_do_nothing(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "killer_action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_is_killer(players, player_id) do
      {next_world, prompt} = transition_to_deduction(state.world)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{player_id} took no action. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Make Accusation --

  defp apply_make_accusation(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    accused_id = fetch(event.payload, :accused_id, "accused_id")
    weapon = fetch(event.payload, :weapon, "weapon", "")
    room_id = fetch(event.payload, :room_id, "room_id", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "deduction_vote"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_has_accusations(state.world, player_id) do
      solution = get(state.world, :solution, %{})
      killer_id = get(solution, :killer_id, "")
      solution_weapon = get(solution, :weapon, "")
      solution_room = get(solution, :room_id, "")

      correct =
        accused_id == killer_id and
          weapon == solution_weapon and
          room_id == solution_room

      accusation = %{
        "player_id" => player_id,
        "accused_id" => accused_id,
        "weapon" => weapon,
        "room_id" => room_id,
        "correct" => correct,
        "round" => get(state.world, :round, 1)
      }

      accusations = get(state.world, :accusations, [])

      players = get(state.world, :players, %{})
      player = Map.get(players, player_id, %{})
      acc_remaining = get(player, :accusations_remaining, 1) - 1
      updated_player = Map.put(player, :accusations_remaining, acc_remaining)
      updated_players = Map.put(players, player_id, updated_player)

      next_world =
        state.world
        |> Map.put(:accusations, accusations ++ [accusation])
        |> Map.put(:players, updated_players)

      if correct do
        final_world =
          next_world
          |> Map.put(:status, "won")
          |> Map.put(:winner, "investigators")
          |> Map.put(:winning_player, player_id)

        next_state =
          state
          |> State.update_world(fn _ -> final_world end)
          |> State.append_event(event)
          |> State.append_event(Events.accusation_result(player_id, true, "correct accusation"))
          |> State.append_event(Events.game_over("investigators", "#{player_id} correctly identified the killer"))

        {:ok, next_state, :skip}
      else
        deduction_done = get(next_world, :deduction_done, MapSet.new())
        deduction_done = MapSet.put(deduction_done, player_id)
        next_world2 = Map.put(next_world, :deduction_done, deduction_done)

        next_state =
          state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(event)
          |> State.append_event(Events.accusation_result(player_id, false, "wrong accusation"))

        {next_world3, prompt} = advance_deduction(next_world2, player_id)
        next_state2 = State.update_world(next_state, fn _ -> next_world3 end)

        {:ok, next_state2, {:decide, "#{player_id} made wrong accusation. #{prompt}"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Skip Accusation --

  defp apply_skip_accusation(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "deduction_vote"),
         :ok <- ensure_active_actor(state.world, player_id) do
      deduction_done = get(state.world, :deduction_done, MapSet.new())
      deduction_done = MapSet.put(deduction_done, player_id)
      next_world = Map.put(state.world, :deduction_done, deduction_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {next_world2, prompt} = advance_deduction(next_world, player_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, "#{player_id} skipped accusation. #{prompt}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Phase Transitions --

  defp advance_investigation(world, current_player_id) do
    turn_order = get(world, :turn_order, [])
    next_player = next_in_turn_order(turn_order, current_player_id)

    if next_player do
      {Map.put(world, :active_actor_id, next_player),
       "#{next_player}'s turn to investigate"}
    else
      # Everyone has gone - move to interrogation
      next_world =
        world
        |> Map.put(:phase, "interrogation")
        |> Map.put(:active_actor_id, List.first(turn_order))
        |> Map.put(:asked_this_round, MapSet.new())
        |> Map.put(:pending_question, nil)

      {next_world, "investigation complete, entering interrogation phase"}
    end
  end

  defp advance_interrogation(world, last_asker_id) do
    turn_order = get(world, :turn_order, [])
    asked_this_round = get(world, :asked_this_round, MapSet.new())

    # Find next player who hasn't asked this round
    remaining_askers =
      turn_order
      |> Enum.reject(&MapSet.member?(asked_this_round, &1))

    case remaining_askers do
      [next | _] ->
        {Map.put(world, :active_actor_id, next),
         "#{next}'s turn to ask a question"}

      [] ->
        # All players have asked - move to discussion
        next_world =
          world
          |> Map.put(:phase, "discussion")
          |> Map.put(:active_actor_id, List.first(turn_order))
          |> Map.put(:discussion_done, MapSet.new())

        {next_world, "interrogation complete, entering discussion phase"}
    end
  end

  defp transition_to_killer_action(world) do
    turn_order = get(world, :turn_order, [])
    players = get(world, :players, %{})

    killer_id =
      Enum.find(turn_order, fn pid ->
        player = Map.get(players, pid, %{})
        get(player, :role, "") == "killer"
      end)

    next_world =
      world
      |> Map.put(:phase, "killer_action")
      |> Map.put(:active_actor_id, killer_id || List.first(turn_order))

    {next_world, "discussion complete, killer must now act"}
  end

  defp transition_to_deduction(world) do
    turn_order = get(world, :turn_order, [])

    next_world =
      world
      |> Map.put(:phase, "deduction_vote")
      |> Map.put(:active_actor_id, List.first(turn_order))
      |> Map.put(:deduction_done, MapSet.new())

    {next_world, "entering deduction vote phase"}
  end

  defp advance_deduction(world, current_player_id) do
    turn_order = get(world, :turn_order, [])
    deduction_done = get(world, :deduction_done, MapSet.new())
    round = get(world, :round, 1)
    max_rounds = get(world, :max_rounds, 5)

    all_voted = Enum.all?(turn_order, &MapSet.member?(deduction_done, &1))

    if all_voted do
      if round >= max_rounds do
        # Killer wins - survived all rounds
        solution = get(world, :solution, %{})
        killer_id = get(solution, :killer_id, "unknown")

        final_world =
          world
          |> Map.put(:status, "won")
          |> Map.put(:winner, "killer")

        {final_world, "all rounds complete - killer #{killer_id} wins!"}
      else
        # Advance to next round
        new_round = round + 1

        next_world =
          world
          |> Map.put(:round, new_round)
          |> Map.put(:phase, "investigation")
          |> Map.put(:active_actor_id, List.first(turn_order))
          |> Map.put(:searched_this_round, MapSet.new())
          |> Map.put(:asked_this_round, MapSet.new())
          |> Map.put(:discussion_done, MapSet.new())
          |> Map.put(:deduction_done, MapSet.new())
          |> Map.put(:pending_question, nil)

        {next_world, "round #{new_round} begins - investigation phase"}
      end
    else
      next_player = next_in_turn_order(turn_order, current_player_id)

      remaining =
        turn_order
        |> Enum.reject(&MapSet.member?(deduction_done, &1))

      next_active = case remaining do
        [first | _] -> first
        [] -> List.first(turn_order)
      end

      {Map.put(world, :active_actor_id, next_active),
       "#{next_active}'s turn to vote or accuse"}
    end
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

  defp ensure_valid_room(world, room_id) do
    rooms = get(world, :rooms, %{})
    if Map.has_key?(rooms, room_id), do: :ok, else: {:error, :invalid_room}
  end

  defp ensure_valid_player(world, player_id) do
    players = get(world, :players, %{})
    if Map.has_key?(players, player_id), do: :ok, else: {:error, :invalid_player}
  end

  defp ensure_different_players(id_a, id_b) do
    if id_a != id_b, do: :ok, else: {:error, :cannot_target_self}
  end

  defp ensure_not_already_searched_this_round(world, player_id) do
    searched = get(world, :searched_this_round, MapSet.new())
    if MapSet.member?(searched, player_id),
      do: {:error, :already_searched_this_round},
      else: :ok
  end

  defp ensure_not_asked_this_round(world, player_id) do
    asked = get(world, :asked_this_round, MapSet.new())
    if MapSet.member?(asked, player_id),
      do: {:error, :already_asked_this_round},
      else: :ok
  end

  defp ensure_pending_question(world, player_id) do
    pending = get(world, :pending_question, nil)
    if is_nil(pending),
      do: {:error, :no_pending_question},
      else: :ok
  end

  defp ensure_is_killer(players, player_id) do
    player = Map.get(players, player_id, %{})
    if get(player, :role, "") == "killer",
      do: :ok,
      else: {:error, :only_killer_can_act}
  end

  defp ensure_clue_in_room(world, room_id, clue_id) do
    rooms = get(world, :rooms, %{})
    room = Map.get(rooms, room_id, %{})
    clues_present = get(room, :clues_present, [])
    if clue_id in clues_present, do: :ok, else: {:error, :clue_not_in_room}
  end

  defp ensure_has_accusations(world, player_id) do
    players = get(world, :players, %{})
    player = Map.get(players, player_id, %{})
    acc = get(player, :accusations_remaining, 0)
    if acc > 0, do: :ok, else: {:error, :no_accusations_remaining}
  end

  # -- Helpers --

  defp next_in_turn_order(turn_order, current_id) do
    case Enum.find_index(turn_order, &(&1 == current_id)) do
      nil ->
        nil
      idx ->
        next_idx = idx + 1
        if next_idx < length(turn_order) do
          Enum.at(turn_order, next_idx)
        else
          nil
        end
    end
  end
end
