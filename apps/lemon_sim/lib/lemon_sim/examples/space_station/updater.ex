defmodule LemonSim.Examples.SpaceStation.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers

  alias LemonSim.State
  alias LemonSim.Examples.SpaceStation.{Events, Roles}

  @repair_min 10
  @repair_max 22
  @sabotage_min 8
  @sabotage_max 18
  @max_health 100

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    # Extract and store thought if present
    state = maybe_store_thought(state, event)

    case event.kind do
      "repair_system" -> apply_repair_system(state, event)
      "sabotage_system" -> apply_sabotage_system(state, event)
      "fake_repair" -> apply_fake_repair(state, event)
      "scan_player" -> apply_scan_player(state, event)
      "lock_room" -> apply_lock_room(state, event)
      "call_emergency_meeting" -> apply_call_emergency_meeting(state, event)
      "vent" -> apply_vent(state, event)
      "make_statement" -> apply_make_statement(state, event)
      "ask_question" -> apply_ask_question(state, event)
      "accuse" -> apply_accuse(state, event)
      "cast_vote" -> apply_cast_vote(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Action: Repair system --

  defp apply_repair_system(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    system_id = fetch(event.payload, :system_id, "system_id")
    players = get(state.world, :players, %{})
    systems = get(state.world, :systems, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_valid_system(systems, system_id) do
      # Record action (private) and location (public)
      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: system_id, action: "repair"})

      location_log = get(state.world, :location_log, []) ++ [{player_id, system_id}]

      # Update player location
      updated_players = put_player_field(players, player_id, :location, system_id)
      updated_players = put_player_field(updated_players, player_id, :last_action, "repair")

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            action_log: action_log,
            location_log: location_log,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Repaired the #{system_display_name(system_id)} system.")
        |> adjust_reputation(player_id, 5)

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Sabotage system (saboteur only) --

  defp apply_sabotage_system(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    system_id = fetch(event.payload, :system_id, "system_id")
    players = get(state.world, :players, %{})
    systems = get(state.world, :systems, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "saboteur"),
         :ok <- ensure_valid_system(systems, system_id),
         :ok <- ensure_not_locked(state.world, system_id) do
      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: system_id, action: "sabotage"})

      location_log = get(state.world, :location_log, []) ++ [{player_id, system_id}]

      updated_players = put_player_field(players, player_id, :location, system_id)
      updated_players = put_player_field(updated_players, player_id, :last_action, "sabotage")

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            action_log: action_log,
            location_log: location_log,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Sabotaged the #{system_display_name(system_id)} system. No one seemed to notice.")

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Fake repair (saboteur only) --

  defp apply_fake_repair(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    system_id = fetch(event.payload, :system_id, "system_id")
    players = get(state.world, :players, %{})
    systems = get(state.world, :systems, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "saboteur"),
         :ok <- ensure_valid_system(systems, system_id) do
      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: system_id, action: "fake_repair"})

      location_log = get(state.world, :location_log, []) ++ [{player_id, system_id}]

      updated_players = put_player_field(players, player_id, :location, system_id)
      updated_players = put_player_field(updated_players, player_id, :last_action, "fake_repair")

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            action_log: action_log,
            location_log: location_log,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Pretended to repair #{system_display_name(system_id)}. Keeping up appearances.")

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Scan player (engineer only) --

  defp apply_scan_player(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "engineer"),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
      # Look up the target's last action from the previous round
      target_player = Map.get(players, target_id, %{})
      last_action = get(target_player, :last_action)

      # Scans are imperfect — 25% chance of incorrect reading due to station interference
      raw_result =
        case last_action do
          "sabotage" -> "sabotaged"
          "fake_repair" -> "sabotaged"
          "repair" -> "repaired"
          "vent" -> "unknown"
          nil -> "no_previous_action"
          _ -> "repaired"
        end

      scan_result_text =
        if raw_result in ["sabotaged", "repaired"] and :rand.uniform(4) == 1 do
          # 25% false reading — flip the result (reduced from 40% to make scans more useful)
          if raw_result == "sabotaged", do: "repaired", else: "sabotaged"
        else
          raw_result
        end

      scan_results =
        state.world
        |> get(:scan_results, %{})
        |> Map.put(player_id, %{target: target_id, result: scan_result_text})

      # Engineer appears at a random system for cover (hides scanning activity)
      cover_system = Enum.random(~w(o2 power hull comms nav medbay shields))

      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: cover_system, action: "scan", target: target_id})

      location_log = get(state.world, :location_log, []) ++ [{player_id, cover_system}]

      updated_players = put_player_field(players, player_id, :location, cover_system)
      updated_players = put_player_field(updated_players, player_id, :last_action, "scan")

      target_name = get(Map.get(players, target_id, %{}), :name, target_id)

      scan_journal =
        case scan_result_text do
          "sabotaged" -> "Scanned #{target_name} — readings suggest sabotage activity."
          "repaired" -> "Scanned #{target_name} — readings look clean."
          "no_previous_action" -> "Scanned #{target_name} — no prior activity to analyze."
          _ -> "Scanned #{target_name} — readings were inconclusive."
        end

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            action_log: action_log,
            location_log: location_log,
            scan_results: scan_results,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> State.append_event(Events.scan_result(player_id, target_id, scan_result_text))
        |> add_journal_entry(player_id, scan_journal)

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Lock room (captain only) --

  defp apply_lock_room(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    system_id = fetch(event.payload, :system_id, "system_id")
    players = get(state.world, :players, %{})
    systems = get(state.world, :systems, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "captain"),
         :ok <- ensure_valid_system(systems, system_id) do
      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: system_id, action: "lock"})

      location_log = get(state.world, :location_log, []) ++ [{player_id, system_id}]

      updated_players = put_player_field(players, player_id, :location, system_id)
      updated_players = put_player_field(updated_players, player_id, :last_action, "lock")

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            captain_lock: system_id,
            action_log: action_log,
            location_log: location_log,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Locked down #{system_display_name(system_id)} to prevent sabotage.")

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Call emergency meeting (captain only) --

  defp apply_call_emergency_meeting(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "captain"),
         :ok <- ensure_emergency_available(state.world) do
      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: nil, action: "emergency_meeting"})

      updated_players = put_player_field(players, player_id, :last_action, "emergency_meeting")

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            emergency_meeting_available: false,
            emergency_meeting_called: true,
            action_log: action_log,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Called an emergency meeting. Something doesn't feel right.")

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Vent (saboteur only) --

  defp apply_vent(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "action"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "saboteur") do
      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: nil, action: "vent"})

      # Venting: no location entry (invisible this round)
      updated_players = put_player_field(players, player_id, :location, nil)
      updated_players = put_player_field(updated_players, player_id, :last_action, "vent")

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            action_log: action_log,
            players: updated_players
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Used the vents to move unseen. Risky, but necessary.")

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Discussion: Make statement --

  defp apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: player_id, statement: statement}
      new_transcript = transcript ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{discussion_transcript: new_transcript}))
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Discussion: Ask question --

  defp apply_ask_question(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    question = fetch(event.payload, :question, "question")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id) do
      transcript = get(state.world, :discussion_transcript, [])

      new_entry = %{
        player: player_id,
        type: "question",
        target: target_id,
        statement: question
      }

      new_transcript = transcript ++ [new_entry]

      # Track pending questions so targets know they should respond
      pending_questions = get(state.world, :pending_questions, [])
      new_pending = pending_questions ++ [%{from: player_id, to: target_id, question: question}]

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            pending_questions: new_pending
          })
        )
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Discussion: Accuse --

  defp apply_accuse(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    evidence = fetch(event.payload, :evidence, "evidence")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id) do
      transcript = get(state.world, :discussion_transcript, [])

      new_entry = %{
        player: player_id,
        type: "accusation",
        target: target_id,
        statement: evidence
      }

      new_transcript = transcript ++ [new_entry]

      # Track accusations for the UI and agent awareness
      accusations = get(state.world, :accusations, [])
      new_accusations = accusations ++ [%{accuser: player_id, accused: target_id, evidence: evidence}]

      target_name = get(Map.get(players, target_id, %{}), :name, target_id)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            accusations: new_accusations
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(player_id, "Formally accused #{target_name}. I believe they're the saboteur.")
        |> adjust_reputation(target_id, -2)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Voting: Cast vote --

  defp apply_cast_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "voting"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_valid_vote_target(players, player_id, target_id) do
      votes =
        state.world
        |> get(:votes, %{})
        |> Map.put(player_id, target_id)

      vote_journal =
        if target_id == "skip" do
          "Decided to skip the vote. Not enough evidence to eject anyone."
        else
          target_name = get(Map.get(players, target_id, %{}), :name, target_id)
          "Voted to eject #{target_name}."
        end

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{votes: votes}))
        |> State.append_event(event)
        |> add_journal_entry(player_id, vote_journal)

      advance_voting_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Turn advancement --

  defp advance_action_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All players have acted; resolve the round
        resolve_round(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} action"}}
    end
  end

  defp advance_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)
    discussion_round = get(state.world, :discussion_round, 1)
    discussion_round_limit = get(state.world, :discussion_round_limit, 1)
    round = get(state.world, :round, 1)
    players = get(state.world, :players, %{})

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        if discussion_round < discussion_round_limit do
          next_round = discussion_round + 1
          next_turn_order = Roles.discussion_turn_order(players, round, next_round)
          first_speaker = List.first(next_turn_order)

          next_state =
            State.put_world(
              state,
              world_updates(state.world, %{
                discussion_round: next_round,
                turn_order: next_turn_order,
                active_actor_id: first_speaker
              })
            )

          {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
        else
          transition_to_voting(state)
        end

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} discussion turn"}}
    end
  end

  defp advance_voting_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All votes cast; resolve
        resolve_votes(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} vote"}}
    end
  end

  # -- Round resolution --
  # Apply system decay, apply player actions, check win conditions

  defp resolve_round(%State{} = state) do
    action_log = get(state.world, :action_log, %{})
    systems = get(state.world, :systems, %{})
    players = get(state.world, :players, %{})
    round = get(state.world, :round, 1)
    saboteur_ejected = Roles.saboteur_ejected?(players)
    emergency_called = get(state.world, :emergency_meeting_called, false)

    # Step 1: Apply system decay (skip if saboteur is ejected)
    decayed_systems =
      if saboteur_ejected do
        # Halve decay rates when saboteur is gone
        Enum.into(systems, %{}, fn {sys_id, sys} ->
          decay = get(sys, :decay_rate, 0)
          half_decay = div(decay, 2)
          health = get(sys, :health, 100)
          new_health = max(0, health - half_decay)
          {sys_id, Map.put(sys, :health, new_health)}
        end)
      else
        Enum.into(systems, %{}, fn {sys_id, sys} ->
          decay = get(sys, :decay_rate, 0)
          health = get(sys, :health, 100)
          new_health = max(0, health - decay)
          {sys_id, Map.put(sys, :health, new_health)}
        end)
      end

    # Step 1.5: Environmental noise — random system perturbations each round
    {noisy_systems, environmental_events} = apply_environmental_noise(decayed_systems, round)

    # Step 1.75: Apply crisis effects
    noisy_systems = apply_crisis_effects(noisy_systems, state.world)

    # Step 2: Apply player actions to systems
    # Only 1 repair per system takes effect per round (cap prevents "verified pair = 100%" strategy)
    {resolved_systems, _repaired_set} =
      Enum.reduce(action_log, {noisy_systems, MapSet.new()}, fn {_player_id, action_entry}, {acc_systems, repaired} ->
        action = get_action_field(action_entry, :action)
        system_id = get_action_field(action_entry, :system)

        case action do
          "repair" when is_binary(system_id) ->
            if MapSet.member?(repaired, system_id) do
              # Second repair on same system this round — no effect
              {acc_systems, repaired}
            else
              repair_amt = Enum.random(@repair_min..@repair_max)
              {apply_system_change(acc_systems, system_id, repair_amt), MapSet.put(repaired, system_id)}
            end

          "sabotage" when is_binary(system_id) ->
            sabotage_amt = Enum.random(@sabotage_min..@sabotage_max)
            {apply_system_change(acc_systems, system_id, -sabotage_amt), repaired}

          # fake_repair, vent, scan, lock, emergency_meeting -- no system effect
          _ ->
            {acc_systems, repaired}
        end
      end)

    # Build system changes report
    system_changes =
      Enum.into(resolved_systems, %{}, fn {sys_id, sys} ->
        old_sys = Map.get(systems, sys_id, %{})
        old_health = get(old_sys, :health, 100)
        new_health = get(sys, :health, 100)
        name = get(sys, :name, sys_id)

        {sys_id,
         %{
           name: name,
           old_health: old_health,
           new_health: new_health,
           delta: new_health - old_health
         }}
      end)

    round_report = build_round_report(state.world, system_changes, round, environmental_events)
    action_history = get(state.world, :action_history, [])

    # Emit environmental events so players see them in recent events
    env_game_events =
      Enum.map(environmental_events, fn evt ->
        Events.environmental_event(
          get(evt, :system, Map.get(evt, "system", "unknown")),
          get(evt, :damage, Map.get(evt, "damage", 0)),
          get(evt, :description, Map.get(evt, "description", "System anomaly"))
        )
      end)

    state = State.append_events(state, env_game_events)

    # Step 3: Generate clues from this round's actions and distribute to players
    {state, clue_events} = generate_and_distribute_clues(state, action_log, players, round)
    state = State.append_events(state, clue_events)

    # Check if any system reached 0 (station destroyed)
    station_destroyed =
      Enum.any?(resolved_systems, fn {_id, sys} -> get(sys, :health, 100) <= 0 end)

    # Check win conditions
    cond do
      station_destroyed ->
        end_game_station_destroyed(
          state,
          resolved_systems,
          system_changes,
          round,
          round_report,
          action_history,
          action_log
        )

      round >= get(state.world, :max_rounds, 8) and not emergency_called ->
        # Crew survived all rounds!
        end_game_crew_survived(
          state,
          resolved_systems,
          system_changes,
          round,
          round_report,
          action_history,
          action_log
        )

      emergency_called ->
        # Emergency meeting: skip report, go to discussion
        transition_to_discussion_after_round(
          state,
          resolved_systems,
          system_changes,
          round,
          true,
          round_report,
          action_history,
          action_log
        )

      true ->
        # Normal: go to report, then discussion, then voting
        transition_to_discussion_after_round(
          state,
          resolved_systems,
          system_changes,
          round,
          false,
          round_report,
          action_history,
          action_log
        )
    end
  end

  defp end_game_station_destroyed(
         state,
         resolved_systems,
         system_changes,
         round,
         round_report,
         action_history,
         action_log
       ) do
    destroyed_system =
      resolved_systems
      |> Enum.find(fn {_id, sys} -> get(sys, :health, 100) <= 0 end)
      |> case do
        {sys_id, sys} -> "#{get(sys, :name, sys_id)} (#{sys_id})"
        nil -> "unknown system"
      end

    game_over_events = [
      Events.round_resolved(system_changes, round),
      Events.game_over(
        "saboteur",
        "The station is destroyed! #{destroyed_system} has failed. The saboteur wins!"
      )
    ]

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          systems: resolved_systems,
          round_reports: get(state.world, :round_reports, []) ++ [round_report],
          action_history: action_history ++ [%{round: round, actions: action_log}],
          status: "game_over",
          winner: "saboteur",
          phase: "game_over",
          active_actor_id: nil,
          turn_order: []
        })
      )
      |> State.append_events(game_over_events)

    {:ok, next_state, :skip}
  end

  defp end_game_crew_survived(
         state,
         resolved_systems,
         system_changes,
         round,
         round_report,
         action_history,
         action_log
       ) do
    game_over_events = [
      Events.round_resolved(system_changes, round),
      Events.game_over("crew", "The crew survived all #{round} rounds! The station is saved!")
    ]

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          systems: resolved_systems,
          round_reports: get(state.world, :round_reports, []) ++ [round_report],
          action_history: action_history ++ [%{round: round, actions: action_log}],
          status: "game_over",
          winner: "crew",
          phase: "game_over",
          active_actor_id: nil,
          turn_order: []
        })
      )
      |> State.append_events(game_over_events)

    {:ok, next_state, :skip}
  end

  defp transition_to_discussion_after_round(
         state,
         resolved_systems,
         system_changes,
         round,
         _emergency,
         round_report,
         action_history,
         action_log
       ) do
    players = get(state.world, :players, %{})
    discussion_order = Roles.discussion_turn_order(players, round, 1)
    first_speaker = List.first(discussion_order)
    discussion_round_limit = Roles.discussion_round_limit(players)

    round_events = [
      Events.round_resolved(system_changes, round),
      Events.phase_changed("discussion", round)
    ]

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          systems: resolved_systems,
          phase: "discussion",
          discussion_transcript: [],
          round_reports: get(state.world, :round_reports, []) ++ [round_report],
          action_history: action_history ++ [%{round: round, actions: action_log}],
          votes: %{},
          discussion_round: 1,
          discussion_round_limit: discussion_round_limit,
          turn_order: discussion_order,
          active_actor_id: first_speaker,
          emergency_meeting_called: false,
          pending_questions: [],
          accusations: []
        })
      )
      |> State.append_events(round_events)

    {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
  end

  # -- Vote resolution --

  defp resolve_votes(%State{} = state) do
    votes = get(state.world, :votes, %{})
    players = get(state.world, :players, %{})
    round = get(state.world, :round, 1)

    # Tally votes (exclude "skip")
    vote_tally =
      votes
      |> Enum.reject(fn {_voter, target} -> target == "skip" end)
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    # Find the player with the most votes
    living_count = length(Roles.living_players(players))
    majority_threshold = div(living_count, 2) + 1

    {ejected_id, _count} =
      vote_tally
      |> Enum.max_by(fn {_target, count} -> count end, fn -> {nil, 0} end)

    ejected_id =
      if not is_nil(ejected_id) and Map.get(vote_tally, ejected_id, 0) >= majority_threshold do
        ejected_id
      else
        nil
      end

    # Apply ejection
    updated_players =
      if not is_nil(ejected_id) do
        victim = Map.get(players, ejected_id, %{})
        Map.put(players, ejected_id, Map.put(victim, :status, "ejected"))
      else
        players
      end

    # Build events
    vote_events = [Events.vote_result(ejected_id, vote_tally)]

    ejection_events =
      if not is_nil(ejected_id) do
        victim_role = get(Map.get(players, ejected_id, %{}), :role, "unknown")
        [Events.player_ejected(ejected_id, victim_role)]
      else
        []
      end

    # Update elimination log
    elimination_log = get(state.world, :elimination_log, [])

    new_elimination_log =
      if not is_nil(ejected_id) do
        victim_role = get(Map.get(players, ejected_id, %{}), :role, "unknown")

        elimination_log ++
          [
            %{
              player: ejected_id,
              role: victim_role,
              reason: "ejected",
              round: get(state.world, :round, 1)
            }
          ]
      else
        elimination_log
      end

    vote_history =
      get(state.world, :vote_history, []) ++
        [
          %{
            round: round,
            votes: votes,
            vote_tally: vote_tally,
            ejected: ejected_id
          }
        ]

    # Apply reputation changes based on ejection result
    state_with_rep =
      if not is_nil(ejected_id) do
        victim_role = get(Map.get(players, ejected_id, %{}), :role, "unknown")
        ejected_name = get(Map.get(players, ejected_id, %{}), :name, ejected_id)

        # Journal entries for all living players about the ejection
        living_ids = Roles.living_players(players) |> Enum.map(fn {id, _p} -> id end)

        state_after_journals =
          Enum.reduce(living_ids, state, fn pid, acc ->
            if pid == ejected_id do
              acc
            else
              add_journal_entry(acc, pid, "#{ejected_name} was ejected. They were #{victim_role}.")
            end
          end)

        if victim_role == "saboteur" do
          # Correct ejection: +10 for voters who voted for the saboteur
          # +15 for captain if emergency meeting was called this game
          Enum.reduce(votes, state_after_journals, fn {voter_id, target}, acc ->
            if target == ejected_id do
              adjust_reputation(acc, voter_id, 10)
            else
              acc
            end
          end)
        else
          # Wrong ejection: -5 for voters who voted for a crew member
          Enum.reduce(votes, state_after_journals, fn {voter_id, target}, acc ->
            if target == ejected_id do
              adjust_reputation(acc, voter_id, -5)
            else
              acc
            end
          end)
        end
      else
        state
      end

    if not is_nil(ejected_id) and get(Map.get(players, ejected_id, %{}), :role) == "saboteur" do
      next_state =
        state_with_rep
        |> State.put_world(
          world_updates(state_with_rep.world, %{
            players: updated_players,
            votes: %{},
            vote_history: vote_history,
            elimination_log: new_elimination_log,
            status: "game_over",
            winner: "crew",
            phase: "game_over",
            active_actor_id: nil,
            turn_order: []
          })
        )
        |> State.append_events(
          vote_events ++
            ejection_events ++
            [Events.game_over("crew", "The crew ejected the saboteur. The station is safe!")]
        )

      {:ok, next_state, :skip}
    else
      # Check if crew survived all rounds after this vote
      # (last round vote happens, then game ends)
      if round >= get(state_with_rep.world, :max_rounds, 8) do
        # Game over: crew survived
        game_over_events = [
          Events.game_over("crew", "The crew survived all #{round} rounds! The station is saved!")
        ]

        next_state =
          state_with_rep
          |> State.put_world(
            world_updates(state_with_rep.world, %{
              players: updated_players,
              votes: %{},
              vote_history: vote_history,
              elimination_log: new_elimination_log,
              status: "game_over",
              winner: "crew",
              phase: "game_over",
              active_actor_id: nil,
              turn_order: []
            })
          )
          |> State.append_events(vote_events ++ ejection_events ++ game_over_events)

        {:ok, next_state, :skip}
      else
        transition_to_next_round(
          state_with_rep,
          updated_players,
          new_elimination_log,
          vote_history,
          vote_events ++ ejection_events
        )
      end
    end
  end

  # -- Phase transitions --

  defp transition_to_voting(%State{} = state) do
    players = get(state.world, :players, %{})
    round = get(state.world, :round, 1)
    voting_order = Roles.voting_turn_order(players, round)
    first_voter = List.first(voting_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "voting",
          votes: %{},
          discussion_round: 0,
          discussion_round_limit: 0,
          turn_order: voting_order,
          active_actor_id: first_voter
        })
      )
      |> State.append_event(Events.phase_changed("voting", round))

    {:ok, next_state, {:decide, "#{first_voter} vote"}}
  end

  defp transition_to_next_round(
         %State{} = state,
         players,
         elimination_log,
         vote_history,
         preceding_events
       ) do
    round = get(state.world, :round, 1) + 1
    action_order = Roles.action_turn_order(players, round)
    first_actor = List.first(action_order)

    # Generate crisis for rounds 3, 5, 7
    {active_crisis, crisis_events} =
      if round in [3, 5, 7] do
        crisis = generate_crisis(round, state.world)
        {crisis, [Events.crisis_triggered(crisis)]}
      else
        {nil, []}
      end

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          players: players,
          phase: "action",
          round: round,
          action_log: %{},
          location_log: [],
          discussion_transcript: [],
          vote_history: vote_history,
          votes: %{},
          discussion_round: 0,
          discussion_round_limit: 0,
          turn_order: action_order,
          active_actor_id: first_actor,
          elimination_log: elimination_log,
          captain_lock: nil,
          scan_results: %{},
          emergency_meeting_called: false,
          active_crisis: active_crisis,
          pending_questions: [],
          accusations: []
        })
      )
      |> State.append_events(
        preceding_events ++ crisis_events ++ [Events.phase_changed("action", round)]
      )

    {:ok, next_state, {:decide, "#{first_actor} action"}}
  end

  # -- Journal helpers --

  defp add_journal_entry(state, player_id, text) do
    journals = get(state.world, :journals, %{})
    player_journal = Map.get(journals, player_id, [])

    entry = %{
      round: get(state.world, :round, 1),
      phase: get(state.world, :phase),
      text: text
    }

    new_journals = Map.put(journals, player_id, player_journal ++ [entry])
    State.put_world(state, world_updates(state.world, %{journals: new_journals}))
  end

  # -- Reputation helpers --

  defp adjust_reputation(state, player_id, delta) do
    players = get(state.world, :players, %{})

    case Map.get(players, player_id) do
      nil ->
        state

      player ->
        current = get(player, :reputation, 0)
        new_rep = max(-100, min(100, current + delta))
        updated_players = Map.put(players, player_id, Map.put(player, :reputation, new_rep))
        State.put_world(state, world_updates(state.world, %{players: updated_players}))
    end
  end

  # -- Helpers --

  defp apply_system_change(systems, system_id, delta) do
    sys_key = normalize_system_key(systems, system_id)

    case Map.get(systems, sys_key) do
      nil ->
        systems

      sys ->
        health = get(sys, :health, 100)
        new_health = min(@max_health, max(0, health + delta))
        Map.put(systems, sys_key, Map.put(sys, :health, new_health))
    end
  end

  defp normalize_system_key(systems, system_id) do
    cond do
      Map.has_key?(systems, system_id) ->
        system_id

      is_binary(system_id) and Map.has_key?(systems, String.to_existing_atom(system_id)) ->
        String.to_existing_atom(system_id)

      true ->
        system_id
    end
  rescue
    ArgumentError -> system_id
  end

  defp put_player_field(players, player_id, field, value) do
    case Map.get(players, player_id) do
      nil -> players
      player -> Map.put(players, player_id, Map.put(player, field, value))
    end
  end

  defp get_action_field(action_entry, key) when is_map(action_entry) do
    Map.get(action_entry, key, Map.get(action_entry, Atom.to_string(key)))
  end

  defp get_action_field(_, _), do: nil

  defp ensure_valid_system(systems, system_id) do
    sys_key = normalize_system_key(systems, system_id)

    if Map.has_key?(systems, sys_key), do: :ok, else: {:error, :invalid_system}
  end

  defp ensure_not_locked(world, system_id) do
    captain_lock = get(world, :captain_lock, nil)

    if captain_lock == system_id do
      {:error, :system_locked}
    else
      :ok
    end
  end

  defp ensure_emergency_available(world) do
    if get(world, :emergency_meeting_available, true),
      do: :ok,
      else: {:error, :emergency_used}
  end

  # -- Environmental noise --
  # Random system perturbations each round to prevent deterministic math

  defp apply_environmental_noise(systems, _round) do
    # Light environmental damage — enough to add uncertainty but not swamp signal
    # Only 3-4 random systems take minor damage each round (not all 7)
    affected_count = Enum.random(3..4)

    affected_systems =
      systems
      |> Map.keys()
      |> Enum.shuffle()
      |> Enum.take(affected_count)

    Enum.reduce(systems, {systems, []}, fn {sys_id, _sys_data}, {acc_sys, acc_events} ->
      if sys_id in affected_systems do
        damage = Enum.random(0..5)

        if damage > 0 do
          sys = Map.get(acc_sys, sys_id, %{})
          health = get(sys, :health, 100)
          new_health = max(0, health - damage)
          desc = environmental_event_description(sys_id, damage)

          {
            Map.put(acc_sys, sys_id, Map.put(sys, :health, new_health)),
            acc_events ++ [%{system: sys_id, damage: damage, description: desc}]
          }
        else
          {acc_sys, acc_events}
        end
      else
        {acc_sys, acc_events}
      end
    end)
  end

  defp environmental_event_description(_system_id, _damage) do
    # Deliberately vague — players should NOT know which systems were hit or by how much
    generic = [
      "Environmental sensors detected anomalous readings across the station",
      "Station systems experienced minor perturbations from external conditions",
      "Automated damage-control routines activated for routine hazard mitigation",
      "Deep-space radiation spike affected station subsystems",
      "Micro-debris field contact — damage-control protocols engaged",
      "Thermal fluctuation detected in station infrastructure"
    ]

    Enum.random(generic)
  end

  # -- Clue generation --
  # After each round, generate evidence based on actual actions and distribute to random players

  defp generate_and_distribute_clues(state, action_log, players, round) do
    living = Roles.living_players(players) |> Enum.map(fn {id, _p} -> id end)

    # Build pool of possible clues from this round's actions
    clue_pool =
      action_log
      |> Enum.flat_map(fn {player_id, action_entry} ->
        action = get_action_field(action_entry, :action)
        system_id = get_action_field(action_entry, :system)
        build_clues_for_action(player_id, action, system_id, players)
      end)

    # Select 2-3 clues to distribute
    clue_count = min(length(clue_pool), Enum.random(2..3))
    selected_clues = clue_pool |> Enum.shuffle() |> Enum.take(clue_count)

    # Distribute each clue to a random living player (not the actor)
    {updated_clues, clue_events, clue_recipients} =
      Enum.reduce(selected_clues, {get(state.world, :clues, %{}), [], []}, fn clue, {acc_clues, acc_events, acc_recipients} ->
        actor_id = Map.get(clue, :about_player)
        eligible = Enum.reject(living, &(&1 == actor_id))

        case eligible do
          [] ->
            {acc_clues, acc_events, acc_recipients}

          recipients ->
            recipient = Enum.random(recipients)
            clue_with_round = Map.put(clue, :round, round)

            player_clues = Map.get(acc_clues, recipient, [])
            updated = Map.put(acc_clues, recipient, player_clues ++ [clue_with_round])

            event = Events.clue_found(recipient, clue_with_round)
            clue_type = Map.get(clue, :type, "evidence")
            {updated, acc_events ++ [event], acc_recipients ++ [{recipient, clue_type}]}
        end
      end)

    updated_state =
      State.put_world(state, world_updates(state.world, %{clues: updated_clues}))

    # Add journal entries for clue recipients
    updated_state =
      Enum.reduce(clue_recipients, updated_state, fn {recipient, clue_type}, acc ->
        add_journal_entry(acc, recipient, "Found a clue: #{clue_type} evidence noted.")
      end)

    {updated_state, clue_events}
  end

  defp build_clues_for_action(player_id, action, system_id, _players) do
    system_name = system_display_name(system_id)

    case action do
      "repair" ->
        [
          Enum.random([
            %{
              type: "tool_marks",
              text: "You notice fresh tool marks and repair residue on the #{system_name} system.",
              about_player: player_id
            },
            %{
              type: "sound",
              text: "You heard the distinctive hum of repair equipment coming from #{system_name} this round.",
              about_player: player_id
            }
          ])
        ]

      "sabotage" ->
        [
          Enum.random([
            %{
              type: "damage_evidence",
              text: "You spot scorch marks and deliberate cuts on the #{system_name} system — this doesn't look like normal wear.",
              about_player: player_id
            },
            %{
              type: "suspicious_activity",
              text: "A security camera near #{system_name} captured a blurred figure working hastily, unlike normal repair posture.",
              about_player: player_id
            },
            %{
              type: "chemical_residue",
              text: "You detect an unusual chemical residue near the #{system_name} system — consistent with deliberate interference.",
              about_player: player_id
            }
          ])
        ]

      "fake_repair" ->
        [
          %{
            type: "incomplete_work",
            text: "The #{system_name} system shows signs someone was there, but no actual repairs were completed.",
            about_player: player_id
          }
        ]

      "vent" ->
        [
          %{
            type: "vent_noise",
            text: "You heard unusual sounds from the ventilation system — someone might be moving through the ducts.",
            about_player: player_id
          }
        ]

      "scan" ->
        [
          %{
            type: "scanner_activity",
            text: "You noticed a brief spike in the station's bio-scanner array. Someone used the scanning equipment.",
            about_player: player_id
          }
        ]

      _ ->
        []
    end
  end

  # -- Crisis generation and effects --

  @crisis_types [:cascade_failure, :power_surge, :lockdown, :hull_breach]

  defp generate_crisis(round, world) do
    systems = get(world, :systems, %{})
    system_ids = Map.keys(systems) |> Enum.map(&to_string/1)

    # Pick a crisis type, cycling through to avoid repeats
    crisis_type = Enum.at(@crisis_types, rem(round, length(@crisis_types)))

    case crisis_type do
      :cascade_failure ->
        [sys_a, sys_b] = system_ids |> Enum.shuffle() |> Enum.take(2)
        name_a = system_display_name(sys_a)
        name_b = system_display_name(sys_b)

        %{
          type: "cascade_failure",
          name: "Cascade Failure",
          linked_systems: [sys_a, sys_b],
          threshold: 40,
          extra_damage: 12,
          description:
            "WARNING: #{name_a} and #{name_b} systems are linked through a shared conduit. " <>
              "If either drops below 40 health, the other takes 12 extra damage!",
          announcement:
            "CRISIS ALERT: Cascade failure detected! #{name_a} and #{name_b} are linked — " <>
              "if either drops below 40 HP, the other takes 12 damage."
        }

      :power_surge ->
        [victim, beneficiary] = system_ids |> Enum.shuffle() |> Enum.take(2)
        victim_name = system_display_name(victim)
        beneficiary_name = system_display_name(beneficiary)
        surge_damage = Enum.random(15..25)
        surge_repair = Enum.random(10..15)

        %{
          type: "power_surge",
          name: "Power Surge",
          victim_system: victim,
          beneficiary_system: beneficiary,
          surge_damage: surge_damage,
          surge_repair: surge_repair,
          description:
            "A power surge is routing energy away from #{victim_name} (-#{surge_damage} HP) " <>
              "and overcharging #{beneficiary_name} (+#{surge_repair} HP). " <>
              "Prioritize repairing #{victim_name} this round!",
          announcement:
            "CRISIS ALERT: Power surge! #{victim_name} takes #{surge_damage} damage, " <>
              "#{beneficiary_name} gains #{surge_repair} health."
        }

      :lockdown ->
        %{
          type: "lockdown",
          name: "Security Lockdown",
          description:
            "Station security lockdown activated! All crew locations will be revealed at the end of this round. " <>
              "Everyone can see where everyone went.",
          announcement:
            "CRISIS ALERT: Security lockdown! All player locations will be revealed this round."
        }

      :hull_breach ->
        [sys_a, sys_b] = system_ids |> Enum.shuffle() |> Enum.take(2)
        name_a = system_display_name(sys_a)
        name_b = system_display_name(sys_b)
        breach_damage = 20

        %{
          type: "hull_breach",
          name: "Hull Breach",
          affected_systems: [sys_a, sys_b],
          breach_damage: breach_damage,
          description:
            "Hull breach detected near #{name_a} and #{name_b}! " <>
              "Both systems take #{breach_damage} extra damage unless someone repairs them this round. " <>
              "Any system that receives a repair this round is spared the breach damage.",
          announcement:
            "CRISIS ALERT: Hull breach! #{name_a} and #{name_b} take #{breach_damage} damage " <>
              "unless repaired this round."
        }
    end
  end

  defp apply_crisis_effects(systems, world) do
    crisis = get(world, :active_crisis)
    action_log = get(world, :action_log, %{})

    if is_nil(crisis) do
      systems
    else
      case get(crisis, :type) do
        "cascade_failure" ->
          [sys_a, sys_b] = get(crisis, :linked_systems, [])
          threshold = get(crisis, :threshold, 40)
          extra_damage = get(crisis, :extra_damage, 12)

          health_a = get(Map.get(systems, sys_a, %{}), :health, 100)
          health_b = get(Map.get(systems, sys_b, %{}), :health, 100)

          systems =
            if health_a < threshold do
              apply_system_change(systems, sys_b, -extra_damage)
            else
              systems
            end

          if health_b < threshold do
            apply_system_change(systems, sys_a, -extra_damage)
          else
            systems
          end

        "power_surge" ->
          victim = get(crisis, :victim_system)
          beneficiary = get(crisis, :beneficiary_system)
          damage = get(crisis, :surge_damage, 20)
          repair = get(crisis, :surge_repair, 12)

          systems
          |> apply_system_change(victim, -damage)
          |> apply_system_change(beneficiary, repair)

        "hull_breach" ->
          affected = get(crisis, :affected_systems, [])
          breach_damage = get(crisis, :breach_damage, 20)

          # Systems that received a repair this round are spared
          repaired_systems =
            action_log
            |> Enum.filter(fn {_pid, entry} -> get_action_field(entry, :action) == "repair" end)
            |> Enum.map(fn {_pid, entry} -> get_action_field(entry, :system) end)
            |> MapSet.new()

          Enum.reduce(affected, systems, fn sys_id, acc ->
            if MapSet.member?(repaired_systems, sys_id) do
              acc
            else
              apply_system_change(acc, sys_id, -breach_damage)
            end
          end)

        # Lockdown has no system effect — it's handled in the projector
        _ ->
          systems
      end
    end
  end

  defp system_display_name(nil), do: "unknown"
  defp system_display_name("o2"), do: "Oxygen"
  defp system_display_name("power"), do: "Reactor Power"
  defp system_display_name("hull"), do: "Hull Integrity"
  defp system_display_name("comms"), do: "Communications"
  defp system_display_name("nav"), do: "Navigation"
  defp system_display_name("medbay"), do: "Medical Bay"
  defp system_display_name("shields"), do: "Shield Array"
  defp system_display_name(other), do: other

  defp build_round_report(world, system_changes, round, environmental_events) do
    critical_systems =
      system_changes
      |> Enum.filter(fn {_system_id, change} -> get(change, :new_health, 100) <= 35 end)
      |> Enum.map(fn {system_id, change} ->
        %{
          system_id: system_id,
          name: get(change, :name, system_id),
          health: get(change, :new_health, 100)
        }
      end)

    %{
      round: round,
      critical_systems: critical_systems,
      captain_lock: get(world, :captain_lock),
      emergency_called: get(world, :emergency_meeting_called, false),
      environmental_events: environmental_events
    }
  end
end
