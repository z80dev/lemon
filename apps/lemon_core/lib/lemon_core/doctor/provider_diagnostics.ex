defmodule LemonCore.Doctor.ProviderDiagnostics do
  @moduledoc """
  Redacted provider setup diagnostics for support bundles.
  """

  alias LemonCore.Config
  alias LemonCore.Secrets

  @known_providers ~w(
    anthropic
    azure_openai
    bedrock
    google
    google_gemini_cli
    google_vertex
    kimi
    minimax
    openai
    openai-codex
    openrouter
    opencode
    vertex
    zai
  )

  @ambient_provider_env %{
    "anthropic" => ["ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"],
    "openai" => ["OPENAI_API_KEY"],
    "openai-codex" => ["OPENAI_CODEX_API_KEY"],
    "google" => ["GOOGLE_GENERATIVE_AI_API_KEY"],
    "google_gemini_cli" => ["GOOGLE_GEMINI_CLI_API_KEY"],
    "opencode" => ["OPENCODE_API_KEY"],
    "zai" => ["ZAI_API_KEY"],
    "minimax" => ["MINIMAX_API_KEY"],
    "openrouter" => ["OPENROUTER_API_KEY"]
  }

  @secret_fields ~w(
    access_key_id_secret
    api_key_secret
    location_secret
    oauth_secret
    project_secret
    secret_access_key_secret
    service_account_json_secret
    session_token_secret
  )a

  @inline_secret_fields ~w(
    api_key
    service_account_json
  )a

  @endpoint_fields ~w(
    api_version
    base_url
    deployment_name_map
    location
    project
    project_id
    region
    resource_name
  )a

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    config = Config.load(project_dir, cache: false)
    providers = provider_ids(config)
    provider_statuses = Enum.map(providers, &provider_status(&1, config))
    routing = routing_status(config, provider_statuses)

    %{
      default_provider: agent_value(config, :default_provider),
      default_model_configured: present?(agent_value(config, :default_model)),
      providers: provider_statuses,
      count: length(provider_statuses),
      configured_count: Enum.count(provider_statuses, & &1.configured),
      credential_reference_count:
        provider_statuses
        |> Enum.flat_map(& &1.secret_references)
        |> length(),
      credential_reference_present_count:
        provider_statuses
        |> Enum.flat_map(& &1.secret_references)
        |> Enum.count(& &1.present),
      ambient_provider_count:
        Enum.count(provider_statuses, &get_in(&1, [:ambient, :provider_env_configured])),
      routing: routing,
      cleanup: %{
        includes_raw_api_keys: false,
        includes_secret_names: false,
        includes_raw_base_urls: false,
        includes_env_var_names: false,
        includes_provider_responses: false,
        includes_model_prompts: false
      }
    }
  end

  defp provider_ids(%Config{providers: providers} = config) when is_map(providers) do
    (Map.keys(providers) ++ @known_providers ++ [agent_value(config, :default_provider)])
    |> Enum.filter(&present?/1)
    |> Enum.map(&normalize_provider/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp provider_status(provider, %Config{providers: providers}) do
    config_name = config_name(provider, providers)
    provider_config = Map.get(providers, config_name, %{})
    secret_references = secret_references(provider_config)
    inline_credentials = inline_credentials(provider_config)
    endpoint_shape = endpoint_shape(provider_config)
    ambient_configured = ambient_configured?(provider)

    %{
      provider: normalize_provider(provider),
      config_name: config_name,
      known: provider in @known_providers or config_name in @known_providers,
      configured: map_size(provider_config) > 0,
      credential_ready:
        ambient_configured or
          Enum.any?(secret_references, & &1.present) or
          Enum.any?(inline_credentials, & &1.configured),
      auth_source: safe_auth_source(provider_config),
      inline_credentials: inline_credentials,
      endpoint_shape: endpoint_shape,
      secret_references: secret_references,
      ambient: %{provider_env_configured: ambient_configured}
    }
  end

  defp routing_status(%Config{} = config, provider_statuses) do
    routing = agent_value(config, :provider_routing) || %{}
    fallback_providers = routing |> map_value(:fallback_providers) |> normalize_list()
    credential_pools = routing |> map_value(:credential_pools) |> normalize_named_configs()
    profiles = routing |> map_value(:profiles) |> normalize_named_configs()

    %{
      enabled: map_value(routing, :enabled) != false,
      require_credentials: map_value(routing, :require_credentials) != false,
      fallback_providers: fallback_providers,
      default_pool_configured: present?(map_value(routing, :default_pool)),
      default_profile_configured: present?(map_value(routing, :default_profile)),
      credential_pool_count: map_size(credential_pools),
      profile_count: map_size(profiles),
      credential_pools:
        credential_pools
        |> Enum.map(fn {name, pool} ->
          providers = pool |> map_value(:providers) |> normalize_list()

          %{
            name_hash: hash_name(name),
            provider_count: length(providers),
            providers: Enum.map(providers, &normalize_provider/1),
            strategy: map_value(pool, :strategy) || "priority",
            credential_reference_count:
              Enum.reduce(providers, 0, fn provider, count ->
                count + provider_reference_count(provider, provider_statuses)
              end)
          }
        end)
        |> Enum.sort_by(& &1.name_hash),
      profiles:
        profiles
        |> Enum.map(fn {name, profile} ->
          distribution = profile |> map_value(:distribution) |> normalize_distribution()

          %{
            name_hash: hash_name(name),
            fallback_providers:
              profile
              |> map_value(:fallback_providers)
              |> normalize_list()
              |> Enum.map(&normalize_provider/1),
            credential_pool_configured: present?(map_value(profile, :credential_pool)),
            distribution: distribution,
            distribution_count: length(distribution)
          }
        end)
        |> Enum.sort_by(& &1.name_hash)
    }
  end

  defp provider_reference_count(provider, statuses) do
    normalized = normalize_provider(provider)

    statuses
    |> Enum.find(%{secret_references: []}, fn status -> status.provider == normalized end)
    |> Map.get(:secret_references, [])
    |> length()
  end

  defp secret_references(provider_config) do
    @secret_fields
    |> Enum.map(fn field ->
      value = map_value(provider_config, field)

      %{
        field: Atom.to_string(field),
        configured: present?(value),
        present: secret_present?(value)
      }
    end)
    |> Enum.filter(&(&1.configured or &1.present))
  end

  defp inline_credentials(provider_config) do
    @inline_secret_fields
    |> Enum.map(fn field ->
      %{field: Atom.to_string(field), configured: present?(map_value(provider_config, field))}
    end)
    |> Enum.filter(& &1.configured)
  end

  defp endpoint_shape(provider_config) do
    @endpoint_fields
    |> Enum.map(fn field ->
      %{field: Atom.to_string(field), configured: present?(map_value(provider_config, field))}
    end)
    |> Enum.filter(& &1.configured)
  end

  defp secret_present?(name) when is_binary(name) do
    Secrets.exists?(name, prefer_env: false, env_fallback: false)
  rescue
    _ -> false
  end

  defp secret_present?(_), do: false

  defp ambient_configured?(provider) do
    provider
    |> normalize_provider()
    |> then(&Map.get(@ambient_provider_env, &1, []))
    |> Enum.any?(&(System.get_env(&1) |> present?()))
  end

  defp config_name(provider, providers) do
    normalized = normalize_provider(provider)

    cond do
      Map.has_key?(providers, normalized) -> normalized
      normalized == "openai_codex" and Map.has_key?(providers, "openai-codex") -> "openai-codex"
      normalized == "openai-codex" and Map.has_key?(providers, "openai_codex") -> "openai_codex"
      true -> normalized
    end
  end

  defp safe_auth_source(provider_config) do
    case map_value(provider_config, :auth_source) do
      value when value in ["api_key", "oauth"] -> value
      _ -> nil
    end
  end

  defp normalize_named_configs(configs) when is_map(configs), do: configs
  defp normalize_named_configs(_), do: %{}

  defp normalize_distribution(distribution) when is_map(distribution) do
    distribution
    |> Enum.map(fn {provider, weight} ->
      %{provider: normalize_provider(provider), weight: weight}
    end)
    |> Enum.sort_by(& &1.provider)
  end

  defp normalize_distribution(_), do: []

  defp normalize_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(_), do: []

  defp agent_value(%Config{agent: agent}, key) when is_map(agent) do
    Map.get(agent, key) || Map.get(agent, to_string(key))
  end

  defp agent_value(_, _), do: nil

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_, _), do: nil

  defp hash_name(name) when is_binary(name) do
    :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp hash_name(name), do: hash_name(to_string(name))

  defp normalize_provider(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp normalize_provider(_), do: "unknown"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
