# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Lane concurrency caps for CodingAgent.LaneQueue
config :coding_agent, :lane_caps,
  main: 4,
  subagent: 8,
  background_exec: 2

# Persist LemonGateway state (including Telegram offsets) to disk.
config :lemon_gateway, LemonGateway.Store,
  backend: LemonGateway.Store.JsonlBackend,
  backend_opts: [path: Path.expand("~/.lemon/store")]

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
