defmodule LemonSim.Examples.Poker.League do
  @moduledoc """
  Poker league adapter for `LemonSim.Bench.League`.

  Ranked mode: each seat's final chip stack is the outcome, so ratings come
  from pairwise stack comparisons — every hand's worth of chips counts, not
  just who bags the win. Metrics track session-level decision quality
  (bb/hand, preflop discipline, aggression mix).
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.Poker.Performance

  @behaviour LemonSim.Bench.League.Adapter

  @impl true
  def scenario_id, do: "poker"

  @impl true
  def mode, do: {:ranked, :maximize}

  @impl true
  def game_summary(world) do
    seats =
      Performance.summarize(world)
      |> Map.fetch!(:players)
      |> Enum.into(%{}, fn {player_id, metrics} ->
        {to_string(player_id),
         %{
           model: get(metrics, :model),
           role: nil,
           won: get(metrics, :won, false),
           value: get(metrics, :final_stack),
           metrics: %{
             "profit_loss" => get(metrics, :profit_loss, 0),
             "bb_per_hand" => get(metrics, :bb_per_hand, 0),
             "hands_played" => get(metrics, :hands_played, 0),
             "hands_won" => get(metrics, :hands_won, 0),
             "vpip" => get(metrics, :vpip, 0),
             "pfr" => get(metrics, :pfr, 0),
             "bet_count" => get(metrics, :bet_count, 0),
             "raise_count" => get(metrics, :raise_count, 0),
             "fold_count" => get(metrics, :fold_count, 0)
           }
         }}
      end)

    %{
      winner: get(world, :winner),
      rounds: get(world, :completed_hands, 0) || 0,
      seats: seats
    }
  end
end
