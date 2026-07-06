defmodule LemonSim.Examples.StockMarket.League do
  @moduledoc """
  Stock Market league adapter for `LemonSim.Bench.League`.

  Ranked mode: each seat's final portfolio value is the outcome, so ratings
  come from pairwise value comparisons — a much finer signal than win/loss.
  Metrics track signaling and trading quality (accurate public calls,
  profitable trades, whispers).
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.StockMarket.Performance

  @behaviour LemonSim.Bench.League.Adapter

  @impl true
  def scenario_id, do: "stock_market"

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
           value: get(metrics, :final_value),
           metrics: %{
             "return_pct" => get(metrics, :return_pct, 0),
             "trades_executed" => get(metrics, :trades_executed, 0),
             "profitable_trades" => get(metrics, :profitable_trades, 0),
             "short_trades" => get(metrics, :short_trades, 0),
             "market_calls_made" => get(metrics, :market_calls_made, 0),
             "accurate_calls" => get(metrics, :accurate_calls, 0),
             "whispers_sent" => get(metrics, :whispers_sent, 0)
           }
         }}
      end)

    %{
      winner: get(world, :winner),
      rounds: get(world, :round, 0),
      seats: seats
    }
  end
end
