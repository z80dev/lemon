import Config

# Keep Logger defaults in tests: several test suites assert on `:info`/`:warning`
# messages via `ExUnit.CaptureLog`. If you need quieter output, prefer per-test
# `capture_log/2` or configure console formatting in CI.

# Isolate on-disk poller locks per `mix test` OS process. This prevents cross-process
# test interference if multiple `mix test` commands run concurrently on the same host.
System.put_env(
  "LEMON_LOCK_DIR",
  Path.join(
    System.tmp_dir!(),
    "lemon_locks_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
  )
)

# Tests must not depend on or mutate a developer's persistent state on disk.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []

# Tests mutate HOME/config files frequently; always re-stat config paths on each call.
config :lemon_core, LemonCore.ConfigCache, mtime_check_interval_ms: 0

# Avoid writing dets / sessions / global config under ~/.lemon/agent during tests.
config :coding_agent,
       :agent_dir,
       Path.join(
         System.tmp_dir!(),
         "lemon_agent_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
       )

# Avoid copying repo-bundled skills into user config during unrelated test suites.
config :lemon_skills, seed_builtin_skills: false

# Prevent unit tests from starting real/interactive transports based on a developer's
# local TOML config. Individual test suites can override these as needed and restart
# the application under test.
config :lemon_gateway, LemonGateway.Config,
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon",
  bindings: [],
  projects: %{}

config :lemon_gateway, :engines, [
  LemonGateway.Engines.Lemon,
  LemonGateway.Engines.Echo,
  LemonGateway.Engines.Codex,
  LemonGateway.Engines.Claude,
  LemonGateway.Engines.Opencode,
  LemonGateway.Engines.Pi
]

config :lemon_gateway, :telegram, nil

# Keep browser.request parity tests node-only; don't try to auto-fallback to the local driver in tests.
config :lemon_control_plane, :browser_local_fallback, false
