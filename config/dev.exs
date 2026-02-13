import Config

# Persist Lemon state (including Telegram offsets) to disk in development.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.JsonlBackend,
  backend_opts: [path: System.get_env("LEMON_STORE_PATH") || Path.expand("~/.lemon/store")]

# In dev, if no browser node is paired/online, allow browser.request to use the local driver.
config :lemon_control_plane, :browser_local_fallback, true
