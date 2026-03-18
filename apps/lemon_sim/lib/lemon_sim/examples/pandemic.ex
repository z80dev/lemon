defmodule LemonSim.Examples.Pandemic do
  @moduledoc """
  Pandemic Response cooperative simulation built on LemonSim.

  A 4-6 player cooperative game where regional governors must contain a disease
  outbreak. Each round progresses through four phases:

  1. **Intelligence** - Governors gather real-time regional disease data (fog of war)
  2. **Communication** - Governors share data and coordinate (may mislead)
  3. **Resource Allocation** - Governors request from shared pool of vaccines/funding/teams
  4. **Local Action** - Governors deploy vaccines, quarantine zones, hospitals, and research

  After all local actions, disease spreads automatically according to the SIR model.

  Win condition: Keep deaths below 10% of total population for all max_rounds rounds.
  Lose condition: Deaths exceed 10% of total population at any point.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.Pandemic.{
    ActionSpace,
    DiseaseModel,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_max_rounds 12
  @default_player_count 6

  # Initial shared resource pool scaled to player count
  @vaccines_per_player 30_000
  @funding_per_player 5
  @teams_per_player 2

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    player_count = max(4, min(6, player_count))
    max_rounds = Keyword.get(opts, :max_rounds, @default_max_rounds)

    seed_region = Keyword.get(opts, :seed_region, "central_hub")
    seed_infected = Keyword.get(opts, :seed_infected, 5_000)

    spread_rate = Keyword.get(opts, :spread_rate, nil)
    mortality_rate = Keyword.get(opts, :mortality_rate, nil)

    disease_opts =
      []
      |> maybe_put(:spread_rate, spread_rate)
      |> maybe_put(:mortality_rate, mortality_rate)

    disease_params = DiseaseModel.initial_disease(disease_opts)
    regions = DiseaseModel.initial_regions(seed_region: seed_region, seed_infected: seed_infected)
    travel_routes = DiseaseModel.travel_routes()
    public_stats = DiseaseModel.build_public_stats(regions)

    # Assign each governor to a region (up to player_count governors)
    region_order = ["northvale", "central_hub", "highland", "westport", "southshore", "eastlands"]
    governor_regions = Enum.take(region_order, player_count)
    governor_ids = Enum.map(1..player_count, &"governor_#{&1}")

    players =
      governor_ids
      |> Enum.zip(governor_regions)
      |> Enum.into(%{}, fn {gov_id, region_id} ->
        {gov_id,
         %{
           region: region_id,
           status: "active",
           resources: %{
             vaccines: 0,
             funding: 0,
             medical_teams: 0
           }
         }}
      end)

    resource_pool = %{
      vaccines: player_count * @vaccines_per_player,
      funding: player_count * @funding_per_player,
      medical_teams: player_count * @teams_per_player
    }

    %{
      # Domain detection key — must be present
      disease_params: disease_params,
      disease: disease_params,
      regions: regions,
      travel_routes: travel_routes,
      public_stats: public_stats,
      resource_pool: resource_pool,
      players: players,
      turn_order: governor_ids,
      phase: "intelligence",
      round: 1,
      max_rounds: max_rounds,
      active_actor_id: List.first(governor_ids),
      phase_done: MapSet.new(),
      allocations: %{},
      comm_inboxes: Enum.into(governor_ids, %{}, &{&1, []}),
      comm_history: [],
      comm_sent_this_round: %{},
      intelligence_checks: %{},
      local_actions_taken: %{},
      hoarding_log: [],
      journals: %{},
      status: "in_progress",
      winner: nil,
      outcome_reason: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "pandemic_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Cooperate with other governors to contain the pandemic. " <>
            "Keep the global death rate below 10% of total population for all rounds. " <>
            "Share intelligence, coordinate resources, and deploy containment measures. " <>
            "You are the active governor shown in the world state."
      },
      plan_history: []
    )
  end

  @spec modules() :: map()
  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      section_builders: %{
        world_state: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :world_state,
            title: "World State",
            format: :json,
            content: visible_world(frame.world, actor_id)
          }
        end,
        your_situation: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          player = Map.get(players, actor_id, %{})
          region_id = get(player, :region, actor_id)
          resources = get(player, :resources, %{})

          regions = get(frame.world, :regions, %{})
          region = Map.get(regions, region_id, %{})
          travel_routes = get(frame.world, :travel_routes, %{})
          neighbors = Map.get(travel_routes, region_id, [])

          neighbor_stats =
            Enum.map(neighbors, fn nid ->
              nr = Map.get(regions, nid, %{})
              public = get(frame.world, :public_stats, %{})
              pub_nr = Map.get(public, nid, %{})

              %{
                "region_id" => nid,
                "infected_approx" => get(pub_nr, :infected_approx, "unknown"),
                "quarantined" => get(nr, :quarantined, false)
              }
            end)

          pool = get(frame.world, :resource_pool, %{})

          %{
            id: :your_situation,
            title: "Your Situation (#{actor_id})",
            format: :json,
            content: %{
              "governor_id" => actor_id,
              "region" => region_id,
              "region_population" => get(region, :population, 0),
              "region_infected" => get(region, :infected, 0),
              "region_dead" => get(region, :dead, 0),
              "region_recovered" => get(region, :recovered, 0),
              "region_vaccinated" => get(region, :vaccinated, 0),
              "region_hospitals" => get(region, :hospitals, 0),
              "region_quarantined" => get(region, :quarantined, false),
              "resources" => %{
                "vaccines" => get(resources, :vaccines, 0),
                "funding" => get(resources, :funding, 0),
                "medical_teams" => get(resources, :medical_teams, 0)
              },
              "shared_pool" => %{
                "vaccines" => get(pool, :vaccines, 0),
                "funding" => get(pool, :funding, 0),
                "medical_teams" => get(pool, :medical_teams, 0)
              },
              "neighboring_regions" => neighbor_stats
            }
          }
        end,
        inbox: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          inboxes = get(frame.world, :comm_inboxes, %{})
          my_inbox = Map.get(inboxes, actor_id, [])

          %{
            id: :inbox,
            title: "Your Communications Inbox",
            format: :json,
            content: my_inbox
          }
        end,
        disease_intel: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          checks = get(frame.world, :intelligence_checks, %{})
          checked_regions = Map.get(checks, actor_id, [])
          regions = get(frame.world, :regions, %{})

          checked_data =
            Enum.into(checked_regions, %{}, fn region_id ->
              region = Map.get(regions, region_id, %{})

              {region_id,
               %{
                 "population" => get(region, :population, 0),
                 "infected" => get(region, :infected, 0),
                 "dead" => get(region, :dead, 0),
                 "recovered" => get(region, :recovered, 0),
                 "vaccinated" => get(region, :vaccinated, 0),
                 "hospitals" => get(region, :hospitals, 0),
                 "quarantined" => get(region, :quarantined, false)
               }}
            end)

          %{
            id: :disease_intel,
            title: "Intelligence Reports (regions you checked this round)",
            format: :json,
            content: %{
              "checked_regions" => checked_regions,
              "data" => checked_data
            }
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: Enum.take(frame.recent_events, -15)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        PANDEMIC RESPONSE RULES:

        PHASES (in order each round):
        1. INTELLIGENCE: Use check_region to gather real-time infection data for your region
           and neighbors. Then call end_intelligence to proceed.
        2. COMMUNICATION: Share data or request help from other governors (max 3 messages per round).
           You may share accurate or misleading information. Call end_communication when done.
        3. RESOURCE ALLOCATION: Request resources from the shared pool (once per round).
           You may also donate your resources to other governors or back to the pool.
           Call end_resource_allocation when done.
        4. LOCAL ACTION: Deploy containment measures:
           - vaccinate: Deploy vaccines in your region (reduces susceptible population)
           - quarantine_zone: Impose quarantine (costs 1 medical team, drastically reduces spread)
           - build_hospital: Build hospital in your region (costs 3 funding, reduces deaths)
           - fund_research: Invest funding to permanently reduce global spread rate
           - hoard_supplies: Take from shared pool (WARNING: logged and visible to all)
           Call end_local_action when done. This triggers disease spread.

        STRATEGY:
        - The disease spreads to neighboring regions each round. Quarantine slows this.
        - Deaths over 10% of total population = game over (loss).
        - Research reduces the GLOBAL spread rate permanently — highly valuable.
        - Hoarding hurts the team. Coordinate resource sharing.
        - You MUST call the end_* action for your phase to advance. Do not stall.
        - The team wins by surviving all #{@default_max_rounds} rounds below the death threshold.

        COOPERATION:
        - Share real intelligence with allies so they can prioritize high-risk regions.
        - Request resources when your region is at crisis level.
        - Respond to help requests from struggling governors.
        - Coordinate quarantine to block travel routes between high-infection regions.
        """
      },
      section_order: [
        :world_state,
        :your_situation,
        :inbox,
        :disease_intel,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    config = Modular.load(project_dir: File.cwd!())
    model = Keyword.get_lazy(overrides, :model, fn -> resolve_configured_model!(config) end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: resolve_provider_api_key!(model.provider, config)}
      end)

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      persist?: true,
      terminal?: &terminal?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)

    player_count = length(get(state.world, :turn_order, []))
    IO.puts("Starting Pandemic Response with #{player_count} governors")
    IO.puts("Regions: #{map_size(get(state.world, :regions, %{}))}")
    IO.puts("Max rounds: #{get(state.world, :max_rounds, @default_max_rounds)}")

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nGame Over!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Game failed:")
        IO.inspect(reason)
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Visibility
  # ---------------------------------------------------------------------------

  defp visible_world(world, actor_id) do
    players = get(world, :players, %{})
    regions = get(world, :regions, %{})
    public_stats = get(world, :public_stats, %{})
    disease = get(world, :disease, %{})
    travel_routes = get(world, :travel_routes, %{})

    # Governors only see public (approximate) regional stats, not exact numbers
    region_view =
      Enum.into(regions, %{}, fn {region_id, region} ->
        pub = Map.get(public_stats, region_id, %{})

        {region_id,
         %{
           "infected_approx" => get(pub, :infected_approx, 0),
           "dead_approx" => get(pub, :dead_approx, 0),
           "recovered_approx" => get(pub, :recovered_approx, 0),
           "hospitals" => get(region, :hospitals, 0),
           "quarantined" => get(region, :quarantined, false),
           "population" => get(region, :population, 0),
           "neighbors" => Map.get(travel_routes, region_id, [])
         }}
      end)

    player_view =
      Enum.into(players, %{}, fn {pid, info} ->
        resources = get(info, :resources, %{})

        is_me = pid == actor_id

        base = %{
          "region" => get(info, :region, pid),
          "status" => get(info, :status, "active")
        }

        # Governors can only see their own resource details
        if is_me do
          Map.put(base, "resources", %{
            "vaccines" => get(resources, :vaccines, 0),
            "funding" => get(resources, :funding, 0),
            "medical_teams" => get(resources, :medical_teams, 0)
          })
        else
          base
        end
        |> then(&{pid, &1})
      end)

    pool = get(world, :resource_pool, %{})

    %{
      "phase" => get(world, :phase, "intelligence"),
      "round" => get(world, :round, 1),
      "max_rounds" => get(world, :max_rounds, @default_max_rounds),
      "active_governor" => MapHelpers.get_key(world, :active_actor_id),
      "status" => get(world, :status, "in_progress"),
      "regions" => region_view,
      "governors" => player_view,
      "shared_pool" => %{
        "vaccines" => get(pool, :vaccines, 0),
        "funding" => get(pool, :funding, 0),
        "medical_teams" => get(pool, :medical_teams, 0)
      },
      "disease" => %{
        "spread_rate" => Float.round(get(disease, :spread_rate, 0.18), 4),
        "research_progress" => get(disease, :research_progress, 0)
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status in ["won", "lost"]
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    phase = get(state.world, :phase, "?")
    round = get(state.world, :round, 1)

    IO.puts("Step #{turn} | round=#{round} phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_disease_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_disease_summary(state) do
    regions = get(state.world, :regions, %{})
    disease = get(state.world, :disease, %{})

    total_pop = DiseaseModel.total_population(regions)
    total_dead = DiseaseModel.total_deaths(regions)
    total_infected = Enum.sum(Enum.map(regions, fn {_, r} -> Map.get(r, :infected, 0) end))
    death_pct = if total_pop > 0, do: Float.round(total_dead / total_pop * 100, 2), else: 0.0
    threshold = trunc(total_pop * 0.10)

    IO.puts(
      "  infected=#{format_stat(total_infected)} dead=#{format_stat(total_dead)}/#{format_stat(threshold)} (#{death_pct}%) spread_rate=#{Float.round(get(disease, :spread_rate, 0.18), 4)}"
    )
  end

  defp print_final_state(state) do
    print_disease_summary(state)

    status = get(state.world, :status, "?")
    round = get(state.world, :round, 1)
    reason = get(state.world, :outcome_reason, nil)
    performance = Performance.summarize(state.world)

    IO.puts("\nOutcome: #{status} after round #{round}")

    if reason do
      IO.puts("Reason: #{reason}")
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_gov, metrics} -> get(metrics, :regional_death_rate, 0.0) end)
    |> Enum.each(fn {gov_id, metrics} ->
      IO.puts(
        "  #{gov_id} [#{get(metrics, :region, "?")}]: " <>
          "death_rate=#{get(metrics, :regional_death_rate, 0)}% " <>
          "vaccinated=#{format_stat(get(metrics, :vaccinated, 0))} " <>
          "hospitals=+#{get(metrics, :hospitals_built, 0)} " <>
          "hoarding=#{get(metrics, :hoarding_incidents, 0)} " <>
          "messages=#{get(metrics, :messages_sent, 0)}"
      )
    end)
  end

  # ---------------------------------------------------------------------------
  # Config resolution (mirrors Diplomacy pattern)
  # ---------------------------------------------------------------------------

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Pandemic example requires a valid default model.
        Configure [defaults].provider + [defaults].model (or [agent].default_*) in Lemon config,
        or pass an explicit model via the mix task.
        """
    end
  end

  defp resolve_model_spec(provider, model_spec) when is_binary(model_spec) do
    trimmed = String.trim(model_spec)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, ":") ->
        case String.split(trimmed, ":", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> nil
        end

      String.contains?(trimmed, "/") ->
        case String.split(trimmed, "/", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> lookup_model(provider, trimmed)
        end

      true ->
        lookup_model(provider, trimmed)
    end
  end

  defp resolve_model_spec(_provider, _model_spec), do: nil

  defp lookup_model(nil, model_id), do: Ai.Models.find_by_id(model_id)
  defp lookup_model("", model_id), do: Ai.Models.find_by_id(model_id)

  defp lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    normalized = normalize_provider(provider)

    Ai.Models.get_model(normalized, model_id) ||
      Ai.Models.get_model(String.to_atom(String.trim(provider)), model_id)
  end

  defp apply_provider_base_url(%Ai.Types.Model{} = model, config) do
    provider_name = provider_name(model.provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)
    base_url = provider_cfg[:base_url]

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  defp resolve_provider_api_key!(provider, config) do
    provider_name = provider_name(provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)

    cond do
      provider_name == "openai-codex" ->
        case Ai.Auth.OpenAICodexOAuth.resolve_access_token() do
          token when is_binary(token) and token != "" ->
            token

          _ ->
            raise "pandemic sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "pandemic sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "pandemic sim requires configured credentials for #{provider_name}"
    end
  end

  @provider_aliases %{
    "gemini" => "google_gemini_cli",
    "gemini_cli" => "google_gemini_cli",
    "gemini-cli" => "google_gemini_cli",
    "openai_codex" => "openai-codex"
  }

  defp provider_name(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> canonical_provider_name()

  defp provider_name(provider) when is_binary(provider), do: canonical_provider_name(provider)

  defp normalize_provider(provider_name) do
    provider_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> canonical_provider_name()
    |> String.to_atom()
  end

  defp canonical_provider_name(provider_name) do
    normalized =
      provider_name
      |> String.trim()
      |> String.downcase()

    Map.get(@provider_aliases, normalized, normalized)
  end

  defp resolve_secret_api_key(secret_name, secret_value)
       when is_binary(secret_name) and is_binary(secret_value) do
    case Ai.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, secret_value) do
      {:ok, resolved_api_key} when is_binary(resolved_api_key) and resolved_api_key != "" ->
        resolved_api_key

      :ignore ->
        secret_value

      {:error, _reason} ->
        secret_value
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_stat(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_stat(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_stat(n) when is_number(n), do: to_string(trunc(n))
  defp format_stat(nil), do: "0"
  defp format_stat(other), do: to_string(other)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
