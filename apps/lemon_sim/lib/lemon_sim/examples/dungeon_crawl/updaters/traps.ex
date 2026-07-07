defmodule LemonSim.Examples.DungeonCrawl.Updaters.Traps do
  @moduledoc false

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.DungeonCrawl.Events

  # -- Trap handling --

  def maybe_trigger_traps(world, party) do
    current_room_index = get(world, :current_room, 0)
    rooms = get(world, :rooms, [])
    current_room = Enum.at(rooms, current_room_index, %{})
    traps = get(current_room, :traps, [])
    round = get(world, :round, 1)

    # Only trigger traps on round 1 (when entering room)
    if round == 1 do
      Enum.reduce(traps, {party, []}, fn trap, {acc_party, acc_events} ->
        if get(trap, :disarmed, false) do
          {acc_party, acc_events}
        else
          trigger_trap(trap, acc_party, acc_events)
        end
      end)
    else
      {party, []}
    end
  end

  defp trigger_trap(trap, party, events) do
    trap_type = get(trap, :type, "unknown")
    damage = get(trap, :damage, 2)
    target_mode = get(trap, :target, "single")

    case target_mode do
      "all" ->
        # Hits all living party members
        Enum.reduce(party, {party, events}, fn {id, adventurer}, {acc_party, acc_events} ->
          if get(adventurer, :hp, 0) > 0 do
            new_hp = max(get(adventurer, :hp, 0) - damage, 0)

            updated =
              adventurer
              |> Map.put(:hp, new_hp)
              |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

            new_events =
              [Events.trap_triggered(trap_type, id, damage)] ++
                if(new_hp <= 0, do: [Events.adventurer_downed(id)], else: [])

            {Map.put(acc_party, id, updated), acc_events ++ new_events}
          else
            {acc_party, acc_events}
          end
        end)

      _ ->
        # Hits one random living party member
        living = Enum.filter(party, fn {_id, a} -> get(a, :hp, 0) > 0 end)

        case living do
          [] ->
            {party, events}

          _ ->
            {target_id, target} = Enum.random(living)
            new_hp = max(get(target, :hp, 0) - damage, 0)

            updated =
              target
              |> Map.put(:hp, new_hp)
              |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

            new_events =
              [Events.trap_triggered(trap_type, target_id, damage)] ++
                if(new_hp <= 0, do: [Events.adventurer_downed(target_id)], else: [])

            {Map.put(party, target_id, updated), events ++ new_events}
        end
    end
  end
end
