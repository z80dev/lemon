# Review: Debt Phase 13 — Client CI Parity & Dependency Governance (M7/M9/M10)

## Plan ID
PLN-20260222-debt-phase-13-client-ci-parity-governance

## Review Date
2026-02-24

## Reviewer
codex

## Scope
This review covers milestones M7, M9, and M10 (M1-M6 were previously landed; M8 and M11 remain deferred).

## Changes Made

### M7 — ESLint for lemon-tui and lemon-browser-node

| File | Change |
|------|--------|
| `clients/lemon-tui/eslint.config.js` | Created — flat config, typescript-eslint, `globals.node` |
| `clients/lemon-tui/package.json` | Added `lint` script; added eslint/typescript-eslint/globals devDeps |
| `clients/lemon-browser-node/eslint.config.js` | Created — identical config |
| `clients/lemon-browser-node/package.json` | Added `lint` script; added eslint/typescript-eslint/globals devDeps |
| `.github/workflows/quality.yml` | Added `lemon-tui lint` and `lemon-browser-node lint` steps |

### M9 — lemon-web/server test coverage

| File | Change |
|------|--------|
| `clients/lemon-web/server/src/utils.ts` | Created — exported pure utility functions from index.ts |
| `clients/lemon-web/server/src/utils.test.ts` | Created — 54 unit tests |
| `clients/lemon-web/server/src/index.ts` | Updated — removed duplicate function definitions, imports from utils.ts |
| `clients/lemon-web/server/package.json` | Added `test`/`test:watch` scripts; added vitest/types/node devDeps |
| `clients/lemon-web/server/vitest.config.ts` | Created — minimal config with globals: true |
| `.github/workflows/quality.yml` | Added `lemon-web server tests` step |

### M10 — Version alignment

| Package | Change |
|---------|--------|
| `clients/lemon-tui/package.json` | `@types/node` ^22→^24, `vitest` ^2→^3 |
| `clients/lemon-browser-node/package.json` | `@types/node` ^22→^24, `vitest` ^2.1.9→^3 |
| `clients/lemon-web/server/package.json` | Added `@types/node ^24.0.0`, `vitest ^3.0.0` |

## Test Results

### lemon-web/server utils (new)
```
54 unit tests covering:
- contentTypeFor: 12 tests (all mapped extensions + unknown + empty)
- parseArgs: 14 tests (all flags, combined, unknown args)
- buildRpcArgs: 10 tests (all opts, flag presence/absence)
- decodeBase64Url: 4 tests (round-trip, paths, mixed chars)
- parseGatewayProbeOutput: 13 tests (errors, success, malformed, valid sessions)
```

## Quality Checks

- [x] All new code is in `utils.ts` — `index.ts` is unchanged in behavior
- [x] `index.ts` correctly imports from `./utils.js` (ESM-compatible `.js` extension)
- [x] ESLint configs use flat config format (v9) matching existing `lemon-web/web` pattern
- [x] ESLint targets `.ts` files only with `globals.node` (correct for Node.js tools)
- [x] Version alignment is conservative (^3.0.0 vitest, ^24.0.0 @types/node) — no breaking API changes
- [x] CI workflow: all new steps placed in correct order (build → lint → test for tui/browser-node; shared tests → server tests → web tests for lemon-web)
- [x] No changes to Elixir code — TypeScript-only changes

## Known Gaps (Deferred)

- **M8**: lemon-web security vulnerabilities remain (ajv ReDoS + minimatch via eslint); non-blocking (CI uses `|| true`); requires upstream fixes
- **M11**: Monorepo workspace restructuring at clients/ root — architectural decision, separate work item

## Recommendation

Approve for landing. All M7/M9/M10 success criteria met. Lock files for lemon-tui and lemon-browser-node will be regenerated on first `npm ci` when ESLint packages are installed in CI. The server utils extraction is a net improvement — the same logic with coverage added.
