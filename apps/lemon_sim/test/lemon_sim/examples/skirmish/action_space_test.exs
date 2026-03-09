defmodule LemonSim.Examples.Skirmish.ActionSpaceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Skirmish
  alias LemonSim.Examples.Skirmish.ActionSpace
  alias LemonSim.State

  test "initial action space exposes the core tactical tools" do
    assert {:ok, tools} = ActionSpace.tools(Skirmish.initial_state(), [])

    assert Enum.map(tools, & &1.name) == [
             "move_unit",
             "attack_unit",
             "take_cover",
             "end_turn"
           ]
  end

  test "action space collapses to end_turn when the actor has no ap" do
    state =
      Skirmish.initial_state()
      |> State.update_world(fn world ->
        put_in(world, [:units, "red_1", :ap], 0)
      end)

    assert {:ok, tools} = ActionSpace.tools(state, [])
    assert Enum.map(tools, & &1.name) == ["end_turn"]
  end
end
