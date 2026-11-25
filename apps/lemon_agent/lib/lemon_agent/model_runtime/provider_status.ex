defmodule LemonAgent.ModelRuntime.ProviderStatus do
  @moduledoc """
  Redacted provider credential readiness diagnostics.

  Credential readiness is `Credentials.credential_readiness/3` in presence
  mode, the predicate doctor, setup readiness and the CLI share: building a
  snapshot never decrypts a value, refreshes a login, runs an external secret
  source or omp, or discovers remote models.
  """

  alias LemonAgent.ModelRuntime.Credentials
  alias LemonAgent.ModelRuntime.CustomProviders
  alias LemonAgent.ModelRuntime.ProviderConfiguration
  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ModelRuntime.ProviderRouting
  alias LemonCore.Config

  @spec snapshot(map() | nil) :: map()
  def snapshot(params \\ %{}) do
    params = params || %{}
    cwd = project_dir(params)
    config = Config.load(cwd, cache: false)
    providers = provider_ids(params, config)

    statuses =
      providers
      |> Enum.map(&provider_status(&1, config, cwd))
      |> Enum.sort_by(&{&1["known"] != true, &1["provider"]})

    %{
      "providers" => statuses,
      "count" => length(statuses),
      "readyCount" => Enum.count(statuses, & &1["credentialReady"]),
      "defaultProvider" => default_agent_value(config, :default_provider),
      "defaultModel" => default_agent_value(config, :default_model),
      "routingConfig" => ProviderConfiguration.snapshot(config),
      "routing" => ProviderRouting.preview(params, config, statuses),
      "cleanup" => %{
        "includesRawApiKeys" => false,
        "includesSecretNames" => false,
        "includesRawBaseUrls" => false,
        "includesEnvVarNames" => false
      }
    }
  end

  @doc """
  Compact per-provider credential summary for the control-plane status RPC.

  Lists configured providers, the catalog providers with a credential and the
  default provider. `"credential"` is `"present"`, `"missing"`, `"unusable"`
  (configured but fails closed, for example an undecryptable secret) or
  `"not_required"` (keyless).
  """
  @spec summary(Config.t() | map()) :: [map()]
  def summary(config \\ Config.load()) do
    providers = config.providers || %{}
    routing = provider_routing(config)

    default =
      summary_id(config.agent.default_provider || model_prefix(config.agent.default_model))

    ids =
      (Map.keys(providers) ++ LemonAi.Models.get_providers() ++ [default])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&summary_id/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(ids, fn id ->
      cfg = ProviderNames.provider_config(providers, id) || Map.get(providers, id, %{})

      credential =
        case Credentials.credential_readiness(id, providers, provider_routing: routing) do
          :ready -> "present"
          :not_required -> "not_required"
          :missing -> "missing"
          :unusable -> "unusable"
        end

      configured =
        id == default or credential in ["present", "unusable"] or
          Enum.any?(cfg, fn {_key, value} -> value not in [nil, "", false, [], %{}] end)

      if configured do
        [
          %{
            "id" => id,
            "configured" => true,
            "credential" => credential,
            "default" => id == default,
            "circuit" => circuit(id),
            "lastError" =>
              LemonAi.CallDispatcher.last_error(ProviderNames.canonical_name(id) || id)
          }
        ]
      else
        []
      end
    end)
  end

  defp summary_id(id), do: ProviderNames.config_name(id) || to_string(id)

  defp model_prefix(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, _model] -> provider
      _ -> nil
    end
  end

  defp model_prefix(_), do: nil

  @doc "Read-only circuit diagnostics shared by provider status projections."
  def circuit(provider) do
    case LemonAi.CircuitBreaker.peek(ProviderNames.canonical_name(provider) || provider) do
      {:ok, info} ->
        %{
          "state" => to_string(info.state),
          "failureCount" => info.failure_count,
          "timeUntilRecoveryMs" => info.time_until_recovery_ms
        }

      state when state in [:not_started, :unknown] ->
        %{"state" => to_string(state), "failureCount" => nil, "timeUntilRecoveryMs" => nil}
    end
  end

  defp project_dir(params) do
    value = get_param(params, "projectDir") || get_param(params, "cwd")
    if present?(value), do: value, else: File.cwd!()
  end

  defp provider_ids(params, config) do
    requested =
      [
        get_param(params, "provider")
        | get_param(params, "providers") |> List.wrap()
      ]
      |> Enum.filter(&present?/1)
      |> Enum.map(&to_string/1)

    cond do
      requested != [] ->
        (requested ++
           ProviderRouting.candidate_provider_ids(params, config))
        |> Enum.uniq_by(&normalize_provider/1)

      include_catalog?(params) ->
        (config_provider_ids(config) ++
           catalog_provider_ids() ++ ProviderNames.all_canonical_names())
        |> Enum.uniq_by(&normalize_provider/1)

      true ->
        (config_provider_ids(config) ++
           default_provider_ids(config) ++
           ProviderRouting.candidate_provider_ids(params, config))
        |> Enum.uniq_by(&normalize_provider/1)
    end
  end

  defp include_catalog?(params) do
    get_param(params, "includeCatalog") == true or get_param(params, "include_catalog") == true
  end

  defp config_provider_ids(%Config{providers: providers}) when is_map(providers),
    do: Map.keys(providers)

  defp config_provider_ids(_), do: []

  defp catalog_provider_ids do
    if Code.ensure_loaded?(LemonAi.Models) do
      LemonAi.Models.list_models(discover_openai: false)
      |> Enum.map(&model_provider/1)
      |> Enum.filter(&present?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp default_provider_ids(config) do
    [
      default_agent_value(config, :default_provider),
      "anthropic",
      "openai",
      "openai-codex",
      "google",
      "zai",
      "kimi",
      "minimax",
      "openrouter"
    ]
    |> Enum.filter(&present?/1)
  end

  defp provider_status(provider, %Config{} = config, cwd) do
    canonical = ProviderNames.canonical_name(provider)
    custom = CustomProviders.custom_provider(config.providers, provider)

    config_name =
      ProviderNames.config_name(provider) || custom_id(custom) || normalize_provider(provider)

    provider_cfg =
      ProviderNames.provider_config(config.providers, provider) ||
        CustomProviders.config_for(config.providers, provider) || %{}

    env_configured? = env_configured?(provider)
    routing = provider_routing(config)

    %{
      "provider" => canonical || custom_id(custom) || normalize_provider(provider),
      "configName" => config_name,
      "known" => is_binary(canonical),
      "custom" => not is_nil(custom),
      "configured" => map_size(provider_cfg) > 0,
      "circuit" => circuit(canonical || custom_id(custom) || normalize_provider(provider)),
      "credentialReady" =>
        (is_binary(canonical) or not is_nil(custom)) and
          Credentials.provider_has_credentials?(
            canonical || custom_id(custom),
            config.providers,
            cwd: cwd,
            provider_routing: routing
          ),
      "config" => %{
        "apiKeyConfigured" => present?(provider_config_value(provider_cfg, :api_key)),
        "apiKeySecretConfigured" =>
          present?(provider_config_value(provider_cfg, :api_key_secret)),
        "oauthSecretConfigured" => present?(provider_config_value(provider_cfg, :oauth_secret)),
        "baseUrlConfigured" => present?(provider_config_value(provider_cfg, :base_url)),
        "authSource" => safe_auth_source(provider_cfg)
      },
      "ambient" => %{
        "envConfigured" => env_configured?
      }
    }
  end

  defp provider_status(provider, _config, _cwd) do
    %{
      "provider" => normalize_provider(provider),
      "configName" => normalize_provider(provider),
      "known" => false,
      "custom" => false,
      "configured" => false,
      "credentialReady" => false,
      "config" => %{
        "apiKeyConfigured" => false,
        "apiKeySecretConfigured" => false,
        "oauthSecretConfigured" => false,
        "baseUrlConfigured" => false,
        "authSource" => nil
      },
      "ambient" => %{"envConfigured" => false}
    }
  end

  defp custom_id({id, _cfg}), do: id
  defp custom_id(nil), do: nil

  defp provider_config_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  # Normalized routing config so pool-only credentials
  # (`provider_routing.credential_pools.<pool>.credentials`) count toward
  # `credentialReady` the same way ModelResolver's readiness gate counts them.
  defp provider_routing(%{agent: agent}) when is_map(agent) do
    Map.get(agent, :provider_routing) || Map.get(agent, "provider_routing") || %{}
  end

  defp provider_routing(_), do: %{}

  defp env_configured?(provider) do
    provider
    |> ProviderNames.env_vars()
    |> Enum.any?(&(System.get_env(&1) |> present?()))
  end

  defp safe_auth_source(provider_cfg) do
    case LemonCore.Config.Providers.normalize_auth_source(
           provider_config_value(provider_cfg, :auth_source)
         ) do
      value when value in ["api_key", "oauth", "omp", "omp_broker"] -> value
      _ -> nil
    end
  end

  defp default_agent_value(%Config{agent: agent}, key) when is_map(agent) do
    Map.get(agent, key) || Map.get(agent, to_string(key))
  end

  defp default_agent_value(_, _), do: nil

  defp model_provider(model) when is_struct(model), do: Map.get(model, :provider)
  defp model_provider(model) when is_map(model), do: model[:provider] || model["provider"]
  defp model_provider(_), do: nil

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp normalize_provider(value), do: ProviderNames.normalize(value) || "unknown"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
