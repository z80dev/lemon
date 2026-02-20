#!/usr/bin/env elixir

defmodule MarketIntel.SecretsCLI do
  @moduledoc """
  CLI for managing MarketIntel secrets.
  
  Usage:
    elixir scripts/secrets.exs list              # List all configured secrets
    elixir scripts/secrets.exs get <name>        # Get a specific secret
    elixir scripts/secrets.exs set <name> <val>  # Set a secret
    elixir scripts/secrets.exs delete <name>     # Delete a secret
    elixir scripts/secrets.exs check             # Check which secrets are configured
  """
  
  @valid_secrets [
    "basescan_key",
    "dexscreener_key", 
    "openai_key",
    "anthropic_key"
  ]
  
  def main(args) do
    case args do
      ["list"] -> list_secrets()
      ["get", name] -> get_secret(name)
      ["set", name, value] -> set_secret(name, value)
      ["delete", name] -> delete_secret(name)
      ["check"] -> check_secrets()
      _ -> usage()
    end
  end
  
  defp list_secrets do
    IO.puts("🔐 MarketIntel Secrets\n")
    IO.puts(String.duplicate("=", 50))
    
    secrets = MarketIntel.Secrets.all_configured()
    
    if map_size(secrets) == 0 do
      IO.puts("\nNo secrets configured.")
      IO.puts("Use: elixir scripts/secrets.exs set <name> <value>")
    else
      IO.puts("\nConfigured secrets:")
      Enum.each(secrets, fn {key, value} ->
        IO.puts("  #{key}: #{value}")
      end)
    end
    
    IO.puts("\nAvailable secrets:")
    Enum.each(@valid_secrets, fn name ->
      status = if MarketIntel.Secrets.configured?(String.to_atom(name)), do: "✅", else: "❌"
      IO.puts("  #{status} #{name}")
    end)
  end
  
  defp get_secret(name) do
    atom_name = String.to_atom(name)
    
    case MarketIntel.Secrets.get(atom_name) do
      {:ok, value} ->
        IO.puts("#{name}: #{mask(value)}")
      {:error, _} ->
        IO.puts("❌ Secret '#{name}' not found")
        System.halt(1)
    end
  end
  
  defp set_secret(name, value) do
    unless name in @valid_secrets do
      IO.puts("❌ Invalid secret name: #{name}")
      IO.puts("Valid names: #{Enum.join(@valid_secrets, ", ")}")
      System.halt(1)
    end
    
    atom_name = String.to_atom(name)
    
    case MarketIntel.Secrets.put(atom_name, value) do
      :ok ->
        IO.puts("✅ Set #{name}")
      {:error, reason} ->
        IO.puts("❌ Failed to set #{name}: #{inspect(reason)}")
        System.halt(1)
    end
  end
  
  defp delete_secret(name) do
    # Note: Actual deletion would need to be implemented in Secrets module
    IO.puts("⚠️  Delete not yet implemented")
    IO.puts("To delete, manually edit the secrets store")
  end
  
  defp check_secrets do
    IO.puts("🔍 Checking MarketIntel Secrets\n")
    IO.puts(String.duplicate("=", 50))
    
    IO.puts("\nData Source APIs:")
    check_secret(:basescan_key, "BaseScan API (on-chain data)")
    check_secret(:dexscreener_key, "DEX Screener API (optional)")
    
    IO.puts("\nAI Generation:")
    check_secret(:openai_key, "OpenAI API")
    check_secret(:anthropic_key, "Anthropic API (alternative)")
    
    IO.puts("\nX API (from lemon_channels):")
    IO.puts("  ℹ️  X API keys are managed by lemon_channels")
    IO.puts("     Check: LemonChannels.Adapters.XAPI.configured?()")
    
    IO.puts("\n" <> String.duplicate("=", 50))
    
    any_ai = MarketIntel.Secrets.configured?(:openai_key) or 
             MarketIntel.Secrets.configured?(:anthropic_key)
    
    if any_ai do
      IO.puts("✅ AI commentary generation available")
    else
      IO.puts("⚠️  No AI provider configured (will use templates)")
    end
  end
  
  defp check_secret(name, description) do
    status = if MarketIntel.Secrets.configured?(name), do: "✅", else: "❌"
    IO.puts("  #{status} #{description}")
  end
  
  defp usage do
    IO.puts(@moduledoc)
  end
  
  defp mask(value) when is_binary(value) do
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

# Start the application to ensure secrets module is loaded
Application.ensure_all_started(:market_intel)

MarketIntel.SecretsCLI.main(System.argv())
