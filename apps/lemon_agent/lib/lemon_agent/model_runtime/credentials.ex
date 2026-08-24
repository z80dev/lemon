defmodule LemonAgent.ModelRuntime.Credentials do
  @moduledoc """
  Lemon-owned provider credential resolution.

  This module owns resolved provider API-key lookup for Lemon callers. It
  centralizes provider alias handling, secret resolution, OAuth payload decoding,
  and provider availability checks before `LemonAi` receives runtime options.

  ## Credential pools

  On top of the single-credential resolution, providers may carry extra
  credentials through `provider_routing.credential_pools.<pool>.credentials`
  (see `LemonCore.Config.Agent`). `list_provider_api_keys/3` returns the
  ordered pool credentials for a provider followed by the single-credential
  resolution as a final `"default"` entry, and `build_get_api_key/1` picks the
  first credential not in cooldown (`CredentialHealth`). With no pools
  configured, behavior is identical to plain single-credential resolution.
  """

  require Logger

  alias LemonAi.Auth.OAuthSecretResolver
  alias LemonAgent.ModelRuntime.CredentialHealth
  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ProviderConfigResolver
  alias LemonCore.Secrets

  @raw_anthropic_secret "llm_anthropic_api_key_raw"

  @type credential_entry :: %{ref: String.t(), api_key: String.t()}

  @spec build_get_api_key(map() | nil) :: (atom() | String.t() -> String.t() | nil)
  def build_get_api_key(providers_map) do
    fn provider -> resolve_pooled_api_key(provider, providers_map) end
  end

  @doc """
  Ordered API-key candidates for a provider.

  Pool credentials come first (pool selection follows the same
  default_pool/profile precedence as the routing plan: `opts[:pool]` >
  profile `credential_pool` > routing `default_pool`), then the existing
  single-credential resolution as a final `%{ref: "default"}` entry. Entries
  whose secret/env fails to resolve are skipped. `config` may be a bare
  providers map or any map carrying `:providers` and `:provider_routing`
  (e.g. a settings struct or `LemonCore.Config`).
  """
  @spec list_provider_api_keys(map() | nil, atom() | String.t(), keyword()) :: [
          credential_entry()
        ]
  def list_provider_api_keys(config, provider, opts \\ []) do
    default_entry =
      case resolve_provider_api_key(provider, config, opts) do
        api_key when is_binary(api_key) ->
          if present_value?(api_key), do: [%{ref: "default", api_key: api_key}], else: []

        _ ->
          []
      end

    pool_credential_entries(config, provider, opts) ++ default_entry
  end

  # `build_get_api_key/1` contract: first non-cooldown credential's key; when
  # every credential is cooling down, fall back to the first one rather than
  # returning nil - a cooled key beats no key. With no pool credentials the
  # list is just the default resolution, so this is byte-identical to plain
  # `resolve_provider_api_key/2` (including the openai_codex "" sentinel).
  defp resolve_pooled_api_key(provider, config) do
    case list_provider_api_keys(config, provider) do
      [] ->
        resolve_provider_api_key(provider, config)

      entries ->
        entry =
          Enum.find(entries, fn entry ->
            not CredentialHealth.in_cooldown?(provider, entry.ref)
          end) ||
            hd(entries)

        entry.api_key
    end
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
        case OAuthSecretResolver.resolve_api_key_from_secret(secret_name, value,
               persist_secret: &persist_oauth_secret/2
             ) do
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

  @doc """
  Whether a provider has any usable credential.

  Pool credentials count: pass the normalized routing config as
  `opts[:provider_routing]` and any resolvable pool credential for the
  provider makes it ready, before the per-provider special paths run.
  """
  @spec provider_has_credentials?(atom() | String.t(), map() | nil, keyword()) :: boolean()
  def provider_has_credentials?(provider, providers_map_or_cfg, opts \\ []) do
    pool_credentials_available?(provider, opts) or
      single_provider_has_credentials?(provider, providers_map_or_cfg, opts)
  end

  defp pool_credentials_available?(provider, opts) do
    case Keyword.get(opts, :provider_routing) do
      routing when is_map(routing) ->
        pool_credential_entries(%{provider_routing: routing}, provider, opts) != []

      _ ->
        false
    end
  end

  defp single_provider_has_credentials?(provider, providers_map_or_cfg, opts) do
    provider_cfg = provider_config(providers_map_or_cfg, provider, opts)

    case ProviderNames.canonical_name(provider) do
      "openai_codex" ->
        ready? =
          present_value?(resolve_provider_api_key(provider, provider_cfg, provider_cfg: true))

        ready? or
          (normalize_auth_source(provider_cfg) == :missing and
             openai_codex_ambient_oauth_available?())

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

  # ---- Credential pools ----

  # Resolved pool credential entries for a provider, in configured order.
  # Entries that fail to resolve (missing secret/env) are skipped.
  defp pool_credential_entries(config, provider, opts) do
    config
    |> routing_config_map()
    |> selected_pool(opts)
    |> pool_refs_for_provider(provider)
    |> Enum.flat_map(fn ref ->
      case resolve_credential_ref(ref) do
        api_key when is_binary(api_key) ->
          if present_value?(api_key) do
            [%{ref: credential_ref_string(ref), api_key: api_key}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp routing_config_map(%{provider_routing: routing}) when is_map(routing), do: routing

  defp routing_config_map(%{"provider_routing" => routing}) when is_map(routing), do: routing

  defp routing_config_map(%{agent: agent}) when is_map(agent),
    do: map_value(agent, :provider_routing) || %{}

  defp routing_config_map(_), do: %{}

  # Mirrors the routing plan's pool precedence: explicit opt > profile
  # credential_pool > routing default_pool.
  defp selected_pool(routing, opts) when is_map(routing) do
    profile =
      routing
      |> map_value(:profiles)
      |> named_config(Keyword.get(opts, :profile) || map_value(routing, :default_profile))

    pool_name =
      first_non_empty_binary([
        Keyword.get(opts, :pool),
        map_value(profile, :credential_pool),
        map_value(routing, :default_pool)
      ])

    routing
    |> map_value(:credential_pools)
    |> named_config(pool_name)
  end

  defp selected_pool(_, _), do: nil

  defp named_config(configs, name) when is_map(configs) and is_binary(name) do
    map_value(configs, name)
  end

  defp named_config(_, _), do: nil

  defp pool_refs_for_provider(pool, provider) when is_map(pool) do
    credentials = map_value(pool, :credentials)

    if is_map(credentials) do
      provider_keys = provider_match_keys(provider)

      Enum.find_value(credentials, [], fn {key, refs} ->
        if normalize_provider_key(key) in provider_keys, do: List.wrap(refs), else: nil
      end)
    else
      []
    end
  end

  defp pool_refs_for_provider(_, _), do: []

  defp provider_match_keys(provider) do
    case ProviderNames.all_names(provider) do
      [] -> [normalize_provider_key(provider)] |> Enum.reject(&is_nil/1)
      names -> names
    end
  end

  defp normalize_provider_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_provider_key()

  defp normalize_provider_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_provider_key(_), do: nil

  # Refs arrive normalized (`%{source: :secret | :env, name: name}`) from
  # `LemonCore.Config.Agent`, but hand-built settings may still carry the raw
  # string forms ("secret:NAME", "env:VAR", bare secret name).
  defp resolve_credential_ref(%{source: :env, name: name}) when is_binary(name),
    do: System.get_env(name)

  defp resolve_credential_ref(%{source: :secret, name: name}) when is_binary(name),
    do: resolve_secret_api_key(name, env_fallback: false)

  defp resolve_credential_ref(%{"source" => source, "name" => name}) when is_binary(name),
    do: resolve_credential_ref(%{source: ref_source(source), name: name})

  defp resolve_credential_ref(ref) when is_binary(ref) do
    case parse_credential_ref(ref) do
      nil -> nil
      parsed -> resolve_credential_ref(parsed)
    end
  end

  defp resolve_credential_ref(_), do: nil

  defp ref_source(:env), do: :env
  defp ref_source("env"), do: :env
  defp ref_source(_), do: :secret

  defp parse_credential_ref(ref) when is_binary(ref) do
    case String.trim(ref) do
      "" -> nil
      "secret:" <> name -> parsed_credential_ref(:secret, name)
      "env:" <> name -> parsed_credential_ref(:env, name)
      name -> %{source: :secret, name: name}
    end
  end

  defp parsed_credential_ref(source, name) do
    case String.trim(name) do
      "" -> nil
      name -> %{source: source, name: name}
    end
  end

  defp credential_ref_string(%{source: source, name: name}), do: "#{source}:#{name}"

  defp credential_ref_string(%{"source" => source, "name" => name}),
    do: credential_ref_string(%{source: ref_source(source), name: name})

  defp credential_ref_string(ref) when is_binary(ref) do
    case parse_credential_ref(ref) do
      nil -> ref
      parsed -> credential_ref_string(parsed)
    end
  end

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp map_value(_, _), do: nil

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
        case LemonAi.Auth.OpenAICodexOAuth.resolve_api_key_from_secret(secret_name, value,
               persist_secret: &persist_openai_codex_secret/2
             ) do
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
        provider_config_value(provider_cfg, :api_key_secret)
      ])

    default_secret_name =
      first_non_empty_binary([
        ProviderNames.oauth_default_secret_name("anthropic"),
        ProviderNames.default_secret_name("anthropic")
      ])

    cond do
      present_value?(secret_name) ->
        resolve_anthropic_oauth_secret(secret_name)

      present_value?(default_secret_name) ->
        case resolve_anthropic_oauth_secret(default_secret_name) do
          value when is_binary(value) and value != "" ->
            value

          _ ->
            resolve_anthropic_access_token()
        end

      true ->
        resolve_anthropic_access_token()
    end
  end

  defp resolve_anthropic_oauth_secret(secret_name) do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} ->
        case LemonAi.Auth.AnthropicOAuth.resolve_api_key_from_secret(secret_name, value,
               persist_secret: &persist_anthropic_secret/2
             ) do
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
    case resolve_openai_codex_access_token() do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  defp vertex_credentials_available?(provider_cfg, opts) do
    resolved =
      ProviderConfigResolver.resolve_for_provider(:google_vertex, %{
        cwd: Keyword.get(opts, :cwd),
        provider_config: provider_cfg
      })

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

  defp resolve_openai_codex_access_token do
    resolve_secret_api_key("OPENAI_CODEX_API_KEY", env_fallback: true) ||
      resolve_secret_api_key("CHATGPT_TOKEN", env_fallback: true) ||
      resolve_secret_api_key(ProviderNames.default_secret_name("openai_codex"),
        env_fallback: false
      ) ||
      LemonAi.Auth.OpenAICodexOAuth.resolve_access_token()
  end

  defp resolve_anthropic_access_token do
    LemonAi.Auth.AnthropicOAuth.resolve_access_token() ||
      resolve_secret_api_key(ProviderNames.oauth_default_secret_name("anthropic"),
        env_fallback: false
      )
  end

  defp persist_oauth_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: "ai_oauth")
    :ok
  end

  defp persist_openai_codex_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: "openai_codex_oauth")
    :ok
  end

  defp persist_anthropic_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: "anthropic_oauth")
    :ok
  end
end
