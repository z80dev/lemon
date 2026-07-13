defmodule LemonSim.Examples.Werewolf.Updaters.NightActions do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.Events
  alias LemonSim.Examples.Werewolf.Updaters.Items
  alias LemonSim.Examples.Werewolf.Updaters.NightResolution

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_choose_victim(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    victim_id = fetch(event.payload, :victim_id, "victim_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "werewolf"),
         :ok <- ensure_living(players, victim_id),
         :ok <- ensure_not_role(players, victim_id, "werewolf") do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "choose_victim", target: victim_id})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  def apply_investigate_player(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "seer"),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
      target_role = get(Map.get(players, target_id, %{}), :role, "unknown")

      # Record the seer's investigation
      seer_history = get(state.world, :seer_history, [])
      new_history = seer_history ++ [%{target: target_id, role: target_role}]

      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "investigate", target: target_id, result: target_role})

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            night_actions: night_actions,
            seer_history: new_history
          })
        )
        |> State.append_event(event)
        |> State.append_event(Events.investigation_result(player_id, target_id, target_role))

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  def apply_protect_player(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "doctor"),
         :ok <- ensure_living(players, target_id) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "protect", target: target_id})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  def apply_sleep(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_sleep_role(players, player_id, get(state.world, :day_number, 1)) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "sleep"})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  def apply_night_wander(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "villager") do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "wander"})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_night_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All night actors have gone; resolve the night
        NightResolution.resolve_night(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} night action"}}
    end
  end

  defp ensure_sleep_role(players, player_id, day_number) do
    role = players |> Map.get(player_id, %{}) |> get(:role)

    if role == "villager" and day_number >= 1, do: :ok, else: {:error, :wrong_role}
  end

  def apply_use_item(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    item_type = fetch(event.payload, :item_type, "item_type")
    players = get(state.world, :players, %{})
    player_items = get(state.world, :player_items, %{})
    current_items = Map.get(player_items, player_id, [])

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         true <- item_type in ["lock", "lantern"],
         true <- Items.has_item?(current_items, item_type) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "use_item", item: item_type})

      new_items = Items.remove_first_item(current_items, item_type)
      new_player_items = Map.put(player_items, player_id, new_items)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            night_actions: night_actions,
            player_items: new_player_items
          })
        )
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      false when item_type in ["lock", "lantern"] ->
        reject_action(state, event, player_id, :item_not_owned)

      false ->
        reject_action(state, event, player_id, :invalid_item)

      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end
end
