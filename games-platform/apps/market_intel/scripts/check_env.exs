#!/usr/bin/env elixir

defmodule MarketIntel.EnvChecker do
  @moduledoc """
  Checks that all required environment variables are set for MarketIntel.
  """

  @required [
    {"X_API_CLIENT_ID", "X API OAuth 2.0 Client ID"},
    {"X_API_CLIENT_SECRET", "X API OAuth 2.0 Client Secret"},
    {"X_API_ACCESS_TOKEN", "X API OAuth 2.0 Access Token"},
    {"X_API_REFRESH_TOKEN", "X API OAuth 2.0 Refresh Token"}
  ]

  @optional [
    {"BASESCAN_API_KEY", "BaseScan API (for on-chain data)"},
    {"DEXSCREENER_API_KEY", "DEX Screener API (optional, free tier works)"},
    {"OPENAI_API_KEY", "OpenAI API (for AI-generated commentary)"}
  ]

  def run do
    IO.puts("🔍 Checking MarketIntel Environment Variables\n")

    # Check required
    IO.puts("📋 Required Variables:")
    missing_required = check_vars(@required, true)

    IO.puts("\n📋 Optional Variables:")
    check_vars(@optional, false)

    IO.puts("\n" <> String.duplicate("=", 50))

    if missing_required > 0 do
      IO.puts("❌ #{missing_required} required variables missing!")
      IO.puts("\nTo fix:")
      IO.puts("1. Copy .env.example to .env")
      IO.puts("2. Fill in your API keys")
      IO.puts("3. Source the file: source .env")
      System.halt(1)
    else
      IO.puts("✅ All required variables set!")
      IO.puts("🚀 MarketIntel is ready to run")
    end
  end

  defp check_vars(vars, required) do
    Enum.reduce(vars, 0, fn {name, description}, acc ->
      value = System.get_env(name)
      
      if value && value != "" && !String.starts_with?(value, "your_") do
        masked = mask_value(value)
        IO.puts("  ✅ #{name}")
        IO.puts("     #{description}: #{masked}")
        acc
      else
        status = if required, do: "❌", else: "⚪"
        IO.puts("  #{status} #{name} (not set)")
        IO.puts("     #{description}")
        if required, do: acc + 1, else: acc
      end
    end)
  end

  defp mask_value(value) when is_binary(value) do
    len = String.length(value)
    
    if len <= 8 do
      "***"
    else
      prefix = String.slice(value, 0, 4)
      suffix = String.slice(value, -4, 4)
      "#{prefix}...#{suffix}"
    end
  end
end

MarketIntel.EnvChecker.run()
