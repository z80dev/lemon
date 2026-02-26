#!/usr/bin/env elixir
# X API OAuth 2.0 Token Exchange
#
# Usage: elixir scripts/x_oauth_exchange.exs <CODE>
#
# Example:
#   elixir scripts/x_oauth_exchange.exs "dmZ3YV9qUEsxMWVYZHNaVTVldWxvckVEejI0aW03MjB1cnQ3OXhCeEJGZlVLOjE3NzE1MTc1OTA5MjI6MToxOmFjOjE"

client_id = "RHozTWdxcjZoQ3E0em5JU0xYQTI6MTpjaQ"
client_secret = "IxhBE1Ssz5ADc9aPEL_j4i5BrNCBF5IufWjy5Mz_sNKb7_siku"
redirect_uri = "http://localhost:4000/auth/x/callback"

code = case System.argv() do
  [c] -> c
  _ ->
    IO.puts("Usage: elixir scripts/x_oauth_exchange.exs <CODE>")
    IO.puts("")
    IO.puts("Get the code from the URL after authorizing:")
    IO.puts("  http://localhost:4000/auth/x/callback?state=...&code=THIS_PART")
    System.halt(1)
end

IO.puts("🐦 Exchanging authorization code for tokens...")
IO.puts("")

# Build the request
body = URI.encode_query(%{
  "grant_type" => "authorization_code",
  "code" => code,
  "redirect_uri" => redirect_uri,
  "client_id" => client_id,
  "code_verifier" => "challenge"
})

auth = Base.encode64("#{client_id}:#{client_secret}")

headers = [
  {"Content-Type", "application/x-www-form-urlencoded"},
  {"Authorization", "Basic #{auth}"}
]

case Req.post("https://api.x.com/2/oauth2/token", body: body, headers: headers) do
  {:ok, %{status: 200, body: response}} ->
    IO.puts("✅ Success! Tokens received:")
    IO.puts("")
    IO.puts("Access Token:")
    IO.puts("  #{response["access_token"]}")
    IO.puts("")
    IO.puts("Refresh Token (SAVE THIS!):")
    IO.puts("  #{response["refresh_token"]}")
    IO.puts("")
    IO.puts("Expires In: #{response["expires_in"]} seconds")
    IO.puts("Scope: #{response["scope"]}")
    IO.puts("")
    IO.puts("Add these to your environment:")
    IO.puts("")
    IO.puts("export X_API_CLIENT_ID=\"#{client_id}\"")
    IO.puts("export X_API_CLIENT_SECRET=\"#{client_secret}\"")
    IO.puts("export X_API_ACCESS_TOKEN=\"#{response["access_token"]}\"")
    IO.puts("export X_API_REFRESH_TOKEN=\"#{response["refresh_token"]}\"")

  {:ok, %{status: status, body: body}} ->
    IO.puts("❌ Error HTTP #{status}:")
    IO.puts("  #{inspect(body)}")

  {:error, reason} ->
    IO.puts("❌ Request failed: #{inspect(reason)}")
end
