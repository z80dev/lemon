# Lemon Documentation

> Canonical documentation hub for the Lemon AI assistant platform.
> For quickstart and project overview, see the root [README.md](https://github.com/z80dev/lemon/blob/main/README.md).
> For agent development context, see [AGENTS.md](https://github.com/z80dev/lemon/blob/main/AGENTS.md).

---

## How to Use This Directory

- **Start here** if you need to understand how Lemon works at a system level.
- **Per-app docs** live in each app's own `README.md` and `AGENTS.md` (see `apps/*/`).
- **Every tracked Markdown file in `docs/`** must be registered in [`docs/catalog.exs`](https://github.com/z80dev/lemon/blob/main/docs/catalog.exs). Run `mix lemon.quality` to enforce coverage, metadata, freshness, and links.

### Catalog Metadata

`docs/catalog.exs` is a data-only map with shared `defaults` and an `entries`
list. Each normalized entry has:

- `path`, `owner`, `last_reviewed`, and `max_age_days` for ownership and freshness
- `kind`: `guide`, `plan`, `proof`, `reference`, or `review`
- `status`: `current`, `historical`, or `superseded`
- `public`: whether a current document is eligible for future public navigation

The defaults are intentionally conservative: entries are current references
but are not public unless opted in. Historical and superseded entries cannot be
public. Override a default only on the entry that differs.

The catalog's `last_reviewed` value is the sole freshness authority. Do not add
or update a second `Last reviewed` footer in a document; dates in document prose
should identify the snapshot or event they describe. Coverage uses `git
ls-files`, so local drafts and other untracked Markdown do not create quality
failures.

---

## User Guides

| Doc | What it covers |
|-----|---------------|
| [index.md](index.md) | Public docs-site homepage: positioning, entry points, current launch stage |
| [getting-started/quickstart.md](getting-started/quickstart.md) | Task-first release install, provider-backed chat proof, session continuity, next features, and recovery |
| [install.md](install.md) | Verified release install, source install, first-run setup, platforms, updates, and uninstall |
| [compare.md](compare.md) | Product comparison against adjacent assistant, CLI, harness, and self-hosted runtime categories |
| [demo.md](demo.md) | Deterministic local demo paths for runtime health, session Web UI, TUI, support bundles, and docs quality |
| [support.md](support.md) | Public support boundaries, issue data requirements, support-bundle commands, and security-reporting path |
| [user-guide/setup.md](user-guide/setup.md) | Full setup walkthrough: install, configure, run, Telegram setup |
| [user-guide/backups.md](user-guide/backups.md) | Versioned `~/.lemon` data contract, atomic backup verification, and guarded restore |
| [user-guide/web.md](user-guide/web.md) | Launch the local browser, complete readiness, stop runs, configure access, and recover errors |
| [user-guide/profiles.md](user-guide/profiles.md) | Create isolated specialist profiles, use canonical chats/roster, clone/export safely, and delete recoverably |
| [user-guide/learn-from-sources.md](user-guide/learn-from-sources.md) | Review bounded files, folders, documents, diffs, URLs, and sessions before exact-digest learning into memory and skill drafts |
| [user-guide/cli.md](user-guide/cli.md) | Runtime command families, durable session lifecycle, stable exit codes, JSON, and shell completion |
| [user-guide/migrate-from-hermes.md](user-guide/migrate-from-hermes.md) | Preview-first migration path for Hermes memories, skills, config, secrets, and session recall |
| [user-guide/skills.md](user-guide/skills.md) | Skills: listing, installing, inspecting, portable profile automation bundles, and synthesized drafts |
| [user-guide/memory.md](user-guide/memory.md) | Memory documents, session search, retention management |
| [user-guide/adaptive.md](user-guide/adaptive.md) | Adaptive routing, routing feedback, skill synthesis pipeline |
| [user-guide/rollout.md](user-guide/rollout.md) | Feature promotion gates, rollback procedure, promotion checklist |

## Architecture

| Doc | What it covers |
|-----|---------------|
| [architecture/overview.md](architecture/overview.md) | System design, app map, data flow, key abstractions |
| [architecture_boundaries.md](architecture_boundaries.md) | Dependency policy between umbrella apps, enforcement via `mix lemon.quality` |
| [architecture/review-2026-09.md](architecture/review-2026-09.md) | September 2026 architecture review: findings with evidence, a phased plan, and quality ratchets |
| [platform/reliability-contracts.md](platform/reliability-contracts.md) | What each seam between apps promises when something goes wrong, and how the promise is enforced |
| [platform/owned-storage.md](platform/owned-storage.md) | How persistent state is split between the modules that own it and the store that keeps it |
| [platform/run-ownership.md](platform/run-ownership.md) | Who owns each transition of a run across the router, the execution runtime and the agent, and the public run-event contract |
| [beam_agents.md](beam_agents.md) | BEAM/OTP architecture: process-per-agent, supervision, message passing |
| [model-selection-decoupling.md](model-selection-decoupling.md) | Model selection design: provider abstraction, routing, fallback |

## Operations

| Doc | What it covers |
|-----|---------------|
| [long-running-agent-harnesses.md](long-running-agent-harnesses.md) | Long-running harness patterns, eval loops, and runtime validation workflows |
| [testing.md](testing.md) | Canonical local test lanes and CI parity guidance |
| [benchmarks/platform-microbenchmarks.md](benchmarks/platform-microbenchmarks.md) | Reproducible `mix lemon.bench` numbers for the store, event bus, streaming coalescers, and per-conversation process lifecycle |
| [config.md](config.md) | TOML configuration reference (providers, runtime, gateway, profiles, tools) |
| [user-guide/backups.md](user-guide/backups.md) | Local user-state backup, verification, restore, and rollback safety model |
| [user-guide/updates.md](user-guide/updates.md) | Non-mutating update plans, exact-confirm apply, receipts, and receipt-bound rollback |
| [extensions.md](extensions.md) | Extension/plugin API, tool hooks, conflict resolution |
| [release/release_checklist_and_support_policy.md](release/release_checklist_and_support_policy.md) | 1.0 release-candidate checklist, rollback checklist, and support boundaries |
| [security/safety.md](security/safety.md) | Plain-language Lemon safety model, recommended defaults, and support-bundle guidance |
| [security/agent-safety-contract.md](security/agent-safety-contract.md) | Agent safety layers: tool policies, approvals, memory screening, skill audits, telemetry |

## Runtime Core

| Doc | What it covers |
|-----|---------------|
| [assistant_bootstrap_contract.md](assistant_bootstrap_contract.md) | How sessions bootstrap: system prompt assembly, skill discovery/loading, context setup |
| [context.md](context.md) | Context management, compaction, branch summarization, token budgets |
| [subagent-parent-questions.md](subagent-parent-questions.md) | Design for the `ask_parent` clarification path from child subagents back to their parent session |
| [runtime-hot-reload.md](runtime-hot-reload.md) | Hot code reload system for live-patching without restarts |
| [telemetry.md](telemetry.md) | Telemetry events, observability, correlation IDs, monitoring |

## Product and Capability Docs

- [`docs/skills.md`](skills.md)
- [`docs/compare.md`](compare.md) - Lemon positioning against hosted assistants, single-engine CLIs, agent harnesses, and self-hosted automation
- [`docs/demo.md`](demo.md) - Local deterministic demo flows for runtime, session Web UI, TUI, support bundles, and docs quality
- [`docs/support.md`](support.md) - Public support policy landing page and issue-prep checklist
- [`docs/for-dummies/README.md`](for-dummies/README.md) - Plain-English guided tour of Lemon for non-Elixir users
- [`docs/skills_v2.md`](skills_v2.md) - Skill manifest v2 and newer skill-system direction
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)
- [`docs/tools/media.md`](tools/media.md)
- [`docs/tools/lsp.md`](tools/lsp.md)
- [`docs/tools/openai-compatible-api.md`](tools/openai-compatible-api.md)
- [`docs/tools/acp.md`](tools/acp.md)
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
| `config/` | Elixir application configuration (config.exs, runtime.exs, etc.) |
| `examples/config.example.toml` | Annotated example TOML configuration |

## Maintenance Rules

1. **Register every tracked Markdown doc** in [`docs/catalog.exs`](https://github.com/z80dev/lemon/blob/main/docs/catalog.exs); rely on catalog defaults and override only differing metadata.
2. **Run `mix lemon.quality`** after any docs edit or app dependency change.
3. **Keep `AGENTS.md` short and operational** — place durable implementation details in `docs/` files.
4. **Update diagrams** when architecture changes — edit the `.excalidraw` source, export to `.svg`.
5. **Review cycle**: docs are checked for staleness based on the catalog's canonical `last_reviewed` and `max_age_days` values.
6. **Regenerate machine-readable docs** with `scripts/generate_docs_llms.py`; `scripts/generate_docs_llms.py --check` verifies `docs/public/llms.txt` and `llms-full.txt` are current.
