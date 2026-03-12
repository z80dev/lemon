defmodule LemonSim.Examples.Skirmish.PhaseEngine do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Skirmish.{Events, Outcome}

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
        max_rounds = get(world, :max_rounds, nil)

        base_units = refresh_turn(units, next_actor_id)

        # Apply storm damage when a new round starts past max_rounds
        {storm_units, storm_events} =
          if wrapped? and is_integer(max_rounds) and next_round > max_rounds do
            apply_storm_damage(base_units)
          else
            {base_units, []}
          end

        winner = Outcome.winner(storm_units)

        next_world =
          world
          |> Map.put(:round, next_round)
          |> Map.put(:active_actor_id, if(is_binary(winner), do: nil, else: next_actor_id))
          |> Map.put(:phase, if(is_binary(winner), do: "game_over", else: "main"))
          |> Map.put(:units, storm_units)
          |> Map.put(:winner, winner)
          |> Map.put(:status, if(is_binary(winner), do: "won", else: "in_progress"))

        events =
          [Events.turn_ended(current_actor_id || next_actor_id, next_actor_id)] ++
            if(wrapped?, do: [Events.round_advanced(next_round)], else: []) ++
            storm_events ++
            if(is_binary(winner), do: [Events.game_over(winner)], else: [])

        {next_world, events}
    end
  end

  defp apply_storm_damage(units) do
    Enum.reduce(units, {%{}, []}, fn {unit_id, unit}, {acc_units, acc_events} ->
      if alive?(unit) do
        hp = get(unit, :hp, 0)
        new_hp = max(hp - 1, 0)
        updated = Map.put(unit, :hp, new_hp)

        updated =
          if new_hp <= 0 do
            Map.put(updated, :status, "dead")
          else
            updated
          end

        events =
          [Events.damage_applied(unit_id, 1, new_hp)] ++
            if(new_hp <= 0,
              do: [Events.unit_died(unit_id, get(unit, :team, "unknown"))],
              else: []
            )

        {Map.put(acc_units, unit_id, updated), acc_events ++ events}
      else
        {Map.put(acc_units, unit_id, unit), acc_events}
      end
    end)
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
