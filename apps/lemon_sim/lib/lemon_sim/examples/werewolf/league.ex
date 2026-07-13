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
           value: get(metrics, :role_score, 0.0),
           metrics: %{
             "survived" => boolean_metric(get(metrics, :survived, false)),
             "votes_for_werewolf" => get(metrics, :votes_for_werewolf, 0),
             "votes_for_villager" => get(metrics, :votes_for_villager, 0),
             "skip_votes" => get(metrics, :skip_votes, 0),
             "successful_kills" => get(metrics, :successful_kills, 0),
             "failed_kills" => get(metrics, :failed_kills, 0),
             "wolf_checks_found" => get(metrics, :wolf_checks_found, 0),
             "doctor_saves" => get(metrics, :doctor_saves, 0),
             "protections_of_villagers" => get(metrics, :protections_of_villagers, 0),
             "protections_of_wolves" => get(metrics, :protections_of_wolves, 0),
             "correct_accusations" => get(metrics, :correct_accusations, 0),
             "false_accusations" => get(metrics, :false_accusations, 0),
             "statements" => get(metrics, :statements, 0),
             "role_score" => get(metrics, :role_score, 0.0)
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
