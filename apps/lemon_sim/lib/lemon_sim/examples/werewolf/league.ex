defmodule LemonSim.Examples.Werewolf.League do
  @moduledoc """
  Werewolf league adapter for `LemonSim.Bench.League`.

  Team mode: villagers vs werewolves. Seats carry the role each model played
  plus the scorecard's role-execution counters, so standings break down per
  role (werewolf / seer / doctor / villager).
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.Werewolf.Performance

  @behaviour LemonSim.Bench.League.Adapter

  @impl true
  def scenario_id, do: "werewolf"

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
           role: get(metrics, :role),
           won: get(metrics, :team_won, false),
           value: nil,
           metrics: %{
             "survived" => boolean_metric(get(metrics, :survived, false)),
             "votes_for_werewolf" => get(metrics, :votes_for_werewolf, 0),
             "votes_for_villager" => get(metrics, :votes_for_villager, 0),
             "skip_votes" => get(metrics, :skip_votes, 0),
             "successful_kills" => get(metrics, :successful_kills, 0),
             "failed_kills" => get(metrics, :failed_kills, 0),
             "wolf_checks_found" => get(metrics, :wolf_checks_found, 0),
             "doctor_saves" => get(metrics, :doctor_saves, 0)
           }
         }}
      end)

    %{
      winner: get(world, :winner),
      rounds: get(world, :day_number, 0),
      seats: seats
    }
  end

  defp boolean_metric(true), do: 1
  defp boolean_metric(_), do: 0
end
