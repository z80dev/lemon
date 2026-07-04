defmodule LemonSim.Examples.MurderMysteryPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.MurderMystery.Performance

  test "scorecard exposes correct accusation rate as a verified metric" do
    world = %{
      winner: "investigators",
      solution: %{killer_id: "killer", weapon: "candlestick", room_id: "library"},
      players: %{
        "detective" => %{role: "investigator", model: "model-a", clues_found: ["note"]},
        "killer" => %{role: "killer", model: "model-b", clues_found: []}
      },
      accusations: [
        %{"player_id" => "detective", "correct" => true},
        %{"player_id" => "killer", "correct" => false}
      ],
      interrogation_log: [%{"asker_id" => "detective"}],
      discussion_log: [%{"player_id" => "detective"}],
      planted_evidence: ["fake_note"],
      destroyed_evidence: ["receipt"]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.correct_accusation_rate == 0.5
    assert scorecard.players["detective"].correct_accusation
    assert scorecard.players["killer"].evidence_planted == 1
    assert {:ok, 0.5} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
