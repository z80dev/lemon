# PLN-20260222: Debt Phase 11 — Placeholder and Stub Burn-Down

**Status:** In Progress
**Branch:** `feature/pln-20260222-debt-phase-11-placeholder-stub-burndown`
**Created:** 2026-02-22

## Goal

Replace placeholder behaviors in production-facing runtime paths with real
implementations or explicitly managed feature flags.

## Milestones

- [x] **M1** — Router status/count placeholder removal
- [ ] **M2** — MarketIntel placeholder replacement (AI commentary + holder stats)
- [ ] **M3** — Voice/media and adapter TODO closure

## Exit Criteria

- No placeholder count values returned by run orchestrator status APIs
- Commentary generation can succeed through an AI provider path in non-fallback mode
- Voice path performs valid mulaw conversion suitable for Twilio playback
- X API TODO list has named owners, target phases, and linked tracking issues

---

## Progress Log

| Timestamp | Milestone | Action |
|-----------|-----------|--------|
| 2026-02-22T00:00 | — | Plan created |
| 2026-02-22T19:35 | M1 | Created RunCountTracker with telemetry-driven counters for queued/completed_today |
| 2026-02-22T19:35 | M1 | Updated RunOrchestrator.counts/0 to read from RunCountTracker instead of returning hardcoded 0 |
| 2026-02-22T19:35 | M1 | Added RunCountTracker to LemonRouter application supervisor |
| 2026-02-22T19:35 | M1 | Added tests for telemetry-driven counting and non-placeholder behavior |

