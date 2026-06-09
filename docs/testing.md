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
- `clients`: mirrors the client CI jobs for `clients/lemon-cli`, `clients/lemon-web`, `clients/lemon-tui`, and `clients/lemon-browser-node`. The Python CLI path uses `uv sync --locked --dev`, `uv run ruff check src tests`, `uv run pytest`, and `uv build --sdist --wheel`; the Node clients install dependencies when `node_modules` is absent, typecheck, lint, build, run coverage tests, and audit production dependencies.
- Source-install changes should keep `scripts/verify_source_install --skip-compile` green after a local compile. For release-candidate source installs, run `scripts/verify_source_install` without skips so it checks the BEAM toolchain, source-wrapper help discoverability for setup/channels/config/doctor/send/media/models/providers/policy/proofs/readiness/secrets/skill/usage/update, locked dependency resolution, warning-free test compile, source-wrapper non-interactive setup dispatch through `./bin/lemon setup runtime --profile runtime_min --non-interactive`, source-wrapper promoted channel readiness through `./bin/lemon channels --project-dir`, source-wrapper config validation through `./bin/lemon config validate --project-dir`, source-wrapper media diagnostics through `./bin/lemon media --project-dir --limit 1`, source-wrapper model catalog listing through `./bin/lemon models --provider anthropic --limit 1`, source-wrapper provider readiness listing through `./bin/lemon providers --provider anthropic --project-dir`, source-wrapper model policy listing through `./bin/lemon policy list`, source-wrapper proof artifact listing through `./bin/lemon proofs --project-dir --limit 1`, source-wrapper readiness summary through `./bin/lemon readiness --project-dir --limit 1`, source-wrapper secrets status through `./bin/lemon secrets status`, source-wrapper skill listing through `./bin/lemon skill list`, source-wrapper usage diagnostics through `./bin/lemon usage`, source-wrapper stage-1 local update dry-run dispatch through `./bin/lemon update --check --no-skill-sync --verbose`, source-wrapper doctor JSON diagnostics through `./bin/lemon doctor --json`, and redacted support-bundle generation with compact launch readiness plus proof-gate status/counts in `readiness_summary.json`.
- `eval-fast`: runs a small deterministic eval harness invocation with `mix lemon.eval --iterations ${LEMON_EVAL_ITERATIONS:-3}`. The harness includes memory scope/topic contracts, relevant-skill prompt disclosure, scripted skill-curator behavior, async delegation joins, and child artifact verification contracts. Increase `LEMON_EVAL_ITERATIONS` locally when you need more confidence.
- `live-eval`: runs the opt-in provider-backed eval lane with `mix lemon.eval --live-model --iterations ${LEMON_EVAL_ITERATIONS:-3}`. It fails before app startup unless `LEMON_EVAL_API_KEY`, `LEMON_EVAL_API_KEY_SECRET`, `INTEGRATION_API_KEY`, `INTEGRATION_API_KEY_SECRET`, or legacy `ANTHROPIC_API_KEY` is set. Secret variables hold the name of a Lemon secret and resolve with env fallback, so local release-candidate runs can use the normal encrypted secret store without printing credentials. Configure the model with `LEMON_EVAL_PROVIDER`, `LEMON_EVAL_MODEL`, `LEMON_EVAL_BASE_URL`, and `LEMON_EVAL_API_TYPE`; matching generic `INTEGRATION_*` variables are also accepted. The current live lane checks that an independent model calls `search_memory` for prior-work recall, chooses `read_skill`/`skill_manage` for reusable skill capture, performs a curator-style umbrella consolidation, respects the scheduled-run blocked cron surface, delegates parallel child work before answering, handles untrusted external content, preserves leaf-worker tool restrictions, verifies child side effects before finalizing, and completes a tiny Elixir coding repair by reading source, patching code, running `elixir test/lemon_release_report_test.exs`, and answering only after the test passes.
- Script notification changes should keep `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1` green. That focused lane covers `mix lemon.send` parsing, `./bin/lemon send` target formats, default Telegram/Discord target env vars, config-backed default targets, env-over-config precedence, account-scoped delivery and known-target resolution, config-backed default account ids, standalone thread/topic target overrides, reply-to payload routing, Telegram known-target discovery from `LemonChannels.Telegram.KnownTargetStore`, Discord known-target discovery from `LemonChannels.Discord.KnownTargetStore`, list-mode alias metadata, unique Telegram known-name resolution, unique Discord known-name resolution, positional/file/stdin body resolution, `--file -`, repeated `--attach` payload construction up to 10 files, attachment caption handling, attachment filename/count/byte metadata, attachment input errors, dry-run validation without delivery, subject formatting, help text, filtered JSON/list mode, bounded `message_id` extraction, batch delivery `extra_message_ids` extraction, and injected Telegram/Discord direct-delivery payloads without real platform credentials. Attachment changes should also keep the adapter file-delivery lanes green with `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs --seed 1`. Discord transport changes that affect target indexing should also run `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs apps/lemon_channels/test/lemon_channels/discord/known_target_store_test.exs --seed 1`. The source wrapper should also be smoke-checked for Unix exit codes: success/list/help/dry-run returns `0`, usage/config/input failures return `2`, attachment usage/input failures return `2`, and platform delivery failures return `1`.
- Cron lifecycle changes should keep `apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs`, `apps/lemon_automation/test/lemon_automation/cron_manager_update_test.exs`, `apps/lemon_automation/test/lemon_automation/cron_store_test.exs`, `apps/lemon_core/test/lemon_core/doctor/cron_diagnostics_test.exs`, `apps/lemon_core/test/lemon_core/doctor/checks_test.exs`, `apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs`, `apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`, `apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs`, `apps/lemon_web/test/lemon_web_test.exs`, and `apps/lemon_gateway/test/tools/cron_test.exs` green. That focused lane covers immutable job fields, schedule shorthand normalization, operator-owned no-agent command cron, pause/resume, active-run abort, terminal `aborted` status persistence, durable lifecycle audit events, redacted support-bundle audit diagnostics, `cron.audit` schema/method/event exposure audit visibility, the model-facing cron tool lifecycle actions, and `cron.preview` doctor readiness over the redacted diagnostics, runtime-restart, and channel-origin proof artifacts. TUI cron abort changes should also keep `cd clients/lemon-tui && npm run typecheck` plus focused `useCommands` and `agent-connection` Vitest coverage green for `/cron abort <run-id>` and `cron.abort` WebSocket routing. Channel-origin cron promotion should also run `MIX_ENV=test mix run scripts/live_cron_channel_origin_smoke.exs`, which proves Telegram- and Discord-shaped channel-peer cron completions through `CronManager`, forwarded run history, `LemonRouter.ChannelsDelivery`, and the LemonChannels outbox using proof-only plugins.
- `smoke`: documents the product-smoke lane and points at `.github/workflows/product-smoke.yml`. It exits successfully locally because the current product smoke builds and boots a release with CI assumptions. The workflow builds a release, boots it, checks control-plane HTTP health, handshakes with the control-plane WebSocket protocol, calls `health`, submits a deterministic `echo` agent run, waits for it through `agent.wait`, checks the web health endpoint for the full runtime profile, verifies release support-bundle generation, lints built-in skills, and runs focused adaptive gate checks.
- `all`: useful local aggregate for BEAM-centric pre-review confidence: `fast`, `quality`, `eval-fast`, then `smoke`. Run `clients` separately when client code or shared contracts changed.
- `path`: pass-through to `mix test` for specific paths or ExUnit args, for example `scripts/test path apps/coding_agent/test --only some_tag`.

## Local/CI parity

- `fast` is the local counterpart for the CI umbrella test job's compile and `mix test --exclude integration` steps.
- `quality` follows the repository quality job without the heavyweight WASM/integration loop. Use CI or targeted manual commands for `cargo test --manifest-path native/lemon-wasm-runtime/Cargo.toml` and WASM integration coverage.
- `clients` follows the CI client job command order for the Python CLI package check and each Node client.
- `eval-fast` is intentionally smaller than CI's `mix lemon.eval --iterations 20` so developers can run it frequently. `live-eval` is intentionally excluded from default local and push/PR CI lanes because it depends on external provider credentials and latency. Use `.github/workflows/live-eval.yml` for manual release-candidate live evals when repository secrets are configured.
- `.github/workflows/history-check.yml` is a PR-only repository-integrity guard. It checks out the pull request head with full history, fetches the base branch, and rejects unrelated-history PRs when `git merge-base "origin/${GITHUB_BASE_REF}" HEAD` returns no common ancestor.
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

Persistent-goal live model judging has its own opt-in proof. It keeps normal
test lanes deterministic, but proves `GoalJudge.RouterRunner` through the real
router/gateway/model path when credentials are available:

```bash
ZAI_API_KEY="$(MIX_ENV=dev mix run --no-start -e 'Logger.configure(level: :emergency); Logger.remove_backend(:console); {:ok, _} = Application.ensure_all_started(:lemon_core); IO.write(LemonCore.Secrets.fetch_value("llm_zai_api_key") || "")')" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_GOAL_JUDGE_MODEL="zai:glm-5-turbo" \
scripts/test path apps/lemon_automation/test/lemon_automation/goal_judge_router_live_test.exs --include integration --seed 1
```

`scripts/test path` uses an isolated `LEMON_STORE_PATH`, so secret-store-backed
providers must be resolved into the provider env var before the test runner
boots. The Z.ai command above passed locally on 2026-05-15 with `1 test, 0
failures`.

The deterministic persistent-goal lane covers durable goal state,
continuation budget plumbing, one-shot continuation, judge-loop verdicts,
bounded and persisted-auto loop behavior, control-plane goal methods, and
channel-visible goal/loop status formatting:

```bash
mix test apps/lemon_core/test/lemon_core/goal_store_test.exs \
  apps/lemon_automation/test/lemon_automation/goal_continuation_test.exs \
  apps/lemon_automation/test/lemon_automation/goal_loop_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/goal_methods_test.exs \
  apps/lemon_channels/test/lemon_channels/goal_status_message_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `32 tests, 0 failures` across
`lemon_core`, `lemon_automation`, `lemon_control_plane`, and `lemon_channels`.

Memory-provider proof covers the BEAM-native provider boundary behind
`search_memory` and the Hermes-compatible `session_search` wrapper: local SQLite remains the built-in provider, registered BEAM
providers receive safety-screened ingest fan-out, scoped searches fan out without
broadening missing scope keys, provider failures are isolated, `memory.status`
exposes read-only provider shape renders the same redacted registry
state, and `memory_diagnostics.json` redacts memory contents and raw provider
config.

```bash
mix test apps/lemon_core/test/lemon_core/memory_providers_test.exs \
  apps/lemon_core/test/lemon_core/memory_ingest_test.exs \
  apps/lemon_core/test/lemon_core/memory_store_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  apps/lemon_core/test/lemon_core/application_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs \
  apps/lemon_web/test/lemon_web_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with 49 core tests, 93 control-plane
tests, and 25 Web tests, all with 0 failures.

Router queue proof covers the session-level preemption rule that keeps
operator/user input ahead of queued autonomous goal continuations:

```bash
mix test apps/lemon_router/test/lemon_router/run_phase_sequence_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `5 tests, 0 failures`. It covers
accepted/queued/waiting phase order, steer fallback, follow-up merge aborts,
and a channel-origin `:collect` submission starting before a queued
`goal_continuation` `:followup`.

Kanban live worker proof is also opt-in. It proves the real dispatcher,
`KanbanRunWorker`, router, gateway, run waiter, and provider-backed Lemon engine
path with three durable tasks; the dispatcher must reach two workers in flight,
then all tasks must complete with run ids and cleared leases:

```bash
secret_file=$(mktemp "${TMPDIR:-/tmp}/lemon-zai-secret.XXXXXX")
LEMON_SECRET_OUTPUT="$secret_file" MIX_ENV=dev mix run --no-start -e '
Logger.configure(level: :emergency)
Logger.remove_backend(:console)
{:ok, _} = Application.ensure_all_started(:lemon_core)
case LemonCore.Secrets.fetch_value("llm_zai_api_key") do
  value when is_binary(value) and value != "" -> File.write!(System.fetch_env!("LEMON_SECRET_OUTPUT"), value)
  _ -> System.halt(66)
end
' >/dev/null 2>&1
ZAI_API_KEY="$(cat "$secret_file")" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_KANBAN_LIVE_MODEL="zai:glm-5-turbo" \
scripts/test path apps/lemon_automation/test/lemon_automation/kanban_dispatcher_live_test.exs --include integration --seed 1
rc=$?
rm -f "$secret_file"
exit "$rc"
```

This proof passed locally on 2026-05-15 with `1 test, 0 failures`.

Durable kanban/fleet board foundation checks cover the BEAM store, JSON-RPC
methods, model-facing tool surface, worker dispatch, worktree submission,
bounded multi-worker leasing, crashed-worker failure marking, TUI command
bridge, and support-bundle redaction:

```bash
mix test apps/coding_agent/test/coding_agent/tools/kanban_test.exs \
  apps/lemon_core/test/lemon_core/kanban_store_test.exs \
  apps/lemon_automation/test/lemon_automation/kanban_dispatcher_test.exs \
  apps/lemon_automation/test/lemon_automation/kanban_dispatcher_live_test.exs \
  apps/lemon_automation/test/lemon_automation/kanban_run_worker_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/kanban_methods_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  apps/lemon_channels/test/lemon_channels/kanban_status_message_test.exs
```

```bash
cd clients/lemon-tui
npm run build
npm test -- src/ink/hooks/useCommands.test.tsx src/agent-connection.test.ts src/autocomplete.test.ts
```

Channel checkpoint rollback checks cover redacted Telegram/Discord checkpoint
status, lifecycle event counts, active-run pushed checkpoint notices, redacted
diff/restore controls, Discord slash-command schema export, and deterministic
Discord slash payload decoding/response handling:

```bash
mix test apps/lemon_channels/test/lemon_channels/checkpoint_status_message_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_checkpoint_event_test.exs --seed 1
```

The Discord transport slice passed locally on 2026-05-16 with `9 tests, 0
failures`, and `mix run --no-start scripts/live_discord_slash_interaction_proof.exs`
writes `.lemon/proofs/discord-slash-interaction-proof-latest.json` with the
current completed deterministic check set. The proof covers the 16-command
local slash inventory, checkpoint/rollback/kanban/media payload decoding, and safe local interaction
responses for session/model/thinking/resume/cancel/media/trigger/cwd/topic/file
paths. The proof artifact also records safe coverage counts consumed by
`proofs.status`, support bundles, and. It is not real Discord
client-click evidence.

The live Discord runtime also has a passive client-click proof recorder. When a
real slash-command interaction arrives from Discord with live-only fields such
as `application_id` and `token`, and Lemon emits a safe interaction response,
the transport writes redacted proof JSON under `.lemon/proofs/` with proof
object `lemon.discord_slash_client_click` and scope
`discord_slash_client_click_observed`. The recorder stores command name,
response type, ephemeral/safe-mention booleans, and coverage booleans/counts,
but not raw interaction tokens, application ids, channel ids, user ids, or
message bodies. Synthetic deterministic interactions do not satisfy this proof
unless they carry the live-field shape, and
`scripts/live_discord_slash_interaction_proof.exs` remains explicitly marked
`real_client_click_proof: false`.

After deploy or hot reload, run the wait-mode handoff and ask an operator to
click the requested real Discord slash command, such as `/media status` or
`/checkpoint status`, before the timeout expires:

```bash
scripts/live_discord_matrix.py --wait-slash-client-click-proof \
  --channel-id "$DISCORD_PROOF_CHANNEL_ID" \
  --result-path tmp/discord-slash-client-click-proof-wait.json \
  --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json
```

The watcher posts a concrete instruction when `--channel-id` is present, polls
`.lemon/proofs/discord-slash-client-click-proof-latest.json`, and rejects proof
artifacts generated before the watcher started. To validate an already captured
artifact without waiting:

```bash
scripts/live_discord_matrix.py --check-slash-client-click-proof \
  --result-path tmp/discord-slash-client-click-proof-check.json
```

The one-shot check does not require Discord API credentials; it validates the local
redacted proof artifact and fails until a real live-field interaction has been
observed.

For live Discord matrix runs, keep `--result-path` for operator handoff data
such as nonces and Discord message ids, and add `--proof-path` when the result
should feed `proofs.status`, support bundles, doctor gates, or.
The proof path writes a sanitized artifact with hashed channel/user/message
identifiers, check counts, reason kinds, cleanup assertions, and safe coverage
booleans for which live-matrix families were exercised, but no raw Discord ids,
message bodies, bot tokens, interaction tokens, application ids, or secret
names:

```bash
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index 1 \
  --manual-matrix \
  --reset-session-between-checks \
  --timeout 300 \
  --result-path tmp/discord-live-proof.json \
  --proof-path .lemon/proofs/discord-live-matrix-latest.json
```

Discord safe-mention checks cover outbound text, edits, file captions, long
chunks, component messages, and interaction responses. Discord sends set
`allowed_mentions: %{parse: [], replied_user: false}` by default so model or
tool output cannot ping users, roles, `@everyone`, `@here`, or replied users:

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1
mix run --no-start scripts/live_discord_safe_mentions_proof.exs
```

This lane passed locally on 2026-05-16 with `15 tests, 0 failures`; the proof
script wrote `.lemon/proofs/discord-safe-mentions-proof-latest.json` with three
completed checks.

Discord approval-component checks cover the button path from a Discord
component interaction into `LemonCore.ExecApprovals.resolve/2` using the same
atom decisions expected by core approval state:

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1
mix run --no-start scripts/live_discord_approval_component_proof.exs
```

This lane passed locally on 2026-05-16 with `10 tests, 0 failures`; the proof
script wrote `.lemon/proofs/discord-approval-component-proof-latest.json` with
two completed checks.

Discord runtime-component checks cover cancel and watchdog keepalive buttons
through the same `LemonChannels.Runtime` / `LemonCore.RouterBridge` path used
in production:

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1
mix run --no-start scripts/live_discord_runtime_components_proof.exs
```

This lane passed locally on 2026-05-16 with `12 tests, 0 failures`; the proof
script wrote `.lemon/proofs/discord-runtime-components-proof-latest.json` with
three completed checks.

Discord inbound dedupe checks cover duplicate `MESSAGE_CREATE` events through
the real transport normalization, ETS dedupe table, persisted idempotency
boundary, debounce buffer, reaction path, `LemonChannels.Runtime`, and
`LemonCore.RouterBridge`. This proves one Lemon run submission for a duplicated
Discord message before debounce flush and after a simulated transport restart
with an empty in-memory buffer and cleared ETS table; it still does not prove
live Discord gateway reconnect replay from an external sender.

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1
mix run --no-start scripts/live_discord_dedupe_proof.exs
```

This lane passed locally on 2026-05-16 with `13 tests, 0 failures`; the proof
script wrote `.lemon/proofs/discord-dedupe-proof-latest.json` with four
completed checks, including
`transport_restart_replay_duplicate_does_not_submit_again`.

Discord trigger-mode checks cover the free-response channel boundary. By
default, unmentioned group messages are suppressed. `/trigger all` stores the
channel mode and lets the next unmentioned message submit through the normal
debounce/runtime path, while `/trigger mentions` restores mention-gated
behavior.

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1
mix run --no-start scripts/live_discord_trigger_mode_proof.exs
```

This lane passed locally on 2026-05-16 with `14 tests, 0 failures`; the proof
script wrote `.lemon/proofs/discord-trigger-mode-proof-latest.json` with four
completed checks.

Live Discord free-response checks use the second bot to send an unmentioned
message in a temporary thread after seeding that thread's trigger mode through
`LemonChannels.Adapters.Discord.TriggerMode`. The harness cleans up the thread
override after the run and records a failure hint if no reply is observed.

```bash
scripts/live_discord_matrix.py --bot-token-index 0 \
  --wait-free-response-trigger \
  --per-check-thread \
  --sender-bot-token-index 1 \
  --reset-session-between-checks \
  --channel-id 1475727417372049419 \
  --result-path tmp/discord-free-response-proof.json \
  --proof-path .lemon/proofs/discord-free-response-latest.json \
  --timeout 120
```

The latest local live run on 2026-05-16 wrote
`tmp/discord-free-response-proof.json` with `ok: false`: the unmentioned
second-bot message was visible through Discord's REST API, the thread trigger
override was set and cleared, but no Lemon reply was observed. Treat this as an
open promotion gate; check Discord Message Content Intent, live gateway delivery
for unmentioned messages, and trigger-mode store visibility before promoting
free-response Discord support beyond deterministic proof. Support bundles expose
the redacted `channel_diagnostics.json` free-response readiness shape so
operators can confirm that Lemon requests the Discord `message_content` gateway
intent at runtime and whether the operator has declared the privileged Developer
Portal setting without leaking Discord IDs or message bodies.

The rerun on 2026-05-17 passed after fixing thread trigger resolution for the
Discord event shape where a public-thread `MESSAGE_CREATE` arrives with the
thread id as `channel_id` and no parent-channel context. The live proof at
`.lemon/proofs/discord-free-response-latest.json` reports
`message_content_intent_declared: true`, trigger mode `all`, cleanup mode
`clear`, and a completed unmentioned second-bot round trip. The runner also
preflights Discord application Message Content Intent flags against the local
Lemon declaration before waiting.

`mix lemon.doctor --verbose` now exposes the same Discord promotion gates as
redacted checks. Before broad Discord promotion, `channels.discord.dm`,
`channels.discord.free_response`, `channels.discord.reconnect`, and
`channels.discord.slash_client_click` must pass. Warning states are expected
before promotion and should classify the live blocker without leaking Discord
IDs or message bodies: closed-DM targets stay `discord_dm_setup_refused`,
restart seed without verify stays a reconnect warning, and missing
operator-clicked slash proof stays a slash client-click warning.

Extension host checks cover the BEAM plugin execution trust boundary. Default
extension directories remain diagnostics-only unless trusted, an explicit
`extension_paths` entry loads a BEAM extension tool through the normal
`CodingAgent.ToolRegistry`, extension tool execution can stream an update, and
built-in tools still win namespace conflicts. The same smoke also verifies
redacted start/stop/exception telemetry with hashed tool-call and extension
identities, and proves global disabled mode blocks explicit-path extension
execution without loading extension code.

```bash
mix run --no-start scripts/live_extension_host_smoke.exs
```

This lane passed locally on 2026-05-17; the proof script wrote
`.lemon/proofs/extension-host-smoke-latest.json` with seven completed checks.
It does not prove public plugin registry workflow or sandboxed non-BEAM host
execution.

WASM tool wrapper telemetry has a separate focused proof:

```bash
MIX_ENV=test mix run scripts/live_wasm_telemetry_smoke.exs
```

This writes `.lemon/proofs/wasm-tool-telemetry-latest.json` and verifies
successful WASM tool execution, returned sidecar errors, and sidecar exits emit
redacted start/stop/exception telemetry with hashed WASM paths and tool-call
ids. `extensions.status` and surface the redacted proof status,
check status, host-boundary flags, proof hash, and redaction summary. It proves
the wrapper telemetry contract only; public registry workflow and broad sandbox
parity remain separate plugin-ecosystem work.

WASM risky-capability approval policy has a separate proof lane:

```bash
MIX_ENV=test mix run scripts/live_wasm_policy_smoke.exs
```

This writes `.lemon/proofs/wasm-policy-latest.json` and verifies that `http`,
`tool_invoke`, and `exec` capabilities require approval by default, safe
capabilities execute without approval, and an explicit `approvals.<tool> =
never` policy can override that default. It proves policy-wrapper behavior, not
full runtime sandboxing or marketplace install/update review.

Extension registry install/update audits have a separate code-free proof lane:

```bash
MIX_ENV=test mix run scripts/live_extension_registry_audit_smoke.exs
```

This writes `.lemon/proofs/extension-registry-audit-latest.json` and verifies
that registry metadata can be validated without loading extension code, audited
packages are counted as installable, unaudited or blocked packages are blocked,
a newer audited update candidate is detected, and registry paths, package
names, distribution URLs, and manifest contents remain out of operator-facing
proof summaries. It proves registry metadata review, not full marketplace
hosting or sandboxed non-BEAM execution.

WASM sidecar lifecycle has a separate proof lane:

```bash
MIX_ENV=test mix run scripts/live_wasm_lifecycle_smoke.exs
```

This writes `.lemon/proofs/wasm-lifecycle-latest.json` and verifies redacted
discover/invoke lifecycle telemetry, running-status visibility, explicit
sidecar stop termination, and omission of raw cwd, session id, tool name, and
params from lifecycle telemetry.

`mix lemon.doctor --verbose` reports the BEAM extension-host proof as
`extensions.telemetry` and the WASM wrapper proof as
`extensions.wasm_telemetry`, and the WASM approval-policy proof as
`extensions.wasm_policy`, and the registry install/update proof as
`extensions.registry_audit`, and the WASM sidecar lifecycle proof as
`extensions.wasm_lifecycle`. These checks warn when a stale or incomplete
proof exists and skip before the matching proof has been generated. The generic
`proofs.status` and support-bundle proof inventory also preserve proof-level
`redaction` maps for extension/WASM artifacts, so recent proof summaries expose
the redacted raw-cwd/session/tool/param/path/manifest/distribution flags even
when the artifact has no generic `cleanup` map. The JSON-RPC `proofs.status`
method preserves the same `redaction` map on formatted recent proofs for
external clients with lowerCamelCase keys, and renders the generic
proof-row redaction summary in its proof artifact panel.

Telegram and Discord renderer checks cover finalized-run text presentation,
file batches, generated-file auto-send boundaries, and Discord config-gated
generated attachment delivery:

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/renderer_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/discord/renderer_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `19 tests, 0 failures`.

Media job observability checks cover redacted generated-media metadata,
`media.status`, support-bundle `media_diagnostics.json` snapshot
visibility, router finalization recording for generated `auto_send_files`, and
Hermes-compatible final-answer `MEDIA:<path>` directives that resolve through
the same safe attachment path:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs \
  apps/lemon_core/test/lemon_core/media_jobs_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  apps/lemon_web/test/lemon_web_test.exs \
  apps/lemon_router/test/lemon_router/artifact_tracker_test.exs \
  apps/lemon_router/test/lemon_router/media_job_recorder_test.exs \
  apps/lemon_router/test/lemon_router/run_process_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `174 tests, 0 failures`.

Channel media status checks cover Telegram `/media` command recognition,
Discord `/media status` slash schema export, local Discord `INTERACTION_CREATE`
ephemeral response handling, and redacted channel formatting for media job
counts, artifact counts, cleanup policy, and recent jobs:

```bash
mix test apps/lemon_channels/test/lemon_channels/media_status_message_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1
```

The focused Discord transport lane passed locally on 2026-05-16 with `9 tests,
0 failures`; the broader media status lane should be rerun after channel media
changes.

BEAM media worker checks cover the OTP media job supervisor, queued/running/
completed/failed metadata transitions, PubSub lifecycle events, artifact
recording, and error redaction:

```bash
mix test apps/lemon_core/test/lemon_core/media_job_supervisor_test.exs \
  apps/lemon_core/test/lemon_core/media_jobs_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `5 tests, 0 failures`.

Model-facing media checks cover the `media_status`, `media_generate_image`,
`media_generate_speech`, `media_transcribe_audio`, `media_analyze_image`, and
`media_generate_video`
tools, the deterministic `local_svg`, `local_wav`, `local_transcript`, and
`local_vision`/`local_mp4` preview workers, redacted prompt/text/audio/image/
video metadata, managed SVG/WAV/audio/transcript/analysis/video artifact writes,
provider-backed `openai_image`, `vertex_imagen`, `openai_tts`, `google_tts`,
`openai_transcribe`,
`openai_vision`, including provider-prefixed OpenAI-compatible vision model
routing, and `openai_video` plus `vertex_veo`
request/response handling with injected HTTP, provider error redaction,
untrusted result marking for model-visible transcript and image-analysis text,
generated
`auto_send_files`, bounded transient-provider retry behavior, source
preservation through the Lemon runner, channel
generated-file gating, tool registry membership, and policy profile behavior:

```bash
mix test apps/coding_agent/test/coding_agent/tools/media_status_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_generate_image_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_generate_speech_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_transcribe_audio_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_analyze_image_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_generate_video_test.exs \
  apps/coding_agent/test/coding_agent/tools_test.exs \
  apps/coding_agent/test/coding_agent/tool_registry_test.exs \
  apps/coding_agent/test/coding_agent/tool_policy_test.exs \
  apps/coding_agent/test/coding_agent_test.exs \
  apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/discord/renderer_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/telegram/renderer_test.exs --seed 1
```

The focused untrusted-output slice for media transcript and image-analysis text
also passed locally on 2026-05-16:

```bash
mix test apps/coding_agent/test/coding_agent/tools/media_analyze_image_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_transcribe_audio_test.exs \
  apps/coding_agent/test/coding_agent/security/untrusted_tool_boundary_test.exs --seed 1
```

This lane passed with `24 tests, 0 failures`. It proves both media tools mark
model-visible `text` as untrusted with trust metadata, and the shared
untrusted-tool boundary wraps malicious marker-smuggling text once before an LLM
sees it.

This lane passed locally on 2026-05-16 with `256 tests, 0 failures`.

Provider-backed media image, speech, transcription, vision, and video have opt-in live proof
harnesses. They are skipped unless live credentials are explicitly enabled,
resolve provider credentials through the same Lemon runtime config/secrets path
as the tools, write redacted proof JSON, and store only hashes/metadata in the
proof. Image proof can use OpenAI or Google Vertex AI Imagen evidence; pass
`--provider vertex_imagen` to validate the Vertex lane with the default
`imagen-4.0-generate-001` model. TTS proof can use OpenAI, ElevenLabs, or
Google Cloud Text-to-Speech evidence; pass `--provider google_tts` to validate
Google TTS with the default `cloud_tts_v1` model and `en-US-Neural2-C` voice.
Video proof can use OpenAI or Google Vertex AI Veo evidence; pass
`--provider vertex_veo` to validate the Vertex lane with the default
`veo-3.1-fast-generate-001` model.
Use `--api-key-secret SECRET_NAME` for one-off proof against the
encrypted Lemon secret store without exporting a raw API key, or
`--api-key-env ENV_NAME` for an explicit environment-variable override:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_image_smoke.exs \
    --proof-path .lemon/proofs/media-image-smoke-latest.json
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_image_smoke.exs \
    --provider vertex_imagen \
    --proof-path .lemon/proofs/media-image-smoke-latest.json
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_speech_smoke.exs \
    --proof-path .lemon/proofs/media-speech-smoke-latest.json
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_speech_smoke.exs \
    --provider google_tts \
    --proof-path .lemon/proofs/media-speech-smoke-latest.json
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_transcription_smoke.exs \
    --proof-path .lemon/proofs/media-transcription-smoke-latest.json
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_vision_smoke.exs \
    --model openrouter:openai/gpt-4o-mini \
    --proof-path .lemon/proofs/media-vision-smoke-latest.json
```

The media vision smoke passed on 2026-05-17 through OpenRouter
`openai/gpt-4o-mini`, writing
`.lemon/proofs/media-vision-smoke-latest.json` with `completed_count: 1`,
`failed_count: 0`, and redacted hashes only. The `--api-key-secret` path uses
`mix run --no-start` so the script can explicitly boot against the persistent
encrypted Lemon secret store before resolving the one-off proof credential. The first
direct-OpenAI attempt reached the BEAM media worker but failed with redacted
`openai_vision_http_error`, so direct OpenAI quota remains a separate
environment proof rather than a stable claim. The provider-prefixed OpenAI-compatible routing handoff is currently supported by the vision proof path only;
image, TTS, STT, and video proof scripts intentionally report
`provider_prefixed_model_not_supported_for_media_type` if called with a
`provider:model` value. For those OpenAI-shaped media endpoints, use
`--base-url` with an unprefixed provider model when validating a compatible
service. Direct OpenAI image, Vertex Imagen image, TTS, Google TTS, STT, and
Vertex Veo video proof attempts also reached the BEAM
media worker and wrote redacted failed
proofs. The current image proof records
`vertex_imagen_http_error:permission_denied`; an earlier OpenAI image proof
recorded `openai_image_http_error:billing_limit_user_error`; the current TTS
proof records `google_tts_http_error:permission_denied`; the current video
proof records `vertex_veo_create_http_error:permission_denied`; an earlier ElevenLabs
TTS proof recorded `elevenlabs_tts_http_error:payment_required`; older direct OpenAI TTS/STT
attempts recorded `openai_tts_http_error` and
`openai_transcription_http_error`. The Deepgram STT provider proof now passes
with `deepgram_transcribe`, moving provider-backed media to 2/5 complete:
STT and vision are current, while image, TTS, and video remain open until
usable provider quota/payment or a compatible provider is configured. The media
smoke proof harnesses include the safe provider error kind in failed proof JSON
instead of only reporting `media job failed`. `mix lemon.doctor --verbose`
also carries those safe `reason_kind` labels into `media.provider_live`, so
operators can distinguish failed, skipped, and missing image/TTS/STT/vision/video
proof lanes without inspecting raw provider responses. The final readiness audit
prints the same bounded `reason_kind` labels when provider-backed media proofs
are incomplete, so a blocked release run shows the credential/quota/API class
without exposing provider bodies, media bytes, prompts, transcripts, or keys.
Provider detail statuses and types are safe-suffixed when available, for example
`vertex_imagen_http_error:permission_denied`,
`google_tts_http_error:permission_denied`,
`openai_tts_http_error:invalid_request_error`, or
`elevenlabs_tts_http_error:payment_required`; the free-form provider message
body is still hashed only.
Discord DM, free-response, and real slash client-click readiness use the same
pattern: incomplete redacted proof artifacts may contribute bounded
`reason_kind` labels to final-audit stderr, but raw Discord IDs, tokens, secret
names, and message bodies stay out of release diagnostics.

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_video_smoke.exs \
    --proof-path .lemon/proofs/media-video-smoke-latest.json
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run --no-start scripts/live_media_video_smoke.exs \
    --provider vertex_veo \
    --proof-path .lemon/proofs/media-video-smoke-latest.json
```

LSP diagnostics preview checks cover the model-facing `lsp_diagnostics` tool,
baseline/delta suppression for pre-existing issues, graceful skipped results,
opt-in post-edit diagnostics on `write`, `edit`, and `patch`, plus redacted
control-plane support-bundle status visibility, and the supervised
language-server registry/session/initialize/JSON-RPC/diagnostic-notification
manager, stderr containment, launcher-child cleanup, request-timeout session
termination, and document open/change/close notification redaction:

```bash
mix test apps/coding_agent/test/coding_agent/tools/lsp_diagnostics_test.exs \
  apps/lemon_core/test/lemon_core/lsp_servers_test.exs \
  apps/lemon_core/test/lemon_core/lsp_server_manager_test.exs \
  apps/lemon_core/test/lemon_core/doctor/lsp_diagnostics_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  apps/lemon_core/test/lemon_core/application_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs \
  apps/lemon_web/test/lemon_web_test.exs \
  apps/coding_agent/test/coding_agent/tools/write_test.exs \
  apps/coding_agent/test/coding_agent/tools/edit_test.exs \
  apps/coding_agent/test/coding_agent/tools/patch_test.exs \
  apps/coding_agent/test/coding_agent/tools_test.exs \
  apps/coding_agent/test/coding_agent/tool_registry_test.exs \
  apps/coding_agent/test/coding_agent_test.exs --seed 1
```

This preview lane passed locally on 2026-05-16 with `404 tests, 0 failures`
across `coding_agent`, `lemon_core`, `lemon_web`, and `lemon_control_plane`.

LSP server live smoke is opt-in and proves the supervised stdio session boundary
against a real language server:

```bash
MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs
```

Use `--out /path/to/proof.json` to change the proof path. For broader
real-server proof, pass a comma-separated server list:

```bash
MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs \
  --servers pyright,gopls,clangd,rust_analyzer,typescript_language_server,elixir_ls \
  --timeout-ms 90000 \
  --project-fixtures \
  --editor-flow
```

On 2026-05-16 the default smoke completed `pyright`, captured `6` redacted
diagnostics in `1` batch, and failed zero servers. The full local fleet proof
completed `pyright`, `gopls`, `clangd`, `rust_analyzer`,
`typescript_language_server`, and `elixir_ls` with `completed_count: 6`,
`failed_count: 0`, `clean_after_change: true` for every server, and redacted
proof JSON. In this local environment ElixirLS uses
`LEMON_LSP_ELIXIR_LS_COMMAND=/home/z80/.local/lib/elixir-ls/launch.sh`; Lemon
sets `ELS_MODE=language_server` for the supervised session. A 2026-05-16
timeout cleanup proof against the broken default `elixir-ls` wrapper returned
`:request_timeout` and left no language-server processes running. The
`--editor-flow` full-fleet proof completed all six servers with diagnostics
reintroduced, cleared a second time, and the document closed. On 2026-05-17 the
project-fixture full-fleet proof wrote
`.lemon/proofs/lsp-project-fixtures-latest.json` with `completed_count: 6`,
`failed_count: 0`, safe `lsp_project_fixtures_smoke` scope, six per-server
completed checks, multi-file fixture counts, root-marker counts,
companion-file counts, final clean diagnostics, and closed documents.

The real-repository fixture proof copies selected Lemon source files into
isolated temporary projects, injects syntax breakage, repairs it, reintroduces
the breakage, repairs it again, and closes each document:

```bash
LEMON_LSP_ELIXIR_LS_COMMAND=/home/z80/.local/lib/elixir-ls/launch.sh \
  MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs \
  --servers typescript_language_server,elixir_ls \
  --real-repo-fixtures \
  --editor-flow \
  --timeout-ms 90000 \
  --out .lemon/proofs/lsp-real-repo-fixtures-latest.json
```

The full registered-server real-repository fixture proof passed locally on
2026-05-17 with `completed_count: 6`, `failed_count: 0`, proof scope
`lsp_real_repo_fixtures_smoke`, source hashes only for selected Python, Go, C,
Rust, TypeScript, and Elixir fixtures, initial/reintroduced diagnostics for all
servers, final clean diagnostics, closed documents, and cleanup flags false for
raw paths, file contents, diagnostics output, raw session ids, and server I/O.
`proofs.status`, support bundles and
`mix lemon.doctor --verbose` consume both
`.lemon/proofs/lsp-project-fixtures-latest.json` and
`.lemon/proofs/lsp-real-repo-fixtures-latest.json`; the final readiness audit
validates the same files by default or the
`LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON` and `LEMON_LSP_REAL_REPO_PROOF_JSON`
overrides when release evidence lives elsewhere.

OpenAI-compatible API preview checks cover the HTTP `/v1` adapter without
starting a real model run:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/http/router_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `24 tests, 0 failures`. It covers
`/v1/health`, `/v1/capabilities`, `/v1/models`,
`/v1/models/:model_id`, queued `/v1/chat/completions`, queued
`/v1/responses`, synchronous wait completion, Responses output text mapping,
wait timeout handling, session-key metadata, `previous_response_id`
continuation metadata, stored response retrieval,
unknown stored response errors, streaming request metadata, redacted run status,
unknown-run errors, run cancellation dispatch, Chat Completions SSE over run bus
events, Responses SSE over run bus events, redacted tool-progress SSE events
without raw tool detail, optional bearer auth, optional `x-api-key` auth,
redacted image-input metadata normalization for Chat Completions and Responses,
data URL image pass-through into runtime-only Lemon image blocks, opt-in
allowlisted HTTPS image URL fetch into runtime-only image blocks, disallowed
remote image host rejection before submission, prompt normalization, and
validation errors.

The `/v1` adapter also has a deterministic live HTTP smoke. It starts a local
Bandit router, calls the endpoints through `:httpc`, exercises redacted
image-input metadata, data URL image pass-through, allowlisted remote image URL
fetch, single-model retrieval, an external Node `fetch` client, and an official
OpenAI Node SDK client, and writes redacted proof JSON without raw prompts,
answers, API keys, or run events:

```bash
MIX_ENV=test mix run scripts/live_openai_compat_smoke.exs
```

This smoke passed locally on 2026-05-16 with `completed_count: 12` and
`failed_count: 0`; the nested external `fetch` client completed 6 checks and
the official OpenAI SDK client completed 4 checks.

`proofs.status`, support bundles, and `mix lemon.doctor --verbose` consume the
same redacted result rows as `openai_compat_*` checks with proof scope
`openai_compat_api`. The doctor check `openai_compat.api_preview` passes only
when the local smoke has completed health/capability, Chat Completions,
Responses, image metadata/pass-through/rejection/policy, streaming, stored
response, cancellation, run-redaction, external fetch client, OpenAI Node SDK,
and OpenAI Python SDK rows. Rerun
`MIX_ENV=test mix run scripts/live_openai_compat_smoke.exs` if it warns or
skips.

The `/v1` adapter also has an opt-in provider-backed vision smoke over the real
router/gateway/model path:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_OPENAI_COMPAT_LIVE_VISION_MODEL=openrouter:openai/gpt-4o-mini \
MIX_ENV=test mix run scripts/live_openai_compat_vision_smoke.exs
```

The script starts a local Bandit router without OpenAICompat stubs, posts a
data URL image to `/v1/responses` with `wait: true`, checks that the provider
identifies the image color, then runs `scripts/live_openai_compat_fetch_client.mjs`
in vision-only mode against the same local `/v1/responses` boundary. It writes
redacted proof JSON and skips unless live credentials are explicitly enabled, a
vision-capable model is configured, and a provider credential resolves.
Credential preflight uses `LemonAiRuntime.provider_has_credentials?/3`, so it
matches runtime credential resolution for env keys, encrypted secrets,
OAuth/default-secret paths, and provider-specific credential shapes. If no model
is provided, the script tries credential-ready defaults in this order: OpenRouter
`openai/gpt-4o-mini`, OpenAI `gpt-4o-mini`, then Z.ai `glm-4.6v`. On
2026-05-16 this proof passed through OpenRouter `openai/gpt-4o-mini` with
`completed_count: 1`, `failed_count: 0`, external Node fetch client vision
sub-proof `completed_count: 1` / `answer_matched_red: true`, and official
OpenAI Node SDK vision sub-proof `completed_count: 1` /
`answer_matched_red: true`. Direct OpenAI was blocked by account quota, and the
Z.ai coding endpoint accepted text credentials but rejected image inputs; keep
any explicit provider in the command aligned with the credential and image
support being claimed.

Provider routing has a separate opt-in live fallback proof:

```bash
ZAI_API_KEY="$(MIX_ENV=dev mix run --no-start -e 'Logger.configure(level: :emergency); Logger.remove_backend(:console); {:ok, _} = Application.ensure_all_started(:lemon_core); IO.write(LemonCore.Secrets.fetch_value("llm_zai_api_key") || "")')" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
MIX_ENV=test mix run scripts/live_provider_fallback_smoke.exs
```

The smoke intentionally starts with an invalid primary OpenAI credential, then
proves that default-model stream fallback retries through the configured Z.ai
provider before visible output starts. It writes redacted proof JSON with only
provider names, model id, hashes, counts, and cleanup booleans. It skips unless
live credentials are explicitly enabled and a fallback provider credential
resolves. The latest run passed on 2026-05-17 with `final_provider: "zai"`,
`completed_count: 1`, and `failed_count: 0`.

The external client sub-proofs can also be run against an already-running Lemon
HTTP server. `scripts/live_openai_compat_fetch_client.mjs` accepts
`LEMON_OPENAI_COMPAT_CHECKS=vision` and `LEMON_OPENAI_COMPAT_IMAGE_BASE64` for
the provider-backed vision sub-proof; omit those variables for the default
deterministic external-client checks. The SDK client accepts the same vision
mode and expects the `openai` package in the current Node working directory; the
live smoke installs it in a temporary directory automatically.

```bash
LEMON_OPENAI_COMPAT_BASE_URL=http://127.0.0.1:4000 \
LEMON_OPENAI_COMPAT_API_TOKEN=... \
node scripts/live_openai_compat_fetch_client.mjs

LEMON_OPENAI_COMPAT_BASE_URL=http://127.0.0.1:4000 \
LEMON_OPENAI_COMPAT_API_TOKEN=... \
node scripts/live_openai_compat_openai_sdk_client.mjs
```

ACP preview checks cover the JSON-RPC adapter without starting a real model
run:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/acp_test.exs --seed 1
```

This lane passed locally on 2026-05-17 with `12 tests, 0 failures`. It covers
ACP `initialize` capability negotiation, safe client filesystem capability
capture on sessions and prompt metadata, `session/new`, router-backed
`session/prompt` with text and resource-link prompt blocks, queued prompt
submission, unsupported media rejection, `session/list`, `session/resume`,
`session/cancel`, `session/close`, `/acp` HTTP bearer-token auth, and the
newline-delimited JSON stdio transport helper used by
`scripts/lemon_acp_stdio.exs`, including store-backed session recovery after
ETS cache loss and `session/update` notification projection from Lemon run bus
`:delta` and `:engine_action` events. It also covers stdio client request
callbacks for `session/request_permission`, `fs/read_text_file`, and
`fs/write_text_file`, with prompt-response metadata limited to method names,
permission outcomes, content byte counts, and content hashes. Matching
`LemonCore.ExecApprovals.request/1` events for the ACP session key are also
bridged to ACP `session/request_permission` and resolved from the selected ACP
option.

The model-facing ACP filesystem bridge is covered with the same control-plane
ACP lane plus focused coding-agent tool tests:

```bash
MIX_ENV=test mix test apps/coding_agent/test/coding_agent/tools/acp_file_bridge_test.exs \
  apps/coding_agent/test/coding_agent/tools/read_test.exs \
  apps/lemon_gateway/test/cli_adapter_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/acp_test.exs --seed 1
```

This lane passed locally on 2026-05-17 with `51 tests, 0 failures` across the
coding-agent tool bridge/read tests, `7 tests, 0 failures` across the gateway
CLI adapter tests, and `12 tests, 0 failures` across the control-plane ACP
tests. It proves `read`, `write`, `edit`, and `patch` model-facing file
operations route through correlated ACP `fs/read_text_file` and
`fs/write_text_file` requests when client filesystem capabilities are present,
that ACP capability metadata reaches runner options, and that unsupported ACP
patch delete/move operations fail closed.

The ACP stdio bridge also has a deterministic smoke over the same
newline-delimited JSON handler used by spawned editor-style clients:

```bash
LEMON_CONTROL_PLANE_PORT=0 \
LEMON_WEB_PORT=0 \
LEMON_SIM_UI_PORT=0 \
LEMON_GATEWAY_HEALTH_PORT=0 \
LEMON_ROUTER_HEALTH_PORT=0 \
mix run scripts/live_acp_stdio_smoke.exs
```

It writes `.lemon/proofs/acp-stdio-smoke-latest.json` plus a timestamped
archive proof. This smoke passed locally on 2026-05-17 with
`completed_count: 6`, `failed_count: 0`, and proof object
`lemon.acp_stdio_smoke`.

ACP stdio also has an external Node client proof. It spawns
`scripts/lemon_acp_stdio.exs` as a child process with
`LEMON_ACP_STDIO_FAKE_RUNTIME=1`, sends newline-delimited JSON requests over
stdin, observes `session/update` notifications on stdout, and writes redacted
proof JSON without raw prompts, answers, events, session ids, API keys, child
stderr, raw file contents, or raw file paths:

```bash
node scripts/live_acp_stdio_external_client.mjs
```

It writes `.lemon/proofs/acp-stdio-external-client-latest.json` plus a
timestamped archive proof. This proof passed locally on 2026-05-17 at
`2026-05-17T09:14:22.069Z` with `completed_count: 9`, `failed_count: 0`,
`update_count: 2`, `client_request_count: 4`, and proof object
`lemon.acp_stdio_external_client_smoke`. The proof verifies that stdio
`initialize` client filesystem capabilities persist into `session/new`, then
round-trips `session/request_permission`, `fs/read_text_file`, and
`fs/write_text_file` through the spawned child-process stdio boundary; the
approval-bridge check proves the same boundary resolves a real
`LemonCore.ExecApprovals.request/1`.

The official ACP SDK proof is documented in `docs/tools/acp.md` and writes
`.lemon/proofs/acp-official-sdk-client-latest.json` with
`completed_count: 8`, `failed_count: 0`, `update_count: 2`, and
`client_request_count: 4`.

`proofs.status`, support bundles, and `mix lemon.doctor --verbose` consume the
ACP stdio proof rows as `acp_stdio_*`, `acp_stdio_external_*`, and
`acp_official_sdk_*` checks. The doctor check `acp.preview` passes only when
the deterministic stdio smoke, external Node stdio client proof, and official
ACP SDK client proof are all complete. Rerun
`MIX_ENV=test mix run scripts/live_acp_stdio_smoke.exs`,
`node scripts/live_acp_stdio_external_client.mjs`, and
`node scripts/live_acp_official_sdk_client.mjs` if it warns or skips.

MCP preview proof uses three redacted smoke artifacts:
`.lemon/proofs/mcp-stdio-latest.json`,
`.lemon/proofs/mcp-http-latest.json`, and
`.lemon/proofs/mcp-sse-latest.json`. `proofs.status`, support bundles, and
`mix lemon.doctor --verbose` consume them as `mcp_stdio`, `mcp_http`, and
`mcp_sse` proof scopes. The doctor check `mcp.preview` passes only when stdio,
Streamable HTTP, and legacy SSE smoke proofs are all complete. Rerun
`MIX_ENV=test mix run scripts/live_mcp_stdio_smoke.exs`,
`MIX_ENV=test mix run scripts/live_mcp_http_smoke.exs`, and
`MIX_ENV=test mix run scripts/live_mcp_sse_smoke.exs` if it warns or skips.

The combined control-plane adapter lane passed locally on 2026-05-16 with
`32 tests, 0 failures`:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/acp_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/http/router_test.exs --seed 1
```

Terminal backend preview checks cover the shared BEAM backend contract, the
local supervised Erlang Port backend metadata, local PTY backend metadata,
Docker backend metadata and in-container hardening assertions, SSH backend
metadata and redaction, support-bundle diagnostics, `exec` backend selection,
risky-shell checkpoints, and `process` list/poll backend visibility:

```bash
mix test apps/lemon_core/test/lemon_core/terminal_backends_test.exs \
  apps/lemon_core/test/lemon_core/terminal_backend_policy_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  apps/coding_agent/test/coding_agent/tools/exec_test.exs \
  apps/coding_agent/test/coding_agent/tools/process_tool_test.exs \
  apps/coding_agent/test/coding_agent/process_manager_test.exs --seed 1
```

The core support-bundle/policy sub-lane passed locally on 2026-05-15 with
`15 tests, 0 failures`.

The coding-agent terminal/checkpoint sub-lane passed locally on 2026-05-17 with
`22 tests, 0 failures` for the focused `exec` lane, including Docker hardening
assertions when Docker is usable.

The control-plane checkpoint restore/registry/schema lane passed locally on
2026-05-15 with `76 tests, 0 failures`.

The read-only terminal backend operator surface is covered by the optional
parity control-plane method lane:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `90 tests, 0 failures` after adding
`providers.status` coverage for redacted runtime credential readiness and schema
validation, plus `extensions.status` coverage for redacted extension loading,
tool-conflict, and extension-provider shape. It also covers `proofs.status`,
the read-only redacted proof-artifact summary for
`.lemon/proofs/*proof*.json`, `.lemon/proofs/*-latest.json`, and
`tmp/*proof*.json`, including safe provider fallback proof object/provider-path
fields and inferred `provider_fallback` scope without raw prompts, answers, or
provider response bodies. Source installs can inspect the same redacted local
inventory through `mix lemon.proofs` or `./bin/lemon proofs --limit 5`,
generated-media job, artifact, and provider-proof readiness through
`mix lemon.media` or `./bin/lemon media --limit 5`, a compact launch-readiness
summary through `mix lemon.readiness` or `./bin/lemon readiness --limit 5`, and
the promoted Telegram/Discord launch-gate summary through
`mix lemon.channels` or `./bin/lemon channels`. Use
`./bin/lemon readiness --strict` when a local script should fail unless the
compact readiness status is fully ready; the readiness text output includes the
shared proof-gate status line for Discord DM, slash registration, slash
client-click, provider media, and terminal backends, plus unresolved-gate reason
labels for text-mode operator triage. The source verifier asserts
that this `Proof gates:` line stays present, then exercises
the non-strict wrappers and checks support-bundle `readiness_summary.json` for
the shared proof-gate object, the five expected proof-gate ids,
`proof_gate_summary.gateCount == 5`, the proof-gate status map, and the
provider-media gate status. It also checks the prompt, provider-response,
raw-path, raw-filename, bot-token, and proof-detail cleanup claims. The same
support lane also covers JSON-RPC `readiness.status`, which returns the compact
launch-readiness rollup with lowerCamelCase cleanup keys and the shared
`LemonCore.Doctor.ProofLaunchGates` proof-gate summary for operator clients.
The JSON-RPC summary includes proof-gate status/counts/status maps for
lightweight clients and a sorted unresolved-gate reason-kind list derived from
both singular gate reasons and provider-media reason lists.
The control-plane optional parity lane passed locally on 2026-05-18 with
`69 tests, 0 failures` after adding `readiness.status` coverage for promoted
Telegram/Discord gate counts, provider-media state, proof totals, unresolved
gate limiting, registry metadata, and redaction of raw ids, prompts, provider
responses, and token-like values. It also locks in sanitized
`lemon.discord_live_matrix` coverage retention for `check_count`, sender shape,
restart, free-response, DM, thread, generated-media, and file-delivery
booleans plus slash-registration coverage booleans while still redacting raw
Discord artifact names and details. It also preserves sanitized terminal
backend proof rows as `terminal_backend_*` checks and exposes only safe Docker
hardening booleans and policy values from terminal backend proofs, including
cgroup-observed memory, CPU, and pids limit flags, without command text or
output.

Provider setup diagnostics are also covered in the support-bundle lane:

```bash
mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `2 tests, 0 failures`, including
`provider_diagnostics.json` coverage for provider setup shape, routing shape,
credential-reference counts, and redaction of raw API keys, secret names, base
URLs, and env var names. The same lane covers `extension_diagnostics.json` for
global/project/configured extension directory shape, extension-file counts,
manifest counts and aggregate capability/provider/host/distribution/audit
shape, and redaction of raw source paths, file contents, manifest contents,
distribution URLs, plugin names, provider names, and load-error messages. It
also covers `channel_diagnostics.json` for Telegram/Discord enablement, binding
counts, file-transfer shape, generated-file auto-send shape, Telegram
voice-transcription shape, Discord DM readiness shape, Discord free-response
readiness and Message Content Intent declaration shape, Discord inbound-replay
readiness shape, Discord slash-command readiness shape, Discord bot-message
policy shape, and redaction of bot tokens, secret names, chat IDs, channel IDs,
guild IDs, and message bodies.
Discord transport tests also prove that the transport ignores self bot messages
and webhooks while preserving `sender.bot` metadata and routing external bot
mentions through the normal runtime path when trigger policy allows them. It
also covers
`proof_diagnostics.json` for `.lemon/proofs/*proof*.json`,
`.lemon/proofs/*-latest.json`, and `tmp/*proof*.json` pass/fail summary, safe
proof-scope counts, safe check-name counts, latest redacted check status,
provider fallback proof object/provider-path metadata, and
reason-kind-count visibility with file/proof hashes only. Proof artifacts with explicit
`status` keep that status, while live proof artifacts with `ok: true` or
`ok: false` are classified as completed or failed instead of unknown. The
Discord free-response no-reply failure is reduced to a safe reason kind without
embedding its raw failure hint. Proof diagnostics omit raw proof paths,
filenames, prompts, provider responses, proof details, and proof file contents.
`mix lemon.proofs` and `./bin/lemon proofs` expose the same local inventory as a
read-only operator command with hash-only proof/file identifiers and no raw
artifact paths. `mix lemon.channels` and `./bin/lemon channels` expose the
shared Telegram/Discord readiness gates with safe evidence and next actions,
without bot tokens, secret names, chat ids, channel ids, message bodies, raw
proof paths, or raw proof details.
`mix lemon.usage` and `./bin/lemon usage` expose the shared usage/cost/token
diagnostics with provider rows, quota state, and cleanup flags, without prompts,
responses, message bodies, credentials, or secret values.
Channel doctor checks also treat the redacted all-command slash registration
artifact as the broad registration gate and warn separately when only the
`/media` registration proof is present.

Provider setup/doctor readiness has a focused lane:

```bash
mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `10 tests, 0 failures`, including
the `providers.routing` check for a not-ready default provider with a
credential-ready fallback. The assertion verifies the check reports only safe
provider labels and does not leak inline key material.

Extension package manifest validation is covered by:

```bash
mix test apps/lemon_core/test/lemon_core/extensions/manifest_test.exs \
  apps/lemon_core/test/mix/tasks/lemon.extension.validate_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `5 tests, 0 failures`.

Web terminal backend, provider-readiness, extension-directory, and proof-artifact
visibility are covered by the operations dashboard lane:

```bash
mix test apps/lemon_web/test/lemon_web_test.exs --seed 1
```

This lane passed locally on 2026-05-16 with `25 tests, 0 failures`.

Terminal backend preview also has an opt-in live local smoke. It runs redacted
commands through every available registered backend and writes proof JSON with
command, cwd, and output hashes. Docker additionally proves the launched
container sees the expected hardening from inside the sandbox: read-only root
filesystem, no-exec `/tmp` tmpfs, dropped effective capabilities,
no-new-privileges, no implicit image pulls, no-network default, and configured
memory, CPU, and pids limits. When `LEMON_SSH_TERMINAL_TARGET` is not already
configured and local `sshd` plus `ssh-keygen` are available, the smoke starts a
temporary high-port loopback `sshd` with generated host/client keys and
temporary known-hosts storage. This proves the SSH backend without touching
`~/.ssh` or recording raw key paths/targets in the proof:

```bash
MIX_ENV=test mix run scripts/live_terminal_backend_smoke.exs
```

Use `LEMON_TERMINAL_SMOKE_RESULT_PATH=/path/to/proof.json` to change the proof
output path. Set `LEMON_TERMINAL_SMOKE_LOOPBACK_SSH=0` to disable the
temporary loopback SSH proof. The smoke passed locally on 2026-05-17 with
`completed=4`, `skipped=0`, and `failed=0`: `local`, `local_pty`, `docker`,
and `ssh` completed, with SSH using temporary loopback credentials and only a
target hash in `.lemon/proofs/terminal-backend-latest.json`. The Docker result
records only safe hardening booleans and policy values: read-only rootfs,
no-exec tmpfs, dropped capabilities, no-new-privileges, cgroup-observed memory,
CPU, and pids limits, pull policy `never`, network `none`, memory `1g`, CPUs
`2`, and pids limit `256`.

`mix lemon.doctor --verbose` consumes the same redacted proof inventory through
`terminal.backends_live`. The check passes only when the latest terminal backend
proof has completed rows for the registered local, local PTY, Docker, and SSH
preview backends, warns on failed or missing rows, and skips when no terminal
backend proof has been generated yet. The remediation points back to
`MIX_ENV=test mix run scripts/live_terminal_backend_smoke.exs` and the canonical
`.lemon/proofs/terminal-backend-latest.json` artifact.

Terminal process metadata/restart preview has its own local smoke:

```bash
MIX_ENV=test mix run scripts/live_terminal_process_smoke.exs
```

It completes a local process, validates bounded-log metadata, restarts the
finished process as a fresh supervised child, verifies restart lineage, cleans
up both records, and writes `.lemon/proofs/terminal-process-latest.json` without
raw commands, logs, or process ids. The latest local run completed 5 checks with
0 failures and 0 skips.

Browser worker proof has both a deterministic ExUnit test and an opt-in live
local smoke. The smoke starts the supervised local browser driver, drives a
local proof page through the coding-agent browser tool boundary, writes a
screenshot artifact, exercises cookie set/get plus clear-state reset controls,
and records redacted proof JSON:

```bash
mix test apps/coding_agent/test/coding_agent/tools/browser_test.exs --seed 1
```

The focused browser tool lane covers metadata-only screenshot artifacts,
`includeImage` model-visible screenshot content, and `sendToChannel` final
Telegram/Discord attachment metadata. It also covers cookie inspection, cookie
seeding, clear-state reset controls, and channel-safe progress update redaction
for URL, selector, and failure paths. It passed locally on 2026-05-17 with
`16 tests, 0 failures`.

```bash
MIX_ENV=test mix run scripts/live_browser_smoke.exs
```

The latest smoke passed locally on 2026-05-17 with `completed_count: 20`,
`failed_count: 0`, local-document route classification, selector waiting, page
evaluation, hover, select-option, upload-file, download, metadata endpoint
blocking, public-route guard rejection, model-visible screenshot, local
browser-to-media vision, browser analyze, cookie set/get redaction, clear-state
reset, attach-only CDP endpoint mode, and 40 redacted browser progress updates
across 20 started and 20 completed phases in the proof JSON. `proofs.status`,
support bundles and `mix lemon.doctor --verbose` consume the same
`.lemon/proofs/browser-smoke-latest.json` artifact through `browser.preview`;
the final readiness audit validates it by default or
`LEMON_BROWSER_PROOF_JSON` when release evidence lives elsewhere.

Use `--executable /path/to/chrome` or `LEMON_BROWSER_EXECUTABLE=/path/to/chrome`
when Chrome/Chromium is not on `PATH`.

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
uv run scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-generated-media-delivery \
  --generated-media-topic-id 35 \
  --timeout 180 \
  --result-path tmp/telegram-generated-media-proof.json
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-generated-audio-delivery \
  --generated-audio-topic-id 35 \
  --timeout 120 \
  --result-path tmp/telegram-generated-audio-proof.json \
  --proof-path .lemon/proofs/telegram-generated-audio-latest.json
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-media-directive-delivery \
  --media-directive-topic-id 35 \
  --timeout 120 \
  --result-path tmp/telegram-media-directive-proof.json \
  --proof-path .lemon/proofs/telegram-media-directive-latest.json
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-kanban \
  --kanban-topic-id 35 \
  --timeout 120
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-checkpoint \
  --checkpoint-topic-id 35 \
  --timeout 120 \
  --result-path tmp/telegram-checkpoint-proof.json
scripts/live_discord_matrix.py --bot-token-index 0 \
  --check-kanban-slash-registration \
  --result-path tmp/discord-kanban-slash-proof-check.json
scripts/live_discord_matrix.py --bot-token-index 0 \
  --check-checkpoint-slash-registration \
  --result-path tmp/discord-checkpoint-slash-proof-check.json
scripts/live_discord_matrix.py --bot-token-index 0 \
  --check-media-slash-registration \
  --result-path tmp/discord-media-slash-proof-check.json \
  --proof-path .lemon/proofs/discord-media-slash-registration-latest.json
scripts/live_discord_matrix.py --bot-token-index 0 \
  --check-all-slash-registration \
  --result-path tmp/discord-all-slash-proof-check.json \
  --proof-path .lemon/proofs/discord-all-slash-registration-latest.json
scripts/live_discord_matrix.py \
  --check-slash-client-click-proof \
  --result-path tmp/discord-slash-client-click-proof-check.json
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index 1 \
  --wait-generated-audio-delivery \
  --reset-session-between-checks \
  --timeout 120 \
  --result-path tmp/discord-generated-audio-proof.json \
  --proof-path .lemon/proofs/discord-generated-audio-latest.json
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index 1 \
  --wait-media-directive-delivery \
  --reset-session-between-checks \
  --timeout 120 \
  --result-path tmp/discord-media-directive-proof.json \
  --proof-path .lemon/proofs/discord-media-directive-latest.json
```

The generated-media probes ask the live Lemon agent to call
`media_generate_image` with `provider local_svg` and `sendToChannel: true`, then
verify that the normal channel attachment path delivers the generated SVG. They
require the channel file settings to opt into generated files with
`auto_send_generated_files = true` or the legacy `auto_send_generated_images`
alias, plus count and size limits.

The generated-audio probes ask the live Lemon agent to call
`media_generate_speech` with `provider local_wav` and `sendToChannel: true`,
then verify that the normal channel attachment path delivers the generated WAV.
Their sanitized proof artifacts include `contains_generated_audio` coverage and
only redacted channel delivery metadata.

The media-directive probes ask the live Lemon agent to create a project-local
text file and finish with a final-answer `MEDIA:<path>` line instead of using a
send-file tool or `sendToChannel`. The proof requires the marker reply, a real
attachment whose filename contains the proof nonce, and no leaked `MEDIA:` line
in the channel-facing text. Sanitized proof artifacts include
`contains_media_directive` coverage, marker status, attachment count/document
status, directive-leak status, and hashed channel/topic identifiers only. Those
sanitized fields are consumed by doctor, support bundles, and `proofs.status`
so operators can distinguish missing proof, missing attachment, and leaked
directive cases without raw paths or message bodies.

The Telegram and Discord MEDIA directive proofs passed on 2026-05-17 against a
fresh main-checkout runtime. Telegram topic `35` wrote
`.lemon/proofs/telegram-media-directive-latest.json` with
`telegram_forum_topic_media_directive_delivery`, `marker_seen: true`,
`telegram_has_document: true`, and `directive_leaked: false`. Discord channel
`1475727417372049419` wrote
`.lemon/proofs/discord-media-directive-latest.json` with
`discord_media_directive_delivery`, `marker_seen: true`, `attachment_count: 1`,
and `directive_leaked: false`.

The Telegram generated-media proof passed on 2026-05-16 in topic `35`: the
agent called `media_generate_image`, replied with the requested marker, and
delivered the generated SVG as a Telegram document. Use
`LEMON_GATEWAY_HEALTH_PORT=0 LEMON_ROUTER_HEALTH_PORT=0` when running a
temporary local runtime beside another Lemon checkout so gateway/router health
ports do not collide.

The Telegram generated-audio proof passed on 2026-05-17 in topic `35`: the
agent called `media_generate_speech`, replied with the requested marker, and
delivered the generated WAV as a Telegram document. The sanitized proof at
`.lemon/proofs/telegram-generated-audio-latest.json` records
`contains_generated_audio: true`, `telegram_has_document: true`, and
`marker_seen: true`.

The Discord generated-media proof passed on 2026-05-16 in channel
`1475727417372049419`: the live agent called `media_generate_image`, replied
with the requested marker, and delivered the generated SVG as a Discord
attachment. That proof depends on `[gateway.discord.files]` preserving
`auto_send_generated_files = true` through core config normalization and gateway
parsing.

The Discord generated-audio proof passed on 2026-05-17 in channel
`1475727417372049419`: the live agent called `media_generate_speech`, replied
with the requested marker, and delivered one generated WAV attachment. The
renderer regression guard covers the edit path so generated attachments are not
lost when Discord final text updates an existing presentation message.

Use `--register-kanban-slash-command` when the live Discord API check shows the
current bot is missing the in-repo `/kanban` schema. That path loads
`LemonChannels.Adapters.Discord.Transport.kanban_command_schema/0`, upserts it
through Discord's application-command API, then reads it back. On 2026-05-15 it
passed for Zeebot with command id `1505003302893522954`, version
`1505003302893522955`, all expected `/kanban` subcommands, and no missing
options.

Use `--register-checkpoint-slash-command` when the live Discord API check shows
the current bot is missing the in-repo `/checkpoint` schema. That path loads
`LemonChannels.Adapters.Discord.Transport.checkpoint_command_schema/0`, upserts
it through Discord's application-command API, then reads it back. On 2026-05-15
it passed again for Zeebot with command id `1505032304920367356`, version
`1505053780025147463`, status/events/diff/restore subcommands, and the required
boolean `confirm` option on restore.

Use `--register-media-slash-command` when the live Discord API check shows the
current bot is missing the in-repo `/media` schema. That path loads
`LemonChannels.Adapters.Discord.Transport.media_command_schema/0`, upserts it
through Discord's application-command API, then reads it back. On 2026-05-16 the
read-only `--check-media-slash-registration` proof passed for Zeebot with
command id `1505282212147232769`, version `1505282212147232770`, and the
expected `status` subcommand.

Use `--register-rollback-slash-command` when the live Discord API check shows
the current bot is missing the in-repo `/rollback` alias. That path loads
`LemonChannels.Adapters.Discord.Transport.rollback_command_schema/0`, upserts it
through Discord's application-command API, then reads it back with the same
status/events/diff/restore validation as `/checkpoint`. Use the read-only
`--check-rollback-slash-registration` path when registration should be verified
without mutating Discord state.

Use `--check-all-slash-registration` for the broad read-only Discord
application-command inventory. That proof loads command names from
`LemonChannels.Adapters.Discord.Transport.slash_commands/0`, reads Discord's
registered global commands, and fails if any expected Lemon command is missing.
On 2026-05-16 it passed for Zeebot with the historical 15-command snapshot
registered; the current in-repo inventory now includes the `/rollback` alias and
expects 16 command names. This is registration evidence only. Pair it with
`scripts/live_discord_slash_interaction_proof.exs` for deterministic local
decoder/response breadth; broad slash parity still needs a real Discord
client-click proof. Use `--wait-slash-client-click-proof` while an operator
clicks a real slash command so the watcher accepts only a fresh runtime
client-click artifact. Use `--check-slash-client-click-proof` only to validate
an already captured redacted proof artifact.
Slash registration checks also honor `--proof-path`; use that path for redacted
support/status artifacts and keep `--result-path` for command ids, versions, and
other operator handoff details.

The Telegram checkpoint proof creates a local temporary filesystem checkpoint
through `LemonCore.Checkpoint`, mutates the file, sends `/checkpoint diff` and
`/checkpoint restore <id> confirm` into the topic, then verifies the file was
restored and the chat output did not leak raw paths, file contents, or session
ids. On 2026-05-15 it passed in topic `35` and wrote
`tmp/telegram-checkpoint-proof.json`.

The live gateway restart/reconnect replay check is separate from the
deterministic transport-restart dedupe proof above: seed a handled topic
message through Discord, restart the runtime, then verify that the old message
is not replayed by Discord and a fresh topic prompt still works.
Use the Discord matrix two-phase runner:

```bash
scripts/live_discord_matrix.py --bot-token-index 0 \
  --restart-seed \
  --sender-bot-token-index 1 \
  --reset-session-between-checks \
  --channel-id 1475727417372049419 \
  --result-path tmp/discord-restart-seed-proof.json \
  --proof-path .lemon/proofs/discord-restart-seed-latest.json \
  --timeout 120

# restart ./bin/lemon or the packaged runtime, then pass the seed nonce/reply id
scripts/live_discord_matrix.py --bot-token-index 0 \
  --restart-verify \
  --restart-runtime-confirmed \
  --restart-nonce lemon-discord-restart-seed-1779001453 \
  --restart-reply-id 1505466024554659890 \
  --sender-bot-token-index 1 \
  --reset-session-between-checks \
  --channel-id 1475727417372049419 \
  --result-path tmp/discord-restart-verify-proof.json \
  --proof-path .lemon/proofs/discord-restart-verify-latest.json \
  --timeout 120
```

On 2026-05-17 the seed phase and post-restart verify phase passed. The verify
artifact recorded `duplicates: []` over a 30 second duplicate window and a
completed fresh post-restart prompt. The sanitized proof artifacts are
`.lemon/proofs/discord-restart-seed-latest.json` and
`.lemon/proofs/discord-restart-verify-latest.json`.

Discord proof uses `~/.zeebot/api_keys/discord.txt` or `DISCORD_BOT_TOKEN`,
guild `1475727416549969980`, and channel `1475727417372049419`:

```bash
scripts/live_discord_matrix.py --list-channels
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-api-smoke
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index -1 \
  --wait-generated-media-delivery \
  --reset-session-between-checks \
  --timeout 180 \
  --result-path tmp/discord-generated-media-proof.json
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index 1 \
  --wait-thread-inbound \
  --per-check-thread \
  --reset-session-between-checks \
  --timeout 180 \
  --result-path tmp/discord-thread-inbound-proof.json
scripts/live_discord_matrix.py \
  --bot-token-index 0 \
  --sender-bot-token-index -1 \
  --wait-dm-inbound \
  --dm-recipient-id 1476753643834183690 \
  --reset-session-between-checks \
  --timeout 60 \
  --result-path tmp/discord-dm-proof.json
scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index -1 \
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
Use `--wait-thread-inbound --per-check-thread` for the focused thread proof; the
script creates a temporary public thread, resets that thread-scoped session, and
requires the responder to reply inside the thread.
On 2026-05-16 it passed in Lemonade Stand `general`
`1475727417372049419`, creating thread `1505317536286376089` and writing
`tmp/discord-thread-inbound-proof.json`.
Use `--wait-dm-inbound` with either `--dm-channel-id` for a known direct-message
channel or `--dm-recipient-id` to ask Discord to create the DM channel before
the check. The harness writes a redacted failed proof JSON when Discord refuses
DM setup, which is expected for bot-to-bot or closed-DM attempts. The failure
proof includes a safe `failure_hint`, redacted `local_channel_diagnostics`, and
support-bundle classification as `discord_dm_setup_refused` for Discord API
code `50007`. On 2026-05-16 the available second-bot setup failed at Discord's
API boundary with code `50007` (`Cannot send messages to this user`) and wrote
`tmp/discord-dm-proof.json`; that does not promote Discord DM support, but it
does prove the operator-facing DM proof path and session-reset key shape.

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
