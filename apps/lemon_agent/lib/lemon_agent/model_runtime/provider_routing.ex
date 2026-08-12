defmodule LemonAgent.ModelRuntime.ProviderRouting do
  @moduledoc """
  Provider route planning and redacted route-plan preview.

  `plan/3` builds the ordered candidate list runtime dispatch consumes: the
  requested primary provider first, then fallbacks by precedence (explicit
  params fallbacks, else profile fallback_providers -> profile distribution ->
  credential-pool providers -> global routing fallback_providers). Candidates
  whose LemonAi circuit breaker is open are demoted to the end of the plan —
  never dropped. `preview/3` renders the same plan as the stable string-keyed
  report used by provider diagnostics, without executing a model call.
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ModelRuntime.ProviderPoolRotator
  alias LemonCore.Config

  @type candidate :: %{
          provider: String.t(),
          role: :primary | :fallback,
          pool: String.t() | nil,
          strategy: String.t() | nil,
          known: boolean(),
          configured: boolean(),
          credential_ready: boolean(),
          selectable: boolean(),
          demotions: [atom()]
        }

  @doc """
  Build the ordered provider candidate plan.

  Options:

    * `:statuses` - provider status maps (as built by `ProviderStatus`) used
      to fill `known`/`configured`/`credential_ready`; defaults to `[]`.
    * `:check_breakers?` - demote candidates whose circuit breaker is open to
      the end of the plan, tagging them with `:circuit_open` (default `true`).
    * `:rotate?` - apply round-robin credential-pool rotation (default
      `false`; rotation advances shared state, so previews leave it off).
    * `:rotation_key` - stable session scope for pool rotation; a caller that
      passes the same value keeps the same rotation slot. Defaults to
      `:global`, which advances the rotation on every planned resolution.
  """
  @spec plan(map() | nil, Config.t(), keyword()) :: [candidate()]
  def plan(params, config, opts \\ [])

  def plan(params, %Config{} = config, opts) do
    build_plan(params, config, opts).candidates
  end

  def plan(params, _config, opts), do: plan(params, %Config{}, opts)

  @spec preview(map() | nil, Config.t(), [map()]) :: map()
  def preview(params, %Config{} = config, provider_statuses) do
    ctx = build_plan(params, config, statuses: provider_statuses)
    routing = ctx.routing

    selected =
      if routing.enabled do
        Enum.find(ctx.candidates, & &1.selectable)
      else
        nil
      end

    %{
      "enabled" => routing.enabled,
      "requestedProvider" => ctx.requested_provider,
      "requestedModel" => ctx.requested_model,
      "selectedProvider" => selected && selected.provider,
      "selectedModel" => if(selected, do: ctx.requested_model),
      "decision" => decision(selected, routing),
      "selectedProfile" => ctx.profile_name,
      "selectedCredentialPool" => ctx.pool_name,
      "fallbackProviders" => ctx.fallback_providers,
      "candidateProviders" => Enum.map(ctx.candidates, &render_candidate(&1, selected)),
      "profileDistribution" => profile_distribution(ctx.profile),
      "credentialPool" => credential_pool(provider_statuses, ctx.pool_name, ctx.pool),
      "cleanup" => %{
        "includesRawApiKeys" => false,
        "includesSecretNames" => false,
        "includesRawBaseUrls" => false,
        "includesEnvVarNames" => false
      }
    }
  end

  def preview(params, _config, provider_statuses) do
    preview(params, %Config{}, provider_statuses)
  end

  @spec candidate_provider_ids(map() | nil, Config.t()) :: [String.t()]
  def candidate_provider_ids(params, %Config{} = config) do
    params
    |> build_plan(config, check_breakers?: false)
    |> Map.fetch!(:candidates)
    |> Enum.map(& &1.provider)
  end

  defp build_plan(params, %Config{} = config, opts) do
    params = params || %{}
    statuses = Keyword.get(opts, :statuses, [])
    routing = routing_config(config)
    requested_provider = requested_provider(params, config)
    requested_model = requested_model(params, config)
    profile_name = requested_profile(params, routing)
    profile = profile_config(routing, profile_name)
    pool_name = requested_pool(params, routing, profile)
    pool = pool_config(routing, pool_name)
    pool_strategy = map_value(pool, :strategy) || "priority"

    {fallback_providers, pool_providers} =
      fallback_providers(params, routing, profile, pool, profile_name, pool_name,
        model_id: requested_model,
        rotate?: Keyword.get(opts, :rotate?, false),
        rotation_key: Keyword.get(opts, :rotation_key, :global)
      )

    candidates =
      [
        plan_candidate(
          requested_provider,
          :primary,
          statuses,
          routing,
          pool_name,
          pool_strategy,
          pool_providers
        )
        | Enum.map(
            fallback_providers,
            &plan_candidate(
              &1,
              :fallback,
              statuses,
              routing,
              pool_name,
              pool_strategy,
              pool_providers
            )
          )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.provider)
      |> apply_breaker_demotions(Keyword.get(opts, :check_breakers?, true))

    %{
      routing: routing,
      requested_provider: requested_provider,
      requested_model: requested_model,
      profile_name: profile_name,
      profile: profile,
      pool_name: pool_name,
      pool: pool,
      fallback_providers: fallback_providers,
      candidates: candidates
    }
  end

  defp routing_config(%Config{agent: agent}) when is_map(agent) do
    routing = Map.get(agent, :provider_routing) || Map.get(agent, "provider_routing") || %{}

    %{
      enabled: Map.get(routing, :enabled, Map.get(routing, "enabled", true)) != false,
      fallback_providers:
        Map.get(routing, :fallback_providers) || Map.get(routing, "fallback_providers") || [],
      default_pool: Map.get(routing, :default_pool) || Map.get(routing, "default_pool"),
      default_profile: Map.get(routing, :default_profile) || Map.get(routing, "default_profile"),
      credential_pools:
        Map.get(routing, :credential_pools) || Map.get(routing, "credential_pools") || %{},
      profiles: Map.get(routing, :profiles) || Map.get(routing, "profiles") || %{},
      require_credentials:
        Map.get(routing, :require_credentials, Map.get(routing, "require_credentials", true)) !=
          false
    }
  end

  defp routing_config(_) do
    %{
      enabled: true,
      fallback_providers: [],
      default_pool: nil,
      default_profile: nil,
      credential_pools: %{},
      profiles: %{},
      require_credentials: true
    }
  end

  defp requested_provider(params, config) do
    params
    |> get_param("requestedProvider")
    |> first_present(get_param(params, "provider"))
    |> first_present(default_provider(config))
    |> normalize_provider()
  end

  defp requested_model(params, config) do
    params
    |> get_param("requestedModel")
    |> first_present(get_param(params, "model"))
    |> first_present(default_model(config))
  end

  defp requested_profile(params, routing) do
    params
    |> get_param("routingProfile")
    |> first_present(get_param(params, "profile"))
    |> first_present(routing.default_profile)
    |> normalize_optional_name()
  end

  defp requested_pool(params, routing, profile) do
    params
    |> get_param("credentialPool")
    |> first_present(get_param(params, "pool"))
    |> first_present(map_value(profile, :credential_pool))
    |> first_present(routing.default_pool)
    |> normalize_optional_name()
  end

  # Returns {ordered fallback providers, ordered pool providers}. Pool
  # providers are only ordered (and pool rotation only advanced) when explicit
  # params fallbacks do not override the configured precedence.
  defp fallback_providers(params, routing, profile, pool, profile_name, pool_name, rotation) do
    params_fallbacks =
      get_param(params, "fallbackProviders") ||
        get_param(params, "fallback_providers")

    params_fallbacks
    |> List.wrap()
    |> normalize_list()
    |> case do
      [] ->
        pool_providers = ordered_pool_providers(pool, profile_name, pool_name, rotation)

        fallbacks =
          [
            profile |> map_value(:fallback_providers) |> normalize_list(),
            distribution_providers(profile),
            pool_providers,
            normalize_list(routing.fallback_providers)
          ]
          |> List.flatten()
          |> Enum.uniq()

        {fallbacks, pool_providers}

      providers ->
        {providers, []}
    end
  end

  defp ordered_pool_providers(pool, profile_name, pool_name, rotation) do
    providers = pool |> map_value(:providers) |> normalize_list()

    if Keyword.get(rotation, :rotate?, false) do
      ProviderPoolRotator.ordered_providers(
        {:provider_pool, profile_name, pool_name, Keyword.get(rotation, :model_id)},
        providers,
        map_value(pool, :strategy) || "priority",
        session_scope: Keyword.get(rotation, :rotation_key, :global)
      )
    else
      providers
    end
  end

  defp plan_candidate(nil, _role, _statuses, _routing, _pool_name, _strategy, _pool_providers),
    do: nil

  defp plan_candidate(provider, role, statuses, routing, pool_name, pool_strategy, pool_providers) do
    normalized = normalize_provider(provider)
    status = find_status(statuses, normalized)
    known = Map.get(status, "known", ProviderNames.canonical_name(normalized) != nil)
    credential_ready = Map.get(status, "credentialReady", false)
    in_pool? = normalized in pool_providers

    %{
      provider: normalized,
      role: role,
      pool: if(in_pool?, do: pool_name),
      strategy: if(in_pool?, do: pool_strategy),
      known: known,
      configured: Map.get(status, "configured", false),
      credential_ready: credential_ready,
      selectable: selectable?(known, credential_ready, routing),
      demotions: []
    }
  end

  defp selectable?(known, _credential_ready, %{require_credentials: false}), do: known == true

  defp selectable?(known, credential_ready, _routing),
    do: known == true and credential_ready == true

  defp apply_breaker_demotions(candidates, false), do: candidates

  defp apply_breaker_demotions(candidates, _check) do
    {open, closed} = Enum.split_with(candidates, &circuit_open?(&1.provider))
    closed ++ Enum.map(open, &%{&1 | demotions: &1.demotions ++ [:circuit_open]})
  end

  defp circuit_open?(provider) do
    case ProviderNames.provider_atom(provider) do
      nil -> false
      provider_atom -> breaker_open?(provider_atom)
    end
  end

  # A missing or crashed breaker process must never break planning.
  defp breaker_open?(provider_atom) do
    LemonAi.CircuitBreaker.open?(provider_atom) == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp find_status(provider_statuses, provider) do
    Enum.find(provider_statuses, %{}, fn status ->
      normalize_provider(Map.get(status, "provider")) == provider or
        normalize_provider(Map.get(status, "configName")) == provider
    end)
  end

  defp decision(_selected, %{enabled: false}), do: "routing_disabled"
  defp decision(%{role: :primary}, _routing), do: "selected_primary"
  defp decision(%{role: :fallback}, _routing), do: "selected_fallback"
  defp decision(_selected, _routing), do: "no_ready_provider"

  defp render_candidate(candidate, selected) do
    %{
      "provider" => candidate.provider,
      "role" => Atom.to_string(candidate.role),
      "known" => candidate.known,
      "configured" => candidate.configured,
      "credentialReady" => candidate.credential_ready,
      "selected" => selected != nil and candidate.provider == selected.provider,
      "demotions" => Enum.map(candidate.demotions, &Atom.to_string/1)
    }
  end

  defp credential_pool(provider_statuses, selected_pool_name, selected_pool) do
    %{
      "selectedPool" => selected_pool_name,
      "strategy" => map_value(selected_pool, :strategy) || "priority",
      "configuredProviders" => normalize_list(map_value(selected_pool, :providers)),
      # Counts only - credential ref names/values never enter the preview.
      "credentialCounts" => pool_credential_counts(selected_pool),
      "providers" =>
        Enum.map(provider_statuses, fn status ->
          config = Map.get(status, "config", %{})
          ambient = Map.get(status, "ambient", %{})

          %{
            "provider" => Map.get(status, "provider"),
            "known" => Map.get(status, "known") == true,
            "credentialReady" => Map.get(status, "credentialReady") == true,
            "referenceCount" =>
              [
                Map.get(config, "apiKeyConfigured"),
                Map.get(config, "apiKeySecretConfigured"),
                Map.get(config, "oauthSecretConfigured"),
                Map.get(ambient, "envConfigured")
              ]
              |> Enum.count(&(&1 == true))
          }
        end)
    }
  end

  defp pool_credential_counts(pool) do
    pool
    |> map_value(:credentials)
    |> case do
      credentials when is_map(credentials) ->
        Map.new(credentials, fn {provider, refs} ->
          {normalize_provider(provider), refs |> List.wrap() |> length()}
        end)

      _ ->
        %{}
    end
  end

  defp profile_distribution(profile) do
    profile
    |> map_value(:distribution)
    |> case do
      distribution when is_map(distribution) ->
        distribution
        |> Enum.map(fn {provider, weight} ->
          %{"provider" => normalize_provider(provider), "weight" => weight}
        end)
        |> Enum.sort_by(&{-1 * numeric_weight(&1["weight"]), &1["provider"]})

      _ ->
        []
    end
  end

  defp distribution_providers(profile) do
    profile_distribution(profile)
    |> Enum.map(& &1["provider"])
  end

  defp pool_config(%{credential_pools: pools}, name), do: named_config(pools, name)
  defp profile_config(%{profiles: profiles}, name), do: named_config(profiles, name)

  defp named_config(configs, name) when is_map(configs) and is_binary(name) do
    Map.get(configs, name) || existing_atom_config(configs, name)
  end

  defp named_config(_, _), do: nil

  defp existing_atom_config(configs, name) do
    Map.get(configs, String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_, _), do: nil

  defp normalize_optional_name(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_name(_), do: nil

  defp numeric_weight(weight) when is_integer(weight), do: weight
  defp numeric_weight(weight) when is_float(weight), do: weight
  defp numeric_weight(_), do: 0

  defp default_provider(%Config{agent: agent}) when is_map(agent) do
    Map.get(agent, :default_provider) || Map.get(agent, "default_provider")
  end

  defp default_provider(_), do: nil

  defp default_model(%Config{agent: agent}) when is_map(agent) do
    Map.get(agent, :default_model) || Map.get(agent, "default_model")
  end

  defp default_model(_), do: nil

  defp get_param(params, key) when is_map(params) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_, _), do: nil

  defp first_present(value, fallback), do: if(present?(value), do: value, else: fallback)

  defp normalize_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_provider/1)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp normalize_list(value) when is_binary(value), do: normalize_list(String.split(value, ","))
  defp normalize_list(_), do: []

  defp normalize_provider(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(value) when is_binary(value) do
    case ProviderNames.canonical_name(value) do
      nil ->
        value
        |> String.trim()
        |> String.downcase()
        |> String.replace("-", "_")

      canonical ->
        canonical
    end
  end

  defp normalize_provider(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
