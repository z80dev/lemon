defmodule LemonSim.Examples.SpaceStation.League do
  @moduledoc """
  Space Station Crisis league adapter for `LemonSim.Bench.League`.

  Team mode: crew vs saboteur. Seats carry the role each model played
  (saboteur / engineer / captain / crew) plus the scorecard's coordination
  and deception counters.
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.SpaceStation.Performance

  @behaviour LemonSim.Bench.League.Adapter

  @impl true
  def scenario_id, do: "space_station"

  @impl true
  def mode, do: :team

  @impl true
  def game_summary(world) do
    seats =
      Performance.summarize(world)
      # Space station's scorecard reports players as a list of maps that
      # each carry their own player_id.
      |> Map.fetch!(:players)
      |> Enum.into(%{}, fn metrics ->
        {to_string(get(metrics, :player_id)),
         %{
           model: get(metrics, :model),
           role: get(metrics, :role),
           won: get(metrics, :team_won, false),
           value: nil,
           metrics: %{
             "survived" => boolean_metric(get(metrics, :survived, false)),
             "repairs" => get(metrics, :repairs, 0),
             "sabotages" => get(metrics, :sabotages, 0),
             "fake_repairs" => get(metrics, :fake_repairs, 0),
             "scans" => get(metrics, :scans, 0),
             "correct_votes" => get(metrics, :correct_votes, 0),
             "wrong_votes" => get(metrics, :wrong_votes, 0),
             "voted_for_saboteur" => boolean_metric(get(metrics, :voted_for_saboteur, false)),
             "was_ejected" => boolean_metric(get(metrics, :was_ejected, false))
           }
         }}
      end)

    %{
      winner: get(world, :winner),
      rounds: get(world, :round, 0),
      seats: seats
    }
  end

  defp boolean_metric(true), do: 1
  defp boolean_metric(_), do: 0
end
