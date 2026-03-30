defmodule LemonAiRuntime.Credentials do
  @moduledoc """
  Lemon-owned provider credential resolution.

  This module owns resolved provider API-key lookup for Lemon callers. It
  centralizes provider alias handling, secret resolution, OAuth payload decoding,
  and provider availability checks before `Ai` receives runtime options.
  """

  require Logger

  alias LemonAiRuntime.Auth.OAuthSecretResolver
  alias LemonAiRuntime.ProviderNames
  alias LemonCore.ProviderConfigResolver
  alias LemonCore.Secrets

  @raw_anthropic_secret "llm_anthropic_api_key_raw"

  @spec build_get_api_key(map() | nil) :: (atom() | String.t() -> String.t() | nil)
  def build_get_api_key(providers_map) do
    fn provider -> resolve_provider_api_key(provider, providers_map) end
  end

  @spec resolve_provider_api_key(atom() | String.t(), map() | nil, keyword()) :: String.t() | nil
  def resolve_provider_api_key(provider, providers_or_cfg, opts \\ []) do
    provider_cfg = provider_config(providers_or_cfg, provider, opts)

    case ProviderNames.canonical_name(provider) do
      "openai_codex" -> resolve_openai_codex_api_key(provider_cfg)
      "anthropic" -> resolve_anthropic_api_key(provider_cfg)
      canonical when is_binary(canonical) -> resolve_generic_api_key(canonical, provider_cfg)
      _ -> nil
    end
  end

  @spec resolve_secret_api_key(String.t(), keyword()) :: String.t() | nil
  def resolve_secret_api_key(secret_name, opts \\ [])

  def resolve_secret_api_key(secret_name, opts) when is_binary(secret_name) do
    env_fallback = Keyword.get(opts, :env_fallback, true)

    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: env_fallback) do
      {:ok, value, _source} ->
        case OAuthSecretResolver.resolve_api_key_from_secret(secret_name, value) do
          {:ok, resolved_api_key} ->
            resolved_api_key

          :ignore ->
            non_empty_binary(value)

          {:error, reason} ->
            Logger.debug("Failed to resolve OAuth secret #{secret_name}: #{inspect(reason)}")
            non_empty_binary(value)
        end

      _ ->
        nil
    end
  end

  def resolve_secret_api_key(_, _), do: nil

  @spec provider_has_credentials?(atom() | String.t(), map() | nil, keyword()) :: boolean()
  def provider_has_credentials?(provider, providers_map_or_cfg, opts \\ []) do
    provider_cfg = provider_config(providers_map_or_cfg, provider, opts)

    case ProviderNames.canonical_name(provider) do
      "openai_codex" ->
        present_value?(resolve_provider_api_key(provider, provider_cfg, provider_cfg: true)) or
          openai_codex_ambient_oauth_available?()

      "google_vertex" ->
        vertex_credentials_available?(provider_cfg, opts)

      "amazon_bedrock" ->
        bedrock_credentials_available?(provider_cfg, opts)

      "bedrock_converse_stream" ->
        bedrock_credentials_available?(provider_cfg, opts)

      _ ->
        present_value?(resolve_provider_api_key(provider, provider_cfg, provider_cfg: true))
    end
  end

  defp resolve_generic_api_key(provider, provider_cfg) do
    env_key =
      provider
      |> ProviderNames.env_vars()
      |> env_first()

    cond do
      present_value?(env_key) ->
        env_key

      present_value?(plain_api_key = provider_config_value(provider_cfg, :api_key)) ->
        plain_api_key

      present_value?(api_key_secret = provider_config_value(provider_cfg, :api_key_secret)) ->
        resolve_secret_api_key(api_key_secret)

      present_value?(default_secret = ProviderNames.default_secret_name(provider)) ->
        resolve_secret_api_key(default_secret)

      true ->
        nil
    end
  end

  defp resolve_openai_codex_api_key(provider_cfg) do
    resolved =
      case normalize_auth_source(provider_cfg) do
        :oauth ->
          resolve_openai_codex_oauth_key(provider_cfg)

        :api_key ->
          resolve_openai_codex_raw_api_key(provider_cfg)

        :missing ->
          Logger.warning(
            "providers.openai-codex.auth_source is required and must be one of: oauth, api_key"
          )

          nil

        {:invalid, value} ->
          Logger.warning(
            "providers.openai-codex.auth_source=#{inspect(value)} is invalid; expected oauth or api_key"
          )

          nil
      end

    resolved || ""
  end

  defp resolve_openai_codex_oauth_key(provider_cfg) do
    secret_name =
      first_non_empty_binary([
        provider_config_value(provider_cfg, :oauth_secret),
        provider_config_value(provider_cfg, :api_key_secret),
        ProviderNames.default_secret_name("openai_codex")
      ])

    if present_value?(secret_name) do
      resolve_openai_codex_oauth_secret(secret_name)
    end
  end

  defp resolve_openai_codex_oauth_secret(secret_name) do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} ->
        case LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_api_key_from_secret(secret_name, value) do
          {:ok, resolved_api_key} ->
            resolved_api_key

          :ignore ->
            resolve_openai_codex_onboarding_access_token(secret_name, value)

          {:error, reason} ->
            Logger.warning(
              "Failed to resolve OpenAI Codex OAuth secret #{secret_name}: #{inspect(reason)}"
            )

            nil
        end

      _ ->
        nil
    end
  end

  defp resolve_openai_codex_raw_api_key(provider_cfg) do
    env_key =
      "openai_codex"
      |> ProviderNames.env_vars()
      |> env_first()

    cond do
      present_value?(env_key) ->
        env_key

      present_value?(plain_api_key = provider_config_value(provider_cfg, :api_key)) ->
        plain_api_key

      present_value?(api_key_secret = provider_config_value(provider_cfg, :api_key_secret)) ->
        resolve_raw_secret_api_key(api_key_secret)

      true ->
        nil
    end
  end

  defp resolve_anthropic_api_key(provider_cfg) do
    case normalize_auth_source(provider_cfg) do
      :oauth ->
        resolve_anthropic_oauth_key(provider_cfg) || ""

      :api_key ->
        resolve_anthropic_raw_api_key(provider_cfg) ||
          resolve_raw_secret_api_key(@raw_anthropic_secret) ||
          ""

      :missing ->
        resolve_anthropic_raw_api_key(provider_cfg) ||
          resolve_raw_secret_api_key(@raw_anthropic_secret) ||
          ""

      {:invalid, value} ->
        Logger.warning(
          "providers.anthropic.auth_source=#{inspect(value)} is invalid; expected oauth or api_key when set"
        )

        ""
    end
  end

  defp resolve_anthropic_oauth_key(provider_cfg) do
    secret_name =
      first_non_empty_binary([
        provider_config_value(provider_cfg, :oauth_secret),
        provider_config_value(provider_cfg, :api_key_secret),
        ProviderNames.oauth_default_secret_name("anthropic"),
        ProviderNames.default_secret_name("anthropic")
      ])

    if(present_value?(secret_name), do: resolve_anthropic_oauth_secret(secret_name)) ||
      LemonAiRuntime.Auth.AnthropicOAuth.resolve_access_token()
  end

  defp resolve_anthropic_oauth_secret(secret_name) do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} ->
        case LemonAiRuntime.Auth.AnthropicOAuth.resolve_api_key_from_secret(secret_name, value) do
          {:ok, resolved_api_key} ->
            resolved_api_key

          :ignore ->
            Logger.warning(
              "Anthropic OAuth secret #{secret_name} is not a recognized Anthropic OAuth payload"
            )

            nil

          {:error, reason} ->
            Logger.warning(
              "Failed to resolve Anthropic OAuth secret #{secret_name}: #{inspect(reason)}"
            )

            nil
        end

      _ ->
        nil
    end
  end

  defp resolve_anthropic_raw_api_key(provider_cfg) do
    env_key =
      "anthropic"
      |> ProviderNames.env_vars()
      |> env_first()

    cond do
      present_value?(env_key) ->
        env_key

      present_value?(plain_api_key = provider_config_value(provider_cfg, :api_key)) ->
        plain_api_key

      present_value?(api_key_secret = provider_config_value(provider_cfg, :api_key_secret)) ->
        resolve_anthropic_raw_secret_api_key(api_key_secret)

      true ->
        nil
    end
  end

  defp resolve_raw_secret_api_key(secret_name) when is_binary(secret_name) do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp resolve_raw_secret_api_key(_), do: nil

  defp resolve_anthropic_raw_secret_api_key(secret_name) when is_binary(secret_name) do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} when is_binary(value) and value != "" ->
        case Jason.decode(value) do
          {:ok, %{} = decoded} ->
            if decoded["type"] in ["anthropic_oauth", "onboarding_anthropic_oauth"] and
                 present_value?(decoded["access_token"]) do
              Logger.warning(
                "Anthropic OAuth payload secret #{secret_name} cannot be used as a raw API key; configure an Anthropic API key instead"
              )

              nil
            else
              value
            end

          _ ->
            value
        end

      _ ->
        nil
    end
  end

  defp resolve_anthropic_raw_secret_api_key(_), do: nil

  defp resolve_openai_codex_onboarding_access_token(secret_name, secret_value)
       when is_binary(secret_name) and is_binary(secret_value) do
    case Jason.decode(secret_value) do
      {:ok, %{"type" => "onboarding_openai_codex_oauth", "access_token" => access_token}}
      when is_binary(access_token) and access_token != "" ->
        access_token

      _ ->
        Logger.warning(
          "OpenAI Codex OAuth secret #{secret_name} is not a recognized Codex OAuth payload"
        )

        nil
    end
  end

  defp openai_codex_ambient_oauth_available? do
    case LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token() do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  defp vertex_credentials_available?(provider_cfg, opts) do
    resolved =
      :google_vertex
      |> ProviderConfigResolver.resolve_for_provider(
        stream_provider_input(provider_cfg, %{}, opts, :google_vertex)
      )

    present_value?(resolved[:api_key]) or
      present_value?(resolved[:service_account_json]) or
      present_value?(System.get_env("GOOGLE_APPLICATION_CREDENTIALS"))
  end

  defp bedrock_credentials_available?(provider_cfg, opts) do
    resolved =
      :bedrock_converse_stream
      |> ProviderConfigResolver.resolve_for_provider(
        stream_provider_input(provider_cfg, %{}, opts, :bedrock_converse_stream)
      )

    headers = Map.get(resolved, :headers, %{})

    (present_value?(headers["aws_access_key_id"]) and
       present_value?(headers["aws_secret_access_key"])) or
      present_value?(resolve_secret_env("AWS_PROFILE"))
  end

  defp stream_provider_input(provider_cfg, base_opts, opts, provider_id) do
    cwd = Keyword.get(opts, :cwd)

    case provider_id do
      :google_vertex ->
        base_opts
        |> Map.put(:cwd, cwd)
        |> maybe_put(
          :project,
          first_non_empty_binary([
            Map.get(base_opts, :project),
            provider_config_value(provider_cfg, :project),
            provider_config_value(provider_cfg, :project_id),
            resolve_secret_api_key(provider_config_value(provider_cfg, :project_secret),
              env_fallback: true
            )
          ])
        )
        |> maybe_put(
          :location,
          first_non_empty_binary([
            Map.get(base_opts, :location),
            provider_config_value(provider_cfg, :location),
            resolve_secret_api_key(provider_config_value(provider_cfg, :location_secret),
              env_fallback: true
            )
          ])
        )
        |> maybe_put(
          :service_account_json,
          first_non_empty_binary([
            Map.get(base_opts, :service_account_json),
            provider_config_value(provider_cfg, :service_account_json),
            resolve_secret_api_key(
              provider_config_value(provider_cfg, :service_account_json_secret),
              env_fallback: true
            )
          ])
        )
        |> maybe_put(:api_key, provider_config_value(provider_cfg, :api_key))

      :bedrock_converse_stream ->
        headers =
          base_opts
          |> Map.get(:headers, %{})
          |> maybe_put("aws_region", provider_config_value(provider_cfg, :region))
          |> maybe_put(
            "aws_access_key_id",
            resolve_secret_api_key(provider_config_value(provider_cfg, :access_key_id_secret),
              env_fallback: true
            )
          )
          |> maybe_put(
            "aws_secret_access_key",
            resolve_secret_api_key(
              provider_config_value(provider_cfg, :secret_access_key_secret),
              env_fallback: true
            )
          )
          |> maybe_put(
            "aws_session_token",
            resolve_secret_api_key(provider_config_value(provider_cfg, :session_token_secret),
              env_fallback: true
            )
          )

        base_opts
        |> Map.put(:cwd, cwd)
        |> Map.put(:headers, headers)

      _ ->
        base_opts
    end
  end

  defp resolve_secret_value(secret_name, opts) when is_binary(secret_name) do
    Secrets.resolve(secret_name, opts)
  rescue
    _ ->
      fallback_secret_value(secret_name, opts)
  catch
    :exit, _ ->
      fallback_secret_value(secret_name, opts)
  end

  defp resolve_secret_value(_, _), do: {:error, :invalid_secret_name}

  defp fallback_secret_value(secret_name, opts) do
    cond do
      Keyword.get(opts, :prefer_env, false) and present_value?(System.get_env(secret_name)) ->
        {:ok, System.get_env(secret_name), :env}

      Keyword.get(opts, :env_fallback, false) and present_value?(System.get_env(secret_name)) ->
        {:ok, System.get_env(secret_name), :env}

      true ->
        {:error, :not_found}
    end
  end

  defp resolve_secret_env(name) do
    case resolve_secret_value(name, prefer_env: true, env_fallback: true) do
      {:ok, value, _source} -> value
      _ -> nil
    end
  end

  defp provider_config(providers_or_cfg, provider, opts) do
    if Keyword.get(opts, :provider_cfg, false) do
      normalize_provider_cfg(providers_or_cfg)
    else
      providers_or_cfg
      |> ProviderNames.provider_config(provider)
      |> normalize_provider_cfg()
    end
  end

  defp normalize_provider_cfg(nil), do: %{}
  defp normalize_provider_cfg(cfg) when is_map(cfg), do: cfg
  defp normalize_provider_cfg(_), do: %{}

  defp provider_config_value(nil, _key), do: nil

  defp provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  defp normalize_auth_source(provider_cfg) do
    source =
      provider_cfg
      |> provider_config_value(:auth_source)
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> nil
      end

    cond do
      source in [nil, ""] -> :missing
      String.downcase(source) == "oauth" -> :oauth
      String.downcase(source) == "api_key" -> :api_key
      true -> {:invalid, source}
    end
  end

  defp env_first(names) when is_list(names) do
    Enum.find_value(names, fn name ->
      value = resolve_secret_env(name)
      if present_value?(value), do: value, else: nil
    end)
  end

  defp env_first(_), do: nil

  defp first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, &present_value?/1)
  end

  defp first_non_empty_binary(_), do: nil

  defp non_empty_binary(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_empty_binary(_), do: nil

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
