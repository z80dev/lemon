defmodule LemonSim.Examples.WerewolfPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.Performance

  test "summarizes objective role metrics for benchmark analysis" do
    world = %{
      winner: "villagers",
      players: %{
        "Alice" => %{
          role: "seer",
          status: "alive",
          model: "openai-codex/gpt-5.3-codex"
        },
        "Bram" => %{role: "doctor", status: "alive", model: "kimi/k2p5"},
        "Cora" => %{
          role: "werewolf",
          status: "dead",
          model: "openai-codex/gpt-5.3-codex"
        },
        "Dane" => %{role: "villager", status: "alive", model: "kimi/k2p5"}
      },
      vote_history: [
        %{
          day: 1,
          voter: "Alice",
          voter_role: "seer",
          target: "Cora",
          target_role: "werewolf"
        },
        %{day: 1, voter: "Bram", voter_role: "doctor", target: "skip", target_role: nil},
        %{
          day: 1,
          voter: "Cora",
          voter_role: "werewolf",
          target: "Dane",
          target_role: "villager"
        }
      ],
      night_history: [
        %{
          day: 1,
          player: "Alice",
          action: "investigate",
          result: "werewolf",
          successful: true,
          saved: false
        },
        %{
          day: 1,
          player: "Bram",
          action: "protect",
          result: nil,
          successful: true,
          saved: true
        },
        %{
          day: 1,
          player: "Cora",
          action: "choose_victim",
          result: nil,
          successful: false,
          saved: false
        }
      ]
    }

    summary = Performance.summarize(world)

    assert summary.benchmark_focus ==
             "hidden-information reasoning, persuasion, and role execution"

    assert summary.players["Alice"].team_won
    assert summary.players["Alice"].votes_for_werewolf == 1
    assert summary.players["Alice"].wolf_checks_found == 1

    assert summary.players["Bram"].skip_votes == 1
    assert summary.players["Bram"].doctor_saves == 1

    refute summary.players["Cora"].team_won
    assert summary.players["Cora"].votes_for_villager == 1
    assert summary.players["Cora"].failed_kills == 1

    assert summary.models["openai-codex/gpt-5.3-codex"].seats == 2
    assert summary.models["openai-codex/gpt-5.3-codex"].votes_for_werewolf == 1
    assert summary.models["kimi/k2p5"].doctor_saves == 1
  end
end
