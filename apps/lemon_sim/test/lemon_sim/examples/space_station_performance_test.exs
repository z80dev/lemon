defmodule LemonSim.Examples.SpaceStationPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.SpaceStation.Performance

  test "summarizes action and vote quality for benchmark analysis" do
    world = %{
      winner: "crew",
      players: %{
        "player_1" => %{
          name: "Alice",
          role: "engineer",
          status: "alive",
          model: "gemini/gemini-2.5-flash"
        },
        "player_2" => %{name: "Bram", role: "captain", status: "alive", model: "gpt-5.3-codex"},
        "player_3" => %{name: "Cora", role: "saboteur", status: "ejected", model: "kimi/k2p5"}
      },
      action_history: [
        %{
          round: 1,
          actions: %{
            "player_1" => %{action: "scan", target: "player_3"},
            "player_2" => %{action: "lock", system: "o2"},
            "player_3" => %{action: "sabotage", system: "power"}
          }
        },
        %{
          round: 2,
          actions: %{
            "player_2" => %{action: "emergency_meeting"},
            "player_3" => %{action: "vent"}
          }
        }
      ],
      vote_history: [
        %{
          round: 1,
          votes: %{"player_1" => "player_3", "player_2" => "player_3", "player_3" => "player_2"}
        }
      ]
    }

    summary = Performance.summarize(world)

    assert summary.saboteur_id == "player_3"
    assert summary.players |> Enum.find(&(&1.player_id == "player_1")) |> Map.get(:scans) == 1
    assert summary.players |> Enum.find(&(&1.player_id == "player_2")) |> Map.get(:locks) == 1

    assert summary.players
           |> Enum.find(&(&1.player_id == "player_2"))
           |> Map.get(:emergency_meetings) == 1

    assert summary.players |> Enum.find(&(&1.player_id == "player_3")) |> Map.get(:sabotages) == 1
    assert summary.players |> Enum.find(&(&1.player_id == "player_3")) |> Map.get(:vents) == 1

    assert summary.players |> Enum.find(&(&1.player_id == "player_1")) |> Map.get(:correct_votes) ==
             1

    assert summary.players |> Enum.find(&(&1.player_id == "player_3")) |> Map.get(:wrong_votes) ==
             1
  end
end
