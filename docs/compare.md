# Compare Lemon

Lemon is a local-first, BEAM-native AI agent runtime. It is not only a chat UI,
coding CLI, or evaluation harness. The product goal is to make daily-agent work
easy to install and operate while using OTP supervision, process isolation,
durable events, explicit policy, and replayable state underneath.

## Positioning

| Category | Typical strength | Lemon's approach |
| --- | --- | --- |
| Hosted assistants | Immediate onboarding and managed infrastructure | Local runtime ownership, local files and secrets, configurable providers, and supportable self-hosting |
| Vendor coding CLIs | Polished repository workflow tied to one provider runtime | One native supervised runtime with provider/model routing, persistent sessions, tools, and in-process subagents |
| Agent harnesses | Repeatable tool loops, transcripts, and evaluation | A production assistant stack plus deterministic LemonSim worlds and replay verification |
| Chat bridges | Reach an assistant from messaging apps | Channel adapters share the same sessions, approvals, memory, tools, events, and diagnostics |
| Automation scripts | Flexible local control with limited product lifecycle | Durable cron, heartbeats, monitor jobs, goal loops, kanban workers, retries, lineage, and preflight under supervision |

## Current strengths

| Area | Current Lemon capability | Evidence |
| --- | --- | --- |
| Runtime | Supervised BEAM applications, one native executor, typed events, durable run state, hot reload, and explicit control-plane APIs | [Architecture](architecture/overview.md), [BEAM agents](beam_agents.md), [Hot reload](runtime-hot-reload.md) |
| Models | Provider/model selection, custom endpoints, live provider fallback, credential pools, cooldowns, and per-session pinning | [Model selection](model-selection-decoupling.md), [Configuration](config.md), [Testing](testing.md) |
| Harness | Native subagents, approval-aware tools, redirect/steer/abort, progressive tool disclosure, programmatic tool calling, compaction, and long-running goal support | [Context](context.md), [Execute Code](tools/execute-code.md), [Harness scorecard](plans/lemon-hermes-agent-harness-parity-scorecard.md) |
| Browser and media | Supervised browser automation, Web search/fetch, downloads/uploads, screenshots, computer use, media jobs, and artifacts | [Web and Browser Tools](tools/web.md), [Media Tools](tools/media.md) |
| Memory and skills | SQLite full-text memory, project context, Honcho integration, skill discovery/audit/install/update, and opt-in synthesis/curation | [Memory](user-guide/memory.md), [Honcho](user-guide/honcho.md), [Skills](user-guide/skills.md), [Adaptive behavior](user-guide/adaptive.md) |
| Automation | Durable cron and timers, retries/lineage, overlap locks, monitor suppression, no-agent commands, chaining, model-drift guard, preflight, goals, and kanban | [Configuration](config.md), [Testing](testing.md), [Support](support.md) |
| Multi-machine work | Authenticated named execution nodes route native Lemon agent runs to destination-local workspaces and credentials | [Architecture](architecture/overview.md) |
| Safety and operations | Central approvals, URL and extension policy, redaction, doctor checks, support bundles, readiness/proof artifacts, release channels, and canonical test lanes | [Safety](security/safety.md), [Support](support.md), [Versioning](release/versioning_and_channels.md), [Testing](testing.md) |
| Simulation | Event-sourced worlds, deterministic replay verification, leagues, ratings, hosted observation, and benchmark artifacts | [Benchmark quickstart](benchmarks/quickstart.md), [Platform guarantees](benchmarks/platform.md) |

## Hermes comparison

Lemon's current runtime closes several old Hermes gaps: `execute_code`,
progressive tool disclosure, three-way interruption, provider/credential
failover, browser automation, and high-quality cron internals are implemented.
The largest remaining differences are product integration and usability:

- Hermes has a native desktop, multi-profile Bot Mode, a broad management Web
  dashboard, and multi-connection roster. Lemon has strong TUI/control-plane/node
  primitives but no equivalent integrated product shell.
- Hermes exposes an extensive coherent CLI. Lemon's packaged CLI covers setup,
  model, gateway, doctor, config, secrets, and channels; additional operations
  are split across the source wrapper, Mix tasks, TUI, and JSON-RPC.
- Hermes has richer update/profile lifecycle and an outbound
  credential-injection proxy. Lemon now has read-only 1Password, Bitwarden, and
  argv-only command sources behind its encrypted store, but no general egress
  broker that withholds credentials from arbitrary remote/browser/tool work.
- Hermes documentation has a more complete install-to-daily-use information
  architecture and many more task guides. Lemon's architecture and proof docs
  are deep, but some user workflows remain under-documented.

The current, source-pinned comparison is the
[Hermes Functionality and UX Gap Audit](plans/lemon-hermes-gap-audit-2026-08-11.md).
It records the exact official Hermes and Lemon revisions, corrections to stale
findings, evidence for every status, and prioritized vertical implementation
bundles. The older
[May feature matrix](plans/lemon-hermes-feature-parity-matrix-2026-05-12.md) is
historical evidence only.

## What is ready to evaluate

- verified one-line release installation on documented macOS and Linux targets
- idempotent first-run setup and provider onboarding
- the Bun terminal UI and Phoenix session Web UI
- stable Telegram and Discord text-first support
- durable sessions, streaming, tools, approvals, queues, memory, and skills
- provider fallback and credential-pool resilience
- browser, media, execute-code, LSP, checkpoint, API, ACP, MCP, and WASM preview
  surfaces behind their documented gates
- cron, heartbeats, monitor jobs, goals, and kanban through control-plane and
  runtime surfaces
- local and authenticated named-node agent execution
- doctor diagnostics, support bundles, readiness/proof commands, release
  profiles, and deterministic LemonSim demos

## Important current limits

Do not choose Lemon yet if your requirement depends on:

- a polished native desktop for non-technical users
- native Windows, Nix/NixOS, Android/Termux, or broad older-Linux installation
- a management Web dashboard for configuration, sessions, cron, skills, memory,
  providers, nodes, and logs
- isolated user-created profiles/bots with clone/export/delete and group-chat UX
- complete session search/export/archive/pin/prune workflows
- an integrated update-plan/rollback and whole-data backup/restore lifecycle
- a general egress credential broker that withholds real credentials from
  arbitrary remote/browser/tool execution
- a hosted managed service
- Discord behavior beyond the live-proven text-first and file-delivery boundary

These are active parity targets, not rejected features. They need end-to-end
product surfaces, documentation, safety policy, and live-instance proof before
broad support claims.

## Evaluation path

1. Follow [Install Lemon](install.md).
2. Complete [Setup](user-guide/setup.md).
3. Start the TUI and run [Demo Lemon](demo.md).
4. Exercise the workflows relevant to you, then inspect the
   [current Hermes gap audit](plans/lemon-hermes-gap-audit-2026-08-11.md).
5. Use [Support](support.md) for diagnostics and a redacted support bundle.
