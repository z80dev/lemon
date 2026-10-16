defmodule LemonCli.Setup.ProviderAuth do
  @moduledoc """
  `lemon model PROVIDER --status` and `--logout` for providers that sign in
  with OAuth.

  Status reports the configured auth source, the stored login (account,
  access-token expiry, estimated re-login date) and whether the provider's
  credentials resolve. Resolving may refresh an access token that is close to
  expiry, exactly as a model request would. Credential values are never shown.

  Logout deletes the stored OAuth login secret and removes the provider's
  `auth_source = "oauth"` and `oauth_secret` config entries (and an
  `api_key_secret` that referenced the deleted login), so API-key resolution
  applies again. For sign-ins that mint a durable API key (OpenRouter, Z.AI)
  status reports whether that key is stored and logout deletes it. Logout does
  not revoke the grant or key at the provider and leaves external logins
  (Claude Code, Codex CLI) and environment tokens alone.

  Status and logout fail closed when the encrypted login cannot be read.
  Only confirmed absence permits removing stale sign-in settings; storage,
  key and decryption failures leave the login and its configuration unchanged.
  """

  alias LemonAgent.ModelRuntime.{Credentials, ProviderNames}
  alias LemonCli.Onboarding.Provider
  alias LemonCli.Onboarding.Providers
  alias LemonCli.Setup.ProviderManagement
  alias LemonAi.Auth.OAuthSecretResolver
  alias LemonCli.Onboarding.Runner
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Secrets

  @type auth_error :: :login_read_failed | :login_delete_failed

  @spec status(Provider.t(), String.t(), map(), keyword()) :: :ok | {:error, auth_error()}
  def status(%Provider{} = spec, config_path, io, opts \\ []) do
    ensure_oauth_provider!(spec)
    config = read_config(config_path)
    provider_cfg = get_in(config, ["providers", spec.id]) || %{}
    auth_source = normalize(provider_cfg["auth_source"])
    secret_name = normalize(opts[:secret_name]) || oauth_secret_name(spec, provider_cfg)

    case stored_login(spec, secret_name) do
      {:ok, login} ->
        io.info.("#{spec.display_name} authentication")
        io.info.("  Config: #{Path.expand(config_path)}")
        io.info.("  Auth source: #{auth_source_label(auth_source)}")

        login_lines(spec, secret_name, login)
        |> Enum.each(&io.info.("  " <> &1))

        api_key_env_lines(spec, auth_source)
        |> Enum.each(&io.info.("  " <> &1))

        ready? =
          if opts[:secret_name] do
            present?(Credentials.resolve_secret_api_key(secret_name, env_fallback: false))
          else
            Credentials.provider_has_credentials?(spec.id, Map.get(config, "providers", %{}))
          end

        io.info.("  Credentials usable: #{if ready?, do: "yes", else: "no"}")
        :ok

      {:error, _} = error ->
        auth_failure(error, io)
    end
  end

  @spec logout(Provider.t(), String.t(), map(), keyword()) :: :ok | {:error, auth_error()}
  def logout(%Provider{} = spec, config_path, io, opts \\ []) do
    ensure_oauth_provider!(spec)
    expanded = Path.expand(config_path)
    content = read_config_content(expanded)
    provider_cfg = get_in(decode!(content, expanded), ["providers", spec.id]) || %{}
    configured_secret = oauth_secret_name(spec, provider_cfg)
    secret_name = normalize(opts[:secret_name]) || configured_secret

    case stored_login(spec, secret_name) do
      {:ok, login} ->
        deleted? = login == :api_key or is_tuple(login)
        changes = if deleted?, do: [{secret_name, :delete}], else: []

        patch = fn content ->
          provider_cfg = get_in(decode!(content, expanded), ["providers", spec.id]) || %{}

          stale_api_key_secret? =
            deleted? and normalize(provider_cfg["api_key_secret"]) == secret_name

          if secret_name == oauth_secret_name(spec, provider_cfg) and
               (normalize(provider_cfg["auth_source"]) == "oauth" or
                  is_binary(provider_cfg["oauth_secret"]) or stale_api_key_secret?) do
            content
            |> TomlPatch.delete_key(spec.provider_table, "auth_source")
            |> TomlPatch.delete_key(spec.provider_table, "oauth_secret")
            |> then(fn patched ->
              if stale_api_key_secret?,
                do: TomlPatch.delete_key(patched, spec.provider_table, "api_key_secret"),
                else: patched
            end)
          else
            content
          end
        end

        case ProviderManagement.persist(expanded, changes, patch) do
          :ok ->
            report_deleted_login(spec, secret_name, login, io)

            io.info.(
              if deleted? do
                "This stored login was deleted. Run `lemon model #{spec.id}` to sign in again. " <>
                  "Other stored logins are unchanged."
              else
                "No stored login was deleted. Other stored logins are unchanged."
              end
            )

            :ok

          {:error, :secret_read_failed} ->
            auth_failure({:error, :login_read_failed}, io)

          {:error, _} ->
            auth_failure({:error, :login_delete_failed}, io)
        end

      {:error, _} = error ->
        auth_failure(error, io)
    end
  end

  defp report_deleted_login(spec, secret_name, login, io)
       when login == :api_key or is_tuple(login) do
    if login == :api_key do
      io.info.(
        "Deleted the stored #{spec.display_name} API key (secret #{secret_name}). " <>
          "Revoke it in the provider's dashboard if it should stop working everywhere."
      )
    else
      io.info.("Deleted the stored #{spec.display_name} login (secret #{secret_name}).")
    end
  end

  defp report_deleted_login(_spec, secret_name, :not_oauth, io) do
    io.info.("Secret #{secret_name} does not hold an OAuth login; left unchanged.")
  end

  defp report_deleted_login(spec, secret_name, :missing, io) do
    io.info.("No stored #{spec.display_name} login in secret #{secret_name}.")
  end

  defp auth_failure({:error, :login_read_failed} = error, io) do
    io.error.("The stored login could not be read. Sign-in settings were left unchanged.")
    error
  end

  defp auth_failure({:error, :login_delete_failed} = error, io) do
    io.error.("The stored login could not be deleted. Sign-in settings were left unchanged.")
    error
  end

  defp ensure_oauth_provider!(%Provider{} = spec) do
    unless Enum.any?([:oauth, :device], &(&1 in spec.auth_modes)) and spec.oauth_module do
      Runner.fail!("#{spec.display_name} does not use an OAuth login.")
    end
  end

  # The config key onboarding wrote for the sign-in secret (`oauth_secret`, or
  # `api_key_secret` for providers that resolve their login like an API key).
  defp oauth_secret_name(%Provider{} = spec, provider_cfg) do
    key = Map.get(spec.secret_config_key_by_mode, :oauth, "api_key_secret")

    normalize(provider_cfg[key]) || normalize(provider_cfg["oauth_secret"]) ||
      get_in(spec.default_secret_name_by_mode || %{}, [:oauth]) ||
      spec.default_secret_name
  end

  defp stored_login(%Provider{oauth_result: :api_key}, secret_name) do
    case Secrets.get(secret_name) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, :api_key}
      {:ok, _value} -> {:ok, :not_oauth}
      {:error, :not_found} -> {:ok, :missing}
      {:error, _reason} -> {:error, :login_read_failed}
    end
  end

  defp stored_login(%Provider{oauth_module: module}, secret_name) do
    case Secrets.get(secret_name) do
      {:ok, value} ->
        case module.decode_secret(value) do
          {:ok, secret} -> {:ok, {:oauth, secret}}
          _ -> {:ok, :not_oauth}
        end

      {:error, :not_found} ->
        {:ok, :missing}

      {:error, _reason} ->
        {:error, :login_read_failed}
    end
  end

  defp login_lines(%Provider{} = spec, secret_name, login) do
    case login do
      {:oauth, secret} ->
        info = describe(spec.oauth_module, secret)
        now = System.system_time(:millisecond)

        [
          "Stored login: #{secret_name} (#{kind_label(info.kind)}#{account_label(info)})"
          | Enum.reject(
              [
                expiry_line(info, now),
                if(is_integer(info[:reauth_by_ms]),
                  do:
                    "Sign in again by: #{format_date(info.reauth_by_ms)} " <>
                      "(the provider ends a login about 30 days after sign-in)"
                )
              ],
              &is_nil/1
            )
        ]

      :api_key ->
        ["Stored API key: #{secret_name} (set; from sign-in or a pasted key, never expires)"]

      :not_oauth ->
        ["Stored login: none (#{secret_name} holds a non-OAuth value)"]

      :missing ->
        ["Stored login: none (#{secret_name} is not set)"]
    end
  end

  defp describe(module, secret) do
    if function_exported?(module, :describe_secret, 1) do
      module.describe_secret(secret)
    else
      %{
        kind: if(secret["refresh_token"], do: :refreshable, else: :static_token),
        expires_at_ms: secret["expires_at_ms"]
      }
    end
  end

  defp expiry_line(%{expires_at_ms: expires_at_ms, kind: kind}, now)
       when is_integer(expires_at_ms) do
    suffix = if kind == :refreshable, do: "; refreshed automatically", else: ""

    if expires_at_ms > now do
      "Access token: expires in #{format_duration(expires_at_ms - now)}#{suffix}"
    else
      "Access token: expired #{format_duration(now - expires_at_ms)} ago#{suffix}"
    end
  end

  defp expiry_line(_info, _now), do: nil

  defp api_key_env_lines(%Provider{} = spec, auth_source) do
    spec.id
    |> ProviderNames.env_vars()
    |> Enum.filter(&present?(System.get_env(&1)))
    |> Enum.map(fn env_var ->
      if auth_source == "oauth",
        do: "#{env_var}: set, ignored while auth_source = \"oauth\"",
        else: "#{env_var}: set, used for API-key authentication"
    end)
  end

  defp auth_source_label("oauth"), do: "oauth (subscription login)"
  defp auth_source_label("api_key"), do: "api_key"
  defp auth_source_label(nil), do: "not set (API key)"
  defp auth_source_label(other), do: "#{other} (invalid)"

  defp kind_label(:refreshable), do: "refreshable login"
  defp kind_label(_), do: "static token, no refresh"

  defp account_label(%{account_email: email, organization_name: org})
       when is_binary(email) and is_binary(org),
       do: ", #{email}, #{org}"

  defp account_label(%{account_email: email}) when is_binary(email), do: ", #{email}"
  defp account_label(_), do: ""

  defp format_duration(ms) do
    minutes = div(ms, 60_000)

    cond do
      minutes < 1 -> "less than a minute"
      minutes < 60 -> "#{minutes}m"
      minutes < 48 * 60 -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
      true -> "#{div(minutes, 24 * 60)} days"
    end
  end

  defp format_date(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()
  end

  @doc """
  Credential-free static observation for the provider management projection.

  Reads only the encrypted store. OAuth payloads are decoded using their real
  auth module, but never refreshed. Expired or refresh-due payloads are not
  resolved. Fresh non-Google payloads run the real resolver on an immutable
  token-only snapshot (refresh removed); Google project discovery is deliberately
  not invoked. A resolver timestamp is emitted only when that local check ran.
  """
  def static_status(provider_id, provider_cfg, secrets \\ Secrets) do
    if ProviderNames.keyless?(provider_id) do
      observation("ready", false, nil)
    else
      selected_oauth? = Credentials.oauth_selected?(provider_cfg)

      name =
        if selected_oauth? do
          normalize(provider_cfg["oauth_secret"]) ||
            normalize(provider_cfg["api_key_secret"]) ||
            ProviderNames.oauth_default_secret_name(provider_id) ||
            ProviderNames.default_secret_name(provider_id)
        else
          normalize(provider_cfg["api_key_secret"]) ||
            ProviderNames.default_secret_name(provider_id)
        end

      cond do
        provider_id in ["google_vertex", "amazon_bedrock", "bedrock_converse_stream"] ->
          observation(
            if(provider_cfg == %{}, do: "needs_login", else: "configured"),
            provider_cfg != %{},
            nil
          )

        provider_id == "openai_codex" and
            normalize(provider_cfg["auth_source"]) not in ["api_key", "oauth"] ->
          observation("needs_login", provider_cfg != %{}, nil)

        not selected_oauth? ->
          case static_api_candidate(provider_id, provider_cfg, name, secrets) do
            {:ok, value} -> static_value(value, false)
            {:error, :not_found} -> observation("needs_login", false, nil)
            {:error, :expired} -> observation("expired", true, nil)
            _ -> %{error: :secret_read_failed}
          end

        true ->
          case apply(secrets, :get, [name]) do
            {:ok, value} -> static_value(value, selected_oauth?)
            {:error, :not_found} -> observation("needs_login", false, nil)
            {:error, :expired} -> observation("expired", true, nil)
            _ -> %{error: :secret_read_failed}
          end
      end
    end
  rescue
    _ -> %{error: :secret_read_failed}
  catch
    _, _ -> %{error: :secret_read_failed}
  end

  defp static_api_candidate(provider_id, cfg, name, secrets) do
    # The runtime checks canonical environment names (including encrypted
    # import-env entries) before the configured inline/reference credential.
    candidate =
      Enum.reduce_while(ProviderNames.env_vars(provider_id), nil, fn env, _ ->
        result =
          case System.get_env(env) do
            value when is_binary(value) and value != "" -> {:ok, value}
            _ -> apply(secrets, :get, [env])
          end

        case result do
          {:error, :not_found} -> {:cont, nil}
          other -> {:halt, other}
        end
      end)

    candidate ||
      if(present?(cfg["api_key"]),
        do: {:ok, cfg["api_key"]},
        else: apply(secrets, :get, [name])
      )
  end

  defp static_value(value, selected_oauth?) do
    decoded =
      Providers.list()
      |> Enum.map(& &1.oauth_module)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.find_value(fn module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :decode_secret, 1) do
          case module.decode_secret(value) do
            {:ok, secret} -> {module, secret}
            _ -> nil
          end
        end
      end)

    case decoded do
      {module, secret} ->
        static_oauth(module, secret)

      nil when selected_oauth? ->
        observation("needs_login", present?(value), nil)

      nil ->
        # The runtime's generic secret resolver accepts unrecognized payloads
        # as plain API keys. No secret lookup or external source is involved.
        result = OAuthSecretResolver.resolve_api_key_from_secret("management_static", value)
        ready? = result == :ignore and present?(value)
        observation(if(ready?, do: "ready", else: "needs_login"), present?(value), ready?)
    end
  end

  defp static_oauth(module, secret) do
    info = describe(module, secret)
    now = System.system_time(:millisecond)
    expires = info[:expires_at_ms]
    reauth = info[:reauth_by_ms]

    cond do
      (is_integer(expires) and expires <= now) or (is_integer(reauth) and reauth <= now) ->
        observation("expired", true, nil)

      not present?(secret["access_token"]) ->
        observation("needs_login", true, nil)

      (is_integer(expires) and expires <= now + 11 * 60_000) or
          module in [LemonAi.Auth.GoogleAntigravityOAuth, LemonAi.Auth.GoogleGeminiCliOAuth] ->
        observation("configured", true, nil)

      true ->
        snapshot = secret |> Map.put("refresh_token", nil) |> module.encode_secret()

        ready? =
          case module.resolve_api_key_from_secret("management_static", snapshot) do
            {:ok, key} -> present?(key)
            _ -> false
          end

        observation(if(ready?, do: "ready", else: "needs_login"), true, ready?)
    end
  end

  defp observation(status, configured, ready) do
    validation =
      if is_boolean(ready),
        do: %{atMs: System.system_time(:millisecond), kind: "resolver", ready: ready},
        else: nil

    %{status: status, configured: configured, last_validation: validation}
  end

  defp read_config(path) do
    expanded = Path.expand(path)
    expanded |> read_config_content() |> decode!(expanded)
  end

  defp read_config_content(expanded) do
    case File.read(expanded) do
      {:ok, content} -> content
      {:error, :enoent} -> ""
      {:error, _} -> Runner.fail!("Could not read provider config. Check permissions.")
    end
  end

  defp decode!(content, _path) do
    case Toml.decode(content) do
      {:ok, decoded} ->
        decoded

      {:error, _} ->
        Runner.fail!("Provider config is not valid TOML. Run `lemon config validate`.")
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil

  defp present?(value), do: normalize(value) != nil
end
