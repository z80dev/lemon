# Review: Debt Phase 10 — Monolith and Release Footprint Reduction

## Plan ID
PLN-20260222-debt-phase-10-monolith-footprint-reduction

## Review Date
2026-02-24

## Reviewer
zeebot

## Summary

All four milestones are complete. Phase 10 accomplished its primary goals: config/doc drift was
cleaned up in the MarketIntel app, the gateway JS asset footprint was analyzed and confirmed already
minimal, a decomposition blueprint for `Ai.Models` was documented, and the release footprint was
measured and baselined. The actual per-provider extraction and Session sub-module splits were
intentionally deferred to Phase 5 M2 (blueprints provided in M3 and the session analysis).

## Milestone Review

| Milestone | Status | Notes |
|-----------|--------|-------|
| M1: Config/doc drift cleanup | ✅ Complete | 4 files updated in `apps/market_intel/` |
| M2: Gateway JS asset analysis | ✅ Complete | No action needed — `node_modules` already gitignored |
| M3: Ai.Models decomposition plan | ✅ Complete | Per-provider extraction blueprint documented |
| M4: Release footprint measurement | ✅ Complete | Baselines captured in plan document |

## Code Changes Verified

### `apps/market_intel/config/config.exs`
- Stale migration comment referencing "old flat keys" removed
- Replaced with accurate note: `# Ingestion feature flags live in the umbrella root config`

### `apps/market_intel/lib/market_intel/config.ex`
- Added legacy debt annotation to `maybe_backfill_legacy_x_account_id/1` (lines 105-110)
- Annotation correctly references this plan and explains the migration shim intent

### `apps/market_intel/README.md`
- "Future Enhancements" wish-list (lines 218-229) replaced with a tracked backlog section
- Backlog links to `PLN-20260222-debt-phase-10-monolith-footprint-reduction.md` (M1) and `AGENTS.md`

### `apps/market_intel/AGENTS.md`
- Stub status annotations added for: Twitter fetch, DB persistence, holder stats, deep analysis
- Each stub cross-references this plan (M1) for tracking

## Test Results

```
$ mix test apps/market_intel
EXIT: 0
```

No regressions. All market_intel tests pass.

## Quality Checks

- [x] `mix compile --no-optional-deps` exits 0, no warnings
- [x] `mix test apps/market_intel` exits 0, no failures
- [x] All M1 code changes are non-behavioral (comments, docs, annotations)
- [x] No new code added — only cleanup and annotation
- [x] Deferred items clearly documented in plan progress log

## Deferred Items (tracked in plan)

The following were explicitly deferred and documented:
- Actual `Ai.Models` per-provider file extraction (Phase 5 M2, blueprint in M3)
- Actual `CodingAgent.Session` sub-module extraction (Phase 5 M2, blueprint in session analysis)
- Removal of `maybe_backfill_legacy_x_account_id/1` once all envs confirmed migrated
- Moving voice shell scripts from `lemon_gateway/priv/` to `scripts/` if not needed at runtime

## Recommendation

Approve for landing. All milestones complete. M1 changes are low-risk doc/annotation cleanup.
Deferred items are tracked and do not block landing.
