#!/usr/bin/env elixir
# Test script for X API adapter
#
# Usage with OAuth 1.0a (API Keys):
#   export X_API_CONSUMER_KEY="your-consumer-key"
#   export X_API_CONSUMER_SECRET="your-consumer-secret"
#   export X_API_ACCESS_TOKEN="your-access-token"
#   export X_API_ACCESS_TOKEN_SECRET="your-access-token-secret"
#   mix run scripts/x_api_test.exs
#
# Usage with OAuth 2.0:
#   export X_API_CLIENT_ID="your-client-id"
#   export X_API_CLIENT_SECRET="your-client-secret"
#   export X_API_ACCESS_TOKEN="your-access-token"
#   export X_API_REFRESH_TOKEN="your-refresh-token"
#   mix run scripts/x_api_test.exs

alias LemonChannels.Adapters.XAPI

IO.puts("🐦 X API Adapter Test")
IO.puts("=" |> String.duplicate(50))

# Check configuration
config = XAPI.config()

IO.puts("\n📋 Configuration:")
IO.puts("  Consumer Key: #{if config[:consumer_key], do: "✅ set", else: "❌ missing"}")
IO.puts("  Consumer Secret: #{if config[:consumer_secret], do: "✅ set", else: "❌ missing"}")
IO.puts("  Access Token: #{if config[:access_token], do: "✅ set", else: "❌ missing"}")
IO.puts("  Access Token Secret: #{if config[:access_token_secret], do: "✅ set", else: "❌ missing"}")
IO.puts("  Client ID (OAuth2): #{if config[:client_id], do: "✅ set", else: "❌ not set (OK if using OAuth 1.0a)"}")
IO.puts("  Configured?: #{if XAPI.configured?(), do: "✅ yes", else: "❌ no"}")
IO.puts("  Auth Method: #{XAPI.auth_method()}")

unless XAPI.configured?() do
  IO.puts("\n❌ Not configured. Please set environment variables:")
  IO.puts("")
  IO.puts("  For OAuth 1.0a (API Keys):")
  IO.puts("    export X_API_CONSUMER_KEY='your-consumer-key'")
  IO.puts("    export X_API_CONSUMER_SECRET='your-consumer-secret'")
  IO.puts("    export X_API_ACCESS_TOKEN='your-access-token'")
  IO.puts("    export X_API_ACCESS_TOKEN_SECRET='your-access-token-secret'")
  IO.puts("")
  IO.puts("  For OAuth 2.0:")
  IO.puts("    export X_API_CLIENT_ID='your-client-id'")
  IO.puts("    export X_API_CLIENT_SECRET='your-client-secret'")
  IO.puts("    export X_API_ACCESS_TOKEN='your-access-token'")
  IO.puts("    export X_API_REFRESH_TOKEN='your-refresh-token'")
  System.halt(1)
end

# Test getting user info
IO.puts("\n👤 Testing user lookup:")
case XAPI.OAuth1Client.get_me() do
  {:ok, %{"data" => data}} ->
    IO.puts("  ✅ Authenticated as @#{data["username"]}")
    IO.puts("  Name: #{data["name"]}")
    IO.puts("  ID: #{data["id"]}")

  {:ok, %{status: status, body: body}} ->
    IO.puts("  ⚠️  HTTP #{status}: #{inspect(body)}")

  {:error, reason} ->
    IO.puts("  ❌ Error: #{inspect(reason)}")
end

# Test getting mentions
IO.puts("\n📨 Testing mentions lookup:")
case XAPI.OAuth1Client.get_mentions(limit: 5) do
  {:ok, %{"data" => mentions}} ->
    IO.puts("  ✅ Found #{length(mentions)} mentions")
    Enum.each(mentions, fn m ->
      IO.puts("    - @#{m["author_id"]}: #{String.slice(m["text"], 0, 50)}...")
    end)

  {:ok, %{"meta" => %{"result_count" => 0}}} ->
    IO.puts("  ✅ No recent mentions")

  {:ok, %{status: status, body: body}} ->
    IO.puts("  ⚠️  HTTP #{status}: #{inspect(body)}")

  {:error, reason} ->
    IO.puts("  ❌ Error: #{inspect(reason)}")
end

# Test posting a tweet (commented out by default)
# Uncomment to actually post:
#
# IO.puts("\n📝 Testing tweet post:")
# test_text = "Testing X API integration from zeebot on Lemon! 🤖🍋 #{System.system_time(:second)}"
# case XAPI.Client.post_text(test_text) do
#   {:ok, %{"data" => data}} ->
#     IO.puts("  ✅ Tweet posted!")
#     IO.puts("  Tweet ID: #{data["id"]}")
#     IO.puts("  Text: #{data["text"]}")
#
#   {:error, reason} ->
#     IO.puts("  ❌ Failed: #{inspect(reason)}")
# end

IO.puts("\n✅ Test complete!")
IO.puts("")
IO.puts("To post a tweet, uncomment the test section in scripts/x_api_test.exs")
