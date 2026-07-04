defmodule LemonSim.Examples.LegislaturePerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.Legislature.Performance

  test "scorecard exposes winning final score as a verified metric" do
    world = %{
      winner: "rep_b",
      players: %{
        "rep_a" => %{
          faction: "north",
          model: "model-a",
          preference_ranking: ["bill_1"],
          political_capital: 2
        },
        "rep_b" => %{
          faction: "south",
          model: "model-b",
          preference_ranking: ["bill_2", "bill_1"],
          political_capital: 4
        }
      },
      scores: %{"rep_a" => 4, "rep_b" => 9},
      bills: %{"bill_1" => %{status: "passed"}, "bill_2" => %{status: "failed"}},
      message_history: [%{from: "rep_b"}],
      floor_statements: [%{"player_id" => "rep_b"}],
      proposed_amendments: [%{proposer_id: "rep_b", passed: true}],
      vote_record: %{"rep_b" => %{"bill_1" => "yes"}}
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.final_score == 9
    assert scorecard.players["rep_b"].won
    assert scorecard.players["rep_b"].amendment_success_rate == 1.0
    assert {:ok, 9} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
