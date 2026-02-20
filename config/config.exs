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

config :phoenix, :json_library, Jason

# Lane concurrency caps for CodingAgent.LaneQueue
config :coding_agent, :lane_caps,
  main: 4,
  subagent: 8,
  background_exec: 2

# Default to an in-memory store. Dev/prod override to disk-backed persistence.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []

config :lemon_web, LemonWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: LemonWeb.ErrorHTML, json: LemonWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LemonCore.PubSub,
  live_view: [signing_salt: "lemonwebsigningsalt"]

config :lemon_web, :access_token, nil
config :lemon_web, :uploads_dir, Path.join(System.tmp_dir!(), "lemon_web_uploads")

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

import_config "#{config_env()}.exs"
