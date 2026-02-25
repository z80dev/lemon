---
plan_id: PLN-20260224-deterministic-ci-test-hardening
landed_at: pending
landed_by: janitor
---

# Merge Record: Deterministic CI and Test Signal Hardening

## Summary
Prepare landing for deterministic CI hardening by enforcing no-skip test policy, adding a repeatable regression loop for historically flaky suites, and documenting deterministic test patterns.

## Artifacts
- Plan: `planning/plans/PLN-20260224-deterministic-ci-test-hardening.md`
- Review: `planning/reviews/RVW-PLN-20260224-deterministic-ci-test-hardening.md`

## Landing Checklist
- [x] M1 skip-tag inventory completed
- [x] M2 Codex runner module-load issue fixed and validated
- [x] M3 run-process module availability fixed and validated
- [x] M4 event-stream timing flake addressed
- [x] M5 skip-tag burndown complete
- [x] M6 CI skip-tag guard + deterministic regression loop added
- [x] M7 deterministic testing patterns documented
- [x] Plan status set to `ready_to_land`
- [ ] Final trunk landing commit recorded in `planning/INDEX.md` Recently Landed table
- [ ] `landed_at` and landed revision filled after merge
