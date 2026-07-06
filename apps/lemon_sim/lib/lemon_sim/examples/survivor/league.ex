defmodule LemonSim.Examples.Survivor.League do
  @moduledoc """
  Survivor league adapter for `LemonSim.Bench.League`.

  Team mode, winner-take-all: the Sole Survivor's seat is the winning side
  and every other seat the losing side, so the winner's model pairs against
  the whole field. Metrics track social-strategy signals (challenge wins,
  whispers, vote quality, idols, jury votes).
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.Survivor.Performance

  @behaviour LemonSim.Bench.League.Adapter

  @impl true
  def scenario_id, do: "survivor"

  @impl true
  def mode, do: :team

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
           value: nil,
           metrics: %{
             "challenge_wins" => get(metrics, :challenge_wins, 0),
             "whispers_sent" => get(metrics, :whispers_sent, 0),
             "correct_votes" => get(metrics, :correct_votes, 0),
             "wrong_votes" => get(metrics, :wrong_votes, 0),
             "idol_plays" => get(metrics, :idol_plays, 0),
             "jury_votes_received" => get(metrics, :jury_votes_received, 0)
           }
         }}
      end)

    %{
      winner: get(world, :winner),
      rounds: length(get(world, :elimination_log, [])),
      seats: seats
    }
  end
end
