defmodule LemonSim.Examples.PandemicPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.Pandemic.Performance

  test "scorecard exposes global death rate as a verified metric" do
    world = %{
      status: "won",
      winner: "team",
      round: 4,
      players: %{
        "gov_a" => %{model: "model-a", region: "north"},
        "gov_b" => %{model: "model-b", region: "south"}
      },
      regions: %{
        "north" => %{population: 1000, dead: 10, infected: 20, recovered: 100, vaccinated: 300},
        "south" => %{population: 1000, dead: 30, infected: 40, recovered: 120, vaccinated: 200}
      },
      disease: %{spread_rate: 0.12, research_progress: 80},
      hoarding_log: [%{governor: "gov_b"}],
      comm_history: [%{from: "gov_a"}]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.team.global_death_rate == 2.0
    assert scorecard.team.won
    assert scorecard.players["gov_b"].hoarding_incidents == 1
    assert {:ok, 2.0} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
