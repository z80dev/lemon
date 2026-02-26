# Lemon

### The agent runtime that never goes down.

---

Lemon is an AI agent system built on the Erlang VM — the same runtime that powers WhatsApp, Discord, and telecom infrastructure serving billions of users. While other agent frameworks bolt concurrency onto languages that were never designed for it, Lemon runs every agent, every tool call, every LLM stream, and every channel adapter as an independent lightweight process — supervised, isolated, and resilient by default.

The result: an agent orchestration platform where crashes are contained, not catastrophic. Where you can steer a running agent mid-thought. Where adding a new communication channel or execution engine is a matter of implementing a behaviour, not rewriting your stack. And where the entire system can be hot-patched in production without dropping a single conversation.

---

## What Makes Lemon Different

### Agents Are Processes, Not Objects

In most agent frameworks, an "agent" is a Python class wrapping an API call. In Lemon, every agent session is a genuine concurrent process with its own memory, mailbox, and lifecycle. This isn't a metaphor — it's the BEAM's actor model applied to AI orchestration.

Each agent process:
- Maintains its own conversation state independently
- Receives messages asynchronously from any other process in the system
- Survives failures in other agents without interruption
- Can be introspected, monitored, and steered while running

This means you can run dozens of agents simultaneously, each working on different tasks across different codebases, all within a single system — with true preemptive scheduling guaranteeing that no single agent can starve the others.

### Live Steering

Most agent systems are fire-and-forget: you send a prompt and wait. Lemon supports **live steering** — injecting messages into a running agent's execution loop between tool calls. See your agent going down the wrong path? Steer it. Want to add context mid-run? Send it. The agent picks up your message at the next safe checkpoint and adjusts course.

This works because BEAM processes have mailboxes. Steering messages are enqueued and consumed naturally between execution steps — no polling, no webhooks, no race conditions.

### True Fault Isolation

When a tool execution crashes in a traditional agent framework, the whole process often dies. In Lemon, tool executions run as supervised tasks linked to the agent via OTP's `Task.Supervisor.async_nolink` — a crash in a tool sends a clean `{:DOWN}` signal to the agent, which handles it gracefully and continues.

The supervision hierarchy extends through the entire system:
- A crashed agent session doesn't affect other sessions
- A failing LLM provider triggers a circuit breaker, not a system-wide outage
- A misbehaving channel adapter is restarted independently
- The event bus, stores, and schedulers each run in their own supervision subtrees

This is the kind of fault tolerance that Erlang/OTP was built for — the same principles that keep telephone switches running for decades without downtime.

### Hot Code Reloading

Deploy new tools, update system prompts, patch agent logic, and load new extensions — all without restarting the system or interrupting active conversations. BEAM's hot code upgrade capability means Lemon is a living system that evolves while running.

---

## Architecture

Lemon is structured as an Elixir umbrella of 12 OTP applications, each owning a clear domain:

| Layer | Application | Role |
|-------|------------|------|
| **AI** | `ai` | Multi-provider LLM abstraction with circuit breakers, rate limiting, and streaming |
| **Agent** | `agent_core` | GenServer-based agent framework with event-driven execution loop |
| **Capabilities** | `coding_agent` | Full coding agent with 15+ tools, WASM extensions, session persistence |
| **Orchestration** | `lemon_gateway` | Multi-engine execution gateway with per-thread scheduling |
| **Routing** | `lemon_router` | Inbound routing, stream coalescing, approval workflows |
| **Channels** | `lemon_channels` | Pluggable channel adapters (Telegram, X/Twitter, more coming) |
| **Automation** | `lemon_automation` | Cron scheduling, heartbeats, on-demand wake |
| **Control** | `lemon_control_plane` | HTTP + WebSocket API with 80+ RPC methods |
| **Knowledge** | `lemon_skills` | Reusable skill modules with dependency verification |
| **Foundation** | `lemon_core` | Event bus, pluggable stores, telemetry, shared primitives |

Every application is a supervision tree. Every component communicates via message passing. There are no shared-memory locks, no thread pools to tune, no garbage collection pauses that freeze the world.

---

## Multi-Provider, Multi-Engine

### LLM Providers

Lemon abstracts across every major LLM provider behind a unified streaming interface:

- **Anthropic** — Claude 3 Haiku through Claude Opus 4.5
- **OpenAI** — GPT-4o, o1, o3, Codex
- **Google** — Gemini via Google AI and Vertex AI
- **Azure** — Azure-hosted OpenAI models
- **AWS Bedrock** — Any Bedrock-supported model

Each provider gets its own circuit breaker, rate limiter, and process isolation. When a provider starts returning errors, Lemon's circuit breaker trips to protect your system and your budget — then probes periodically to detect recovery. Model metadata includes full pricing information for real-time cost tracking.

### Execution Engines

Lemon doesn't lock you into a single agent implementation. The gateway supports multiple execution engines through a pluggable behaviour:

- **Native Lemon** — Full-featured Elixir agent with all tools and extensions
- **Claude CLI** — Anthropic's Claude Code as a subprocess
- **Codex CLI** — OpenAI's Codex as a subprocess
- **OpenCode CLI** — OpenCode as a subprocess
- **Pi CLI** — Pi as a subprocess

All engines emit events into the same unified stream. You can switch engines per-message, per-chat, or per-binding. Engines can even be used as subagents — spawn a Claude CLI task from within a native Lemon session.

---

## The Tool System

### Built-In Tools

Lemon ships with a comprehensive tool suite for coding and general-purpose work:

**File Operations** — `read`, `write`, `edit`, `patch`, `multiedit`, `ls`, `glob`, `find`, `grep`
**Execution** — `bash` with streaming output and timeout control
**Web** — `webfetch`, `websearch`, `webdownload`, `browser` automation
**Orchestration** — `task` for spawning async subagents, `todo` for structured task tracking
**Memory** — `memory_topic` for persistent operational knowledge across sessions
**Extensions** — dynamically loaded custom tools from the filesystem

### Tool Policy Engine

Fine-grained control over what agents can do:

- **Profiles**: `full_access`, `read_only`, `safe_mode`, `subagent_restricted`, or `custom`
- **Per-tool approval**: `always`, `never`, or interactive approval via the channel
- **Interactive approvals**: When an agent needs to run a sensitive tool, the user gets inline buttons in Telegram — approve once, for the session, for the agent, globally, or deny

### WASM Sandboxing

Extend Lemon with tools written in any language that compiles to WebAssembly. WASM tools run in a sandboxed sidecar runtime with their results tagged as untrusted — giving you extensibility without sacrificing security. Auto-build from Rust source when `auto_build` is enabled.

---

## Channels

Lemon meets you where you are. The channel system is a pluggable adapter layer with a clean behaviour contract:

### Telegram
The primary interface. Full-featured with:
- Rich Markdown rendering with Telegram entity support
- Voice message transcription
- Inline approval buttons for tool authorization
- Smart message chunking that respects formatting boundaries
- Rate limiting and deduplication built into the outbox

### X (Twitter)
Post tweets, reply to mentions, and manage threads — all agent-driven. OAuth 2.0 with automatic token refresh, 280-character chunking, image support, and 24-hour deduplication.

### SMS (Twilio)
Receive and process SMS messages. Agents can wait for verification codes, claim messages from a shared inbox, and respond — useful for automated workflows that need phone-based verification.

### More Coming
Discord, Slack, and other adapters plug in through the same behaviour. Adding a new channel means implementing six callbacks — the routing, delivery, rate limiting, and deduplication infrastructure is already there.

---

## Orchestration Runtime

### Lane-Aware Scheduling

Not all work is equal. Lemon's scheduler organizes work into lanes with independent concurrency limits:

- **Main** (4 concurrent) — Primary agent sessions
- **Subagent** (8 concurrent) — `task` tool-spawned sub-agents
- **Background** (2 concurrent) — Durable long-running processes

This prevents subagent storms from starving interactive sessions and keeps background work from consuming all resources.

### Stream Coalescing

LLM tokens arrive one at a time. Sending each token as a separate Telegram message would be absurd. Lemon's stream coalescer buffers intelligently:
- Minimum character threshold before flushing
- Idle timeout for responsive updates during pauses
- Maximum latency cap to guarantee delivery
- Automatic in-place message editing when the channel supports it

The result: smooth, real-time streaming updates in Telegram that feel like watching someone type — not a flood of individual messages.

### Async Subagents

Agents can spawn other agents. The `task` tool lets a running agent delegate work to subagents — potentially using different engines or models — and collect results. Subagents run in their own supervised processes with their own tool policies, creating a natural hierarchy for complex multi-step workflows.

### Durable Background Processes

Some tasks take hours — monitoring a deployment, watching for events, running a long build. Lemon's process manager supports durable background executions that survive session boundaries, with their own lifecycle management and event streaming.

### Cron and Automation

Schedule recurring agent runs with cron expressions. The automation system ticks every minute, checks due jobs, applies optional jitter to prevent thundering herds, and submits runs through the standard routing pipeline. Heartbeat monitoring provides system health observability.

---

## Session Management

### Persistent Conversations

Every conversation is persisted as a JSONL file with a tree-structured message history. Sessions support branching, resumption, and parent-child relationships. The v3 format stores rich metadata including compaction summaries, model changes, thinking level adjustments, and custom entries.

### Context Compaction

Long conversations eventually exceed context windows. Lemon handles this automatically: when token usage approaches the limit, the compaction system identifies a safe cut point (never splitting a tool call from its result), summarizes the compacted portion, and continues — preserving continuity without manual intervention.

### Memory Topics

Agents can write persistent knowledge to `memory/topics/*.md` files — local setup notes, API patterns, key file paths, project conventions. These survive across sessions and provide durable operational memory that builds up over time, making agents more effective the longer they work with a codebase.

---

## Why BEAM

The choice of Erlang/OTP as the foundation isn't incidental — it's the core architectural decision that makes everything else possible.

**Lightweight Processes**: BEAM processes cost ~2KB each. Lemon can run thousands of concurrent agent sessions, tool executions, and stream handlers without the overhead of OS threads or the complexity of async/await.

**Preemptive Scheduling**: The BEAM scheduler preempts processes after a fixed number of reductions. No agent can monopolize the runtime. No runaway tool can freeze the system. Every process gets fair CPU time, always.

**Supervision Trees**: OTP supervisors define restart strategies for every component. When something fails, the supervisor restarts just that component — not the whole application. This is battle-tested infrastructure that has run telecom systems at five-nines uptime for decades.

**Message Passing**: No shared mutable state. No locks. No data races. Processes communicate by sending immutable messages. This eliminates entire categories of concurrency bugs that plague thread-based agent systems.

**Distribution**: BEAM nodes can form clusters. Lemon already runs as a named distributed node with remote shell access. The path to multi-node deployment — agents running across machines, automatic failover, location-transparent messaging — is built into the runtime.

**Hot Code Upgrades**: Update running code without stopping the system. Deploy new tools, fix bugs, and evolve the platform while active sessions continue uninterrupted.

**Garbage Collection**: Per-process garbage collection means no stop-the-world pauses. Each of Lemon's thousands of processes has its own heap, collected independently. Latency stays predictable even under heavy load.

---

## Clients

### Telegram
The primary day-to-day interface. Message your bot from anywhere — your phone, tablet, or desktop. Full streaming, inline approvals, voice transcription, and engine switching via commands.

### Terminal UI
A rich terminal interface built with themes, multi-session support, and real-time streaming via JSON-RPC.

### Web UI
A React + Vite frontend with WebSocket streaming for browser-based access.

### Control Plane API
80+ RPC methods over HTTP and WebSocket for programmatic control — session management, run lifecycle, configuration, and system introspection.

### Remote Shell
Attach directly to the running BEAM node for live debugging, introspection, and administration. Full access to the running system's state, processes, and OTP tooling.

---

## Local-First

Lemon runs on your machine. Your code stays on your machine. Your conversations stay on your machine. There is no cloud service between you and your agents — just direct API calls to your chosen LLM provider.

This isn't just a privacy feature. It means:
- Zero latency between the agent and your filesystem
- No rate limits beyond what your provider imposes
- No vendor lock-in to a hosted agent platform
- Full control over configuration, tool policies, and security boundaries
- Your agent has the same access to your development environment that you do

---

## Built for the Long Run

Lemon isn't a weekend prototype wrapped in a CLI. It's 12 OTP applications, hundreds of modules, and thousands of lines of well-structured Elixir — built on a runtime that was designed from the ground up for systems that never stop.

Every architectural decision — processes over threads, supervision over crash-and-burn, message passing over shared state, behaviours over inheritance — compounds into a system that gets more reliable as it grows more complex. That's the BEAM promise, and Lemon delivers on it.

If you're building agent systems that need to be concurrent, resilient, extensible, and observable — Lemon is the foundation.

---

*Named after a very good cat.*
