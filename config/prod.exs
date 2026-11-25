import Config

config :lemon_core,
  build_git_sha: System.get_env("LEMON_GIT_SHA"),
  build_git_branch: System.get_env("LEMON_GIT_BRANCH")

# Persist Lemon state to disk in production.
#
# Set `LEMON_STORE_PATH` to control where state is written.
# It may be either a directory (store.sqlite3 is created inside)
# or a direct SQLite file path.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.SqliteBackend,
  backend_opts: [
    path: System.get_env("LEMON_STORE_PATH") || "/var/lib/lemon/store",
    ephemeral_tables: [:runs]
  ]

# The assistant runtime cannot run without these: lemon_core refuses to start
# in the runtime boot mode when one is unavailable (LemonCore.Capabilities).
config :lemon_core, :required_capabilities, [:durable_store, :run_history, :runtime_control]

config :lemon_automation,
  goal_judge_runner: LemonAutomation.GoalJudge.RouterRunner

config :lemon_web, LemonWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
