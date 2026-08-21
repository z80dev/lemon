# Part 4: The Traffic Cop (lemon_router)

[< The Front Door](03-the-front-door.md) | [Next: The Engine Room >](05-the-engine-room.md)

---

`lemon_router` is the brain of the operation. It doesn't run AI or talk to
Telegram — it decides **who** handles a message, **how** it should be handled,
and **when** it should run. Think of it as an air traffic controller for AI
conversations.

## What lemon_router Does

1. **Resolves configuration** — which agent, model, tools, project, and working directory to use
2. **Manages sessions** — tracks conversation state, native resume tokens, and queue order
3. **Orchestrates native runs** — starts and monitors the one top-level executor
4. **Coalesces output** — buffers streaming text into deliverable chunks
5. **Routes delivery** — sends semantic intents to the right channel

---

## Sessions, Runs, and Conversations

These three concepts are central to how the router works:

### Session

A **session** is a persistent conversation thread. It has a **session key** that
uniquely identifies it:

```
agent:default:telegram:default:dm:123456789
  │       │       │         │    │      │
  │       │       │         │    │      └── your Telegram chat ID
  │       │       │         │    └── peer kind (dm, group, or channel)
  │       │       │         └── bot account
  │       │       └── which channel
  │       └── which agent profile
  └── prefix
```

Sessions persist across messages. When you send multiple messages to the same
Telegram chat, they all belong to the same session. The AI can build on previous
context because the session maintains a native resume token.

### Run

A **run** is a single prompt-to-response cycle. You send "What files are in my
home directory?" → the AI thinks, maybe uses some tools, and generates a
response. That's one run. A session contains many runs over time.

Each run has a unique `run_id` and is managed by its own `RunProcess`.

### Conversation Key

A **conversation key** groups runs that should be serialized (processed one at a
time). Usually it matches the session key. When a native resume token is active,
the conversation key incorporates that native session identity so all runs
continuing the same conversation go through the same queue even if they come
from different routes.

---

## The Orchestration Pipeline

When a message arrives from lemon_channels, it passes through a well-defined
pipeline:

### 1. Router.handle_inbound/1

The entry point. The Router:
- Resolves the session key (usually from metadata the channel adapter already computed)
- Checks for a **pending compaction** marker — if the previous conversation hit
  the AI's context window limit, a transcript summary is prepended to your
  message so the AI has context even though the raw history was truncated
- Wraps everything in a `RunRequest`

### 2. RunOrchestrator.submit/1

The orchestrator resolves all the configuration:

| What | How |
|------|-----|
| **Agent profile** | Looks up the agent ID (usually "default") in `AgentProfiles` |
| **Tool policy** | Layers: base policy → agent profile overrides → operator overrides |
| **Model** | Layers: request explicit → session preference → agent profile → system default |
| **Top-level execution** | Always uses Lemon's native executor; no request, binding, or profile selects another executor |
| **Resume token** | Auto-loads only the native token from `ChatStateStore`; historical vendor tokens remain readable but are quarantined from selection |
| **Working directory** | From the job, or a config default |

The result is a fully-resolved `ExecutionRequest` — everything the gateway needs
to actually run the AI.

### 3. SessionCoordinator

The SessionCoordinator is a per-conversation GenServer that serializes runs.
Only one run per conversation can be active at a time. If a new message arrives
while the AI is busy:

| Queue Mode | What Happens |
|------------|--------------|
| `:collect` | The message is held in a backlog. When the current run finishes, all collected messages are merged into a single follow-up prompt. |
| `:followup` | The message waits as a follow-up. When the current run finishes, it starts as the next run. A brief debounce window (500ms) merges rapid follow-ups. |
| `:steer` | The native executor receives the message in the running conversation mid-stream. |
| `:interrupt` | The current run is cancelled, and the new message starts immediately. |

The default mode is `:collect` — if you send messages while the AI is busy,
they're gathered up and delivered as one batch when it's free.

### 4. RunProcess

When it's time to run, a `RunProcess` GenServer is created. It:
- Submits the `ExecutionRequest` to the gateway
- Subscribes to the Bus for run events
- Delegates to focused submodules for different concerns

```
RunProcess
├── SurfaceManager ──── coordinates answer/status/task surfaces and fanout
├── ArtifactTracker ── tracks generated files and answer file metadata
├── Watchdog ──── idle-run timer (prompts user if AI goes silent too long)
├── CompactionTrigger ── detects context-window overflow
└── RetryHandler ──── auto-retries zero-answer failures
```

The RunProcess is short-lived — it exists only for the duration of one run and
stops itself on completion.

---

## Stream Coalescing

The AI doesn't generate text all at once. It produces tokens one or a few at a
time, which means the raw event stream is very chatty. Sending every token as a
separate Telegram message edit would be wasteful and visually jarring.

The **StreamCoalescer** buffers text chunks and flushes them at sensible
intervals:

- Flush when the buffer reaches **48+ characters**
- Flush after **400ms of idle** (no new tokens)
- Flush after **1200ms maximum latency** (even if characters keep coming)

This produces a smooth "typing" experience on Telegram — the message updates
every fraction of a second with meaningful new text rather than letter by letter.

Similarly, the **ToolStatusCoalescer** handles tool-use events, producing
updates like "Running `ls ~`..." that appear in Telegram while tools execute.
`SurfaceManager` sits above both coalescers and decides when assistant text
should hand off to a tool-status surface, when task-specific status messages
should be reused, and when the final answer should be fanned out to secondary
routes. `ArtifactTracker` keeps generated images and explicit file sends out of
the channel layer until the final answer metadata is ready.

Both coalescers emit **DeliveryIntents** rather than raw messages. A
DeliveryIntent is a semantic description ("stream snapshot of text X for
session Y") that the channels layer knows how to render for each platform.

---

## Agent Profiles

Lemon supports multiple **agent profiles**, each with its own personality,
tools, and model preferences. Profiles are defined in your `config.toml`:

```toml
[agents.default]
name = "Lemon"
description = "General-purpose assistant"

[agents.researcher]
name = "Research Bot"
description = "Focused on web research"
model = "gpt-5.4"
```

When a message arrives, the router looks up the agent ID (from the session key
or message metadata) and loads the corresponding profile. This is how you can
have different "personalities" in different Telegram chats.

---

## The Agent Directory

The **AgentDirectory** is a queryable registry of all known sessions. It merges
two data sources:

- **Active sessions** — currently running, held in memory
- **Historical sessions** — persisted in the run store across restarts

You can query it for things like:
- "What sessions exist for the default agent?"
- "What's the most recent session in this Telegram chat?"
- "What Telegram chats has Lemon ever talked in?"

This is used by the Agent Inbox (for programmatic message sending) and by
the control plane UI.

---

## Agent Inbox and Endpoints

The **AgentInbox** lets other parts of Lemon send messages to an agent
programmatically. For example, a cron job might send "Run the daily report"
to the default agent. The inbox resolves which session to use (latest existing,
or create a new one) and submits it through the normal orchestration pipeline.

**AgentEndpoints** are persistent named aliases for specific routes. Instead of
remembering `telegram:default:dm:-100123456:thread:42`, you can name it
`"ops-room"` and reference it by name when sending automated messages.

---

## Model Selection and Native Execution

The router has a multi-layered model-selection process:

```
1. Explicit in the request
2. Session/meta preference
3. Agent profile preference
4. System default
```

Every supported top-level route uses the native Lemon executor. Messages,
bindings, agent profiles, and persisted session preferences cannot select a
vendor CLI or another executor.

Native resume tokens can continue native sessions. Historical vendor tokens
remain readable in session history and persisted state for rollback and
diagnostics, but the router quarantines them from explicit and automatic
top-level resume selection rather than treating them as native sessions.

Vendor CLIs remain available as delegated task subagents. A task result can
retain its runner identity and vendor resume metadata, but that metadata never
routes or resumes a top-level conversation.

---

## Failure Handling

The router handles several failure scenarios:

| Scenario | What Happens |
|----------|--------------|
| **AI goes silent** | Watchdog timer fires after configurable idle period, prompts user to continue or cancel |
| **Context overflow** | CompactionTrigger detects the error, clears the native resume token so the next run starts fresh, marks pending compaction |
| **Zero-answer failure** | RetryHandler automatically retries the run once |
| **Gateway process dies** | RunProcess detects the `:DOWN` signal and synthesizes a failure event so the session doesn't get stuck |
| **RunProcess itself dies** | SessionCoordinator detects the `:DOWN`, releases the queue, starts the next pending run |

The guiding principle is: **never leave a session stuck.** If something goes
wrong, clean up and make the session available for the next message.

---

## Key Takeaways

1. **The router is the orchestration layer** — it resolves route scope and coordinates native AI work.
2. **Sessions are the unit of conversation** — they persist across messages
   and maintain continuity via native resume tokens; historical vendor tokens remain quarantined from top-level use.
3. **Only one run per conversation at a time** — the SessionCoordinator
   serializes runs and manages the queue.
4. **Stream coalescing makes streaming smooth** — raw token events are buffered
   into meaningful chunks before being sent to Telegram.
5. **DeliveryIntents are semantic, not mechanical** — the router says "show
   this text" and the channel decides how.
6. **Multiple failure recovery mechanisms** — watchdog, retry, compaction, and
   process monitoring ensure conversations never get permanently stuck.

---

[Next: The Engine Room (lemon_gateway) >](05-the-engine-room.md)
