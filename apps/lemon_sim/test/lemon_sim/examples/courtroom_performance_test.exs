defmodule LemonSim.Examples.CourtroomPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.Courtroom.Performance

  test "scorecard exposes evidence utilization as a verified metric" do
    world = %{
      winner: "prosecution",
      outcome: "guilty",
      players: %{
        "prosecution" => %{role: "prosecution", model: "model-a"},
        "defense" => %{role: "defense", model: "model-b"}
      },
      case_file: %{evidence_list: ["knife", "receipt", "photo", "text"]},
      evidence_presented: ["knife", "receipt"],
      objections: [%{player_id: "defense", ruling: "sustained"}],
      testimony_log: [%{type: "statement", player_id: "prosecution"}],
      verdict_votes: %{"juror_1" => "guilty", "juror_2" => "guilty"}
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.evidence_utilization_pct == 50.0
    assert scorecard.players["prosecution"].won
    assert scorecard.models["model-a"].wins == 1
    assert {:ok, 50.0} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
