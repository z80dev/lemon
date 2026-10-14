# LemonEvals

Deterministic and opt-in live evaluation harnesses for the Lemon coding-agent stack.

## Responsibilities

- `LemonEvals.Harness` runs deterministic tool, prompt, memory, skill, delegation, and coding-repair contracts against the real coding-agent surface.
- `mix lemon.eval` runs the harness from the umbrella root with the existing task name.
- Live-model checks remain opt-in through `--live-model` and the `LEMON_EVAL_*` / `INTEGRATION_*` credential environment variables.

`lemon_evals` is a dev/CI rig and is not included in runtime releases.

## Commands

```bash
mix lemon.eval --iterations 20
mix test apps/lemon_evals/test
cd apps/lemon_evals && mix test --cover
```

## Live agentic coding benchmark

The nonpaired lane measures actual coding outcomes through the production
`lemon -p --output json` client and can make paid model calls immediately. It is
never part of the fast lane:

```bash
LEMON_CONTROL_PLANE_PORT=4210 mix lemon.eval.coding \
  --model openai-codex:gpt-6.1-sol \
  --output /tmp/lemon-coding-benchmark.json
```

Configure credentials normally and reuse a healthy daemon, or let the standard
launcher start it. The Mix task itself does not boot another router. `--lemon`
selects an installed launcher; `--timeout` bounds each CLI invocation (default
660 seconds, slightly longer than the client's ten-minute run deadline).

Twelve disposable git repositories exercise bug repair, multi-file refactoring,
feature implementation with tests, reading and answering, bash debugging,
targeted editing of a 12,000-entry file, repository-wide search/migration,
recovery after a failing tool, a five-layer atomic reservation feature,
order-dependent flaky-test diagnosis, a vendored dependency API migration, and
large, noisy retry-log analysis. A verifier outside each repository checks real
behavior, and applicable tasks must also pass their repository's unittest suite.
The recovery task also requires at least one observed failed tool call, so simply
skipping the requested failure cannot earn a pass.
Runs explicitly allow requested tool approvals; use an isolated runtime and do
not point this benchmark at a sensitive workspace.

The command writes a JSON report and adjacent Markdown table containing task
pass/fail, completed assistant turns, tokens, wall time, and failed tool calls.
Missing runtime counters are `null`/`n/a`, never estimated from tool-call count.
All tasks run even when one fails; any failure makes the command exit nonzero.
The report contains no raw prompts, model output, credentials, or workspace paths.
Without `--paired`, it measures one trial per task, not statistically significant
model rankings.

For local failure diagnosis only, `--failure-dir /tmp/lemon-bench-failures`
retains private failure bundles with the task repo, verifier, and CLI/test
stdout/stderr. These may contain sensitive model output; do not commit or upload
them. Without that explicit flag, every temporary repository is removed.

### Repeated paired disclosure trials

`--paired` extends the same fixtures, production client, and external verifiers
to compare `baseline` (the legacy disclosure profile) with opt-in `coding`.
It does not compare omp. Attempts run sequentially in seeded, counterbalanced
order, with a fresh production runtime, configuration, store, and fixture per
attempt.

```bash
# Operator-selected paths/settings; no --live means no model calls.
mix lemon.eval.coding --paired \
  --model PROVIDER:MODEL \
  --repetitions 3 --seed 107 \
  --config /OPERATOR/PATH/benchmark-base.toml \
  --profile-python /OPERATOR/PATH/profile-venv/bin/python \
  --timeout 660 --run-timeout 3600 \
  --output /OPERATOR/PATH/paired-plan-template.json
```

The base TOML must omit `runtime.tools.disclosure`; live profiling requires
`tiktoken` in the selected Python environment.

This is plan-only: it writes a sanitized **unsigned plan template**, not outcome
evidence. Live attempts additionally require `--live --plan PLAN.json
--approve-plan-digest SHA256`, with an explicitly approved exact experiment and
positive bounded spend/attempt limits backed by a hard account/provider budget.
Do not use ordinary daemon credentials or assume local timeouts enforce billing
limits. Optional `--schema-budgets N,N` adds explicitly selected
`coding_budget_N` variants only when useful after the baseline/coding comparison.

The [canonical paired workflow](../../docs/benchmarks/paired-disclosure.md)
defines approval, configuration isolation, report metadata, all-attempt cost
accounting, exploratory task-cluster uncertainty, redaction, and rollback.
No authorized live paired evidence is recorded here: keep current defaults and
keep the coding profile opt-in; any promotion remains pending an approved bounded
run and sanitized report. Schema-size diagnostics alone do not justify promotion.

### Comparing omp on identical tasks

```bash
LEMON_CONTROL_PLANE_PORT=4210 mix lemon.eval.coding --compare-omp \
  --model openai-codex:gpt-6.1-sol --omp-model openai-codex/gpt-6.1-sol \
  --output /tmp/lemon-vs-omp.json
```

`--omp PATH` selects an installed executable. Configure its credentials normally;
the benchmark never imports, refreshes, or rotates credentials. `PI_CODING_AGENT_DIR`
can select isolated omp state. Each harness gets a fresh copy of the identical
fixture and prompt, and uses its normal default tool catalog. Requested approvals
are explicitly allowed. omp uses print mode, JSON events, no saved session/title,
and its own maximum-time option. One Lemon/omp pair runs concurrently; subsequent
tasks wait for both results. The Markdown report places pass, completed parent
turns, provider-reported tokens, and wall time side by side. JSON additionally
separates cached and uncached input and records independent verifier outcomes.
Cached input is included in total tokens, not treated as newly billed input.
Default reasoning/configuration remains harness-specific; this is an empirical
workflow comparison, not a controlled model ranking. `--tasks NAME,NAME` selects
specific cases for an intentional targeted trial.

### Profiling Lemon's per-turn token consumers

Use a dedicated source-development daemon, never an existing user's daemon.
After normal boot, deliberately install the development adapter:

```elixir
LemonEvals.PayloadProfile.install!("/tmp/lemon-payload-profile.jsonl",
  python: "/path/to/venv/bin/python")
```

Its Python environment requires `tiktoken` (`python3 -m venv /tmp/profile-venv`
then `/tmp/profile-venv/bin/pip install tiktoken`). Installation uses the transient
`CodingAgent.Executor.configure_stream_options/1` hook; it does not replace the
gateway executor. Clear the hook with `CodingAgent.Executor.configure_stream_options(nil)`
when ending profiling. The native coding session and provider configuration remain
unchanged. Optional Codex callbacks observe final request bodies and raw terminal
usage in memory. Only counts, declared tool names,
and hashes are written to an owner-only JSONL file; raw prompts, arguments, tool
outputs, encrypted replay values, headers, and credentials are never retained.
Profile work is asynchronous and opt-in; the ordinary runtime has no observer.

After running the benchmark against that daemon:

```bash
python3 apps/lemon_evals/priv/profile_report.py \
  --input /tmp/lemon-payload-profile.jsonl \
  --benchmark /tmp/lemon-vs-omp.json \
  --output /tmp/lemon-token-profile.json
```

Vendor `usage.attribution.request_fields` supplies actual instructions/schema
input and cache attribution where available. Visible text/JSON measurements use
`o200k_base` and are explicitly **estimates**, not provider billing totals.
Encrypted replay is counted only in bytes. Repeated context is a subset of those
measurements, not an extra category to add to the total. The report rejects
missing terminal usage measurements rather than manufacturing a complete profile.



## Retained evaluation reports

Write a machine-readable artifact separately from diagnostic console output:

```bash
mix lemon.eval --iterations 20 \
  --output /tmp/lemon-evals/contracts.json \
  --revision "$(git rev-parse HEAD)"
```

`--output` writes schema version 1 before the task raises for failed checks, so
an ordinary evaluation failure still leaves a report. An application startup
failure, killed process, or harness exception before a report is produced does
not manufacture a success artifact. File-write failures also fail the command.
A sibling temporary file is renamed into place after writing; this is not a
power-loss durability guarantee.

The artifact contains the suite name, recording time, explicit commit SHA,
Elixir/OTP versions, configured iterations/live-model/timeout settings, total
suite duration, recomputed pass/fail counts, and each check's stable name/status.
Raw `details`, prompts, transcripts, tool arguments, errors, provider URLs,
workspace paths, and credentials are excluded. Check names are code-authored,
non-sensitive identifiers, not user-provided labels. No environment snapshot or
implicit Git command is used. Omitted `--revision` produces JSON null.

The existing `--json` flag still prints the detailed legacy report to stdout.
It is not the redacted artifact and its diagnostic details may be sensitive.
Only upload the `--output` file when sharing summary results.

`--iterations` controls existing statistical checks. It does **not** repeat
every live-model check as an independent trial. The report records contract
results, not benchmark task-success rates, dollar costs, or a Hermes comparison.
The separate coding lane above records single-trial production-path outcomes by
default; `--paired` is the explicitly opted-in repeated disclosure experiment.
Neither lane changes what the contract harness's `--iterations` means.

The manually dispatched Live Eval workflow retains this allowlisted report for
14 days with `if: always()`, including when checks fail. It warns when startup
or another early failure prevented artifact creation. This does not add a
schedule, an automatic paid-model run, or raw-trace uploading.
