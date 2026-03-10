# Part 1: The Big Picture

[< Table of Contents](README.md) | [Next: Your Message's Journey >](02-message-journey.md)

---

## What Is Lemon?

Lemon is an AI assistant that runs on your own computer. You talk to it through
Telegram (or other channels), and it can do things like read and write code, run
shell commands, search the web, manage files, and hold ongoing conversations
with memory of past interactions.

Think of it like having ChatGPT, but:

- It runs **locally** on your machine (your data never leaves unless you send
  it to an AI provider)
- It can **do things** on your computer (not just chat)
- It supports **multiple AI backends** (Claude, GPT, Gemini, Codex, and more)
- It **remembers** across conversations
- You interact with it from your **phone** via Telegram

The name comes from a very good cat.

---

## The Cast of Characters

Lemon is built as a collection of cooperating applications (called an "umbrella"
in Elixir). Each app has one job. Here are the ones that matter for the
Telegram personal assistant use case:

```
You, on Telegram
      |
      v
+-----------------+
| lemon_channels  |  "The Front Door"
|  Telegram bot   |  Receives your messages, delivers responses
+-----------------+
      |
      v
+-----------------+
| lemon_router    |  "The Traffic Cop"
|  Routing &      |  Figures out which agent and session to use,
|  orchestration  |  queues runs, manages conversation state
+-----------------+
      |
      v
+-----------------+
| lemon_gateway   |  "The Engine Room"
|  Engine mgmt &  |  Picks an AI engine, manages concurrency,
|  execution      |  runs the actual AI work
+-----------------+
      |
      v
+-----------------+     +-----------------+
| agent_core      |     | coding_agent    |
| "The Runtime"   |     | "The Personality"|
| Generic agent   |<--->| 30+ tools,      |
| loop & events   |     | sessions, memory|
+-----------------+     +-----------------+
      |
      v
+-----------------+
| ai              |  "The Translator"
|  Provider       |  Talks to Claude, GPT, Gemini, etc.
|  abstraction    |  using their native APIs
+-----------------+
      |
      v
  Claude / GPT / Gemini / etc.
```

And sitting underneath all of them:

```
+-----------------+
| lemon_core      |  "The Foundation"
|  Config, store, |  Shared config, storage, the event bus,
|  PubSub bus     |  and all the data structures everyone uses
+-----------------+
```

---

## How the Parts Fit Together

The key insight is that **messages flow down, responses flow up**:

1. Your Telegram message enters at the top (lemon_channels)
2. It gets routed and queued (lemon_router)
3. An engine runs the AI work (lemon_gateway)
4. The agent thinks, uses tools, and calls the LLM (agent_core + coding_agent + ai)
5. The response streams back up through the same layers
6. It appears on your phone as a Telegram message

The response doesn't wait until the AI is completely done. It **streams** —
you'll see the message appear and grow in real-time on Telegram, just like
watching someone type.

---

## Why So Many Layers?

You might wonder: why not just have one app that reads Telegram messages and
talks to Claude?

The layered design gives Lemon some powerful properties:

- **Swap AI providers freely.** Switch from Claude to GPT by changing one config
  line. The rest of the system doesn't care.
- **Multiple frontends.** Telegram today, Discord tomorrow, a web UI, a
  terminal UI — they all plug into the same router.
- **Concurrency without chaos.** Multiple conversations can run simultaneously
  without stepping on each other. The gateway manages slots, the router manages
  queues.
- **Fault isolation.** If one conversation crashes, the others keep running.
  Each conversation is an isolated process.
- **Streaming everywhere.** Every layer passes events as they happen, so you see
  the AI "typing" in real-time rather than waiting for the full response.

---

## The BEAM: Why Elixir?

Lemon is written in Elixir, which runs on the BEAM virtual machine (the same VM
that powers Erlang and WhatsApp). You don't need to know Elixir to use Lemon,
but it helps to understand two concepts that come up throughout the system:

### Processes

In the BEAM, a "process" is a lightweight isolated unit of work (not an OS
process — more like a goroutine or green thread, but with its own memory).
Lemon creates a process for each conversation, each running AI job, each tool
execution, etc. If one crashes, the others are unaffected.

### Message Passing

BEAM processes communicate by sending messages to each other (like actors in the
actor model). When the AI produces a text chunk, it sends a message to the
router process, which sends a message to the Telegram process, which sends an
HTTP request to Telegram's API. This is the "event bus" you'll see mentioned
throughout the guide.

---

## What About the Other Apps?

The Lemon umbrella has several other apps that we won't cover in depth:

| App | What It Does |
|-----|--------------|
| lemon_control_plane | HTTP/WebSocket API for the TUI and web clients |
| lemon_automation | Scheduled cron jobs and heartbeat tasks |
| lemon_skills | Skill system (injectable domain knowledge) |
| lemon_games | Agent-vs-agent games (Connect 4, etc.) |
| lemon_web | Phoenix web interface |
| lemon_mcp | Model Context Protocol bridge |
| lemon_services | Long-running external process management |
| lemon_sim | Simulation harness for testing agents |
| market_intel | Market data ingestion |

These are all real parts of Lemon, but they're adjacent to the core
"talk to your AI assistant via Telegram" flow. If you're curious, each has
its own `AGENTS.md` with detailed documentation.

---

## Quick Glossary

Terms you'll encounter throughout this guide:

| Term | Meaning |
|------|---------|
| **Session** | A conversation thread between you and an agent, identified by a session key |
| **Run** | A single prompt-to-response cycle within a session |
| **Engine** | An AI backend (native Lemon, Claude CLI, Codex CLI, etc.) |
| **Agent** | A configured personality with specific tools and system prompt |
| **Tool** | Something the AI can do (read a file, run a command, search the web) |
| **Bus** | The internal event messaging system (built on Phoenix PubSub) |
| **Stream** | Real-time delivery of partial results as they're generated |
| **Resume token** | A saved pointer that lets the AI continue a previous conversation |

---

[Next: Your Message's Journey >](02-message-journey.md)
