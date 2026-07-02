defmodule XApi do
  @moduledoc """
  X API client configuration and authentication helpers.

  Config can be set under `config :x_api, XApi`. Existing
  `config :lemon_channels, LemonChannels.Adapters.XAPI` settings remain
  supported as a compatibility fallback.
  """

  require Logger

  alias LemonCore.Secrets

  @legacy_app :lemon_channels
  @legacy_module :"Elixir.LemonChannels.Adapters.XAPI"
  @env_config_keys [
    client_id: "X_API_CLIENT_ID",
    client_secret: "X_API_CLIENT_SECRET",
    bearer_token: "X_API_BEARER_TOKEN",
    access_token: "X_API_ACCESS_TOKEN",
    refresh_token: "X_API_REFRESH_TOKEN",
    token_expires_at: "X_API_TOKEN_EXPIRES_AT",
    default_account_id: "X_DEFAULT_ACCOUNT_ID",
    default_account_username: "X_DEFAULT_ACCOUNT_USERNAME",
    consumer_key: "X_API_CONSUMER_KEY",
    consumer_secret: "X_API_CONSUMER_SECRET",
    access_token_secret: "X_API_ACCESS_TOKEN_SECRET"
  ]

  @token_config_keys [:access_token, :refresh_token, :token_expires_at]

  @doc """
  Get the current configuration.
  """
  def config do
    app_config =
      :x_api
      |> Application.get_env(__MODULE__, [])
      |> normalize_app_config()

    legacy_config =
      @legacy_app
      |> Application.get_env(@legacy_module, [])
      |> normalize_app_config()

    configured =
      legacy_config
      |> Keyword.merge(app_config, fn _key, _legacy_value, app_value -> app_value end)

    Keyword.merge(runtime_config(), configured, fn key, runtime_value, app_value ->
      if key in @token_config_keys do
        if present?(runtime_value), do: runtime_value, else: app_value
      else
        if present?(app_value), do: app_value, else: runtime_value
      end
    end)
  end

  @doc """
  Check if the client has credentials for OAuth 2.0 or OAuth 1.0a.
  """
  def configured? do
    conf = config()

    oauth2_configured =
      present?(conf[:client_id]) and
        present?(conf[:client_secret]) and
        present?(conf[:access_token])

    oauth1_configured =
      present?(conf[:consumer_key]) and
        present?(conf[:consumer_secret]) and
        present?(conf[:access_token]) and
        present?(conf[:access_token_secret])

    oauth2_configured or oauth1_configured
  end

  @doc """
  Check if the client has credentials that can read/search public X posts.
  """
  def search_configured? do
    conf = config()
    present?(conf[:bearer_token]) or configured?()
  end

  @doc """
  Returns which auth method is being used.
  """
  def auth_method do
    conf = config()

    if present?(conf[:client_id]) do
      :oauth2
    else
      :oauth1
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp runtime_config do
    Enum.reduce(@env_config_keys, [], fn {key, env_var}, acc ->
      value = resolve_runtime_value(env_var)

      if present?(value) do
        Keyword.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp resolve_runtime_value(env_var) do
    if use_secrets_resolution?() do
      normalize_optional_string(fetch_secret_value(env_var))
    else
      normalize_optional_string(System.get_env(env_var))
    end
  end

  defp fetch_secret_value(env_var) when is_binary(env_var) do
    secrets_module =
      Application.get_env(
        :x_api,
        :secrets_module,
        Application.get_env(@legacy_app, :x_api_secrets_module, Secrets)
      )

    cond do
      function_exported?(secrets_module, :fetch_value, 2) ->
        secrets_module.fetch_value(env_var, [])

      function_exported?(secrets_module, :fetch_value, 1) ->
        secrets_module.fetch_value(env_var)

      function_exported?(secrets_module, :resolve, 2) ->
        case secrets_module.resolve(env_var, []) do
          {:ok, value, _source} -> value
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  rescue
    e ->
      Logger.warning("Failed to fetch secret #{env_var}: #{Exception.message(e)}")
      nil
  end

  defp use_secrets_resolution? do
    Application.get_env(
      :x_api,
      :use_secrets,
      Application.get_env(@legacy_app, :x_api_use_secrets, true)
    ) != false
  end

  defp normalize_app_config(config) when is_list(config), do: config
  defp normalize_app_config(config) when is_map(config), do: Enum.into(config, [])
  defp normalize_app_config(_), do: []

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value), do: value
end
