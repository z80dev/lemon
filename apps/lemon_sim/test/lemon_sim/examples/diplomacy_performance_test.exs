defmodule LemonSim.Examples.DiplomacyPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Diplomacy.Performance

  test "summarizes negotiation, support, and capture metrics" do
    world = %{
      winner: "player_2",
      players: %{
        "player_1" => %{faction: "Red", model: "google/gemini-3-flash"},
        "player_2" => %{faction: "Blue", model: "google/gemini-3-flash"},
        "player_3" => %{faction: "Green", model: "kimi/k2p5"}
      },
      territories: %{
        "A" => %{owner: "player_2", armies: 3},
        "B" => %{owner: "player_2", armies: 2},
        "C" => %{owner: "player_3", armies: 1}
      },
      message_history: [
        %{round: 1, from: "player_1", to: "player_2"},
        %{round: 1, from: "player_1", to: "player_3"},
        %{round: 2, from: "player_2", to: "player_1"}
      ],
      order_history: [
        %{
          round: 1,
          player: "player_1",
          orders: %{
            "A" => %{"order_type" => "support"}
          }
        },
        %{
          round: 1,
          player: "player_2",
          orders: %{
            "B" => %{"order_type" => "move"}
          }
        }
      ],
      capture_history: [
        %{round: 1, attacker: "player_2", defender: "player_1", territory: "A"},
        %{round: 2, attacker: "player_2", defender: nil, territory: "B"}
      ]
    }

    summary = Performance.summarize(world)

    assert summary.benchmark_focus ==
             "negotiation throughput, support coordination, and territory conversion"

    assert summary.players["player_1"].messages_sent == 2
    assert summary.players["player_1"].support_orders == 1
    assert summary.players["player_1"].final_territories == 0

    assert summary.players["player_2"].won
    assert summary.players["player_2"].messages_sent == 1
    assert summary.players["player_2"].orders_submitted == 1
    assert summary.players["player_2"].territories_captured == 2
    assert summary.players["player_2"].final_territories == 2

    assert summary.models["google/gemini-3-flash"].seats == 2
    assert summary.models["google/gemini-3-flash"].wins == 1
    assert summary.models["google/gemini-3-flash"].territories_captured == 2
    assert summary.models["kimi/k2p5"].final_territories == 1
  end
end
