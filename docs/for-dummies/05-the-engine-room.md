# Part 5: The Engine Room (lemon_gateway)

[< The Traffic Cop](04-the-traffic-cop.md) | [Next: The Agent >](06-the-agent.md)

---

`lemon_gateway` is where the AI actually runs. It manages a pool of execution
slots, selects the right AI engine, and runs the work. Think of it as a machine
shop with multiple types of machines (engines), a foreman who assigns work
(Scheduler), and workers who operate the machines one job at a time
(ThreadWorkers).

## What lemon_gateway Does

1. **Manages concurrency** — limits how many AI jobs run simultaneously
2. **Serializes per-conversation** — ensures messages in one conversation are
   processed in order
3. **Selects and starts engines** — picks the right AI backend and kicks it off
4. **Broadcasts events** — streams run events to the Bus for the router to pick up

---

## The Six Engines

An **engine** is a pluggable AI backend. Every engine implements the same
interface (the `Engine` behaviour), so the rest of the system doesn't care which
one is running underneath.

| Engine | What It Is | How It Works |
|--------|-----------|--------------|
| **lemon** | Native Lemon engine | Runs entirely inside the Elixir VM using CodingAgent |
| **claude** | Claude Code CLI | Spawns the `claude` CLI as a subprocess |
| **codex** | OpenAI Codex CLI | Spawns the `codex` CLI as a subprocess |
| **opencode** | OpenCode CLI | Spawns the `opencode` CLI as a subprocess |
| **pi** | Pi CLI | Spawns the `pi` CLI as a subprocess |
| **echo** | Test engine | Echoes the prompt back (for testing only) |

### Native Lemon vs. CLI Engines

The **native Lemon engine** is special. It runs Lemon's own `CodingAgent`
inside the Elixir VM — no subprocess, no external tool. This gives it
superpowers:

- **Steering:** You can inject messages into a running conversation mid-stream
  (the only engine that supports this)
- **Gateway tools:** Extra tools are injected that only work in the gateway
  context (cron management, SMS inbox, Telegram image sending)
- **Full integration:** Direct access to Lemon's tool ecosystem (30+ tools)

The **CLI engines** are thin wrappers around external command-line AI tools.
Each one:
1. Spawns the CLI binary as an OS subprocess
2. Consumes its stdout (JSON lines format)
3. Translates the CLI's events into Lemon's standard event format
4. Sends those events back to the gateway

The advantage of CLI engines is that you can use any AI tool that has a CLI
without Lemon needing to implement it natively. The disadvantage is less
integration — they can't be steered, and they don't get gateway tools.

### Engine Selection

Engine selection follows a priority chain:

```
Resume token engine (continue with same engine)
    ↓ if none
Explicit directive ("/claude fix this")
    ↓ if none
Chat binding (this chat always uses Claude)
    ↓ if none
Config default (defaults to "lemon")
```

Composite IDs like `"claude:claude-3-opus"` are split — the prefix `"claude"`
identifies the engine, and the rest identifies the model within that engine.

---

## The Scheduling System

The gateway needs to manage two constraints:
1. **Global concurrency:** Don't run too many AI jobs at once (default limit: 10)
2. **Per-conversation ordering:** Messages in one conversation must be processed
   sequentially

### The Scheduler

The `Scheduler` is a single GenServer that manages a pool of execution slots.
When a run request arrives:

1. It derives a **thread key** from the conversation key
2. It finds or creates a `ThreadWorker` for that thread key
3. It sends the request to the ThreadWorker

The Scheduler tracks:
- `in_flight` — which slots are currently occupied
- `waitq` — which ThreadWorkers are waiting for a slot

### The ThreadWorker

Each active conversation gets its own `ThreadWorker` GenServer. The
ThreadWorker's job is simple:

1. Hold a FIFO queue of requests for this conversation
2. When a request is ready and no run is active, request a slot from the
   Scheduler
3. When a slot is granted, start the Run process
4. When the Run completes, release the slot and process the next request
5. When the queue is empty and no run is active, shut down

```
Scheduler (global, one instance)
├── ThreadWorker (conversation A)
│   └── Run (active job)
├── ThreadWorker (conversation B)
│   └── [waiting for slot]
└── ThreadWorker (conversation C)
    └── Run (active job)
```

This design means:
- Two different users can have AI running simultaneously (up to the global limit)
- One user's messages are always processed in order
- ThreadWorkers are created on demand and cleaned up when idle

### Stale Request Timeout

If a ThreadWorker waits more than 30 seconds for a slot (because all slots are
full), the request times out and is cleaned up. This prevents unbounded queue
growth under heavy load.

---

## The Run Process

The `Run` GenServer is where execution actually happens. One Run exists per
active AI job. Here's what it does:

### Startup

1. Look up the engine module from the `EngineRegistry`
2. Acquire an **engine lock** for this session (a FIFO mutex that prevents two
   runs from operating on the same session simultaneously — defense in depth)
3. Resolve the working directory
4. Emit a `run_started` event to the Bus
5. Call `engine.start_run(job, opts, self())` — this kicks off the engine

### During Execution

The engine sends events to the Run process:
- `{:engine_event, ref, Event.started(...)}` — engine has started
- `{:engine_delta, ref, "text chunk"}` — streaming text output
- `{:engine_event, ref, Event.action_event(...)}` — tool use notification
- `{:engine_event, ref, Event.completed(...)}` — engine is done

The Run process broadcasts each event to the Bus on the topic `"run:<run_id>"`:

```
Engine  ──events──>  Run process  ──broadcasts──>  Bus ("run:<run_id>")
                                                      │
                                                      ├── RunProcess (router)
                                                      ├── WebSocket clients
                                                      └── Anyone else subscribed
```

### Completion

When the engine finishes:
1. The Run saves the **resume token** (if any) to `ChatStateStore` — this lets
   the next message continue the AI conversation
2. Emits `run_completed` to the Bus
3. Notifies the ThreadWorker so it can release the slot
4. Stops itself

### Context Overflow

If the AI reports that the conversation is too long (context window exceeded),
the Run clears the saved resume token. This means the next message will start
a fresh conversation. The router's CompactionTrigger will save a summary of the
old conversation so context isn't completely lost.

---

## The Engine Interface

Every engine must implement these callbacks:

| Callback | Purpose |
|----------|---------|
| `id/0` | Returns the engine name (e.g., `"claude"`) |
| `start_run/3` | Starts an AI run, returns `{:ok, ref, cancel_ctx}` |
| `cancel/1` | Kills a running job |
| `supports_steer?/0` | Can this engine accept mid-run messages? |
| `steer/2` | Inject a message into a running conversation |
| `format_resume/1` | Convert a resume token to CLI flags |
| `extract_resume/1` | Parse engine output for a resume token |

The important insight is that **engines are event producers**. They don't return
a final answer — they stream events to a sink process (the Run). This is what
enables real-time streaming all the way to Telegram.

---

## Gateway-Injected Tools

When the native Lemon engine starts, the gateway injects extra tools that are
only available in the gateway context:

| Tool | What It Does |
|------|-------------|
| `Cron` | Create, list, and manage scheduled/recurring tasks |
| `SmsGetInboxNumber` | Get the Twilio phone number for SMS |
| `SmsWaitForCode` | Wait for and capture an SMS verification code |
| `SmsListMessages` | List received SMS messages |
| `SmsClaimMessage` | Claim/acknowledge a received SMS |
| `TelegramSendImage` | Send an image to a Telegram chat (only for Telegram sessions) |

These tools don't exist in the base CodingAgent — they're added by the gateway
because they only make sense when running in a gateway context (where Telegram
and SMS transports are available).

---

## Other Transports (Brief)

While Telegram is the primary way to use Lemon, the gateway also hosts several
other inbound transports:

| Transport | How It Works |
|-----------|-------------|
| **SMS (Twilio)** | HTTP webhook server, validates Twilio HMAC signatures |
| **Voice (Twilio + Deepgram)** | WebSocket audio streaming, speech-to-text, text-to-speech |
| **Email** | Inbound via SMTP/webhook |
| **Webhook** | Generic HTTP endpoint for integrations (Zapier, n8n, Make.com) |
| **Farcaster** | Social protocol integration |

All transports follow the same pattern: normalize the inbound to a `RunRequest`,
submit via `RouterBridge`, and let the normal pipeline handle the rest.
Each transport returns `:ignore` from its start function if not configured,
so missing credentials simply disable the transport rather than crashing.

---

## The Event Protocol

Here's the complete lifecycle of events for a single run:

```
1. run_started ──── Run is initializing
2. engine_started ── Engine has been created
3. delta ──────── Text chunk (many of these, with seq numbers)
3. engine_action ── Tool use (optional, can have phases: started/output/completed)
3. ... (more deltas and actions as AI works)
4. engine_completed ── Engine is done
5. run_completed ── Run is finalizing, includes full answer + status
```

Events 3 can repeat many times in any order — the AI might produce text, then
use a tool, then produce more text, then use another tool, etc.

All events are broadcast as plain maps (not Elixir structs) on the Bus. This
makes them safe to serialize, log, and pass between processes without coupling
to specific module definitions.

---

## Key Takeaways

1. **Engines are pluggable backends** — the native Lemon engine runs in-process,
   CLI engines spawn subprocesses, but they all produce the same event stream.
2. **The Scheduler + ThreadWorker pattern** manages global concurrency while
   keeping per-conversation ordering.
3. **The Run process is the execution unit** — it starts the engine, relays
   events to the Bus, saves resume tokens, and cleans up.
4. **Events, not return values** — engines stream events to a sink rather than
   returning a final result. This is what enables end-to-end streaming.
5. **Gateway tools extend the native engine** — the gateway injects extra tools
   (cron, SMS, Telegram image sending) that only make sense in its context.

---

[Next: The Agent (coding_agent + agent_core) >](06-the-agent.md)
