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

- `fast`: compiles with `mix compile --warnings-as-errors`, then runs `mix test --exclude integration`. The lane defaults to `MIX_ENV=test`, creates per-invocation temp `LEMON_TEST_TMPDIR` and `LEMON_STORE_PATH` values when they are not already set, and scrubs ambient live provider/platform credentials unless explicitly opted in.
- `quality`: runs Lemon's lightweight policy/quality gates: `scripts/lint_ci_docs.sh`, `scripts/test_contract.sh`, `mix lemon.skill.lint`, `mix lemon.quality`, and the focused quality/eval contract tests used by CI. `mix lemon.quality` already runs the duplicate test module guard internally.
- `clients`: mirrors the client CI job for `clients/lemon-web`, `clients/lemon-tui`, and `clients/lemon-browser-node`: install dependencies when `node_modules` is absent, typecheck, lint, build, run coverage tests, and audit production dependencies.
- `eval-fast`: runs a small deterministic eval harness invocation with `mix lemon.eval --iterations ${LEMON_EVAL_ITERATIONS:-3}`. The harness includes memory scope/topic contracts, relevant-skill prompt disclosure, and the scripted skill-curator behavior contract. Increase `LEMON_EVAL_ITERATIONS` locally when you need more confidence.
- Opt-in live model evals: run `mix lemon.eval --live-model` when you want provider-backed behavioral coverage outside CI. Configure with `LEMON_EVAL_API_KEY`, `LEMON_EVAL_PROVIDER`, `LEMON_EVAL_MODEL`, `LEMON_EVAL_BASE_URL`, and `LEMON_EVAL_API_TYPE`; matching `INTEGRATION_*` variables are also accepted. The current live lane checks that an independent model calls `search_memory` for prior-work recall, chooses `read_skill`/`skill_manage` for reusable skill capture, performs a curator-style umbrella consolidation, respects the scheduled-run blocked cron surface, and delegates parallel child work before answering.
- `smoke`: documents the product-smoke lane and points at `.github/workflows/product-smoke.yml`. It exits successfully locally because the current product smoke builds and boots a release with CI assumptions.
- `all`: useful local aggregate for BEAM-centric pre-review confidence: `fast`, `quality`, `eval-fast`, then `smoke`. Run `clients` separately when client code or shared contracts changed.
- `path`: pass-through to `mix test` for specific paths or ExUnit args, for example `scripts/test path apps/coding_agent/test --only some_tag`.

## Local/CI parity

- `fast` is the local counterpart for the CI umbrella test job's compile and `mix test --exclude integration` steps.
- `quality` follows the repository quality job without the heavyweight WASM/integration loop. Use CI or targeted manual commands for `cargo test --manifest-path native/lemon-wasm-runtime/Cargo.toml` and WASM integration coverage.
- `clients` follows the CI client job command order for each Node client.
- `eval-fast` is intentionally smaller than CI's `mix lemon.eval --iterations 20` so developers can run it frequently. Live model evals are intentionally excluded from default local and CI lanes because they depend on external provider credentials and latency.
- `smoke` is CI-only until there is a stable local release-smoke wrapper; use the GitHub workflow for the full product smoke.

## Hermetic unit-test environment

The BEAM test lanes in `scripts/test` scrub ambient live credentials before running Mix commands. This keeps normal unit tests from accidentally depending on a developer's local provider, cloud, or platform tokens.

Representative scrubbed variables include:

- LLM/provider secrets: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENAI_CODEX_API_KEY`, `CHATGPT_TOKEN`, `OPENCODE_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, `GOOGLE_GEMINI_CLI_API_KEY`, `GOOGLE_API_KEY`, `GROQ_API_KEY`, `NOUS_API_KEY`, `KIMI_API_KEY`, `MOONSHOT_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`, `FIREWORKS_API_KEY`, `XAI_API_KEY`.
- OAuth/CLI and secret-store material: `ANTHROPIC_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, `LEMON_SECRETS_MASTER_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_APPLICATION_CREDENTIALS_JSON`.
- Platform/cloud credentials: `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `TWILIO_AUTH_TOKEN`, X API credentials, XMTP wallet keys, Feishu/DingTalk tokens.

Live/integration runs that intentionally need real credentials must opt in explicitly:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 scripts/test path apps/some_app/test --only integration
```

Shared Elixir helpers live in `LemonCore.Testing.HermeticEnv`:

- `credential_env_vars/0` returns the canonical scrub list.
- `scrub_unit_credentials!/1` deletes those variables unless live credentials are explicitly allowed. It returns `:ok` when scrubbing runs and `{:skipped, :live_credentials_allowed}` when the live-credential opt-in is active.
- `with_restored_env/2` snapshots and restores env vars around synchronous tests that intentionally mutate process-wide env.

Because environment variables are process-wide, tests that call `System.put_env/2` or `System.delete_env/1` should generally be `async: false` and should restore their changes with `with_restored_env/2` or an `on_exit/1` snapshot.

## Notes for agents

- Prefer `scripts/test fast` over ad hoc `mix test` for broad local checks.
- Prefer `scripts/test path ...` when validating a narrow change.
- Keep new lanes documented here and visible in `scripts/test help`.
- Do not bypass credential scrubbing for unit lanes. Use `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1` only for explicit live/integration validation.
