---
plan_id: PLN-20260222-debt-phase-10-monolith-footprint-reduction
landed_at: 2026-02-24
landed_by: zeebot
---

# Merge Record: Debt Phase 10 — Monolith and Release Footprint Reduction

## Summary

Phase 10 landed as change `3b102fdc` (jj change `uvlzkvrr`). All four milestones are complete.
The phase cleaned up config/doc drift in the MarketIntel app, confirmed the gateway JS footprint
is already minimal, documented a decomposition blueprint for `Ai.Models`, and baselined the release
footprint. Actual code-splitting extractions were scoped, blueprinted, and deferred to Phase 5 M2.

## Changes Landed

### `apps/market_intel/config/config.exs`
- Removed stale migration comment about "old flat keys (enable_dex, enable_polymarket, etc.)"
- Added accurate comment pointing to the canonical `:ingestion` map in umbrella `config/config.exs`

### `apps/market_intel/lib/market_intel/config.ex`
- Added `# Legacy backfill:` annotation to `maybe_backfill_legacy_x_account_id/1`
- Annotation documents the function as a migration shim, references this plan as tracked debt

### `apps/market_intel/README.md`
- Replaced untracked "Future Enhancements" wish-list with a `## Backlog` section
- Backlog links to `PLN-20260222-debt-phase-10-monolith-footprint-reduction.md` (M1) and `AGENTS.md`

### `apps/market_intel/AGENTS.md`
- Added stub status annotations referencing this plan for: Twitter fetch, DB persistence,
  holder stats, and deep analysis scheduler stub

## Analysis Artifacts (in plan document)

- **M2**: Gateway JS footprint analysis — confirmed `node_modules` gitignored, priv total 80 KB
- **M3**: `Ai.Models` decomposition blueprint — 25 per-provider modules, 95% data / 5% logic
- **Session analysis**: `CodingAgent.Session` extraction targets — 5 sub-modules, ~1,390 lines
- **M4**: Release footprint baselines captured (models.ex 11,203 lines, session.ex 3,261 lines)

## Test Results

```
$ mix test apps/market_intel
EXIT: 0
```

No regressions. All market_intel tests pass.

## Exit Criteria

- [x] Stale migration comment removed from market_intel config
- [x] Legacy annotation added to `maybe_backfill_legacy_x_account_id/1`
- [x] README "Future Enhancements" wish-list converted to tracked backlog
- [x] AGENTS.md stub items annotated with plan cross-references
- [x] `mix compile --no-optional-deps` exits 0
- [x] `mix test apps/market_intel` exits 0
- [x] Decomposition blueprints documented for Phase 5 M2 work
- [x] All deferred items explicitly logged in plan progress log

## Deferred to Future Phases

| Item | Target | Notes |
|------|--------|-------|
| `Ai.Models` per-provider extraction | Phase 5 M2 | Blueprint in M3 |
| `CodingAgent.Session` sub-module split | Phase 5 M2 | Blueprint in session analysis |
| Remove `maybe_backfill_legacy_x_account_id/1` | Future cleanup | Once all envs migrated |
| Move voice scripts from `lemon_gateway/priv/` | Future cleanup | If not needed at runtime |

## Related

- Plan: `planning/plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md`
- Review: `planning/reviews/RVW-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md`
- Change: jj `uvlzkvrr` / git `3b102fdc`
