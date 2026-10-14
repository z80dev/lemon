# Repeated paired disclosure trials

This workflow extends Lemon's existing twelve-task production coding benchmark;
it is not a second benchmark or a model-ranking campaign. See the
[evaluation app guide](https://github.com/z80dev/lemon/blob/main/apps/lemon_evals/README.md) for the nonpaired
single-trial lane, separate omp comparison, and payload profiling.

## Decision and evidence status

**Keep current defaults; keep the coding disclosure profile opt-in.** No
operator-authorized live paired run or sanitized outcome report is recorded by
this change. The runner can be delivered without paid evidence, but the rollout
decision remains **pending** an explicitly approved, bounded live experiment and
review of its sanitized report. There is no performance claim here.

A negative or inconclusive experiment is a valid outcome. Smaller tool schemas
alone are not evidence of improved coding outcomes and cannot justify promotion.
Promotion requires useful measured task-level benefit without unacceptable
verified-success or security regression. Do not block unrelated correctness
fixes on this experiment.

## CLI contract

Run from the umbrella source checkout. Paired runs require that checkout's
source launcher, not an installed launcher from another revision.

| Option | Paired behavior |
| --- | --- |
| `--paired` | Select repeated disclosure trials through the existing production client and verifiers. |
| `--lemon PATH` | Source launcher from this checkout; Mix defaults to `bin/lemon`. An installed launcher from another revision is rejected. |
| `--model PROVIDER:MODEL` | Use one identical Lemon model/provider route for every variant; default `openai-codex:gpt-6.1-sol`. |
| `--tasks NAME,NAME` | Select existing benchmark tasks; omitted means all twelve. |
| `--repetitions N` | Positive repetitions per task and variant; default `4`. |
| `--seed N` | Deterministic scheduling and uncertainty seed; default `107`. |
| `--config FILE.toml` | Required explicit base configuration; must omit `runtime.tools.disclosure`, including inline/quoted forms. |
| `--timeout S` | Positive per-attempt deadline; default `660` seconds. Includes fresh runtime boot, fixture work, production client, and external verification. |
| `--run-timeout S` | Positive whole-experiment deadline; default `7200` seconds. |
| `--profile-python PATH` | Python 3.11+ interpreter for the opt-in profiler; default is the runner's interpreter. Live use requires `tiktoken` installed in that environment. |
| `--output FILE.json` | Output destination; set explicitly as below. Mix defaults to `/tmp/lemon-coding-benchmark.json`; the direct Python runner requires this option. Without `--live`, this is an unsigned plan template, not an outcome report. |
| `--plan FILE.json` | In live mode, the approved plan object, not the plan-template wrapper. |
| `--approve-plan-digest SHA256` | Explicit lowercase SHA-256 of the canonical final approved plan. Required for live authorization. |
| `--live` | Enable paid calls only after all approval checks pass. Never implied by `--paired`. |
| `--schema-budgets N,N` | Add at most three distinct positive integer schema-budget variants, named `coding_budget_N`. Explicit diagnostic experiment selection, not an automatic sweep. |
| `--failure-dir DIR` | Optional private failure bundles; never upload or commit them. |

`--paired` and `--compare-omp` cannot be combined. The nonpaired coding command
and omp comparison keep their existing behavior, including live calls without
the paired plan gate. The contract harness's `mix lemon.eval --iterations N`
still does not repeat live coding tasks.

Paired-only options (`--config`, `--repetitions`, `--seed`, `--run-timeout`,
`--profile-python`, `--live`, `--plan`, `--approve-plan-digest`, and
`--schema-budgets`) are rejected without `--paired`, rather than ignored and
allowed to fall through to the nonpaired paid lane. This includes explicitly
negated authorization (`--no-live`) in the Mix entrypoint. Use exact full option
names; abbreviated options are not accepted. A nonpaired invocation without
paired-only options remains unchanged.

Start with `baseline` versus `coding`. Select additional schema-budget thresholds
only if useful after that comparison; they require their own exact approved
experiment. There is no automatic threshold selection or default change.

## Plan-only preparation: no paid calls

All paths and model/settings below are **operator-edited placeholders**, not
recorded commands or evidence. Example repetition/deadline values are illustrative,
not approval. Store the configuration, profiling environment, plans, and reports
outside the source checkout: adding or changing nonignored source files changes
the source digest and invalidates an earlier plan.

A live experiment requires a nonempty precompiled development build containing
the integrated #106/#107 source. Compile that source **before generating the
plan you intend to approve**; live attempts do not compile it. Plan-only mode
also works without compiled artifacts, but compiling afterward changes the
experiment identity and requires a newly generated plan and renewed approval.
No compilation or live experiment is claimed by this documentation.

```bash
# Replace /OPERATOR/PATH and PROVIDER:MODEL before use.
# The base TOML has no [runtime.tools.disclosure] table and no secrets.
mix lemon.eval.coding --paired \
  --model PROVIDER:MODEL \
  --repetitions 3 --seed 107 \
  --config /OPERATOR/PATH/benchmark-base.toml \
  --profile-python /OPERATOR/PATH/profile-venv/bin/python \
  --timeout 660 --run-timeout 3600 \
  --output /OPERATOR/PATH/paired-plan-template.json
```

Without `--live`, the runner writes a schema-version-3
`paired_disclosure_plan` artifact containing `plan`, `plan_digest`,
`scheduled_trials`, `live_calls: 0`, and the pending decision. It schedules trials
and hashes local source/configuration/fixtures/interpreter, but does not start
trial runtimes, run benchmark fixtures, or call a model. The template digest is
**not** authorization for a live run.

Offline regression fixtures exercise scheduling, configuration/environment
isolation, exact approval binding, aggregation, failures/timeouts, missing
counters/spend, and zero-success behavior without paid API calls. They check
runner mechanics, not model performance. For an operator's offline-only check,
from the umbrella root:

```bash
python3 -m unittest discover -s apps/lemon_evals/priv \
  -p test_coding_benchmark_paired.py -v
```

The generated `plan` object has this shape; the omitted experiment content is
supplied by the runner and must be retained exactly:

```json
{
  "approved": false,
  "experiment": {},
  "max_attempts": 0,
  "max_spend_usd": null,
  "per_attempt_spend_ceiling_usd": null,
  "provider_budget_enforced": false,
  "credential_env": []
}
```

This illustrative object is intentionally unusable for live calls: the actual
runner fills `experiment` and the scheduled `max_attempts`; this page grants no
real spend approval. Extract the generated `plan`, not this illustration:

```bash
python3 - /OPERATOR/PATH/paired-plan-template.json /OPERATOR/PATH/operator-plan.json <<'PY'
import json
import sys
from pathlib import Path
wrapper = json.loads(Path(sys.argv[1]).read_text())
Path(sys.argv[2]).write_text(json.dumps(wrapper['plan'], indent=2) + '\n')
PY
```

## Explicit bounded live authorization

Before approving the extracted plan, the operator must:

1. Inspect the selected tasks, variants, model, exact revision/source and compiled
   build digests, fixtures, configuration, interpreter, repetitions, seed, and
   both deadlines. Preserve the generated `experiment` unchanged.
2. Provision isolated provider credentials with an **externally enforced hard
   account/provider spend cap**. A warning threshold, local cost estimate, client
   timeout, or claim of unlimited/subscription access is not a hard cap. If the
   provider cannot enforce a hard cap, do not authorize this workflow.
3. Set positive finite `max_spend_usd` and
   `per_attempt_spend_ceiling_usd`, with the ceiling no greater than the maximum.
   Keep `max_attempts` at least the actual scheduled count
   (`tasks × variants × repetitions`). Confirm `provider_budget_enforced: true`
   only after external enforcement exists; the boolean does not create or verify
   that provider cap.
4. List only explicitly required credential environment-variable **names** in
   `credential_env`, never credential values. Names must be uppercase provider
   credential names ending in `API_KEY`, `ACCESS_TOKEN`, or `AUTH_TOKEN`; the list
   must be nonempty and distinct, and every named value must be present at launch.
5. Only after review, set `approved: true` and compute the digest of that exact
   final object. Any edit requires renewed review and a new digest.

Canonicalization is Python `json.dumps(plan, sort_keys=True,
separators=(',', ':'), allow_nan=False)` with its default ASCII escaping, encoded
as UTF-8, then SHA-256. Hash the JSON **object**, not the file's whitespace or the
outer template wrapper. This command computes the digest without changing the
plan or making paid calls:

```bash
python3 - /OPERATOR/PATH/operator-plan.json <<'PY'
import hashlib
import json
import sys
from pathlib import Path
plan = json.loads(Path(sys.argv[1]).read_text())
canonical = json.dumps(plan, sort_keys=True, separators=(',', ':'), allow_nan=False)
print(hashlib.sha256(canonical.encode('utf-8')).hexdigest())
PY
```

Only an operator who has completed those steps may run:

```bash
# NOT authorized by this documentation. Substitute reviewed operator values.
# Export only the credentials named by the approved plan, outside shell history.
mix lemon.eval.coding --paired --live \
  --model PROVIDER:MODEL \
  --repetitions 3 --seed 107 \
  --config /OPERATOR/PATH/benchmark-base.toml \
  --profile-python /OPERATOR/PATH/profile-venv/bin/python \
  --timeout 660 --run-timeout 3600 \
  --plan /OPERATOR/PATH/operator-plan.json \
  --approve-plan-digest OPERATOR_COMPUTED_FINAL_PLAN_SHA256 \
  --output /OPERATOR/PATH/paired-report.json
```

The live invocation must reproduce the exact generated experiment. That binding
includes `tasks`, `model`, `revision`, `source_digest`, `compiled_build_digest`,
`repetitions`, `seed`, `timeout`, `run_timeout`, `variants`, `config_digest`,
`fixture_digests`, and `profile_python_digest`. The source digest covers tracked
and nonignored untracked file contents, so a dirty checkout is not represented
as just its HEAD revision. `compiled_build_digest` SHA-256 binds all development
`ebin/*.beam` artifacts actually available to the runtime. Changed settings,
source, or compiled artifacts require a new plan, not a bypass.

The runner stops subsequent live calls when measured spend plus the next
per-attempt ceiling would exceed the total, an attempt exceeds its ceiling,
required spend is missing or incomplete, or the whole-run deadline is reached. Local
accounting cannot prevent an in-flight request exceeding an estimate; the hard
external cap remains mandatory. Paid experiments stay outside ordinary CI and
must never be automatically triggered by a code change.

## Pairing and isolation

Each task/repetition has a stable `pair_id`; each variant has a stable `trial_id`
and records `task`, `variant`, `repetition`, and within-pair `order`. A seeded
initial variant shuffle followed by rotation counterbalances position (AB/BA for
two variants). Attempts are interleaved by pair and run sequentially, not all
baseline trials followed by all coding trials.

Every attempted trial uses fresh identical fixture content, prompt, and external
behavioral verifier, including the applicable fixture unittest suite and the
existing required failed-tool observation for the recovery task. It runs through
`LemonCore.Runtime.Boot.start!(:runtime_full)` and the production
`lemon -p --output json` client, not a mocked session. It does not reuse the user's
daemon. Runtime teardown occurs after each attempt.
Shutdown permits up to five seconds of runtime/process-group termination grace
after a deadline; that cleanup is not permission for additional paid calls.
Teardown force-kills remaining attempt process-group children even when the
runtime leader has already exited. Deadline-owned client/fixture/verifier
commands likewise cannot leave same-group background children after completion.
Before any paid production-client invocation, the fresh runtime must resolve
the expected disclosure profile from configuration. If the opt-in profile
support from #106 is unavailable, this gate fails rather than silently running
the legacy catalog under a coding label. Observed `applied_profiles` must also
confirm the selected variant before a trial can receive a passing outcome.

A fresh private HOME, configuration cwd, store, operator token, secret master key,
and runtime ports isolate every attempt. The subprocess environment forwards
only minimal tool variables (`PATH`, `LANG`, `LC_ALL`, `TMPDIR`) and approved
credential variables; ambient Lemon settings, provider state, proxy settings,
and dotenv contents are not inherited. `LEMON_AGENT_PROFILES_CWD`,
`LEMON_DOTENV_DIR`, `LEMON_STORE_PATH`, and the disclosure-profile environment
variable point to the isolated trial state/settings. Keep secrets out of base
TOML and do not configure external sensitive workspaces or stateful services.

The same explicit base TOML is used for every variant. The runner appends
`[runtime.tools.disclosure]` with `enabled = true`, `catalog_tokens = 2000`,
`max_results = 5`, and:

- `baseline`: `profile = "legacy"`, `budget_tokens = 40000`.
- `coding`: `profile = "coding"`, `budget_tokens = 40000`.
- `coding_budget_N`: `profile = "coding"`, `budget_tokens = N`.

Model/provider route, reasoning settings, requested approvals, permissions,
fixture and deadlines are otherwise identical. Reasoning is the provider default
if absent from the base config; record that rather than claiming it was fixed.
Fresh local state is not a provider-cache flush. Provider cache/queue/load,
pricing/route drift, and OS scheduling remain uncontrolled; distinguish observed
cache usage from unknown cold/warm provider regimes.

## Report interpretation

Live schema-version-3 `live_agentic_coding_paired` JSON records the exact
experiment and approval digest, production boot/client metadata, runtime versions
where available, per-trial configuration/fixture digests, stable schedule IDs,
`runtime_versions.pricing_catalog_digest` (the SHA-256 identity of the runtime
model catalog used as the pricing basis),
and independent verifier/test outcomes. Failed and timed-out attempts remain in
the report. Trials prevented by a stop condition are recorded separately as
not attempted; do not count them as observed paid attempts or successes. Read
completion and stop metadata as well as the outcome summary: an artifact is not
proof that every scheduled live trial ran.

Outcome/usage fields include verified pass/fail, wall seconds, completed parent
turns, uncached input, cached input, cache-write and output tokens, and tool errors.
Versioned disclosure-bridge diagnostics provide `discovery_failures` and
`incorrect_tool_calls` as defined below; they do not count arbitrary invalid
nonbridge tool calls. `tool_error_recoveries` is a binary per-attempt indicator
of observed failed-tool calls **and** verified success, not an inferred number of
retries or per-call recoveries; missing tool-error counters keep it `null`.
Other unavailable counters likewise remain `null`,
never zero or estimates inferred from tool counts. Cached input is not newly
billed input; raw total tokens are not a spend comparison.

For each variant:

- `attempts`, `successes`, and `success_rate` describe attempted trials and
  independently verified outcomes, including failures/timeouts.
- `measured_spend_usd` sums available `cost_usd` across **all attempts**, including
  failures, not only successes. With missing or incomplete measurements it is a
  partial measured sum, not proof of zero spend or a complete budget total.
- Per-trial `spend_complete` requires cost, a completed profiler flush, and
  one-to-one matched request/terminal-usage identities for every completed parent
  turn, including numeric provider input/output/cache-read counters. Empty or
  unsupported observations, unmatched retries, and observed nested sessions do
  not prove the parent CLI cost covers all spend. Those trials remain incomplete,
  retain any numeric partial parent cost, and stop subsequent live calls rather
  than manufacturing full nested or missing spend. Variant `spend_complete`
  requires complete spend for every attempt; incomplete spend cannot produce a
  complete cost-per-success estimate.
- `cost_per_verified_success_usd` is total all-attempt measured spend divided by
  verified successes **only when spend is complete and successes are nonzero**.
  With positive successes, missing or incomplete spend produces `null` with
  `incomplete_missing_spend`. Zero successes produce `null` with
  `undefined_zero_successes` even if spend is also incomplete, never zero cost per
  success; `spend_complete` independently records that missingness.

Cost basis is runtime-reported `costUsd` using model-catalog pricing estimates,
**not a provider invoice**. Preserve the report's cost/pricing basis when sharing;
do not relabel estimates as billed dollars. No cost is manufactured from tool
counts or missing usage.

Candidate-minus-baseline paired verified-success and wall-time differences first
average within each task and then weight task clusters equally. The seeded
percentile bootstrap resamples whole task clusters 2,000 times; its 95% intervals
preserve task structure rather than treating repeated attempts as independent
tasks. A single task cluster has no uncertainty interval. Small selected task
samples are explicitly **exploratory**, not statistically significant global
model rankings. Missing wall measurements exclude only that pair's wall
comparison, not its observed success/failure outcome.

### Schema diagnostics are not outcome evidence

The opt-in per-attempt payload profiler records observed wire catalog digests,
request counts, terminal usage observations, cache observability, and
`o200k_base` visible schema-token estimates under `schema_diagnostics`.
Unobserved catalog/schema measurements remain unavailable, not fabricated.
Schema estimates are not billed input and do not establish verified success,
safety, or cost benefit. Encrypted replay is not treated as visible text tokens.

`schema_diagnostics.full_catalog_digests` identifies the full resolved catalog
from runtime disclosure-application telemetry; `catalog_digests` identifies the
actual observed wire catalog. `disclosure_measurements` retains the observed
profile/active state and heuristic before/after schema estimates and
hidden/disclosed counts (`estimated_tokens`, `disclosed_tokens`, `hidden_count`,
`disclosed_count`). The adapter collects those runtime measurements without
recomputing them; they are distinct from the profiler's visible-wire tokenizer
estimates and are not provider billing totals.

The disclosure `:applied` event advertises `diagnostic_events_version = 1`.
With that marker, `discovery_failures` counts empty or errored bridge searches
from `:search` status/matched-count events. `incorrect_tool_calls` counts valid
`:invoke_rejected` events classified as `unknown_tool`, `invalid_arguments`, or
`invalid_request`, plus malformed search requests. Pre-aborted cancelled calls
emit neither diagnostic and are not classified as discovery failures or
incorrect calls. Without the version marker these metrics remain `null`; with
the marker and no relevant calls, zero is an observed value. These bridge-only
counters are not a general measure of every invalid tool call in the runtime.

Safely resolved bridge invocations are attributed from
`[:coding_agent, :tool_disclosure, :invoke]` runtime telemetry under
`schema_diagnostics.resolved_bridge_invocations`, shaped as
`{SHA256_TOOL_IDENTITY: {calls, errors}}`. Only validated resolved catalog targets
are included; unknown targets and schema-invalid calls are excluded. This does
not retain raw requested arguments or tool identities. The `applied_profiles`
diagnostic records observed `legacy`/`coding` application. `flush_complete`
records whether queued profiler records reached the private output file before
collection; an incomplete flush is not evidence of zero activity.

Keep these diagnostics separate from external verifier outcomes and measured
all-attempt costs. The existing nonpaired `profile_report.py` workflow remains a
separate diagnostic lane, not a substitute for repeated production-path evidence.

## Redaction and sharing

Share only the allowlisted JSON report and adjacent Markdown summary after
review. They contain code-authored task/variant IDs, numeric counters, hashes,
bounded failure classifications and runtime/model metadata, not raw prompts,
model output, hidden reasoning, credentials, headers, private tool outputs,
workspace paths, or arbitrary exception text. Do not upload environment
snapshots, base config, credential values, temporary profile/runtime state, or
private `--failure-dir` bundles. Configuration/source/catalog hashes establish
identity, not permission to publish their unhashed contents.

For an authorized evidence attachment, record the exact sanitized command,
revision **and source digest**, approved plan digest, experiment settings, report
link, uncontrolled factors, missing measurements, and the decision. Never attach
secrets or imply a plan-only artifact is a live result.

## Rollout and rollback

Until that evidence is reviewed, the recorded decision remains
`keep-current-defaults` / `keep-opt-in`; no profile or threshold is promoted.
After an authorized run, retain the defaults for negative/inconclusive evidence,
or name the exact proposed profile/threshold and its success/security checks,
measured task-level benefit, uncertainty and cache/pricing caveats. Do not
promote solely because schema-token estimates declined.

To revert an operator's opt-in profile to the existing disclosure behavior:

```toml
[runtime.tools.disclosure]
profile = "legacy"
```

To disable disclosure entirely instead:

```toml
[runtime.tools.disclosure]
enabled = false
```

Remove conflicting environment/profile overrides (environment has precedence)
and start a fresh session/runtime so the chosen catalog is rebuilt. These are
operator rollback settings, not tables to put into the paired base TOML, which
must leave disclosure settings to the runner.
