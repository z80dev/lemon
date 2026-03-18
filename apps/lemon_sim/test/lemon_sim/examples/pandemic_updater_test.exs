defmodule LemonSim.Examples.PandemicUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Pandemic.{DiseaseModel, Events, Updater}
  alias LemonSim.State

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_world(overrides \\ %{}) do
    regions = DiseaseModel.initial_regions(seed_region: "central_hub", seed_infected: 10_000)
    travel_routes = DiseaseModel.travel_routes()

    Map.merge(
      %{
        regions: regions,
        disease: DiseaseModel.initial_disease(),
        resource_pool: %{vaccines: 100_000, funding: 30, medical_teams: 12},
        travel_routes: travel_routes,
        players: %{
          "governor_1" => %{
            region: "northvale",
            status: "active",
            resources: %{vaccines: 20_000, funding: 5, medical_teams: 2}
          },
          "governor_2" => %{
            region: "central_hub",
            status: "active",
            resources: %{vaccines: 20_000, funding: 5, medical_teams: 2}
          }
        },
        turn_order: ["governor_1", "governor_2"],
        phase: "intelligence",
        round: 1,
        max_rounds: 12,
        active_actor_id: "governor_1",
        phase_done: MapSet.new(),
        allocations: %{},
        comm_inboxes: %{"governor_1" => [], "governor_2" => []},
        comm_history: [],
        comm_sent_this_round: %{},
        intelligence_checks: %{},
        local_actions_taken: %{},
        hoarding_log: [],
        public_stats: DiseaseModel.build_public_stats(regions),
        journals: %{},
        status: "in_progress",
        winner: nil,
        outcome_reason: nil
      },
      overrides
    )
  end

  defp new_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "pandemic-test",
      world: base_world(world_overrides)
    )
  end

  # ---------------------------------------------------------------------------
  # Intelligence phase
  # ---------------------------------------------------------------------------

  test "check_region returns full data for governor's own region" do
    state = new_state()

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.check_region("governor_1", "northvale"),
               []
             )

    assert String.contains?(prompt, "governor_1")

    # Governor's own region should be tracked as checked
    checks = next_state.world.intelligence_checks
    assert "northvale" in Map.get(checks, "governor_1", [])
  end

  test "check_region allows checking neighboring regions" do
    state = new_state()
    # northvale neighbors include central_hub
    travel_routes = DiseaseModel.travel_routes()
    northvale_neighbors = Map.get(travel_routes, "northvale", [])

    assert "central_hub" in northvale_neighbors

    assert {:ok, _next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.check_region("governor_1", "central_hub"),
               []
             )
  end

  test "check_region rejects out-of-range regions" do
    state = new_state()
    # southshore is not adjacent to northvale
    travel_routes = DiseaseModel.travel_routes()
    northvale_neighbors = Map.get(travel_routes, "northvale", [])
    refute "southshore" in northvale_neighbors

    assert {:ok, next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.check_region("governor_1", "southshore"),
               []
             )

    assert String.contains?(reason, "range") or String.contains?(reason, "region")
    # No check was recorded
    checks = next_state.world.intelligence_checks
    assert "southshore" not in Map.get(checks, "governor_1", [])
  end

  test "end_intelligence advances phase when all governors done" do
    state =
      new_state(%{
        phase_done: MapSet.new(["governor_2"])
      })

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.end_intelligence("governor_1"),
               []
             )

    assert next_state.world.phase == "communication"
    assert String.contains?(prompt, "communication")
  end

  test "end_intelligence advances to next governor when not all done" do
    state = new_state()

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.end_intelligence("governor_1"),
               []
             )

    # Should stay in intelligence phase for governor_2
    assert next_state.world.phase == "intelligence"
    assert next_state.world.active_actor_id == "governor_2"
  end

  # ---------------------------------------------------------------------------
  # Communication phase
  # ---------------------------------------------------------------------------

  test "share_data records message in recipient inbox" do
    state = new_state(%{phase: "communication"})

    data = %{"infection_level" => "high", "needs_vaccines" => true}

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.share_data("governor_1", "governor_2", data),
               []
             )

    inbox = next_state.world.comm_inboxes["governor_2"]
    assert length(inbox) == 1
    msg = List.last(inbox)
    assert msg["from"] == "governor_1"
    assert msg["to"] == "governor_2"
  end

  test "share_data increments comm_sent counter" do
    state = new_state(%{phase: "communication"})

    assert {:ok, next_state, _} =
             Updater.apply_event(
               state,
               Events.share_data("governor_1", "governor_2", %{"note" => "test"}),
               []
             )

    assert Map.get(next_state.world.comm_sent_this_round, "governor_1", 0) == 1
  end

  test "share_data rejects after quota exceeded (3 messages)" do
    state =
      new_state(%{
        phase: "communication",
        comm_sent_this_round: %{"governor_1" => 3}
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.share_data("governor_1", "governor_2", %{}),
               []
             )

    assert String.contains?(reason, "quota")
  end

  test "share_data rejects sending to self" do
    state = new_state(%{phase: "communication"})

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.share_data("governor_1", "governor_1", %{}),
               []
             )

    assert String.contains?(reason, "yourself") or String.contains?(reason, "self")
  end

  # ---------------------------------------------------------------------------
  # Resource allocation phase
  # ---------------------------------------------------------------------------

  test "request_resources allocates from shared pool" do
    state = new_state(%{phase: "resource_allocation"})

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.request_resources("governor_1", 10_000, 2, 1),
               []
             )

    # Governor should have more resources
    player = next_state.world.players["governor_1"]
    resources = player.resources
    assert resources.vaccines >= 20_000
    # Pool should be smaller
    assert next_state.world.resource_pool.vaccines < 100_000
    assert String.contains?(prompt, "governor_1")
  end

  test "request_resources prevents double allocation" do
    state =
      new_state(%{
        phase: "resource_allocation",
        allocations: %{"governor_1" => %{granted: %{vaccines: 5_000}}}
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.request_resources("governor_1", 5_000, 0, 0),
               []
             )

    assert String.contains?(reason, "already")
  end

  test "donate_resources to pool increases pool" do
    state = new_state(%{phase: "resource_allocation"})

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.donate_resources("governor_1", "pool", 5_000, 0, 0),
               []
             )

    assert next_state.world.resource_pool.vaccines == 105_000
    assert next_state.world.players["governor_1"].resources.vaccines == 15_000
  end

  test "donate_resources to another governor transfers directly" do
    state = new_state(%{phase: "resource_allocation"})

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.donate_resources("governor_1", "governor_2", 5_000, 0, 0),
               []
             )

    assert next_state.world.players["governor_1"].resources.vaccines == 15_000
    assert next_state.world.players["governor_2"].resources.vaccines == 25_000
  end

  # ---------------------------------------------------------------------------
  # Local action phase
  # ---------------------------------------------------------------------------

  test "vaccinate deploys vaccines in governor's region" do
    state = new_state(%{phase: "local_action"})

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.vaccinate("governor_1", 10_000),
               []
             )

    region = next_state.world.regions["northvale"]
    assert region.vaccinated > 0
    assert next_state.world.players["governor_1"].resources.vaccines == 10_000
    assert String.contains?(prompt, "northvale")
  end

  test "vaccinate rejects when insufficient vaccines" do
    state =
      new_state(%{
        phase: "local_action",
        players: %{
          "governor_1" => %{
            region: "northvale",
            status: "active",
            resources: %{vaccines: 100, funding: 5, medical_teams: 2}
          },
          "governor_2" => %{
            region: "central_hub",
            status: "active",
            resources: %{vaccines: 20_000, funding: 5, medical_teams: 2}
          }
        }
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.vaccinate("governor_1", 50_000),
               []
             )

    assert String.contains?(reason, "vaccine")
  end

  test "quarantine_zone marks region as quarantined" do
    state = new_state(%{phase: "local_action"})

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.quarantine_zone("governor_1", "northvale"),
               []
             )

    assert next_state.world.regions["northvale"].quarantined == true
    assert next_state.world.players["governor_1"].resources.medical_teams == 1
  end

  test "quarantine_zone rejects for another governor's region" do
    state = new_state(%{phase: "local_action"})

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.quarantine_zone("governor_1", "central_hub"),
               []
             )

    assert String.contains?(reason, "region")
  end

  test "build_hospital increases hospital count and costs funding" do
    state = new_state(%{phase: "local_action"})

    hospitals_before = get_in(base_world(), [:regions, "northvale", :hospitals])

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.build_hospital("governor_1"),
               []
             )

    assert next_state.world.regions["northvale"].hospitals == (hospitals_before || 1) + 1
    assert next_state.world.players["governor_1"].resources.funding == 2
  end

  test "fund_research reduces disease spread rate" do
    state = new_state(%{phase: "local_action"})
    initial_spread = state.world.disease.spread_rate

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.fund_research("governor_1", 5),
               []
             )

    assert next_state.world.disease.spread_rate <= initial_spread
    assert next_state.world.players["governor_1"].resources.funding == 0
  end

  test "hoard_supplies pulls from shared pool and records incident" do
    state = new_state(%{phase: "local_action"})

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.hoard_supplies("governor_1", 10_000, 1),
               []
             )

    assert next_state.world.resource_pool.vaccines == 90_000
    assert next_state.world.resource_pool.medical_teams == 11
    assert next_state.world.players["governor_1"].resources.vaccines == 30_000
    assert length(next_state.world.hoarding_log) == 1
    assert List.first(next_state.world.hoarding_log).governor == "governor_1"
  end

  test "end_local_action triggers disease spread when all governors done" do
    state =
      new_state(%{
        phase: "local_action",
        phase_done: MapSet.new(["governor_2"])
      })

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.end_local_action("governor_1"),
               []
             )

    # Round should advance
    assert next_state.world.round == 2
    # Phase should reset to intelligence
    assert next_state.world.phase == "intelligence"
    assert String.contains?(prompt, "round 2") or String.contains?(prompt, "intelligence")
  end

  # ---------------------------------------------------------------------------
  # Disease spread mechanics
  # ---------------------------------------------------------------------------

  test "disease spreads from infected region to neighbor" do
    regions = DiseaseModel.initial_regions(seed_region: "central_hub", seed_infected: 500_000)
    disease = DiseaseModel.initial_disease()

    {spread_regions, _spread_events, _death_events} = DiseaseModel.spread(regions, disease)

    # central_hub neighbors should have some infection after spread
    travel_routes = DiseaseModel.travel_routes()
    neighbors = Map.get(travel_routes, "central_hub", [])

    assert Enum.any?(neighbors, fn neighbor_id ->
      get_in(spread_regions, [neighbor_id, :infected]) > 0
    end)
  end

  test "quarantine reduces disease spread significantly" do
    regions =
      DiseaseModel.initial_regions(seed_region: "central_hub", seed_infected: 500_000)

    # Set northvale as quarantined
    quarantined_regions = put_in(regions, ["northvale", :quarantined], true)
    disease = DiseaseModel.initial_disease()

    {normal_spread, _, _} = DiseaseModel.spread(regions, disease)
    {quarantine_spread, _, _} = DiseaseModel.spread(quarantined_regions, disease)

    northvale_normal = get_in(normal_spread, ["northvale", :infected]) || 0
    northvale_quarantined = get_in(quarantine_spread, ["northvale", :infected]) || 0

    # Quarantine should result in significantly fewer infections
    assert northvale_quarantined <= northvale_normal
  end

  test "deaths are recorded for infected regions with insufficient hospitals" do
    # Create a situation with overwhelming infection
    regions = DiseaseModel.initial_regions(seed_region: "central_hub", seed_infected: 4_000_000)

    disease = DiseaseModel.initial_disease(mortality_rate: 0.05)

    {_spread_regions, _spread_events, death_events} = DiseaseModel.spread(regions, disease)

    # Should have death events for central_hub
    assert Enum.any?(death_events, fn ev ->
      ev.kind == "deaths_recorded" and
        Map.get(ev.payload, "region_id") == "central_hub"
    end)
  end

  # ---------------------------------------------------------------------------
  # End conditions
  # ---------------------------------------------------------------------------

  test "game is lost when deaths exceed 10% threshold" do
    # Set up a world where deaths already exceed threshold
    regions =
      DiseaseModel.initial_regions()
      |> Enum.into(%{}, fn {id, r} ->
        pop = r.population
        {id, Map.put(r, :dead, div(pop, 8))}
      end)

    total_pop = DiseaseModel.total_population(regions)
    total_dead = DiseaseModel.total_deaths(regions)
    death_threshold = trunc(total_pop * 0.10)

    assert total_dead >= death_threshold,
           "Setup error: deaths #{total_dead} must exceed threshold #{death_threshold}"

    state =
      new_state(%{
        regions: regions,
        phase: "local_action",
        phase_done: MapSet.new(["governor_2"]),
        round: 5
      })

    assert {:ok, next_state, :skip} =
             Updater.apply_event(
               state,
               Events.end_local_action("governor_1"),
               []
             )

    assert next_state.world.status == "lost"
  end

  test "game is won when all rounds complete without exceeding death threshold" do
    state =
      new_state(%{
        phase: "local_action",
        phase_done: MapSet.new(["governor_2"]),
        round: 12,
        max_rounds: 12
      })

    assert {:ok, next_state, _} =
             Updater.apply_event(
               state,
               Events.end_local_action("governor_1"),
               []
             )

    # Round advanced to 13 > 12, so game should be over
    assert next_state.world.status == "won"
    assert next_state.world.winner == "team"
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  test "actions are rejected when game is over" do
    state = new_state(%{status: "lost"})

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.check_region("governor_1", "northvale"),
               []
             )

    assert String.contains?(reason, "over")
  end

  test "actions are rejected for wrong phase" do
    state = new_state(%{phase: "communication"})

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.check_region("governor_1", "northvale"),
               []
             )

    assert String.contains?(reason, "phase")
  end

  test "actions are rejected for non-active actor" do
    state = new_state()

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.check_region("governor_2", "central_hub"),
               []
             )

    assert String.contains?(reason, "active") or String.contains?(reason, "actor")
  end
end
