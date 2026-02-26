import Config

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

config :lemon_web, LemonWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Enable autoplay for games platform - bots will automatically create and play matches
config :lemon_games, :autoplay,
  enabled: true,
  # Check every 30 seconds if we need more matches
  interval_ms: 30_000,
  # Target number of active matches to maintain
  target_active_matches: 5,
  # Max concurrent matches to prevent overload
  max_concurrent_matches: 10
