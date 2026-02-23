# PLN-20260223: macOS Keychain Secrets Path Audit and Hardening

**Status:** Planned  
**Branch:** `feature/pln-20260223-macos-keychain-secrets-audit`  
**Created:** 2026-02-23  

## Goal

Audit all macOS Keychain and secret-resolution behavior end-to-end, document exactly where secrets are written and read, verify fallback semantics, and add extensive tests so secret handling remains correct and safe under refactors.

## Milestones

- [ ] **M1** — Secrets flow inventory and contract mapping
- [ ] **M2** — Behavior verification (read/write/fallback/error) against current implementation
- [ ] **M3** — Test hardening and edge-case expansion for keychain + master key + resolve paths
- [ ] **M4** — Documentation updates and operational guidance

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

- [ ] A checked-in matrix documents where each secret path writes and reads.
- [ ] Keychain unavailable/missing/denied/timeout/invalid-key cases are covered by tests.
- [ ] Fallback precedence is explicitly tested and documented.
- [ ] User/operator docs reflect validated behavior and known caveats.
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
