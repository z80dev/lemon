defmodule LemonSim.Examples.Skirmish.PhaseEngine do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Skirmish.Events

  @spec advance_turn(map()) :: {map(), [LemonSim.Event.t()]}
  def advance_turn(world) when is_map(world) do
    units = get(world, :units, %{})
    turn_order = get(world, :turn_order, [])
    current_actor_id = MapHelpers.get_key(world, :active_actor_id)

    living_order = Enum.filter(turn_order, &alive?(Map.get(units, &1)))

    case living_order do
      [] ->
        {world, []}

      [only_actor] ->
        next_world =
          world
          |> Map.put(:active_actor_id, only_actor)
          |> Map.put(:phase, "main")
          |> Map.put(:units, refresh_turn(units, only_actor))

        {next_world, [Events.turn_ended(current_actor_id || only_actor, only_actor)]}

      _ ->
        current_index = Enum.find_index(living_order, &(&1 == current_actor_id)) || 0
        next_index = rem(current_index + 1, length(living_order))
        next_actor_id = Enum.at(living_order, next_index)
        wrapped? = next_index == 0
        next_round = get(world, :round, 1) + if(wrapped?, do: 1, else: 0)

        next_world =
          world
          |> Map.put(:round, next_round)
          |> Map.put(:active_actor_id, next_actor_id)
          |> Map.put(:phase, "main")
          |> Map.put(:units, refresh_turn(units, next_actor_id))

        events =
          [Events.turn_ended(current_actor_id || next_actor_id, next_actor_id)] ++
            if(wrapped?, do: [Events.round_advanced(next_round)], else: [])

        {next_world, events}
    end
  end

  defp refresh_turn(units, actor_id) do
    Map.update(units, actor_id, %{}, fn unit ->
      max_ap = get(unit, :max_ap, 2)
      unit |> Map.put(:ap, max_ap)
    end)
  end

  defp alive?(nil), do: false

  defp alive?(unit) do
    get(unit, :status, "alive") != "dead" and get(unit, :hp, 0) > 0
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
