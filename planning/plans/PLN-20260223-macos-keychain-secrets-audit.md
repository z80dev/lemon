# PLN-20260223: macOS Keychain Secrets Path Audit and Hardening

**Status:** ready_to_land  
**Owner:** janitor  
**Reviewer:** janitor  
**Workspace:** `feature/pln-20260223-macos-keychain-secrets-audit`  
**Change ID:** `pending`  
**Created:** 2026-02-23  

## Goal

Audit all macOS Keychain and secret-resolution behavior end-to-end, document exactly where secrets are written and read, verify fallback semantics, and add extensive tests so secret handling remains correct and safe under refactors.

## Milestones

- [x] **M1** — Secrets flow inventory and contract mapping
- [x] **M2** — Behavior verification (read/write/fallback/error) against current implementation
- [x] **M3** — Test hardening and edge-case expansion for keychain + master key + resolve paths
- [x] **M4** — Documentation updates and operational guidance

## Scope

- In scope:
  - Map all call paths for secret writes/reads in Lemon Core and runtime consumers.
  - Verify precedence and fallback logic across:
    - macOS Keychain
    - encrypted Lemon secret store
    - environment-variable fallback
  - Validate behavior for missing/denied/timeout/invalid keychain responses.
  - Add or tighten tests for expected behavior and error surfaces.
  - Update docs to reflect actual, validated behavior.
- Out of scope:
  - Non-macOS platform secret backends beyond current behavior documentation.
  - Replacing keychain integration with a new secrets architecture.

## Initial Audit Targets

- `apps/lemon_core/lib/lemon_core/secrets/keychain.ex`
- `apps/lemon_core/lib/lemon_core/secrets/master_key.ex`
- `apps/lemon_core/lib/lemon_core/secrets.ex`
- `apps/lemon_core/test/lemon_core/secrets/keychain_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/master_key_test.exs`
- `apps/lemon_core/test/lemon_core/secrets_test.exs`
- `apps/coding_agent/lib/coding_agent/session.ex` (secret resolve call sites)
- `apps/market_intel/lib/market_intel/secrets.ex` (secrets store/env fallback usage)

## Exit Criteria Verification

- [x] A checked-in matrix documents where each secret path writes and reads.
- [x] Keychain unavailable/missing/denied/timeout/invalid-key cases are covered by tests.
- [x] Fallback precedence is explicitly tested and documented.
- [x] User/operator docs reflect validated behavior and known caveats.
- [ ] `mix lemon.quality` passes after updates.

## Test Strategy

- Unit tests for keychain command wrappers (success + error codes + timeouts + malformed values).
- Unit tests for master key resolution precedence and fallback behavior.
- Integration-style checks for secret resolution in downstream consumers.
- Regression coverage for any bug found during audit.

## Progress Log

| Timestamp | Milestone | Note |
|-----------|-----------|------|
| 2026-02-23T00:00 | -- | Plan created from roadmap request for keychain/secrets audit and extensive testing |
| 2026-02-25T16:00Z | M1, M3, M4 | Claimed by janitor; added checked-in secrets flow matrix documentation and expanded master key/secrets fallback precedence tests |
| 2026-02-25T16:20Z | M2 | Re-ran targeted lemon_core suites (`secrets/master_key_test.exs`, `secrets_test.exs`) plus `mix test apps/lemon_core`; all green |
