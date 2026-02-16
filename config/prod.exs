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
