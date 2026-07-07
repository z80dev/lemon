defmodule LemonSim.Examples.SpaceStation.Updaters.RoundResolution do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers
  import LemonSim.Examples.SpaceStation.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.SpaceStation.{Events, Roles}
  alias LemonSim.Examples.SpaceStation.Updaters.Clues
  alias LemonSim.Examples.SpaceStation.Updaters.Crises

  @repair_min 10
  @repair_max 22
  @sabotage_min 8
  @sabotage_max 18

  # -- Round resolution --
  # Apply system decay, apply player actions, check win conditions

  def resolve_round(%State{} = state) do
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
    noisy_systems = Crises.apply_crisis_effects(noisy_systems, state.world)

    # Step 2: Apply player actions to systems
    # Only 1 repair per system takes effect per round (cap prevents "verified pair = 100%" strategy)
    {resolved_systems, _repaired_set} =
      Enum.reduce(action_log, {noisy_systems, MapSet.new()}, fn {_player_id, action_entry},
                                                                {acc_systems, repaired} ->
        action = get_action_field(action_entry, :action)
        system_id = get_action_field(action_entry, :system)

        case action do
          "repair" when is_binary(system_id) ->
            if MapSet.member?(repaired, system_id) do
              # Second repair on same system this round — no effect
              {acc_systems, repaired}
            else
              repair_amt = Enum.random(@repair_min..@repair_max)

              {apply_system_change(acc_systems, system_id, repair_amt),
               MapSet.put(repaired, system_id)}
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
    {state, clue_events} = Clues.generate_and_distribute_clues(state, action_log, players, round)
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
