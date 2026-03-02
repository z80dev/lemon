#!/usr/bin/env elixir

# Games Platform Cron Task
# 
# This script runs the LobbySeeder to keep games active.
# It can be run manually or via cron.
#
# Usage:
#   mix run scripts/games_cron.exs
#   
# Or with explicit config:
#   AUTOPLAY_ENABLED=true AUTOPLAY_INTERVAL_MS=30000 mix run scripts/games_cron.exs

require Logger

# Configure autoplay from environment or use defaults
autoplay_config = [
  enabled: System.get_env("AUTOPLAY_ENABLED", "true") == "true",
  interval_ms: String.to_integer(System.get_env("AUTOPLAY_INTERVAL_MS", "30000")),
  max_active_matches: String.to_integer(System.get_env("AUTOPLAY_MAX_MATCHES", "5")),
  house_agent_id: System.get_env("AUTOPLAY_HOUSE_AGENT", "lemon_house"),
  game_types: String.split(System.get_env("AUTOPLAY_GAME_TYPES", "rock_paper_scissors,connect4,tic_tac_toe"), ",")
]

IO.puts("""
========================================
Games Platform Cron Task
========================================
Config:
  enabled: #{Keyword.get(autoplay_config, :enabled)}
  interval_ms: #{Keyword.get(autoplay_config, :interval_ms)}
  max_active_matches: #{Keyword.get(autoplay_config, :max_active_matches)}
  house_agent_id: #{Keyword.get(autoplay_config, :house_agent_id)}
  game_types: #{inspect(Keyword.get(autoplay_config, :game_types))}
""")

# Start required applications
{:ok, _} = Application.ensure_all_started(:lemon_core)
{:ok, _} = Application.ensure_all_started(:lemon_games)

# Check current match state
matches = 
  :game_matches
  |> LemonCore.Store.list()
  |> Enum.map(fn {_k, v} -> v end)

active_matches = Enum.filter(matches, fn m -> m["status"] == "active" end)
house_matches = Enum.filter(active_matches, fn m -> m["created_by"] == "lemon_house" end)

IO.puts("""
Current State:
  Total matches: #{length(matches)}
  Active matches: #{length(active_matches)}
  House matches: #{length(house_matches)}
""")

# Run the lobby seeder once
if Keyword.get(autoplay_config, :enabled) do
  IO.puts("Running LobbySeeder...")
  
  result = LemonGames.Bot.LobbySeeder.run_once(autoplay_config)
  
  IO.puts("""

Results:
  Created: #{result.created}
  Advanced: #{result.advanced}
  Active house matches: #{result.active_house}

========================================
Done!
========================================
  """)
else
  IO.puts("Autoplay is disabled. Set AUTOPLAY_ENABLED=true to run.")
end
