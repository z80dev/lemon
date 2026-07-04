defmodule LemonSim.Examples.IntelNetworkPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.IntelNetwork.Performance

  test "scorecard exposes detection accuracy as a verified metric" do
    world = %{
      winner: "loyalists",
      players: %{
        "alpha" => %{role: "operative", model: "model-a", intel_fragments: ["x", "y"]},
        "bravo" => %{role: "mole", model: "model-b", intel_fragments: ["x"]},
        "charlie" => %{role: "operative", model: "model-a", intel_fragments: ["x"]}
      },
      intel_pool: ["x", "y"],
      leaked_intel: ["z"],
      suspicion_board: %{"bravo" => [%{by: "alpha"}], "charlie" => [%{by: "bravo"}]},
      message_log: %{"alpha-bravo" => [%{from: "alpha"}, %{from: "bravo"}]},
      operations_log: [
        %{player_id: "alpha", operation_type: "share_intel"},
        %{player_id: "bravo", operation_type: "report_suspicion"}
      ],
      adjacency: %{"alpha" => ["bravo"], "bravo" => ["alpha", "charlie"], "charlie" => ["bravo"]},
      max_rounds: 2
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.mole_id == "bravo"
    assert scorecard.detection_accuracy == 0.5
    assert scorecard.players["alpha"].share_intel_count == 1
    assert scorecard.models["model-a"].seats == 2
    assert {:ok, 0.5} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
