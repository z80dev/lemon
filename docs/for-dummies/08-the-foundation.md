# Part 8: The Foundation (lemon_core)

[< Talking to LLMs](07-talking-to-llms.md)

---

`lemon_core` is the bottom of the stack. Every other app in Lemon depends on it,
but it depends on nothing else (within the umbrella). It provides the shared
vocabulary, storage, messaging, and configuration that all the specialized apps
build on.

Think of it as the operating system kernel of Lemon — invisible when everything
works, but everything breaks without it.

---

## The Three Pillars

lemon_core provides three essential services:

1. **Config** — how Lemon knows what to do (TOML files, secrets, hot reload)
2. **Store** — how Lemon remembers things (ETS, SQLite, typed wrappers)
3. **Bus** — how Lemon's parts talk to each other (PubSub event messaging)

Plus a collection of shared data structures and utilities.

---

## Pillar 1: Config

### Where Config Lives

Lemon loads configuration from up to three sources, merged in priority order:

```
~/.lemon/config.toml          ← User-wide defaults (lowest priority)
    +
<project>/.lemon/config.toml  ← Project-specific overrides
    +
Environment variables          ← Highest priority (ANTHROPIC_API_KEY, etc.)
```

Each layer overrides the one below it. This means you can set defaults globally
and override per-project.

### What's in the Config

The main config sections:

| Section | What It Controls |
|---------|-----------------|
| `[providers]` | API keys and base URLs for AI providers |
| `[defaults]` / `[agent]` | Default provider, model, thinking level, tool settings |
| `[profiles]` / `[agents]` | Per-agent profiles (name, engine, model, system prompt) |
| `[gateway]` | Max concurrent runs, channel enables, engine bindings |
| `[logging]` | Log file path, level, rotation |
| `[tui]` | Terminal UI theme and debug mode |

### Hot Reload

Lemon watches your config files and reloads them automatically when they change:

1. `ConfigReloader.Watcher` monitors `config.toml` and `.env` files
2. On change, it computes a file digest to detect actual changes
3. If changed: reloads `.env` first, then TOML
4. Computes a diff, updates the ETS cache
5. Broadcasts a `:config_reloaded` event on the Bus
6. Every app that cares (router, gateway, channels) can react to the change

If the reload fails (bad TOML syntax, etc.), the last good config is kept
and a `:config_reload_failed` event is broadcast.

This means you can edit your config.toml while Lemon is running, and changes
take effect within seconds without restarting.

### Secrets

Sensitive values (API keys, tokens) can be stored in an encrypted secrets
store instead of plain text in config or environment variables.

**How encryption works:**
- AES-256-GCM encryption (military-grade)
- Per-secret key derived via HKDF-SHA256 from a master key + random salt
- Master key lives in macOS Keychain (preferred) or `LEMON_SECRETS_MASTER_KEY`
  env var

**Using secrets:**
```toml
# In config.toml, reference a secret instead of a plain key:
[providers.anthropic]
secret_ref = "llm_anthropic_api_key_raw"
```

Secrets are managed via mix tasks: `mix lemon.secrets.set`,
`mix lemon.secrets.list`, `mix lemon.secrets.delete`.

---

## Pillar 2: Store

The Store is Lemon's persistence layer — a key-value store organized into
named tables (namespaces).

### Three Backends

| Backend | Persistent? | When Used |
|---------|------------|-----------|
| **ETS** | No (in-memory only) | Tests, ephemeral data, default |
| **SQLite** | Yes (single file, WAL mode) | Production |
| **JSONL** | Yes (append-only files) | Debugging, data portability |

The backend is pluggable — you can switch between them without changing any
code that uses the Store.

### How It Works

The Store is a single GenServer that wraps the chosen backend:

```
Caller → Store GenServer → Backend (ETS/SQLite/JSONL) → Data
```

The basic operations:
- `put(table, key, value)` — store a value
- `get(table, key)` — retrieve a value
- `delete(table, key)` — remove a value
- `list(table)` — list all entries in a table

### The ReadCache (Performance)

For frequently-read data, the Store maintains **public ETS tables** that shadow
the backing store. Reads bypass the GenServer entirely — direct ETS lookups are
instant and don't create a bottleneck.

Cached domains include:
- Chat state
- Run records
- Progress mappings
- Session index
- Telegram known targets

Writes still go through the GenServer, which updates both the backend and the
cache atomically.

### Typed Wrappers

Direct Store access is discouraged. Instead, each data domain has a **typed
wrapper** that provides a clean API:

| Wrapper | What It Stores |
|---------|---------------|
| `ChatStateStore` | Per-chat state with 24h TTL, auto-swept every 5 minutes |
| `RunStore` | Run history (events, finalization, queries) |
| `PolicyStore` | Per-agent, per-channel, per-session runtime policies |
| `IdempotencyStore` | Idempotency entries (24h TTL) |
| `ProgressStore` | Progress message → run_id mappings |
| `IntrospectionStore` | Telemetry event log (7-day retention) |
| `HeartbeatStore` | Heartbeat configs and timestamps |
| `ExecApprovalStore` | Pending tool-execution approvals |

### Fail-Soft

If the Store GenServer is overloaded or down:
- Writes return `{:error, :store_unavailable}`
- Reads return `nil` or `[]`

Callers never crash due to Store problems. This is an important reliability
property — a storage hiccup shouldn't take down an active AI conversation.

---

## Pillar 3: The Bus

The Bus is Lemon's nervous system. It's a thin wrapper around Phoenix.PubSub
(Elixir's battle-tested publish/subscribe library).

### How It Works

Any process can:
1. **Subscribe** to a topic: `Bus.subscribe("run:abc-123")`
2. **Receive** messages as regular Elixir messages in its mailbox
3. **Broadcast** to a topic: `Bus.broadcast("run:abc-123", event)`
4. **Unsubscribe** when done

Messages arrive as standard Elixir process messages, so any GenServer or Task
can participate.

### Standard Topics

| Topic | What Gets Published |
|-------|-------------------|
| `"run:<run_id>"` | All events for a specific AI run (deltas, tool actions, completion) |
| `"session:<session_key>"` | Session-level events (forwarded from run events) |
| `"channels"` | Channel lifecycle events |
| `"cron"` | Automation events |
| `"exec_approvals"` | Tool approval requests and resolutions |
| `"system"` | Config reload, global events |
| `"logs"` | Log streaming |

### The Event Envelope

Every message on the Bus is wrapped in an `Event` struct:

```
%LemonCore.Event{
  type: :delta,
  ts_ms: 1710000123456,
  payload: %{text: "Here is the answer..."},
  meta: %{run_id: "abc-123", session_key: "agent:default:..."}
}
```

This standardized envelope means consumers can always check event type and
timestamp without knowing the specific payload structure.

### Why the Bus Matters

The Bus is what makes Lemon's streaming architecture possible. When the AI
generates a token:

```
ai package → agent_core → lemon_gateway (Run) → Bus("run:xyz")
                                                    │
                                    ┌───────────────┼───────────────┐
                                    │               │               │
                               RunProcess     WebSocket       Control Plane
                              (router)        (TUI/web)       (API clients)
                                    │
                              StreamCoalescer
                                    │
                              Dispatcher
                                    │
                              Telegram
                                    │
                              Your phone
```

The gateway doesn't know or care who's listening. It just broadcasts. The
router, TUI, web UI, and any other subscriber all receive the same events
simultaneously.

---

## Shared Data Structures

lemon_core defines the common vocabulary that all apps speak:

### InboundMessage

The universal format for incoming user messages, regardless of channel:

```
%InboundMessage{
  channel_id: "telegram",
  account_id: "default",
  peer: %{kind: :dm, id: "123456789"},
  sender: %{id: "123456789", username: "you"},
  message: %{text: "Hello Lemon", timestamp: 1710000000}
}
```

### RunRequest

The formal "please run the AI" request:

```
%RunRequest{
  origin: :channel,
  session_key: "agent:default:telegram:default:dm:123456789",
  prompt: "What files are in my home directory?",
  agent_id: "default",
  engine_id: "lemon",
  queue_mode: :collect
}
```

### DeliveryIntent

A semantic description of what to show the user:

```
%DeliveryIntent{
  kind: :stream_snapshot,
  run_id: "abc-123",
  session_key: "agent:default:...",
  body: "Here are the files in your home directory...",
  route: %DeliveryRoute{channel_id: "telegram", peer: ...}
}
```

### SessionKey

A string encoding that uniquely identifies a conversation:

```
"agent:default:telegram:default:dm:123456789"
  │       │       │         │    │      │
  prefix  agent   channel  acct  kind   peer_id
```

### ResumeToken

A saved pointer for continuing AI conversations:

```
%ResumeToken{engine: "lemon", value: "session-uuid-here"}
```

---

## The Glue Patterns

### Runtime Bridges

lemon_core provides bridge modules that allow apps to call each other without
compile-time dependencies:

```
lemon_channels ──RouterBridge──> lemon_router
                 (runtime only, no compile-time dep)
```

The router registers itself at startup. Channels call through the bridge.
If the router isn't available, the bridge returns `{:error, :unavailable}`
instead of crashing.

`EventBridge` works the same way for the control plane.

### Shared Vocabulary

By putting `InboundMessage`, `RunRequest`, `DeliveryIntent`, `Event`,
`SessionKey`, and all the typed store wrappers in lemon_core, every app
speaks the same language:

```
Telegram adapter creates InboundMessage
    → passes to RouterBridge
        → router creates RunRequest
            → gateway broadcasts Events on the Bus
                → Telegram adapter receives Events
                    → delivers response to your phone
```

None of these apps import each other directly. They only import lemon_core.

---

## Other Utilities

lemon_core also provides a grab bag of utilities:

| Module | What It Does |
|--------|-------------|
| `Id` | UUID generation for run IDs, approval IDs, etc. |
| `Clock` | Monotonic timestamps |
| `Httpc` | Thin HTTP client wrapper |
| `Dotenv` | Loads `.env` files into the process environment |
| `Telemetry` | Standardized telemetry event helpers |
| `Idempotency` | At-most-once execution with 24h TTL |
| `Dedupe.Ets` | Low-level ETS-backed deduplication |
| `ExecApprovals` | Tool execution approval workflow |

---

## The Supervision Tree

```
LemonCore.Application
├── Phoenix.PubSub (the Bus backbone)
├── ConfigCache (ETS-backed config cache)
├── Store (storage GenServer)
├── ConfigReloader (hot reload orchestrator)
├── ConfigReloader.Watcher (file watcher)
└── Browser.LocalServer (Playwright integration)
```

These processes start first, before any other app. By the time lemon_router,
lemon_gateway, or lemon_channels start, all of lemon_core's services are
available.

---

## Key Takeaways

1. **lemon_core is the dependency-free base** — it depends on no other umbrella
   app, but every app depends on it.
2. **Three pillars: Config, Store, Bus** — configuration, persistence, and
   messaging are the foundation everything else is built on.
3. **Hot reload** means config changes take effect without restarting Lemon.
4. **The ReadCache pattern** makes reads fast (direct ETS) while keeping writes
   consistent (through the GenServer).
5. **Runtime bridges** allow apps to communicate without compile-time coupling,
   making the system more resilient and independently testable.
6. **Shared data structures** are the common language — every app speaks
   `InboundMessage`, `RunRequest`, `Event`, and `DeliveryIntent`.
7. **Fail-soft everywhere** — if the Store or Bus has issues, callers get
   errors instead of crashes. Active conversations survive infrastructure
   hiccups.

---

## You Made It!

That's the complete tour of Lemon's architecture, from your thumbs on a
Telegram keyboard all the way down to the event bus and storage layer.

Here's the full picture one last time:

```
┌─────────────────────────────────────────────────────────┐
│                    Your Phone (Telegram)                 │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  lemon_channels ("The Front Door")                      │
│  Telegram polling → normalize → auth → buffer → route   │
│  Outbox ← renderer ← dispatcher ← delivery intents     │
└────────────────────────┬────────────────────────────────┘
                         │ RouterBridge
┌────────────────────────▼────────────────────────────────┐
│  lemon_router ("The Traffic Cop")                       │
│  Orchestrator → SessionCoordinator → RunProcess         │
│  StreamCoalescer → ToolStatusCoalescer → DeliveryIntent │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  lemon_gateway ("The Engine Room")                      │
│  Scheduler → ThreadWorker → Run → Engine                │
│  Events broadcast to Bus                                │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  agent_core + coding_agent ("The Agent")                │
│  Agent loop: prompt → LLM → tools → repeat              │
│  30+ tools, session persistence, compaction              │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  ai ("The Translator")                                  │
│  Provider abstraction → stream/complete                  │
│  Circuit breaker, rate limiter, token tracking           │
└────────────────────────┬────────────────────────────────┘
                         │
              ┌──────────▼──────────┐
              │  Claude / GPT /     │
              │  Gemini / Bedrock   │
              │  (external APIs)    │
              └─────────────────────┘

         ┌──────────────────────────────┐
         │  lemon_core ("The Foundation") │
         │  Config │ Store │ Bus         │
         │  Shared data structures       │
         │  (underneath everything)      │
         └──────────────────────────────┘
```

To learn more about any specific area, check the `AGENTS.md` file in each
app's directory, or the detailed docs in `docs/`.

[< Back to Table of Contents](README.md)
