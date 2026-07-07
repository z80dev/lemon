defmodule LemonSim.Examples.DungeonCrawl.Updaters.Rooms do
  @moduledoc false

  import LemonSim.Examples.Helpers

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.DungeonCrawl.Events

  # -- Room management --

  def maybe_check_room_clear(%State{} = state) do
    world = state.world
    enemies = get(world, :enemies, %{})

    all_dead =
      Enum.all?(enemies, fn {_id, e} -> get(e, :status, "alive") != "alive" end)

    if all_dead do
      handle_room_clear(state)
    else
      state
    end
  end

  defp handle_room_clear(%State{} = state) do
    world = state.world
    current_room_index = get(world, :current_room, 0)
    rooms = get(world, :rooms, [])
    current_room = Enum.at(rooms, current_room_index, %{})

    # Mark room as cleared
    updated_room = Map.put(current_room, :cleared, true)
    updated_rooms = List.replace_at(rooms, current_room_index, updated_room)

    # Collect treasure
    treasure = get(current_room, :treasure, [])
    current_inventory = get(world, :inventory, [])
    new_inventory = current_inventory ++ treasure

    treasure_events =
      Enum.map(treasure, fn item ->
        Events.item_collected(get(item, :name, "unknown"))
      end)

    room_clear_events = [Events.room_cleared(current_room_index)] ++ treasure_events

    next_room_index = current_room_index + 1

    if next_room_index >= length(rooms) do
      # All rooms cleared - victory!
      next_world =
        world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:inventory, new_inventory)
        |> Map.put(:status, "won")
        |> Map.put(:winner, "party")
        |> Map.put(:active_actor_id, nil)

      victory_events =
        room_clear_events ++ [Events.game_over("won", "The dungeon has been cleared!")]

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_events(victory_events)

      {:ok, next_state, :skip}
    else
      # Move to next room
      next_room = Enum.at(rooms, next_room_index, %{})
      next_enemies = load_room_enemies(next_room)
      first_actor = find_first_living_actor(world)

      next_world =
        world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:inventory, new_inventory)
        |> Map.put(:current_room, next_room_index)
        |> Map.put(:enemies, next_enemies)
        |> Map.put(:round, 1)
        |> Map.put(:taunt_active, nil)
        |> Map.put(:attacks_this_turn, [])

      next_world = refresh_all_ap(next_world)
      next_world = Map.put(next_world, :active_actor_id, first_actor)

      enter_events = room_clear_events ++ [Events.room_entered(next_room_index)]

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_events(enter_events)

      {:ok, next_state,
       {:decide,
        "Room #{next_room_index + 1}: #{get(next_room, :name, "Unknown")} - #{first_actor} turn"}}
    end
  end

  defp load_room_enemies(room) do
    room
    |> get(:enemies, [])
    |> Enum.into(%{}, fn enemy ->
      {get(enemy, :id, "unknown"), enemy}
    end)
  end

  defp find_first_living_actor(world) do
    turn_order = get(world, :turn_order, [])
    party = get(world, :party, %{})

    Enum.find(turn_order, List.first(turn_order), fn id ->
      adventurer = Map.get(party, id)
      adventurer && get(adventurer, :hp, 0) > 0
    end)
  end

  defp refresh_all_ap(world) do
    party = get(world, :party, %{})

    updated_party =
      Enum.into(party, %{}, fn {id, adventurer} ->
        if get(adventurer, :hp, 0) > 0 do
          {id, Map.put(adventurer, :ap, get(adventurer, :max_ap, 2))}
        else
          {id, adventurer}
        end
      end)

    Map.put(world, :party, updated_party)
  end
end
