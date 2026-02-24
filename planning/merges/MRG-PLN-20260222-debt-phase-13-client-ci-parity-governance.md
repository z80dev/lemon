---
plan_id: PLN-20260222-debt-phase-13-client-ci-parity-governance
status: ready_to_land
prepared_at: 2026-02-24
prepared_by: janitor
---

# Merge Record: Debt Phase 13 — Client CI Parity & Dependency Governance (M7/M9/M10)

## Summary

This change completes Phase 13 milestones **M7**, **M9**, and **M10** on top of previously completed M1–M6.
M8 (security vuln resolution requiring upstream/transitive fixes) and M11 (monorepo workspace decision) remain deferred.

## Completed in this change

### M7 — ESLint parity for `lemon-tui` and `lemon-browser-node`

- Added `eslint.config.js` to both packages (flat config via `typescript-eslint`)
- Added `lint` npm scripts
- Added eslint devDependencies and lockfile updates
- Added CI lint steps for both clients
- Set pragmatic initial rule profile (`no-unused-vars`, `no-explicit-any`, `no-control-regex` disabled) so lint is actionable without failing on legacy code debt

### M9 — `lemon-web/server` tests

- Extracted pure helpers from `src/index.ts` into `src/utils.ts`
- Added `src/utils.test.ts` with **54 tests**
- Added `vitest.config.ts`
- Added `test`/`test:watch` scripts and server test step in CI

### M10 — dependency alignment

- Aligned `@types/node` to v24 in `lemon-tui` and `lemon-browser-node`
- Aligned vitest majors to v3 for `lemon-tui` and `lemon-browser-node`
- Added `@types/node` and vitest to `lemon-web/server`
- Updated package lockfiles for reproducible `npm ci`

## Validation

### Elixir

- `mix test apps/lemon_gateway/test/email/inbound_security_test.exs` ✅ (8 tests)
- `mix test apps/lemon_services/test` ✅ (14 tests)

### TypeScript / Clients

- `clients/lemon-web/server`: test + typecheck ✅ (54 tests)
- `clients/lemon-web/shared`: test ✅ (108 tests)
- `clients/lemon-tui`: lint + typecheck + test ✅ (947 tests)
- `clients/lemon-browser-node`: lint + typecheck + test ✅ (15 tests)

## Related Artifacts

- Plan: `planning/plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md`
- Review: `planning/reviews/RVW-PLN-20260222-debt-phase-13.md`
- Workspace bookmark: `feature/pln-20260222-debt-phase-13-client-ci-parity-governance`
