defmodule LemonAgent.ProviderConfigResolver do
  @moduledoc """
  Resolves provider configuration from canonical config + env + secrets.

  This module centralizes provider settings resolution so that provider
  implementations don't need to read env vars or secrets directly.

  Each provider function returns a map of resolved settings that can be
  merged into StreamOptions or used directly by the provider.

  API-key secret fields use credential-aware OAuth resolution, never raw secret
  bytes. A caller-resolved selected login carries `api_key_authoritative: true`;
  this preserves its refusal without a second credential lookup or fallback.
  """

  alias LemonAgent.ModelRuntime.Credentials

  @doc """
  Resolve stream options for a given provider from canonical config.

  Returns a map of resolved settings. Keys with nil values are excluded.
  """
  @spec resolve_for_provider(atom(), map()) :: map()
  def resolve_for_provider(provider_id, opts \\ %{})

  def resolve_for_provider(:google_vertex, opts) do
    config = get_provider_config("google_vertex", opts)

    project =
      first_credential([
        {:value, Map.get(opts, :project)},
        {:secret, config[:project_secret]},
        {:value, config[:project]},
        {:value, config[:project_id]},
        {:env, "GOOGLE_CLOUD_PROJECT"},
        {:env, "GCLOUD_PROJECT"}
      ])

    location =
      first_credential([
        {:value, Map.get(opts, :location)},
        {:secret, config[:location_secret]},
        {:value, config[:location]},
        {:env, "GOOGLE_CLOUD_LOCATION"}
      ])

    service_account =
      walk_credentials([
        {:value, Map.get(opts, :service_account_json)},
        {:secret, config[:service_account_json_secret]},
        {:value, config[:service_account_json]},
        {:env, "GOOGLE_APPLICATION_CREDENTIALS_JSON"}
      ])

    # An unreadable configured service account is an authoritative refusal:
    # the provider must not continue to GOOGLE_APPLICATION_CREDENTIALS or gcloud.
    %{
      project: project,
      location: location,
      service_account_json: credential_value(service_account),
      credential_error: if(service_account == :error, do: :service_account_unavailable),
      api_key: config[:api_key]
    }
    |> reject_nil_values()
  end

  def resolve_for_provider(:google_gemini_cli, opts) do
    config = get_provider_config("google_gemini_cli", opts)

    project =
      first_credential([
        {:value, Map.get(opts, :project)},
        {:value, Map.get(opts, :project_id)},
        {:value, Map.get(opts, "project_id")},
        {:value, Map.get(opts, :projectId)},
        {:value, Map.get(opts, "projectId")},
        {:secret, Map.get(opts, :project_secret) || Map.get(opts, "project_secret")},
        {:value, config[:project]},
        {:value, config[:project_id]},
        {:secret, config[:project_secret]},
        {:env, "LEMON_GEMINI_PROJECT_ID"},
        {:env, "GOOGLE_CLOUD_PROJECT"},
        {:env, "GOOGLE_CLOUD_PROJECT_ID"},
        {:env, "GCLOUD_PROJECT"}
      ])

    %{project: project}
    |> reject_nil_values()
  end

  def resolve_for_provider(:google, opts) do
    config = get_provider_config("google", opts)

    %{
      api_key: resolve_api_key(:google, opts, config),
      api_key_authoritative: authority_option(opts, config),
      base_url:
        first_non_empty_binary([
          Map.get(opts, :base_url),
          config[:base_url]
        ])
    }
    |> reject_nil_values()
  end

  def resolve_for_provider(:azure_openai_responses, opts) do
    config = get_provider_config("azure_openai_responses", opts)
    azure_opts = Map.get(opts, :azure, %{})

    api_key = resolve_api_key(:azure_openai_responses, opts, config)

    base_url =
      first_non_empty_binary([
        Map.get(azure_opts, :base_url),
        config[:base_url],
        System.get_env("AZURE_OPENAI_BASE_URL")
      ])

    resource_name =
      first_non_empty_binary([
        Map.get(azure_opts, :resource_name),
        config[:resource_name],
        System.get_env("AZURE_OPENAI_RESOURCE_NAME")
      ])

    api_version =
      first_non_empty_binary([
        Map.get(azure_opts, :api_version),
        config[:api_version],
        System.get_env("AZURE_OPENAI_API_VERSION")
      ])

    deployment_name_map =
      Map.merge(
        parse_deployment_name_map(System.get_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")),
        Map.get(config, :deployment_name_map, %{})
      )
      |> Map.merge(Map.get(azure_opts, :deployment_name_map, %{}))

    %{
      api_key: api_key,
      api_key_authoritative: authority_option(opts, config),
      base_url: base_url,
      resource_name: resource_name,
      api_version: api_version,
      deployment_name_map: deployment_name_map
    }
    |> reject_nil_values()
  end

  def resolve_for_provider(:bedrock_converse_stream, opts) do
    config = get_provider_config("amazon_bedrock", opts)

    region =
      get_in_headers(opts, "aws_region") ||
        config[:region] ||
        System.get_env("AWS_REGION") ||
        System.get_env("AWS_DEFAULT_REGION") ||
        "us-east-1"

    access_key_id =
      first_credential([
        {:value, get_in_headers(opts, "aws_access_key_id")},
        {:secret, config[:access_key_id_secret]},
        {:secret, "AWS_ACCESS_KEY_ID"}
      ])

    secret_access_key =
      first_credential([
        {:value, get_in_headers(opts, "aws_secret_access_key")},
        {:secret, config[:secret_access_key_secret]},
        {:secret, "AWS_SECRET_ACCESS_KEY"}
      ])

    session_token =
      first_credential([
        {:value, get_in_headers(opts, "aws_session_token")},
        {:secret, config[:session_token_secret]},
        {:secret, "AWS_SESSION_TOKEN"}
      ])

    %{
      headers: %{
        "aws_region" => region,
        "aws_access_key_id" => access_key_id,
        "aws_secret_access_key" => secret_access_key,
        "aws_session_token" => session_token
      }
    }
    |> reject_nil_header_values()
  end

  def resolve_for_provider(provider_id, opts) do
    case openai_compatible_provider_name(provider_id) do
      nil ->
        %{}

      provider_name ->
        config = get_provider_config(provider_name, opts)

        %{
          api_key: resolve_api_key(provider_name, opts, config),
          api_key_authoritative: authority_option(opts, config),
          base_url:
            first_non_empty_binary([
              Map.get(opts, :base_url),
              config[:base_url]
            ])
        }
        |> reject_nil_values()
    end
  end

  defp resolve_api_key(provider, opts, config) do
    cond do
      Map.get(opts, :api_key_authoritative, false) ->
        Map.get(opts, :api_key)

      Credentials.oauth_selected?(config) ->
        Credentials.resolve_provider_api_key(provider, config, provider_cfg: true)

      provider == :azure_openai_responses ->
        first_credential([
          {:value, Map.get(opts, :api_key)},
          {:api_key_secret, config[:api_key_secret]},
          {:value, config[:api_key]},
          {:secret, "AZURE_OPENAI_API_KEY"}
        ])

      true ->
        first_credential([
          {:value, Map.get(opts, :api_key)},
          {:value, config[:api_key]},
          {:api_key_secret, config[:api_key_secret]}
        ])
    end
  end

  defp authority_option(opts, config) do
    if Map.get(opts, :api_key_authoritative, false) or Credentials.oauth_selected?(config),
      do: true
  end

  # ============================================================================
  # Internal helpers
  # ============================================================================

  @provider_config_key_aliases %{
    "access_key_id_secret" => :access_key_id_secret,
    "api_key" => :api_key,
    "auth_source" => :auth_source,
    "api_key_secret" => :api_key_secret,
    "api_version" => :api_version,
    "base_url" => :base_url,
    "deployment_name_map" => :deployment_name_map,
    "location" => :location,
    "location_secret" => :location_secret,
    "project" => :project,
    "oauth_secret" => :oauth_secret,
    "project_id" => :project_id,
    "projectId" => :projectId,
    "project_secret" => :project_secret,
    "region" => :region,
    "resource_name" => :resource_name,
    "secret_access_key_secret" => :secret_access_key_secret,
    "service_account_json" => :service_account_json,
    "service_account_json_secret" => :service_account_json_secret,
    "session_token_secret" => :session_token_secret
  }

  defp get_provider_config(name, opts) do
    cwd = if is_map(opts), do: Map.get(opts, :cwd), else: nil

    cached =
      try do
        LemonCore.Config.cached(cwd).providers
        |> Map.get(name, %{})
      rescue
        _ -> %{}
      end

    Map.merge(cached, explicit_provider_config(opts))
  end

  defp explicit_provider_config(opts) when is_map(opts) do
    opts
    |> Map.get(:provider_config, Map.get(opts, "provider_config", %{}))
    |> normalize_provider_config()
  end

  defp explicit_provider_config(_), do: %{}

  defp normalize_provider_config(config) when is_map(config) do
    Map.new(config, fn {key, value} ->
      {Map.get(@provider_config_key_aliases, key, key), value}
    end)
  end

  defp normalize_provider_config(_), do: %{}

  # Walks candidates in precedence order. A configured secret that cannot be
  # read (any error but a definite miss, or a crash) stops the walk with no
  # value, so a later inline, alias or environment credential never replaces
  # it. `Secrets.resolve/2` itself still falls back to the same-name
  # environment variable after a definite miss.
  defp first_credential(candidates), do: candidates |> walk_credentials() |> credential_value()

  defp walk_credentials(candidates) do
    Enum.reduce_while(candidates, :miss, fn candidate, :miss ->
      case credential(candidate) do
        {:ok, _value} = found -> {:halt, found}
        :miss -> {:cont, :miss}
        :error -> {:halt, :error}
      end
    end)
  end

  defp credential_value({:ok, value}), do: value
  defp credential_value(_miss_or_error), do: nil

  defp credential({:value, value}), do: present(value)
  defp credential({:env, name}), do: present(System.get_env(name))
  defp credential({:api_key_secret, name}), do: Credentials.fetch_secret_api_key(name)

  defp credential({:secret, name}) when is_binary(name) and name != "" do
    case LemonCore.Secrets.resolve(name, env_fallback: true) do
      {:ok, value, _source} -> present(value)
      {:error, :not_found} -> :miss
      {:error, _reason} -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp credential({:secret, _name}), do: :miss

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: :miss, else: {:ok, value}
  end

  defp present(nil), do: :miss
  defp present(value), do: {:ok, value}

  defp get_in_headers(%{headers: headers}, key) when is_map(headers) do
    Map.get(headers, key)
  end

  defp get_in_headers(_, _key), do: nil

  defp first_non_empty_binary(values) when is_list(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  defp openai_compatible_provider_name(provider_id) do
    normalized =
      case provider_id do
        value when is_atom(value) ->
          value
          |> Atom.to_string()
          |> String.downcase()
          |> String.replace("-", "_")

        value when is_binary(value) ->
          value
          |> String.downcase()
          |> String.replace("-", "_")

        _ ->
          nil
      end

    case normalized do
      name
      when name in [
             "openai",
             "opencode",
             "opencode_go",
             "xai",
             "mistral",
             "cerebras",
             "openrouter",
             "zai",
             "minimax",
             "minimax_cn",
             "fireworks",
             "github_copilot",
             "huggingface",
             "deepseek",
             "qwen",
             "vercel_ai_gateway",
             "kimi",
             "kimi_coding",
             "groq"
           ] ->
        name

      _ ->
        nil
    end
  end

  defp parse_deployment_name_map(nil), do: %{}

  defp parse_deployment_name_map(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.reduce(%{}, fn entry, acc ->
      entry = String.trim(entry)

      case String.split(entry, "=", parts: 2) do
        [model_id, deployment_name] ->
          Map.put(acc, String.trim(model_id), String.trim(deployment_name))

        _ ->
          acc
      end
    end)
  end

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp reject_nil_header_values(%{headers: headers} = map) do
    cleaned_headers = headers |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    %{map | headers: cleaned_headers}
  end
end
