defmodule LemonSim.Examples.WerewolfActionSpaceInventoryTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.ActionSpace
  alias LemonSim.Kernel.State

  test "night role tools expose only living valid targets" do
    state =
      state(%{
        phase: "night",
        day_number: 2,
        active_actor_id: "Cora",
        players: %{
          "Alice" => %{role: "villager", status: "alive"},
          "Bram" => %{role: "doctor", status: "dead"},
          "Cora" => %{role: "werewolf", status: "alive"},
          "Dane" => %{role: "seer", status: "alive"}
        }
      })

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "choose_victim"
    assert tool.parameters["properties"]["victim_id"]["enum"] == ["Alice", "Dane"]
  end

  test "inventory tools are available only in matching phases" do
    day_state =
      state(%{
        phase: "day_discussion",
        active_actor_id: "Alice",
        player_items: %{
          "Alice" => [%{type: "anonymous_letter"}, %{"type" => "lock"}]
        }
      })

    assert {:ok, day_tools} = ActionSpace.tools(day_state, [])

    assert Enum.map(day_tools, & &1.name) == [
             "make_statement",
             "make_accusation",
             "send_anonymous_letter"
           ]

    night_state =
      state(%{
        phase: "night",
        active_actor_id: "Alice",
        player_items: %{
          "Alice" => [%{"type" => "lock"}, %{type: "lantern"}, %{type: "anonymous_letter"}]
        }
      })

    assert {:ok, night_tools} = ActionSpace.tools(night_state, [])

    assert Enum.map(night_tools, & &1.name) == [
             "sleep",
             "night_wander",
             "use_lock",
             "use_lantern"
           ]
  end

  test "last words phase lets an eliminated actor speak" do
    state =
      state(%{
        phase: "last_words_vote",
        active_actor_id: "Alice",
        players: %{
          "Alice" => %{role: "villager", status: "dead"},
          "Bram" => %{role: "doctor", status: "alive"}
        }
      })

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "make_last_words"
    assert tool.parameters["required"] == ["statement"]
  end

  defp state(world_overrides) do
    State.new(
      sim_id: "werewolf-action-space-inventory-test",
      world:
        Map.merge(
          %{
            status: "in_progress",
            phase: "day_discussion",
            day_number: 2,
            active_actor_id: "Alice",
            players: %{
              "Alice" => %{role: "villager", status: "alive"},
              "Bram" => %{role: "doctor", status: "alive"},
              "Cora" => %{role: "werewolf", status: "alive"}
            },
            player_items: %{}
          },
          world_overrides
        )
    )
  end
end
