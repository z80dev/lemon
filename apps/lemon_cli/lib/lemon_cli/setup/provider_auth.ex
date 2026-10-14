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

    with {:ok, login} <- stored_login(spec, secret_name) do
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
    else
      {:error, _} = error -> auth_failure(error, io)
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

    with {:ok, login} <- stored_login(spec, secret_name),
         {:ok, deleted?} <- delete_login(spec, secret_name, login, io) do
      stale_api_key_secret? =
        deleted? and normalize(provider_cfg["api_key_secret"]) == secret_name

      if secret_name == configured_secret and
           (normalize(provider_cfg["auth_source"]) == "oauth" or
              is_binary(provider_cfg["oauth_secret"]) or stale_api_key_secret?) do
        updated =
          content
          |> TomlPatch.delete_key(spec.provider_table, "auth_source")
          |> TomlPatch.delete_key(spec.provider_table, "oauth_secret")
          |> then(fn patched ->
            if stale_api_key_secret?,
              do: TomlPatch.delete_key(patched, spec.provider_table, "api_key_secret"),
              else: patched
          end)

        # Refuse to write a patch that no longer parses.
        _ = decode!(updated, expanded)
        File.write!(expanded, updated)
        io.info.("Removed sign-in settings from [#{spec.provider_table}] in #{expanded}.")
      end

      io.info.(
        if deleted? do
          "This stored login was deleted. Run `lemon model #{spec.id}` to sign in again. " <>
            "Other stored logins are unchanged."
        else
          "No stored login was deleted. Other stored logins are unchanged."
        end
      )

      :ok
    else
      {:error, _} = error -> auth_failure(error, io)
    end
  end

  defp delete_login(spec, secret_name, login, io) when login == :api_key or is_tuple(login) do
    case Secrets.delete(secret_name) do
      :ok ->
        if login == :api_key do
          io.info.(
            "Deleted the stored #{spec.display_name} API key (secret #{secret_name}). " <>
              "Revoke it in the provider's dashboard if it should stop working everywhere."
          )
        else
          io.info.("Deleted the stored #{spec.display_name} login (secret #{secret_name}).")
        end

        {:ok, true}

      {:error, _reason} ->
        {:error, :login_delete_failed}
    end
  end

  defp delete_login(_spec, secret_name, :not_oauth, io) do
    io.info.("Secret #{secret_name} does not hold an OAuth login; left unchanged.")
    {:ok, false}
  end

  defp delete_login(spec, secret_name, :missing, io) do
    io.info.("No stored #{spec.display_name} login in secret #{secret_name}.")
    {:ok, false}
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

  defp read_config(path) do
    expanded = Path.expand(path)
    expanded |> read_config_content() |> decode!(expanded)
  end

  defp read_config_content(expanded) do
    case File.read(expanded) do
      {:ok, content} -> content
      {:error, :enoent} -> ""
      {:error, reason} -> Runner.fail!("Failed to read #{expanded}: #{inspect(reason)}")
    end
  end

  defp decode!(content, path) do
    case Toml.decode(content) do
      {:ok, decoded} ->
        decoded

      {:error, reason} ->
        Runner.fail!("Config file #{path} is not valid TOML: #{inspect(reason)}")
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
