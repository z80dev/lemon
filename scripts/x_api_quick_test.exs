#!/usr/bin/env elixir
# Quick test for X API without starting the full application

Mix.install([:req])

client_id = System.get_env("X_API_CLIENT_ID")
client_secret = System.get_env("X_API_CLIENT_SECRET")
access_token = System.get_env("X_API_ACCESS_TOKEN")

IO.puts("🐦 X API Quick Test")
IO.puts("=" |> String.duplicate(50))

unless client_id && client_secret && access_token do
  IO.puts("""
  ❌ Missing credentials!

  Please set:
    export X_API_CLIENT_ID="..."
    export X_API_CLIENT_SECRET="..."
    export X_API_ACCESS_TOKEN="..."
  """)
  System.halt(1)
end

IO.puts("\n📋 Configuration:")
IO.puts("  Client ID: #{String.slice(client_id, 0, 20)}...")
IO.puts("  Access Token: #{String.slice(access_token, 0, 20)}...")

# Test: Get user info
IO.puts("\n👤 Testing user lookup:")

case Req.get("https://api.x.com/2/users/me",
  headers: [
    {"Authorization", "Bearer #{access_token}"}
  ]
) do
  {:ok, %{status: 200, body: body}} ->
    IO.puts("  ✅ Authenticated!")
    IO.puts("  Username: @#{body["data"]["username"]}")
    IO.puts("  Name: #{body["data"]["name"]}")
    IO.puts("  ID: #{body["data"]["id"]}")

  {:ok, %{status: 401, body: body}} ->
    IO.puts("  ❌ Authentication failed (401)")
    IO.puts("  Error: #{inspect(body)}")

  {:ok, %{status: status, body: body}} ->
    IO.puts("  ⚠️  HTTP #{status}")
    IO.puts("  Response: #{inspect(body)}")

  {:error, reason} ->
    IO.puts("  ❌ Request failed: #{inspect(reason)}")
end

# Test: Get mentions
IO.puts("\n📨 Testing mentions:")

case Req.get("https://api.x.com/2/users/me/mentions",
  headers: [
    {"Authorization", "Bearer #{access_token}"}
  ],
  params: [max_results: 5]
) do
  {:ok, %{status: 200, body: %{"data" => mentions}}} ->
    IO.puts("  ✅ Found #{length(mentions)} mentions")

  {:ok, %{status: 200, body: %{"meta" => %{"result_count" => 0}}}} ->
    IO.puts("  ✅ No recent mentions")

  {:ok, %{status: status, body: body}} ->
    IO.puts("  ⚠️  HTTP #{status}: #{inspect(body)}")

  {:error, reason} ->
    IO.puts("  ❌ Error: #{inspect(reason)}")
end

IO.puts("\n✅ Test complete!")
IO.puts("")
IO.puts("To post a tweet, add this to your environment and restart Lemon:")
IO.puts("  export X_API_CLIENT_ID=\"#{client_id}\"")
IO.puts("  export X_API_CLIENT_SECRET=\"#{client_secret}\"")
IO.puts("  export X_API_ACCESS_TOKEN=\"#{access_token}\"")
IO.puts("  export X_API_REFRESH_TOKEN=\"#{System.get_env("X_API_REFRESH_TOKEN")}\"")
