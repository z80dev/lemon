# Roadmap (Living Document)

Last updated: 2026-02-22
Maintainers: Shared (any contributor/agent touching related work)

## How to Use This File

This file is a **living roadmap** for improvement areas, experiments, and future concepts. It is intentionally **loosely prioritized**. Items in the same section are not rank-ordered.

1. Capture ideas early. If something might matter later, add it here with a short outcome statement.
2. Keep items outcome-focused. Describe the user/system impact, not just implementation details.
3. Use roadmap buckets, not strict rankings:
   - `Now`: important near-term work (next few weeks)
   - `Next`: meaningful follow-up work after current focus
   - `Later`: valuable but not urgent
   - `Explore`: research/spikes/uncertain bets
4. Every item should include lightweight metadata in this format:
   - `[area:<app-or-domain>] [status:<idea|planned|active|blocked|done>] [impact:<H|M|L>] [effort:<S|M|L>] [updated:YYYY-MM-DD]`
5. When code or docs land for an item, update this file in the same change:
   - update `status`
   - update `updated` date
   - add/refresh links under `Refs`
6. During weekly review, move items across buckets based on current reality.
7. Do not delete completed items immediately. Move them to `Done / Archive` to preserve context.

## Item Template

```md
- [ ] <Initiative title> [area:<...>] [status:idea] [impact:M] [effort:M] [updated:YYYY-MM-DD]
  - Outcome: <what gets better if this is done>
  - Next: <smallest next step>
  - Refs: <issue/PR/doc paths>
```

## Now (Loose Priority)

- [ ] Deterministic CI and test signal hardening [area:quality] [status:planned] [impact:H] [effort:M] [updated:2026-02-22]
  - Outcome: Failures represent real regressions, with fewer flaky or skipped paths.
  - Next: Remove remaining skip tags where deterministic mocks are possible.
  - Refs: `debt_plan.md`, `.github/workflows/quality.yml`

- [ ] Run-state concurrency safety in coding agent [area:coding_agent] [status:planned] [impact:H] [effort:M] [updated:2026-02-22]
  - Outcome: No lost or conflicting run transitions under concurrent updates.
  - Next: Add stress tests around `RunGraph` transition paths.
  - Refs: `apps/coding_agent/lib/coding_agent/run_graph.ex`

- [ ] Session/store write-path scalability [area:lemon_core] [status:idea] [impact:H] [effort:L] [updated:2026-02-22]
  - Outcome: Stable latency as history grows; reduced mailbox/write amplification.
  - Next: Benchmark current append/cleanup hot paths and publish baseline numbers.
  - Refs: `apps/lemon_core/lib/lemon_core/store.ex`, `apps/coding_agent/lib/coding_agent/session_manager.ex`

- [ ] Gateway runtime failure isolation [area:lemon_gateway] [status:idea] [impact:H] [effort:M] [updated:2026-02-22]
  - Outcome: Localized transport/worker failures without broad message flow degradation.
  - Next: Audit supervision tree for fanout, monitor, and worker restart semantics.
  - Refs: `apps/lemon_gateway/`

- [ ] Documentation drift prevention sweep [area:docs] [status:active] [impact:M] [effort:M] [updated:2026-02-22]
  - Outcome: AGENTS/README/docs consistently reflect current behaviors and configuration.
  - Next: Add a recurring checklist for changed modules/config/env vars.
  - Refs: `AGENTS.md`, `docs/README.md`

## Next (Loose Priority)

- [ ] Model routing policy with explicit fallback rules [area:ai] [status:idea] [impact:H] [effort:M] [updated:2026-02-22]
  - Outcome: Predictable model/provider behavior across latency, cost, and failure modes.
  - Next: Define policy matrix by task type and required capabilities.
  - Refs: `apps/ai/`, `apps/lemon_gateway/lib/lemon_gateway/engines/`

- [ ] Skill lifecycle quality gates [area:lemon_skills] [status:idea] [impact:M] [effort:M] [updated:2026-02-22]
  - Outcome: New skills have stronger validation, docs coverage, and upgrade safety.
  - Next: Define minimal acceptance checklist for install/discovery/update flows.
  - Refs: `apps/lemon_skills/`, `docs/skills.md`

- [ ] Unified observability surface [area:telemetry] [status:idea] [impact:H] [effort:L] [updated:2026-02-22]
  - Outcome: Faster diagnosis across gateway/router/coding_agent with shared correlation IDs.
  - Next: Standardize event names and run identifiers across app boundaries.
  - Refs: `docs/telemetry.md`

- [ ] Faster local developer bootstrap path [area:dx] [status:idea] [impact:M] [effort:M] [updated:2026-02-22]
  - Outcome: New contributors can run a practical subset quickly with fewer manual steps.
  - Next: Define a minimal profile target (`gateway + router + core`) and measure startup time.
  - Refs: `README.md`, `bin/lemon-dev`

- [ ] Gateway/channel replay safety and idempotency [area:lemon_channels] [status:idea] [impact:H] [effort:M] [updated:2026-02-22]
  - Outcome: Duplicate inbound/outbound events do not trigger duplicated actions.
  - Next: Add replay/idempotency tests around channel adapters and outbox boundaries.
  - Refs: `apps/lemon_channels/`, `apps/lemon_gateway/`

## Later (Loose Priority)

- [ ] Decompose oversized modules and catalogs [area:architecture] [status:idea] [impact:M] [effort:L] [updated:2026-02-22]
  - Outcome: Smaller ownership surfaces and safer incremental changes.
  - Next: Identify top 5 files by complexity/churn and carve-out candidates.
  - Refs: `apps/ai/lib/ai/models.ex`, `apps/coding_agent/lib/coding_agent/session.ex`

- [ ] Release footprint reduction for bundled JS runtime assets [area:build] [status:idea] [impact:M] [effort:L] [updated:2026-02-22]
  - Outcome: Smaller release artifacts and simpler upgrade path for JS runtime dependencies.
  - Next: Evaluate externalized artifact strategy with integrity/version checks.
  - Refs: `apps/lemon_gateway/priv/`

- [ ] Cross-channel thread continuity model [area:product] [status:idea] [impact:M] [effort:L] [updated:2026-02-22]
  - Outcome: Conversations can move between Telegram/SMS/Discord/XMTP with clearer continuity.
  - Next: Define identity/thread mapping semantics and conflict rules.
  - Refs: `apps/lemon_router/`, `apps/lemon_channels/`

- [ ] Policy engine for tool authorization and rate budgets [area:security] [status:idea] [impact:H] [effort:L] [updated:2026-02-22]
  - Outcome: More explicit risk controls for tool usage by context, source, and environment.
  - Next: Draft policy schema and enforcement points in coding agent.
  - Refs: `apps/coding_agent/`, `apps/lemon_core/`

## Explore (Research / Spikes)

- [ ] Run outcome feedback loop for routing/tool selection [area:agent-loop] [status:idea] [impact:M] [effort:M] [updated:2026-02-22]
  - Outcome: Better first-attempt success rate using local historical signals.
  - Next: Prototype capture of success/failure labels with minimal overhead.
  - Refs: `docs/agent-loop/`

- [ ] Semantic memory layer for long-lived sessions [area:memory] [status:idea] [impact:M] [effort:L] [updated:2026-02-22]
  - Outcome: More stable continuity without replaying full transcript history.
  - Next: Evaluate memory boundaries (per-session/per-user/per-agent) and eviction policy.
  - Refs: `apps/coding_agent/`, `docs/context.md`

- [ ] Voice pipeline latency target (<1s partial response) [area:voice] [status:idea] [impact:M] [effort:L] [updated:2026-02-22]
  - Outcome: More responsive voice interactions with progressive delivery.
  - Next: Measure current baseline and isolate top latency contributors.
  - Refs: `apps/lemon_gateway/`, `VOICE_FIXES.md`

- [ ] Structured benchmark harness for end-to-end scenarios [area:performance] [status:idea] [impact:M] [effort:M] [updated:2026-02-22]
  - Outcome: Repeatable performance regressions detected before release.
  - Next: Define 3 canonical scenarios (short chat, tool-heavy run, long session).
  - Refs: `docs/benchmarks.md`

## Done / Archive

- (Move completed roadmap items here with completion date and links.)
