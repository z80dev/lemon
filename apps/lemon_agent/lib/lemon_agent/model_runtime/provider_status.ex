defmodule LemonAgent.ModelRuntime.ProviderStatus do
  @moduledoc """
  Redacted provider credential readiness diagnostics.
  """

  alias LemonAgent.ModelRuntime.CustomProviders
  alias LemonAgent.ModelRuntime.ProviderNames
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
      "routingConfig" => LemonAgent.ModelRuntime.ProviderConfiguration.snapshot(config),
      "routing" => LemonAgent.ModelRuntime.ProviderRouting.preview(params, config, statuses),
      "cleanup" => %{
        "includesRawApiKeys" => false,
        "includesSecretNames" => false,
        "includesRawBaseUrls" => false,
        "includesEnvVarNames" => false
      }
    }
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
           LemonAgent.ModelRuntime.ProviderRouting.candidate_provider_ids(params, config))
        |> Enum.uniq_by(&normalize_provider/1)

      include_catalog?(params) ->
        (config_provider_ids(config) ++
           catalog_provider_ids() ++ ProviderNames.all_canonical_names())
        |> Enum.uniq_by(&normalize_provider/1)

      true ->
        (config_provider_ids(config) ++
           default_provider_ids(config) ++
           LemonAgent.ModelRuntime.ProviderRouting.candidate_provider_ids(params, config))
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
      "credentialReady" =>
        cond do
          canonical ->
            credential_ready?(
              canonical,
              config.providers,
              provider_cfg,
              env_configured?,
              cwd,
              routing
            )

          custom ->
            LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(
              custom_id(custom),
              config.providers,
              cwd: cwd,
              provider_routing: routing
            )

          true ->
            false
        end,
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

  defp credential_ready?("openai_codex", providers, provider_cfg, env_configured?, cwd, routing) do
    LemonAgent.ModelRuntime.Credentials.provider_has_credentials?("openai_codex", providers,
      cwd: cwd,
      provider_routing: routing
    ) or
      (not present?(provider_config_value(provider_cfg, :auth_source)) && not env_configured? &&
         LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(
           "openai_codex",
           %{"openai-codex" => %{"auth_source" => "oauth"}},
           cwd: cwd
         ))
  end

  defp credential_ready?("anthropic", providers, _provider_cfg, _env_configured?, cwd, routing) do
    LemonAgent.ModelRuntime.Credentials.provider_has_credentials?("anthropic", providers,
      cwd: cwd,
      provider_routing: routing
    )
  end

  defp credential_ready?(canonical, providers, _provider_cfg, _env_configured?, cwd, routing) do
    LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(canonical, providers,
      cwd: cwd,
      provider_routing: routing
    )
  end

  # Normalized routing config so pool-only credentials
  # (`provider_routing.credential_pools.<pool>.credentials`) count toward
  # `credentialReady` the same way ModelResolver's readiness gate counts them.
  defp provider_routing(%Config{agent: agent}) when is_map(agent) do
    Map.get(agent, :provider_routing) || Map.get(agent, "provider_routing") || %{}
  end

  defp provider_routing(_), do: %{}

  defp env_configured?(provider) do
    provider
    |> ProviderNames.env_vars()
    |> Enum.any?(&(System.get_env(&1) |> present?()))
  end

  defp safe_auth_source(provider_cfg) do
    case provider_config_value(provider_cfg, :auth_source) do
      value when value in ["api_key", "oauth"] -> value
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

  defp normalize_provider(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider(_), do: "unknown"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
