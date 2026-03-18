defmodule LemonSim.Examples.Pandemic.Performance do
  @moduledoc """
  Objective performance summary for Pandemic Response runs.

  Tracks cooperative outcomes alongside per-governor metrics:
  vaccinations deployed, research funded, hoarding incidents, and
  regional death rates relative to population.
  """

  import LemonSim.GameHelpers

  alias LemonSim.Examples.Pandemic.DiseaseModel

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    regions = get(world, :regions, %{})
    status = get(world, :status, "in_progress")
    winner = get(world, :winner)
    outcome_reason = get(world, :outcome_reason)
    hoarding_log = get(world, :hoarding_log, [])
    comm_history = get(world, :comm_history, [])

    total_pop = DiseaseModel.total_population(regions)
    total_dead = DiseaseModel.total_deaths(regions)
    total_infected = Enum.sum(Enum.map(regions, fn {_, r} -> Map.get(r, :infected, 0) end))
    total_recovered = Enum.sum(Enum.map(regions, fn {_, r} -> Map.get(r, :recovered, 0) end))
    total_vaccinated = Enum.sum(Enum.map(regions, fn {_, r} -> Map.get(r, :vaccinated, 0) end))
    global_death_rate = if total_pop > 0, do: Float.round(total_dead / total_pop * 100, 2), else: 0.0

    player_metrics =
      Enum.into(players, %{}, fn {governor_id, info} ->
        region_id = Map.get(info, :region, governor_id)
        region = Map.get(regions, region_id, %{})
        pop = Map.get(region, :population, 1)
        dead = Map.get(region, :dead, 0)
        regional_death_rate = if pop > 0, do: Float.round(dead / pop * 100, 2), else: 0.0
        vaccinated = Map.get(region, :vaccinated, 0)
        hospitals = Map.get(region, :hospitals, 0)

        hoarding_count =
          Enum.count(hoarding_log, fn h ->
            Map.get(h, :governor, Map.get(h, "governor")) == governor_id
          end)

        messages_sent =
          Enum.count(comm_history, fn m ->
            Map.get(m, :from, Map.get(m, "from")) == governor_id
          end)

        {governor_id,
         %{
           model: get(info, :model),
           region: region_id,
           regional_death_rate: regional_death_rate,
           regional_dead: dead,
           regional_population: pop,
           vaccinated: vaccinated,
           hospitals_built: max(0, hospitals - 2),
           hoarding_incidents: hoarding_count,
           messages_sent: messages_sent,
           team_won: status == "won"
         }}
      end)

    disease = get(world, :disease, %{})

    %{
      benchmark_focus: "cooperative pandemic containment, vaccination coverage, research investment",
      status: status,
      winner: winner,
      outcome_reason: outcome_reason,
      rounds_played: get(world, :round, 1),
      team: %{
        won: status == "won",
        total_population: total_pop,
        total_dead: total_dead,
        total_infected: total_infected,
        total_recovered: total_recovered,
        total_vaccinated: total_vaccinated,
        global_death_rate: global_death_rate,
        death_threshold: trunc(total_pop * 0.10),
        final_spread_rate: Float.round(Map.get(disease, :spread_rate, 0.18), 4),
        research_progress: Map.get(disease, :research_progress, 0),
        total_hoarding_incidents: length(hoarding_log)
      },
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn {_governor_id, metrics} -> get(metrics, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics_list = Enum.map(entries, fn {_id, m} -> m end)

      {model,
       %{
         seats: length(metrics_list),
         team_wins: Enum.count(metrics_list, &get(&1, :team_won, false)),
         total_vaccinated: Enum.sum(Enum.map(metrics_list, &get(&1, :vaccinated, 0))),
         total_hoarding: Enum.sum(Enum.map(metrics_list, &get(&1, :hoarding_incidents, 0))),
         messages_sent: Enum.sum(Enum.map(metrics_list, &get(&1, :messages_sent, 0))),
         avg_regional_death_rate:
           if length(metrics_list) > 0 do
             Float.round(
               Enum.sum(Enum.map(metrics_list, &get(&1, :regional_death_rate, 0.0))) /
                 length(metrics_list),
               2
             )
           else
             0.0
           end
       }}
    end)
  end
end
