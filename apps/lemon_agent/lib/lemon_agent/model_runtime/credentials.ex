defmodule LemonAgent.ModelRuntime.Credentials do
  @moduledoc """
  Lemon-owned provider credential resolution.

  This module owns resolved provider API-key lookup for Lemon callers. It
  centralizes provider alias handling, secret resolution, OAuth payload decoding,
  and provider availability checks before `LemonAi` receives runtime options.

  A selected OAuth login that cannot resolve returns `""`, not `nil`, so a
  request callback cannot replace the refusal with an earlier key. Pool entries
  still exclude unusable credentials and retain the configured default policy.

  ## Credential pools

  On top of the single-credential resolution, providers may carry extra
  credentials through `provider_routing.credential_pools.<pool>.credentials`
  (see `LemonCore.Config.Agent`). `list_provider_api_keys/3` returns the
  ordered pool credentials for a provider followed by the single-credential
  resolution as a final `"default"` entry, and `build_get_api_key/1` picks the
  first credential not in cooldown (`CredentialHealth`). With no pools
  configured, behavior is identical to plain single-credential resolution.

  ## omp

  `auth_source = "omp_broker"` reads the provider's credential from omp's auth
  broker (`LemonAgent.ModelRuntime.OmpBroker`) on any provider, built-in or
  custom; it is authoritative and fails closed like a selected OAuth login.
  `list_provider_api_keys/3` lists every broker account as an
  `"omp_broker:<id>"` entry so a rate-limited account rotates to the next one;
  `report_rate_limit/4` tells the broker to block it. The
  `omp_gateway` provider falls back to omp's `auth-gateway.token` after its
  environment, inline and secret-store keys.
  """

  require Logger

  alias LemonAi.Auth.OAuthSecretResolver
  alias LemonAi.Auth.OmpToken
  alias LemonAgent.ModelRuntime.CredentialHealth
  alias LemonAgent.ModelRuntime.CustomProviders
  alias LemonAgent.ModelRuntime.OmpBroker
  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ModelRuntime.StreamOptions.ProviderSettings
  alias LemonCore.Secrets

  @raw_anthropic_secret "llm_anthropic_api_key_raw"
  @omp_broker_ref_prefix "omp_broker:"

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
  single-credential resolution as a final `%{ref: "default"}` entry. For
  `auth_source = "omp_broker"` providers that final part is instead one
  `%{ref: "omp_broker:<id>"}` entry per broker account in the broker's order
  (none when the broker is unavailable). Entries
  whose secret/env fails to resolve are skipped. `config` may be a bare
  providers map or any map carrying `:providers` and `:provider_routing`
  (e.g. a settings struct or `LemonCore.Config`).
  """
  @spec list_provider_api_keys(map() | nil, atom() | String.t(), keyword()) :: [
          credential_entry()
        ]
  def list_provider_api_keys(config, provider, opts \\ []) do
    pool_credential_entries(config, provider, opts) ++
      default_credential_entries(config, provider, opts)
  end

  # An omp-broker provider lists one entry per broker account; a broker
  # failure yields none, so no other credential replaces the selection.
  defp default_credential_entries(config, provider, opts) do
    provider_cfg = provider_config(config, provider, opts)

    if normalize_auth_source(provider_cfg) == :omp_broker do
      omp_broker_entries(provider, provider_cfg)
    else
      case resolve_provider_api_key(provider, config, opts) do
        api_key when is_binary(api_key) ->
          if present_value?(api_key), do: [%{ref: "default", api_key: api_key}], else: []

        _ ->
          []
      end
    end
  end

  defp omp_broker_entries(provider, provider_cfg) do
    case OmpBroker.api_keys(provider, provider_cfg) do
      {:ok, keys} ->
        for {id, api_key} <- keys, present_value?(api_key) do
          %{ref: "#{@omp_broker_ref_prefix}#{id}", api_key: api_key}
        end

      {:error, reason} ->
        OmpBroker.log_failure(provider, reason)
        []
    end
  end

  @doc """
  Reports that the provider rate-limited a credential until the wall-clock
  `blocked_until_ms` (epoch milliseconds).

  For an `"omp_broker:<id>"` ref the omp auth broker is told asynchronously so
  it steers every client to its next account; the call never waits on the
  broker. Every other ref is a no-op.
  """
  @spec report_rate_limit(map() | nil, atom() | String.t(), String.t(), integer()) :: :ok
  def report_rate_limit(config, provider, credential_ref, blocked_until_ms)
      when is_binary(credential_ref) and is_integer(blocked_until_ms) do
    with {:ok, id} <- omp_broker_ref_id(credential_ref),
         provider_cfg = provider_config(config, provider, []),
         :omp_broker <- normalize_auth_source(provider_cfg) do
      OmpBroker.report_block(provider, provider_cfg, id, blocked_until_ms)
    else
      _ -> :ok
    end
  end

  def report_rate_limit(_config, _provider, _credential_ref, _blocked_until_ms), do: :ok

  defp omp_broker_ref_id(@omp_broker_ref_prefix <> id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp omp_broker_ref_id(_), do: :error

  @doc """
  Force-refreshes the OAuth credential behind one `list_provider_api_keys/3`
  entry after the provider rejected `previous_key` (for example an HTTP 401).

  `credential_ref` is the entry's `:ref`: `"default"`, `"secret:NAME"`,
  `"env:VAR"` or `"omp_broker:ID"` (recovers that exact omp broker
  credential). Environment variables, inline keys and plain API-key secrets
  cannot be refreshed and return `{:error, :not_refreshable}`. When the
  credential currently resolves to a key other than `previous_key` (another
  caller already refreshed it), that key is returned without a token request.
  Otherwise the OAuth helper refreshes under its lock and persists the result
  through the encrypted secret store; a failed refresh never returns the
  rejected key. Error reasons are bare atoms safe to log.
  """
  @spec refresh_provider_api_key(map() | nil, atom() | String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def refresh_provider_api_key(config, provider, credential_ref, previous_key)
      when is_binary(credential_ref) do
    provider_cfg = provider_config(config, provider, [])
    auth_source = normalize_auth_source(provider_cfg)

    cond do
      credential_ref == "default" and auth_source == :omp_broker ->
        OmpBroker.recover(provider, provider_cfg, previous_key)

      auth_source == :omp_broker and match?({:ok, _}, omp_broker_ref_id(credential_ref)) ->
        {:ok, id} = omp_broker_ref_id(credential_ref)
        OmpBroker.recover(provider, provider_cfg, previous_key, id: id)

      credential_ref == "default" and ProviderNames.canonical_name(provider) == "kimi_coding" and
          auth_source == :omp ->
        OmpToken.resolve(provider_config_value(provider_cfg, :omp_path), force_refresh: true)

      true ->
        case refresh_target(config, provider, credential_ref) do
          {:ok, secret_name, resolver} ->
            force_refresh_secret(secret_name, resolver, previous_key)

          {:error, _} = error ->
            error
        end
    end
  end

  def refresh_provider_api_key(_config, _provider, _credential_ref, _previous_key),
    do: {:error, :not_refreshable}

  # Maps a credential ref to the secret holding its OAuth payload and the
  # resolver that `resolve_provider_api_key/3` / pool resolution use for it, so
  # a refresh persists exactly what the next resolution reads.
  defp refresh_target(config, provider, "default") do
    provider_cfg = provider_config(config, provider, [])

    case ProviderNames.canonical_name(provider) do
      "openai_codex" ->
        if normalize_auth_source(provider_cfg) == :oauth do
          provider_cfg
          |> codex_oauth_secret_name()
          |> refresh_target_for(:openai_codex)
        else
          {:error, :not_refreshable}
        end

      "anthropic" ->
        if normalize_auth_source(provider_cfg) == :oauth do
          [
            provider_config_value(provider_cfg, :oauth_secret),
            provider_config_value(provider_cfg, :api_key_secret),
            ProviderNames.oauth_default_secret_name("anthropic")
          ]
          |> first_non_empty_binary()
          |> refresh_target_for(:anthropic)
        else
          {:error, :not_refreshable}
        end

      canonical when is_binary(canonical) ->
        # Generic resolution prefers environment and inline keys, which cannot
        # be refreshed, unless `auth_source = "oauth"` makes the stored sign-in
        # authoritative; otherwise it reads the configured or default secret.
        oauth? = normalize_auth_source(provider_cfg) == :oauth

        cond do
          # Resolution answers from (or stops at) an env-named credential.
          not oauth? and env_first(ProviderNames.env_vars(canonical)) != :miss ->
            {:error, :not_refreshable}

          not oauth? and present_value?(provider_config_value(provider_cfg, :api_key)) ->
            {:error, :not_refreshable}

          true ->
            generic_secret_name(provider_cfg, canonical)
            |> refresh_target_for(:generic)
        end

      _ ->
        {:error, :not_refreshable}
    end
  end

  defp refresh_target(_config, _provider, ref) do
    case parse_credential_ref(ref) do
      %{source: :secret, name: name} -> refresh_target_for(name, :generic)
      _ -> {:error, :not_refreshable}
    end
  end

  defp refresh_target_for(secret_name, resolver) do
    if present_value?(secret_name),
      do: {:ok, secret_name, resolver},
      else: {:error, :not_refreshable}
  end

  defp codex_oauth_secret_name(provider_cfg) do
    first_non_empty_binary([
      provider_config_value(provider_cfg, :oauth_secret),
      provider_config_value(provider_cfg, :api_key_secret),
      ProviderNames.default_secret_name("openai_codex")
    ])
  end

  defp force_refresh_secret(secret_name, resolver, previous_key) do
    case reload_secret(secret_name) do
      {:ok, value, _revision} when is_binary(value) ->
        case oauth_resolve(resolver, secret_name, value, []) do
          {:ok, current} when is_binary(current) and current != previous_key ->
            {:ok, current}

          :ignore ->
            {:error, :not_refreshable}

          {:ok, _current} ->
            case oauth_resolve(resolver, secret_name, value, force_refresh: true) do
              {:ok, fresh} when is_binary(fresh) -> {:ok, fresh}
              :ignore -> {:error, :not_refreshable}
              {:error, reason} -> {:error, safe_reason(reason)}
            end

          {:error, reason} ->
            {:error, safe_reason(reason)}
        end

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp oauth_resolve(:anthropic, secret_name, value, opts) do
    OAuthSecretResolver.resolve_with(
      LemonAi.Auth.AnthropicOAuth,
      secret_name,
      value,
      [
        persist_secret: &persist_anthropic_secret/3,
        reload_secret: &reload_secret/1
      ] ++ opts
    )
  end

  defp oauth_resolve(:openai_codex, secret_name, value, opts) do
    OAuthSecretResolver.resolve_with(
      LemonAi.Auth.OpenAICodexOAuth,
      secret_name,
      value,
      [
        persist_secret: &persist_openai_codex_secret/3,
        reload_secret: &reload_secret/1
      ] ++ opts
    )
  end

  defp oauth_resolve(:generic, secret_name, value, opts) do
    OAuthSecretResolver.resolve_api_key_from_secret(
      secret_name,
      value,
      [
        persist_secret: &persist_oauth_secret/3,
        reload_secret: &reload_secret/1
      ] ++ opts
    )
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

  @doc "Whether the provider config explicitly selects OAuth credential authority."
  @spec oauth_selected?(map() | nil) :: boolean()
  def oauth_selected?(provider_cfg), do: normalize_auth_source(provider_cfg) == :oauth

  @doc "Whether the provider config explicitly selects OAuth or omp credential authority."
  @spec authoritative_selected?(map() | nil) :: boolean()
  def authoritative_selected?(provider_cfg),
    do: normalize_auth_source(provider_cfg) in [:oauth, :omp, :omp_broker]

  @spec resolve_provider_api_key(atom() | String.t(), map() | nil, keyword()) :: String.t() | nil
  def resolve_provider_api_key(provider, providers_or_cfg, opts \\ []) do
    provider_cfg = provider_config(providers_or_cfg, provider, opts)

    if normalize_auth_source(provider_cfg) == :omp_broker do
      resolve_omp_broker_api_key(provider, provider_cfg)
    else
      resolve_configured_api_key(provider, provider_cfg)
    end
  end

  defp resolve_configured_api_key(provider, provider_cfg) do
    case ProviderNames.canonical_name(provider) do
      "openai_codex" ->
        resolve_openai_codex_api_key(provider_cfg)

      "anthropic" ->
        resolve_anthropic_api_key(provider_cfg)

      "kimi_coding" ->
        if normalize_auth_source(provider_cfg) == :omp,
          do: resolve_omp_api_key(provider_cfg),
          else: resolve_generic_api_key("kimi_coding", provider_cfg)

      # The gateway bearer omp itself stores is the last resort.
      "omp_gateway" ->
        case resolve_generic_api_key("omp_gateway", provider_cfg) do
          key when is_binary(key) and key != "" -> key
          _ -> LemonAi.Auth.OmpConfig.read_token(:gateway)
        end

      canonical when is_binary(canonical) ->
        resolve_generic_api_key(canonical, provider_cfg)

      # Not a ProviderNames provider: custom `[providers.<id>]` entries resolve
      # only their own configured credential, never another provider's env key.
      _ ->
        resolve_custom_api_key(provider_cfg)
    end
  end

  @spec resolve_secret_api_key(String.t(), keyword()) :: String.t() | nil
  def resolve_secret_api_key(secret_name, opts \\ []) do
    secret_name |> fetch_secret_api_key(opts) |> credential_value()
  end

  @doc """
  Tagged form of `resolve_secret_api_key/2`: `{:ok, api_key}`, `:miss` when
  the secret definitely does not exist (or no name is given), or `:error` when
  it exists but cannot be read or used. Callers that try another credential
  next must stop on `:error`.
  """
  @spec fetch_secret_api_key(String.t() | nil, keyword()) :: {:ok, String.t()} | :miss | :error
  def fetch_secret_api_key(secret_name, opts \\ [])

  def fetch_secret_api_key(secret_name, opts) when is_binary(secret_name) and secret_name != "" do
    env_fallback = Keyword.get(opts, :env_fallback, true)

    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: env_fallback) do
      {:ok, value, _source} ->
        case OAuthSecretResolver.resolve_api_key_from_secret(secret_name, value,
               persist_secret: &persist_oauth_secret/3,
               reload_secret: &reload_secret/1
             ) do
          {:ok, resolved_api_key} ->
            present_or_error(resolved_api_key)

          :ignore ->
            present_or_error(value)

          {:error, reason} ->
            # The value is a recognised OAuth payload that could not be used
            # (refresh or persistence failed); it is not an API key.
            Logger.warning(
              "Failed to resolve OAuth secret #{secret_name}: #{inspect(safe_reason(reason))}"
            )

            :error
        end

      result ->
        secret_miss_or_error(result)
    end
  end

  def fetch_secret_api_key(_, _), do: :miss

  @typedoc """
  Credential readiness: `:ready` (a credential is present), `:not_required`
  (keyless provider), `:missing` (none configured) or `:unusable` (configured
  but fails closed, for example an encrypted secret under another master key).
  """
  @type readiness :: :ready | :not_required | :missing | :unusable

  @doc """
  The single credential-readiness predicate shared by doctor, setup readiness,
  provider status, the CLI, the model catalog and runtime routing.

  Follows `resolve_provider_api_key/3`'s precedence (including authoritative
  OAuth/omp selections that never fall back to ambient credentials) and counts
  pool credentials: pass the routing config as `opts[:provider_routing]`.

  ## Modes (`opts[:mode]`)

    * `:presence` (default) - side-effect free: never decrypts a secret,
      refreshes an OAuth login, runs an external secret source or omp, or
      makes a network request. Stored secrets count only when the current
      master key is the store's (`LemonCore.Secrets.presence/2`), so an
      undecryptable credential is `:unusable`.
    * `:resolve` - resolves the credential exactly as a request would (may
      refresh a token or ask omp); answers `:ready`, `:not_required` or
      `:missing`.
  """
  @spec credential_readiness(atom() | String.t(), map() | nil, keyword()) :: readiness()
  def credential_readiness(provider, providers_map_or_cfg, opts \\ []) do
    provider_cfg = provider_config(providers_map_or_cfg, provider, opts)
    canonical = ProviderNames.canonical_name(provider)

    cond do
      ProviderNames.keyless?(canonical) or
          (is_nil(canonical) and CustomProviders.keyless?(provider_cfg)) ->
        :not_required

      Keyword.get(opts, :mode, :presence) == :resolve ->
        if pool_credentials_available?(provider, opts) or
             single_provider_has_credentials?(provider, providers_map_or_cfg, opts),
           do: :ready,
           else: :missing

      pool_credentials_present?(provider, opts) ->
        :ready

      true ->
        case presence(provider, canonical, provider_cfg) do
          {:ok, _} -> :ready
          :miss -> :missing
          :error -> :unusable
        end
    end
  end

  @doc """
  Whether `credential_readiness/3` reports a usable (or unneeded) credential.
  Takes the same options, including `:mode`.
  """
  @spec provider_has_credentials?(atom() | String.t(), map() | nil, keyword()) :: boolean()
  def provider_has_credentials?(provider, providers_map_or_cfg, opts \\ []) do
    credential_readiness(provider, providers_map_or_cfg, opts) in [:ready, :not_required]
  end

  # ---- Presence mode ----

  # Each candidate answers `{:ok, :present}`, `:miss` or `:error` and walks
  # through `first_credential/1`, so an unusable configured credential stops
  # the walk exactly as it stops resolution.
  defp presence(provider, canonical, provider_cfg) do
    source = normalize_auth_source(provider_cfg)

    cond do
      source == :omp_broker -> omp_broker_presence(provider, provider_cfg)
      canonical == "openai_codex" -> openai_codex_presence(provider_cfg, source)
      canonical == "anthropic" -> anthropic_presence(provider_cfg, source)
      canonical == "kimi_coding" and source == :omp -> omp_presence(provider_cfg)
      canonical == "google_vertex" -> vertex_presence(provider_cfg)
      canonical in ["amazon_bedrock", "bedrock_converse_stream"] -> bedrock_presence(provider_cfg)
      canonical == "omp_gateway" -> omp_gateway_presence(provider_cfg, source)
      is_binary(canonical) -> generic_presence(canonical, provider_cfg, source)
      true -> custom_presence(provider_cfg)
    end
  end

  defp omp_broker_presence(provider, provider_cfg) do
    cond do
      is_nil(OmpBroker.omp_provider(provider, provider_cfg)) ->
        :miss

      present_value?(LemonAi.Auth.OmpConfig.read_token(:broker)) ->
        {:ok, :present}

      true ->
        secret_env_presence("OMP_AUTH_BROKER_TOKEN")
    end
  end

  defp omp_presence(provider_cfg) do
    case OmpToken.discover(provider_config_value(provider_cfg, :omp_path)) do
      {:ok, _executable} -> {:ok, :present}
      _ -> :miss
    end
  end

  defp omp_gateway_presence(provider_cfg, source) do
    case generic_presence("omp_gateway", provider_cfg, source) do
      :miss ->
        if present_value?(LemonAi.Auth.OmpConfig.read_token(:gateway)),
          do: {:ok, :present},
          else: :miss

      other ->
        other
    end
  end

  defp openai_codex_presence(provider_cfg, :oauth),
    do: provider_cfg |> codex_oauth_secret_name() |> stored_presence()

  defp openai_codex_presence(provider_cfg, :api_key) do
    first_credential([
      fn -> env_presence("openai_codex") end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn -> stored_presence(provider_config_value(provider_cfg, :api_key_secret)) end
    ])
  end

  # Without an explicit auth source only the ambient sign-in counts, as in
  # `openai_codex_ambient_oauth_available?/0`.
  defp openai_codex_presence(_provider_cfg, :missing) do
    first_credential([
      fn -> secret_presence("OPENAI_CODEX_API_KEY", env_fallback: true) end,
      fn -> secret_presence("CHATGPT_TOKEN", env_fallback: true) end,
      fn -> stored_presence(ProviderNames.default_secret_name("openai_codex")) end
    ])
  end

  defp openai_codex_presence(_provider_cfg, _invalid), do: :miss

  defp anthropic_presence(provider_cfg, :oauth) do
    named =
      first_non_empty_binary([
        provider_config_value(provider_cfg, :oauth_secret),
        provider_config_value(provider_cfg, :api_key_secret)
      ])

    if present_value?(named) do
      stored_presence(named)
    else
      case stored_presence(ProviderNames.oauth_default_secret_name("anthropic")) do
        :miss ->
          if LemonAi.Auth.AnthropicOAuth.ambient_login_present?(),
            do: {:ok, :present},
            else: :miss

        other ->
          other
      end
    end
  end

  defp anthropic_presence(provider_cfg, source) when source in [:api_key, :missing] do
    first_credential([
      fn -> env_presence("anthropic") end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn -> stored_presence(provider_config_value(provider_cfg, :api_key_secret)) end,
      fn -> stored_presence(@raw_anthropic_secret) end
    ])
  end

  defp anthropic_presence(_provider_cfg, _invalid), do: :miss

  defp vertex_presence(provider_cfg) do
    case first_credential([
           fn -> present(provider_config_value(provider_cfg, :api_key)) end,
           fn ->
             secret_presence(provider_config_value(provider_cfg, :service_account_json_secret),
               env_fallback: true
             )
           end,
           fn -> present(provider_config_value(provider_cfg, :service_account_json)) end,
           fn -> present(System.get_env("GOOGLE_APPLICATION_CREDENTIALS_JSON")) end
         ]) do
      :miss -> present(System.get_env("GOOGLE_APPLICATION_CREDENTIALS"))
      other -> other
    end
  end

  defp bedrock_presence(provider_cfg) do
    key_pair =
      [
        {:access_key_id_secret, "AWS_ACCESS_KEY_ID"},
        {:secret_access_key_secret, "AWS_SECRET_ACCESS_KEY"}
      ]
      |> Enum.map(fn {field, ambient} ->
        first_credential([
          fn ->
            secret_presence(provider_config_value(provider_cfg, field), env_fallback: true)
          end,
          fn -> secret_presence(ambient, env_fallback: true) end
        ])
      end)

    cond do
      :error in key_pair -> :error
      Enum.all?(key_pair, &match?({:ok, _}, &1)) -> {:ok, :present}
      true -> secret_env_presence("AWS_PROFILE")
    end
  end

  defp generic_presence(canonical, provider_cfg, :oauth),
    do: provider_cfg |> generic_secret_name(canonical) |> stored_presence()

  defp generic_presence(canonical, provider_cfg, _source) do
    first_credential([
      fn -> env_presence(canonical) end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn ->
        case provider_config_value(provider_cfg, :api_key_secret) do
          name when is_binary(name) and name != "" -> secret_presence(name, env_fallback: true)
          _ -> secret_presence(ProviderNames.default_secret_name(canonical), env_fallback: true)
        end
      end
    ])
  end

  defp custom_presence(provider_cfg) do
    first_credential([
      fn -> present(provider_env_value(provider_cfg, :api_key_env)) end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn ->
        secret_presence(provider_config_value(provider_cfg, :api_key_secret), env_fallback: true)
      end
    ])
  end

  defp pool_credentials_present?(provider, opts) do
    case Keyword.get(opts, :provider_routing) do
      routing when is_map(routing) ->
        routing
        |> selected_pool(opts)
        |> pool_refs_for_provider(provider)
        |> Enum.any?(&match?({:ok, _}, credential_ref_presence(&1)))

      _ ->
        false
    end
  end

  defp credential_ref_presence(%{source: :env, name: name}) when is_binary(name),
    do: present(System.get_env(name))

  defp credential_ref_presence(%{source: :secret, name: name}) when is_binary(name),
    do: stored_presence(name)

  defp credential_ref_presence(%{"source" => source, "name" => name}) when is_binary(name),
    do: credential_ref_presence(%{source: ref_source(source), name: name})

  defp credential_ref_presence(ref) when is_binary(ref) do
    case parse_credential_ref(ref) do
      nil -> :miss
      parsed -> credential_ref_presence(parsed)
    end
  end

  defp credential_ref_presence(_), do: :miss

  defp env_presence(canonical) do
    canonical
    |> ProviderNames.env_vars()
    |> Enum.map(fn name -> fn -> secret_env_presence(name) end end)
    |> first_credential()
  end

  # Mirrors `secret_env_credential/1`: a set environment value answers (a
  # blank one is a miss), otherwise the store and external sources.
  defp secret_env_presence(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> present(value)
      _ -> secret_presence(name, env_fallback: true)
    end
  end

  # Mirrors the store-only reads of selected logins and raw secrets.
  defp stored_presence(name), do: secret_presence(name, env_fallback: false)

  defp secret_presence(name, opts) when is_binary(name) and name != "" do
    case Secrets.presence(name, opts) do
      :present -> {:ok, :present}
      :missing -> :miss
      {:unusable, _reason} -> :error
    end
  end

  defp secret_presence(_name, _opts), do: :miss

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

      canonical ->
        ProviderNames.keyless?(canonical) or
          present_value?(resolve_provider_api_key(provider, provider_cfg, provider_cfg: true)) or
          (is_nil(canonical) and CustomProviders.keyless?(provider_cfg))
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

  # A broker failure returns "" so no other credential replaces the selection.
  defp resolve_omp_broker_api_key(provider, provider_cfg) do
    case OmpBroker.api_key(provider, provider_cfg) do
      {:ok, key} ->
        key

      {:error, reason} ->
        OmpBroker.log_failure(provider, reason)
        ""
    end
  end

  defp resolve_omp_api_key(provider_cfg) do
    case OmpToken.resolve(provider_config_value(provider_cfg, :omp_path)) do
      {:ok, token} ->
        token

      {:error, reason} ->
        Logger.warning(OmpToken.error_message(reason))
        ""
    end
  end

  # `auth_source = "oauth"` makes the selected stored sign-in authoritative:
  # oauth_secret > api_key_secret > default, never ambient env or inline keys.
  defp resolve_generic_api_key(provider, provider_cfg) do
    if normalize_auth_source(provider_cfg) == :oauth do
      case generic_secret_name(provider_cfg, provider) do
        secret_name when is_binary(secret_name) ->
          resolve_secret_api_key(secret_name, env_fallback: false) || ""

        _ ->
          ""
      end
    else
      first_credential([
        fn -> provider |> ProviderNames.env_vars() |> env_first() end,
        fn -> present(provider_config_value(provider_cfg, :api_key)) end,
        fn ->
          case provider_config_value(provider_cfg, :api_key_secret) do
            name when is_binary(name) and name != "" -> fetch_secret_api_key(name)
            _ -> fetch_secret_api_key(ProviderNames.default_secret_name(provider))
          end
        end
      ])
      |> credential_value()
    end
  end

  defp generic_secret_name(provider_cfg, provider) do
    first_non_empty_binary([
      if(normalize_auth_source(provider_cfg) == :oauth,
        do: provider_config_value(provider_cfg, :oauth_secret)
      ),
      provider_config_value(provider_cfg, :api_key_secret),
      ProviderNames.default_secret_name(provider)
    ])
  end

  # Custom providers: `api_key_env` -> inline `api_key` -> `api_key_secret`.
  # `auth = "none"` providers are ready without any key (see
  # `single_provider_has_credentials?/3`).
  defp resolve_custom_api_key(provider_cfg) do
    first_credential([
      fn -> present(provider_env_value(provider_cfg, :api_key_env)) end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn -> fetch_secret_api_key(provider_config_value(provider_cfg, :api_key_secret)) end
    ])
    |> credential_value()
  end

  defp provider_env_value(provider_cfg, key) do
    case provider_config_value(provider_cfg, key) do
      name when is_binary(name) and name != "" -> System.get_env(name)
      _ -> nil
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
            "providers.openai-codex.auth_source is required and must be one of: oauth, api_key, omp_broker"
          )

          nil

        {:invalid, value} ->
          Logger.warning(
            "providers.openai-codex.auth_source=#{inspect(value)} is invalid; expected oauth, api_key or omp_broker"
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
        case OAuthSecretResolver.resolve_with(
               LemonAi.Auth.OpenAICodexOAuth,
               secret_name,
               value,
               persist_secret: &persist_openai_codex_secret/3,
               reload_secret: &reload_secret/1
             ) do
          {:ok, resolved_api_key} ->
            resolved_api_key

          :ignore ->
            resolve_openai_codex_onboarding_access_token(secret_name, value)

          {:error, reason} ->
            Logger.warning(
              "Failed to resolve OpenAI Codex OAuth secret #{secret_name}: #{inspect(safe_reason(reason))}"
            )

            nil
        end

      _ ->
        nil
    end
  end

  defp resolve_openai_codex_raw_api_key(provider_cfg) do
    first_credential([
      fn -> "openai_codex" |> ProviderNames.env_vars() |> env_first() end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn -> fetch_raw_secret_api_key(provider_config_value(provider_cfg, :api_key_secret)) end
    ])
    |> credential_value()
  end

  defp resolve_anthropic_api_key(provider_cfg) do
    case normalize_auth_source(provider_cfg) do
      :oauth ->
        resolve_anthropic_oauth_key(provider_cfg) || ""

      source when source in [:api_key, :missing] ->
        first_credential([
          fn -> anthropic_raw_api_key(provider_cfg) end,
          fn -> fetch_raw_secret_api_key(@raw_anthropic_secret) end
        ])
        |> credential_value()
        |> Kernel.||("")

      {:invalid, value} ->
        Logger.warning(
          "providers.anthropic.auth_source=#{inspect(value)} is invalid; expected oauth, api_key or omp_broker when set"
        )

        ""
    end
  end

  # A configured or stored Lemon login fails closed: when it exists but cannot
  # produce a token (rejected refresh, persistence failure), resolution returns
  # no credential instead of switching to ambient Claude Code tokens.
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
        case resolve_anthropic_oauth_secret(secret_name) do
          {:ok, api_key} -> api_key
          _ -> nil
        end

      present_value?(default_secret_name) ->
        case resolve_anthropic_oauth_secret(default_secret_name) do
          {:ok, api_key} -> api_key
          :error -> nil
          _missing_or_not_oauth -> resolve_anthropic_access_token()
        end

      true ->
        resolve_anthropic_access_token()
    end
  end

  defp resolve_anthropic_oauth_secret(secret_name) do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} ->
        case OAuthSecretResolver.resolve_with(
               LemonAi.Auth.AnthropicOAuth,
               secret_name,
               value,
               persist_secret: &persist_anthropic_secret/3,
               reload_secret: &reload_secret/1
             ) do
          {:ok, resolved_api_key} ->
            {:ok, resolved_api_key}

          :ignore ->
            Logger.warning(
              "Anthropic OAuth secret #{secret_name} is not a recognized Anthropic OAuth payload"
            )

            :not_oauth

          {:error, :reauth_required} ->
            Logger.warning(
              "Anthropic rejected the Claude login refresh in #{secret_name}; " <>
                "run `lemon model anthropic` to sign in again"
            )

            :error

          {:error, reason} ->
            Logger.warning(
              "Failed to resolve Anthropic OAuth secret #{secret_name}: #{inspect(safe_reason(reason))}"
            )

            :error
        end

      {:error, :not_found} ->
        :missing

      # An unreadable stored login is not an absent one: never continue to
      # ambient Claude credentials.
      _ ->
        :error
    end
  end

  # Bind a refresh to the authoritative encrypted-store incarnation. External
  # and environment credentials are read-only and cannot be refreshed into it.
  defp reload_secret(secret_name) do
    Secrets.get_with_revision(secret_name)
  end

  defp anthropic_raw_api_key(provider_cfg) do
    first_credential([
      fn -> "anthropic" |> ProviderNames.env_vars() |> env_first() end,
      fn -> present(provider_config_value(provider_cfg, :api_key)) end,
      fn -> fetch_anthropic_raw_secret(provider_config_value(provider_cfg, :api_key_secret)) end
    ])
  end

  defp fetch_raw_secret_api_key(secret_name) when is_binary(secret_name) and secret_name != "" do
    case resolve_secret_value(secret_name, prefer_env: false, env_fallback: false) do
      {:ok, value, _source} -> present_or_error(value)
      result -> secret_miss_or_error(result)
    end
  end

  defp fetch_raw_secret_api_key(_), do: :miss

  defp fetch_anthropic_raw_secret(secret_name)
       when is_binary(secret_name) and secret_name != "" do
    with {:ok, value} <- fetch_raw_secret_api_key(secret_name) do
      case Jason.decode(value) do
        {:ok, %{"type" => type, "access_token" => token}}
        when type in ["anthropic_oauth", "onboarding_anthropic_oauth"] and is_binary(token) and
               token != "" ->
          Logger.warning(
            "Anthropic OAuth payload secret #{secret_name} cannot be used as a raw API key; configure an Anthropic API key instead"
          )

          :error

        _ ->
          {:ok, value}
      end
    end
  end

  defp fetch_anthropic_raw_secret(_), do: :miss

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
      ProviderSettings.resolve(:google_vertex, %{
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
      |> ProviderSettings.resolve(stream_provider_input(provider_cfg, %{}, opts, :bedrock_converse_stream))

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

  # `Secrets.resolve/2` owns store, external-source and environment order and
  # fails closed; a crash here is a failure too, never a reason to read env.
  defp resolve_secret_value(secret_name, opts) when is_binary(secret_name) do
    Secrets.resolve(secret_name, opts)
  rescue
    _ -> {:error, :secret_resolution_failed}
  catch
    :exit, _ -> {:error, :secret_resolution_failed}
  end

  defp resolve_secret_value(_, _), do: {:error, :invalid_secret_name}

  defp resolve_secret_env(name), do: name |> secret_env_credential() |> credential_value()

  defp secret_env_credential(name) do
    case resolve_secret_value(name, prefer_env: true, env_fallback: true) do
      {:ok, value, _source} -> present(value)
      result -> secret_miss_or_error(result)
    end
  end

  # Credential candidates in precedence order, each returning `{:ok, value}`,
  # `:miss` (definitely absent) or `:error` (configured but unreadable). An
  # error stops the walk: a later env, inline or alias credential never
  # replaces an unreadable one.
  defp first_credential(candidates) do
    Enum.reduce_while(candidates, :miss, fn candidate, :miss ->
      case candidate.() do
        {:ok, _value} = found -> {:halt, found}
        :miss -> {:cont, :miss}
        :error -> {:halt, :error}
      end
    end)
  end

  defp credential_value({:ok, value}), do: value
  defp credential_value(_miss_or_error), do: nil

  defp present(value), do: if(present_value?(value), do: {:ok, value}, else: :miss)
  defp present_or_error(value), do: if(present_value?(value), do: {:ok, value}, else: :error)

  defp secret_miss_or_error({:error, :not_found}), do: :miss
  defp secret_miss_or_error(_error), do: :error

  defp provider_config(providers_or_cfg, provider, opts) do
    if Keyword.get(opts, :provider_cfg, false) do
      normalize_provider_cfg(providers_or_cfg)
    else
      providers_or_cfg
      |> ProviderNames.provider_config(provider)
      |> Kernel.||(CustomProviders.config_for(providers_or_cfg, provider))
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
    provider_cfg
    |> provider_config_value(:auth_source)
    |> LemonCore.Config.Providers.normalize_auth_source()
    |> case do
      nil -> :missing
      "oauth" -> :oauth
      "api_key" -> :api_key
      "omp" -> :omp
      "omp_broker" -> :omp_broker
      source -> {:invalid, source}
    end
  end

  defp env_first(names) when is_list(names) do
    first_credential(Enum.map(names, fn name -> fn -> secret_env_credential(name) end end))
  end

  defp first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, &present_value?/1)
  end

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_openai_codex_access_token do
    first_credential([
      fn -> fetch_secret_api_key("OPENAI_CODEX_API_KEY", env_fallback: true) end,
      fn -> fetch_secret_api_key("CHATGPT_TOKEN", env_fallback: true) end,
      fn ->
        fetch_secret_api_key(ProviderNames.default_secret_name("openai_codex"),
          env_fallback: false
        )
      end,
      fn -> present(LemonAi.Auth.OpenAICodexOAuth.resolve_access_token()) end
    ])
    |> credential_value()
  end

  defp resolve_anthropic_access_token do
    first_credential([
      fn -> present(LemonAi.Auth.AnthropicOAuth.resolve_access_token()) end,
      fn ->
        fetch_secret_api_key(ProviderNames.oauth_default_secret_name("anthropic"),
          env_fallback: false
        )
      end
    ])
    |> credential_value()
  end

  # Persistence results are returned, not swallowed: a refreshed OAuth secret
  # that was not stored (for example `{:error, :secrets_locked}` during a key
  # rotation) must fail the resolution rather than strand a rotated refresh
  # token.
  defp persist_oauth_secret(secret_name, encoded_secret, revision) do
    Secrets.set_if_revision(secret_name, encoded_secret, revision, provider: "ai_oauth")
  end

  defp persist_openai_codex_secret(secret_name, encoded_secret, revision) do
    Secrets.set_if_revision(secret_name, encoded_secret, revision, provider: "openai_codex_oauth")
  end

  defp persist_anthropic_secret(secret_name, encoded_secret, revision) do
    Secrets.set_if_revision(secret_name, encoded_secret, revision, provider: "anthropic_oauth")
  end

  # Error terms from OAuth helpers can carry provider response bodies; log only
  # their leading tag.
  defp safe_reason(reason) when is_atom(reason), do: reason

  defp safe_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp safe_reason(_reason), do: :unknown
end
