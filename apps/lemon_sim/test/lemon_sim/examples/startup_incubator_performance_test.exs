defmodule LemonSim.Examples.StartupIncubatorPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.StartupIncubator.Performance

  test "scorecard exposes best founder valuation as a verified metric" do
    world = %{
      winner: "founder_a",
      players: %{
        "founder_a" => %{role: "founder", model: "model-a"},
        "investor_b" => %{role: "investor", model: "model-b"}
      },
      startups: %{
        "founder_a" => %{sector: "ai", traction: 10, employees: 3, funding_raised: 50_000}
      },
      investors: %{
        "investor_b" => %{
          fund_size: 1_000_000,
          remaining_capital: 900_000,
          portfolio: [%{"founder_id" => "founder_a", "equity_pct" => 10.0}]
        }
      },
      pitch_log: [%{founder_id: "founder_a"}],
      question_log: [%{investor_id: "investor_b", founder_id: "founder_a"}],
      deal_history: [%{founder_id: "founder_a", investor_id: "investor_b"}]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.final_valuation == 270_000
    assert scorecard.players["founder_a"].won
    assert scorecard.players["investor_b"].deals_closed == 1
    assert {:ok, 270_000} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
