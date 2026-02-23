# PLN-20260222: Debt Phase 11 — Placeholder and Stub Burn-Down

**Status:** Complete
**Branch:** `feature/pln-20260222-debt-phase-11-placeholder-stub-burndown`
**Created:** 2026-02-22

## Goal

Replace placeholder behaviors in production-facing runtime paths with real
implementations or explicitly managed feature flags.

## Milestones

- [x] **M1** — Router status/count placeholder removal
- [x] **M2** — MarketIntel placeholder replacement (AI commentary + holder stats)
- [x] **M3** — Voice/media and adapter TODO closure

## Exit Criteria

- [x] No placeholder count values returned by run orchestrator status APIs
- [x] Commentary generation can succeed through an AI provider path in non-fallback mode
- [x] Voice path performs valid mulaw conversion suitable for Twilio playback
- [x] X API TODO list has named owners, target phases, and linked tracking issues

---

## Progress Log

| Timestamp | Milestone | Action |
|-----------|-----------|--------|
| 2026-02-22T00:00 | — | Plan created |
| 2026-02-22T19:35 | M1 | Created RunCountTracker with telemetry-driven counters for queued/completed_today |
| 2026-02-22T19:35 | M1 | Updated RunOrchestrator.counts/0 to read from RunCountTracker instead of returning hardcoded 0 |
| 2026-02-22T19:35 | M1 | Added RunCountTracker to LemonRouter application supervisor |
| 2026-02-22T19:35 | M1 | Added tests for telemetry-driven counting and non-placeholder behavior |
| 2026-02-22T19:40 | M2 | Replaced generate_with_openai/generate_with_anthropic stubs with real Ai.complete path |
| 2026-02-22T19:40 | M2 | generate_tweet now tries AI first, falls back to templates only on failure |
| 2026-02-22T19:40 | M2 | Replaced placeholder holder stats with feature-flagged (market_intel.holder_stats_enabled) implementation |
| 2026-02-22T19:40 | M2 | When enabled, holder stats fetch from BaseScan token info API |
| 2026-02-22T19:40 | M2 | Updated tests for AI provider integration and feature-flagged holder stats |
| 2026-02-22T19:43 | M3 | Created AudioConversion module with pure-Elixir ITU-T G.711 mu-law encoder |
| 2026-02-22T19:43 | M3 | Updated CallSession.convert_pcm_to_mulaw to use AudioConversion; detects MP3 input |
| 2026-02-22T19:43 | M3 | Converted X API README TODO list into owned backlog table with phases and owners |
| 2026-02-22T19:43 | M3 | Added comprehensive AudioConversion tests (monotonicity, edge cases, round-trip) |

