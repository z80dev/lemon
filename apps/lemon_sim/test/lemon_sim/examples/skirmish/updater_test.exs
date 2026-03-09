defmodule LemonSim.Examples.Skirmish.UpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Skirmish
  alias LemonSim.Examples.Skirmish.{Events, Updater}

  test "move request updates position and spends ap" do
    state = Skirmish.initial_state()

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
    state = Skirmish.initial_state()

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
    state = Skirmish.initial_state()

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
