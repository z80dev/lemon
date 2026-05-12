# Lemon testing lanes

`scripts/test` is the canonical repo-level test runner. It keeps local commands close to CI while leaving heavyweight or environment-specific checks explicit.

## Quick usage

```bash
scripts/test help
scripts/test fast
scripts/test quality
scripts/test clients
scripts/test eval-fast
scripts/test live-eval
scripts/test smoke
scripts/test all
scripts/test path apps/lemon_core/test/lemon_core/quality --seed 1
```

## Lanes

- `fast`: compiles with `mix compile --warnings-as-errors`, then runs `mix test --exclude integration`. The lane defaults to `MIX_ENV=test`, creates per-invocation temp `LEMON_TEST_TMPDIR` and `LEMON_STORE_PATH` values when they are not already set, and scrubs ambient live provider/platform credentials unless explicitly opted in.
- `quality`: runs Lemon's lightweight policy/quality gates: `scripts/lint_ci_docs.sh`, `scripts/test_contract.sh`, `mix lemon.skill.lint`, `mix lemon.quality`, and the focused quality/eval contract tests used by CI. `mix lemon.quality` already runs the duplicate test module guard internally.
- `clients`: mirrors the client CI job for `clients/lemon-web`, `clients/lemon-tui`, and `clients/lemon-browser-node`: install dependencies when `node_modules` is absent, typecheck, lint, build, run coverage tests, and audit production dependencies.
- `eval-fast`: runs a small deterministic eval harness invocation with `mix lemon.eval --iterations ${LEMON_EVAL_ITERATIONS:-3}`. The harness includes memory scope/topic contracts, relevant-skill prompt disclosure, scripted skill-curator behavior, async delegation joins, and child artifact verification contracts. Increase `LEMON_EVAL_ITERATIONS` locally when you need more confidence.
- `live-eval`: runs the opt-in provider-backed eval lane with `mix lemon.eval --live-model --iterations ${LEMON_EVAL_ITERATIONS:-3}`. It fails before app startup unless `LEMON_EVAL_API_KEY`, `LEMON_EVAL_API_KEY_SECRET`, `INTEGRATION_API_KEY`, `INTEGRATION_API_KEY_SECRET`, or legacy `ANTHROPIC_API_KEY` is set. Secret variables hold the name of a Lemon secret and resolve with env fallback, so local release-candidate runs can use the normal encrypted secret store without printing credentials. Configure the model with `LEMON_EVAL_PROVIDER`, `LEMON_EVAL_MODEL`, `LEMON_EVAL_BASE_URL`, and `LEMON_EVAL_API_TYPE`; matching generic `INTEGRATION_*` variables are also accepted. The current live lane checks that an independent model calls `search_memory` for prior-work recall, chooses `read_skill`/`skill_manage` for reusable skill capture, performs a curator-style umbrella consolidation, respects the scheduled-run blocked cron surface, and delegates parallel child work before answering.
- `smoke`: documents the product-smoke lane and points at `.github/workflows/product-smoke.yml`. It exits successfully locally because the current product smoke builds and boots a release with CI assumptions. The workflow builds a release, boots it, checks control-plane HTTP health, handshakes with the control-plane WebSocket protocol, calls `health`, submits a deterministic `echo` agent run, waits for it through `agent.wait`, checks the web health endpoint for the full runtime profile, verifies release support-bundle generation, lints built-in skills, and runs focused adaptive gate checks.
- `all`: useful local aggregate for BEAM-centric pre-review confidence: `fast`, `quality`, `eval-fast`, then `smoke`. Run `clients` separately when client code or shared contracts changed.
- `path`: pass-through to `mix test` for specific paths or ExUnit args, for example `scripts/test path apps/coding_agent/test --only some_tag`.

## Local/CI parity

- `fast` is the local counterpart for the CI umbrella test job's compile and `mix test --exclude integration` steps.
- `quality` follows the repository quality job without the heavyweight WASM/integration loop. Use CI or targeted manual commands for `cargo test --manifest-path native/lemon-wasm-runtime/Cargo.toml` and WASM integration coverage.
- `clients` follows the CI client job command order for each Node client.
- `eval-fast` is intentionally smaller than CI's `mix lemon.eval --iterations 20` so developers can run it frequently. `live-eval` is intentionally excluded from default local and push/PR CI lanes because it depends on external provider credentials and latency. Use `.github/workflows/live-eval.yml` for manual release-candidate live evals when repository secrets are configured.
- `smoke` is CI-only until there is a stable local release-smoke wrapper; use the GitHub workflow for the full product smoke.

## Hermetic unit-test environment

The BEAM test lanes in `scripts/test` scrub ambient live credentials before running Mix commands. This keeps normal unit tests from accidentally depending on a developer's local provider, cloud, or platform tokens.

Representative scrubbed variables include:

- LLM/provider secrets: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENAI_CODEX_API_KEY`, `CHATGPT_TOKEN`, `OPENCODE_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, `GOOGLE_GEMINI_CLI_API_KEY`, `GOOGLE_API_KEY`, `GROQ_API_KEY`, `NOUS_API_KEY`, `KIMI_API_KEY`, `MOONSHOT_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`, `FIREWORKS_API_KEY`, `XAI_API_KEY`, `LEMON_EVAL_API_KEY`, `LEMON_EVAL_API_KEY_SECRET`, `INTEGRATION_API_KEY`, `INTEGRATION_API_KEY_SECRET`.
- OAuth/CLI and secret-store material: `ANTHROPIC_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, `LEMON_SECRETS_MASTER_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_APPLICATION_CREDENTIALS_JSON`.
- Platform/cloud credentials: `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `TWILIO_AUTH_TOKEN`, X API credentials, XMTP wallet keys, Feishu/DingTalk tokens.

Live/integration runs that intentionally need real credentials must opt in explicitly:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 scripts/test path apps/some_app/test --only integration
scripts/test live-eval
```

## Live Channel Proofs

Live channel proofs are release-candidate gates, not normal unit-test lanes. Run
them with the established Telegram and Discord credentials only when validating
the channel support boundary, and never print token or session-file contents.

Telegram stable-boundary proof uses Telethon credentials from
`~/.zeebot/api_keys/telegram.txt` and targets the Lemonade Stand group
`-1003842984060`, primary forum topic `35`, and isolation topic `16456`:

```bash
scripts/live_telegram_matrix.py --timeout 90
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-isolation \
  --isolation-topic-id 35 \
  --isolation-topic-id 16456 \
  --timeout 180
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-cancel \
  --cancel-topic-id 35 \
  --timeout 95
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-tool-rendering \
  --topic-markdown \
  --timeout 160
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-approval \
  --approval-topic-id 35 \
  --timeout 180
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-long-output \
  --long-output-topic-id 35 \
  --timeout 120
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-file-get \
  --file-get-topic-id 35 \
  --timeout 90
```

The restart/dedupe check is two-step: seed a handled topic message, restart the
runtime, then verify that the old message is not replayed and a fresh topic
prompt still works.

Discord proof uses `~/.zeebot/api_keys/discord.txt` or `DISCORD_BOT_TOKEN`,
guild `1475727416549969980`, and channel `1475727417372049419`:

```bash
scripts/live_discord_matrix.py --list-channels
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-api-smoke
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index 1 \
  --manual-matrix \
  --reset-session-between-checks \
  --timeout 300 \
  --result-path tmp/discord-live-proof.json
```

The Discord bot API smoke is diagnostic only. Stable Discord requires an
external-sender inbound prompt that creates a Lemon run and receives the
expected reply in the same supported channel or thread. The sender can be a
human Discord user or the second Lemonade Stand bot token; self-authored
responder messages and webhooks do not count. The manual matrix prints one
prompt at a time and stops on the first failed check by default, so each next
prompt means the previous prompt was observed and validated. Use
`--continue-on-failure` only when collecting diagnostic failure output.
When using the second bot sender, keep `--reset-session-between-checks` so each
matrix prompt starts from a clean Discord channel session.

The manual GitHub workflow is:

```bash
gh workflow run live-eval.yml \
  --ref v2026.05.0 \
  -f iterations=3 \
  -f live_timeout_ms=90000
gh run list --workflow live-eval.yml --limit 5
gh run watch {run-id} --exit-status
```

Configure the workflow with the repository secret `LEMON_EVAL_API_KEY` or one of
the accepted fallback secrets, `INTEGRATION_API_KEY` or `ANTHROPIC_API_KEY`.
For local release-candidate runs, `LEMON_EVAL_API_KEY_SECRET` and
`INTEGRATION_API_KEY_SECRET` may point at a Lemon secret name, for example:

```bash
mix lemon.secrets.set release_eval_api_key <token>
LEMON_EVAL_API_KEY_SECRET=release_eval_api_key scripts/test live-eval
```

The workflow exposes provider/model/base URL/API type as dispatch inputs and
runs the same `scripts/test live-eval` lane on Elixir 1.19.5 and Erlang/OTP
28.5.

To configure the preferred release-eval secret through GitHub CLI without
printing the value in shell history:

```bash
gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon
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
