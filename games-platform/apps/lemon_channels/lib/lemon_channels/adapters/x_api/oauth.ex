defmodule LemonChannels.Adapters.XAPI.OAuth do
  @moduledoc """
  OAuth 2.0 helper for X API authentication.

  This module helps with the initial OAuth flow to obtain refresh tokens.
  After the initial setup, the TokenManager handles automatic refresh.

  ## OAuth 2.0 Flow

  1. Generate authorization URL
  2. User authorizes app in browser
  3. X redirects to callback with code
  4. Exchange code for access + refresh tokens
  5. Store refresh token for future use

  ## Required OAuth Settings in X Developer Portal

  - App permissions: Read and Write
  - Type of App: Web App, Automated App or Bot
  - Callback URI: Your callback endpoint (e.g., http://localhost:4000/auth/x/callback)
  - Website URL: Your website

  ## Scopes Needed

  - `tweet.read` - Read tweets
  - `tweet.write` - Post tweets
  - `users.read` - Read user info
  - `offline.access` - Get refresh token (REQUIRED for bots)
  """

  require Logger

  @oauth_authorize_url "https://twitter.com/i/oauth2/authorize"
  @oauth_token_url "https://api.x.com/2/oauth2/token"

  @scopes [
    "tweet.read",
    "tweet.write",
    "users.read",
    "offline.access"
  ]

  @doc """
  Generate the OAuth 2.0 authorization URL.

  ## Options
    - :redirect_uri - The callback URL (required)
    - :state - CSRF protection state (optional, recommended)
    - :code_challenge - PKCE code challenge (optional but recommended)

  ## Example

      iex> OAuth.authorization_url(redirect_uri: "http://localhost:4000/auth/x/callback")
      "https://twitter.com/i/oauth2/authorize?response_type=code&..."
  """
  def authorization_url(opts \\ []) do
    config = LemonChannels.Adapters.XAPI.config()
    client_id = config[:client_id]

    unless client_id do
      raise "X_API_CLIENT_ID not configured"
    end

    redirect_uri = opts[:redirect_uri] || raise "redirect_uri is required"
    state = opts[:state] || generate_state()
    code_challenge = opts[:code_challenge]

    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "scope" => Enum.join(@scopes, " "),
      "state" => state,
      "code_challenge_method" => "plain"
    }

    # Add PKCE if provided
    params = if code_challenge do
      Map.put(params, "code_challenge", code_challenge)
    else
      params
    end

    query = URI.encode_query(params)
    "#{@oauth_authorize_url}?#{query}"
  end

  @doc """
  Exchange authorization code for access and refresh tokens.

  ## Parameters
    - code: The authorization code from callback
    - redirect_uri: Must match the URI used in authorization_url
    - code_verifier: PKCE code verifier (if PKCE was used)

  ## Returns
    - {:ok, %{access_token: ..., refresh_token: ..., expires_in: ..., expires_at: ...}}
    - {:error, reason}
  """
  def exchange_code(code, redirect_uri, code_verifier \\ nil) do
    config = LemonChannels.Adapters.XAPI.config()

    body = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => config[:client_id]
    }

    body = if code_verifier do
      Map.put(body, "code_verifier", code_verifier)
    else
      body
    end

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Authorization", "Basic #{encode_credentials(config)}"}
    ]

    case Req.post(@oauth_token_url, body: URI.encode_query(body), headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        expires_in = response["expires_in"] || 7200
        expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

        {:ok, %{
          access_token: response["access_token"],
          refresh_token: response["refresh_token"],
          expires_in: expires_in,
          expires_at: expires_at,
          token_type: response["token_type"] || "Bearer",
          scope: response["scope"]
        }}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[XAPI OAuth] Token exchange failed: HTTP #{status} - #{inspect(body)}")
        {:error, {:token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a PKCE code challenge and verifier.

  Returns %{challenge: ..., verifier: ..., method: "S256"}
  """
  def generate_pkce do
    # Generate random verifier (43-128 chars)
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    # Generate challenge (SHA256 hash of verifier)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    %{
      verifier: verifier,
      challenge: challenge,
      method: "S256"
    }
  end

  @doc """
  Print setup instructions for manual OAuth flow.
  """
  def print_setup_instructions do
    config = LemonChannels.Adapters.XAPI.config()

    unless config[:client_id] do
    IO.puts("""
    ❌ X API Not Configured

    Please set the following environment variables:

      export X_API_CLIENT_ID="your-client-id"
      export X_API_CLIENT_SECRET="your-client-secret"

    Get these from https://developer.x.com → Projects → Your App → Keys and Tokens
    """)

    :error
    end

    pkce = generate_pkce()
    redirect_uri = "http://localhost:4000/auth/x/callback"

    auth_url = authorization_url(
      redirect_uri: redirect_uri,
      state: generate_state(),
      code_challenge: pkce.challenge
    )

    IO.puts("""
    🐦 X API OAuth Setup

    1. Visit this URL in your browser:

       #{auth_url}

    2. Authorize the app

    3. You'll be redirected to localhost (it will fail, that's OK)

    4. Copy the 'code' parameter from the URL

    5. Run in IEx:

       #{__MODULE__}.exchange_code("PASTE_CODE_HERE", "#{redirect_uri}", "#{pkce.verifier}")

    6. Save the refresh_token to your environment:

       export X_API_REFRESH_TOKEN="the-refresh-token"

    7. Restart the application
    """)

    :ok
  end

  ## Private Functions

  defp encode_credentials(config) do
    credentials = "#{config[:client_id]}:#{config[:client_secret]}"
    Base.encode64(credentials)
  end

  defp generate_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
