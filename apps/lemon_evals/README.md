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
