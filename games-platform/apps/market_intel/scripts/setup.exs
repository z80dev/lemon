#!/usr/bin/env elixir

defmodule MarketIntel.Setup do
  @moduledoc """
  Setup script for MarketIntel.
  
  Run this after cloning to:
  1. Check environment variables
  2. Create database
  3. Run migrations
  4. Verify data directory exists
  """

  def run do
    IO.puts("🍋 MarketIntel Setup\n")
    IO.puts(String.duplicate("=", 50))
    
    # Step 1: Check env vars
    IO.puts("\n📋 Step 1: Checking Environment Variables")
    check_env_vars()
    
    # Step 2: Create data directory
    IO.puts("\n📁 Step 2: Creating Data Directory")
    create_data_dir()
    
    # Step 3: Instructions for next steps
    IO.puts("\n🚀 Next Steps:")
    IO.puts("""
    1. Ensure your X API credentials are set:
       export X_API_CLIENT_ID="..."
       export X_API_CLIENT_SECRET="..."
       export X_API_ACCESS_TOKEN="..."
       export X_API_REFRESH_TOKEN="..."
    
    2. (Optional) Get a BaseScan API key:
       https://basescan.org/apis
       export BASESCAN_API_KEY="..."
    
    3. Start the application:
       cd ~/dev/lemon
       mix deps.get
       mix ecto.create -r MarketIntel.Repo
       mix ecto.migrate -r MarketIntel.Repo
       iex -S mix
    
    4. Test the pipeline:
       MarketIntel.Commentary.Pipeline.generate_now()
    """)
    
    IO.puts("\n✅ Setup complete!")
  end
  
  defp check_env_vars do
    required = [
      "X_API_CLIENT_ID",
      "X_API_CLIENT_SECRET", 
      "X_API_ACCESS_TOKEN",
      "X_API_REFRESH_TOKEN"
    ]
    
    missing = Enum.filter(required, fn var ->
      is_nil(System.get_env(var)) or System.get_env(var) == ""
    end)
    
    if missing == [] do
      IO.puts("  ✅ All required X API variables set")
    else
      IO.puts("  ⚠️  Missing required variables:")
      Enum.each(missing, fn var ->
        IO.puts("     - #{var}")
      end)
      IO.puts("\n  Get your X API credentials at: https://developer.twitter.com")
    end
  end
  
  defp create_data_dir do
    data_dir = Path.expand("../../data", __DIR__)
    
    if File.exists?(data_dir) do
      IO.puts("  ✅ Data directory exists: #{data_dir}")
    else
      case File.mkdir_p(data_dir) do
        :ok ->
          IO.puts("  ✅ Created data directory: #{data_dir}")
        {:error, reason} ->
          IO.puts("  ❌ Failed to create data directory: #{inspect(reason)}")
      end
    end
  end
end

MarketIntel.Setup.run()
