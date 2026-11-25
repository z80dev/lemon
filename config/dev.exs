import Config

# Persist Lemon state (including Telegram offsets) to disk in development.
# `LEMON_STORE_PATH` may be either a directory (store.sqlite3 is created inside)
# or a direct SQLite file path.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.SqliteBackend,
  backend_opts: [
    path: System.get_env("LEMON_STORE_PATH") || Path.expand("~/.lemon/store"),
    ephemeral_tables: [:runs]
  ]

config :lemon_automation,
  goal_judge_runner: LemonAutomation.GoalJudge.RouterRunner

# bin/lemon runs the daemon from this environment, so it gets the same endpoint
# posture as a release: no code reloader or debug error pages, the socket's own
# origin check, and a per-install secret from config/runtime.exs.
config :lemon_web, LemonWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("LEMON_WEB_PORT") || "4080")
  ]
