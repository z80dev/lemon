# PLN-20260222: Debt Phase 13 — Client CI Parity & Dependency Governance

**Status:** In Progress
**Created:** 2026-02-22
**Owner:** codex
**Reviewer:** codex

## Goal

Bring all TypeScript/JS client packages to CI parity with each other and the Elixir umbrella: consistent typecheck, build, test, lint, and dependency audit steps for every client. Establish dependency governance to keep shared packages aligned and free of known vulnerabilities.

## Current State Assessment

### Client packages inventory

| Package | Build | Typecheck | Tests | Lint | CI Coverage | Audit |
|---------|-------|-----------|-------|------|-------------|-------|
| `clients/lemon-tui` | tsup (pass) | tsc (6 errors, fixed) | vitest 947 pass | none | tests only | 5 moderate (esbuild/vite) |
| `clients/lemon-browser-node` | tsup (pass) | tsc (pass) | vitest 15 pass | none | **not in CI** | 5 moderate (esbuild/vite) |
| `clients/lemon-web/shared` | tsup (pass) | tsc (pass) | vitest 108 pass | none | typecheck only (tests missing) | via root |
| `clients/lemon-web/server` | tsup (pass) | tsc (pass) | none | none | typecheck only | via root |
| `clients/lemon-web/web` | vite (pass) | tsc (pass) | vitest 680 pass | eslint (pass) | typecheck+lint+tests | via root |
| `clients/lemon-web` (root) | workspace orchestration | pass | pass | via web | partial | 11 vulns (1 moderate, 10 high) |

### CI workflow analysis (`.github/workflows/quality.yml`)

The existing `clients` job covers:
- lemon-web: install, typecheck, lint, tests (web workspace only)
- lemon-tui: install, tests only

**Missing from CI:**
- lemon-browser-node: entirely absent (no install, typecheck, build, or test)
- lemon-tui: no typecheck step, no build verification
- lemon-web shared: tests not run (only web workspace tests)
- lemon-web: no build verification step
- All clients: no dependency audit step
- lemon-browser-node lock file not in npm cache key

### Dependency version mismatches

| Dependency | lemon-tui | lemon-browser-node | lemon-web/server | lemon-web/shared | lemon-web/web |
|------------|-----------|-------------------|------------------|------------------|---------------|
| ws | ^8.18.0 | ^8.18.0 | ^8.17.1 (fixed to ^8.18.0) | - | - |
| @types/node | ^22.0.0 | ^22.0.0 | - | ^24.0.0 | ^24.10.1 |
| @types/ws | ^8.18.0 | ^8.18.0 | ^8.18.1 | - | - |
| typescript | ^5.0.0 | ^5.0.0 | ^5.0.0 | ^5.0.0 | ~5.9.3 |
| vitest | ^2.0.0 | ^2.1.9 | - | ^3.0.0 | ^4.0.18 |

### Security audit summary

- **lemon-tui**: 5 moderate (esbuild in vitest->vite chain, dev-only)
- **lemon-browser-node**: 5 moderate (same esbuild chain, dev-only)
- **lemon-web**: 11 vulns (1 moderate ajv ReDoS, 10 high minimatch ReDoS in eslint chain)
  - ajv: fixable via `npm audit fix`
  - minimatch: requires eslint upgrade to v10 (breaking change)

## Gaps Identified

1. **lemon-browser-node completely missing from CI** — No install, typecheck, build, or tests
2. **lemon-tui missing typecheck and build steps in CI** — only tests ran
3. **lemon-web/shared tests not executed in CI** — only typecheck via umbrella
4. **No build verification in CI for any client** — builds could break silently
5. **No dependency audit in CI** — vulnerabilities not tracked
6. **lemon-tui typecheck was broken** — 6 TS2749 errors in agent-connection.test.ts (value used as type)
7. **No vitest.config.ts in lemon-tui or lemon-browser-node** — implicit default config
8. **No ESLint config in lemon-tui or lemon-browser-node** — no lint enforcement
9. **No tests in lemon-web/server** — server code untested
10. **Dependency version drift** — ws, @types/node, vitest versions diverge across packages

## Milestones

- [x] **M1** — Fix lemon-tui typecheck errors (6 TS2749 errors in agent-connection.test.ts)
- [x] **M2** — Add lemon-browser-node to CI workflow (install, typecheck, build, test)
- [x] **M3** — Add missing CI steps for lemon-tui (typecheck, build) and lemon-web (build, shared tests)
- [x] **M4** — Add dependency audit steps to CI for all three client roots
- [x] **M5** — Add vitest.config.ts to lemon-tui and lemon-browser-node
- [x] **M6** — Align ws dependency version in lemon-web/server (^8.17.1 -> ^8.18.0)
- [ ] **M7** — Add ESLint config to lemon-tui and lemon-browser-node (future: requires npm install of eslint + typescript-eslint)
- [ ] **M8** — Resolve lemon-web security vulnerabilities (ajv fix, eslint upgrade for minimatch)
- [ ] **M9** — Add test coverage for lemon-web/server
- [ ] **M10** — Align @types/node and vitest versions across all packages
- [ ] **M11** — Consider monorepo-level dependency tooling (npm workspaces at root, or Turborepo)

## Success Criteria

- [x] All three client packages (lemon-tui, lemon-browser-node, lemon-web) have CI steps for: install, typecheck, build, test
- [x] lemon-web/shared tests run in CI
- [x] Dependency audit runs (non-blocking) in CI for all clients
- [x] lemon-tui typecheck passes cleanly
- [x] All existing tests continue to pass
- [ ] No high-severity vulnerabilities in production dependencies
- [ ] ESLint runs for all TypeScript client packages
- [ ] Shared dependency versions are aligned across packages

## Dependency Governance Recommendations

1. **Pin major versions consistently**: All packages should use the same major version of shared dependencies (typescript, vitest, @types/node). Currently vitest ranges from ^2.0.0 to ^4.0.18 across packages.

2. **Separate dev vs production audit policy**: The esbuild/vite vulnerabilities only affect devDependencies (build tooling, test runners). These are lower priority than production dependency vulnerabilities.

3. **Consider workspace hoisting**: A root-level `package.json` with `workspaces` for all three client directories would deduplicate shared devDependencies and make version alignment automatic.

4. **Quarterly audit cadence**: Run `npm audit` monthly with a quarterly remediation window for breaking version bumps.

5. **Lock file hygiene**: All three clients have committed lock files, which is correct. Ensure CI uses `npm ci` (not `npm install`) to enforce lock file integrity.

## Validation Results (2026-02-22)

Validation performed by agent after M1-M6 were applied. All checks passed.

### .github/workflows/quality.yml

The `clients` job was correctly extended with:
- npm cache key now includes `clients/lemon-browser-node/package-lock.json` alongside the other two lock files
- `lemon-web` block added a `lemon-web build` step (`npm run build`) and `lemon-web shared tests` step (`npm --workspace shared run test`), plus audit (`npm audit --audit-level=high || true`)
- `lemon-tui` block added `lemon-tui typecheck` (`npm run typecheck`) and `lemon-tui build` (`npm run build`) before the existing test step, plus audit
- `lemon-browser-node` block added in full: install, typecheck, build, test, audit
- Audit steps use `|| true` so they are non-blocking (informational), which is correct for the first iteration

All step ordering and `working-directory` declarations are correct. No YAML syntax issues observed.

### clients/lemon-tui/vitest.config.ts

Valid minimal config: imports `defineConfig` from `vitest/config`, enables `globals: true`. Matches the pattern used by `lemon-web/web`. No issues.

### clients/lemon-browser-node/vitest.config.ts

Identical config to lemon-tui. Valid and correct.

### clients/lemon-tui/src/agent-connection.test.ts

The TS2749 fix on line 75 uses the idiom `type MockWebSocket = InstanceType<typeof MockWebSocket>`. This creates a local type alias that resolves the "value used as type" error while keeping the value binding from `vi.hoisted()`. The pattern is idiomatic for vitest hoisting scenarios. All 947 tests remain structurally intact.

### clients/lemon-web/server/package.json

`ws` dependency correctly updated from `^8.17.1` to `^8.18.0`. All other fields unchanged. The `@types/ws` is `^8.18.1` which is compatible.

### Elixir compilation

`mix compile --no-optional-deps` exits with code 0 and produces no output — the Elixir umbrella is unaffected by the TypeScript changes.

---

## M7-M11 Assessment (2026-02-22)

### M7 — ESLint config for lemon-tui and lemon-browser-node

**Status: Future — requires npm install**

Neither package currently has eslint or typescript-eslint as a devDependency. Adding an eslint config without first running `npm install` to add the packages would produce a broken config that CI cannot execute. The `lemon-web/web` package uses the flat config format (eslint v9, `eslint.config.js`), which is the correct target format.

**Required work (out of scope for this workspace):**
1. `npm install --save-dev eslint typescript-eslint` in both `clients/lemon-tui` and `clients/lemon-browser-node`
2. Add `eslint.config.js` (flat config, matching `lemon-web/web` pattern)
3. Add `"lint": "eslint ."` script to each `package.json`
4. Add lint steps to the CI workflow after typecheck steps

### M8 — Resolve lemon-web security vulnerabilities

**Status: Partially actionable without npm install**

From the prior audit summary:
- **ajv (1 moderate ReDoS)**: `npm audit fix` would resolve this. Requires running npm in `clients/lemon-web`. Out of scope for this workspace (would modify package-lock.json).
- **minimatch via eslint (10 high ReDoS)**: The `lemon-web/web` package uses `eslint@^9.39.1` and `typescript-eslint@^8.46.4`. The minimatch vulnerability is in the eslint dependency chain. Resolving it requires upgrading to eslint v10 when it becomes available with a fixed minimatch dependency, or waiting for typescript-eslint to release a version that pins a safe minimatch. This is a **transitive dependency issue** — there is no direct action available that does not risk breaking the eslint configuration.
- **esbuild moderate (lemon-tui and lemon-browser-node)**: These are in the vitest→vite→esbuild dev chain. The audit level in CI is `--audit-level=high` so these moderate-severity dev-only issues do not block CI. No action needed until esbuild releases a fix.

**Recommendation**: The audit steps added in M4 will surface these in CI as informational. Track until upstream fixes are available. The `|| true` guard is intentional.

### M9 — Add test coverage for lemon-web/server

**Status: Future — requires careful design**

`clients/lemon-web/server` has no tests and no vitest devDependency. The server package does have a `tsup` build and a `typecheck` script. Adding tests requires:
1. Adding `vitest` as a devDependency (`npm install --save-dev vitest` in `clients/lemon-web/server`)
2. Designing a test strategy (the server likely involves WebSocket/HTTP logic that requires careful mocking)
3. Adding `"test": "vitest run"` script and a vitest.config.ts
4. Writing the actual tests

This is non-trivial and should be a dedicated work item. Marking as future.

### M10 — Align @types/node and vitest versions across all packages

**Status: Partially documentable; changes require npm install**

Current state (from package.json review):

| Package | vitest | @types/node |
|---------|--------|-------------|
| lemon-tui | ^2.0.0 | ^22.0.0 |
| lemon-browser-node | ^2.1.9 | ^22.0.0 |
| lemon-web/shared | ^3.0.0 | ^24.0.0 |
| lemon-web/web | ^4.0.18 | ^24.10.1 |
| lemon-web/server | — | — |

The vitest major version drift (v2 vs v3 vs v4) is the most significant alignment gap. The `lemon-web/web` package drives the highest versions because it uses Vite and the `@vitest/ui` package. The pragmatic target is to align all packages to the minimum major version they can accept without breaking changes, or to upgrade all to v4 simultaneously.

**Recommended alignment targets (to implement when npm install is permitted):**
- `vitest`: upgrade lemon-tui and lemon-browser-node to `^3.0.0` (conservative) or `^4.0.18` (match lemon-web/web)
- `@types/node`: upgrade lemon-tui and lemon-browser-node from `^22.0.0` to `^24.0.0` (match lemon-web/shared)

No changes made in this workspace (npm install required).

### M11 — Monorepo-level dependency tooling

**Status: Future architectural decision**

Three independent npm roots (`clients/lemon-tui`, `clients/lemon-browser-node`, `clients/lemon-web`) are currently managed separately. The `lemon-web` directory already uses npm workspaces for its sub-packages. Extending this pattern to the top level would mean:
- A single `clients/package.json` with `"workspaces": ["lemon-tui", "lemon-browser-node", "lemon-web"]`
- A single `clients/package-lock.json` replacing three separate lock files
- Hoisted shared devDependencies (typescript, vitest, @types/node) automatically aligned

Turborepo is an alternative that adds task orchestration (parallel builds, caching) on top of workspaces. Given the current scale (3 packages), plain npm workspaces is sufficient.

This is a significant structural change that would affect the CI workflow (single `npm ci` at `clients/` level), developer workflows, and lock file history. It should be evaluated as a dedicated architectural decision, not done incrementally.

---

## Progress Log

| Timestamp | Milestone | Note |
|-----------|-----------|------|
| 2026-02-22T21:44 | M1 | Fixed 6 TS2749 errors by adding `type MockWebSocket = InstanceType<typeof MockWebSocket>` alias |
| 2026-02-22T21:45 | M2-M4 | Updated quality.yml: added lemon-browser-node (install/typecheck/build/test), lemon-tui typecheck+build, lemon-web build+shared tests, audit steps for all |
| 2026-02-22T21:45 | M5 | Added vitest.config.ts to lemon-tui and lemon-browser-node |
| 2026-02-22T21:45 | M6 | Aligned ws version in lemon-web/server from ^8.17.1 to ^8.18.0 |
| 2026-02-22 | Validation | Agent validated all M1-M6 changes: quality.yml structure correct, vitest configs valid, TS2749 fix correct, ws version aligned, Elixir compile clean |
| 2026-02-22 | M7-M11 | Assessed remaining milestones: M7/M9/M11 deferred (require npm install or architectural decisions); M8 documented (upstream transitive deps, non-blocking); M10 alignment targets documented |
