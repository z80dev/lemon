# Part 5: The Engine Room (lemon_gateway)

[< The Traffic Cop](04-the-traffic-cop.md) | [Next: The Agent >](06-the-agent.md)

---

`lemon_gateway` is where top-level AI work actually runs. It manages a pool of
execution slots and runs Lemon's native executor. Think of it as a machine shop
with one production machine, a foreman who assigns work (the Scheduler), and
workers who operate that machine one job at a time (ThreadWorkers).

## What lemon_gateway Does

1. **Manages concurrency** — limits how many top-level AI jobs run simultaneously
2. **Serializes per-conversation** — ensures messages in one conversation are
   processed in order
3. **Starts native execution** — runs the fixed Lemon executor for every
   supported top-level request
4. **Broadcasts events** — streams run events to the Bus for the router to pick up

---

## Native Top-Level Execution

Every supported gateway and channel route runs Lemon's native executor inside
the Elixir VM using `CodingAgent`. There is no top-level executor selection:
messages, bindings, profiles, configuration defaults, and resume metadata do
not choose a vendor CLI or an alternate backend.

The native executor provides:

- **Steering:** A queued message can be injected into the running native
  conversation mid-stream.
- **Gateway tools:** The gateway can inject tools that only work in this runtime,
  such as cron management, SMS inbox access, and Telegram image sending.
- **Full integration:** The executor has direct access to Lemon's tool ecosystem
  and the gateway's event lifecycle.

### Delegated Native Subagent Tasks

A native top-level conversation can delegate a bounded task to a subagent
through its `task` tool. Subagents run natively in-process: each delegated task
is a child `CodingAgent.Session` coordinated by `CodingAgent.Coordinator`,
managing its own progress and result. Subagents do not become gateway
executors, do not consume gateway top-level slots, and cannot be selected by a
message, binding, profile, or configuration default. There are no vendor CLI
subprocess runners.

A delegated task result may retain the subagent's identity and resume metadata.
That metadata belongs to the task record: it never resumes or routes a
top-level conversation.

### Native Resume and Historical Data

Only native `lemon` resume tokens can continue a top-level session. Historical
vendor tokens in chat state, message indexes, or run records remain readable so
operators can inspect history and roll back the migration. The routing path
quarantines them from explicit and automatic top-level resume selection and
never reinterprets them as native tokens.

---

## The Scheduling System

The gateway manages two constraints:
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

The `Run` GenServer is where one native execution happens. One Run exists per
active AI job. Here's what it does:

### Startup

1. Acquire a per-session FIFO lock as defense in depth against concurrent
   access to the same native session
2. Resolve the working directory
3. Emit a `run_started` event to the Bus
4. Start the fixed native executor with the resolved request

### During Execution

The native executor sends events to the Run process:
- `{:engine_event, ref, Event.started(...)}` — execution has started
- `{:engine_delta, ref, "text chunk"}` — streaming text output
- `{:engine_event, ref, Event.action_event(...)}` — tool-use notification
- `{:engine_event, ref, Event.completed(...)}` — execution is done

The Run process broadcasts each event to the Bus on the topic `"run:<run_id>"`:

```
Native executor ──events──> Run process ──broadcasts──> Bus ("run:<run_id>")
                                                          │
                                                          ├── RunProcess (router)
                                                          ├── WebSocket clients
                                                          └── Anyone else subscribed
```

### Completion

When execution finishes:
1. The Run saves the native resume token, if any, to `ChatStateStore`
2. Emits `run_completed` to the Bus
3. Notifies the ThreadWorker so it can release the slot
4. Stops itself

### Context Overflow

If the native executor reports that the conversation is too long (context
window exceeded), the Run clears the saved native resume token. The next
message starts a fresh native session, while the router's `CompactionTrigger`
saves a summary so context is not completely lost.

---

## Gateway-Injected Tools

When the native executor starts, the gateway injects extra tools that are only
available in the gateway context:

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

All transports follow the same pattern: normalize the inbound to a `RunRequest`,
submit via `RouterBridge`, and let the normal native pipeline handle the rest.
Each transport returns `:ignore` from its start function if not configured,
so missing credentials simply disable the transport rather than crashing.

---

## The Event Protocol

Here's the complete lifecycle of events for a single run:

```
1. run_started ──── Run is initializing
2. engine_started ── Native executor has been created
3. delta ──────── Text chunk (many of these, with seq numbers)
3. engine_action ── Tool use (optional, can have phases: started/output/completed)
3. ... (more deltas and actions as AI works)
4. engine_completed ── Native execution is done
5. run_completed ── Run is finalizing, includes full answer + status
```

Events 3 can repeat many times in any order — the AI might produce text, then
use a tool, then produce more text, then use another tool, etc.

All events are broadcast as plain maps (not Elixir structs) on the Bus. This
makes them safe to serialize, log, and pass between processes without coupling
to specific module definitions.

---

## Key Takeaways

1. **One native executor owns every top-level run** — channel and gateway
   requests cannot select a vendor CLI or another executor.
2. **Subagents are native in-process sessions** — delegated tasks run as child
   `CodingAgent.Session` executions; their identity and resume metadata stay
   with task results, outside top-level routing.
3. **Historical vendor resume data is preserved but quarantined** — it remains
   readable without becoming a supported top-level resume path.
4. **The Scheduler + ThreadWorker pattern** manages global concurrency while
   keeping per-conversation ordering.
5. **The Run process is the execution unit** — it starts native work, relays
   events to the Bus, saves native resume tokens, and cleans up.
6. **Gateway tools extend the native executor** — the gateway injects tools
   (cron, SMS, Telegram image sending) that only make sense in its context.

---

[Next: The Agent (coding_agent + agent_core) >](06-the-agent.md)
