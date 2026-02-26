# Review: Deterministic CI and Test Signal Hardening

## Plan ID
PLN-20260224-deterministic-ci-test-hardening

## Review Date
2026-02-25

## Reviewer
janitor

## Summary
Closed out M6/M7 by adding CI guardrails against newly skipped tests, introducing a deterministic regression loop for historically flaky suites, and documenting deterministic test-writing patterns.

## Scope Reviewed
- `.github/workflows/quality.yml`
- `docs/testing/deterministic-test-patterns.md`
- `docs/catalog.exs`
- `planning/plans/PLN-20260224-deterministic-ci-test-hardening.md`

## Validation
```bash
rg -n "@tag\s+:skip|@tag\s+skip:" apps --glob "*test*.exs"
for i in 1 2; do
  mix test \
    apps/coding_agent/test/coding_agent/session_overflow_recovery_test.exs \
    apps/coding_agent/test/coding_agent/tools/fuzzy_test.exs \
    apps/lemon_skills/test/lemon_skills/discovery_readme_test.exs \
    apps/lemon_skills/test/mix/tasks/lemon.skill_test.exs
done
```

## Quality Checklist
- [x] CI fails fast when new skip tags are committed in test files
- [x] Deterministic regression suites are executed repeatedly in CI
- [x] Deterministic testing guidance documented and cataloged
- [x] Plan milestones M1-M7 and exit criteria are all complete

## Notes
- Validation succeeded with no skip tags detected and two consecutive green runs for the targeted deterministic suites.
- The local test environment still emits pre-existing runtime warnings unrelated to this plan (Nostrum optional binaries and Exqlite config warnings during suite boot).

## Recommendation
Approve and keep in `ready_to_land` pending final landing commit bookkeeping.
