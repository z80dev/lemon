defmodule LemonSim.Examples.WerewolfActionSpaceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.ActionSpace
  alias LemonSim.State

  test "runoff voting forces a choice between the finalists" do
    state =
      State.new(
        sim_id: "werewolf-runoff-vote",
        world: %{
          status: "in_progress",
          phase: "runoff_voting",
          active_actor_id: "Alice",
          runoff_candidates: ["Bram", "Cora"],
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "cast_vote"
    assert tool.parameters["properties"]["target_id"]["enum"] == ["Bram", "Cora"]
    refute "skip" in tool.parameters["properties"]["target_id"]["enum"]
  end

  test "day voting also forces a vote target" do
    state =
      State.new(
        sim_id: "werewolf-day-vote",
        world: %{
          status: "in_progress",
          phase: "day_voting",
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "cast_vote"
    assert tool.parameters["properties"]["target_id"]["enum"] == ["Bram", "Cora"]
    refute "skip" in tool.parameters["properties"]["target_id"]["enum"]
  end

  test "seer cannot investigate on night 1" do
    state =
      State.new(
        sim_id: "werewolf-seer-night-1",
        world: %{
          status: "in_progress",
          phase: "night",
          day_number: 1,
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "seer", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "sleep"
    refute Map.has_key?(tool.parameters["properties"], "target_id")
  end
end
