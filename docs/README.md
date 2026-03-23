# Lemon Documentation

> Canonical documentation hub for the Lemon AI assistant platform.
> For quickstart and project overview, see the root [README.md](../README.md).
> For agent development context, see [AGENTS.md](../AGENTS.md).

---

## How to Use This Directory

- **Start here** if you need to understand how Lemon works at a system level.
- **Per-app docs** live in each app's own `README.md` and `AGENTS.md` (see `apps/*/`).
- **Every file in `docs/`** must be registered in [`catalog.exs`](catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`. Run `mix lemon.quality` to enforce freshness.

---

## User Guides

| Doc | What it covers |
|-----|---------------|
| [user-guide/setup.md](user-guide/setup.md) | Full setup walkthrough: install, configure, run, Telegram setup |
| [user-guide/skills.md](user-guide/skills.md) | Skills: listing, installing, inspecting, synthesizing drafts |
| [user-guide/memory.md](user-guide/memory.md) | Memory documents, session search, retention management |
| [user-guide/adaptive.md](user-guide/adaptive.md) | Adaptive routing, routing feedback, skill synthesis pipeline |
| [user-guide/rollout.md](user-guide/rollout.md) | Feature promotion gates, rollback procedure, promotion checklist |

## Architecture

| Doc | What it covers |
|-----|---------------|
| [architecture/overview.md](architecture/overview.md) | System design, app map, data flow, key abstractions |
| [architecture_boundaries.md](architecture_boundaries.md) | Dependency policy between umbrella apps, enforcement via `mix lemon.quality` |
| [beam_agents.md](beam_agents.md) | BEAM/OTP architecture: process-per-agent, supervision, message passing |
| [model-selection-decoupling.md](model-selection-decoupling.md) | Model selection design: provider abstraction, routing, fallback |

## Operations

| Doc | What it covers |
|-----|---------------|
| [quality_harness.md](quality_harness.md) | Quality checks, eval harness, cleanup routines, CI gates |
| [config.md](config.md) | TOML configuration reference (providers, runtime, gateway, profiles, tools) |
| [extensions.md](extensions.md) | Extension/plugin API, tool hooks, conflict resolution |

## Runtime Core

| Doc | What it covers |
|-----|---------------|
| [assistant_bootstrap_contract.md](assistant_bootstrap_contract.md) | How sessions bootstrap: system prompt assembly, skill injection, context setup |
| [context.md](context.md) | Context management, compaction, branch summarization, token budgets |
| [remote-cli-task-execution-plan.md](remote-cli-task-execution-plan.md) | Planning note for remote `codex`/`claude` task execution over generic runner backends |
| [subagent-parent-questions.md](subagent-parent-questions.md) | Design for the `ask_parent` clarification path from child subagents back to their parent session |
| [runtime-hot-reload.md](runtime-hot-reload.md) | Hot code reload system for live-patching without restarts |
| [telemetry.md](telemetry.md) | Telemetry events, observability, correlation IDs, monitoring |

## Product and Capability Docs

- [`docs/skills.md`](skills.md)
- [`docs/product/skill_synthesis_planning.md`](product/skill_synthesis_planning.md) - Current-state review and planning notes for adaptive skill synthesis and self-authored skills
- [`docs/testing/missing-tests-plan.md`](testing/missing-tests-plan.md) - Ranked backlog of the highest-impact missing automated tests across the umbrella apps
- [`docs/for-dummies/README.md`](for-dummies/README.md) - Plain-English guided tour of Lemon for non-Elixir users
- [`docs/benchmarks.md`](benchmarks.md)
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)
- [`docs/tools/wasm.md`](tools/wasm.md)

## Continuous Improvement Loop

| Doc | What it covers |
|-----|---------------|
| [agent-loop/README.md](agent-loop/README.md) | Agent loop design: feedback cycles, self-improvement patterns |
| [agent-loop/GOALS.md](agent-loop/GOALS.md) | Current goals for the continuous improvement loop |
| [agent-loop/RUN_LOG.md](agent-loop/RUN_LOG.md) | Log of agent loop runs and outcomes |

## Architecture Diagrams

All diagrams are in `docs/diagrams/` as both Excalidraw source and exported SVG:

| Diagram | What it shows |
|---------|--------------|
| `architecture.excalidraw` / `.svg` | Complete system architecture: clients, control plane, routing, infrastructure, core |
| `data-flow.excalidraw` / `.svg` | Four data paths: direct, control plane, channel, automation |
| `event-bus.excalidraw` / `.svg` | Event bus topology and pub/sub messaging |
| `orchestration.excalidraw` / `.svg` | Run orchestration: scheduling, lane queues, engine dispatch |
| `supervision-tree.excalidraw` / `.svg` | OTP supervision tree across all 17 applications |
| `tool-execution.excalidraw` / `.svg` | Tool execution pipeline: registry, policy, approval, execution |

---

## Related Documentation

| Location | Contents |
|----------|---------|
| `apps/*/README.md` | Per-app documentation (architecture, API, usage, dependencies) |
| `apps/*/AGENTS.md` | Per-app AI agent context (key files, patterns, testing, gotchas) |
| `AGENTS.md` (root) | Project-wide agent guide (navigation, team composition, conventions) |
| `README.md` (root) | 5-minute orientation: what it is, quickstart, feature summary, doc links |
| `ROADMAP.md` | Living roadmap: Now/Next/Later/Explore items with metadata |
| `config/` | Elixir application configuration (config.exs, runtime.exs, etc.) |
| `examples/config.example.toml` | Annotated example TOML configuration |

## Maintenance Rules

1. **Register every doc** in [`catalog.exs`](catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`.
2. **Run `mix lemon.quality`** after any docs edit or app dependency change.
3. **Keep `AGENTS.md` short and operational** — place durable implementation details in `docs/` files.
4. **Update diagrams** when architecture changes — edit the `.excalidraw` source, export to `.svg`.
5. **Review cycle**: docs are checked for staleness based on `max_age_days` in the catalog.

*Last reviewed: 2026-03-16*
