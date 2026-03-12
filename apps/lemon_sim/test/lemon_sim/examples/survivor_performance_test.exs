defmodule LemonSim.Examples.SurvivorPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Survivor.Performance

  test "summarizes challenge, social, and vote-quality metrics" do
    world = %{
      winner: "player_2",
      players: %{
        "player_1" => %{status: "eliminated", model: "google/gemini-2.5-flash"},
        "player_2" => %{status: "alive", model: "google/gemini-2.5-flash"},
        "player_3" => %{status: "alive", model: "kimi/k2p5"}
      },
      challenge_history: [
        %{episode: 1, winner: "player_2"},
        %{episode: 2, winner: "player_2"},
        %{episode: 3, winner: "player_3"}
      ],
      whisper_history: [
        %{episode: 1, from: "player_1", to: "player_2"},
        %{episode: 1, from: "player_1", to: "player_3"},
        %{episode: 2, from: "player_2", to: "player_3"}
      ],
      vote_history: [
        %{
          episode: 1,
          voter: "player_1",
          target: "player_3",
          target_eliminated: false,
          merged: false
        },
        %{
          episode: 1,
          voter: "player_2",
          target: "player_1",
          target_eliminated: true,
          merged: false
        },
        %{
          episode: 2,
          voter: "player_3",
          target: "player_1",
          target_eliminated: true,
          merged: true
        }
      ],
      idol_history: [
        %{episode: 2, player: "player_3"}
      ],
      jury_votes: %{
        "player_1" => "player_2"
      }
    }

    summary = Performance.summarize(world)

    assert summary.benchmark_focus ==
             "social strategy, vote quality, alliance signaling, and endgame conversion"

    refute summary.players["player_1"].won
    assert summary.players["player_1"].whispers_sent == 2
    assert summary.players["player_1"].wrong_votes == 1

    assert summary.players["player_2"].won
    assert summary.players["player_2"].challenge_wins == 2
    assert summary.players["player_2"].correct_votes == 1
    assert summary.players["player_2"].jury_votes_received == 1

    assert summary.players["player_3"].challenge_wins == 1
    assert summary.players["player_3"].correct_votes == 1
    assert summary.players["player_3"].idol_plays == 1

    assert summary.models["google/gemini-2.5-flash"].seats == 2
    assert summary.models["google/gemini-2.5-flash"].wins == 1
    assert summary.models["google/gemini-2.5-flash"].challenge_wins == 2
    assert summary.models["google/gemini-2.5-flash"].correct_votes == 1
    assert summary.models["kimi/k2p5"].jury_votes_received == 0
  end
end
