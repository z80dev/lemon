# Architecture Overview

Lemon is an AI coding assistant built as a distributed system of concurrent processes
running on the BEAM (Erlang VM). This document covers the system architecture, key
design decisions, and component responsibilities.

For system diagrams see `docs/diagrams/`. For per-app details see each `apps/*/README.md`.

---

## Core Philosophy

1. **Agents as Processes** — each AI agent is a GenServer with isolated state, a
   mailbox, and an independent lifecycle. Multiple sessions never share state.

2. **Streaming as Events** — LLM responses are modeled as event streams, enabling
   reactive UIs, parallel processing, and backpressure handling.

3. **Fault Tolerance** — OTP supervision trees isolate failures. A crashing tool
   does not kill the agent session; a network error during streaming is recoverable.

4. **Live Steering** — users can inject messages mid-execution because the BEAM
   can send a message to any process at any time.

5. **Multi-Provider Abstraction** — unified interface for 26 LLM providers with
   automatic model configuration and cost tracking.

6. **Multi-Engine Architecture** — pluggable execution engines: native Lemon plus
   Codex CLI, Claude CLI, OpenCode CLI, and Pi CLI backends.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Clients                                                      │
│  TUI (TypeScript)  ·  Web (React)  ·  Browser (Playwright)  │
└───────────────────────┬─────────────────────────────────────┘
                        │ JSON-RPC / WebSocket
┌───────────────────────▼────────────────────┐
│ LemonControlPlane  (112+ RPC methods)       │
└───────────────────────┬────────────────────┘
                        │
┌───────────────────────▼────────────────────┐
│ LemonRouter            RunOrchestrator      │
│  · model selection     · policy enforcement │
│  · routing feedback    · approval gating    │
└────────┬──────────────────────┬────────────┘
         │                      │
┌────────▼───────┐   ┌──────────▼──────────┐
│ LemonGateway   │   │ LemonChannels        │
│  (engines)     │   │  Telegram, Discord,  │
└────────┬───────┘   │  X/Twitter           │
         │           └─────────────────────-┘
┌────────▼───────────────────────────────────┐
│ CodingAgent.Session                         │
│  · 20 built-in tools                        │
│  · context compaction                       │
│  · extension system                         │
└────────┬───────────────────────────────────┘
         │
┌────────▼──────────────┬──────────────────┐
│ LemonCore             │ LemonSkills       │
│  · EventBus           │  · skill catalog  │
│  · MemoryStore        │  · audit engine   │
│  · RoutingFeedback    │  · synthesis      │
│  · TaskFingerprint    │  · installer      │
└───────────────────────┴──────────────────┘
         │
┌────────▼──────────────────────────────────┐
│ Ai  (provider abstraction layer)           │
│  26 providers: Anthropic, OpenAI, Google,  │
│  Azure, AWS Bedrock, xAI, Mistral, …       │
└───────────────────────────────────────────┘
```

See `docs/diagrams/architecture.svg` for the full visual diagram.

---

## Application Map

The project is an Elixir umbrella with 18+ applications:

| App | Role |
|---|---|
| `ai` | Provider abstraction, streaming, cost tracking |
| `agent_core` | Core agent loop, tool execution, abort/subagent semantics |
| `coding_agent` | Session management, compaction, JSONL persistence, tools |
| `coding_agent_ui` | Debug RPC interface, TUI/Web bridge |
| `lemon_core` | EventBus, MemoryStore, RoutingFeedbackStore, TaskFingerprint, config |
| `lemon_router` | RunOrchestrator, ModelSelection, lane queues, policy engine |
| `lemon_gateway` | Engine dispatch (native + CLI backends), execution lifecycle |
| `lemon_channels` | Transport adapters: Telegram, Discord, X/Twitter |
| `lemon_automation` | CronManager, HeartbeatManager, scheduled jobs |
| `lemon_control_plane` | HTTP/WebSocket server, 112+ RPC methods |
| `lemon_skills` | Skill catalog, manifest v2 parser, installer, audit, synthesis |
| `lemon_mcp` | MCP protocol server |
| `lemon_games` | Agent-vs-Agent game platform |
| `lemon_sim` | Simulation harness for development/testing |
| `lemon_web` | React web frontend bridge |
| `lemon_services` | Shared service infrastructure |
| `market_intel` | Market intelligence capabilities |

---

## Data Flow

Four main paths through the system:

1. **Direct (TUI/Web)**: JSON-RPC → `debug_agent_rpc` → `coding_agent_ui` → Session → AgentCore → Tools/Ai

2. **Control Plane**: WebSocket → ControlPlane → Router → Orchestrator → Gateway → Engine

3. **Channel (Telegram etc.)**: Message → LemonChannels → Router → StreamCoalescer → Outbox

4. **Automation**: CronManager tick → Due jobs → Router → HeartbeatManager → EventBus

See `docs/diagrams/data-flow.svg` for the full diagram.

---

## Run Lifecycle

```
User message
  → Session routing (canonical session key)
    → RunOrchestrator.start_run/1
      → ModelSelection.resolve/1  (explicit → meta → session → profile → history → default)
      → Lane selection (main/subagent/background)
      → Engine dispatch
        → Tool execution (isolated Task processes)
        → LLM streaming (event stream per response)
      → Outcome recording (RunOutcome → MemoryDocument)
      → Routing feedback entry
```

### Lane scheduling

| Lane | Default cap | Purpose |
|---|---|---|
| `main` | 4 | User-initiated runs |
| `subagent` | 8 | Agent-spawned subagents |
| `background` | 2 | Cron jobs, automations |

### Model selection precedence

```
explicit_model        # per-message /model override
  → meta_model        # metadata field in request
    → session_model   # /model set for this session
      → profile_model # config [profiles.X] model field
        → history_model  # best model for this task fingerprint (routing_feedback)
          → default_model  # config [defaults] model
```

---

## Key Abstractions

### TaskFingerprint

Classifies every run into a canonical key used for routing feedback and skill synthesis:

```
<task_family>|<toolset>|<workspace>|<provider>|<model>
```

Task families: `:code`, `:query`, `:file_ops`, `:chat`, `:unknown`

Context key (for history lookup): `<task_family>|<toolset>|<workspace>`

### MemoryDocument

Durable record of a completed run:

```
doc_id, run_id, session_key, agent_id, workspace_key, scope,
started_at_ms, ingested_at_ms,
prompt_summary, answer_summary, tools_used,
provider, model, outcome, meta
```

### Feature Flags

All non-trivial features are gated behind flags in `[features]` TOML section.
Code reads flags via `LemonCore.Config.Features.enabled?(features, :flag_name)`.

Current flags: `product_runtime`, `skills_hub_v2`, `skill_manifest_v2`,
`progressive_skill_loading_v2`, `session_search`, `routing_feedback`,
`skill_synthesis_drafts`.

---

## Why BEAM?

| Concern | BEAM advantage |
|---|---|
| Millions of concurrent agents | Lightweight processes (microseconds to start, ~2KB memory) |
| Live steering mid-run | Message to any process at any time |
| Tool crash isolation | OTP supervision; supervisor restarts failed child |
| Streaming responses | Process-per-stream with backpressure |
| Session persistence across restarts | Durable state in ETS + SQLite |
| Hot code reload | BEAM code upgrade without restart |
| Multi-node future | Native Erlang distribution built in |

---

## Further Reading

| Document | Topic |
|---|---|
| [`docs/architecture_boundaries.md`](../architecture_boundaries.md) | Dependency policy between apps |
| [`docs/beam_agents.md`](../beam_agents.md) | BEAM agent architecture deep-dive |
| [`docs/context.md`](../context.md) | Context management and compaction |
| [`docs/model-selection-decoupling.md`](../model-selection-decoupling.md) | Model selection design |
| [`docs/assistant_bootstrap_contract.md`](../assistant_bootstrap_contract.md) | Session bootstrap sequence |
| `apps/*/README.md` | Per-application documentation |

*Last reviewed: 2026-03-16*
