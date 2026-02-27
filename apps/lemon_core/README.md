# LemonCore

Foundational shared library for the Lemon umbrella project. All other apps depend on `lemon_core` -- it provides configuration management, encrypted secrets, pluggable storage, an event bus, session routing primitives, idempotency, execution approvals, telemetry, and quality tooling.

This app has **zero dependencies on other umbrella apps** and must remain that way.

## Architecture Overview

```
                   +-----------------------+
                   |    LemonCore.Config   |  TOML parsing, env overrides,
                   |  .Modular / .Providers|  hot reload, validation
                   +-----------+-----------+
                               |
                   +-----------+-----------+
                   |  LemonCore.ConfigCache |  ETS cache with mtime-based
                   |  LemonCore.ConfigReloader| invalidation + FileSystem watcher
                   +-----------+-----------+
                               |
          +--------------------+--------------------+
          |                    |                    |
+---------+--------+ +--------+--------+ +---------+--------+
| LemonCore.Secrets| | LemonCore.Store | | LemonCore.Bus    |
| .Crypto          | | .EtsBackend     | | (Phoenix.PubSub) |
| .Keychain        | | .SqliteBackend  | |                  |
| .MasterKey       | | .JsonlBackend   | | LemonCore.Event  |
+------------------+ | .ReadCache      | +------------------+
                     +-----------------+
                               |
          +--------------------+--------------------+
          |                    |                    |
+---------+--------+ +--------+--------+ +---------+--------+
| LemonCore.       | | LemonCore.      | | LemonCore.       |
| Idempotency      | | ExecApprovals   | | Introspection    |
+------------------+ +-----------------+ +------------------+
          |
+---------+--------+
| LemonCore.       |
| RouterBridge     |  Runtime bridge to :lemon_router
| SessionKey       |  without compile-time coupling
| RunRequest       |
| InboundMessage   |
+------------------+
```

## Supervised Process Tree

`LemonCore.Application` starts these children under a `:one_for_one` supervisor:

| # | Child | Purpose |
|---|-------|---------|
| 1 | `Phoenix.PubSub` (name: `LemonCore.PubSub`) | PubSub backbone for the Bus |
| 2 | `LemonCore.ConfigCache` | ETS-backed config cache with TTL fingerprinting |
| 3 | `LemonCore.Store` | Key-value storage GenServer with pluggable backends |
| 4 | `LemonCore.ConfigReloader` | Reload orchestrator with diff computation |
| 5 | `LemonCore.ConfigReloader.Watcher` | FileSystem watcher for `config.toml` and `.env` |
| 6 | `LemonCore.Browser.LocalServer` | Local browser automation via Node/Playwright |

## Module Inventory

### Configuration

| Module | Purpose |
|--------|---------|
| `LemonCore.Config` | Canonical TOML config loader with global/project merge and env overrides |
| `LemonCore.Config.Modular` | Newer typed config interface delegating to per-domain sub-modules |
| `LemonCore.Config.Providers` | LLM provider config (API keys, base URLs, secret refs, OAuth) |
| `LemonCore.Config.Agent` | Agent behavior settings sub-module |
| `LemonCore.Config.Gateway` | Gateway settings sub-module |
| `LemonCore.Config.Tools` | Web tools and WASM config sub-module |
| `LemonCore.Config.TUI` | Terminal UI theme and debug sub-module |
| `LemonCore.Config.Logging` | Log file and rotation sub-module |
| `LemonCore.Config.Validator` | Validation for both legacy and modular config structs |
| `LemonCore.Config.ValidationError` | Raised by `Config.Modular.load!/1` on invalid config |
| `LemonCore.Config.Helpers` | Shared config parsing helpers |
| `LemonCore.Config.TomlPatch` | Textual TOML editing for targeted key upserts |
| `LemonCore.ConfigCache` | ETS cache with mtime/size fingerprint-based invalidation |
| `LemonCore.ConfigCacheError` | Raised when ConfigCache is unavailable |
| `LemonCore.ConfigReloader` | Central reload orchestrator with digest diffing and Bus broadcast |
| `LemonCore.ConfigReloader.Digest` | File/env/secrets digest computation |
| `LemonCore.ConfigReloader.Watcher` | FileSystem watcher targeting config.toml and .env paths |
| `LemonCore.GatewayConfig` | Unified gateway config access merging TOML, app env, and transport overrides |
| `LemonCore.Dotenv` | `.env` file loader preserving existing env vars |
| `LemonCore.Logging` | Runtime log-to-file handler from `[logging]` config |
| `LemonCore.LoggerSetup` | Logger configuration helpers |

### Secrets

| Module | Purpose |
|--------|---------|
| `LemonCore.Secrets` | Encrypted secrets API (get/set/list/delete/resolve with env fallback) |
| `LemonCore.Secrets.Crypto` | AES-256-GCM encryption with HKDF-SHA256 key derivation |
| `LemonCore.Secrets.Keychain` | macOS Keychain integration for master key storage |
| `LemonCore.Secrets.MasterKey` | Master key resolution chain (keychain -> env var) |

### Storage

| Module | Purpose |
|--------|---------|
| `LemonCore.Store` | GenServer with pluggable backends and specialized APIs |
| `LemonCore.Store.Backend` | Behaviour for storage backends (init/put/get/delete/list) |
| `LemonCore.Store.EtsBackend` | In-memory ETS backend (ephemeral, default) |
| `LemonCore.Store.SqliteBackend` | SQLite backend with WAL mode and optional ephemeral tables |
| `LemonCore.Store.JsonlBackend` | Append-only JSONL backend (human-readable, portable) |
| `LemonCore.Store.ReadCache` | Public ETS read-through cache for hot domains |

### Event System

| Module | Purpose |
|--------|---------|
| `LemonCore.Bus` | PubSub wrapper with topic helpers |
| `LemonCore.Event` | Canonical event struct (type, ts_ms, payload, meta) |
| `LemonCore.EventBridge` | Cross-app event translation |

### Routing and Sessions

| Module | Purpose |
|--------|---------|
| `LemonCore.SessionKey` | Session key generation and parsing |
| `LemonCore.RouterBridge` | Runtime bridge to `:lemon_router` without compile-time coupling |
| `LemonCore.RunRequest` | Canonical run submission struct |
| `LemonCore.InboundMessage` | Normalized inbound message from any channel |
| `LemonCore.Binding` | Struct mapping transport/chat/topic to project config |
| `LemonCore.BindingResolver` | Binding resolution logic |
| `LemonCore.ChatScope` | Chat scope struct |
| `LemonCore.ResumeToken` | Resume token for session continuity |

### Operations

| Module | Purpose |
|--------|---------|
| `LemonCore.Idempotency` | At-most-once deduplication backed by Store with 24h TTL |
| `LemonCore.ExecApprovals` | Tool execution approval flow with scope-based persistence |
| `LemonCore.Introspection` | Canonical introspection event builder and persistence |
| `LemonCore.Dedupe.Ets` | Low-level ETS-backed TTL deduplication |

### Utilities

| Module | Purpose |
|--------|---------|
| `LemonCore` | Root module with module list |
| `LemonCore.Id` | UUID and unique ID generation |
| `LemonCore.Clock` | Time utilities (monotonic timestamps) |
| `LemonCore.Httpc` | `:httpc` wrapper ensuring `:inets`/`:ssl` started |
| `LemonCore.MapHelpers` | Map key access helpers (atom/string agnostic) |
| `LemonCore.Telemetry` | Telemetry event helpers and named event emitters |
| `LemonCore.Reload` | Runtime BEAM/extension reload orchestration |
| `LemonCore.Testing` | Test harness builder (Harness, Case, Helpers) |
| `LemonCore.Browser.LocalServer` | Local browser automation via Playwright |

### Quality

| Module | Purpose |
|--------|---------|
| `LemonCore.Quality.Cleanup` | Data cleanup utilities |
| `LemonCore.Quality.DocsCatalog` | Documentation catalog checks |
| `LemonCore.Quality.DocsCheck` | Documentation completeness validation |
| `LemonCore.Quality.ArchitectureCheck` | Architecture boundary validation |

### Mix Tasks

| Task | Purpose |
|------|---------|
| `mix lemon.config` | Validate and show configuration |
| `mix lemon.secrets.init` | Generate master key |
| `mix lemon.secrets.status` | Show secrets status |
| `mix lemon.secrets.list` | List secrets metadata |
| `mix lemon.secrets.set` | Store a secret |
| `mix lemon.secrets.delete` | Delete a secret |
| `mix lemon.secrets.check` | Check secrets health |
| `mix lemon.secrets.import_env` | Import env vars as secrets |
| `mix lemon.onboard.anthropic` | Anthropic provider setup |
| `mix lemon.onboard.antigravity` | Antigravity (Google) provider setup with OAuth |
| `mix lemon.onboard.codex` | OpenAI Codex provider setup with OAuth |
| `mix lemon.onboard.copilot` | GitHub Copilot provider setup with OAuth |
| `mix lemon.quality` | Run all quality checks |
| `mix lemon.cleanup` | Clean up old data |
| `mix lemon.store.migrate_jsonl_to_sqlite` | Migrate JSONL to SQLite |
| `mix lemon.introspection` | Query introspection events |
| `mix lemon.check_duplicate_tests` | Check for duplicate test names |

## Configuration System

### Config Sources (precedence: env > project > global)

1. **Global**: `~/.lemon/config.toml`
2. **Project**: `<cwd>/.lemon/config.toml`
3. **Environment**: `LEMON_*` and provider-specific variables override both

### Config Sections

- `providers` -- LLM API keys and base URLs (anthropic, openai, openai-codex, opencode, kimi, google)
- `defaults` -- Preferred home for default provider/model/thinking level/engine
- `runtime` -- Runtime behavior (compaction, retry, shell, tools, cli, extensions, theme)
- `profiles` -- Per-agent profiles with tool policies
- `agent` -- Legacy alias for runtime/default settings (still supported)
- `agents` -- Legacy alias for profile settings (still supported)
- `tui` -- Theme, debug mode
- `logging` -- File logging, level, rotation
- `gateway` -- Max concurrent runs, engine bindings, Telegram/Discord/SMS/email settings

### Access Patterns

```elixir
# Cached read (default hot path) - uses ConfigCache when available
config = LemonCore.Config.load(cwd)

# Force reload from disk (updates cache)
config = LemonCore.Config.reload(cwd)

# Access nested values
provider = LemonCore.Config.get(config, [:agent, :default_provider], "anthropic")

# Modular config interface (typed sub-structs, validation)
config = LemonCore.Config.Modular.load(project_dir: cwd)
config = LemonCore.Config.Modular.load!(project_dir: cwd)
{:ok, config} = LemonCore.Config.Modular.load_with_validation(project_dir: cwd)
```

### Hot Reload Flow

```
LemonCore.ConfigReloader.reload/1
  |-- Acquire reload lock
  |-- Compute file/env/secrets digests
  |-- Compare with cached digests
  |-- Reload .env if changed
  |-- Reload TOML via LemonCore.Config.reload/2
  |-- Compute redacted diff vs previous snapshot
  |-- Update ConfigCache
  |-- Broadcast :config_reloaded on "system" topic
  |-- On failure: keep last good snapshot, emit :config_reload_failed
```

### Environment Variable Overrides

| Env Var | Overrides |
|---------|-----------|
| `LEMON_DEFAULT_PROVIDER` | `defaults.provider` |
| `LEMON_DEFAULT_MODEL` | `defaults.model` |
| `LEMON_DEBUG` | `tui.debug` |
| `LEMON_THEME` | `tui.theme` |
| `LEMON_LOG_FILE` | `logging.file` |
| `LEMON_LOG_LEVEL` | `logging.level` |
| `LEMON_CODEX_EXTRA_ARGS` | `runtime.cli.codex.extra_args` |
| `LEMON_CODEX_AUTO_APPROVE` | `runtime.cli.codex.auto_approve` |
| `LEMON_CLAUDE_YOLO` | `runtime.cli.claude.dangerously_skip_permissions` |
| `LEMON_WASM_ENABLED` | `runtime.tools.wasm.enabled` |
| `LEMON_WASM_RUNTIME_PATH` | `runtime.tools.wasm.runtime_path` |
| `LEMON_WASM_TOOL_PATHS` | `runtime.tools.wasm.tool_paths` |
| `LEMON_WASM_AUTO_BUILD` | `runtime.tools.wasm.auto_build` |
| `LEMON_BROWSER_DRIVER_PATH` | Path to local browser driver JS file |
| `ANTHROPIC_API_KEY` | `providers.anthropic.api_key` |
| `OPENAI_API_KEY` | `providers.openai.api_key` |
| `OPENAI_CODEX_API_KEY` | `providers.openai-codex.api_key` |
| `GOOGLE_GENERATIVE_AI_API_KEY` | `providers.google.api_key` |

## Secrets Management

### Storage Model

Secrets are encrypted at rest with AES-256-GCM. Per-secret encryption keys are derived via HKDF-SHA256 from a master key and a random 32-byte salt. The ciphertext, nonce, and salt are base64-encoded and stored in the `:secrets_v1` Store table.

### Master Key Resolution (in order)

1. macOS Keychain (`Lemon Secrets` service, `default` account) -- preferred
2. `LEMON_SECRETS_MASTER_KEY` environment variable -- fallback
3. Fail with `:missing_master_key`

### API

```elixir
# Store a secret
{:ok, metadata} = LemonCore.Secrets.set("api_key", "secret_value", provider: "manual")

# Retrieve a secret
{:ok, value} = LemonCore.Secrets.get("api_key")

# Resolve (store first, then env fallback)
{:ok, value, :store} = LemonCore.Secrets.resolve("api_key")
{:ok, value, :env} = LemonCore.Secrets.resolve("MISSING_FROM_STORE")

# Convenience (returns value or nil)
value = LemonCore.Secrets.fetch_value("ANTHROPIC_API_KEY")

# Check existence
exists? = LemonCore.Secrets.exists?("api_key")

# List (metadata only, no values)
{:ok, metadata_list} = LemonCore.Secrets.list()

# Delete
:ok = LemonCore.Secrets.delete("api_key")

# Status
status = LemonCore.Secrets.status()
```

Secrets automatically fall back to environment variables of the same name. Use `env_fallback: false` to disable. Secret reads update usage metadata (`usage_count`, `last_used_at`) without mutating `updated_at`.

## Storage Backends

### When to Use Each

| Backend | Persistence | Use Case |
|---------|-------------|----------|
| `EtsBackend` | No (in-memory) | Tests, ephemeral data, default |
| `SqliteBackend` | Yes (single file) | Production, WAL mode, optional ephemeral tables for high-churn |
| `JsonlBackend` | Yes (append-only files) | Debugging, data portability, human-readable |

### Configuration

```elixir
# config/config.exs
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.SqliteBackend,
  backend_opts: [path: "/var/lib/lemon/store.sqlite3"]
```

### Generic Table API

```elixir
:ok = LemonCore.Store.put(:my_table, key, value)
value = LemonCore.Store.get(:my_table, key)
:ok = LemonCore.Store.delete(:my_table, key)
items = LemonCore.Store.list(:my_table)
```

Store calls are fail-soft: if the GenServer is overloaded/unavailable, write APIs return `{:error, :store_unavailable}` and read/list APIs return `nil`/`[]`.

### Specialized APIs

The Store provides higher-level APIs for common domains:

- **Chat state**: `put_chat_state/2`, `get_chat_state/1`, `delete_chat_state/1` (24h TTL, auto-swept every 5 min)
- **Run history**: `append_run_event/2`, `finalize_run/2`, `get_run_history/2`, `get_run/1`
- **Policies**: `put_agent_policy/2`, `put_channel_policy/2`, `put_session_policy/2`, `put_runtime_policy/1`
- **Progress mapping**: `put_progress_mapping/3`, `get_run_by_progress/2`
- **Introspection**: `append_introspection_event/1`, `list_introspection_events/1`

### ReadCache

`LemonCore.Store.ReadCache` maintains public ETS tables for hot domains (`:chat`, `:runs`, `:progress`, `:sessions_index`, `:telegram_known_targets`). Reads bypass the GenServer entirely for O(1) ETS lookup, while writes go through the GenServer which updates both the backend and cache atomically.

### Backend Behaviour

Implementing a new backend requires the `LemonCore.Store.Backend` behaviour:

```elixir
@callback init(opts()) :: {:ok, state()} | {:error, term()}
@callback put(state(), table(), key(), value()) :: {:ok, state()}
@callback get(state(), table(), key()) :: {:ok, value() | nil, state()}
@callback delete(state(), table(), key()) :: {:ok, state()}
@callback list(state(), table()) :: {:ok, [{key(), value()}], state()}
```

Keys and values are serialized with `:erlang.term_to_binary/1` in the SQLite backend.

## Event Bus

### Standard Topics

| Topic | Purpose |
|-------|---------|
| `"run:<run_id>"` | Run-specific events |
| `"session:<session_key>"` | Session-scoped events |
| `"channels"` | Channel lifecycle |
| `"cron"` | Cron/automation events |
| `"exec_approvals"` | Approval requests/resolutions |
| `"nodes"` | Node pairing/invocation |
| `"system"` | Config reload, global events |
| `"logs"` | Log streaming |

### Usage

```elixir
# Subscribe
LemonCore.Bus.subscribe("run:" <> run_id)

# Receive
receive do
  %LemonCore.Event{type: :delta, payload: payload} -> handle_delta(payload)
  %LemonCore.Event{type: :completed, payload: payload} -> handle_completion(payload)
after
  30_000 -> :timeout
end

# Broadcast
event = LemonCore.Event.new(:run_started, %{engine: "lemon"}, %{run_id: run_id})
LemonCore.Bus.broadcast("session:" <> session_key, event)

# Unsubscribe
LemonCore.Bus.unsubscribe("run:" <> run_id)
```

## Session Keys

Session keys provide stable identifiers for routing and state management.

### Formats

- Main: `agent:<agent_id>:main[:sub:<sub_id>]`
- Channel: `agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>][:sub:<sub_id>]`

### Usage

```elixir
key = LemonCore.SessionKey.main("my_agent")
# => "agent:my_agent:main"

key = LemonCore.SessionKey.channel_peer(%{
  agent_id: "my_agent", channel_id: "telegram",
  account_id: "bot123", peer_kind: :dm, peer_id: "user456"
})

%{agent_id: id, kind: :main} = LemonCore.SessionKey.parse(key)
```

## Execution Approvals

Tool execution gating with scope-based persistence. Placed in `lemon_core` so any app can request/resolve approvals without depending on `:lemon_router`.

### Scopes

| Scope | Persistence |
|-------|-------------|
| `:approve_once` | Not persisted (single request) |
| `:approve_session` | Persisted per session_key |
| `:approve_agent` | Persisted per agent_id |
| `:approve_global` | Persisted globally |

```elixir
# Request (blocks until resolved)
case LemonCore.ExecApprovals.request(%{
  run_id: run_id, session_key: session_key,
  tool: "shell", action: %{command: "rm -rf /tmp/old"},
  expires_in_ms: 60_000
}) do
  {:ok, :approved, scope} -> proceed()
  {:ok, :denied} -> halt()
  {:error, :timeout} -> handle_timeout()
end

# Resolve (called by UI/admin)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_session)
```

## Idempotency

At-most-once deduplication backed by the Store with 24h TTL.

```elixir
result = LemonCore.Idempotency.execute("messages", msg_id, fn ->
  perform_operation()
end)
```

## Introspection

Canonical event persistence with redaction for tool arguments and sensitive fields.

```elixir
:ok = LemonCore.Introspection.record(:tool_completed,
  %{tool_name: "exec", result_preview: "ok"},
  run_id: run_id, session_key: session_key, engine: "codex"
)

events = LemonCore.Introspection.list(run_id: run_id, limit: 50)
```

## RouterBridge

Channel adapters forward runs to `:lemon_router` without compile-time coupling. The router registers itself at startup.

```elixir
{:ok, run_id} = LemonCore.RouterBridge.submit_run(run_request)
:ok = LemonCore.RouterBridge.handle_inbound(inbound_message)
:ok = LemonCore.RouterBridge.abort_session(session_key, :user_requested)
```

Returns `{:error, :unavailable}` when `:lemon_router` has not registered; callers must handle this gracefully.

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:lemon, :run, :submit]` | `%{count: 1}` | session_key, origin, engine |
| `[:lemon, :run, :start]` | `%{ts_ms: ...}` | run_id |
| `[:lemon, :run, :first_token]` | `%{latency_ms: ...}` | run_id |
| `[:lemon, :run, :stop]` | `%{duration_ms: ..., ok: bool}` | run_id |
| `[:lemon, :run, :exception]` | `%{}` | run_id, exception, stacktrace |
| `[:lemon, :channels, :inbound]` | `%{count: 1}` | channel_id |
| `[:lemon, :approvals, :requested]` | `%{count: 1}` | approval_id, tool |
| `[:lemon, :approvals, :resolved]` | `%{count: 1}` | approval_id, decision |
| `[:lemon, :cron, :tick]` | `%{job_count: ...}` | |
| `[:lemon, :config, :reload, :start/stop/exception]` | duration | reload_id, reason, sources |

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `jason` | JSON encoding/decoding |
| `toml` | TOML parsing |
| `uuid` | UUID generation |
| `phoenix_pubsub` | PubSub infrastructure for the Bus |
| `telemetry` | Metrics and instrumentation |
| `exqlite` | SQLite driver for SqliteBackend |
| `file_system` | File watching for config reload (optional) |

## Testing

```bash
# Run all lemon_core tests
mix test apps/lemon_core

# Run specific test file
mix test apps/lemon_core/test/lemon_core/config_test.exs

# Run with coverage
mix test --cover apps/lemon_core
```

### Test Harness

```elixir
defmodule MyTest do
  use LemonCore.Testing.Case, async: true

  test "example", %{harness: harness, tmp_dir: tmp_dir} do
    path = temp_file!(harness, "config.toml", "[agent]\ndefault_model = \"test\"")
    key = unique_session_key("mytest")
  end
end
```

Available helpers: `unique_token/0`, `unique_scope/0`, `unique_session_key/0`, `unique_run_id/0`, `temp_file!/3`, `temp_dir!/2`, `clear_store_table/1`, `mock_home!/1`, `random_master_key/0`.

## Important Notes

- Never add umbrella app dependencies to `lemon_core` -- it is the base layer
- Keep module interfaces stable -- other apps depend on them
- `Config.load/2` uses the cache by default; `Config.reload/2` forces a disk read
- Secret values are never logged or returned by list/status APIs
- Store backends serialize with `:erlang.term_to_binary/1`
- Events use millisecond timestamps from `System.system_time(:millisecond)`
- `RouterBridge` returns `{:error, :unavailable}` when `:lemon_router` has not registered
- `Dedupe.Ets` uses monotonic time for TTL; `Idempotency` uses wall-clock time
- `Config.Modular` is the newer typed approach; `Config` is still the primary interface
