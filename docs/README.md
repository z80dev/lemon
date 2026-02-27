# Lemon Documentation

> Canonical documentation hub for the Lemon AI assistant platform.
> For quickstart and project overview, see the root [README.md](../README.md).
> For agent development context, see [AGENTS.md](../AGENTS.md).

---

## How to Use This Directory

- **Start here** if you need to understand how Lemon works at a system level.
- **Per-app docs** live in each app's own `README.md` and `AGENTS.md` (see `apps/*/`).
- **Planning docs** live in `planning/` (plans, ideas, reviews, merges).
- **Every file in `docs/`** must be registered in [`catalog.exs`](catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`. Run `mix lemon.quality` to enforce freshness.

---

## Start Here

| Doc | What it covers |
|-----|---------------|
| [architecture_boundaries.md](architecture_boundaries.md) | Dependency policy between umbrella apps, enforcement via `mix lemon.quality` |
| [quality_harness.md](quality_harness.md) | Quality checks, eval harness, cleanup routines, CI gates |
| [config.md](config.md) | TOML configuration reference (providers, runtime, gateway, profiles, tools) |
| [extensions.md](extensions.md) | Extension/plugin API, tool hooks, conflict resolution |

## Runtime Core

| Doc | What it covers |
|-----|---------------|
| [assistant_bootstrap_contract.md](assistant_bootstrap_contract.md) | How sessions bootstrap: system prompt assembly, skill injection, context setup |
| [context.md](context.md) | Context management, compaction, branch summarization, token budgets |
| [beam_agents.md](beam_agents.md) | BEAM agent architecture: process-per-agent, supervision, message passing |
| [runtime-hot-reload.md](runtime-hot-reload.md) | Hot code reload system for live-patching without restarts |
| [model-selection-decoupling.md](model-selection-decoupling.md) | Model selection design: provider abstraction, routing, fallback |
| [telemetry.md](telemetry.md) | Telemetry events, observability, correlation IDs, monitoring |

## Product and Capability Docs

| Doc | What it covers |
|-----|---------------|
| [skills.md](skills.md) | Skill system: SKILL.md format, discovery, relevance matching, prompt injection |
| [games-platform.md](games-platform.md) | Games platform: agent-vs-agent matches, game engines, WASM integration |
| [long-running-agent-harnesses.md](long-running-agent-harnesses.md) | Task management patterns for durable background processes |
| [benchmarks.md](benchmarks.md) | Performance benchmarks and measurement methodology |

## Tool Documentation

| Doc | What it covers |
|-----|---------------|
| [tools/web.md](tools/web.md) | `websearch` and `webfetch` tools: providers, config, caching, guardrails |
| [tools/firecrawl.md](tools/firecrawl.md) | Firecrawl integration for robust web page extraction |
| [tools/wasm.md](tools/wasm.md) | WASM tool runtime: sidecar architecture, tool discovery, security model |

## Testing

| Doc | What it covers |
|-----|---------------|
| [testing/deterministic-test-patterns.md](testing/deterministic-test-patterns.md) | Patterns for deterministic testing with mocks, avoiding flaky tests |
| [testing/lemonade-stand-stress-test.md](testing/lemonade-stand-stress-test.md) | Stress testing methodology for gateway and routing |

## Security

| Doc | What it covers |
|-----|---------------|
| [security/secrets-keychain-audit-matrix.md](security/secrets-keychain-audit-matrix.md) | Secrets management audit: encrypted store, keychain integration, provider credentials |

## Content and Presentations

| Doc | What it covers |
|-----|---------------|
| [foundry-tools-presentation.md](foundry-tools-presentation.md) | Foundry/WASM tools presentation materials |
| [foundry-tools-tweets.md](foundry-tools-tweets.md) | Foundry tools social media content |

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
| `supervision-tree.excalidraw` / `.svg` | OTP supervision tree across all 15 applications |
| `tool-execution.excalidraw` / `.svg` | Tool execution pipeline: registry, policy, approval, execution |

---

## Related Documentation

| Location | Contents |
|----------|---------|
| `apps/*/README.md` | Per-app documentation (architecture, API, usage, dependencies) |
| `apps/*/AGENTS.md` | Per-app AI agent context (key files, patterns, testing, gotchas) |
| `AGENTS.md` (root) | Project-wide agent guide (navigation, team composition, conventions) |
| `README.md` (root) | Project overview, quickstart, architecture deep-dive |
| `ROADMAP.md` | Living roadmap: Now/Next/Later/Explore items with metadata |
| `planning/INDEX.md` | Planning board: active plans, ideas, merges, reviews |
| `config/` | Elixir application configuration (config.exs, runtime.exs, etc.) |
| `examples/config.example.toml` | Annotated example TOML configuration |

## Maintenance Rules

1. **Register every doc** in [`catalog.exs`](catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`.
2. **Run `mix lemon.quality`** after any docs edit or app dependency change.
3. **Keep `AGENTS.md` short and operational** — place durable implementation details in `docs/` files.
4. **Update diagrams** when architecture changes — edit the `.excalidraw` source, export to `.svg`.
5. **Review cycle**: docs are checked for staleness based on `max_age_days` in the catalog.

*Last reviewed: 2026-02-27*
