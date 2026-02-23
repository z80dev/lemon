---
id: PLN-20260222-agent-introspection
title: End-to-end agent introspection (commands, tools, tasks, lineage)
status: in_progress
priority_bucket: now
owner: codex
reviewer: codex
branch: feature/pln-20260222-agent-introspection-m1
created: 2026-02-22
updated: 2026-02-23
roadmap_ref: ROADMAP.md:74
review_doc: planning/reviews/RVW-PLN-20260222-agent-introspection.md
merge_doc: planning/merges/MRG-PLN-20260222-agent-introspection.md
decision_docs: []
depends_on: []
---

# Summary

Implement an end-to-end introspection system so operators can inspect agent execution state and lineage across Lemon-native and external engines.

## Scope

- In scope:
  - Canonical event schema for introspection events.
  - Store API for append/query with filtering and retention sweep.
  - Redaction defaults for sensitive payload fields.
  - Unit-test coverage for canonical contract and filtering behavior.
- Out of scope:
  - Full control-plane timeline API rollout.
  - External-engine adapter parity work.

## Milestones

- [x] M0 - Discovery and architecture direction.
- [x] M1 - Event model and storage contract.
- [ ] M2 - Lemon-native instrumentation coverage.
- [ ] M3 - External-engine adapter enrichment.
- [ ] M4 - Query/operations surfaces and runbooks.

## M1 Delivered

- Added `LemonCore.Introspection` as canonical envelope builder and persistence API.
- Added `LemonCore.Store.append_introspection_event/1` and `LemonCore.Store.list_introspection_events/1`.
- Added event validation/filter/sort logic and periodic retention sweep for `:introspection_log`.
- Added targeted test coverage and docs updates.

## Evidence

- Code commit: `62144b29` (`feat(lemon_core): add canonical introspection event store contract`).
- Key files:
  - `apps/lemon_core/lib/lemon_core/introspection.ex`
  - `apps/lemon_core/lib/lemon_core/store.ex`
  - `apps/lemon_core/test/lemon_core/introspection_test.exs`
  - `apps/lemon_core/test/lemon_core/store_test.exs`
  - `apps/lemon_core/AGENTS.md`
  - `docs/telemetry.md`

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit | `mix test apps/lemon_core/test/lemon_core/introspection_test.exs apps/lemon_core/test/lemon_core/store_test.exs apps/lemon_core/test/lemon_core_test.exs` | 0 failures | `codex` | `pass` |
| quality | `mix lemon.quality` | full quality gates pass | `codex` | `blocked` |

Quality blockers are unrelated to introspection scope:
- Duplicate test modules in `apps/ai/test/...` from concurrent AI test expansion work.
- Existing architecture-boundary violations in `apps/market_intel/lib/market_intel/commentary/pipeline.ex`.

## Risks and Mitigations

- Risk: Heterogeneous engine metadata availability.
  - Mitigation: retain provenance and optional fields in canonical envelope.
- Risk: Event growth/storage churn.
  - Mitigation: retention sweep and query limits.
- Risk: Sensitive payload leakage.
  - Mitigation: default redaction in `LemonCore.Introspection`.

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-22 | `codex` | Plan initiated for introspection workstream | `planning/INDEX.md` |
| 2026-02-23 | `codex` | M1 store/schema contract implemented in isolated worktree and cherry-picked to `main` | `62144b29`, `apps/lemon_core/lib/lemon_core/introspection.ex` |
| 2026-02-23 | `codex` | M1 unit tests passed on `main` | `mix test ...` (32 tests, 0 failures) |

## Completion Checklist

- [x] M1 scope delivered
- [x] Tests recorded with pass/fail evidence
- [ ] Review artifact completed
- [ ] Merge artifact completed
- [x] Relevant docs updated (`AGENTS.md`, `docs/telemetry.md`, module docs)
- [ ] Plan status set to `merged`
