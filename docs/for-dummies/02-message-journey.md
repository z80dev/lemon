# Part 2: Your Message's Journey

[< The Big Picture](01-big-picture.md) | [Next: The Front Door >](03-the-front-door.md)

---

This is the "follow the bouncing ball" chapter. We'll trace a single message
from the moment you tap Send on Telegram to the moment the AI's response
appears on your screen. Every step is real — this is exactly what happens inside
Lemon.

## The Scenario

You open Telegram on your phone and send this message to your Lemon bot:

> What files are in my home directory?

Let's follow it.

---

## Step 1: Telegram Delivers the Message

Telegram's servers receive your message and hold it. Meanwhile, Lemon's Telegram
adapter is running a polling loop — every second or so, it asks Telegram
"any new messages?" via the `getUpdates` API.

Telegram responds with your message as a JSON blob:

```
Telegram servers  ----HTTP response---->  lemon_channels (Telegram.Transport)
```

**Where we are:** `lemon_channels` — the Telegram transport's polling loop.

---

## Step 2: The Message Gets Normalized

Your message arrived as Telegram-specific JSON (with `chat_id`, `update_id`,
Telegram-flavored fields, etc.). The adapter converts it into a universal
`InboundMessage` — Lemon's standard format that works regardless of whether
the message came from Telegram, Discord, SMS, or anywhere else.

The normalized message contains:
- **Who sent it:** your Telegram user ID and username
- **Where it came from:** channel=telegram, peer=dm with your chat ID
- **The text:** "What files are in my home directory?"
- **Metadata:** timestamps, message IDs, etc.

**Where we are:** Still in `lemon_channels`, specifically `Telegram.Inbound.normalize/1`.

---

## Step 3: Authorization and Deduplication

Before going further, the adapter checks:

- **Is this chat allowed?** (Your chat ID must be in the allow-list in config)
- **Have we already seen this update?** (Telegram can re-deliver; duplicates are
  dropped via an ETS-based dedup cache with a 10-minute window)

If either check fails, the message is silently dropped. Yours passes.

**Where we are:** `lemon_channels`, `Telegram.Transport.UpdateProcessor`.

---

## Step 4: The Bouncing Ball Reaction

The adapter sends a reaction on your message in Telegram. You'll see a little
eyes emoji (👀) appear on your message — this is Lemon's way of saying "got it,
working on it."

---

## Step 5: Session Key Resolution

The adapter figures out which conversation this message belongs to by building
a **session key** — a string that uniquely identifies this conversation thread.
For a DM with the default agent, it looks something like:

```
agent:default:telegram:default:dm:123456789
```

This key stays the same across all your messages in this chat, so the AI can
maintain a continuous conversation with you.

**Where we are:** Still in `lemon_channels`, `Telegram.Transport.submit_inbound_now/2`.

---

## Step 6: Hand-off to the Router

The adapter calls `RouterBridge.handle_inbound(inbound_message)`. This is the
boundary between `lemon_channels` and `lemon_router`.

The RouterBridge is a clever indirection — it lets channels talk to the router
without being directly wired to it. If the router isn't running for some reason,
the bridge returns `{:error, :unavailable}` instead of crashing.

```
lemon_channels  ----RouterBridge---->  lemon_router
```

**Where we are:** Crossing into `lemon_router`.

---

## Step 7: The Router Builds a Run Request

The router receives your `InboundMessage` and converts it into a `RunRequest` —
the formal "please run the AI" request. It attaches:

- The session key
- The agent ID ("default")
- Your prompt text
- The origin (`:channel`)
- Queue mode (how to handle this if the AI is already busy)

**Where we are:** `lemon_router`, `Router.handle_inbound/1`.

---

## Step 8: Run Orchestration

The `RunOrchestrator` takes your `RunRequest` and resolves all the configuration
needed to actually run the AI:

1. **Agent profile** — looks up "default" agent's config (system prompt,
   tools, etc.)
2. **Engine selection** — which AI engine to use (e.g., "lemon" native engine)
3. **Model selection** — which specific LLM model (e.g., claude-sonnet-4)
4. **Resume token** — checks if there's a previous conversation to continue
5. **Tool policy** — which tools the AI is allowed to use
6. **Working directory** — where file operations are rooted

All of this gets packaged into an `ExecutionRequest`.

**Where we are:** `lemon_router`, `RunOrchestrator.submit/1`.

---

## Step 9: Session Coordination (The Queue)

Before the run can start, the `SessionCoordinator` checks: is this conversation
already running an AI job? Only one run per conversation can be active at a
time.

- If the AI is idle: the run starts immediately.
- If the AI is busy: the message is queued, and depending on the queue mode,
  it might be held as a follow-up, merged with pending messages, or it might
  interrupt the current run.

Your conversation is idle, so we proceed.

**Where we are:** `lemon_router`, `SessionCoordinator`.

---

## Step 10: The Gateway Takes Over

A `RunProcess` is created and it submits the `ExecutionRequest` to the gateway:

```
lemon_router (RunProcess)  ---->  lemon_gateway (Runtime.submit_execution)
```

The gateway's **Scheduler** receives the request. It manages a pool of execution
slots (default: 10 concurrent runs across all conversations). It finds or
creates a **ThreadWorker** for your conversation.

The ThreadWorker is a per-conversation serializer — it ensures your messages are
processed in order, one at a time. It requests a slot from the Scheduler, and
when granted, starts a **Run** process.

**Where we are:** `lemon_gateway`, `Scheduler` + `ThreadWorker`.

---

## Step 11: Engine Start

The `Run` process:
1. Looks up the engine module (e.g., `Engines.Lemon` for the native engine)
2. Acquires an engine lock for your session (prevents double-runs)
3. Calls `engine.start_run(job, opts, self())` — this kicks off the actual AI

For the native Lemon engine, this starts a `CodingAgent` session inside the
Elixir VM. For CLI engines like Claude or Codex, this would spawn an external
subprocess.

```
lemon_gateway (Run)  ---->  coding_agent + agent_core
```

**Where we are:** `lemon_gateway`, `Run` GenServer.

---

## Step 12: The Agent Loop

Now we're in the heart of Lemon. The `AgentCore.Loop` starts:

1. **Build the context** — your message + conversation history + system prompt
2. **Call the LLM** — sends everything to Claude (or whatever model is
   configured) via the `ai` package
3. **Stream the response** — as Claude generates text, tokens flow back as events

The AI decides it needs to run a command to answer your question, so it makes
a **tool call** — it asks to use the `bash` tool with the command `ls ~`.

**Where we are:** `agent_core`, `Loop` + `Loop.Streaming`.

---

## Step 13: Tool Execution

The `bash` tool runs `ls ~` on your machine. The output streams back as tool
result events. The result is appended to the conversation context, and the
agent loop goes back to step 12 — another LLM call, this time with the
directory listing included.

Claude now has the answer. It generates a response like:
> "Here are the files in your home directory: Documents, Downloads, ..."

This time there are no tool calls, so the agent loop finishes.

**Where we are:** `agent_core`, `Loop.ToolCalls`.

---

## Step 14: The Response Streams Back

As the AI generates each chunk of text, events flow back through the layers:

```
ai (EventStream) → agent_core (Loop) → lemon_gateway (Run) → Bus → lemon_router (RunProcess)
```

The `RunProcess` feeds text chunks into the **StreamCoalescer**, which
buffers them into coherent pieces (it waits until it has at least 48
characters, or 400ms have passed, whichever comes first).

**Where we are:** `lemon_router`, `StreamCoalescer`.

---

## Step 15: Delivery to Telegram

The StreamCoalescer emits a `DeliveryIntent` — a semantic description of what
to show the user. The `Dispatcher` routes it to the Telegram renderer.

The Telegram renderer uses a clever **send-then-edit** strategy:
- First chunk: sends a new message in your Telegram chat
- Subsequent chunks: edits that same message with the updated text
- Final chunk: one last edit with the complete response

This is why you see the message "grow" in real-time on Telegram.

```
lemon_router (StreamCoalescer)
    → lemon_channels (Dispatcher)
        → Telegram Renderer
            → Outbox (rate limiting, chunking, dedup)
                → Telegram Bot API
                    → Your phone
```

**Where we are:** `lemon_channels`, `Dispatcher` → `Outbox` → Telegram API.

---

## Step 16: Cleanup

Once the run completes:
- The **resume token** is saved so the next message can continue this
  conversation thread
- The `RunProcess` stops itself
- The `ThreadWorker` releases its execution slot
- The session is marked as idle, ready for your next message

---

## The Complete Journey (Summary)

```
Your phone (Telegram)
  │
  ▼
lemon_channels ─── Telegram polling picks up your message
  │                 Normalizes to InboundMessage
  │                 Checks auth, deduplicates
  │                 Sends 👀 reaction
  │                 Resolves session key
  │
  ▼
lemon_router ───── Builds RunRequest
  │                 Orchestrator resolves config (engine, model, tools)
  │                 SessionCoordinator queues the run
  │                 RunProcess created
  │
  ▼
lemon_gateway ──── Scheduler assigns an execution slot
  │                 ThreadWorker starts the Run
  │                 Engine is selected and started
  │
  ▼
agent_core ─────── Agent loop begins
  │                 Context built (history + system prompt + tools)
  │
  ▼
ai ────────────── LLM API call (e.g., Claude)
  │                 Streaming response
  │                 Tool call detected → bash tool → ls ~
  │                 Second LLM call with tool result
  │                 Final text response streamed
  │
  ▲ (responses flow back up)
  │
lemon_gateway ──── Run broadcasts events to the Bus
  │
  ▲
  │
lemon_router ───── RunProcess receives events
  │                 StreamCoalescer buffers text chunks
  │                 Emits DeliveryIntents
  │
  ▲
  │
lemon_channels ─── Dispatcher → Telegram Renderer
  │                 Outbox handles rate limiting
  │                 Sends/edits Telegram message
  │
  ▼
Your phone (Telegram) ── response appears, growing in real-time
```

**Total time:** Usually 2-10 seconds for the first text to appear, depending on
the AI model's speed. The internal routing/scheduling overhead is negligible
(milliseconds).

---

## Key Takeaways

1. **Every layer has one job** — channels handle platforms, router handles
   orchestration, gateway handles execution, agent handles thinking.
2. **Streaming is end-to-end** — you see the AI "typing" because every layer
   passes events through as they happen, not waiting for completion.
3. **The Bus is the nervous system** — the event bus (PubSub) connects the
   gateway's output to the router's delivery pipeline without tight coupling.
4. **Sessions persist across messages** — your conversation continues naturally
   because resume tokens and session keys track state.

---

[Next: The Front Door (lemon_channels) >](03-the-front-door.md)
