# Lemon testing lanes

`scripts/test` is the repo-level test runner. CI calls the same lanes, so a
lane that passes locally runs the same commands in CI.

## Quick usage

```bash
scripts/test help
scripts/test premerge    # diff format/credo/guards, then affected app tests
scripts/test changed     # affected app tests plus relevant clients/docs checks
scripts/test changed --focused  # quick matching-file pre-check only
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
| `changed` | Selects the merge-base-to-working-tree diff (including untracked non-ignored files), compiles with warnings as errors, then runs affected apps and reverse dependencies excluding integration; full scope falls back to `fast`. Runs client checks and docs verification when selected. |
| `premerge` | Changed-file format check, changed-file `mix credo` with quality's default configuration, skip-tag guard, changed changelog validation, then `changed --narrow`; stops at the first failure and prints step timings. |
| `quality` | `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, the skip-tag guard, `scripts/check_changelog`, `python3 scripts/test_changed_tests.py`, `shellcheck` on the test/install/update/launcher scripts, `scripts/test_lemon_tui_auth.sh`, `scripts/test_lemon_launcher_reuse.sh`, `scripts/test_lemonup.sh`, `mix lemon.skill.lint`, `mix lemon.quality`, and the quality/eval-harness tests. |
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

When Bun is installed, `fast` also exercises the production TUI through the
control plane. Install its locked dependencies in a fresh worktree first:
`(cd clients/tui && bun install --frozen-lockfile)`. Release BEAM setup performs
the same install before its deterministic gates.

SVG tests use injected rasterizers by default. The real `rsvg-convert` case carries
the `:rsvg_convert` tag, which the coding-agent helper explicitly excludes when
librsvg is not installed. Install librsvg to include that host-backed coverage.

The real LLDB/DAP integration carries `:lldb_dap`. The coding-agent helper
compiles a trivial program and launches it with batch LLDB once per suite, with
bounded subprocess probes. It excludes the tag if the adapter/compiler is
missing or the host cannot launch the debuggee (including macOS debug permission
denied in a non-interactive session); finding `lldb-dap` alone is not sufficient.

Product and packaged-boot smokes isolate their home/store directories and use
valid, test-only 32-byte secrets keys; no live provider credential is needed.
For packaged CLI coverage, run `scripts/verify_release_runtime_boot` in
`--single TARBALL --profile PROFILE` mode against both locally assembled
`lemon_runtime_min` and `lemon_runtime_full` tarballs.

## Which checks for my diff

Run `scripts/test premerge` before merging a small change. It checks changed
Elixir/HEEx formatting, changed Elixir files with the same Credo settings as
`quality`, skip tags, changed changelogs, and then runs `changed --narrow`, in
that order. Each step reports elapsed time and stops on failure. Both `premerge` and
`changed` accept `--base REF` (default `origin/main`); selection compares the
merge base with the working tree, including untracked non-ignored files.

`--narrow` keeps the changed apps (and data readers) whole but limits every other
affected downstream app to the test files that name a module defined in a
changed lib file (its current or merge-base version). It falls back to whole
apps when shared test support names such a module or a changed lib file defines
no module. A behaviour change that reaches a downstream app only through an
intermediate module is left to PR CI, which still runs affected apps whole.
BEAM lanes install `clients/tui` (`bun install --frozen-lockfile`) when it has no
`node_modules` and lemon_control_plane's TUI wire tests are selected.

Use `scripts/test changed [--base REF] [mix test args...]` to repeat just the
affected work. App changes include transitive reverse dependencies, including
test-only/conditional umbrella dependencies. Shared build/config/tooling inputs
and unknown paths conservatively select the full fast suite and clients.
Documentation/client/product/showcase data changes select apps whose lib, test
or priv files reference the exact path or an ancestor of at least two segments;
these data readers do not pull in reverse dependencies. Client changes also run
`clients`; docs changes run `scripts/verify_docs_site` (Node and Python required).

For an inner loop, `scripts/test changed --focused` runs only existing changed
`*_test.exs` files and conventional `lib/a/b.ex` → `test/a/b_test.exs` matches.
This is a **quick pre-check, not a substitute for the affected-app run**; it can
find no matching tests. Selected client/docs checks still run.
Preview the selection with `scripts/changed_tests --focused`; `--format json`
is machine-readable. `--format github` appends `scope`, `apps`, `test_paths`,
`clients`, `wasm`, and `docs` to `$GITHUB_OUTPUT`, and a selection summary to
`$GITHUB_STEP_SUMMARY` when set. The WASM flag is for CI's dedicated runtime
lane; `changed` itself does not invoke that toolchain.

Keep `quality` for repository-wide checks. `scripts/check_changelog` checks
root/app/installer changelogs by default, or named files; Unreleased must be the
first version section, and its bullets must sit under unique Keep a Changelog
subsections. Published release bodies are frozen and retain historical headings.
Version headings must consistently include or omit dates within each file.

Diff checks do not replace the full suite on main after merge, nightly coverage
and repeated regression/eval runs, or release assembly/boot/package checks.
Dialyzer, install verification, sim-bench, and the dedicated WASM lane remain CI
responsibilities. No live provider calls are needed for `premerge` or `changed`.


## CI mapping

| Workflow | Trigger | What it runs |
| --- | --- | --- |
| `ci.yml` | every PR and push to `main`; called by `release.yml` and `nightly.yml`; dispatch | `changes` → `scripts/changed_tests` (PRs only); `check` → `scripts/test quality` + `eval-fast` (PRs: `quality --base origin/<base>`, which formats and credo-checks only changed files unless the diff is full scope; Credo's cross-file checks are authoritative on `main`'s full run); `test (n/N)` → `scripts/test fast --partitions N [selected app test dirs]`; `dialyzer` (advisory full run plus the `scripts/dialyzer_gate.sh` allowlist gate); `sim-bench` (`scripts/ci_sim_bench.sh`); `install` → `scripts/verify_source_install` + `scripts/verify_install_script`; `clients` → `scripts/test clients`; `wasm-runtime`; `history` (PRs only); `CI result` (the one status to require; summarizes failures) |
| `nightly.yml` | daily + dispatch | the full `ci.yml`; `scripts/test coverage`; the prompt/skill/overflow regression files with `--repeat-until-failure 5`; `scripts/test eval-fast` with 20 iterations; the `nightly-red` issue |
| `product-smoke.yml` | PRs touching `apps/**`, weekly, dispatch | Boots a `lemon_runtime_full` release against a local deterministic provider |
| `release-smoke.yml` | release paths, weekly, dispatch | Release assembly and boot matrix |
| `osv-scanner.yml` | lockfile changes, weekly | The only dependency-vulnerability scan (Mix, npm, Bun lockfiles) |
| `docs-site.yml` | `docs/**` changes | VitePress build and link check |
| `release.yml` | tag / dispatch | Skips the gates when `scripts/ci_verified_commit` finds (or waits up to 30 minutes for) a green `ci.yml` push run on the release commit or on an ancestor it differs from only by version fields and changelogs; otherwise calls `ci.yml` itself, so the release runs the same sharded jobs. Then builds and publishes artifacts. |
| `live-eval.yml` | dispatch | `scripts/test live-eval` with repository secrets |
| `packaging.yml` | PRs touching the five Hex packages, `lemon_channels`, `installer/` or the packaging scripts; nightly; dispatch | `scripts/verify_packages` (consumer project and generated projects built from the unpacked Hex tarballs; advisory Elixir 1.15 leg) and `scripts/verify_generator` (both generator shapes against the checkout) |
| `publish.yml` | `<package>-v<version>` tag / dispatch | `scripts/release_package --verify`, then `--publish-tagged` when `HEX_API_KEY` is set |

In `ci.yml`, pull requests run only what their diff can affect, chosen by
`scripts/changed_tests --base origin/<base>` (see above): the `test` job runs the
selected apps' test directories (one shard for small selections, four when
`coding_agent` or more than six apps are selected, or for full scope); no
selected app skips `test`, `dialyzer` and `install`; `sim-bench` runs when
`lemon_sim` is selected; `clients` and `wasm-runtime` follow their lanes. `check`
always runs. Every other event (pushes to `main`, release preflight, nightly,
dispatch) runs every job, which is what lets a release reuse a main commit's
green run. Cross-app effects that only appear in the shared umbrella BEAM (an app
registering into another's runtime registry) are therefore caught by `main`'s
full run, not by the pull request.

Every executing CI job records its actual Git HEAD, PR head/base (or pushed
checkout), run ID and attempt immediately after the canonical unnamed checkout,
before repository-controlled code. `Record tested checkout identity` uses
isolated Python; keep its name, command and position compatible with the factory
verifier. The always-running `CI result` also checks out and attests, even when
optional lanes skip. Skipped jobs have no log identity and must not be configured
as individually required factory lanes. The history gate deliberately checks out
the PR head rather than the test merge, so it must not be required alongside
merge-checkout lanes by a verifier that requires identical tested SHAs.

Run `python3 scripts/test_ci_checkout_identity.py` for the hermetic producer/
consumer contract test (also run by `check`). It uses fake GitHub metadata and
a labelled snapshot of the factory consumer, not a local factory installation.
Failed-job reruns bind each lane to its own attempt; omitted successful lanes
are resolved from earlier attempts of the same run by the consumer.

Pushes to `main` are serialized: one run plus the newest pending one, so a
burst of merges coalesces into a run of the latest commit. When a `main` run
fails, `CI result` opens (or comments on) the `main-red` issue with the failing
jobs and ExUnit tests (`scripts/ci_failure_report`); the next green run closes
it. Check `gh issue list --label main-red` before merging and fix forward first.
Nightly failures do the same with `nightly-red`.

One `deps`/`_build` cache entry per `MIX_ENV` family (`test`, `dev`, `install`) is
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

The `coding_agent` helper disables `[features] session_search` in its isolated
home: mocking a session's stream does not mock background project-fact extraction.
Memory fixtures opt in with project config and control extraction explicitly.
Recall-only fixtures omit the capture session key; capacity fixtures monitor their
admitted workers through exit before asserting reuse of stale registry entries.
Recall ingest fixtures also give their supervised ingest worker an explicit
project-config loader and use a server barrier before querying persisted facts,
rather than polling for global ingest to pick up changed feature flags.

Session fixtures pass a per-test `workspace_dir` as well as a temporary working
directory: the isolated test HOME is still shared by concurrent modules.
`CodingAgent.SessionSupervisor` accepts a second scope-options argument with
`:supervisor` and `:registry` targets for isolated session trees. Start those
targets under the test supervisor, and query/stop only that tree rather than
enumerating or clearing the application's global sessions.

Session/branch/lifecycle fixtures inject `extension_inventory: {[], []}` and
`mcp_tools: []` when discovery is not under test, avoiding shared extension
loader/cache state and configured MCP services. Their ordinary sessions use
explicit tools; the default-tool assertions still request the real built-in
toolset. Temporary working roots live outside the checkout so session discovery
does not inherit repository-local resources.
The two approval-event broadcast cases remain in the small synchronous
`SessionApprovalEventsTest` module because they publish to a shared Bus topic.

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

Register restoration callbacks before the first mutation or fallible setup
assertion, not at the end of setup: ExUnit cannot run a callback that a failed
setup never registered. Keep restoration separate from fallible resource cleanup.
The synchronous native-followup fixture also scopes its recorder to its own
profile because background tasks can outlive another test. Its setup-failure
regression lets ExUnit restore the override before exercising an unrelated
`cron.abort`, so restoration is checked at the same boundary as the next suite.

Provider-registry fixtures must restore the exact API-to-module mappings they
found, rather than leave the registry empty after extension tests. Provider
stream fixtures use `LemonAi.Types.AssistantMessage` terminal payloads and call
`EventStream.error/2` for errors, not a raw error followed by successful completion.

Controlled provider-outage fixtures own their circuit-breaker and rate-limiter
processes and await terminal health accounting before teardown; injected failures
must not poison another case or a repeated run.

Approval fixtures read pending requests through `LemonCore.ExecApprovalStore`;
the underlying table also retains terminal resolution receipts.

Coordinator cancellation fixtures wait for tracked admission guardians and sessions
to exit before asserting an empty active set: a bounded batch result is not a
synchronous shutdown receipt.

Coordinator timeout/abort protocol fixtures use controlled sessions, wait for
prompt acknowledgements, deliver timeout messages explicitly and monitor cleanup.
Terminal-event fixtures supply empty tools, extension inventory and MCP tools;
they exercise event handling rather than unrelated resource discovery.
Delegated completion fixtures finalize the durable run summary before publishing
the Bus event, including late reconciliation and store-only poll recovery.
Environment cap/ordering fixtures keep the full filesystem traversal but inject
its probe execution; they must not mistake the valid production deadline result
for deterministic rendering. Large file fixtures run synchronously and use raw
writes to avoid contending with async tests through the shared file server.

LSP owner-lifecycle fixtures monitor the scoped client through exit, then assert
that its exact managed server ID is gone. Unrelated idle-server cleanup can change
the shared manager's active count concurrently; global count deltas are not an
ownership assertion.

Recency/deduplication fixtures use explicit ingestion timestamps, not consecutive
wall-clock reads. Exercise reversed input and equal-timestamp ID tie-breaking
separately so crossing a millisecond cannot change the expected winner.

Submission-shape fixtures use per-test run supervisors and capturing run processes,
not real gateway work that can finish during another test's global count assertions.
Fixtures that deliberately submit real router work run synchronously, abort their
exact run IDs on exit, and await `RunRegistry` removal before teardown completes.
Own database fixtures with `start_supervised!` so shutdown finishes before directory
cleanup; checking `Process.alive?` before stopping a test-linked process is a race.
Atom-safety tests check that each generated untrusted token still fails
`String.to_existing_atom/1`, rather than attributing VM-wide atom growth to one call.

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

For pruning measurements, distinguish literal source test definitions from
executed tests: parameterized cases, properties, doctests, tags, and moved cases
make those counts differ. Record the baseline revision, exact lane command,
failures, and whether slowest-test reporting serialized the run. Compare timings
only under the same options; a smaller source diff alone does not establish
faster or green CI.

Do not replace an elapsed-time regression with an assertion on its configured
timeout: that no longer exercises waiting past the failure boundary. Likewise,
an immediate mailbox check is not a barrier for work sent by another process.
Keep unique stress, restart, queue-race, and UTF-8 boundary scenarios even when
they are slow; shorten them only when the same observable invariant is retained.

Channel chunking tests assert the payloads delivered to the adapter: content and
ordering, continuation metadata, and first-chunk-only reply, idempotency and
notification identity. A successful enqueue or a live outbox process alone does
not prove these contracts. Keep formatting boundary coverage (UTF-16 entities,
table cells, Unicode splits and resume lines) and cold-start/restart regressions
when trimming slower channel suites.

## Tags

- `:integration` is excluded by default. It is for tests that need a real
  network service, provider, or toolchain; do not use it to quarantine flaky
  tests.
- `:python3` (`coding_agent`) marks tests that need a `python3` interpreter.
  The app's `test_helper.exs` excludes the tag only when `python3` is missing.
- `:lldb_dap` (`coding_agent`) marks the real debugger smoke. The app excludes
  it when `lldb-dap`, a C compiler, or host debuggee launch is unavailable (see above).
- `:rsvg_convert` (`coding_agent`) marks the real `rsvg-convert` SVG case; excluded
  when librsvg is not installed.
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

The omp real-binary smoke (lifecycle, approvals bridge, parallel workers) is opt-in:
`LEMON_OMP_LIVE=1 scripts/test path apps/lemon_omp/test/lemon_omp/live_smoke_test.exs`.
It uses omp's own credentials and a zero-cost model, not Lemon provider keys.
Every throwaway workspace pins auxiliary model roles to that same `:free` model
and disables model fallback. Required-tool steps allow at most two attempts,
re-prompting only after a completed text-only/nonmatching-tool response, never
after a tool error or an uncertain command acknowledgement. Cancellation,
redirect and SIGKILL wait for a bash-created marker **and** an active bash call;
approval denial must observe a real shared approval request. Required-action
failures include attempt snapshots and an 8 KiB read-only tail of that smoke
session's transcript. Treat these diagnostics as local test output, not an
artifact to commit. Run the complete live file twice consecutively when changing
this smoke, followed by `scripts/test path apps/lemon_omp/test`.
See [omp verification](../apps/lemon_omp/AGENTS.md#verification) for overrides.

The remaining manual smoke scripts are not run by CI:
`scripts/live_telegram_matrix.py` (with `scripts/telegram_driver.py`),
`scripts/live_discord_matrix.py`, `scripts/live_provider_fallback_smoke.exs`,
`scripts/live_provider_ownership_smoke.exs`, and
`scripts/live_cron_runtime_restart_smoke.exs`. MCP has no live smoke script: its
client, transports and fixture server are covered by the deterministic
`apps/lemon_mcp/test` suite (`scripts/test path apps/lemon_mcp/test`).

## Umbrella gotchas

- `mix test apps/<app>` from the umbrella root runs zero tests and reports
  success. Pass test paths (`mix test apps/<app>/test/...`) or run from inside
  the app directory.
- `lemon_channels`, `lemon_gateway`, `lemon_router`, and `lemon_automation`
  suites only run from the umbrella root: their `test_helper.exs` starts apps
  that are not in their own `deps`.
- `lemon_ai` `Auth.*OAuth` tests need `lemon_core` services and fail when run
  from `apps/lemon_ai`; run them from the umbrella root.
