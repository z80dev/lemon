defmodule LemonAiRuntime.ProviderRouting do
  @moduledoc """
  Redacted provider route-plan preview.

  This module defines Lemon's stable provider routing shape without executing a
  model call. Runtime dispatch can consume the same candidate ordering once the
  fallback execution path is wired.
  """

  alias LemonAiRuntime.ProviderNames
  alias LemonCore.Config

  @spec preview(map() | nil, Config.t(), [map()]) :: map()
  def preview(params, %Config{} = config, provider_statuses) do
    params = params || %{}
    routing = routing_config(config)
    requested_provider = requested_provider(params, config)
    requested_model = requested_model(params, config)
    requested_profile = requested_profile(params, routing)
    selected_profile = profile_config(routing, requested_profile)
    requested_pool = requested_pool(params, routing, selected_profile)
    selected_pool = pool_config(routing, requested_pool)
    fallback_providers = fallback_providers(params, routing, selected_profile, selected_pool)

    candidates =
      [
        candidate(requested_provider, "primary", provider_statuses)
        | fallback_candidates(fallback_providers, provider_statuses)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["provider"])

    selected =
      if routing.enabled do
        Enum.find(candidates, &candidate_selectable?(&1, routing))
      else
        nil
      end

    %{
      "enabled" => routing.enabled,
      "requestedProvider" => requested_provider,
      "requestedModel" => requested_model,
      "selectedProvider" => selected && selected["provider"],
      "selectedModel" => if(selected, do: requested_model),
      "decision" => decision(selected, routing),
      "selectedProfile" => requested_profile,
      "selectedCredentialPool" => requested_pool,
      "fallbackProviders" =>
        Enum.map(fallback_candidates(fallback_providers, provider_statuses), & &1["provider"]),
      "candidateProviders" => Enum.map(candidates, &mark_selected(&1, selected)),
      "profileDistribution" => profile_distribution(selected_profile),
      "credentialPool" => credential_pool(provider_statuses, requested_pool, selected_pool),
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
    params = params || %{}
    routing = routing_config(config)
    selected_profile = profile_config(routing, requested_profile(params, routing))
    selected_pool = pool_config(routing, requested_pool(params, routing, selected_profile))

    [
      requested_provider(params, config)
      | fallback_providers(params, routing, selected_profile, selected_pool)
    ]
    |> Enum.filter(&present?/1)
    |> Enum.map(&normalize_provider/1)
    |> Enum.uniq()
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

  defp fallback_providers(params, routing, profile, pool) do
    params_fallbacks =
      get_param(params, "fallbackProviders") ||
        get_param(params, "fallback_providers")

    params_fallbacks
    |> List.wrap()
    |> normalize_list()
    |> case do
      [] ->
        [
          profile |> map_value(:fallback_providers) |> normalize_list(),
          distribution_providers(profile),
          pool |> map_value(:providers) |> normalize_list(),
          normalize_list(routing.fallback_providers)
        ]
        |> List.flatten()
        |> Enum.uniq()

      providers ->
        providers
    end
  end

  defp fallback_candidates(fallback_providers, provider_statuses) do
    fallback_providers
    |> Enum.map(&candidate(&1, "fallback", provider_statuses))
    |> Enum.reject(&is_nil/1)
  end

  defp candidate(nil, _role, _provider_statuses), do: nil

  defp candidate(provider, role, provider_statuses) do
    normalized = normalize_provider(provider)
    status = find_status(provider_statuses, normalized)

    %{
      "provider" => normalized,
      "role" => role,
      "known" => Map.get(status, "known", ProviderNames.canonical_name(normalized) != nil),
      "configured" => Map.get(status, "configured", false),
      "credentialReady" => Map.get(status, "credentialReady", false),
      "selected" => false
    }
  end

  defp find_status(provider_statuses, provider) do
    Enum.find(provider_statuses, %{}, fn status ->
      normalize_provider(Map.get(status, "provider")) == provider or
        normalize_provider(Map.get(status, "configName")) == provider
    end)
  end

  defp candidate_selectable?(candidate, %{require_credentials: false}),
    do: candidate["known"] == true

  defp candidate_selectable?(candidate, _routing),
    do: candidate["known"] == true and candidate["credentialReady"] == true

  defp decision(_selected, %{enabled: false}), do: "routing_disabled"
  defp decision(%{"role" => "primary"}, _routing), do: "selected_primary"
  defp decision(%{"role" => "fallback"}, _routing), do: "selected_fallback"
  defp decision(_selected, _routing), do: "no_ready_provider"

  defp mark_selected(candidate, nil), do: candidate

  defp mark_selected(candidate, selected) do
    Map.put(candidate, "selected", candidate["provider"] == selected["provider"])
  end

  defp credential_pool(provider_statuses, selected_pool_name, selected_pool) do
    %{
      "selectedPool" => selected_pool_name,
      "strategy" => map_value(selected_pool, :strategy) || "priority",
      "configuredProviders" => normalize_list(map_value(selected_pool, :providers)),
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

  defp normalize_provider(value) when is_atom(value),
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
