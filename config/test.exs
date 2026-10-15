import Config

# Keep Logger defaults in tests: several test suites assert on `:info`/`:warning`
# messages via `ExUnit.CaptureLog`. Every app's test_helper starts ExUnit with
# `capture_log: true`, so log output is only printed for failing tests.

# ExUnit's default `assert_receive` timeout is 100ms, shorter than scheduler
# latency on loaded CI runners. A bare `assert_receive` returns as soon as the
# message arrives, so the larger bound only lengthens genuine failures.
# `refute_receive` keeps its own default.
config :ex_unit, assert_receive_timeout: 1_000

# Isolate on-disk poller locks per `mix test` OS process. This prevents cross-process
# test interference if multiple `mix test` commands run concurrently on the same host.
System.put_env(
  "LEMON_LOCK_DIR",
  Path.join(
    System.tmp_dir!(),
    "lemon_locks_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
  )
)

# Tests must never read or write the developer's real ~/.lemon. LemonCore.Paths
# resolves config.toml, secrets and state from $HOME, and every umbrella app
# (including LemonCore's config load) boots before any test_helper runs, so a
# personal config could otherwise fail or skew the whole suite. Tests that need
# a specific home still set HOME themselves and restore this one afterwards.
lemon_test_home =
  Path.join(
    System.get_env("LEMON_TEST_TMPDIR") || System.tmp_dir!(),
    "lemon_home_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
  )

File.mkdir_p!(lemon_test_home)
System.put_env("HOME", lemon_test_home)

# Tests must not depend on or mutate a developer's persistent state on disk.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []

# Enable test-mode gateway config path (full-replacement via app env).
config :lemon_core, config_test_mode: true

# Tests opt into channel adapters explicitly.
config :lemon_channels, adapters: []

# The Honcho satellite reads the vendor's own `HONCHO_API_KEY` when no Lemon-side
# key is configured, which is a deliberate convenience in dev and prod — and a
# hazard here: a developer who exported that variable for some other Honcho
# client would otherwise have `mix test` register the memory provider and the
# context contributor and ship every prompt, answer and memory search of the
# suite into their real workspace. `enabled: false` wins over the exported key
# (the key only fills `:api_key`), so `configured?/1` stays false and nothing
# registers; `start_session_manager` keeps the supervised session manager out of
# the tree as well. Suites that exercise Honcho set these explicitly and restart
# the app.
config :lemon_honcho, enabled: false
config :lemon_honcho, start_session_manager: false

# ...and the switch above is not, by itself, enough. `LemonHoncho.Config`
# resolves OS environment *ahead of* application env, so `LEMON_HONCHO_ENABLED=true`
# exported in a developer's shell rc overrides `enabled: false` and switches the
# suite back on — measured: provider registered, contributor registered, and with
# `:client` unset every umbrella memory search fanning out to the live service.
# Configuration cannot close that hole with a flag the shell can win.
#
# Pinning the transport does close it. `:client` has no environment fallback, so
# whatever activates the integration, the module it reaches for is one that
# raises instead of opening a socket. See `LemonHoncho.Client.Tripwire`, which
# also explains why it lives in `lib/` rather than in a `test/support` file only
# one app's suite could load.
config :lemon_honcho, client: LemonHoncho.Client.Tripwire

# Tests mutate HOME/config files frequently; always re-stat config paths on each call.
config :lemon_core, LemonCore.ConfigCache, mtime_check_interval_ms: 0

# Avoid writing dets / sessions / global config under ~/.lemon/agent during tests.
config :coding_agent,
       :agent_dir,
       Path.join(
         System.tmp_dir!(),
         "lemon_agent_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
       )

# Avoid writing routing-feedback sqlite under ~/.lemon/store during tests.
# (The router test_helper overrides this with a per-run unique path.)
config :lemon_router, LemonRouter.RoutingFeedbackStore,
  path:
    Path.join(
      System.tmp_dir!(),
      "lemon_routing_feedback_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
    )

# Same for the two sqlite stores that fall back to LemonCore.Store's directory
# (`~/.lemon/store`) when unset. Without these, every `mix test` run appends to
# the developer's real run-history/memory databases; contention on a large one
# surfaces as :sqlite_busy and run-history assertion timeouts.
lemon_store_test_dir =
  Path.join(
    System.tmp_dir!(),
    "lemon_store_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
  )

config :lemon_core, LemonCore.RunHistoryStore, path: lemon_store_test_dir
config :lemon_memory, LemonMemory.Store, path: lemon_store_test_dir

# Avoid copying repo-bundled skills into user config during unrelated test suites.
config :lemon_skills, seed_builtin_skills: false
config :lemon_skills, :http_client, LemonSkills.HttpClient.Mock

# Never import MCP servers from the checkout's or developer's other-tool configs
# (`.mcp.json`, `~/.claude.json`, ...); discovery tests enable it explicitly.
config :lemon_skills, :mcp_external_discovery, false

# Background skill curation is tested explicitly; keep the runtime scheduler
# from submitting real agent runs during unrelated test suites.
config :lemon_automation, :skill_curator, enabled: false

# Scheduled skill synthesis is tested explicitly; keep the runtime scheduler
# from generating drafts (and touching the memory store) during unrelated suites.
config :lemon_automation, :synthesis_runner, enabled: false

# The daily brief job is reconciled from the developer's config.toml at boot;
# `LemonAutomation.HeartbeatTest` exercises the sync explicitly instead.
config :lemon_automation, daily_brief_sync: false

# The omp delegate must never launch a developer's real `omp` or read their
# `~/.omp`. `:executable` falls back to PATH when unset, so pin it to a path
# that cannot exist; suites that need a binary point it at
# `apps/lemon_omp/test/support/fake_omp` and restore it. `LEMON_OMP_*` exported
# in the shell outranks app env, so drop it for this VM. Short timeouts keep
# the failure paths fast.
config :lemon_omp,
  executable: Path.join(System.tmp_dir!(), "lemon_omp_test_no_such_dir/omp"),
  agent_dir:
    Path.join(
      System.tmp_dir!(),
      "lemon_omp_agent_test_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
    ),
  ready_timeout_ms: 5_000,
  command_timeout_ms: 2_000

Enum.each(
  ~w(LEMON_OMP_BIN LEMON_OMP_MAX_SESSIONS LEMON_OMP_IDLE_TIMEOUT_MS),
  &System.delete_env/1
)

# Computer use drives the real desktop. It stays off in tests regardless of a
# developer's exported opt-in; suites start their own server against a fake
# bridge.
config :lemon_computer_use, enabled: false

Enum.each(
  ~w(LEMON_COMPUTER_USE_ENABLED LEMON_COMPUTER_USE_CHROME LEMON_COMPUTER_USE_DECLINED_ORIGINS),
  &System.delete_env/1
)

# Prevent unit tests from starting real/interactive transports based on a developer's
# local TOML config. Individual test suites can override these as needed and restart
# the application under test.
config :lemon_gateway, LemonGateway.Config,
  enable_telegram: false,
  max_concurrent_runs: 1,
  bindings: [],
  projects: %{}

# Credentials the umbrella's transports read, scrubbed from the unit lane on
# top of LemonCore.Testing.HermeticEnv's built-in provider list. They live here
# rather than in the library: the platform an adapter talks to is the adapter's
# business, not lemon_core's.
config :lemon_core, :test_credential_env_vars, ~w(
  DISCORD_BOT_TOKEN
  TELEGRAM_BOT_TOKEN
  XMTP_WALLET_KEY
)

# Keep executor validation deterministic without introducing a test-only
# operator-selectable implementation. CodingAgent.Executor is loaded from the
# umbrella code path and is structurally valid even when coding_agent is not
# started by a particular suite.
config :lemon_gateway, :executor, CodingAgent.Executor

config :lemon_gateway, :telegram, nil

# ── lemon-sim product block — sim wiring outside apps/lemon_sim* (docs/platform-split.md) ──
config :lemon_sim_ui, LemonSimUi.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4092],
  secret_key_base:
    "test_sim_ui_secret_key_base_test_sim_ui_secret_key_base_test_sim_ui_secret_key_base",
  server: false

config :lemon_sim_ui, :hosted_rooms_enabled, true
config :lemon_sim_ui, :allow_insecure_admin, true
# ── end lemon-sim product block ──

config :lemon_web, LemonWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4082],
  secret_key_base:
    "test_secret_key_base_test_secret_key_base_test_secret_key_base_test_secret_key_base",
  server: false
