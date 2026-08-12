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

# In prod, the node model is preferred, but local fallback is still useful for single-box installs.
config :lemon_control_plane, :browser_local_fallback, true

config :lemon_automation,
  goal_judge_runner: LemonAutomation.GoalJudge.RouterRunner

config :lemon_web, LemonWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# ── lemon-sim product block — moves to the lemon-sim repo (docs/platform-split.md Phase 5) ──
config :lemon_sim_ui, LemonSimUi.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# ── end lemon-sim product block ──
