# Lemon testing lanes

`scripts/test` is the repo-level test runner. CI calls the same lanes, so a
lane that passes locally runs the same commands in CI.

## Quick usage

```bash
scripts/test help
scripts/test fast        # what CI's `test` job runs
scripts/test quality     # what CI's `check` job runs
scripts/test clients     # what CI's `clients` job runs
scripts/test coverage    # nightly coverage lane
scripts/test eval-fast
scripts/test live-eval
scripts/test smoke
scripts/test all
scripts/test path apps/lemon_core/test/lemon_core/quality --seed 1
```

## Lanes

| Lane | Runs |
| --- | --- |
| `fast` | `mix compile --warnings-as-errors`, then `mix test --exclude integration` (no coverage). |
| `quality` | `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, the skip-tag guard, `shellcheck` on `install.sh` / `scripts/verify_install_script` / `rel/overlays/bin/lemon` / `bin/lemonup`, `scripts/test_lemon_tui_auth.sh`, `scripts/test_lemon_launcher_reuse.sh`, `scripts/test_lemonup.sh`, `mix lemon.skill.lint`, `mix lemon.quality`, and the quality/eval-harness tests. |
| `clients` | `clients/tui`: `bun install --frozen-lockfile`, `bun run check`, `bun run lint`, `bun test`. `clients/lemon-browser-node`: `npm ci`, `typecheck`, `lint`, `build`, `npm test`. |
| `coverage` | `mix compile --warnings-as-errors`, then `mix test --exclude integration --cover` with each app's `test_coverage` threshold. |
| `eval-fast` | `mix lemon.eval --iterations ${LEMON_EVAL_ITERATIONS:-3}` (deterministic eval harness). |
| `live-eval` | `mix lemon.eval --live-model`; needs a live credential (see below). |
| `smoke` | Prints how to run `scripts/product_smoke_local` (`--release` for release-boot parity). |
| `all` | `fast`, `quality`, `eval-fast`, `smoke`. Run `clients` separately when client code changes. |
| `path` | Pass-through to `mix test`, e.g. `scripts/test path apps/coding_agent/test --only some_tag`. |

`mix lemon.quality` checks that local markdown links in tracked
`docs/**/*.md` files resolve, that the generated dependency table in
`docs/architecture_boundaries.md` is current, that every app's `deps/0` matches
`LemonCore.Quality.ArchitecturePolicy`, and that no two test modules share a
name. Add `--validate-config` to also validate the runtime config.

`quality` needs `shellcheck` and `python3` on `PATH`. Client lanes reinstall
dependencies; set `LEMON_TEST_REUSE_NODE_MODULES=1` to reuse existing
`node_modules` in local loops.

Product and packaged-boot smokes isolate their home/store directories and use
valid, test-only 32-byte secrets keys; no live provider credential is needed.
For packaged CLI coverage, run `scripts/verify_release_runtime_boot` in
`--single TARBALL --profile PROFILE` mode against both locally assembled
`lemon_runtime_min` and `lemon_runtime_full` tarballs.

## CI mapping

| Workflow | Trigger | What it runs |
| --- | --- | --- |
| `ci.yml` | every PR and push to `main` | `check` → `scripts/test quality` + `eval-fast`; `test (1..4)` → `scripts/test fast --partitions 4`; `dialyzer` (advisory full run plus the `scripts/dialyzer_gate.sh` allowlist gate); `sim-bench` (`scripts/ci_sim_bench.sh`); `install` → `scripts/verify_source_install` + `scripts/verify_install_script`; `clients` → `scripts/test clients`; `wasm-runtime`; `history` (PRs only); `CI result` (the one status to require) |
| `nightly.yml` | daily + dispatch | `scripts/test coverage`; the prompt/skill/overflow regression files with `--repeat-until-failure 5`; `scripts/test eval-fast` with 20 iterations |
| `product-smoke.yml` | PRs touching `apps/**`, weekly, dispatch | Boots a `lemon_runtime_full` release against a local deterministic provider |
| `release-smoke.yml` | release paths, weekly, dispatch | Release assembly and boot matrix |
| `osv-scanner.yml` | lockfile changes, weekly | The only dependency-vulnerability scan (Mix, npm, Bun lockfiles) |
| `docs-site.yml` | `docs/**` changes | VitePress build and link check |
| `release.yml` | tag / dispatch | Skips the BEAM and client gates when `scripts/ci_verified_commit` finds a green `ci.yml` push run on the release commit or on an ancestor it differs from only by version fields and changelogs; otherwise runs `fast`, `quality`, `eval-fast`, the install checks and `clients`. Then builds and publishes artifacts. |
| `live-eval.yml` | dispatch | `scripts/test live-eval` with repository secrets |
| `packaging.yml` | PRs touching the five Hex packages, `lemon_channels`, `installer/` or the packaging scripts; nightly; dispatch | `scripts/verify_packages` (consumer project and generated projects built from the unpacked Hex tarballs; advisory Elixir 1.15 leg) and `scripts/verify_generator` (both generator shapes against the checkout) |
| `publish.yml` | `<package>-v<version>` tag / dispatch | `scripts/release_package --verify`, then `--publish-tagged` when `HEX_API_KEY` is set |

In `ci.yml`, pull requests skip what their paths cannot affect: prose-only
changes (`docs/**`, `*.md`) run only `check`; `clients` runs for `clients/**`;
`wasm-runtime` runs for `native/**` and the WASM bridge. Pushes to `main` run
every job, which is what lets a release reuse a main commit's green run. One
`deps`/`_build` cache entry per `MIX_ENV` family (`test`, `dev`, `install`) is
saved per main commit by `.github/actions/beam-setup` callers; pull requests
restore main's newest entry and compile incrementally. To reproduce one test
shard locally: `MIX_TEST_PARTITION=2 scripts/test fast --partitions 4`.

## Hermetic test environment

BEAM lanes default to `MIX_ENV=test`, create a per-invocation
`LEMON_TEST_TMPDIR` and `LEMON_STORE_PATH` when unset, and unset ambient
provider, OAuth, cloud, and chat-platform credentials (the list is
`SCRUB_CREDENTIAL_ENV_VARS` in `scripts/test`). `config/test.exs` also points
the store at ETS, starts no channel adapters unless a test opts in, and
disables Honcho and background automation workers.

Every app's `test_helper.exs` starts ExUnit with `capture_log: true`: log
output is printed only for failing tests. Assert on logs with
`ExUnit.CaptureLog.capture_log/2`.

Shared Elixir helpers live in `LemonCore.Testing.HermeticEnv`:

- `credential_env_vars/0` returns the canonical scrub list.
- `scrub_unit_credentials!/1` deletes those variables unless live credentials
  are explicitly allowed.
- `with_restored_env/2` snapshots and restores env vars around synchronous
  tests that mutate process-wide env.

Tests that call `System.put_env/2` or `System.delete_env/1` should be
`async: false` and restore their changes.

Application environment is shared across umbrella app suites too. Tests that
replace a runtime executor or dispatcher must snapshot it with
`Application.fetch_env/2` and restore the exact value (or absence) on exit.
Cross-app wire tests should explicitly configure the real source-side runtime;
replace only the destination executor when probing remote execution.

Aggregation/property and per-delta cost tests should use the semantic dispatcher
seam rather than synchronously rendering every accumulated snapshot through an
adapter/outbox. Own their coalescers with the test supervisor so pending idle
flushes cannot outlive the test's dispatcher configuration. Keep adapter delivery
and live remote-stream assertions in their behavioral suites.

## Behavior-focused coverage

Keep one canonical test for each consumer-visible contract. Prefer observable
results, failure boundaries, precedence, state transitions, and concurrency
invariants over module-existence checks, source/documentation string matching,
copied defaults, or assertions that only repeat a mock's reply.

When consolidating overlapping test families, move unique scenarios into the
remaining suite before deleting a file. Provider request snapshots belong beside
their protocol tests; keep omission, authentication, streaming, and error cases
that exercise different branches. Stream and loop coverage must retain terminal
ordering, cancellation, monitoring, and tool-result accounting—not just a
successful return or a nonempty event list.

## Tags

- `:integration` is excluded by default. It is for tests that need a real
  network service, provider, or toolchain; do not use it to quarantine flaky
  tests.
- `:python3` (`coding_agent`) marks tests that need a `python3` interpreter.
  The app's `test_helper.exs` excludes the tag only when `python3` is missing.
- `:ast_grep` (`coding_agent`) marks tests that need the optional ast-grep CLI.
  The app excludes the tag only when backend discovery fails; set
  `LEMON_AST_GREP_EXECUTABLE` to select an installed release binary.
- Skip tags (`@tag :skip`, `@tag skip: ...`, `@moduletag :skip`,
  `@describetag :skip`) fail the `quality` lane. Fix the test or give it a
  named tag with a conditional exclude.

See [`testing/deterministic-test-patterns.md`](testing/deterministic-test-patterns.md)
for synchronization patterns that replace `Process.sleep/1`.

## Live and manual lanes

Live runs must opt in to real credentials explicitly:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 scripts/test path apps/some_app/test --include integration
scripts/test live-eval
```

`live-eval` fails before app startup unless one of `LEMON_EVAL_API_KEY`,
`LEMON_EVAL_API_KEY_SECRET`, `INTEGRATION_API_KEY`,
`INTEGRATION_API_KEY_SECRET`, or `ANTHROPIC_API_KEY` is set. The `*_SECRET`
variables name a Lemon secret, so local runs can use the encrypted store:

```bash
mix lemon.secrets.set release_eval_api_key <token>
LEMON_EVAL_API_KEY_SECRET=release_eval_api_key scripts/test live-eval
```

Choose the model with `LEMON_EVAL_PROVIDER`, `LEMON_EVAL_MODEL`,
`LEMON_EVAL_BASE_URL`, and `LEMON_EVAL_API_TYPE`. In CI, dispatch
`live-eval.yml` (`gh workflow run live-eval.yml -f iterations=3`) with the
`LEMON_EVAL_API_KEY` repository secret configured.

`scripts/test path` isolates `LEMON_STORE_PATH`, so resolve secret-store-backed
provider keys into their env var before running live integration tests.

The omp real-binary lifecycle smoke is opt-in:
`LEMON_OMP_LIVE=1 scripts/test path apps/lemon_omp/test/lemon_omp/live_smoke_test.exs`.
It uses omp's own credentials and a zero-cost model, not Lemon provider keys.
See [omp verification](../apps/lemon_omp/AGENTS.md#verification) for overrides.

The remaining manual smoke scripts are not run by CI:
`scripts/live_telegram_matrix.py` (with `scripts/telegram_driver.py`),
`scripts/live_discord_matrix.py`, `scripts/live_provider_fallback_smoke.exs`,
`scripts/live_mcp_stdio_smoke.exs`, and
`scripts/live_cron_runtime_restart_smoke.exs`.

## Umbrella gotchas

- `mix test apps/<app>` from the umbrella root runs zero tests and reports
  success. Pass test paths (`mix test apps/<app>/test/...`) or run from inside
  the app directory.
- `lemon_channels`, `lemon_gateway`, `lemon_router`, and `lemon_automation`
  suites only run from the umbrella root: their `test_helper.exs` starts apps
  that are not in their own `deps`.
- `lemon_ai` `Auth.*OAuth` tests need `lemon_core` services and fail when run
  from `apps/lemon_ai`; run them from the umbrella root.
