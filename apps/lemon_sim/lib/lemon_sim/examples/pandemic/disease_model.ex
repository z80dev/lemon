defmodule LemonSim.Examples.Pandemic.DiseaseModel do
  @moduledoc """
  Disease mechanics for the Pandemic Response simulation.

  Models an SIR-inspired epidemic across six regions with fog-of-war,
  quarantine effects, hospital capacity, and research-driven parameter change.
  """

  alias LemonSim.Examples.Pandemic.Events

  # Region definitions: id => {name, population, neighbors}
  @regions %{
    "northvale" => %{name: "Northvale", population: 2_800_000},
    "central_hub" => %{name: "Central Hub", population: 5_200_000},
    "highland" => %{name: "Highland", population: 1_900_000},
    "westport" => %{name: "Westport", population: 3_400_000},
    "southshore" => %{name: "Southshore", population: 2_100_000},
    "eastlands" => %{name: "Eastlands", population: 2_600_000}
  }

  # Travel routes (bidirectional adjacency)
  @travel_routes %{
    "northvale" => ["central_hub", "highland"],
    "central_hub" => ["northvale", "highland", "westport", "southshore", "eastlands"],
    "highland" => ["northvale", "central_hub", "eastlands"],
    "westport" => ["central_hub", "southshore"],
    "southshore" => ["westport", "central_hub", "eastlands"],
    "eastlands" => ["highland", "central_hub", "southshore"]
  }

  @default_spread_rate 0.18
  @default_mortality_rate 0.012
  @hospital_capacity_per_unit 200_000
  @quarantine_spread_factor 0.15
  @research_spread_reduction 0.005

  @doc """
  Returns travel routes adjacency map.
  """
  @spec travel_routes() :: map()
  def travel_routes, do: @travel_routes

  @doc """
  Returns initial disease parameters.
  """
  @spec initial_disease(keyword()) :: map()
  def initial_disease(opts \\ []) do
    %{
      spread_rate: Keyword.get(opts, :spread_rate, @default_spread_rate),
      mortality_rate: Keyword.get(opts, :mortality_rate, @default_mortality_rate),
      research_progress: 0
    }
  end

  @doc """
  Builds initial regions map, optionally seeding infection in one region.
  """
  @spec initial_regions(keyword()) :: map()
  def initial_regions(opts \\ []) do
    seed_region = Keyword.get(opts, :seed_region, "central_hub")
    seed_infected = Keyword.get(opts, :seed_infected, 5_000)

    Enum.into(@regions, %{}, fn {id, info} ->
      base = %{
        population: info.population,
        infected: 0,
        recovered: 0,
        dead: 0,
        hospitals: 2,
        quarantined: false,
        vaccinated: 0
      }

      region =
        if id == seed_region do
          Map.put(base, :infected, seed_infected)
        else
          base
        end

      {id, region}
    end)
  end

  @doc """
  Builds a lagged public stats snapshot (what governors see by default).
  """
  @spec build_public_stats(map()) :: map()
  def build_public_stats(regions) do
    Enum.into(regions, %{}, fn {id, r} ->
      # Public stats are approximate — rounded to nearest 1000
      {id,
       %{
         infected_approx: round_to_nearest(r.infected, 1_000),
         dead_approx: round_to_nearest(r.dead, 1_000),
         recovered_approx: round_to_nearest(r.recovered, 1_000),
         hospitals: r.hospitals,
         quarantined: r.quarantined
       }}
    end)
  end

  @doc """
  Simulates one round of disease spread.

  Returns `{updated_regions, spread_events, death_events}`.
  """
  @spec spread(map(), map()) :: {map(), [map()], [map()]}
  def spread(regions, disease) do
    spread_rate = disease.spread_rate
    mortality_rate = disease.mortality_rate

    # Step 1: local spread and deaths within each region
    {regions_after_local, death_events} =
      Enum.reduce(regions, {regions, []}, fn {region_id, region}, {acc_regions, acc_events} ->
        {updated_region, events} =
          apply_local_spread(region_id, region, spread_rate, mortality_rate)

        {Map.put(acc_regions, region_id, updated_region), acc_events ++ events}
      end)

    # Step 2: cross-region travel spread
    {regions_after_travel, spread_events} =
      Enum.reduce(@travel_routes, {regions_after_local, []}, fn {from_id, neighbors},
                                                                {acc_regions, acc_events} ->
        from_region = Map.get(acc_regions, from_id, %{})
        from_infected = Map.get(from_region, :infected, 0)
        from_pop = Map.get(from_region, :population, 1)
        from_quarantined = Map.get(from_region, :quarantined, false)

        if from_infected == 0 do
          {acc_regions, acc_events}
        else
          infection_ratio = from_infected / from_pop
          travel_factor = if from_quarantined, do: @quarantine_spread_factor, else: 1.0

          Enum.reduce(neighbors, {acc_regions, acc_events}, fn neighbor_id,
                                                               {inner_regions, inner_events} ->
            neighbor = Map.get(inner_regions, neighbor_id, %{})
            neighbor_pop = Map.get(neighbor, :population, 1)
            neighbor_infected = Map.get(neighbor, :infected, 0)
            neighbor_recovered = Map.get(neighbor, :recovered, 0)
            neighbor_vaccinated = Map.get(neighbor, :vaccinated, 0)
            neighbor_quarantined = Map.get(neighbor, :quarantined, false)

            susceptible =
              neighbor_pop - neighbor_infected - neighbor_recovered - neighbor_vaccinated

            susceptible = max(0, susceptible)

            if susceptible == 0 do
              {inner_regions, inner_events}
            else
              receive_factor = if neighbor_quarantined, do: @quarantine_spread_factor, else: 1.0
              combined_factor = travel_factor * receive_factor

              new_cases =
                trunc(susceptible * spread_rate * infection_ratio * 0.3 * combined_factor)

              new_cases = min(new_cases, susceptible)

              if new_cases > 0 do
                updated_neighbor =
                  Map.update!(neighbor, :infected, &(&1 + new_cases))

                event =
                  Events.spread_occurred(neighbor_id, new_cases, neighbor_infected + new_cases)

                {Map.put(inner_regions, neighbor_id, updated_neighbor), inner_events ++ [event]}
              else
                {inner_regions, inner_events}
              end
            end
          end)
        end
      end)

    {regions_after_travel, spread_events, death_events}
  end

  @doc """
  Total population across all regions.
  """
  @spec total_population(map()) :: non_neg_integer()
  def total_population(regions) do
    Enum.sum(Enum.map(regions, fn {_, r} -> Map.get(r, :population, 0) end))
  end

  @doc """
  Total deaths across all regions.
  """
  @spec total_deaths(map()) :: non_neg_integer()
  def total_deaths(regions) do
    Enum.sum(Enum.map(regions, fn {_, r} -> Map.get(r, :dead, 0) end))
  end

  @doc """
  Applies research progress to reduce spread rate.
  """
  @spec apply_research(map(), non_neg_integer()) :: map()
  def apply_research(disease, research_points) do
    current_progress = Map.get(disease, :research_progress, 0)
    new_progress = current_progress + research_points

    current_spread = Map.get(disease, :spread_rate, @default_spread_rate)
    reduction = research_points * @research_spread_reduction
    new_spread = max(0.02, current_spread - reduction)

    disease
    |> Map.put(:research_progress, new_progress)
    |> Map.put(:spread_rate, new_spread)
  end

  # -- Private helpers --

  defp apply_local_spread(region_id, region, spread_rate, mortality_rate) do
    pop = Map.get(region, :population, 1)
    infected = Map.get(region, :infected, 0)
    recovered = Map.get(region, :recovered, 0)
    vaccinated = Map.get(region, :vaccinated, 0)
    hospitals = Map.get(region, :hospitals, 1)
    quarantined = Map.get(region, :quarantined, false)

    if infected == 0 do
      {region, []}
    else
      susceptible = max(0, pop - infected - recovered - vaccinated)

      effective_spread =
        if quarantined, do: spread_rate * @quarantine_spread_factor, else: spread_rate

      infection_ratio = infected / pop
      new_cases = trunc(susceptible * effective_spread * infection_ratio)
      new_cases = min(new_cases, susceptible)

      # Recovery: ~20% of infected recover per round
      recovery_count = trunc(infected * 0.20)

      # Deaths: limited by hospital capacity
      hospital_capacity = hospitals * @hospital_capacity_per_unit
      overflow = max(0, infected - hospital_capacity)
      base_deaths = trunc(infected * mortality_rate)
      overflow_deaths = trunc(overflow * mortality_rate * 0.5)
      deaths = min(base_deaths + overflow_deaths, infected - recovery_count)
      deaths = max(0, deaths)

      updated_region =
        region
        |> Map.update!(:infected, &max(0, &1 + new_cases - recovery_count - deaths))
        |> Map.update!(:recovered, &(&1 + recovery_count))
        |> Map.update!(:dead, &(&1 + deaths))

      death_events =
        if deaths > 0 do
          [Events.deaths_recorded(region_id, deaths)]
        else
          []
        end

      {updated_region, death_events}
    end
  end

  defp round_to_nearest(n, _factor) when n == 0, do: 0
  defp round_to_nearest(n, factor), do: round(n / factor) * factor
end
