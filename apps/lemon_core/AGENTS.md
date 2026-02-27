# lemon_core - Foundational Shared Library

This is the **base app** of the Lemon umbrella. All other apps depend on it. It contains cross-cutting concerns that must be stable and dependency-free (within the umbrella).

## Purpose and Responsibilities

- **Configuration management** - TOML-based config loading, caching, validation, and hot reloading
- **Secrets management** - Encrypted storage with AES-256-GCM, keychain integration
- **Storage backends** - Pluggable storage (ETS, SQLite, JSONL) for state persistence
- **Event bus** - Process-safe PubSub via Phoenix.PubSub for cross-app communication
- **Session key management** - Canonical session key formats for routing
- **Idempotency** - Deduplication for at-most-once operations
- **Execution approvals** - Tool execution gating with scope-based persistence
- **Quality checks** - Docs catalog and architecture boundary validation
- **Telemetry** - Consistent event emission across the umbrella
- **HTTP client** - Thin wrapper around Erlang's `:httpc`

## Key Module Reference

| Module | Purpose |
|--------|---------|
| `LemonCore` | Main module with module list |
| `LemonCore.Config` | TOML config loading from `~/.lemon/config.toml` and project `.lemon/config.toml` |
| `LemonCore.Config.Modular` | Alternative modular config loader with typed sub-structs per section |
| `LemonCore.ConfigCache` | ETS-backed config cache with mtime-based invalidation |
| `LemonCore.ConfigReloader` | Hot reload orchestrator with diff computation and Bus broadcast |
| `LemonCore.ConfigReloader.Watcher` | FileSystem watcher that targets `config.toml`/`.env` paths (file-first, parent-dir fallback) and triggers reload only for those files |
| `LemonCore.Secrets` | Encrypted secrets API (get/set/list/delete) |
| `LemonCore.Secrets.Crypto` | AES-256-GCM encryption with HKDF key derivation |
| `LemonCore.Secrets.Keychain` | macOS keychain integration for master key storage |
| `LemonCore.Secrets.MasterKey` | Master key resolution (keychain first, then env var) |
| `LemonCore.Store` | Storage GenServer with pluggable backends |
| `LemonCore.Store.ReadCache` | ETS read cache for hot domains (`:chat`, `:runs`, `:progress`, `:sessions_index`, `:telegram_known_targets`) |
| `LemonCore.Store.EtsBackend` | In-memory ETS (ephemeral, default) |
| `LemonCore.Store.SqliteBackend` | SQLite with WAL mode (persistent) |
| `LemonCore.Store.JsonlBackend` | Append-only JSONL (portable, human-readable) |
| `LemonCore.Bus` | PubSub wrapper with topic helpers |
| `LemonCore.Event` | Canonical event struct for Bus and persistence |
| `LemonCore.EventBridge` | Cross-app event translation |
| `LemonCore.InboundMessage` | Normalized inbound message from any channel (Telegram, SMS, etc.) |
| `LemonCore.RunRequest` | Canonical run submission struct used by router-facing callers |
| `LemonCore.RouterBridge` | Runtime bridge to `:lemon_router` without compile-time coupling |
| `LemonCore.SessionKey` | Session key generation and parsing |
| `LemonCore.Idempotency` | At-most-once deduplication backed by `LemonCore.Store` with 24h TTL |
| `LemonCore.Dedupe.Ets` | Low-level ETS-backed TTL deduplication (`:seen?`, `:check_and_mark`) |
| `LemonCore.ExecApprovals` | Tool execution approval flow with scope-based persistence |
| `LemonCore.Telemetry` | Telemetry event helpers |
| `LemonCore.Introspection` | Canonical introspection envelope builder and persistence API |
| `Lemon.Reload` | Runtime BEAM/extension reload orchestration with global lock and telemetry |
| `LemonCore.Httpc` | `:httpc` wrapper ensuring `:inets`/`:ssl` started |
| `LemonCore.Clock` | Time utilities (monotonic timestamps) |
| `LemonCore.Id` | UUID and unique ID generation |
| `LemonCore.Dotenv` | `.env` file loader; preserves existing env vars by default |
| `LemonCore.Logging` | Runtime log-to-file handler setup from `[logging]` config |
| `LemonCore.GatewayConfig` | Unified gateway config access merging TOML, app env, and per-transport overrides |
| `LemonCore.Config.TomlPatch` | Textual TOML editing for targeted key upserts without a TOML encoder |
| `LemonCore.Binding` | Struct mapping transport/chat/topic to project/agent/engine |
| `LemonCore.BindingResolver` | Resolves bindings for inbound messages |
| `LemonCore.Browser.LocalServer` | Local browser automation via Node/Playwright (line-delimited JSON protocol) |
| `LemonCore.Testing` | Test harness builder (`Harness`, `Case`, `Helpers`) for lemon_core tests |

## Configuration System Architecture

### Config Sources (precedence: env > project > global)

1. **Global**: `~/.lemon/config.toml`
2. **Project**: `<cwd>/.lemon/config.toml`
3. **Environment**: `LEMON_*` variables override both

### Hot Reload Flow

```
LemonCore.ConfigReloader.reload/1
  ├─ Compute file digests (mtime/size)
  ├─ Compare with cached digests
  ├─ Reload .env if changed
  ├─ Reload TOML via LemonCore.Config.reload/2
  ├─ Compute redacted diff
  ├─ Update ConfigCache
  └─ Broadcast :config_reloaded on "system" topic
```

### Access Patterns

```elixir
# Cached read (default, hot path) - delegates to ConfigCache when available
config = LemonCore.Config.load(cwd)

# Force reload from disk (also updates cache)
config = LemonCore.Config.reload(cwd)

# Access nested values
provider = LemonCore.Config.get(config, [:agent, :default_provider], "anthropic")

# Modular config interface (typed sub-structs, validation support)
config = LemonCore.Config.Modular.load(project_dir: cwd)
config = LemonCore.Config.Modular.load!(project_dir: cwd)  # raises on invalid
{:ok, config} = LemonCore.Config.Modular.load_with_validation(project_dir: cwd)
```

### Config Sections

- `providers` - LLM API keys and base URLs (anthropic, openai, openai-codex, opencode, kimi, google). `openai-codex` requires `auth_source` (`oauth` or `api_key`); `anthropic` uses API key inputs (`api_key` / `api_key_secret` / `ANTHROPIC_API_KEY`).
- `defaults` - Preferred home for default provider/model/thinking level/engine
- `runtime` - Preferred home for runtime behavior (compaction, retry, shell, tools, cli, extensions, theme)
- `profiles` - Preferred home for per-agent profiles with tool policies
- `agent` - Legacy alias for runtime/default settings (still supported)
- `agents` - Legacy alias for profile settings (still supported)
- `tui` - Theme, debug mode
- `logging` - File logging, level, rotation
- `gateway` - Max concurrent runs, engine bindings, Telegram settings, SMS, queue, projects

### Environment Variable Overrides

| Env Var | Overrides |
|---------|-----------|
| `LEMON_DEFAULT_PROVIDER` | `defaults.provider` (legacy: `agent.default_provider`) |
| `LEMON_DEFAULT_MODEL` | `defaults.model` (legacy: `agent.default_model`) |
| `LEMON_DEBUG` | `tui.debug` |
| `LEMON_THEME` | `tui.theme` |
| `LEMON_LOG_FILE` | `logging.file` |
| `LEMON_LOG_LEVEL` | `logging.level` |
| `LEMON_CODEX_EXTRA_ARGS` | `runtime.cli.codex.extra_args` (legacy: `agent.cli.codex.extra_args`) |
| `LEMON_CODEX_AUTO_APPROVE` | `runtime.cli.codex.auto_approve` (legacy: `agent.cli.codex.auto_approve`) |
| `LEMON_CLAUDE_YOLO` | `runtime.cli.claude.dangerously_skip_permissions` (legacy: `agent.cli.claude.dangerously_skip_permissions`) |
| `LEMON_WASM_ENABLED` | `runtime.tools.wasm.enabled` (legacy: `agent.tools.wasm.enabled`) |
| `LEMON_WASM_RUNTIME_PATH` | `runtime.tools.wasm.runtime_path` (legacy: `agent.tools.wasm.runtime_path`) |
| `LEMON_WASM_TOOL_PATHS` | `runtime.tools.wasm.tool_paths` (legacy: `agent.tools.wasm.tool_paths`) |
| `LEMON_WASM_AUTO_BUILD` | `runtime.tools.wasm.auto_build` (legacy: `agent.tools.wasm.auto_build`) |
| `LEMON_BROWSER_DRIVER_PATH` | Path to local browser driver JS file |
| `ANTHROPIC_API_KEY` | `providers.anthropic.api_key` |
| `OPENAI_API_KEY` | `providers.openai.api_key` |
| `OPENAI_CODEX_API_KEY` | `providers.openai-codex.api_key` (used when `providers.openai-codex.auth_source = "api_key"`) |
| `GOOGLE_GENERATIVE_AI_API_KEY` | `providers.google.api_key` |

## Secrets Management Flow

### Storage Model

Secrets are encrypted at rest with AES-256-GCM. The encryption key is derived via HKDF-SHA256 from a master key plus per-secret random salt.

### Master Key Resolution (in order)

1. macOS Keychain (preferred; tried first)
2. `LEMON_SECRETS_MASTER_KEY` env var (fallback)
3. Fail with `:missing_master_key`

For a path-by-path audit matrix (including error and fallback semantics), see `docs/security/secrets-keychain-audit-matrix.md`.

### API Usage

```elixir
# Store a secret
{:ok, metadata} = LemonCore.Secrets.set("api_key", "secret_value", provider: "manual")

# Retrieve a secret
{:ok, value} = LemonCore.Secrets.get("api_key")

# Check existence
exists? = LemonCore.Secrets.exists?("api_key")

# List secrets (metadata only, no values)
{:ok, metadata_list} = LemonCore.Secrets.list()

# Delete a secret
:ok = LemonCore.Secrets.delete("api_key")
```

### Env Fallback

Secrets automatically fallback to environment variables (same name). Use `env_fallback: false` to disable.

## Storage Backends

### When to Use Each

| Backend | Persistence | Use Case |
|---------|-------------|----------|
| `EtsBackend` | No (in-memory) | Tests, ephemeral data, default |
| `SqliteBackend` | Yes (single file) | Production, complex queries, WAL mode |
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
# Any table name (atom) works
:ok = LemonCore.Store.put(:my_table, key, value)
value = LemonCore.Store.get(:my_table, key)
:ok = LemonCore.Store.delete(:my_table, key)
items = LemonCore.Store.list(:my_table)
```

Store client calls are fail-soft: if `LemonCore.Store` is overloaded/unavailable and a synchronous call exits (timeout/noproc/shutdown), write APIs return `{:error, :store_unavailable}` and read/list APIs return `nil`/`[]` so callers do not crash.

### Specialized APIs

```elixir
# Chat state (with 24h TTL, auto-swept every 5 minutes)
:ok = LemonCore.Store.put_chat_state(scope, state)
state = LemonCore.Store.get_chat_state(scope)
:ok = LemonCore.Store.delete_chat_state(scope)

# Run history
:ok = LemonCore.Store.append_run_event(run_id, event)
:ok = LemonCore.Store.finalize_run(run_id, summary)
history = LemonCore.Store.get_run_history(session_key, limit: 10)
run = LemonCore.Store.get_run(run_id)

# Policies (agent, channel, session, runtime)
:ok = LemonCore.Store.put_agent_policy(agent_id, policy)
policy = LemonCore.Store.get_agent_policy(agent_id)
:ok = LemonCore.Store.put_channel_policy(channel_id, policy)
:ok = LemonCore.Store.put_session_policy(session_key, policy)
:ok = LemonCore.Store.put_runtime_policy(policy)  # global override
policy = LemonCore.Store.get_runtime_policy()

# Progress mapping (scope + Telegram message ID -> run_id)
:ok = LemonCore.Store.put_progress_mapping(scope, progress_msg_id, run_id)
run_id = LemonCore.Store.get_run_by_progress(scope, progress_msg_id)
:ok = LemonCore.Store.delete_progress_mapping(scope, progress_msg_id)

# Introspection events (canonical envelope + filtered queries)
:ok =
  LemonCore.Introspection.record(
    :tool_completed,
    %{tool_name: "exec", result_preview: "ok"},
    run_id: run_id,
    session_key: session_key,
    engine: "codex"
  )

events = LemonCore.Introspection.list(run_id: run_id, limit: 50)
```

### Telegram Resume Indexing

When `LemonCore.Store.finalize_run/2` processes Telegram-origin summaries, it indexes
resume tokens for reply-based session switching in `:telegram_msg_resume`.

- Key shape: `{account_id, chat_id, thread_id, thread_generation, msg_id}`
- `thread_generation` comes from run summary `meta.thread_generation` (defaults to `0`)
- This generation field lets transports invalidate stale reply mappings by bumping
  generation per chat/thread, without synchronously scanning and deleting all old rows.

## Event Bus Usage Patterns

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

### Subscribe and Receive

```elixir
# Subscribe
LemonCore.Bus.subscribe("run:" <> run_id)

# Receive events
receive do
  %LemonCore.Event{type: :delta, payload: payload} ->
    handle_delta(payload)
  %LemonCore.Event{type: :completed, payload: payload} ->
    handle_completion(payload)
after
  30_000 -> :timeout
end

# Unsubscribe when done
LemonCore.Bus.unsubscribe("run:" <> run_id)
```

### Broadcast Events

```elixir
event = LemonCore.Event.new(:run_started, %{engine: "lemon"}, %{run_id: run_id})
LemonCore.Bus.broadcast("session:" <> session_key, event)
```

## Common Modification Patterns

### Adding a New Config Key

1. Add the default value to the appropriate `@default_*` map in `lib/lemon_core/config.ex`
2. Add parsing in the corresponding `parse_*` function (e.g., `parse_agent/1`, `parse_gateway/1`)
3. If the key needs an env override, add it to `apply_env_*_overrides/1`
4. If using the Modular interface, update the relevant sub-module in `lib/lemon_core/config/`
5. Add validation in `lib/lemon_core/config/validator.ex` if the key has constraints
6. Update the env var table in AGENTS.md if adding an env override
7. Add tests in `test/lemon_core/config_test.exs`

### Adding a New Storage Backend

1. Create `lib/lemon_core/store/my_backend.ex` implementing `LemonCore.Store.Backend`
2. Implement all 5 callbacks: `init/1`, `put/4`, `get/3`, `delete/3`, `list/2`
3. Add tests in `test/lemon_core/store/my_backend_test.exs`
4. Configure via `config :lemon_core, LemonCore.Store, backend: MyBackend, backend_opts: [...]`

### Adding a New Bus Topic

1. Document the topic in `LemonCore.Bus` moduledoc
2. Add a topic helper function if the topic follows a pattern (like `run_topic/1`)
3. Update the Standard Topics table in AGENTS.md

### Adding a New Secret Provider

1. Secrets are provider-agnostic -- the `provider` field is metadata only
2. To add a new master key source, extend `LemonCore.Secrets.MasterKey.resolve/1`
3. To add a new keychain backend, implement the same interface as `LemonCore.Secrets.Keychain`

### Adding a New Onboarding Task

1. Create `lib/mix/tasks/lemon.onboard.<provider>.ex`
2. The task should handle OAuth flow or token input
3. Store credentials via `LemonCore.Secrets.set/3`
4. Update config via `LemonCore.Config.TomlPatch.upsert_string/4`
5. Add tests in `test/mix/tasks/lemon.onboard.<provider>_test.exs`

### Adding a New Quality Check

1. Create `lib/lemon_core/quality/my_check.ex` with `run/1` returning `{:ok, report} | {:error, report}`
2. Register in `lib/mix/tasks/lemon.quality.ex` checks list
3. Add tests in `test/lemon_core/quality/my_check_test.exs`

## How to Add Quality Checks

Quality checks live in `lib/lemon_core/quality/`. Add new checks to the `mix lemon.quality` task.

### Check Module Structure

```elixir
defmodule LemonCore.Quality.MyCheck do
  @moduledoc "Checks something important."

  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    issues = detect_issues(root)

    report = %{
      issue_count: length(issues),
      issues: issues
    }

    if issues == [] do
      {:ok, report}
    else
      {:error, report}
    end
  end

  defp detect_issues(root) do
    # Return list of %{path: String.t(), code: String.t(), message: String.t()}
    []
  end
end
```

### Register in Mix Task

Edit `lib/mix/tasks/lemon.quality.ex`:

```elixir
checks = [
  {:docs, fn -> DocsCheck.run(root: root) end},
  {:architecture, fn -> ArchitectureCheck.run(root: root) end},
  {:my_check, fn -> MyCheck.run(root: root) end}  # Add here
]
```

## Mix Task Usage

### Config Tasks

```bash
# Validate configuration
mix lemon.config validate
mix lemon.config validate --verbose
mix lemon.config validate --project-dir /path/to/project

# Show current config
mix lemon.config show
```

### Secrets Tasks

```bash
# Initialize secrets (generate master key)
mix lemon.secrets.init

# Check secrets status
mix lemon.secrets.status

# List secrets (metadata only)
mix lemon.secrets.list

# Store a secret
mix lemon.secrets.set API_KEY abc123
mix lemon.secrets.set API_KEY abc123 --provider manual --expires-at 1735689600000

# Delete a secret
mix lemon.secrets.delete API_KEY
```

### Onboarding Tasks

```bash
# Guided provider setup:
# - runs provider OAuth flow by default (or accepts --token)
# - stores OAuth credentials in encrypted secrets
# - writes providers.<provider>.api_key_secret
# - optionally updates defaults.provider/defaults.model
mix lemon.onboard.antigravity
mix lemon.onboard.codex
mix lemon.onboard.copilot

# Non-interactive examples
mix lemon.onboard.antigravity --token <token> --set-default --model gemini-3-pro-high
mix lemon.onboard.codex --token <token> --set-default --model gpt-5.2
mix lemon.onboard.codex --token <token> --config-path /path/to/config.toml

# Copilot-specific options
mix lemon.onboard.copilot --enterprise-domain company.ghe.com
mix lemon.onboard.copilot --skip-enable-models
mix lemon.onboard.copilot --token <token>  # bypass OAuth and store raw token
mix lemon.onboard.copilot --token <token> --set-default --model gpt-5
mix lemon.onboard.copilot --token <token> --config-path /path/to/config.toml
```

Anthropic provider auth is API-key based; use `mix lemon.secrets.set llm_anthropic_api_key_raw <token>` and set `providers.anthropic.api_key_secret` accordingly.

### Quality Tasks

```bash
# Run all quality checks
mix lemon.quality

# With config validation
mix lemon.quality --validate-config

# Specific root directory
mix lemon.quality --root /path/to/repo
```

### Store Tasks

```bash
# Migrate JSONL storage to SQLite
mix lemon.store.migrate_jsonl_to_sqlite --from /old/path --to /new/path
```

### Introspection Tasks

```bash
# Show the 20 most recent introspection events (default)
mix lemon.introspection

# Increase limit
mix lemon.introspection --limit 100

# Filter by run ID
mix lemon.introspection --run-id <run_id>

# Filter by session key
mix lemon.introspection --session-key <session_key>

# Filter by event type
mix lemon.introspection --event-type tool_completed

# Filter by agent ID
mix lemon.introspection --agent-id <agent_id>

# Relative time window (h = hours, m = minutes, d = days)
mix lemon.introspection --since 1h
mix lemon.introspection --since 30m
mix lemon.introspection --since 2d

# Absolute time window (ISO 8601)
mix lemon.introspection --since 2026-02-23T00:00:00Z

# Combine filters
mix lemon.introspection --run-id <run_id> --event-type tool_completed --limit 50
```

### Cleanup Tasks

```bash
# Cleanup old data
mix lemon.cleanup --dry-run
mix lemon.cleanup --older-than 30d
```

## Common Tasks and Examples

### Working with Session Keys

```elixir
# Generate main session key
key = LemonCore.SessionKey.main("my_agent")
# => "agent:my_agent:main"

# Generate channel peer key
key = LemonCore.SessionKey.channel_peer(%{
  agent_id: "my_agent",
  channel_id: "telegram",
  account_id: "bot123",
  peer_kind: :dm,
  peer_id: "user456",
  thread_id: "789"  # optional
})

# Parse a session key
%{agent_id: id, kind: kind} = LemonCore.SessionKey.parse(key)
```

### Idempotency for Operations

```elixir
# Simple check/put pattern
case LemonCore.Idempotency.get("messages", msg_id) do
  {:ok, result} ->
    result  # Return cached
  :miss ->
    result = perform_operation()
    :ok = LemonCore.Idempotency.put("messages", msg_id, result)
    result
end

# Or use the execute helper
result = LemonCore.Idempotency.execute("messages", msg_id, fn ->
  perform_operation()
end)
```

### Execution Approvals

```elixir
# Request approval (blocks until resolved; default timeout is :infinity)
case LemonCore.ExecApprovals.request(%{
  run_id: run_id,
  session_key: session_key,
  agent_id: agent_id,
  tool: "shell",
  action: %{command: "rm -rf /"},
  rationale: "Cleanup old files",
  expires_in_ms: 60_000  # optional
}) do
  {:ok, :approved, scope} -> proceed()  # scope: :approve_once/:approve_session/:approve_agent/:approve_global
  {:ok, :denied} -> halt()
  {:error, :timeout} -> handle_timeout()
end

# Resolve approval (called by UI/admin)
# Scopes: :approve_once (not persisted), :approve_session, :approve_agent, :approve_global
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_once)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_session)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_agent)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_global)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :deny)
```

### Telemetry Spans

```elixir
# Emit start/stop/exception automatically
LemonCore.Telemetry.span([:lemon, :my_op], %{meta: "data"}, fn ->
  result = do_work()
  {result, %{extra: "metadata"}}  # Return tuple with result and final metadata
end)

# Direct emit
LemonCore.Telemetry.emit([:lemon, :custom], %{count: 1}, %{detail: "info"})
```

### InboundMessage and RunRequest

```elixir
# InboundMessage: normalized message from any channel
msg = %LemonCore.InboundMessage{
  channel_id: "telegram",
  account_id: "bot123",
  peer: %{kind: :dm, id: "456", thread_id: nil},
  sender: %{id: "789", username: "alice", display_name: "Alice"},
  message: %{id: "1", text: "hello", timestamp: 1234567890, reply_to_id: nil},
  raw: %{},  # original update
  meta: %{}
}

# Build from Telegram update
msg = LemonCore.InboundMessage.from_telegram(:my_bot, chat_id, telegram_message_map)

# RunRequest: canonical run submission (accepted by RouterBridge.submit_run/1)
req = LemonCore.RunRequest.new(%{
  origin: :channel,
  session_key: session_key,
  agent_id: "default",
  prompt: "Hello",
  queue_mode: :collect,  # :collect | :followup | :steer | :interrupt
  engine_id: nil,
  model: nil,
  cwd: "/path/to/project",
  tool_policy: nil,
  meta: %{}
})
```

### RouterBridge

Channel adapters and other producers forward runs to `:lemon_router` without a compile-time dependency. `:lemon_router` registers itself at startup.

```elixir
# Submit a run (returns {:ok, run_id} or {:error, :unavailable})
{:ok, run_id} = LemonCore.RouterBridge.submit_run(run_request)

# Forward inbound message to router
:ok = LemonCore.RouterBridge.handle_inbound(inbound_message)

# Abort a session or run
:ok = LemonCore.RouterBridge.abort_session(session_key, :user_requested)
:ok = LemonCore.RouterBridge.abort_run(run_id, :user_requested)

# Watchdog keepalive decision for an active run
:ok = LemonCore.RouterBridge.keep_run_alive(run_id, :continue)
```

### Dotenv

```elixir
# Load <dir>/.env into process environment (does not override existing vars)
:ok = LemonCore.Dotenv.load("/path/to/project")
:ok = LemonCore.Dotenv.load("/path/to/project", override: true)

# Load and swallow errors (logs warnings)
:ok = LemonCore.Dotenv.load_and_log("/path/to/project")
```

### Low-level ETS Deduplication

`LemonCore.Dedupe.Ets` is a lightweight TTL dedup that operates directly on ETS tables (no GenServer). Use it for high-frequency dedup within a single process or supervisor.

```elixir
:ok = LemonCore.Dedupe.Ets.init(:my_dedup_table)
:ok = LemonCore.Dedupe.Ets.mark(:my_dedup_table, key)
true = LemonCore.Dedupe.Ets.seen?(:my_dedup_table, key, ttl_ms)
:seen | :new = LemonCore.Dedupe.Ets.check_and_mark(:my_dedup_table, key, ttl_ms)
count = LemonCore.Dedupe.Ets.cleanup_expired(:my_dedup_table, ttl_ms)
```

### HTTP Requests

```elixir
# Ensure inets/ssl started, then request
LemonCore.Httpc.request(:get, {"https://api.example.com/data", []}, [], [])
```

## Testing Guidance

### Test Harness

`LemonCore.Testing` provides a test harness for writing isolated tests.

```elixir
# In test files, use the Case template
defmodule MyTest do
  use LemonCore.Testing.Case, async: true  # or with_store: true

  test "example", %{harness: harness, tmp_dir: tmp_dir} do
    path = temp_file!(harness, "config.toml", "[agent]\ndefault_model = \"test\"")
    key = unique_session_key("mytest")
  end
end

# Available helpers (imported automatically by LemonCore.Testing.Case):
unique_token()             # unique integer
unique_scope()             # {prefix, integer}
unique_session_key()       # "agent:test_<n>:main"
unique_run_id()            # "run_<n>"
temp_file!(harness, name, content)   # create file in tmp_dir
temp_dir!(harness, name)             # create subdir in tmp_dir
clear_store_table(table)             # empty a Store table
mock_home!(harness)                  # redirect HOME to tmp subdir
random_master_key()                  # 32-byte base64 key for secrets tests
```

### Running Tests

```bash
# Run all tests for lemon_core
mix test apps/lemon_core

# Run specific test file
mix test apps/lemon_core/test/lemon_core/config_test.exs

# Run with coverage
mix test --cover apps/lemon_core
```

### Test Patterns

- **Config tests**: Use `mock_home!/1` to redirect HOME; create TOML files in tmp dirs; run as `async: false` since they modify env vars
- **Secrets tests**: Use `random_master_key/0` and set `LEMON_SECRETS_MASTER_KEY` env; clear `:secrets_v1` table in setup
- **Store tests**: Start Store with `Store.start_link([])` in setup; implement custom backends for error testing
- **Bus tests**: Subscribe in test process, broadcast, assert receive within timeout

## Connections to Other Apps

This is the foundational app. All other umbrella apps depend on it:

- **lemon_router** -- Registers via `RouterBridge.configure/1` at startup; uses `SessionKey`, `Store`, `Bus`, `Config`
- **lemon_gateway** -- Uses `GatewayConfig`, `Config`, `Bus`, `Store` for gateway lifecycle
- **lemon_channels** -- Uses `InboundMessage`, `RouterBridge`, `Bus`, `Binding`, `SessionKey`
- **coding_agent** -- Uses `Config` (provider/model resolution), `Secrets` (API key resolution), `Store`, `Bus`
- **lemon_automation** -- Uses `Store` (cron jobs), `Bus` (cron events), `Config`
- **lemon_control_plane** -- Uses `Config.reload`, `Store`, `Secrets`, `ExecApprovals`
- **ai** -- Uses `Secrets` and `Config.Providers` for API key resolution

## External Dependencies

- `jason` - JSON encoding/decoding
- `toml` - TOML parsing
- `uuid` - UUID generation
- `phoenix_pubsub` - PubSub infrastructure
- `telemetry` - Metrics and instrumentation
- `exqlite` - SQLite driver
- `file_system` - File watching (optional, for config reload)

## Supervised Process Tree

The `LemonCore.Application` supervisor starts (`:one_for_one`):

1. `Phoenix.PubSub` (name: `LemonCore.PubSub`) - PubSub backbone
2. `LemonCore.ConfigCache` - ETS-backed config cache
3. `LemonCore.Store` - Storage GenServer
4. `LemonCore.ConfigReloader` - Reload orchestrator
5. `LemonCore.ConfigReloader.Watcher` - File-system watcher (optional, requires `file_system` dep)
6. `LemonCore.Browser.LocalServer` - Local browser driver

## Important Notes

- **Never** add umbrella app dependencies to lemon_core - it's the base layer
- Keep module interfaces stable - other apps depend on them
- `LemonCore.Config.load/2` uses the cache by default; `LemonCore.Config.reload/2` forces a disk read and updates the cache
- Secrets values are never logged or returned by list/status APIs
- Secret reads (`get/2`) update usage metadata (`usage_count`, `last_used_at`) but do not mutate `updated_at`
- Store backends serialize with `:erlang.term_to_binary/1`; keys and values can be any Erlang term
- Events use millisecond timestamps from `System.system_time(:millisecond)`
- `LemonCore.RouterBridge` returns `{:error, :unavailable}` when `:lemon_router` has not registered itself; callers must handle this gracefully
- `LemonCore.Dedupe.Ets` uses monotonic time for TTL; `LemonCore.Idempotency` uses wall-clock time
- The `LemonCore.Config.Modular` interface is the newer typed approach; the older `LemonCore.Config` struct is still the primary interface used by most of the codebase
