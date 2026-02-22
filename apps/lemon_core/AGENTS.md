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
| `LemonCore.ConfigCache` | ETS-backed config cache with mtime-based invalidation |
| `LemonCore.ConfigReloader` | Hot reload orchestrator with diff computation and Bus broadcast |
| `LemonCore.Secrets` | Encrypted secrets API (get/set/list/delete) |
| `LemonCore.Secrets.Crypto` | AES-256-GCM encryption with HKDF key derivation |
| `LemonCore.Secrets.Keychain` | macOS keychain integration for master key storage |
| `LemonCore.Store` | Storage GenServer with pluggable backends |
| `LemonCore.Store.EtsBackend` | In-memory ETS (ephemeral, default) |
| `LemonCore.Store.SqliteBackend` | SQLite with WAL mode (persistent) |
| `LemonCore.Store.JsonlBackend` | Append-only JSONL (portable, human-readable) |
| `LemonCore.Bus` | PubSub wrapper with topic helpers |
| `LemonCore.Event` | Canonical event struct for Bus and persistence |
| `LemonCore.EventBridge` | Cross-app event translation |
| `LemonCore.SessionKey` | Session key generation and parsing |
| `LemonCore.Idempotency` | Deduplication with TTL support |
| `LemonCore.ExecApprovals` | Tool execution approval flow |
| `LemonCore.Telemetry` | Telemetry event helpers |
| `LemonCore.Httpc` | `:httpc` wrapper ensuring `:inets`/`:ssl` started |
| `LemonCore.Clock` | Time utilities (monotonic timestamps) |
| `LemonCore.Id` | UUID and unique ID generation |

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
# Cached read (default, hot path)
config = LemonCore.Config.load(cwd)

# Force reload from disk
config = LemonCore.Config.reload(cwd)

# Access nested values
provider = LemonCore.Config.get(config, [:agent, :default_provider], "anthropic")
```

### Config Sections

- `providers` - LLM API keys and base URLs
- `agent` - Default model, thinking level, retry config, tool settings
- `tui` - Theme, debug mode
- `logging` - File logging, level, rotation
- `gateway` - Max concurrent runs, engine bindings, Telegram settings
- `agents` - Per-agent profiles with tool policies

## Secrets Management Flow

### Storage Model

Secrets are encrypted at rest with AES-256-GCM. The encryption key is derived via HKDF-SHA256 from a master key plus per-secret random salt.

### Master Key Resolution (in order)

1. `LEMON_SECRETS_MASTER_KEY` env var
2. macOS Keychain (if available)
3. Fail with `:missing_master_key`

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

### Specialized APIs

```elixir
# Chat state (with TTL)
:ok = LemonCore.Store.put_chat_state(scope, state)
state = LemonCore.Store.get_chat_state(scope)

# Run history
:ok = LemonCore.Store.append_run_event(run_id, event)
:ok = LemonCore.Store.finalize_run(run_id, summary)
history = LemonCore.Store.get_run_history(session_key, limit: 10)

# Policies
:ok = LemonCore.Store.put_agent_policy(agent_id, policy)
policy = LemonCore.Store.get_agent_policy(agent_id)
```

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
# Request approval (blocks until resolved)
case LemonCore.ExecApprovals.request(%{
  run_id: run_id,
  session_key: session_key,
  agent_id: agent_id,
  tool: "shell",
  action: %{command: "rm -rf /"},
  rationale: "Cleanup old files"
}) do
  {:ok, :approved, scope} -> proceed()
  {:ok, :denied} -> halt()
  {:error, :timeout} -> handle_timeout()
end

# Resolve approval (called by UI/admin)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_once)
:ok = LemonCore.ExecApprovals.resolve(approval_id, :approve_session)
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

### HTTP Requests

```elixir
# Ensure inets/ssl started, then request
LemonCore.Httpc.request(:get, {"https://api.example.com/data", []}, [], [])
```

## External Dependencies

- `jason` - JSON encoding/decoding
- `toml` - TOML parsing
- `uuid` - UUID generation
- `phoenix_pubsub` - PubSub infrastructure
- `telemetry` - Metrics and instrumentation
- `exqlite` - SQLite driver
- `file_system` - File watching (optional, for config reload)

## Testing

```bash
# Run all tests for lemon_core
mix test apps/lemon_core

# Run specific test file
mix test apps/lemon_core/test/lemon_core/config_test.exs

# Run with coverage
mix test --cover apps/lemon_core
```

## Important Notes

- **Never** add umbrella app dependencies to lemon_core - it's the base layer
- Keep module interfaces stable - other apps depend on them
- Use `LemonCore.ConfigCache` for hot-path config reads
- Secrets values are never logged or returned by list/status APIs
- Store backends auto-serialize with `:erlang.term_to_binary/1`
- Events use millisecond timestamps from `System.system_time(:millisecond)`
