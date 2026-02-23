# PLN-20260222: Debt Phase 6 — CI & Test Signal Hardening

**Status:** Complete
**Branch:** `feature/pln-20260222-debt-phase-06-ci-test-hardening`
**Created:** 2026-02-22

## Goal

Make CI failures trustworthy by removing skipped test paths with deterministic mocking.

## Milestones

- [x] **M1** — Discovery test unskip migration (11 `@tag :skip` in `discovery_test.exs`)
- [x] **M2** — CI edge-case coverage parity (6 `@tag :skip_on_ci` in read/write/patch tool tests)
- [x] **M3** — (COMPLETE from Phase 3) Duplicate-module guard rollout
- [x] **M4** — CI gate verification (non-wasm discovery integration coverage)

## Exit Criteria Verification

- [x] No `@tag :skip` in `apps/lemon_skills/test/lemon_skills/discovery_test.exs`
- [x] No `@tag :skip_on_ci` in read/write/patch tool tests
- [x] CI `elixir-test-suite` job (`mix test --exclude integration`) covers non-wasm discovery integration

## Progress Log

| Timestamp | Milestone | Note |
|-----------|-----------|------|
| 2026-02-22T00:00 | -- | Plan created, starting M1 discovery test unskip |
| 2026-02-22T00:01 | M1 | Created `HttpClient.Mock` agent-based stub, rewired test_helper.exs, removed all 11 `@tag :skip` from discovery_test.exs — 14 tests pass (2 integration excluded) |
| 2026-02-22T00:02 | M2 | Created `PermissionHelpers` with `with_unreadable/2`, `with_unwritable_dir/2`, `with_readonly_file/2`. Replaced all 6 `@tag :skip_on_ci` in read/write/patch tests. All 166 tool tests pass. |
| 2026-02-22T00:03 | M4 | Verified `elixir-test-suite` CI job runs `mix test --exclude integration` which covers all newly-unskipped tests. No workflow changes needed. |
