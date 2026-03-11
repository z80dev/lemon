defmodule LemonSim.Examples.Skirmish.Visibility do
  @moduledoc false

  alias LemonCore.MapHelpers

  @spec view_world(map(), String.t() | nil) :: map()
  def view_world(world, actor_id) do
    %{
      "round" => MapHelpers.get_key(world, :round),
      "phase" => MapHelpers.get_key(world, :phase),
      "status" => MapHelpers.get_key(world, :status),
      "winner" => MapHelpers.get_key(world, :winner),
      "active_actor_id" => MapHelpers.get_key(world, :active_actor_id),
      "map" => MapHelpers.get_key(world, :map),
      "units" => visible_units(world, actor_id),
      "terrain_summary" => terrain_summary(world)
    }
  end

  @spec visible_units(map(), String.t() | nil) :: map()
  def visible_units(world, _actor_id) do
    get(world, :units, %{})
  end

  @spec active_unit(map()) :: map() | nil
  def active_unit(world) do
    actor_id = MapHelpers.get_key(world, :active_actor_id)
    get_unit(world, actor_id)
  end

  @spec enemy_units(map(), String.t() | nil) :: [map()]
  def enemy_units(world, actor_id) do
    actor_team =
      world
      |> get_unit(actor_id)
      |> case do
        nil -> nil
        unit -> MapHelpers.get_key(unit, :team)
      end

    world
    |> visible_units(actor_id)
    |> Map.values()
    |> Enum.filter(fn unit ->
      MapHelpers.get_key(unit, :status) != "dead" and
        MapHelpers.get_key(unit, :team) != actor_team
    end)
  end

  @spec friendly_units(map(), String.t() | nil) :: [map()]
  def friendly_units(world, actor_id) do
    actor_team =
      world
      |> get_unit(actor_id)
      |> case do
        nil -> nil
        unit -> MapHelpers.get_key(unit, :team)
      end

    world
    |> visible_units(actor_id)
    |> Enum.filter(fn {uid, unit} ->
      uid != actor_id and
        MapHelpers.get_key(unit, :status) != "dead" and
        MapHelpers.get_key(unit, :team) == actor_team
    end)
    |> Enum.map(fn {_uid, unit} -> unit end)
  end

  defp terrain_summary(world) do
    map_data = get(world, :map, %{})

    %{
      "walls" => length(get(map_data, :walls, [])),
      "water" => length(get(map_data, :water, [])),
      "cover" => length(get(map_data, :cover, [])),
      "high_ground" => length(get(map_data, :high_ground, []))
    }
  end

  defp get_unit(_world, nil), do: nil

  defp get_unit(world, unit_id) do
    world
    |> get(:units, %{})
    |> Map.get(unit_id)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
