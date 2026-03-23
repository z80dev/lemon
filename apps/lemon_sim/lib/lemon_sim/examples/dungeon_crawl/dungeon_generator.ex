defmodule LemonSim.Examples.DungeonCrawl.DungeonGenerator do
  @moduledoc false

  @doc """
  Generates 5 dungeon rooms with enemies, traps, and treasure.

  Uses a seed for deterministic generation.
  """
  @spec generate(keyword()) :: [map()]
  def generate(opts \\ []) do
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    Enum.map(0..4, fn room_index ->
      generate_room(room_index)
    end)
  end

  defp generate_room(4) do
    # Boss room (room 5) - always has the ogre
    %{
      index: 4,
      name: "The Boss Chamber",
      enemies:
        [
          %{id: "ogre_1", type: "ogre", hp: 15, max_hp: 15, attack: 5, status: "alive"}
        ] ++ maybe_boss_adds(),
      traps: [],
      treasure: [%{name: "healing_potion", effect: "heal", value: 5}],
      cleared: false
    }
  end

  defp generate_room(room_index) do
    enemy_count = room_index + 2
    enemies = generate_enemies(room_index, enemy_count)
    traps = maybe_trap(room_index)
    treasure = maybe_treasure(room_index)

    %{
      index: room_index,
      name: room_name(room_index),
      enemies: enemies,
      traps: traps,
      treasure: treasure,
      cleared: false
    }
  end

  defp generate_enemies(room_index, count) do
    skeleton_chance = min(room_index * 20, 60)

    Enum.map(1..count, fn idx ->
      roll = :rand.uniform(100)

      if roll <= skeleton_chance do
        %{
          id: "skeleton_#{room_index}_#{idx}",
          type: "skeleton",
          hp: 6,
          max_hp: 6,
          attack: 3,
          status: "alive"
        }
      else
        %{
          id: "goblin_#{room_index}_#{idx}",
          type: "goblin",
          hp: 4,
          max_hp: 4,
          attack: 2,
          status: "alive"
        }
      end
    end)
  end

  defp maybe_boss_adds do
    roll = :rand.uniform(100)

    if roll <= 60 do
      [
        %{
          id: "skeleton_4_2",
          type: "skeleton",
          hp: 6,
          max_hp: 6,
          attack: 3,
          status: "alive"
        }
      ]
    else
      []
    end
  end

  defp maybe_trap(room_index) do
    roll = :rand.uniform(100)
    threshold = 20 + room_index * 10

    cond do
      roll <= div(threshold, 2) ->
        [%{type: "poison_gas", damage: 2, target: "all", disarmed: false}]

      roll <= threshold ->
        [%{type: "floor_spikes", damage: 3, target: "single", disarmed: false}]

      true ->
        []
    end
  end

  defp maybe_treasure(room_index) do
    roll = :rand.uniform(100)
    threshold = 30 + room_index * 10

    cond do
      roll <= div(threshold, 2) ->
        [%{name: "healing_potion", effect: "heal", value: 5}]

      roll <= threshold ->
        [%{name: "damage_scroll", effect: "damage", value: 5}]

      true ->
        []
    end
  end

  defp room_name(0), do: "The Entrance Hall"
  defp room_name(1), do: "The Dark Corridor"
  defp room_name(2), do: "The Crypt"
  defp room_name(3), do: "The Armory"
  defp room_name(_), do: "The Deep Chamber"
end
