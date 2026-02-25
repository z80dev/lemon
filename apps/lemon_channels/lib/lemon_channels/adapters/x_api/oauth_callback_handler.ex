defmodule LemonChannels.Adapters.XAPI.OAuthCallbackHandler do
  @moduledoc """
  HTTP handler for OAuth 2.0 callback from X.

  This module provides a Plug-compatible handler that can be mounted
  in the gateway to receive OAuth callbacks and exchange codes for tokens.

  ## Setup

  1. Configure callback URL in X Developer Portal:
     http://your-gateway-host:port/auth/x/callback

  2. The handler will receive the code and exchange it for tokens

  3. Tokens are printed to logs (save them securely!)

  ## Routes

  GET /auth/x/callback - Receives OAuth callback from X
  GET /auth/x/start    - Initiates OAuth flow (redirects to X)
  """

  require Logger

  @doc """
  Handle OAuth callback from X.
  """
  def handle_callback(%{"code" => code, "state" => state_param}) do
    config = LemonChannels.Adapters.XAPI.config()

    # Look up PKCE verifier by state param
    verifier =
      case LemonChannels.Adapters.XAPI.TokenManager.consume_pkce_state(state_param) do
        {:ok, v} -> v
        {:error, :not_found} ->
          Logger.warning("[XAPI] No PKCE state found for OAuth callback; token exchange may fail")
          nil
      end

    unless verifier do
      Logger.error("[XAPI] Cannot complete OAuth callback: no PKCE verifier for state #{state_param}")
    end

    # Exchange code for tokens
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => get_callback_url(config),
        "client_id" => config[:client_id],
        "code_verifier" => verifier || "challenge"
      })

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Authorization",
       "Basic #{Base.encode64("#{config[:client_id]}:#{config[:client_secret]}")}"}
    ]

    case Req.post("https://api.x.com/2/oauth2/token", body: body, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        expires_at = DateTime.add(DateTime.utc_now(), response["expires_in"] || 7200, :second)

        tokens = %{
          access_token: response["access_token"],
          refresh_token: response["refresh_token"],
          expires_at: expires_at,
          scope: response["scope"]
        }

        persist_tokens(tokens)

        # Log token receipt (values are persisted to runtime config/env/secrets store)
        Logger.info("""
        🎉 X API OAuth 2.0 Tokens Received!

        Access Token: #{String.slice(tokens.access_token, 0, 20)}...
        Refresh Token: #{String.slice(tokens.refresh_token, 0, 20)}...
        Expires At: #{tokens.expires_at}
        Scope: #{tokens.scope}
        """)

        {:ok, tokens}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OAuth token exchange failed: HTTP #{status} - #{inspect(body)}")
        {:error, {:token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_callback(%{"error" => error, "error_description" => desc}) do
    Logger.error("OAuth error: #{error} - #{desc}")
    {:error, {:oauth_error, error, desc}}
  end

  def handle_callback(_params) do
    {:error, :invalid_callback}
  end

  @doc """
  Generate the authorization URL to start OAuth flow.
  """
  def authorization_url do
    config = LemonChannels.Adapters.XAPI.config()
    client_id = config[:client_id]

    unless client_id do
      raise "X_API_CLIENT_ID not configured"
    end

    callback_url = get_callback_url(config)
    state = generate_state()
    pkce = LemonChannels.Adapters.XAPI.OAuth.generate_pkce()
    :ok = LemonChannels.Adapters.XAPI.TokenManager.register_pkce_state(state, pkce.verifier)

    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => callback_url,
      "scope" => "tweet.read tweet.write users.read offline.access",
      "state" => state,
      "code_challenge" => pkce.challenge,
      "code_challenge_method" => "S256"
    }

    query = URI.encode_query(params)
    "https://twitter.com/i/oauth2/authorize?#{query}"
  end

  ## Private Functions

  defp get_callback_url(config) do
    config[:callback_url] || "http://localhost:4000/auth/x/callback"
  end

  defp generate_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp persist_tokens(%{access_token: _, refresh_token: _, expires_at: _} = tokens) do
    attrs = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      expires_at: tokens.expires_at
    }

    case Process.whereis(LemonChannels.Adapters.XAPI.TokenManager) do
      pid when is_pid(pid) ->
        case LemonChannels.Adapters.XAPI.TokenManager.update_tokens(attrs) do
          {:ok, _state} ->
            :ok

          {:error, reason} ->
            Logger.warning("[XAPI] Failed to persist OAuth callback tokens: #{inspect(reason)}")
        end

      _ ->
        :ok = LemonChannels.Adapters.XAPI.TokenManager.persist_tokens(attrs)
    end
  end
end
