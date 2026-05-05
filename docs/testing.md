# Lemon testing lanes

`scripts/test` is the canonical repo-level test runner. It keeps local commands close to CI while leaving heavyweight or environment-specific checks explicit.

## Quick usage

```bash
scripts/test help
scripts/test fast
scripts/test quality
scripts/test clients
scripts/test eval-fast
scripts/test smoke
scripts/test all
scripts/test path apps/lemon_core/test/lemon_core/quality --seed 1
```

## Lanes

- `fast`: compiles with `mix compile --warnings-as-errors`, then runs `mix test --exclude integration`. The lane defaults to `MIX_ENV=test` and creates per-invocation temp `LEMON_TEST_TMPDIR` and `LEMON_STORE_PATH` values when they are not already set.
- `quality`: runs Lemon's lightweight policy/quality gates: `scripts/lint_ci_docs.sh`, `scripts/test_contract.sh`, `mix lemon.skill.lint`, `mix lemon.quality`, `mix lemon.check_duplicate_tests`, and the focused quality/eval contract tests used by CI.
- `clients`: mirrors the client CI job for `clients/lemon-web`, `clients/lemon-tui`, and `clients/lemon-browser-node`: install dependencies when `node_modules` is absent, typecheck, lint, build, run coverage tests, and audit production dependencies.
- `eval-fast`: runs a small deterministic eval harness invocation with `mix lemon.eval --iterations ${LEMON_EVAL_ITERATIONS:-3}`. Increase `LEMON_EVAL_ITERATIONS` locally when you need more confidence.
- `smoke`: documents the product-smoke lane and points at `.github/workflows/product-smoke.yml`. It exits successfully locally because the current product smoke builds and boots a release with CI assumptions.
- `all`: useful local aggregate for BEAM-centric pre-review confidence: `fast`, `quality`, `eval-fast`, then `smoke`. Run `clients` separately when client code or shared contracts changed.
- `path`: pass-through to `mix test` for specific paths or ExUnit args, for example `scripts/test path apps/coding_agent/test --only some_tag`.

## Local/CI parity

- `fast` is the local counterpart for the CI umbrella test job's compile and `mix test --exclude integration` steps.
- `quality` follows the repository quality job without the heavyweight WASM/integration loop. Use CI or targeted manual commands for `cargo test --manifest-path native/lemon-wasm-runtime/Cargo.toml` and WASM integration coverage.
- `clients` follows the CI client job command order for each Node client.
- `eval-fast` is intentionally smaller than CI's `mix lemon.eval --iterations 20` so developers can run it frequently.
- `smoke` is CI-only until there is a stable local release-smoke wrapper; use the GitHub workflow for the full product smoke.

## Notes for agents

- Prefer `scripts/test fast` over ad hoc `mix test` for broad local checks.
- Prefer `scripts/test path ...` when validating a narrow change.
- Keep new lanes documented here and visible in `scripts/test help`.
- Do not add full hermetic environment scrubbing in this runner without a separate design; Phase 1 only sets basic deterministic temp paths for test lanes.
