defmodule LemonChannels.Adapters.XAPI do
  @moduledoc """
  X (Twitter) API v2 adapter for posting tweets.

  Uses OAuth 2.0 authentication with refresh token support for
  automated bot posting. Implements pay-per-use API pricing model.

  ## Configuration

  Can be configured either in `config/runtime.exs` or directly via
  `X_API_*` environment variables:

      config :lemon_channels, LemonChannels.Adapters.XAPI,
        client_id: System.get_env("X_API_CLIENT_ID"),
        client_secret: System.get_env("X_API_CLIENT_SECRET"),
        bearer_token: System.get_env("X_API_BEARER_TOKEN"),
        access_token: System.get_env("X_API_ACCESS_TOKEN"),
        refresh_token: System.get_env("X_API_REFRESH_TOKEN"),
        token_expires_at: System.get_env("X_API_TOKEN_EXPIRES_AT"),
        default_account_id: System.get_env("X_DEFAULT_ACCOUNT_ID"),
        default_account_username: System.get_env("X_DEFAULT_ACCOUNT_USERNAME")

  ## Usage

      payload = LemonChannels.OutboundPayload.text(
        "x_api",
        "your_bot_account",
        %{kind: :channel, id: "public", thread_id: nil},
        "Hello from Lemon!"
      )
      LemonChannels.Adapters.XAPI.deliver(payload)

  ## Rate Limits

  - 2,400 tweets per day (resets every 24 hours)
  - Pay-per-use pricing: credits deducted per request
  - Deduplication: 24h window for same resource requests

  ## References

  - https://docs.x.com/x-api/introduction
  - https://docs.x.com/x-api/getting-started/pricing
  """

  @behaviour LemonChannels.Plugin

  require Logger

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

  # API base URLs
  # @api_base "https://api.x.com/2"
  # @oauth_base "https://api.x.com/2/oauth2"

  @impl true
  def id, do: "x_api"

  @impl true
  def meta do
    %{
      label: "X (Twitter) API",
      capabilities: %{
        edit_support: true,
        delete_support: true,
        chunk_limit: 280,
        # per day
        rate_limit: 2400,
        voice_support: false,
        image_support: true,
        file_support: false,
        reaction_support: false,
        thread_support: true
      },
      docs: "https://docs.x.com/x-api"
    }
  end

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__.TokenManager, :start_link, [opts]},
      type: :worker
    }
  end

  @impl true
  def normalize_inbound(_raw) do
    # X API is primarily outbound for our use case
    # Webhook handling would be implemented here for mentions/DMs
    {:error, :not_implemented}
  end

  @impl true
  def deliver(%LemonChannels.OutboundPayload{} = payload) do
    __MODULE__.Client.deliver(payload)
  end

  @impl true
  def gateway_methods do
    [
      %{
        name: "x_api.post_tweet",
        scopes: [:agent],
        handler: __MODULE__.GatewayMethods
      },
      %{
        name: "x_api.get_mentions",
        scopes: [:agent],
        handler: __MODULE__.GatewayMethods
      },
      %{
        name: "x_api.reply_to_tweet",
        scopes: [:agent],
        handler: __MODULE__.GatewayMethods
      }
    ]
  end

  @doc """
  Get the current configuration.
  """
  def config do
    app_config =
      :lemon_channels
      |> Application.get_env(__MODULE__, [])
      |> normalize_app_config()

    Keyword.merge(runtime_config(), app_config, fn key, runtime_value, app_value ->
      if key in @token_config_keys do
        if present?(runtime_value), do: runtime_value, else: app_value
      else
        if present?(app_value), do: app_value, else: runtime_value
      end
    end)
  end

  @doc """
  Check if the adapter is properly configured.

  Supports both OAuth 2.0 and OAuth 1.0a authentication.
  """
  def configured? do
    conf = config()

    # OAuth 2.0 check
    oauth2_configured =
      present?(conf[:client_id]) and
        present?(conf[:client_secret]) and
        present?(conf[:access_token])

    # OAuth 1.0a check (simpler, uses API keys directly)
    oauth1_configured =
      present?(conf[:consumer_key]) and
        present?(conf[:consumer_secret]) and
        present?(conf[:access_token]) and
        present?(conf[:access_token_secret])

    oauth2_configured or oauth1_configured
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
    resolve_from_secret_store(env_var) || normalize_optional_string(System.get_env(env_var))
  end

  defp resolve_from_secret_store(name) do
    if use_secrets_resolution?() do
      module = secrets_module()

      if is_atom(module) and Code.ensure_loaded?(module) and
           function_exported?(module, :resolve, 2) do
        case module.resolve(name, prefer_env: false, env_fallback: false) do
          {:ok, value, :store} -> normalize_optional_string(value)
          _ -> nil
        end
      else
        nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp use_secrets_resolution? do
    Application.get_env(:lemon_channels, :x_api_use_secrets, true) != false
  end

  defp secrets_module do
    Application.get_env(:lemon_channels, :x_api_secrets_module, LemonCore.Secrets)
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
