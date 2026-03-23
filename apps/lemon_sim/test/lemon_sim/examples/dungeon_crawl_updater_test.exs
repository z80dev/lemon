defmodule LemonSim.Examples.DungeonCrawlUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.DungeonCrawl.{Events, Updater}
  alias LemonSim.State

  defp base_world do
    %{
      status: "in_progress",
      active_actor_id: "warrior_1",
      party: %{
        "warrior_1" => %{
          class: "warrior",
          hp: 20,
          max_hp: 20,
          ap: 2,
          max_ap: 2,
          attack: 5,
          armor: 2,
          status: "alive"
        },
        "rogue_1" => %{
          class: "rogue",
          hp: 14,
          max_hp: 14,
          ap: 2,
          max_ap: 2,
          attack: 4,
          armor: 0,
          status: "alive"
        },
        "mage_1" => %{
          class: "mage",
          hp: 10,
          max_hp: 10,
          ap: 2,
          max_ap: 2,
          attack: 3,
          armor: 0,
          status: "alive"
        },
        "cleric_1" => %{
          class: "cleric",
          hp: 16,
          max_hp: 16,
          ap: 2,
          max_ap: 2,
          attack: 2,
          armor: 1,
          heal: 4,
          status: "alive"
        }
      },
      turn_order: ["warrior_1", "rogue_1", "mage_1", "cleric_1"],
      enemies: %{
        "goblin_1" => %{id: "goblin_1", hp: 8, attack: 3, armor: 1, status: "alive"}
      },
      rooms: [
        %{
          name: "Entry Hall",
          enemies: [%{id: "goblin_1", hp: 8, attack: 3, armor: 1, status: "alive"}],
          traps: [],
          treasure: [],
          cleared: false
        },
        %{
          name: "Dark Corridor",
          enemies: [%{id: "goblin_2", hp: 6, attack: 2, armor: 0, status: "alive"}],
          traps: [],
          treasure: [],
          cleared: false
        }
      ],
      current_room: 0,
      round: 1,
      inventory: [],
      attacks_this_turn: [],
      taunt_active: nil,
      buffs: %{}
    }
  end

  defp new_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "dungeon-test",
      world: Map.merge(base_world(), world_overrides)
    )
  end

  test "basic attack reduces goblin hp by damage minus armor" do
    # warrior: attack=5, goblin: armor=1, damage = max(5 - 1, 1) = 4
    state = new_state()

    assert {:ok, next_state, _signal} =
             Updater.apply_event(state, Events.attack_requested("warrior_1", "goblin_1"), [])

    goblin = next_state.world.enemies["goblin_1"]
    assert goblin.hp == 4
    assert goblin.status == "alive"

    warrior = next_state.world.party["warrior_1"]
    assert warrior.ap == 1
  end

  test "attack killing an enemy emits enemy_killed event and sets enemy status to dead in events" do
    state =
      new_state(%{
        enemies: %{
          "goblin_1" => %{id: "goblin_1", hp: 4, attack: 3, armor: 0, status: "alive"}
        },
        # Only 1 room so we can check the final state without room advancement confusion
        rooms: [
          %{
            name: "Entry Hall",
            enemies: [%{id: "goblin_1", hp: 4, attack: 3, armor: 0, status: "alive"}],
            traps: [],
            treasure: [],
            cleared: false
          }
        ]
      })

    # warrior attack=5, armor=0, damage=5, hp=4 -> dead; only 1 room -> victory
    assert {:ok, next_state, :skip} =
             Updater.apply_event(state, Events.attack_requested("warrior_1", "goblin_1"), [])

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "enemy_killed" in kinds
    assert "game_over" in kinds
    assert next_state.world.status == "won"
  end

  test "taunt sets taunt_active to actor and costs 1 AP" do
    state = new_state()

    assert {:ok, next_state, _signal} =
             Updater.apply_event(state, Events.ability_requested("warrior_1", "taunt"), [])

    assert next_state.world.taunt_active == "warrior_1"
    assert next_state.world.party["warrior_1"].ap == 1
  end

  test "backstab with ally attack on same target this turn deals double raw damage" do
    # warrior already attacked goblin_1 this turn
    state =
      new_state(%{
        active_actor_id: "rogue_1",
        attacks_this_turn: [%{"attacker_id" => "warrior_1", "target_id" => "goblin_1"}]
      })

    # rogue: attack=4, armor=0 on goblin. backstab: 2 * 4 = 8 raw damage, goblin armor=1, final=7
    # goblin hp=8, new_hp = max(8 - 7, 0) = 1
    assert {:ok, next_state, _signal} =
             Updater.apply_event(
               state,
               Events.ability_requested("rogue_1", "backstab", %{"target_id" => "goblin_1"}),
               []
             )

    goblin = next_state.world.enemies["goblin_1"]
    # 2*4 - 1 = 7 damage, 8 - 7 = 1 hp
    assert goblin.hp == 1

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "backstab_resolved" in kinds
  end

  test "fireball hits all living enemies for 2 damage each and costs 2 AP" do
    state =
      new_state(%{
        active_actor_id: "mage_1",
        enemies: %{
          "goblin_1" => %{id: "goblin_1", hp: 8, attack: 3, armor: 1, status: "alive"},
          "goblin_2" => %{id: "goblin_2", hp: 5, attack: 2, armor: 0, status: "alive"}
        }
      })

    assert {:ok, next_state, _signal} =
             Updater.apply_event(state, Events.ability_requested("mage_1", "fireball"), [])

    assert next_state.world.enemies["goblin_1"].hp == 6
    assert next_state.world.enemies["goblin_2"].hp == 3
    assert next_state.world.party["mage_1"].ap == 0

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "fireball_resolved" in kinds
  end

  test "heal increases wounded target hp up to max_hp and costs cleric 1 AP" do
    state =
      new_state(%{
        active_actor_id: "cleric_1",
        party: %{
          "warrior_1" => %{
            class: "warrior",
            hp: 10,
            max_hp: 20,
            ap: 2,
            max_ap: 2,
            attack: 5,
            armor: 2,
            status: "alive"
          },
          "rogue_1" => %{
            class: "rogue",
            hp: 14,
            max_hp: 14,
            ap: 2,
            max_ap: 2,
            attack: 4,
            armor: 0,
            status: "alive"
          },
          "mage_1" => %{
            class: "mage",
            hp: 10,
            max_hp: 10,
            ap: 2,
            max_ap: 2,
            attack: 3,
            armor: 0,
            status: "alive"
          },
          "cleric_1" => %{
            class: "cleric",
            hp: 16,
            max_hp: 16,
            ap: 2,
            max_ap: 2,
            attack: 2,
            armor: 1,
            heal: 4,
            status: "alive"
          }
        }
      })

    assert {:ok, next_state, _signal} =
             Updater.apply_event(
               state,
               Events.ability_requested("cleric_1", "heal", %{"target_id" => "warrior_1"}),
               []
             )

    # warrior hp=10, heal=4, new_hp = min(14, 20) = 14
    assert next_state.world.party["warrior_1"].hp == 14
    assert next_state.world.party["cleric_1"].ap == 1

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "heal_applied" in kinds
  end

  test "heal does not exceed max_hp" do
    state =
      new_state(%{
        active_actor_id: "cleric_1",
        party: %{
          "warrior_1" => %{
            class: "warrior",
            hp: 18,
            max_hp: 20,
            ap: 2,
            max_ap: 2,
            attack: 5,
            armor: 2,
            status: "alive"
          },
          "rogue_1" => %{
            class: "rogue",
            hp: 14,
            max_hp: 14,
            ap: 2,
            max_ap: 2,
            attack: 4,
            armor: 0,
            status: "alive"
          },
          "mage_1" => %{
            class: "mage",
            hp: 10,
            max_hp: 10,
            ap: 2,
            max_ap: 2,
            attack: 3,
            armor: 0,
            status: "alive"
          },
          "cleric_1" => %{
            class: "cleric",
            hp: 16,
            max_hp: 16,
            ap: 2,
            max_ap: 2,
            attack: 2,
            armor: 1,
            heal: 4,
            status: "alive"
          }
        }
      })

    assert {:ok, next_state, _signal} =
             Updater.apply_event(
               state,
               Events.ability_requested("cleric_1", "heal", %{"target_id" => "warrior_1"}),
               []
             )

    # warrior hp=18, heal=4, but max_hp=20, so new_hp = min(22, 20) = 20
    assert next_state.world.party["warrior_1"].hp == 20
  end

  test "disarm_trap marks the first active trap as disarmed" do
    state =
      new_state(%{
        active_actor_id: "rogue_1",
        rooms: [
          %{
            name: "Entry Hall",
            enemies: [],
            traps: [%{type: "arrow", damage: 3, disarmed: false}],
            treasure: [],
            cleared: false
          },
          %{name: "Dark Corridor", enemies: [], traps: [], treasure: [], cleared: false}
        ]
      })

    assert {:ok, next_state, _signal} =
             Updater.apply_event(state, Events.ability_requested("rogue_1", "disarm_trap"), [])

    room = Enum.at(next_state.world.rooms, 0)
    trap = List.first(room.traps)
    assert trap.disarmed == true
    assert next_state.world.party["rogue_1"].ap == 1

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "trap_disarmed" in kinds
  end

  test "actor with 0 AP cannot attack and action is rejected" do
    state =
      new_state(%{
        party: %{
          "warrior_1" => %{
            class: "warrior",
            hp: 20,
            max_hp: 20,
            ap: 0,
            max_ap: 2,
            attack: 5,
            armor: 2,
            status: "alive"
          },
          "rogue_1" => %{
            class: "rogue",
            hp: 14,
            max_hp: 14,
            ap: 2,
            max_ap: 2,
            attack: 4,
            armor: 0,
            status: "alive"
          },
          "mage_1" => %{
            class: "mage",
            hp: 10,
            max_hp: 10,
            ap: 2,
            max_ap: 2,
            attack: 3,
            armor: 0,
            status: "alive"
          },
          "cleric_1" => %{
            class: "cleric",
            hp: 16,
            max_hp: 16,
            ap: 2,
            max_ap: 2,
            attack: 2,
            armor: 1,
            heal: 4,
            status: "alive"
          }
        }
      })

    assert {:ok, next_state, {:decide, _msg}} =
             Updater.apply_event(state, Events.attack_requested("warrior_1", "goblin_1"), [])

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "action_rejected" in kinds

    # Enemy HP should be unchanged
    assert next_state.world.enemies["goblin_1"].hp == 8
  end

  test "killing last enemy in last room triggers victory" do
    state =
      new_state(%{
        enemies: %{
          "goblin_1" => %{id: "goblin_1", hp: 1, attack: 3, armor: 0, status: "alive"}
        },
        rooms: [
          %{
            name: "Entry Hall",
            enemies: [%{id: "goblin_1", hp: 1, attack: 3, armor: 0, status: "alive"}],
            traps: [],
            treasure: [],
            cleared: false
          }
        ]
      })

    # warrior attack=5, goblin armor=0, damage=5, hp=1 -> dead. Only 1 room -> won
    assert {:ok, next_state, :skip} =
             Updater.apply_event(state, Events.attack_requested("warrior_1", "goblin_1"), [])

    assert next_state.world.status == "won"

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "game_over" in kinds
  end

  test "killing last enemy in non-final room advances to next room" do
    state =
      new_state(%{
        enemies: %{
          "goblin_1" => %{id: "goblin_1", hp: 1, attack: 3, armor: 0, status: "alive"}
        }
      })

    # Two rooms, killing goblin in room 0 -> advance to room 1
    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.attack_requested("warrior_1", "goblin_1"), [])

    assert next_state.world.current_room == 1
    assert next_state.world.status == "in_progress"

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "room_cleared" in kinds
    assert "room_entered" in kinds
  end
end
