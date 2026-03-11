defmodule LemonSim.Examples.Skirmish.UpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Skirmish.{Events, Updater}
  alias LemonSim.State

  # Build a minimal test world with 2 units close together
  defp test_state do
    world = %{
      map: %{
        width: 5,
        height: 5,
        cover: [%{x: 1, y: 1}, %{x: 3, y: 3}],
        walls: [],
        water: [],
        high_ground: []
      },
      units: %{
        "red_1" => %{
          team: "red",
          hp: 8,
          max_hp: 8,
          ap: 2,
          max_ap: 2,
          pos: %{x: 0, y: 0},
          status: "alive",
          cover?: false,
          attack_range: 2,
          attack_damage: 3,
          attack_chance: 100,
          sight_range: 4,
          class: "soldier",
          abilities: []
        },
        "blue_1" => %{
          team: "blue",
          hp: 8,
          max_hp: 8,
          ap: 2,
          max_ap: 2,
          pos: %{x: 2, y: 0},
          status: "alive",
          cover?: false,
          attack_range: 2,
          attack_damage: 3,
          attack_chance: 100,
          sight_range: 4,
          class: "soldier",
          abilities: []
        }
      },
      turn_order: ["red_1", "blue_1"],
      active_actor_id: "red_1",
      phase: "main",
      round: 1,
      rng_seed: 5,
      winner: nil,
      status: "in_progress",
      kill_feed: []
    }

    State.new(
      sim_id: "test_skirmish",
      world: world,
      intent: %{goal: "Win the skirmish"},
      plan_history: []
    )
  end

  test "move request updates position and spends ap" do
    state = test_state()

    assert {:ok, next_state, {:decide, "red_1 has 1 ap remaining"}} =
             Updater.apply_event(state, Events.move_requested("red_1", 1, 0), [])

    assert next_state.world.units["red_1"].pos == %{x: 1, y: 0}
    assert next_state.world.units["red_1"].ap == 1

    assert Enum.map(next_state.recent_events, & &1.kind) == [
             "move_requested",
             "ap_spent",
             "unit_moved"
           ]
  end

  test "attack request resolves deterministically and applies damage" do
    state = test_state()

    assert {:ok, next_state, {:decide, "red_1 has 1 ap remaining"}} =
             Updater.apply_event(state, Events.attack_requested("red_1", "blue_1"), [])

    assert next_state.world.units["blue_1"].hp == 5
    assert next_state.world.units["red_1"].ap == 1
    assert next_state.world.rng_seed == 22

    assert Enum.map(next_state.recent_events, & &1.kind) == [
             "attack_requested",
             "ap_spent",
             "attack_resolved",
             "damage_applied"
           ]
  end

  test "end turn advances the active actor" do
    state = test_state()

    assert {:ok, next_state, {:decide, "blue_1 turn"}} =
             Updater.apply_event(state, Events.end_turn_requested("red_1"), [])

    assert next_state.world.active_actor_id == "blue_1"
    assert next_state.world.round == 1

    assert Enum.map(next_state.recent_events, & &1.kind) == [
             "end_turn_requested",
             "turn_ended"
           ]
  end
end
