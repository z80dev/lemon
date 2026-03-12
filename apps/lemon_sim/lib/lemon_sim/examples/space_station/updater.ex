defmodule LemonSim.Examples.SpaceStation.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers

  alias LemonSim.State
  alias LemonSim.Examples.SpaceStation.{Events, Roles}

  @repair_amount 20
  @sabotage_amount 25
  @max_health 100

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "repair_system" -> apply_repair_system(state, event)
      "sabotage_system" -> apply_sabotage_system(state, event)
      "fake_repair" -> apply_fake_repair(state, event)
      "scan_player" -> apply_scan_player(state, event)
      "lock_room" -> apply_lock_room(state, event)
      "call_emergency_meeting" -> apply_call_emergency_meeting(state, event)
      "vent" -> apply_vent(state, event)
      "make_statement" -> apply_make_statement(state, event)
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

      scan_result_text =
        case last_action do
          "sabotage" -> "sabotaged"
          "fake_repair" -> "sabotaged"
          "repair" -> "repaired"
          "vent" -> "unknown"
          nil -> "no_previous_action"
          _ -> "repaired"
        end

      scan_results =
        state.world
        |> get(:scan_results, %{})
        |> Map.put(player_id, %{target: target_id, result: scan_result_text})

      action_log =
        state.world
        |> get(:action_log, %{})
        |> Map.put(player_id, %{system: "scanner", action: "scan", target: target_id})

      # Engineer scanning is not tied to a system location; show as "scanner"
      location_log = get(state.world, :location_log, []) ++ [{player_id, "scanner"}]

      updated_players = put_player_field(players, player_id, :location, "scanner")
      updated_players = put_player_field(updated_players, player_id, :last_action, "scan")

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

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{votes: votes}))
        |> State.append_event(event)

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

    # Step 2: Apply player actions to systems
    resolved_systems =
      Enum.reduce(action_log, decayed_systems, fn {_player_id, action_entry}, acc_systems ->
        action = get_action_field(action_entry, :action)
        system_id = get_action_field(action_entry, :system)

        case action do
          "repair" when is_binary(system_id) ->
            apply_system_change(acc_systems, system_id, @repair_amount)

          "sabotage" when is_binary(system_id) ->
            apply_system_change(acc_systems, system_id, -@sabotage_amount)

          # fake_repair, vent, scan, lock, emergency_meeting -- no system effect
          _ ->
            acc_systems
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

    round_report = build_round_report(state.world, players, system_changes, round)
    action_history = get(state.world, :action_history, [])

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
          emergency_meeting_called: false
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

    if not is_nil(ejected_id) and get(Map.get(players, ejected_id, %{}), :role) == "saboteur" do
      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
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
      if round >= get(state.world, :max_rounds, 8) do
        # Game over: crew survived
        game_over_events = [
          Events.game_over("crew", "The crew survived all #{round} rounds! The station is saved!")
        ]

        next_state =
          state
          |> State.put_world(
            world_updates(state.world, %{
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
          state,
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
          emergency_meeting_called: false
        })
      )
      |> State.append_events(preceding_events ++ [Events.phase_changed("action", round)])

    {:ok, next_state, {:decide, "#{first_actor} action"}}
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

  defp build_round_report(world, players, system_changes, round) do
    visible_visits =
      world
      |> get(:location_log, [])
      |> Enum.map(fn {player_id, system_id} -> %{player: player_id, system: system_id} end)

    visible_ids = MapSet.new(Enum.map(visible_visits, &get(&1, :player)))

    unseen_players =
      players
      |> Roles.living_players()
      |> Enum.map(fn {player_id, _player} -> player_id end)
      |> Enum.reject(&MapSet.member?(visible_ids, &1))

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
      visible_visits: visible_visits,
      unseen_players: unseen_players,
      critical_systems: critical_systems,
      captain_lock: get(world, :captain_lock),
      emergency_called: get(world, :emergency_meeting_called, false),
      system_changes: system_changes
    }
  end
end
