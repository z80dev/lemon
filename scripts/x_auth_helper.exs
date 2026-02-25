#!/usr/bin/env elixir
# X API Authentication Helper
#
# This script helps you get OAuth 2.0 tokens by opening the browser
# and providing an easy way to paste the code.
#
# Credentials are loaded from (in order of priority):
# 1. Lemon secrets store (via mix lemon.secrets.set X_API_CLIENT_ID ...)
# 2. Environment variables

Mix.install([:req])

# Start lemon_core to access secrets store
Mix.Task.run("loadpaths")
{:ok, _} = Application.ensure_all_started(:lemon_core)

defmodule XAuthHelper do
  def load_credential(name) do
    # Try secrets store first
    case LemonCore.Secrets.resolve(name, prefer_env: false) do
      {:ok, value, :store} -> value
      _ -> System.get_env(name)
    end
  end
end

client_id = XAuthHelper.load_credential("X_API_CLIENT_ID")
client_secret = XAuthHelper.load_credential("X_API_CLIENT_SECRET")
redirect_uri = System.get_env("X_API_REDIRECT_URI", "http://localhost:4000/auth/x/callback")
state_prefix = System.get_env("X_API_STATE_PREFIX", "lemon")
state = "#{state_prefix}_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
pkce = LemonChannels.Adapters.XAPI.OAuth.generate_pkce()

if is_nil(client_id) or is_nil(client_secret) do
  IO.puts("""
  ❌ Missing required credentials.

  Set these via secrets store (recommended):
    mix lemon.secrets.set X_API_CLIENT_ID "your-client-id"
    mix lemon.secrets.set X_API_CLIENT_SECRET "your-client-secret"

  Or via environment variables:
    export X_API_CLIENT_ID="your-client-id"
    export X_API_CLIENT_SECRET="your-client-secret"

  Optional:
    export X_API_REDIRECT_URI="http://localhost:4000/auth/x/callback"
    export X_API_STATE_PREFIX="lemon"
  """)

  System.halt(1)
end

auth_url =
  "https://twitter.com/i/oauth2/authorize?" <>
    URI.encode_query(%{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "scope" => "tweet.read tweet.write users.read offline.access",
      "state" => state,
      "code_challenge" => pkce.challenge,
      "code_challenge_method" => "S256"
    })

IO.puts("""
🐦 X API Authentication Helper
==================================================

1. Opening browser to authorize...

   If it doesn't open automatically, visit:
   #{auth_url}

2. After authorizing, you'll be redirected to localhost (error page is OK)

3. Paste the FULL callback URL here (or just the code):
""")

# Try to open browser
System.cmd("open", [auth_url])

# Read user input
url_or_code = IO.gets("URL/Code: ") |> String.trim()

# Extract code from URL if needed
code =
  cond do
    String.contains?(url_or_code, "code=") ->
      Regex.run(~r/code=([^&]+)/, url_or_code)
      |> case do
        [_, c] -> URI.decode_www_form(c)
        _ -> url_or_code
      end

    true ->
      url_or_code
  end

IO.puts("")
IO.puts("Using code: #{String.slice(code, 0, 30)}...")
IO.puts("")

# Exchange for tokens
body =
  URI.encode_query(%{
    "grant_type" => "authorization_code",
    "code" => code,
    "redirect_uri" => redirect_uri,
    "client_id" => client_id,
    "code_verifier" => pkce.verifier
  })

auth = Base.encode64("#{client_id}:#{client_secret}")

headers = [
  {"Content-Type", "application/x-www-form-urlencoded"},
  {"Authorization", "Basic #{auth}"}
]

case Req.post("https://api.x.com/2/oauth2/token", body: body, headers: headers) do
  {:ok, %{status: 200, body: response}} ->
    IO.puts("✅ SUCCESS! Save these tokens:")
    IO.puts("")
    IO.puts("export X_API_CLIENT_ID=\"#{client_id}\"")
    IO.puts("export X_API_CLIENT_SECRET=\"#{client_secret}\"")
    IO.puts("export X_API_ACCESS_TOKEN=\"#{response["access_token"]}\"")
    IO.puts("export X_API_REFRESH_TOKEN=\"#{response["refresh_token"]}\"")
    IO.puts("")
    IO.puts("Then run: mix run scripts/x_api_test.exs")

  {:ok, %{status: status, body: body}} ->
    IO.puts("❌ Error HTTP #{status}:")
    IO.inspect(body)

  {:error, reason} ->
    IO.puts("❌ Request failed:")
    IO.inspect(reason)
end
