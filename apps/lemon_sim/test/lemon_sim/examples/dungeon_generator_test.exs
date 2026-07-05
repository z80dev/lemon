defmodule LemonSim.Examples.DungeonGeneratorTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.DungeonCrawl.DungeonGenerator

  test "seeded generation is deterministic and includes the boss room" do
    first = DungeonGenerator.generate(seed: 42)
    second = DungeonGenerator.generate(seed: 42)

    assert first == second
    assert length(first) == 5
    assert Enum.map(first, & &1.index) == [0, 1, 2, 3, 4]

    assert Enum.map(first, & &1.name) == [
             "The Entrance Hall",
             "The Dark Corridor",
             "The Crypt",
             "The Armory",
             "The Boss Chamber"
           ]

    boss_room = List.last(first)

    assert boss_room.treasure == [%{name: "healing_potion", effect: "heal", value: 5}]
    assert boss_room.traps == []
    assert Enum.any?(boss_room.enemies, &(&1.id == "ogre_1"))
  end

  test "generated rooms keep enemy and encounter shapes valid" do
    rooms = DungeonGenerator.generate(seed: 7)

    for room <- rooms do
      assert room.cleared == false
      assert is_list(room.enemies)
      assert is_list(room.traps)
      assert is_list(room.treasure)

      for enemy <- room.enemies do
        assert enemy.status == "alive"
        assert enemy.hp == enemy.max_hp
        assert enemy.attack > 0
        assert enemy.type in ["goblin", "skeleton", "ogre"]
      end

      for trap <- room.traps do
        assert trap.type in ["poison_gas", "floor_spikes"]
        assert trap.damage > 0
        assert trap.disarmed == false
      end

      for treasure <- room.treasure do
        assert treasure.effect in ["heal", "damage"]
        assert treasure.value == 5
      end
    end
  end
end
