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
A production-path outcome suite and repeated paired trials remain separate work.

The manually dispatched Live Eval workflow retains this allowlisted report for
14 days with `if: always()`, including when checks fail. It warns when startup
or another early failure prevented artifact creation. This does not add a
schedule, an automatic paid-model run, or raw-trace uploading.
