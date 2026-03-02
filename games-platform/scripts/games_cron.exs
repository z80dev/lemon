#!/usr/bin/env elixir

# Games Platform Cron Task
#
# This script connects to the running Lemon node and checks/runs the games platform.
# It can be run manually or via cron.
#
# Usage:
#   elixir scripts/games_cron.exs
#
# Environment:
#   LEMON_NODE    - The node name to connect to (default: lemon@chico)
#   LEMON_COOKIE  - The Erlang cookie for authentication (default: reads from ~/.erlang.cookie or uses lemon_gateway_dev_cookie)
#
# What it does:
#   1. Connects to the running Lemon BEAM node
#   2. Checks current match state
#   3. Runs the LobbySeeder to create/advance matches
#   4. Reports status

require Logger

# Configuration from environment or defaults
# Note: Short hostname is used for shortnames distributed Erlang
short_hostname = :inet.gethostname() |> elem(1) |> List.to_string() |> String.split(".") |> List.first()

node_name =
  System.get_env("LEMON_NODE", "lemon@#{short_hostname}")
  |> String.to_atom()

cookie =
  System.get_env("LEMON_COOKIE") ||
    # Default to the development cookie used by bin/lemon
    :lemon_gateway_dev_cookie

my_node = :"games_cron@#{short_hostname}"

IO.puts("""
========================================
Games Platform Cron Task
========================================
Node: #{node_name}
""")

# Start distributed Erlang
Node.start(my_node, :shortnames)
Node.set_cookie(node_name, cookie)

if Node.connect(node_name) do
  IO.puts("✓ Connected to #{node_name}")

  # Check if LobbySeeder is running
  children = :rpc.call(node_name, Supervisor, :which_children, [LemonGames.Supervisor])
  seeder_running = Enum.any?(children, fn {mod, _, _, _} -> mod == LemonGames.Bot.LobbySeeder end)

  IO.puts("✓ LobbySeeder running: #{seeder_running}")

  # Get match state
  matches =
    :rpc.call(node_name, LemonCore.Store, :list, [:game_matches])
    |> Enum.map(fn {_k, v} -> v end)

  total = length(matches)
  active = Enum.count(matches, fn m -> m["status"] == "active" end)
  finished = Enum.count(matches, fn m -> m["status"] == "finished" end)
  expired = Enum.count(matches, fn m -> m["status"] == "expired" end)

  house_matches = Enum.filter(matches, fn m -> m["created_by"] == "lemon_house" end)
  active_house = Enum.count(house_matches, fn m -> m["status"] == "active" end)

  IO.puts("""

Match Statistics:
  Total: #{total}
  Active: #{active}
  Finished: #{finished}
  Expired: #{expired}

House Matches:
  Total: #{length(house_matches)}
  Active: #{active_house}
""")

  # Show active matches
  if active > 0 do
    IO.puts("\nActive Matches:")
    matches
    |> Enum.filter(fn m -> m["status"] == "active" end)
    |> Enum.take(5)
    |> Enum.each(fn m ->
      game_type = m["game_type"]
      turn = m["turn_number"]
      next = m["next_player"]
      created_by = m["created_by"]
      IO.puts("  • #{game_type} | Turn #{turn} | Next: #{next} | By: #{created_by}")
    end)
  end

  # Run the lobby seeder once to ensure we have active games
  IO.puts("\nRunning LobbySeeder...")
  result = :rpc.call(node_name, LemonGames.Bot.LobbySeeder, :run_once, [[]])

  IO.puts("""

LobbySeeder Results:
  Created: #{result.created}
  Advanced: #{result.advanced}
  Active house matches: #{result.active_house}
""")

  # Check web endpoint
  endpoint_pid = :rpc.call(node_name, Process, :whereis, [LemonWeb.Endpoint])
  endpoint_running = is_pid(endpoint_pid) and :rpc.call(node_name, Process, :alive?, [endpoint_pid])

  IO.puts("Web Endpoint: #{if endpoint_running, do: "running", else: "not running"}")

  # Check if web is accessible
  case :gen_tcp.connect({127, 0, 0, 1}, 4080, [], 500) do
    {:ok, sock} ->
      :gen_tcp.close(sock)
      IO.puts("Web UI: http://localhost:4080/games ✓")

    {:error, _} ->
      IO.puts("Web UI: NOT accessible on port 4080")
      IO.puts("  To start: Ensure the endpoint is started with server: true")
  end

  IO.puts("""

========================================
Done!
========================================
  """)

else
  IO.puts("""
✗ Failed to connect to #{node_name}

The Lemon node may not be running. Start it with:
  cd ~/dev/lemon/games-platform && iex -S mix

Or if running via the bin/lemon script, check:
  ps aux | grep beam

To specify a different node or cookie:
  LEMON_NODE=lemon@myhost LEMON_COOKIE=mysecret elixir scripts/games_cron.exs
""")
  System.halt(1)
end
