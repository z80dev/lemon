defmodule LemonSim.Examples.SpaceStation.Updaters.Actions do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers
  import LemonSim.Examples.SpaceStation.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.SpaceStation.Events
  alias LemonSim.Examples.SpaceStation.Updaters.RoundResolution

  # -- Action: Repair system --

  def apply_repair_system(%State{} = state, event) do
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

  def apply_sabotage_system(%State{} = state, event) do
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
        |> add_journal_entry(
          player_id,
          "Sabotaged the #{system_display_name(system_id)} system. No one seemed to notice."
        )

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Fake repair (saboteur only) --

  def apply_fake_repair(%State{} = state, event) do
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
        |> add_journal_entry(
          player_id,
          "Pretended to repair #{system_display_name(system_id)}. Keeping up appearances."
        )

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Scan player (engineer only) --

  def apply_scan_player(%State{} = state, event) do
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

  def apply_lock_room(%State{} = state, event) do
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
        |> add_journal_entry(
          player_id,
          "Locked down #{system_display_name(system_id)} to prevent sabotage."
        )

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Call emergency meeting (captain only) --

  def apply_call_emergency_meeting(%State{} = state, event) do
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
        |> add_journal_entry(
          player_id,
          "Called an emergency meeting. Something doesn't feel right."
        )

      advance_action_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Action: Vent (saboteur only) --

  def apply_vent(%State{} = state, event) do
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

  # -- Turn advancement --

  defp advance_action_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All players have acted; resolve the round
        RoundResolution.resolve_round(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} action"}}
    end
  end

  # -- Helpers local to action-phase validation --

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

  defp put_player_field(players, player_id, field, value) do
    case Map.get(players, player_id) do
      nil -> players
      player -> Map.put(players, player_id, Map.put(player, field, value))
    end
  end
end
