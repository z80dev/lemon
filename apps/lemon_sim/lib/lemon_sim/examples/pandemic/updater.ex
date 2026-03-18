defmodule LemonSim.Examples.Pandemic.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.Pandemic.{DiseaseModel, Events}

  @comm_quota 3
  @hospital_funding_cost 3
  @quarantine_team_cost 1

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "check_region" -> apply_check_region(state, event)
      "end_intelligence" -> apply_end_phase(state, event, "intelligence", "communication")
      "share_data" -> apply_share_data(state, event)
      "request_help" -> apply_request_help(state, event)
      "end_communication" -> apply_end_phase(state, event, "communication", "resource_allocation")
      "request_resources" -> apply_request_resources(state, event)
      "donate_resources" -> apply_donate_resources(state, event)
      "end_resource_allocation" -> apply_end_phase(state, event, "resource_allocation", "local_action")
      "vaccinate" -> apply_vaccinate(state, event)
      "quarantine_zone" -> apply_quarantine_zone(state, event)
      "build_hospital" -> apply_build_hospital(state, event)
      "fund_research" -> apply_fund_research(state, event)
      "hoard_supplies" -> apply_hoard_supplies(state, event)
      "end_local_action" -> apply_end_local_action(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Intelligence phase --

  defp apply_check_region(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")
    region_id = fetch(event.payload, :region_id, "region_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "intelligence"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_region_in_range(state.world, governor_id, region_id) do
      checks = get(state.world, :intelligence_checks, %{})
      governor_checks = Map.get(checks, governor_id, [])
      updated_checks = Map.put(checks, governor_id, Enum.uniq(governor_checks ++ [region_id]))

      next_world = Map.put(state.world, :intelligence_checks, updated_checks)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state,
       {:decide, "#{governor_id} checked region #{region_id}, continue intelligence phase"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  # -- Generic phase-end handler --

  defp apply_end_phase(%State{} = state, event, current_phase, next_phase) do
    governor_id = extract_governor_id(event)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, current_phase),
         :ok <- ensure_active_actor(state.world, governor_id) do
      phase_done = get(state.world, :phase_done, MapSet.new())
      phase_done = MapSet.put(phase_done, governor_id)
      next_world = Map.put(state.world, :phase_done, phase_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      active_players = active_governor_ids(next_world)
      all_done = Enum.all?(active_players, &MapSet.member?(phase_done, &1))

      if all_done do
        # Transition to next phase
        next_world2 =
          next_world
          |> Map.put(:phase, next_phase)
          |> Map.put(:phase_done, MapSet.new())
          |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed(current_phase, next_phase))

        {:ok, next_state2,
         {:decide,
          "all governors finished #{current_phase}, now in #{next_phase} phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        {next_world2, _} = advance_to_next_governor(next_world, governor_id, phase_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{governor_id} finished #{current_phase}, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  # -- Communication phase --

  defp apply_share_data(%State{} = state, event) do
    from_id = fetch(event.payload, :from_id, "from_id")
    to_id = fetch(event.payload, :to_id, "to_id")
    data = fetch(event.payload, :data, "data", %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communication"),
         :ok <- ensure_active_actor(state.world, from_id),
         :ok <- ensure_not_self_comm(from_id, to_id),
         :ok <- ensure_valid_governor(state.world, to_id),
         :ok <- ensure_comm_quota(state.world, from_id) do
      inboxes = get(state.world, :comm_inboxes, %{})
      to_inbox = Map.get(inboxes, to_id, [])
      round = get(state.world, :round, 1)

      msg = %{
        "from" => from_id,
        "to" => to_id,
        "type" => "data",
        "data" => data,
        "round" => round
      }

      updated_inboxes = Map.put(inboxes, to_id, to_inbox ++ [msg])

      comm_sent = get(state.world, :comm_sent_this_round, %{})
      updated_sent = Map.update(comm_sent, from_id, 1, &(&1 + 1))

      comm_history = get(state.world, :comm_history, [])

      next_world =
        state.world
        |> Map.put(:comm_inboxes, updated_inboxes)
        |> Map.put(:comm_sent_this_round, updated_sent)
        |> Map.put(:comm_history, comm_history ++ [%{from: from_id, to: to_id, type: "data", round: round}])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.data_shared(from_id, to_id, data))

      {:ok, next_state, {:decide, "#{from_id} shared data with #{to_id}, continue communication"}}
    else
      {:error, reason} ->
        reject_action(state, event, from_id, reason)
    end
  end

  defp apply_request_help(%State{} = state, event) do
    from_id = fetch(event.payload, :from_id, "from_id")
    to_id = fetch(event.payload, :to_id, "to_id")
    message = fetch(event.payload, :message, "message", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "communication"),
         :ok <- ensure_active_actor(state.world, from_id),
         :ok <- ensure_not_self_comm(from_id, to_id),
         :ok <- ensure_valid_governor(state.world, to_id),
         :ok <- ensure_comm_quota(state.world, from_id) do
      inboxes = get(state.world, :comm_inboxes, %{})
      to_inbox = Map.get(inboxes, to_id, [])
      round = get(state.world, :round, 1)

      msg = %{
        "from" => from_id,
        "to" => to_id,
        "type" => "help_request",
        "message" => message,
        "round" => round
      }

      updated_inboxes = Map.put(inboxes, to_id, to_inbox ++ [msg])

      comm_sent = get(state.world, :comm_sent_this_round, %{})
      updated_sent = Map.update(comm_sent, from_id, 1, &(&1 + 1))

      comm_history = get(state.world, :comm_history, [])

      next_world =
        state.world
        |> Map.put(:comm_inboxes, updated_inboxes)
        |> Map.put(:comm_sent_this_round, updated_sent)
        |> Map.put(:comm_history, comm_history ++ [%{from: from_id, to: to_id, type: "help_request", round: round}])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{from_id} requested help from #{to_id}, continue communication"}}
    else
      {:error, reason} ->
        reject_action(state, event, from_id, reason)
    end
  end

  # -- Resource allocation phase --

  defp apply_request_resources(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")
    vaccines = fetch(event.payload, :vaccines, "vaccines", 0)
    funding = fetch(event.payload, :funding, "funding", 0)
    medical_teams = fetch(event.payload, :medical_teams, "medical_teams", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "resource_allocation"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_not_already_allocated(state.world, governor_id),
         :ok <- ensure_pool_has(state.world, vaccines, funding, medical_teams) do
      pool = get(state.world, :resource_pool, %{})
      players = get(state.world, :players, %{})
      player = Map.get(players, governor_id, %{})
      resources = Map.get(player, :resources, %{})

      new_pool =
        pool
        |> Map.update(:vaccines, 0, &max(0, &1 - vaccines))
        |> Map.update(:funding, 0, &max(0, &1 - funding))
        |> Map.update(:medical_teams, 0, &max(0, &1 - medical_teams))

      new_resources =
        resources
        |> Map.update(:vaccines, vaccines, &(&1 + vaccines))
        |> Map.update(:funding, funding, &(&1 + funding))
        |> Map.update(:medical_teams, medical_teams, &(&1 + medical_teams))

      allocations = get(state.world, :allocations, %{})

      next_world =
        state.world
        |> Map.put(:resource_pool, new_pool)
        |> Map.put(:players, Map.put(players, governor_id, Map.put(player, :resources, new_resources)))
        |> Map.put(:allocations, Map.put(allocations, governor_id, %{granted: %{vaccines: vaccines, funding: funding, medical_teams: medical_teams}}))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{governor_id} received resources from pool, end your turn or donate"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  defp apply_donate_resources(%State{} = state, event) do
    from_id = fetch(event.payload, :from_id, "from_id")
    to_id = fetch(event.payload, :to_id, "to_id")
    vaccines = fetch(event.payload, :vaccines, "vaccines", 0)
    funding = fetch(event.payload, :funding, "funding", 0)
    medical_teams = fetch(event.payload, :medical_teams, "medical_teams", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "resource_allocation"),
         :ok <- ensure_active_actor(state.world, from_id),
         :ok <- ensure_donor_has(state.world, from_id, vaccines, funding, medical_teams) do
      players = get(state.world, :players, %{})
      from_player = Map.get(players, from_id, %{})
      from_resources = Map.get(from_player, :resources, %{})

      new_from_resources =
        from_resources
        |> Map.update(:vaccines, 0, &max(0, &1 - vaccines))
        |> Map.update(:funding, 0, &max(0, &1 - funding))
        |> Map.update(:medical_teams, 0, &max(0, &1 - medical_teams))

      updated_players =
        if to_id == "pool" do
          pool = get(state.world, :resource_pool, %{})

          new_pool =
            pool
            |> Map.update(:vaccines, vaccines, &(&1 + vaccines))
            |> Map.update(:funding, funding, &(&1 + funding))
            |> Map.update(:medical_teams, medical_teams, &(&1 + medical_teams))

          {Map.put(players, from_id, Map.put(from_player, :resources, new_from_resources)),
           new_pool}
        else
          to_player = Map.get(players, to_id, %{})
          to_resources = Map.get(to_player, :resources, %{})

          new_to_resources =
            to_resources
            |> Map.update(:vaccines, vaccines, &(&1 + vaccines))
            |> Map.update(:funding, funding, &(&1 + funding))
            |> Map.update(:medical_teams, medical_teams, &(&1 + medical_teams))

          {players
           |> Map.put(from_id, Map.put(from_player, :resources, new_from_resources))
           |> Map.put(to_id, Map.put(to_player, :resources, new_to_resources)),
           get(state.world, :resource_pool, %{})}
        end

      {new_players, new_pool} = updated_players

      next_world =
        state.world
        |> Map.put(:players, new_players)
        |> Map.put(:resource_pool, new_pool)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state,
       {:decide, "#{from_id} donated resources to #{to_id}, continue allocation phase"}}
    else
      {:error, reason} ->
        reject_action(state, event, from_id, reason)
    end
  end

  # -- Local action phase --

  defp apply_vaccinate(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")
    count = fetch(event.payload, :count, "count", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "local_action"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_governor_has_vaccines(state.world, governor_id, count) do
      players = get(state.world, :players, %{})
      player = Map.get(players, governor_id, %{})
      region_id = Map.get(player, :region, governor_id)
      resources = Map.get(player, :resources, %{})

      new_resources = Map.update(resources, :vaccines, 0, &max(0, &1 - count))

      regions = get(state.world, :regions, %{})
      region = Map.get(regions, region_id, %{})

      pop = Map.get(region, :population, 1)
      already_vaccinated = Map.get(region, :vaccinated, 0)
      max_vaccinatable = max(0, pop - already_vaccinated)
      actual_vaccinated = min(count, max_vaccinatable)

      new_region = Map.update(region, :vaccinated, actual_vaccinated, &(&1 + actual_vaccinated))

      next_world =
        state.world
        |> Map.put(:regions, Map.put(regions, region_id, new_region))
        |> Map.put(:players, Map.put(players, governor_id, Map.put(player, :resources, new_resources)))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state,
       {:decide, "#{governor_id} vaccinated #{actual_vaccinated} people in #{region_id}"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  defp apply_quarantine_zone(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")
    region_id = fetch(event.payload, :region_id, "region_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "local_action"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_owns_region(state.world, governor_id, region_id),
         :ok <- ensure_has_medical_teams(state.world, governor_id, @quarantine_team_cost) do
      players = get(state.world, :players, %{})
      player = Map.get(players, governor_id, %{})
      resources = Map.get(player, :resources, %{})
      new_resources = Map.update(resources, :medical_teams, 0, &max(0, &1 - @quarantine_team_cost))

      regions = get(state.world, :regions, %{})
      region = Map.get(regions, region_id, %{})
      new_region = Map.put(region, :quarantined, true)

      next_world =
        state.world
        |> Map.put(:regions, Map.put(regions, region_id, new_region))
        |> Map.put(:players, Map.put(players, governor_id, Map.put(player, :resources, new_resources)))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{governor_id} quarantined #{region_id}"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  defp apply_build_hospital(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "local_action"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_has_funding(state.world, governor_id, @hospital_funding_cost) do
      players = get(state.world, :players, %{})
      player = Map.get(players, governor_id, %{})
      region_id = Map.get(player, :region, governor_id)
      resources = Map.get(player, :resources, %{})
      new_resources = Map.update(resources, :funding, 0, &max(0, &1 - @hospital_funding_cost))

      regions = get(state.world, :regions, %{})
      region = Map.get(regions, region_id, %{})
      new_region = Map.update(region, :hospitals, 1, &(&1 + 1))

      next_world =
        state.world
        |> Map.put(:regions, Map.put(regions, region_id, new_region))
        |> Map.put(:players, Map.put(players, governor_id, Map.put(player, :resources, new_resources)))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, "#{governor_id} built a hospital in #{region_id}"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  defp apply_fund_research(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")
    funding = fetch(event.payload, :funding, "funding", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "local_action"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_has_funding(state.world, governor_id, funding) do
      players = get(state.world, :players, %{})
      player = Map.get(players, governor_id, %{})
      resources = Map.get(player, :resources, %{})
      new_resources = Map.update(resources, :funding, 0, &max(0, &1 - funding))

      disease = get(state.world, :disease, %{})
      updated_disease = DiseaseModel.apply_research(disease, funding)

      next_world =
        state.world
        |> Map.put(:disease, updated_disease)
        |> Map.put(:players, Map.put(players, governor_id, Map.put(player, :resources, new_resources)))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state,
       {:decide,
        "#{governor_id} funded #{funding} research points, spread rate is now #{Float.round(updated_disease.spread_rate, 4)}"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  defp apply_hoard_supplies(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")
    vaccines = fetch(event.payload, :vaccines, "vaccines", 0)
    medical_teams = fetch(event.payload, :medical_teams, "medical_teams", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "local_action"),
         :ok <- ensure_active_actor(state.world, governor_id),
         :ok <- ensure_pool_has_hoard(state.world, vaccines, medical_teams) do
      pool = get(state.world, :resource_pool, %{})
      players = get(state.world, :players, %{})
      player = Map.get(players, governor_id, %{})
      resources = Map.get(player, :resources, %{})

      new_pool =
        pool
        |> Map.update(:vaccines, 0, &max(0, &1 - vaccines))
        |> Map.update(:medical_teams, 0, &max(0, &1 - medical_teams))

      new_resources =
        resources
        |> Map.update(:vaccines, vaccines, &(&1 + vaccines))
        |> Map.update(:medical_teams, medical_teams, &(&1 + medical_teams))

      round = get(state.world, :round, 1)
      hoarding_log = get(state.world, :hoarding_log, [])

      next_world =
        state.world
        |> Map.put(:resource_pool, new_pool)
        |> Map.put(:players, Map.put(players, governor_id, Map.put(player, :resources, new_resources)))
        |> Map.put(:hoarding_log, hoarding_log ++ [%{governor: governor_id, round: round, vaccines: vaccines, medical_teams: medical_teams}])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state,
       {:decide, "#{governor_id} hoarded supplies from the shared pool (this has been logged)"}}
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  # -- End local action: triggers spread then round advance --

  defp apply_end_local_action(%State{} = state, event) do
    governor_id = fetch(event.payload, :governor_id, "governor_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "local_action"),
         :ok <- ensure_active_actor(state.world, governor_id) do
      phase_done = get(state.world, :phase_done, MapSet.new())
      phase_done = MapSet.put(phase_done, governor_id)
      next_world = Map.put(state.world, :phase_done, phase_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      active_players = active_governor_ids(next_world)
      all_done = Enum.all?(active_players, &MapSet.member?(phase_done, &1))

      if all_done do
        # Trigger disease spread, then advance round
        {next_world2, spread_events} = execute_spread(next_world)
        {next_world3, outcome_events, outcome} = check_and_advance_round(next_world2)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world3 end)
          |> State.append_events(spread_events)
          |> State.append_events(outcome_events)

        {:ok, next_state2, outcome}
      else
        {next_world2, _} = advance_to_next_governor(next_world, governor_id, phase_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{governor_id} finished local actions, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, governor_id, reason)
    end
  end

  # -- Spread + round advance --

  defp execute_spread(world) do
    regions = get(world, :regions, %{})
    disease = get(world, :disease, %{})

    {updated_regions, spread_events, death_events} = DiseaseModel.spread(regions, disease)

    # Update public stats with lagged data (from before spread)
    new_public_stats = DiseaseModel.build_public_stats(updated_regions)

    next_world =
      world
      |> Map.put(:regions, updated_regions)
      |> Map.put(:public_stats, new_public_stats)

    {next_world, spread_events ++ death_events}
  end

  defp check_and_advance_round(world) do
    regions = get(world, :regions, %{})
    round = get(world, :round, 1)
    max_rounds = get(world, :max_rounds, 12)

    total_pop = DiseaseModel.total_population(regions)
    total_dead = DiseaseModel.total_deaths(regions)
    death_threshold = trunc(total_pop * 0.10)

    cond do
      total_dead >= death_threshold ->
        reason = "Deaths (#{total_dead}) exceeded 10% threshold (#{death_threshold})"

        final_world =
          world
          |> Map.put(:status, "lost")
          |> Map.put(:winner, nil)
          |> Map.put(:outcome_reason, reason)

        events = [Events.game_over("lost", nil, reason)]
        {final_world, events, :skip}

      round >= max_rounds ->
        reason = "Team successfully contained the pandemic over #{max_rounds} rounds"

        final_world =
          world
          |> Map.put(:status, "won")
          |> Map.put(:winner, "team")
          |> Map.put(:outcome_reason, reason)

        events = [Events.game_over("won", "team", reason)]
        {final_world, events, :skip}

      true ->
        next_round = round + 1

        next_world =
          world
          |> Map.put(:round, next_round)
          |> Map.put(:phase, "intelligence")
          |> Map.put(:phase_done, MapSet.new())
          |> Map.put(:allocations, %{})
          |> Map.put(:comm_sent_this_round, %{})
          |> Map.put(:comm_inboxes, reset_inboxes(world))
          |> Map.put(:intelligence_checks, %{})
          |> Map.put(:local_actions_taken, %{})
          |> Map.put(:active_actor_id, List.first(get(world, :turn_order, [])))

        events = [
          Events.phase_changed("local_action", "intelligence"),
          Events.round_advanced(next_round)
        ]

        {next_world, events,
         {:decide, "round #{next_round} begins, intelligence phase for #{List.first(get(next_world, :turn_order, []))}"}}
    end
  end

  defp reset_inboxes(world) do
    players = get(world, :players, %{})
    Enum.into(players, %{}, fn {id, _} -> {id, []} end)
  end

  # -- Phase helpers --

  defp advance_to_next_governor(world, current_id, done_set) do
    turn_order = get(world, :turn_order, [])
    active = active_governor_ids(world)

    remaining =
      turn_order
      |> Enum.filter(&(&1 in active))
      |> Enum.reject(&MapSet.member?(done_set, &1))

    next =
      case remaining do
        [] -> current_id
        [first | _] -> first
      end

    {Map.put(world, :active_actor_id, next), []}
  end

  defp active_governor_ids(world) do
    players = get(world, :players, %{})

    players
    |> Enum.filter(fn {_id, info} -> Map.get(info, :status, "active") == "active" end)
    |> Enum.map(fn {id, _} -> id end)
  end

  defp extract_governor_id(event) do
    fetch(event.payload, :governor_id, "governor_id")
  end

  # -- Validation --

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :game_over}
  end

  defp ensure_phase(world, expected) do
    if get(world, :phase, nil) == expected,
      do: :ok,
      else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, governor_id) do
    if MapHelpers.get_key(world, :active_actor_id) == governor_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp ensure_valid_governor(world, governor_id) do
    players = get(world, :players, %{})

    if Map.has_key?(players, governor_id),
      do: :ok,
      else: {:error, :invalid_governor}
  end

  defp ensure_not_self_comm(from_id, to_id) do
    if from_id != to_id,
      do: :ok,
      else: {:error, :cannot_message_self}
  end

  defp ensure_comm_quota(world, governor_id) do
    sent = get(world, :comm_sent_this_round, %{})
    count = Map.get(sent, governor_id, 0)

    if count < @comm_quota,
      do: :ok,
      else: {:error, :comm_quota_exceeded}
  end

  defp ensure_region_in_range(world, governor_id, region_id) do
    players = get(world, :players, %{})
    player = Map.get(players, governor_id, %{})
    own_region = Map.get(player, :region, governor_id)
    travel_routes = get(world, :travel_routes, %{})
    neighbors = Map.get(travel_routes, own_region, [])

    if region_id == own_region or region_id in neighbors,
      do: :ok,
      else: {:error, :region_out_of_range}
  end

  defp ensure_not_already_allocated(world, governor_id) do
    allocations = get(world, :allocations, %{})

    if Map.has_key?(allocations, governor_id),
      do: {:error, :already_allocated},
      else: :ok
  end

  defp ensure_pool_has(world, vaccines, funding, medical_teams) do
    pool = get(world, :resource_pool, %{})

    cond do
      Map.get(pool, :vaccines, 0) < vaccines -> {:error, :insufficient_pool_vaccines}
      Map.get(pool, :funding, 0) < funding -> {:error, :insufficient_pool_funding}
      Map.get(pool, :medical_teams, 0) < medical_teams -> {:error, :insufficient_pool_teams}
      true -> :ok
    end
  end

  defp ensure_pool_has_hoard(world, vaccines, medical_teams) do
    pool = get(world, :resource_pool, %{})

    cond do
      Map.get(pool, :vaccines, 0) < vaccines -> {:error, :insufficient_pool_vaccines}
      Map.get(pool, :medical_teams, 0) < medical_teams -> {:error, :insufficient_pool_teams}
      true -> :ok
    end
  end

  defp ensure_donor_has(world, governor_id, vaccines, funding, medical_teams) do
    players = get(world, :players, %{})
    player = Map.get(players, governor_id, %{})
    resources = Map.get(player, :resources, %{})

    cond do
      Map.get(resources, :vaccines, 0) < vaccines -> {:error, :insufficient_vaccines}
      Map.get(resources, :funding, 0) < funding -> {:error, :insufficient_funding}
      Map.get(resources, :medical_teams, 0) < medical_teams -> {:error, :insufficient_teams}
      true -> :ok
    end
  end

  defp ensure_governor_has_vaccines(world, governor_id, count) do
    players = get(world, :players, %{})
    player = Map.get(players, governor_id, %{})
    resources = Map.get(player, :resources, %{})

    if Map.get(resources, :vaccines, 0) >= count,
      do: :ok,
      else: {:error, :insufficient_vaccines}
  end

  defp ensure_has_medical_teams(world, governor_id, required) do
    players = get(world, :players, %{})
    player = Map.get(players, governor_id, %{})
    resources = Map.get(player, :resources, %{})

    if Map.get(resources, :medical_teams, 0) >= required,
      do: :ok,
      else: {:error, :insufficient_teams}
  end

  defp ensure_has_funding(world, governor_id, required) do
    players = get(world, :players, %{})
    player = Map.get(players, governor_id, %{})
    resources = Map.get(player, :resources, %{})

    if Map.get(resources, :funding, 0) >= required,
      do: :ok,
      else: {:error, :insufficient_funding}
  end

  defp ensure_owns_region(world, governor_id, region_id) do
    players = get(world, :players, %{})
    player = Map.get(players, governor_id, %{})
    own_region = Map.get(player, :region, nil)

    if own_region == region_id,
      do: :ok,
      else: {:error, :not_your_region}
  end

  # -- Error handling --

  defp reject_action(%State{} = state, event, governor_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(event.kind, to_string(governor_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:wrong_phase), do: "wrong phase for this action"
  defp rejection_reason(:not_active_actor), do: "not the active actor"
  defp rejection_reason(:invalid_governor), do: "invalid governor id"
  defp rejection_reason(:cannot_message_self), do: "cannot send message to yourself"
  defp rejection_reason(:comm_quota_exceeded), do: "communication quota exceeded (max #{@comm_quota} per round)"
  defp rejection_reason(:region_out_of_range), do: "region is out of range - can only check own region or neighbors"
  defp rejection_reason(:already_allocated), do: "resources already allocated this round"
  defp rejection_reason(:insufficient_pool_vaccines), do: "not enough vaccines in shared pool"
  defp rejection_reason(:insufficient_pool_funding), do: "not enough funding in shared pool"
  defp rejection_reason(:insufficient_pool_teams), do: "not enough medical teams in shared pool"
  defp rejection_reason(:insufficient_vaccines), do: "insufficient vaccines"
  defp rejection_reason(:insufficient_funding), do: "insufficient funding"
  defp rejection_reason(:insufficient_teams), do: "insufficient medical teams"
  defp rejection_reason(:not_your_region), do: "can only act on your own region"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"
end
