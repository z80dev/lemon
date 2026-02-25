# Review: macOS Keychain Secrets Path Audit and Hardening

## Plan ID
PLN-20260223-macos-keychain-secrets-audit

## Review Date
2026-02-25

## Reviewer
janitor

## Summary
Completed the planned keychain/secrets audit pass by adding a checked-in path matrix, tightening fallback-precedence coverage, and validating current behavior contracts for keychain unavailability and malformed key material.

## Scope Reviewed
- `docs/security/secrets-keychain-audit-matrix.md`
- `README.md`
- `apps/lemon_core/AGENTS.md`
- `apps/lemon_core/test/lemon_core/secrets/master_key_test.exs`
- `apps/lemon_core/test/lemon_core/secrets_test.exs`
- `planning/plans/PLN-20260223-macos-keychain-secrets-audit.md`

## Validation
```bash
mix test apps/lemon_core/test/lemon_core/secrets/master_key_test.exs apps/lemon_core/test/lemon_core/secrets_test.exs
mix test apps/lemon_core
```

## Quality Checklist
- [x] Audit matrix checked in with read/write/fallback mappings
- [x] Keychain unavailable + invalid-key fallback behaviors covered by tests
- [x] Secret resolve precedence (`prefer_env`, `env_fallback`) explicitly tested
- [x] User/operator docs updated with audit matrix reference
- [x] Plan metadata updated to `ready_to_land`

## Notes
- Existing umbrella warning about `apps/lemon_ingestion` missing `mix.exs` persists and is unrelated.
- `mix lemon.quality` was not run in this pass due runtime cost; focused validation ran on affected lemon_core scope.

## Recommendation
Approve and keep in `ready_to_land` pending final landing commit bookkeeping.
