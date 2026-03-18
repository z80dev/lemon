# Part 3: The Front Door (lemon_channels)

[< Your Message's Journey](02-message-journey.md) | [Next: The Traffic Cop >](04-the-traffic-cop.md)

---

`lemon_channels` is the part of Lemon that talks to the outside world. It
handles Telegram, Discord, X/Twitter, XMTP, and WhatsApp. For this guide,
we'll focus on Telegram since that's the primary way to use Lemon day-to-day.

## What lemon_channels Does

Three things, and only three things:

1. **Receives messages** from Telegram, converts them to a standard format,
   and forwards them to the router
2. **Renders responses** from the router into Telegram-appropriate messages
3. **Delivers those messages** reliably, with rate limiting, chunking, and
   retry logic

It doesn't decide what to do with your message — that's the router's job. It
doesn't run AI — that's the gateway's job. It's purely a translator between
Telegram's world and Lemon's world.

---

## The Plugin System

Each messaging platform is a **plugin** that implements a standard interface.
Adding a new platform means writing a new plugin without changing any other
part of Lemon. WhatsApp, for example, was added this way — it is a fully
separate adapter that runs alongside XMTP, each serving its own messaging
service independently.

Current plugins:
- **Telegram** — the primary one, fully featured
- **Discord** — via the Nostrum library
- **X/Twitter** — posting and mention monitoring
- **XMTP** — decentralized messaging (via an external JS bridge)
- **WhatsApp** — messaging via a Node.js bridge; coexists alongside XMTP as a
  separate adapter for a different service (they do not replace each other)

Each plugin provides:
- An ID (e.g., `"telegram"`)
- A way to normalize incoming messages
- A way to deliver outgoing messages
- Optional gateway methods for the control plane

---

## Inbound: How Messages Arrive

### Polling (Not Webhooks)

Lemon uses Telegram's **long-polling** API rather than webhooks. This means
Lemon doesn't need a public URL or SSL certificate — it just asks Telegram
"any new messages?" in a loop.

The `Telegram.Transport` GenServer sends itself a `:poll` message every second.
The poller calls Telegram's `getUpdates` endpoint and processes whatever comes
back.

### The Normalization Pipeline

When a Telegram update arrives, it goes through several steps:

```
Raw Telegram JSON
    │
    ▼
Inbound.normalize/1 ──── Converts to InboundMessage struct
    │                      (channel_id, peer, sender, message, meta)
    │
    ▼
UpdateProcessor.prepare_inbound/4 ── Adds account_id, update_id
    │
    ▼
Voice transcription (if applicable) ── Converts audio to text
    │
    ▼
Authorization check ──── Is this chat in the allow-list?
    │
    ▼
Deduplication ──── Have we seen this update_id before? (10-min ETS cache)
    │
    ▼
CommandRouter ──── Is this a /command or a regular message?
```

### The InboundMessage

After normalization, your Telegram message becomes a standard `InboundMessage`:

```
%InboundMessage{
  channel_id: "telegram",
  account_id: "default",
  peer: %{kind: :dm, id: "123456789", thread_id: nil},
  sender: %{id: "123456789", username: "yourname", display_name: "You"},
  message: %{id: "42", text: "What files are in my home directory?", timestamp: 1710000000},
  meta: %{chat_id: 123456789, ...},
  raw: %{...the original Telegram JSON...}
}
```

This struct is the same regardless of whether the message came from Telegram,
Discord, or any other channel. Everything downstream only works with this
standardized format.

### Bot Commands

If your message starts with a slash command, the `CommandRouter` handles it
specially:

| Command | What It Does |
|---------|--------------|
| `/new` | Starts a fresh conversation (clears resume token) |
| `/resume` | Lists and resumes previous sessions |
| `/model` | Changes the AI model for this chat |
| `/cancel` | Cancels the currently running AI task |
| `/claude`, `/codex`, `/pi`, etc. | Routes to a specific AI engine |

Regular messages (no slash command) go through a **message buffer** — a 1-second
debounce window that coalesces rapid-fire messages into a single prompt. If you
send three messages in quick succession, Lemon combines them into one prompt
instead of creating three separate AI runs.

---

## Outbound: How Responses Get Delivered

The outbound path has two layers: a semantic layer (what to show) and a
mechanical layer (how to deliver it).

### The Semantic Layer: DeliveryIntents

The router doesn't send raw Telegram messages. Instead, it sends
**DeliveryIntents** — abstract descriptions of what the user should see:

- `stream_snapshot` — "here's the latest chunk of streaming text"
- `stream_finalize` — "the response is complete, here's the final text"
- `tool_status_snapshot` — "the AI is currently using these tools..."
- `tool_status_finalize` — "tool execution is done"
- `final_text` — "here's a complete one-shot response"
- `file_batch` — "here are some files to send"

The `Dispatcher` receives these intents and routes them to the right renderer
based on the channel. The Telegram renderer knows how to turn these into
actual Telegram API calls.

### The Send-Then-Edit Pattern

When the AI is streaming its response, Telegram can't show a "typing indicator"
that updates in real-time. Instead, the renderer uses a clever pattern:

1. **First chunk arrives:** Send a new Telegram message with the partial text
2. **More chunks arrive:** Edit that same message with the updated text
3. **Response complete:** One final edit with the complete text

The `PresentationState` module tracks which message ID corresponds to which
streaming session, so it knows whether to send a new message or edit an
existing one.

### The Outbox

The `Outbox` is a GenServer that handles all the mechanical complexity of
actually delivering messages to Telegram:

```
DeliveryIntent
    │
    ▼
Renderer ──── Converts intent to OutboundPayload(s)
    │
    ▼
Outbox.enqueue/1
    │
    ├── Idempotency check (have we already sent this?)
    ├── Chunking (split messages > 4096 chars at sentence boundaries)
    ├── Rate limiting (token bucket: 30 msg/sec for Telegram)
    └── Per-group FIFO (messages to the same chat are ordered)
    │
    ▼
Telegram Bot API ──── HTTP POST
    │
    ▼
Your phone
```

Key properties of the Outbox:

- **Idempotency:** Each payload has a unique key. If the same key is submitted
  twice (e.g., due to a retry), the duplicate is dropped.
- **Chunking:** Telegram has a 4096-character limit per message. Long responses
  are automatically split at sentence or word boundaries.
- **Rate limiting:** A token bucket prevents Telegram from rate-limiting the bot.
  Default: 30 messages per second.
- **Ordered delivery:** Messages to the same chat are sent in order, one at a
  time. Different chats can be delivered concurrently.
- **Retry with backoff:** Failed deliveries are retried up to 3 times with
  exponential backoff (1s, 2s, 4s). Telegram's `429` responses respect the
  `retry_after` field.

---

## The Connection to the Router

lemon_channels connects to lemon_router through `RouterBridge` — a runtime
bridge in lemon_core. This is an important design choice: there's **no
compile-time dependency** between channels and the router.

```
lemon_channels ──RouterBridge──> lemon_router
                 (runtime only)
```

Why does this matter? It means:
- Channels can start even if the router hasn't started yet
- If the router crashes and restarts, channels keep running
- The two apps can be developed and tested independently

The bridge works by having the router register itself at startup:
`RouterBridge.configure(router: LemonRouter.Router, ...)`. Channels then call
`RouterBridge.handle_inbound(msg)`, which dynamically looks up and calls the
registered router module.

---

## State Management

The Telegram adapter maintains several pieces of state in ETS (in-memory)
tables:

| Store | What It Tracks |
|-------|----------------|
| `StateStore` | Per-session model and thinking preferences |
| `ResumeIndexStore` | Maps message IDs to session keys (for reply-based routing) |
| `KnownTargetStore` | Metadata about known Telegram chats |
| `TriggerMode` | Per-chat trigger mode (`:all` vs `:mentions`) |
| `OffsetStore` | The last processed Telegram update ID |

The `OffsetStore` is particularly important: when Lemon restarts, it reads
the last offset from persistent storage so it doesn't reprocess old messages.

---

## Supervision Tree

If you're curious about how the Telegram adapter stays alive:

```
LemonChannels.Application
├── Registry (plugin registry)
├── PresentationState (message ID tracking)
├── Outbox.RateLimiter (token bucket)
├── Outbox.Dedupe (idempotency cache)
├── Outbox.WorkerSupervisor (delivery task pool)
├── Outbox (the delivery queue)
└── AdapterSupervisor (DynamicSupervisor)
    └── Telegram.Supervisor (if Telegram is enabled)
        ├── Telegram.AsyncSupervisor (task pool)
        └── Telegram.Transport (the polling loop)
```

If the Transport crashes (say, due to a network error), its supervisor
restarts it. The Outbox, rate limiter, and dedup cache are independent — a
crash in delivery doesn't affect message reception and vice versa.

---

## Key Takeaways

1. **lemon_channels is a translator** — it converts between platform-specific
   formats and Lemon's internal format, nothing more.
2. **The Outbox handles all delivery complexity** — rate limiting, chunking,
   ordering, retries, and idempotency are all handled in one place.
3. **The send-then-edit pattern** enables real-time streaming in Telegram,
   which doesn't natively support it.
4. **No compile-time coupling to the router** — the RouterBridge pattern keeps
   channels and routing independently deployable and testable.
5. **The message buffer** coalesces rapid messages — Lemon is smart about not
   creating separate AI runs for quickly-typed messages.

---

[Next: The Traffic Cop (lemon_router) >](04-the-traffic-cop.md)
