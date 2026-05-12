# Lemon Documentation

> Canonical documentation hub for the Lemon AI assistant platform.
> For quickstart and project overview, see the root [README.md](https://github.com/z80dev/lemon/blob/main/README.md).
> For agent development context, see [AGENTS.md](https://github.com/z80dev/lemon/blob/main/AGENTS.md).

---

## How to Use This Directory

- **Start here** if you need to understand how Lemon works at a system level.
- **Per-app docs** live in each app's own `README.md` and `AGENTS.md` (see `apps/*/`).
- **Every file in `docs/`** must be registered in [`docs/catalog.exs`](https://github.com/z80dev/lemon/blob/main/docs/catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`. Run `mix lemon.quality` to enforce freshness.

---

## User Guides

| Doc | What it covers |
|-----|---------------|
| [index.md](index.md) | Public docs-site homepage: positioning, entry points, current launch stage |
| [install.md](install.md) | Short install landing page for source install and release-artifact status |
| [compare.md](compare.md) | Product comparison against adjacent assistant, CLI, harness, and self-hosted runtime categories |
| [demo.md](demo.md) | Deterministic local demo paths for runtime health, Web ops, TUI, support bundles, and docs quality |
| [support.md](support.md) | Public support boundaries, issue data requirements, support-bundle commands, and security-reporting path |
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
| [long-running-agent-harnesses.md](long-running-agent-harnesses.md) | Long-running harness patterns, eval loops, and runtime validation workflows |
| [testing.md](testing.md) | Canonical local test lanes and CI parity guidance |
| [config.md](config.md) | TOML configuration reference (providers, runtime, gateway, profiles, tools) |
| [extensions.md](extensions.md) | Extension/plugin API, tool hooks, conflict resolution |
| [release/release_checklist_and_support_policy.md](release/release_checklist_and_support_policy.md) | 1.0 release-candidate checklist, rollback checklist, and support boundaries |
| [security/safety.md](security/safety.md) | Plain-language Lemon safety model, recommended defaults, and support-bundle guidance |
| [security/agent-safety-contract.md](security/agent-safety-contract.md) | Agent safety layers: tool policies, approvals, memory screening, skill audits, telemetry |

## Runtime Core

| Doc | What it covers |
|-----|---------------|
| [assistant_bootstrap_contract.md](assistant_bootstrap_contract.md) | How sessions bootstrap: system prompt assembly, skill injection, context setup |
| [context.md](context.md) | Context management, compaction, branch summarization, token budgets |
| [subagent-parent-questions.md](subagent-parent-questions.md) | Design for the `ask_parent` clarification path from child subagents back to their parent session |
| [runtime-hot-reload.md](runtime-hot-reload.md) | Hot code reload system for live-patching without restarts |
| [telemetry.md](telemetry.md) | Telemetry events, observability, correlation IDs, monitoring |

## Product and Capability Docs

- [`docs/skills.md`](skills.md)
- [`docs/compare.md`](compare.md) - Lemon positioning against hosted assistants, single-engine CLIs, agent harnesses, and self-hosted automation
- [`docs/demo.md`](demo.md) - Local deterministic demo flows for runtime, Web operations, TUI, support bundles, and docs quality
- [`docs/support.md`](support.md) - Public support policy landing page and issue-prep checklist
- [`docs/plans/lemon-1.0-mainstream-readiness.md`](plans/lemon-1.0-mainstream-readiness.md) - Launch goal and readiness plan for Lemon 1.0 mainstream use
- [`docs/plans/lemon-1.0-fresh-install-proof-2026-05-11.md`](plans/lemon-1.0-fresh-install-proof-2026-05-11.md) - Source-dev fresh install proof for the Lemon 1.0 launch goal
- [`docs/plans/lemon-1.0-release-artifact-proof-2026-05-11.md`](plans/lemon-1.0-release-artifact-proof-2026-05-11.md) - Local release-artifact proof for `lemon_runtime_full`
- [`docs/plans/lemon-1.0-interface-supportability-audit-2026-05-11.md`](plans/lemon-1.0-interface-supportability-audit-2026-05-11.md) - Interface supportability audit for Web, TUI, Telegram, Discord, and the control plane
- [`docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md`](plans/lemon-1.0-interface-proof-pack-2026-05-11.md) - Release-candidate proof pack for automated TUI, Web, and Telegram-adjacent interface coverage
- [`docs/plans/lemon-1.0-completion-audit-2026-05-12.md`](plans/lemon-1.0-completion-audit-2026-05-12.md) - Prompt-to-artifact completion audit and remaining external launch blockers
- [`docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`](plans/lemon-hermes-agent-harness-parity-scorecard.md) - Hermes-class agent harness parity scorecard
- [`docs/for-dummies/README.md`](for-dummies/README.md) - Plain-English guided tour of Lemon for non-Elixir users
- [`docs/skills_v2.md`](skills_v2.md) - Skill manifest v2 and newer skill-system direction
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)
- [`docs/tools/wasm.md`](tools/wasm.md)

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
| `docs/plans/lemon-1.0-mainstream-readiness.md` | Living launch goal: mainstream readiness workstreams, milestones, and acceptance criteria |
| `config/` | Elixir application configuration (config.exs, runtime.exs, etc.) |
| `examples/config.example.toml` | Annotated example TOML configuration |

## Maintenance Rules

1. **Register every doc** in [`docs/catalog.exs`](https://github.com/z80dev/lemon/blob/main/docs/catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`.
2. **Run `mix lemon.quality`** after any docs edit or app dependency change.
3. **Keep `AGENTS.md` short and operational** — place durable implementation details in `docs/` files.
4. **Update diagrams** when architecture changes — edit the `.excalidraw` source, export to `.svg`.
5. **Review cycle**: docs are checked for staleness based on `max_age_days` in the catalog.

*Last reviewed: 2026-05-11*
