# LemonRouter

Central routing and orchestration layer for the Lemon agent platform. LemonRouter sits between inbound channels (Telegram, Discord, HTTP, etc.) and the AI engine gateway, managing the full lifecycle of agent runs: message intake, session resolution, run submission, streaming output coalescing, tool status tracking, and delivery back to channels.

## Architecture Overview

```
                         ┌─────────────────────────────────────┐
                         │           LemonRouter               │
                         │                                     │
  ┌──────────┐           │  ┌────────┐     ┌────────────────┐  │         ┌──────────────┐
  │ Telegram  │──inbound──▶│  Router  │────▶│ RunOrchestrator │──────────▶│ LemonGateway │
  │ Discord   │           │  └────────┘     └────────────────┘  │         │  (AI Engine)  │
  │ HTTP API  │           │       │               │             │         └──────┬───────┘
  └──────────┘           │       │          ┌────┴─────┐       │                │
       ▲                 │       │          │RunProcess │       │           run events
       │                 │       │          │ (per-run) │       │           (deltas,
       │                 │       │          └────┬─────┘       │            actions,
       │                 │       │               │             │            completion)
       │                 │  ┌────┴───────────────┴──────┐      │                │
       │                 │  │     StreamCoalescer        │◀─────────────────────┘
       │                 │  │     ToolStatusCoalescer    │      │
       │                 │  └────────────┬──────────────┘      │
       │                 │               │                     │
       │                 │        ┌──────┴───────┐             │
       │                 │        │ChannelAdapter│             │
       │                 │        │ (per-channel) │             │
       │                 │        └──────┬───────┘             │
       │                 │               │                     │
       │                 └───────────────┼─────────────────────┘
       │                                 │
       └──────── delivery (edits, ───────┘
                  new messages,
                  media groups)
```

### Core Flow

1. **Inbound**: A message arrives from a channel (Telegram, Discord, etc.) as an `InboundMessage` struct.
2. **Session Resolution**: `Router` resolves the session key from explicit metadata or computes it from channel/peer identity.
3. **Run Submission**: `RunOrchestrator` resolves the agent profile, model, engine, tool policy, and builds a `LemonGateway.Types.Job`. It starts a `RunProcess` under the `RunSupervisor`.
4. **Run Execution**: `RunProcess` monitors the gateway process and subscribes to run events via `LemonCore.Bus`.
5. **Streaming Output**: Deltas flow into `StreamCoalescer`, which buffers them and flushes to channels through `ChannelAdapter` implementations.
6. **Tool Status**: Action lifecycle events flow into `ToolStatusCoalescer`, rendered by `ToolStatusRenderer` into editable status messages.
7. **Completion**: `RunProcess` finalizes coalescers, delivers final output, handles fanout to secondary routes, and cleans up.

## Module Inventory

### Public API

| Module | Purpose |
|--------|---------|
| `LemonRouter` | Facade delegating to internal modules: `submit/1`, `abort/2`, `send_to_agent/3`, `resolve_agent_session/3`, directory/endpoint listing |

### Message Intake and Routing

| Module | Purpose |
|--------|---------|
| `LemonRouter.Router` | Inbound message handler. Resolves session keys, handles control-agent messages, abort/keepalive, pending compaction consumption |
| `LemonRouter.AgentInbox` | BEAM-local inbox API with session selectors (`:latest`, `:new`, explicit key), primary/fanout target resolution, queue modes |
| `LemonRouter.AgentDirectory` | Session/agent discovery phonebook. Merges active sessions from `SessionRegistry` with durable metadata from `LemonCore.Store` |
| `LemonRouter.AgentEndpoints` | Persistent endpoint aliases mapping friendly names to routes. Supports Telegram shorthand (`tg:<chat_id>`, `tg:<chat_id>/<topic_id>`) |
| `LemonRouter.AgentProfiles` | GenServer loading agent profiles from TOML config. Provides `get/1`, `exists?/1`, `list/0`, `reload/0` |

### Run Orchestration

| Module | Purpose |
|--------|---------|
| `LemonRouter.RunOrchestrator` | GenServer handling run submission. Resolves agent config, tool policy, model/engine, sticky engine, cwd, resume tokens. Builds `LemonGateway.Types.Job` |
| `LemonRouter.RunProcess` | Per-run GenServer owning run lifecycle. Registers in `RunRegistry`/`SessionRegistry`, subscribes to Bus events, delegates to submodules |
| `LemonRouter.RunProcess.Watchdog` | Idle-run watchdog timer (default 2h). Interactive keepalive confirmation for Telegram with Keep Waiting / Stop Run buttons |
| `LemonRouter.RunProcess.CompactionTrigger` | Context overflow detection via error markers. Preemptive compaction when usage approaches context limit (default ratio 0.9) |
| `LemonRouter.RunProcess.RetryHandler` | Zero-answer auto-retry (max 1 attempt). Only retries assistant_error with empty answer |
| `LemonRouter.RunProcess.OutputTracker` | Delta ingestion to `StreamCoalescer`, final output, stream finalization, tool status finalization, fanout delivery, generated image tracking |
| `LemonRouter.RunSupervisor` | DynamicSupervisor wrapper for `RunProcess` children with lifecycle logging |
| `LemonRouter.RunCountTracker` | Telemetry-based run counters (active, queued, completed_today) with midnight UTC reset |

### Streaming and Output

| Module | Purpose |
|--------|---------|
| `LemonRouter.StreamCoalescer` | GenServer buffering streaming deltas with configurable thresholds (min_chars, idle_ms, max_latency_ms). Delegates to `ChannelAdapter` for channel-specific output |
| `LemonRouter.ToolStatusCoalescer` | Coalesces tool/action lifecycle events into editable "Tool calls" status messages. Max 40 actions tracked |
| `LemonRouter.ToolStatusRenderer` | Renders "Tool calls:" status text with `[running]`/`[ok]`/`[err]` labels and result previews (truncated to 140 chars) |
| `LemonRouter.ToolPreview` | Normalizes tool results to human-readable text. Handles `AgentToolResult`, `TextContent`, lists, maps |

### Channel Adapters

| Module | Purpose |
|--------|---------|
| `LemonRouter.ChannelAdapter` | Behaviour defining channel-specific output strategies. Dispatches `"telegram"` to Telegram adapter, everything else to Generic |
| `LemonRouter.ChannelAdapter.Generic` | Default adapter: no truncation, no file batching, no reply markup. Uses `ChannelsDelivery.enqueue` |
| `LemonRouter.ChannelAdapter.Telegram` | Telegram-specific: dual-message model (progress + answer), resume token tracking, media group batching (max 10), inline keyboard cancel button, recent action limit of 5 |
| `LemonRouter.ChannelsDelivery` | Wraps `LemonChannels.Outbox` enqueueing with telemetry on failure. Provides telegram-specific `telegram_enqueue` and `telegram_enqueue_with_notify` |
| `LemonRouter.ChannelContext` | Session key parsing, channel_id extraction, channel edit support detection, `compact_meta/1` |

### Model and Engine Selection

| Module | Purpose |
|--------|---------|
| `LemonRouter.ModelSelection` | Independent model + engine resolution with multi-level precedence |
| `LemonRouter.SmartRouting` | Task complexity classification (simple/moderate/complex) to select cheap vs primary model |
| `LemonRouter.StickyEngine` | Extracts engine preference from prompt directives ("use codex", "switch to claude", "with gemini") |
| `LemonRouter.Policy` | Tool policy merging from multiple sources with strictness escalation for groups |

### Infrastructure

| Module | Purpose |
|--------|---------|
| `LemonRouter.Application` | OTP application: starts registries, supervisors, GenServers, optional health server, configures `RouterBridge` |
| `LemonRouter.Health` | Health check logic: supervisor, orchestrator, run_supervisor, run_counts |
| `LemonRouter.Health.Router` | Plug router serving `/healthz` JSON endpoint |

## Message Flow in Detail

### Inbound Message Processing

```
InboundMessage arrives
    │
    ▼
Router.handle_inbound/1
    │
    ├── Resolve session key
    │     ├── Explicit: meta.session_key
    │     └── Computed: agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>]
    │
    ├── Check pending compaction (generic :pending_compaction marker)
    │     ├── If pending and not auto_compacted: build compaction prompt, submit
    │     └── TTL: 12 hours
    │
    └── Submit to RunOrchestrator
```

### Run Submission Pipeline

```
RunOrchestrator.submit/1
    │
    ├── Load agent profile (AgentProfiles)
    ├── Resolve tool policy (Policy.merge/1)
    │     Precedence: agent → channel → session → runtime
    ├── Resolve model (ModelSelection)
    │     Precedence: request → meta → session → profile → default
    ├── Resolve engine (ModelSelection)
    │     Precedence: resume → explicit → model-implied → profile default
    ├── Check sticky engine (StickyEngine)
    │     Matches: "use <engine>", "switch to <engine>", "with <engine>"
    ├── Resolve cwd and resume tokens
    │
    ├── Build LemonGateway.Types.Job
    │
    └── Start RunProcess under RunSupervisor (DynamicSupervisor)
          ├── Register in RunRegistry (by run_id)
          ├── Register in SessionRegistry (by session_key)
          ├── Subscribe to Bus topic for run events
          └── Call LemonGateway.submit/1
```

### Run Event Lifecycle

```
Gateway emits events via LemonCore.Bus
    │
    ├── :run_started
    │     └── RunProcess records start, emits run_started broadcast
    │
    ├── :delta (seq, text)
    │     └── OutputTracker → StreamCoalescer.ingest_delta
    │           ├── Buffer text
    │           ├── Flush when: buffer >= min_chars OR max_latency reached OR idle timeout
    │           └── ChannelAdapter.emit_stream_output → Channel delivery
    │
    ├── :engine_action (tool/command/file_change/web_search/subagent)
    │     └── OutputTracker → ToolStatusCoalescer.ingest_action
    │           ├── Upsert action (started/updated/completed)
    │           ├── Render via ToolStatusRenderer
    │           └── ChannelAdapter.emit_tool_status → Channel delivery
    │
    └── :run_completed
          ├── CompactionTrigger: check context overflow, schedule compaction if needed
          ├── RetryHandler: auto-retry if zero answer + assistant_error
          ├── OutputTracker: finalize stream, finalize tool status
          ├── Fanout to secondary routes
          └── RunProcess terminates
```

### Stream Coalescing

```
Delta arrives at StreamCoalescer
    │
    ├── Reject if finalized or out-of-order (seq <= last_seq)
    │
    ├── Append to buffer and full_text (capped at 100,000 chars)
    │
    └── Flush decision:
          ├── buffer >= min_chars (48)     → immediate flush
          ├── time >= max_latency (1200ms) → immediate flush
          └── otherwise                    → schedule idle timer (400ms)
                                               └── flush on :idle_timeout

Flush:
    ├── Broadcast :coalesced_output to session topic
    └── ChannelAdapter.emit_stream_output(snapshot)
          ├── Generic: enqueue :text chunk
          └── Telegram: create/edit answer message with full text
```

## Session Key Format

Session keys uniquely identify an agent's conversation context:

```
Simple (control plane):
  agent:<agent_id>:main

Channel-specific:
  agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>

Threaded:
  agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>:thread:<thread_id>

With sub-session:
  agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>:sub:<sub_id>
```

## Routing Rules and Patterns

### Model Selection Precedence

1. **Request-level**: Explicit `model` in submit options
2. **Meta-level**: `meta.model` from the inbound message
3. **Session-level**: Stored session model preference
4. **Profile-level**: Agent profile default model
5. **System default**: Falls back to system-configured default

### Engine Selection Precedence

1. **Resume**: If resuming a run, use the original engine
2. **Explicit**: `engine` in submit options
3. **Model-implied**: Engine implied by the selected model (e.g., `o3` implies OpenAI)
4. **Profile default**: Agent profile engine setting
5. **System default**: `"lemon"` engine

### Sticky Engine

Users can override engine mid-conversation via natural language:
- `"use codex"`, `"switch to claude"`, `"with gemini"`
- Only matches engines registered in `LemonChannels.EngineRegistry`

### Tool Policy Merging

Policies merge from least to most specific, with later sources overriding earlier ones:

1. **Agent-level**: From agent profile config
2. **Channel-level**: Channel-specific restrictions
3. **Session-level**: Per-session overrides
4. **Runtime-level**: Per-request overrides

Group channels get stricter defaults: `bash`, `write`, and `process` tools require `:always` approval.

### Smart Routing

Classifies message complexity for model selection:
- **Simple**: Greetings, short questions, acknowledgments -> cheap model
- **Complex**: Multi-step reasoning, code review, analysis -> primary model
- **Moderate**: Everything else -> primary model

### Queue Modes

Messages can be queued with different semantics via `AgentInbox`:
- `:collect` - Append to pending messages
- `:followup` - Follow-up to current run
- `:steer` - Steering instruction for active run
- `:steer_backlog` - Steer with backlog awareness
- `:interrupt` - Interrupt current run

## Configuration Options

### Stream Coalescer Thresholds

| Option | Default | Description |
|--------|---------|-------------|
| `min_chars` | 48 | Minimum characters before flushing buffer |
| `idle_ms` | 400 | Flush after this idle period (ms) |
| `max_latency_ms` | 1200 | Maximum time before forced flush (ms) |

### Watchdog

| Option | Default | Description |
|--------|---------|-------------|
| idle timeout | 2 hours | Time before watchdog fires on idle run |
| confirmation timeout | 5 minutes | Time to wait for keepalive confirmation (Telegram) |

### Compaction Trigger

| Option | Default | Description |
|--------|---------|-------------|
| preemptive ratio | 0.9 | Usage ratio triggering preemptive compaction |
| compaction TTL | 12 hours | Expiry for pending compaction markers |

### Application

| Option | Default | Description |
|--------|---------|-------------|
| `max_children` | 500 | Maximum concurrent `RunProcess` children under `RunSupervisor` |
| Health port | 4043 | HTTP port for `/healthz` endpoint |

### Run Count Tracker

- Tracks active, queued, and completed_today counters via `:counters`
- Resets at midnight UTC daily

## OTP Supervision Tree

```
LemonRouter.Application
├── LemonRouter.AgentProfiles (GenServer)
├── Registry: LemonRouter.RunRegistry
├── Registry: LemonRouter.SessionRegistry
├── Registry: LemonRouter.CoalescerRegistry
├── Registry: LemonRouter.ToolStatusRegistry
├── LemonRouter.RunSupervisor (DynamicSupervisor, max_children: 500)
│   └── LemonRouter.RunProcess (per-run GenServer, dynamic)
├── LemonRouter.CoalescerSupervisor (DynamicSupervisor)
│   └── LemonRouter.StreamCoalescer (per-session+channel, dynamic)
├── LemonRouter.ToolStatusSupervisor (DynamicSupervisor)
│   └── LemonRouter.ToolStatusCoalescer (per-session+channel, dynamic)
├── LemonRouter.RunCountTracker (GenServer)
├── LemonRouter.RunOrchestrator (GenServer)
└── Bandit (optional, Health HTTP server on port 4043)
```

## Dependencies

### Umbrella (in-app)

| Dependency | Role |
|------------|------|
| `lemon_core` | Shared types, config, PubSub bus, persistent store |
| `lemon_gateway` | AI engine gateway for run submission and event streaming |
| `lemon_channels` | Channel integrations (Telegram outbox, engine registry, truncation) |
| `coding_agent` | Coding agent session management and history |
| `agent_core` | Agent types and tool result structures |

### External

| Dependency | Role |
|------------|------|
| `bandit` | HTTP server for health check endpoint |
| `plug` | HTTP routing for health check |
| `jason` | JSON encoding for health check responses |

## Health Check

The health endpoint runs on port 4043 (configurable) and responds at `GET /healthz`:

```json
{
  "status": "ok",
  "checks": {
    "supervisor": "ok",
    "run_orchestrator": "ok",
    "run_supervisor": "ok"
  },
  "run_counts": {
    "active": 2,
    "queued": 0,
    "completed_today": 47
  }
}
```

Returns HTTP 200 when all checks pass, HTTP 503 otherwise.
