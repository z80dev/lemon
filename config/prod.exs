import Config

# Persist Lemon state to disk in production.
#
# Set `LEMON_STORE_PATH` to control where state is written.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.JsonlBackend,
  backend_opts: [path: System.get_env("LEMON_STORE_PATH") || "/var/lib/lemon/store"]

# In prod, the node model is preferred, but local fallback is still useful for single-box installs.
config :lemon_control_plane, :browser_local_fallback, true
