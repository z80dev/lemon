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

# In dev, if no browser node is paired/online, allow browser.request to use the local driver.
config :lemon_control_plane, :browser_local_fallback, true
