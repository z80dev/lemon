defmodule LemonSim.Examples.PokerPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.Poker.Performance

  test "scorecard exposes best profit loss as a verified metric" do
    world = %{
      table: %{big_blind: 2},
      completed_hands: 4,
      player_stats: %{
        "p1" => %{starting_stack: 100, hands_played: 4, hands_won: 2, vpip_hands: 2, pfr_hands: 1},
        "p2" => %{starting_stack: 100, hands_played: 4, hands_won: 1, vpip_hands: 1, pfr_hands: 1}
      },
      chip_counts: [%{"player_id" => "p1", "stack" => 130}, %{"player_id" => "p2", "stack" => 70}]
    }

    scorecard = Performance.scorecard(world)
    metric = Performance.primary_metric()

    assert scorecard.best_profit_loss == 30
    assert scorecard.players["p1"].bb_per_hand == 3.75
    assert scorecard.players["p2"].profit_loss == -30
    assert {:ok, 30} = Suite.metric_value(scorecard, List.wrap(metric.key))
    assert Performance.scorecard(world) == scorecard
  end
end
