# Lemon ↔ Hermes Feature Parity Matrix

Status: active audit ledger

Last reviewed: 2026-05-18

## Purpose

This document is the source-grounded feature matrix for the Lemon goal:

> Hermes, but better, on the BEAM.

It compares Lemon against the refreshed upstream Hermes baseline at
`/home/z80/dev/hermes-agent` `origin/main` and classifies launch-relevant gaps
by what a user can actually experience. It is stricter than the harness
scorecard. The scorecard proves many agent-loop contracts; this matrix decides
whether Lemon can credibly match Hermes as a product and daily-use agent system.

The product decision for this goal is now explicit:

- Telegram and Discord are the only messaging platforms that must be promoted
  for the near-term Hermes-parity launch.
- Other messaging platforms can remain preview until they meet the same proof
  standard.
- Browser, media, terminal backends, checkpoint rollback, API/editor
  integration, plugins, goals, kanban, LSP, cron, provider routing, and
  observability are not optional extras. They are parity workstreams.
- Lemon should not copy Hermes internals. Each parity workstream should land as
  supervised BEAM-native runtime capability with telemetry, durable state,
  support-bundle visibility, policy gates, and deterministic/live proof.

## Source Snapshot

Hermes source evidence used for this pass:

- `/home/z80/dev/hermes-agent` `origin/main` at `94c523f0c`
- `README.md`
- `AGENTS.md`
- `website/docs/user-guide/features/overview.md`
- `website/docs/user-guide/features/tools.md`
- `website/docs/user-guide/features/browser.md`
- `website/docs/user-guide/features/voice-mode.md`
- `website/docs/user-guide/features/tts.md`
- `website/docs/user-guide/features/vision.md`
- `website/docs/user-guide/features/image-generation.md`
- `website/docs/user-guide/features/web-search.md`
- `website/docs/user-guide/features/x-search.md`
- `website/docs/user-guide/features/memory.md`
- `website/docs/user-guide/features/memory-providers.md`
- `website/docs/user-guide/features/skills.md`
- `website/docs/user-guide/features/mcp.md`
- `website/docs/user-guide/features/cron.md`
- `website/docs/user-guide/features/goals.md`
- `website/docs/user-guide/features/kanban.md`
- `website/docs/user-guide/features/lsp.md`
- `website/docs/user-guide/features/plugins.md`
- `website/docs/user-guide/features/provider-routing.md`
- `website/docs/user-guide/features/fallback-providers.md`
- `website/docs/user-guide/features/credential-pools.md`
- `website/docs/user-guide/features/api-server.md`
- `website/docs/user-guide/features/acp.md`
- `website/docs/user-guide/features/codex-app-server-runtime.md`
- `website/docs/user-guide/checkpoints-and-rollback.md`
- `website/docs/user-guide/messaging/telegram.md`
- `website/docs/user-guide/messaging/discord.md`
- `gateway/platforms/telegram.py`
- `gateway/platforms/discord.py`
- `hermes_cli/security_advisories.py`
- `website/docs/guides/pipe-script-output.md`
- `website/docs/guides/oauth-over-ssh.md`
- `website/docs/developer-guide/programmatic-integration.md`
- `website/docs/getting-started/updating.md`
- `.github/workflows/history-check.yml`
- `.github/workflows/osv-scanner.yml`
- `.github/workflows/python-cli.yml`
- `.github/workflows/upload_to_pypi.yml`

Lemon source evidence used for this pass:

- `docs/plans/lemon-1.0-mainstream-readiness.md`
- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`
- `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md`
- `docs/plans/lemon-1.0-interface-supportability-audit-2026-05-11.md`
- `docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md`
- `apps/coding_agent/lib/coding_agent/tools.ex`
- `apps/agent_core/`
- `apps/lemon_automation/`
- `apps/lemon_channels/`
- `apps/lemon_control_plane/`
- `apps/lemon_core/`
- `apps/lemon_mcp/`
- `apps/lemon_sim/`
- `apps/lemon_skills/`
- `clients/lemon-browser-node/`
- `docs/testing.md`
- `docs/skills.md`
- `docs/user-guide/skills.md`
- `docs/user-guide/memory.md`
- `docs/support.md`
- `.github/workflows/history-check.yml`
- `.github/workflows/osv-scanner.yml`
- `bin/lemon`
- `apps/lemon_channels/lib/lemon_channels/script_send.ex`
- `apps/lemon_channels/lib/mix/tasks/lemon.send.ex`
- `apps/lemon_channels/lib/lemon_channels/telegram/known_target_store.ex`
- `apps/lemon_channels/lib/lemon_channels/discord/known_target_store.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/discord/transport.ex`

## Status Legend

- `Green`: Lemon has comparable user-visible capability and proof.
- `Partial`: Lemon has meaningful implementation, but proof or user-visible
  breadth is weaker than Hermes.
- `Open`: Lemon lacks a comparable stable feature or proof.
- `BEAM parity target`: Lemon lacks the full Hermes-visible surface today, but
  the capability is in scope for this goal and should be implemented through
  supervised BEAM-native runtime boundaries.

## P0 Product Blockers

These block the broad "Hermes but better, on BEAM" claim until implemented and
proven. They do not necessarily block a narrower release candidate if public
claims stay bounded.

1. **Browser automation:** Lemon must expose first-class browser tools with
   session lifecycle, artifacts, screenshots, policy gates, `/ops` visibility,
   and channel-safe progress.
2. **Media and multimodal tools:** Lemon now has BEAM-preview supervised image
   generation, image analysis, TTS, STT, and video tools plus live-proven
   Telegram and Discord generated-SVG and generated-audio delivery through the
   normal attachment path; successful live provider proof for every media
   provider path and voice mode remain open before broad parity claims.
3. **Checkpoint and rollback:** Lemon must snapshot risky file/shell work,
   expose diff preview and restore, and make checkpoint events visible in Web,
   TUI, Telegram, Discord, and support bundles.
4. **Telegram and Discord broad parity:** Lemon already has text/file proof,
   deterministic Discord approval/control/safe-mention proof, public-thread
   proof, generated-SVG and generated-audio delivery proof, free-response trigger-mode proof,
   external-bot author policy proof, and duplicate `MESSAGE_CREATE` suppression
   proof; it still needs richer media, Discord DM workflows, real-client
   slash/component click proof and voice for
   promoted surfaces.
5. **External API/editor parity:** Lemon needs OpenAI-compatible
   Chat Completions/Responses surfaces and ACP/editor adapters over the existing
   run graph and control plane.
6. **Terminal backend parity:** Lemon has local PTY plus optional Docker and SSH
   previews now; it still needs live remote proof, host/image policy, richer
   logs, approval controls, and resource controls before stable parity.
7. **Durable long-running work:** Lemon needs Hermes-style `/goal` and durable
   kanban/fleet coordination primitives, implemented with BEAM processes,
   persistent state, and human/operator controls.
8. **Plugin/provider ecosystem:** Lemon needs audited plugin/capability hosts,
   external memory-provider semantics, provider routing, fallback providers,
   and credential-pool behavior that can degrade safely.
9. **LSP semantic edit feedback:** Lemon has preview post-edit LSP diagnostics
   with six-server real-repo proof; broader editor integration and operational
   promotion criteria remain before stable Hermes LSP parity.
10. **Observability expansion:** every new parity surface must have `/ops`
    panels, event streams, logs, metrics, and support-bundle hooks.

## Guardrails

- Do not market unsupported Hermes drop-in command parity.
- Do not promote a channel feature without direct live proof through real
  Telegram or Discord credentials.
- Do not promote browser/media/plugin/MCP surfaces without untrusted-content
  tests.
- Do not add opaque worker daemons when an OTP-supervised process, GenServer,
  DynamicSupervisor, event log, and control-plane API can make the behavior
  observable.
- Prefer one narrow vertical slice with proof over a broad surface that cannot
  be operated or supported.

## BEAM-Native Implementation Standard

When Lemon closes a Hermes parity gap, the implementation should use:

- one supervised process tree per durable run, browser session, media job,
  terminal backend, cron job, plugin host, kanban worker, and channel adapter
- explicit state machines for run lifecycle, approvals, checkpoints, rollback,
  scheduled jobs, goal continuation, kanban dispatch, and delivery retries
- PubSub/event-stream progress that feeds Web, TUI, Telegram, Discord, support
  bundles, control-plane presence/resource summaries, and eval artifacts from
  the same facts
- durable stores for replayable run history, artifacts, checkpoints, goals,
  kanban tasks, memory, skill usage, plugin health, scheduler state, and
  provider routing decisions
- capability-aware policies, audits, and degraded-startup behavior for plugins,
  MCP tools, media pipelines, and external process backends

## 2026-05-18 Upstream Refresh Notes

The Hermes baseline moved from `4ad5fa702` to `94c523f0c`. New or newly
documented upstream surfaces to track in future Lemon slices include the
single-shape `session_search` rewrite with discovery, browse, and scroll
ergonomics; first-party X/Twitter search through xAI Responses and OAuth/API-key
gating; expanded script-output piping and OAuth-over-SSH guidance; richer
programmatic integration docs; provider fallback ladder documentation; kanban
triage auto-decomposition; PyPI publishing workflow coverage; and a history
check workflow. Lemon already has general web search/fetch, memory search, X
posting/mentions surfaces, provider routing/fallback previews, kanban
dispatcher proof, Hermes-compatible `session_search`, first-party read-only
`x_search`, a PR-only `history-check.yml` common-ancestor guard, a
Telegram/Discord `./bin/lemon send` script notification path with BEAM-store
known-target discovery, exact list-mode aliases, config-backed default targets
and default account ids, account-scoped delivery and known-target resolution, standalone thread/topic
target overrides, reply-to payload routing, unique Telegram/Discord known-name resolution, bounded multi-attachment script artifact uploads through the existing channel file adapters, and credential-free dry-run validation, a
non-publishing Python CLI wheel/sdist check, and release/test lanes, while
actual PyPI publishing remains a future workstream.

## Matrix

| Area | Hermes evidence | Lemon evidence | Status | Launch action |
| --- | --- | --- | --- | --- |
| Install and setup | README advertises one-line Linux/macOS/WSL2/Termux install, native Windows beta, `hermes setup`, `hermes model`, `hermes gateway setup`, `hermes doctor`, and `hermes update`. | Lemon has source setup through `./bin/lemon setup` / `mix lemon.setup`, config validation through `./bin/lemon config` / `mix lemon.config`, diagnostics through `./bin/lemon doctor` / `mix lemon.doctor`, promoted Telegram/Discord readiness through `./bin/lemon channels` / `mix lemon.channels`, compact launch readiness through `./bin/lemon readiness` / `mix lemon.readiness`, proof inventory through `./bin/lemon proofs` / `mix lemon.proofs`, `mix lemon.update` as a stage-1 local maintenance task, `./bin/lemon update` as the source wrapper for that task, local release proofs, Linux `x86_64` tarball scope in readiness/support docs, and `scripts/verify_source_install` for a repeatable source-install proof covering toolchain checks, source-wrapper help discoverability for setup/channels/config/doctor/send/media/models/providers/policy/proofs/readiness/secrets/skill/usage/update, locked dependency resolution, warning-free compile, source-wrapper non-interactive setup dispatch, source-wrapper channel readiness, source-wrapper config validation, source-wrapper media/model/provider/policy/proofs/readiness/secrets/skill/usage inspection, source-wrapper stage-1 update dry-run dispatch, source-wrapper doctor JSON, and support-bundle generation with `readiness_summary.json`. | Partial | P1. Keep source/Linux scope honest until a one-line installer or remote binary updater has equivalent artifact verification, rollback, and support-bundle proof. |
| Provider/model switching | Hermes supports many hosted/custom providers, `/model`, provider routing, fallback providers, credential pools, and profile distributions. | Lemon supports multiple engines/providers through `apps/ai`, config/secrets, gateway engines, live-eval env knobs, redacted provider readiness, route previews, credential-pool shape, doctor routing checks, control-plane `providers.status` live fallback proof visibility, redacted `secrets.status` store health/fallback visibility, no-value summaries for `secrets.list`, `secrets.set`, `secrets.delete`, and `secrets.exists`, control-plane `models.list` provider/capability summaries without credential values, source-wrapper `./bin/lemon models` catalog discovery, source-wrapper `./bin/lemon providers` readiness checks from the same BEAM `ProviderStatus` snapshot, source-wrapper `./bin/lemon policy` route-specific model/thinking policies, allowlisted source-wrapper `./bin/lemon secrets` secret-store tasks, and Web `/ops` live fallback proof visibility. Provider-backed live eval passed against Z.ai `glm-5-turbo` on 2026-05-12, and `scripts/live_provider_fallback_smoke.exs` passed with an intentionally invalid OpenAI primary and Z.ai fallback on 2026-05-16. | BEAM live-fallback proof plus source-wrapper model/provider/policy/secrets proof | P1. Add OAuth/custom endpoint variants and keep the fallback proof green. |
| CLI/TUI | Hermes TUI has multiline editing, autocomplete, history, interrupt/redirect, streaming tool output, session picker, approvals, and slash dispatch. | Lemon TUI proof covers source-runtime echo, rendered tool failure, stats, overlays, and cancellation. | Partial | P1. Keep TUI proof green and decide which Hermes slash commands need Lemon equivalents. |
| Web dashboard | Hermes dashboard includes sessions, tools, plugins, profiles, models, kanban, and runtime status surfaces. | Lemon Web and `/ops` show health, run detail, approvals, cron, skills, memory, browser status with driver session timestamps, safe capability labels, operator guidance, hashed driver process ids, and artifact cleanup metadata, checkpoint status with copy-ready rollback command guidance and direct diff/restore controls, redacted goal status, redacted kanban board/task status, redacted media job metadata/artifact summaries, redacted proof-artifact pass/fail summaries, safe proof reason/scope/check coverage and latest redacted proof-check status backed by read-only `proofs.status`, redacted `proofs.status` launch-gate summaries for Discord DM, Discord client-click, provider media, and terminal backends, compact launch-readiness summaries through `readiness.status`, safe proof coverage counts for deterministic Discord slash promotion evidence, channel failure drilldown for Telegram voice transcription plus Discord DM/free-response/reconnect/slash-client promotion gates, redacted channel diagnostics and channel proof status through `channels.status`, redacted provider readiness and route preview, redacted live provider fallback proof status, redacted usage/cost/quota aggregate visibility, redacted cron diagnostics through support bundles, `health` public runtime summaries, root `status` BEAM VM capacity counters and cleanup summaries, `system-presence` resource summaries, `config.reload` lifecycle summaries, `system.reload` lifecycle summaries, `node.list` inventory summaries, `node.describe` redacted metadata summaries, `node.pair.list` pending-pairing summaries, `node.pair.request` pairing-code delivery summaries, `node.pair.approve` token/challenge delivery summaries, `node.pair.reject` cleanup summaries, `node.pair.verify` status cleanup summaries, `connect.challenge` session-token delivery summaries, `device.pair.request` pairing-code delivery summaries, `device.pair.approve` token/challenge delivery summaries, `device.pair.reject` cleanup summaries, `exec.approvals.get` pending-action redaction summaries, `exec.approval.request` action cleanup summaries, `exec.approval.resolve` decision cleanup summaries, `exec.approvals.set` policy-write summaries, `exec.approvals.node.set` node-policy-write summaries, `last-heartbeat` response redaction summaries, `set-heartbeats` prompt-cleanup summaries, `node.invoke` response cleanup summaries, `node.event` acknowledgement summaries, `node.rename` response cleanup summaries, terminal backend status, redacted LSP diagnostics checker status plus supervised language-server registry/session state and recent LSP proof artifacts/check summaries, redacted extension/plugin manifest plus host-runtime diagnostics, redacted extension-host telemetry proof status/hash/counts, WASM wrapper telemetry/policy/lifecycle proof artifacts, redacted extension registry install/update audit proof status, agent directory/target summaries through `agent.directory.list`, `agents.list`, and `agent.targets.list`, core submission and wait summaries through `agent` and `agent.wait`, identity capability summaries through `agent.identity.get`, progress polling summaries through `agent.progress`, file operation summaries through `agents.files.list`, `agents.files.get`, and `agents.files.set`, prompt-cleanup summaries for `agent.inbox.send`, and route cleanup summaries for `agent.endpoints.list`, `agent.endpoints.set`, and `agent.endpoints.delete`, support bundle, and source-runtime proofs. The BEAM extension-host smoke proof now verifies explicit extension tool execution, redacted extension tool telemetry, config/env disabled-mode explicit-path blocking, and conflict precedence. The WASM telemetry/policy/lifecycle smokes verify redacted wrapper events, risky-capability approval defaults, and sidecar discover/invoke/stop lifecycle, and the registry audit smoke verifies code-free install/update metadata review, but `/ops` still treats plugin execution health as preview diagnostics rather than a stable marketplace/sandbox panel. | Partial | P1. Add live media delivery results, cron scheduler-lock/retry visibility, stable editor promotion views, and sandbox execution health. |
| OpenAI-compatible API | Hermes exposes Chat Completions, Responses, streaming, tool progress, image input, named conversations, stored response chains, models, capabilities, health, and runs APIs. | Lemon now has a preview `/v1` HTTP adapter over the existing BEAM control plane: `GET /v1/health`, `GET /v1/capabilities`, `GET /v1/models`, `GET /v1/models/:model_id`, `POST /v1/chat/completions`, `POST /v1/responses`, `GET /v1/responses/:response_id`, `GET /v1/runs/:run_id`, and `POST /v1/runs/:run_id/cancel`. The model endpoints expose Lemon capability metadata including `supportsVision`. The generation endpoints normalize OpenAI-style chat/messages or Responses input, including redacted URL/file-id image metadata, data URL image pass-through, and opt-in allowlisted HTTPS image URL fetch, submit Lemon runs through the router/run graph, return queued metadata by default, support `wait: true` / `timeout_ms` to synchronously wait through the existing `agent.wait` path and map completed answers into Chat Completions or Responses output text, and support `stream: true` by returning `text/event-stream` chunks from Lemon run bus `:delta`, `:engine_action`, and `:run_completed` events. Chat streams emit redacted `lemon.tool_progress` events, Responses streams emit redacted `response.tool_progress` events, and both omit raw tool args/results. Stored Responses use `resp_<run_id>` ids over the Lemon run store, and `previous_response_id` defaults follow-up runs to the prior Lemon session key. HTTP(S) image URLs and file ids are hashed/redacted into request metadata and bounded prompt placeholders by default; when `LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` and the HTTPS host is allowlisted, URL images are fetched, MIME/size-checked, redacted, and passed as runtime-only image blocks; base64 data URL images are validated, size/count-limited, redacted from prompts and metadata, and threaded as runtime-only image blocks through `RunRequest`, the router, gateway, `LemonRunner`, and `CodingAgent.Session.prompt/3`; known provider-prefixed text-only models reject runtime image bytes before run submission. The run endpoints expose redacted status and cancellation dispatch through `LemonRouter.abort_run/2` without raw events or answer text in status responses. The `/v1` surface supports opt-in token auth through application config or `LEMON_OPENAI_COMPAT_API_TOKEN` / `LEMON_OPENAI_COMPAT_TOKEN`, accepting either bearer auth or `x-api-key`. Focused HTTP tests cover model/capability shape, `supportsVision` metadata, chat/responses submission, synchronous wait completion, wait timeout handling, Chat Completions SSE, Responses SSE, redacted tool-progress SSE events, stored response retrieval, previous-response continuation metadata, redacted image-input metadata normalization without raw URL/data-byte leakage, data URL image pass-through into runtime-only Lemon image blocks, opt-in allowlisted HTTPS image URL fetch into runtime-only Lemon image blocks, disallowed remote image host rejection, known non-vision model rejection before runtime-image submission, redacted run status, unknown-run errors, stored-response not-found errors, cancellation dispatch, optional bearer auth, optional `x-api-key` auth, metadata-derived session keys, streaming-request metadata, prompt normalization, and validation errors without starting a real model run. `scripts/live_openai_compat_smoke.exs` starts a local Bandit router, calls `/v1` through `:httpc`, runs `scripts/live_openai_compat_fetch_client.mjs` as an external Node `fetch` client, official OpenAI Node SDK client, and official OpenAI Python SDK client, writes redacted proof JSON, includes top-level `non_vision_image_rejection` coverage for sanitized rejection without submitting a run, and passed on 2026-05-17 with `completed_count: 14`, `failed_count: 0`; all three external clients verify single-model retrieval plus `supportsVision` list/retrieve consistency, the external Node `fetch` sub-proof covers raw Chat Completions and Responses SSE, and the Node and Python SDK sub-proofs each complete synchronous Chat Completions, SDK Chat Completions and Responses streaming, Responses continuation, and stored Response retrieval with 6 checks and 0 failures. `proofs.status` and `mix lemon.doctor --verbose` now expose these redacted result rows as `openai_compat_*` checks and `openai_compat.api_preview`, which passes only when all fourteen local smoke rows are complete. `proofs.status` and `mix lemon.doctor --verbose` now also expose the deterministic ACP stdio smoke, external Node stdio client proof, and official ACP SDK client proof as `acp_stdio_*`, `acp_stdio_external_*`, and `acp_official_sdk_*` checks plus `acp.preview`, which passes only when all three ACP proof artifacts are complete. `scripts/live_openai_compat_vision_smoke.exs` is an opt-in provider-backed vision proof harness over the unstubbed `/v1/responses` path; it passed on 2026-05-16 through OpenRouter `openai/gpt-4o-mini` with `completed_count: 1`, `failed_count: 0`, and redacted proof JSON. Its credential preflight uses `AgentCore.ModelRuntime.Credentials.provider_has_credentials?/3`, so env keys, encrypted secrets, OAuth/default-secret paths, and provider-specific credential shapes match runtime behavior. Direct OpenAI was blocked by account quota in this environment, and Z.ai's coding endpoint accepted text credentials but rejected image input. | BEAM preview with live vision proof, non-vision guard, and Node/Python SDK streaming proof | P0/P1. Add deployed editor UI proof and keep provider-specific vision proof green. |
| ACP/editor integration | Hermes supports ACP-compatible editors such as VS Code, Zed, and JetBrains. | Lemon now has a preview `POST /acp` JSON-RPC bridge over the existing control-plane/router path. It supports `initialize`, `session/new`, official `session/load`, `session/resume`, `session/list`, `session/prompt`, `session/cancel`, and `session/close`; maps text and resource-link prompt blocks into router-submitted Lemon runs; waits through `agent.wait` by default; supports queued submission with `_meta.lemon.wait: false`; cancels through `LemonRouter.abort_run/2`; can require bearer or `x-api-key` auth through `LEMON_ACP_API_TOKEN`; and captures only safe filesystem capability booleans from ACP `clientCapabilities.fs.readTextFile`, `writeTextFile`, `deleteFile`, and `renameFile`, carrying them into sessions, `session/list`, prompt responses, and Lemon run metadata. When those safe booleans are present, `CodingAgent.Tools.ACPFileBridge` routes model-facing `read`, `write`, `edit`, and `patch` add/update/delete/move operations through correlated ACP `fs/read_text_file`, `fs/write_text_file`, `fs/delete_file`, and `fs/rename_file` requests. `scripts/lemon_acp_stdio.exs` exposes the same handler over ACP's newline-delimited JSON stream shape for spawned stdio clients, emits `session/update` notifications for Lemon text deltas and redacted tool progress while prompt waits are active, round-trips agent-to-client request lines for `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `fs/delete_file`, and `fs/rename_file`, and bridges matching `LemonCore.ExecApprovals.request/1` events for the ACP session key into ACP permission requests. `scripts/live_acp_stdio_external_client.mjs` now spawns that stdio bridge as a child process, sends newline-delimited JSON from a separate Node client, proves client filesystem capability negotiation across `initialize` and `session/new`, observes updates, answers the ACP permission/read/write/delete/rename requests, proves the approval-bus bridge, and writes redacted proof with `completed_count: 9`, `failed_count: 0`, `update_count: 2`, and `client_request_count: 6` at `2026-05-17T11:12:43.029Z`. `scripts/live_acp_official_sdk_client.mjs` installs official `@zed-industries/agent-client-protocol@0.4.5` under ignored `tmp/`, drives the stdio bridge through `ClientSideConnection`, and proves initialize, session new/load/cancel, queued and waited prompts, session updates, spec-compatible permission/read/write callbacks, unsupported-image rejection, and redacted proof output with `completed_count: 8`, `failed_count: 0`, `update_count: 2`, and `client_request_count: 4` at `2026-05-17T11:12:42.429Z`. Lemon advertises only the capabilities it currently supports and leaves image, audio, embedded-resource, MCP HTTP, and MCP SSE prompt capabilities disabled. Focused tests cover capability negotiation, safe client filesystem capability capture on sessions and prompt metadata, session creation, prompt submission, queued prompt behavior, unsupported media rejection, list/resume/cancel/close, HTTP auth, NDJSON stdio parsing, store-backed session recovery after ETS cache loss, `session/update` projection from run bus events, redacted client-request summaries for ACP permission/read/write/delete/rename responses, approval-bus resolution through ACP `session/request_permission`, official `session/load`, and the focused coding-agent ACP file bridge lane with `6 tests, 0 failures` for read/write/edit/patch add-update-delete-move routing. | Partial / BEAM preview with official SDK proof | P1. Add deployed editor UI proof before claiming stable editor parity. |
| Slash commands | Hermes exposes session, config, tool, skill, browser, cron, memory, voice, debug, update, restart, approval, goal, kanban, and dynamic skill commands across CLI/gateway surfaces. | Lemon Telegram/Discord commands are inventoried in the channel matrix. Telegram is stable for the text/document boundary; Discord is live-proven for text/file but broad slash parity is not claimed. Goal, kanban, checkpoint, rollback, and media status commands now map to supported Lemon concepts, with channel media status intentionally limited to redacted job/artifact counts. Discord now has deterministic proof for slash payload decoding, approval buttons, cancel/keepalive controls, safe mention output, duplicate `MESSAGE_CREATE` suppression, and a local slash interaction proof across the 16-command inventory, checkpoint/rollback/kanban/media decoding, all durable kanban subcommand decoders, and safe local responses for session/model/thinking/resume/cancel/media/trigger/cwd/topic/file paths. `scripts/live_discord_matrix.py --check-all-slash-registration` proved the prior 15-command inventory on 2026-05-16; after adding `/rollback`, live registration proof must be rerun against the current `Transport.slash_commands/0` names before broad slash promotion. The runtime now passively records redacted `lemon.discord_slash_client_click` proof artifacts when a real slash-command interaction with live Discord fields receives a safe Lemon response, and `scripts/live_discord_matrix.py --wait-slash-client-click-proof` asks an operator for a fresh real click before validating that artifact. | Partial / live recorder ready | P1. Add only commands that map to supported Lemon concepts; document naming differences and keep Discord client-click proof separate from schema proof, registration proof, deterministic component/inbound proofs, and deterministic local interaction proof until an operator clicks real commands after deploy/hot reload. |
| Tool registry breadth | Hermes covers web, browser, terminal/process, files, memory, session search, skills, cron, delegation, code execution, messaging, image gen, video gen, TTS, vision, Home Assistant, RL, kanban, MCP, and plugin tools. | Lemon has read/write/edit/patch/checkpoint/lsp_diagnostics/search/shell/webfetch/websearch/browser/media_status/media_generate_image/media_generate_speech/media_transcribe_audio/media_analyze_image/media_generate_video/todo/task/agent/parent_question/memory/skill/auth/extension tools plus first-party `x_search`, `post_to_x`, and `get_x_mentions` social tools. The additional `exec`/`process` tools now carry terminal backend metadata through a backend registry. `scripts/live_extension_host_smoke.exs` proves the BEAM extension-host path for explicitly trusted extension tools: default directories stay diagnostics-only, an explicit extension path loads and executes a tool through `CodingAgent.ToolRegistry`, streamed tool updates work, redacted start/stop/exception telemetry is emitted without raw params, paths, or call ids, config/env disabled mode blocks explicit-path BEAM extension execution, and built-ins win namespace conflicts. `scripts/live_mcp_stdio_smoke.exs` proves stdio MCP capability hosting now flows through the BEAM path too: clean stdio client startup, prefixed `mcp_<server>_<tool>` discovery through `LemonSkills.McpSource`, model-facing exposure through `CodingAgent.ToolRegistry`, success and MCP tool-error calls, resource list/read and prompt list/get utilities, exact allow/block filtering, degraded missing-command startup, `notifications/initialized` compatibility, the opt-in `sampling/createMessage` callback wrapper, the reviewed model-backed sampling policy wrapper with redacted summaries, reviewer approval, and token-limit proof, and the configured-source ops approval bridge with `completed_count: 17`, `failed_count: 0`. `scripts/live_mcp_http_smoke.exs` proves the matching Streamable HTTP MCP client/source/registry path for initialize, JSON and per-request SSE responses, session/protocol headers, OAuth protected-resource and authorization-server metadata discovery, OAuth client-credentials token acquisition, client_secret_post and client_secret_basic token endpoint auth, protected-request retry, and refresh-token grant retry and one-shot bearer reacquisition after a later 401, authorization-code PKCE callback/token exchange, OAuth token cache resume, configured-source loopback callback capture plus operator approval routing, tool/resource/prompt listing and reading/getting, success and MCP tool-error calls, source resource/prompt utility invocation, prefixed source discovery, model-facing registry exposure, capability status shape, and exact HTTP filtering with `completed_count: 24`, `failed_count: 0`. `scripts/live_mcp_sse_smoke.exs` proves the legacy HTTP+SSE MCP client/source/registry path for endpoint discovery, tool/resource/prompt listing and reading/getting, success and MCP tool-error calls, source resource/prompt utility invocation, prefixed source discovery, model-facing registry exposure, capability status shape, and exact SSE filtering with `completed_count: 14`, `failed_count: 0`. `scripts/live_wasm_telemetry_smoke.exs` proves the WASM tool wrapper emits redacted start/stop/exception telemetry for success, sidecar error, and sidecar-exit paths without raw params, raw paths, raw tool-call ids, sidecar error text, or result payloads. `scripts/live_wasm_policy_smoke.exs` proves WASM risky-capability approval defaults for `http`, `tool_invoke`, and `exec`, plus safe-capability execution and explicit `never` override. `scripts/live_extension_registry_audit_smoke.exs` proves registry install/update metadata can be validated without loading extension code, blocks unaudited installs, detects audited update candidates, and redacts registry paths, package names, distribution URLs, and manifest contents. `scripts/live_wasm_lifecycle_smoke.exs` proves redacted WASM sidecar discover/invoke telemetry, running status, stop termination, and lifecycle redaction. `media_status` gives models redacted job/artifact/worker visibility, and control-plane `media.status` exposes provider-backed media proof lane state with safe reason kinds and rerun commands. `media_generate_image` is a BEAM-supervised local SVG plus provider-backed OpenAI and Vertex Imagen image path, `media_generate_speech` is a BEAM-supervised local WAV plus provider-backed OpenAI, ElevenLabs, and Google TTS path, `media_transcribe_audio` is a BEAM-supervised local transcript plus provider-backed OpenAI STT path, `media_analyze_image` is a BEAM-supervised local image-analysis plus provider-backed OpenAI/OpenAI-compatible vision path, and `media_generate_video` is a BEAM-supervised local MP4 plus provider-backed OpenAI video path. They record redacted `LemonMedia.MediaJobs` metadata and generated attachment metadata through `LemonMedia.MediaJobSupervisor`; Telegram and Discord generated-SVG plus generated-audio delivery are live-proven, and provider-backed media STT and vision now have live proof, while image/TTS/video live provider proof is still not stable. | Partial | P0. Browser, file-checkpoint, kanban, LSP diagnostics, terminal backend metadata, BEAM extension-host execution, stdio MCP ingestion with local callback, reviewed sampling policy, and ops approval bridge wrappers, WASM wrapper telemetry/policy/lifecycle proof, registry audit proof, and media job observability/generation preview have started as supervised surfaces; remaining provider-backed media, full marketplace/sandbox execution, broader external-server compatibility, and non-local terminal backends remain priority breadth gaps. |
| Plugin/extension final audit | Hermes has plugin support and extension documentation; release claims need evidence that Lemon's plugin host proofs are current. | Lemon's final readiness audit now validates extension host, WASM telemetry, WASM policy, extension registry audit, and WASM lifecycle proof artifacts before plugin/extension preview support can be promoted. | Partial / final-audit-gated preview | P1. Add full marketplace/sandbox execution proof before stable plugin claims. |
| Terminal and process backends | Hermes supports local, Docker, SSH, Singularity, Modal, Daytona, Vercel Sandbox, background process management, PTY, sudo, resource controls, and container hardening. | Lemon now has a shared `LemonCore.TerminalBackend` behavior, `TerminalBackends` registry, `TerminalBackendPolicy`, atom-safe backend normalization, local backend metadata for the supervised `ProcessSession` Erlang Port runner, local PTY execution via util-linux `script(1)` when available, optional Docker CLI container execution with cwd mounted at `/workspace`, `--pull never`, no-new-privileges, dropped capabilities, read-only root filesystem by default, bounded `/tmp` tmpfs scratch space, and default CPU/memory/pids/network limits, optional OpenSSH execution in `BatchMode=yes` when `LEMON_SSH_TERMINAL_TARGET` is configured, backend allow/deny policy, optional Docker image allowlist, optional SSH target allowlist with redacted hashes, backend-specific `exec` approval requirements via `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL`, redacted approval actions with backend, command hash, cwd hash, and env keys only, backend-aware `exec` parameters with env payload validation before launch, `process` list/poll backend/capability/log/restart metadata visibility, manual restart of finished processes as fresh supervised children with new process ids and original-record preservation, read-only `terminal.backends.status` control-plane metadata with terminal live-proof state, Docker hardening, backend/policy counts, and cleanup summary, redacted `terminal_diagnostics.json` support-bundle metadata, Web `/ops` terminal backend policy/status visibility, and `scripts/live_terminal_backend_smoke.exs` for redacted live proof of every available backend. Focused core/support/policy tests passed with `15 tests, 0 failures`; the focused coding-agent `exec` lane passed with `22 tests, 0 failures` including Docker hardening assertions when Docker is usable; the process restart/log-metadata lane passed with `124 tests, 0 failures`; the control-plane and Web lanes cover policy/status visibility; the live smoke completed `local`, `local_pty`, `docker`, and loopback `ssh`, skipped zero backends, and failed zero backends. The Docker proof now validates read-only rootfs, no-exec `/tmp`, dropped capabilities, no-new-privileges, no-network default, no implicit pulls, and cgroup-observed CPU/memory/pids policy from inside the launched container. Support bundles and `proofs.status` also infer `terminal_backend` scope from result rows, expose `terminal_backend_*` check status, and whitelist only safe Docker hardening fields. `mix lemon.doctor --verbose` now reports `terminal.backends_live` from those redacted proof rows and warns on failed or missing local, local PTY, Docker, or SSH preview rows. | Partial / BEAM preview | P0/P1. Keep execution inside `ProcessManager`, then add fleet/container backends, restart policy, and advanced sandbox profiles. |
| File editing | Hermes has read/write/patch/search, fuzzy patching, post-write lint, checkpoint hooks, and LSP diagnostics. | Lemon has read/write/edit/hashline_edit/patch/grep/find/ls and strong tool lifecycle tests. `write`, `edit`, and `patch` now create restorable filesystem checkpoints when the tool context has a session id and can opt into post-edit baseline/delta diagnostics through the BEAM-preview `lsp_diagnostics` runner. | Green for basic file tools; Partial / BEAM preview for semantic edit quality | Keep file lifecycle tests green while promoting LSP diagnostics language-by-language and adding broader checkpoint surfaces. |
| Checkpoints and rollback | Hermes supports opt-in filesystem checkpoints before file tools and destructive terminal commands, `/rollback`, per-file restore, diff preview, and checkpoint maintenance. | Lemon now stores filesystem snapshots, filesystem diff/restore, and checkpoint lifecycle events in `LemonCore.Checkpoint`; `CodingAgent.Checkpoint` only adds coding-agent todo/requirement resume state. Lemon automatically checkpoints `write`/`edit`/`patch` with a session id, exposes the `checkpoint` tool for list, diff preview, per-file/full restore, and delete, emits checkpoint create/restore/delete events into introspection plus run/session event streams, snapshots configured `checkpoint_paths` before risky `exec` shell commands such as `rm`, `mv`, `sed -i`, `find ... -delete`, `git reset`, or `git clean`, exposes control-plane `checkpoint.diff` / `checkpoint.restore` methods backed by core for shared operator rollback flows, with path/diff/restore cleanup summaries that distinguish returned raw paths and diff text from excluded raw session ids, credentials, secret values, and restored file contents, and exposes control-plane `checkpoint.status` redacted lifecycle event counts and recent event summaries filtered by run/session/agent without raw paths, file contents, raw payloads, or raw session ids. Lemon provides TUI `/checkpoint diff` / `/checkpoint restore` controls, shows copy-ready TUI/control-plane rollback commands plus direct diff/restore controls in Web `/ops`, and exposes Telegram/Discord `/checkpoint` plus Hermes-style `/rollback` redacted status with lifecycle event counts, browsable event history, pushed active-run notices, and diff/restore controls with explicit restore confirmation. | Partial / BEAM preview | P0. Add Discord client-click restore proof before claiming stable slash-command parity. |
| LSP semantic diagnostics | Hermes runs pyright, gopls, rust-analyzer, typescript-language-server, clangd, ElixirLS, and more after writes, surfacing only newly introduced diagnostics. | Lemon now has a model-facing `lsp_diagnostics` tool and opt-in `diagnostics` flags on `write`, `edit`, and `patch`. The preview runner detects language by extension, performs deterministic Elixir syntax diagnostics, invokes local workspace tools when present (`mix compile --return-errors`, `node --check`, `tsc --noEmit`, `py_compile`, `cargo check`, `go test`, compiler `-fsyntax-only`), computes baseline/delta diagnostics, and skips gracefully when a checker, compiler, or workspace marker is absent. `LemonLsp.Servers` registers ElixirLS, TypeScript Language Server, Pyright, rust-analyzer, gopls, and clangd without atom leaks; `LemonLsp.ServerManager` runs under the core supervisor, reports redacted registry/availability/session state, and exposes `lsp.server.start` / `lsp.server.initialize` / `lsp.document.open` / `lsp.document.change` / `lsp.document.close` / `lsp.server.request` / `lsp.server.stop` controls for supervised stdio sessions with Content-Length JSON-RPC framing, initialize/initialized orchestration, document open/change/close notifications with lifecycle byte-count and cleanup summaries, server start/stop lifecycle summaries, initialize/request protocol summaries with cleanup flags for raw session ids, cwd paths, executable paths, request params, server IO, diagnostic text, credentials, and secret values, response correlation, request timeouts that terminate unhealthy sessions, launcher/descendant cleanup, and redacted `textDocument/publishDiagnostics` notification counters plus `textDocument/diagnostic` pull-response capture. `scripts/live_lsp_server_smoke.exs` now provides opt-in real-server proof with a `--servers` list, `--editor-flow`, `--project-fixtures`, and `--real-repo-fixtures`; the latest project-fixture full local fleet run completed Pyright, gopls, clangd, rust-analyzer, TypeScript Language Server, and ElixirLS initialize/open/didChange/publishDiagnostics with `completed_count: 6`, `failed_count: 0`, multi-file fixtures, root markers, companion-file counts, redacted diagnostic counters, non-zero reintroduced diagnostics, final clean diagnostics, closed documents, safe `lsp_project_fixtures_smoke` proof scope, and six per-server completed checks. The 2026-05-17 `--real-repo-fixtures --editor-flow` proof now covers the full registered server fleet: Pyright, gopls, clangd, rust-analyzer, TypeScript Language Server, and ElixirLS completed against isolated copied or maintained Lemon repository fixtures with `completed_count: 6`, `failed_count: 0`, injected and reintroduced diagnostics, final clean diagnostics, closed documents, safe `lsp_real_repo_fixtures_smoke` scope, source hashes only, and cleanup flags false for raw paths, file contents, diagnostics output, raw session ids, and server I/O. A broken-default-wrapper cleanup proof returns `:request_timeout` without leaving `elixir-ls` or `language_server` processes running. `docs/tools/lsp.md` documents local checker installs, language-server installs, override env vars, ElixirLS launcher support, timeout cleanup, control-plane methods, project-fixture proof, real-repo fixture proof, and proof lanes. `lsp.diagnostics.status`, Web `/ops`, and support-bundle `lsp_diagnostics.json` expose redacted language/checker/server/session capability metadata without paths, executable paths, raw session ids, file contents, roots, diagnostic output, or server I/O. `lsp.diagnostics.status` now also reports timeout, language, executable, server, proof, check, and cleanup summaries, and `lsp.diagnostics.status` plus Web `/ops` show recent redacted LSP proof artifacts and latest LSP proof-check summaries so operators can inspect current real-server promotion state without opening proof JSON by hand. Focused tests cover clean syntax, introduced diagnostics, pre-existing-diagnostic suppression, JavaScript syntax fixtures, Python clean/error fixtures, TypeScript no-tsconfig skip behavior, TypeScript tsconfig diagnostics, Go workspace diagnostics, Rust workspace diagnostics, C compiler diagnostics, tool output, all three mutation hooks, registry status, stdio session start/stop, JSON-RPC request/response, initialize handshake, request-timeout session cleanup, document-sync notifications, redacted push and pull diagnostic capture, stderr containment, wrapper child-process cleanup, manager restartability, control-plane schema/status/session lifecycle, control-plane LSP proof visibility, support-bundle redaction, and Web snapshot visibility. | Partial / BEAM preview | P1. Add broader editor integration and operational promotion lanes before claiming stable Hermes LSP parity. |
| LSP final audit | Hermes exposes LSP diagnostics as an editor feedback feature; release claims need current multi-server proof. | Lemon's `lsp.preview` doctor gate and final readiness audit now validate project-fixture and real-repo fixture editor-flow proof artifacts across Pyright, gopls, clangd, rust-analyzer, TypeScript Language Server, and ElixirLS. | Partial / final-audit-gated preview | P1. Add broader editor integration proof before stable LSP claims. |
| Web search/fetch | Hermes has `web_search` and `web_extract` through configured backends and the Tool Gateway. | Lemon has `websearch` and `webfetch`; support docs mark text web tools stable in reproducible runs. | Partial | P1. Verify backend setup, support boundaries, and live/integration proof. |
| Browser automation | Hermes supports Browserbase, Browser Use, Firecrawl, Camofox, local Chrome CDP, local Chromium, hybrid private-URL routing, snapshots, click/type/scroll/press, waits, console, dialogs, images, vision, file uploads/downloads, and cleanup. | Lemon now exposes `browser_navigate`, `browser_snapshot`, `browser_get_content`, `browser_click`, `browser_type`, `browser_hover`, `browser_select_option`, `browser_upload_file`, `browser_download`, `browser_press`, `browser_scroll`, `browser_back`, `browser_wait_for_selector`, `browser_evaluate`, `browser_events`, `browser_get_cookies`, `browser_set_cookies`, `browser_clear_state`, `browser_screenshot`, and `browser_analyze` through the native coding-agent tool registry, backed by the supervised local Node/Playwright driver. Browser navigation policy now lives in `LemonBrowser.RoutePolicy` and is enforced by both the coding-agent `browser_navigate` tool and control-plane `browser.request` before `browser.navigate` reaches a paired browser node or local fallback: default `auto` preserves local-first behavior while classifying public/private/local-document targets, `public` rejects local/private/data/file targets, `local` rejects public targets, metadata endpoints are blocked for every route, already-prefixed `browser.navigate` requests are not double-prefixed, policy-only `route` args are stripped before node dispatch, and responses expose only safe `networkPolicy` metadata. `browser.request` successful responses now include browser-specific dispatch/result summaries plus cleanup flags for raw URLs, selectors, typed text, page content, screenshot data, cookie values, evaluated results, error text, credentials, and secret values, while preserving the underlying `node.invoke` summary as `nodeInvokeSummary` when dispatching through a paired node. `browser_evaluate` executes page-scoped JavaScript against the current page, returns untrusted output, is policy-gated as dangerous/external, and redacts evaluated expressions from progress. `browser_hover` and `browser_select_option` cover menu/form interaction workflows; select-option is policy-gated as dangerous/external, hover is external, and progress redacts selectors plus selected values. `browser_upload_file` covers project-local file-input workflows through the browser worker's `browser.setInputFiles` method; it is policy-gated as dangerous/external, validates paths under the current project before dispatch, rejects out-of-project files, and redacts selectors plus upload paths from progress. `browser_download` covers supervised download workflows through the browser worker's `browser.download` method; it is policy-gated as dangerous/external, optionally clicks a selector before waiting for the Playwright download event, saves into a managed project-local artifact path when no path is supplied, rejects out-of-project output paths, and redacts selectors plus download paths from progress. The browser node helper also supports `LEMON_BROWSER_CDP_ENDPOINT` / `--cdp-endpoint` attach-only mode for already-running local, container, or managed CDP endpoints without launching a replacement browser, with endpoint credential redaction on connection errors. `browser.status`, Web `/ops`, and support bundles expose BEAM-owned status plus redacted artifact and cleanup metadata; control-plane `browser.status` also exposes recent live browser proof state, latest browser proof checks, and browser proof cleanup booleans. Browser tools now emit channel-safe partial progress updates with `current_action` metadata for the existing Web/TUI/Telegram/Discord status pipeline, using only method, phase, timeout, safe counts, artifact flags, route classification, and hashed host metadata while omitting raw URLs, selectors, evaluated expressions, selected values, upload paths, download paths, filenames, downloaded file contents, typed text, cookie values, page text, screenshot bytes, and artifact paths. A deterministic local-page proof and `scripts/live_browser_smoke.exs` both drive navigate/wait/evaluate/hover/select/upload/download/snapshot/type/click/screenshot/content/events through `LemonBrowser.LocalServer`; the latest live smoke also proves local-document route classification, selector waiting, page evaluation, hover, select-option, upload-file, download, metadata endpoint blocking, public-route guard rejection, cookie set/get redaction, clear-state reset, attach-only CDP endpoint mode, and 40 redacted browser progress updates through the real local driver with `completed_count: 20`, `failed_count: 0`, `model_visible_image_included: true`, `browser_to_media_vision_completed: true`, `browser_wait_for_selector_completed: true`, `browser_evaluate_completed: true`, `browser_hover_completed: true`, `browser_select_option_completed: true`, `browser_upload_file_completed: true`, `browser_upload_file_count: 1`, `browser_download_completed: true`, `browser_download_bytes: 22`, `browser_analyze_completed: true`, and `browser_cdp_attach_completed: true`. Focused wrapper and control-plane tests prove route guards, metadata blocking, selector waiting with redacted progress, page evaluation with redacted expression progress, hover/select with redacted selector and selected-value progress, upload-file project-local validation with redacted selector/path progress, download output validation with redacted selector/path progress, cookie inspection with default value redaction, explicit value opt-in, cookie seeding, clear-state reset controls, `browser.request` method normalization, policy-only arg stripping, and browser progress redaction; router status tests prove browser `current_action` partials render as child status actions without leaking hashed diagnostic details. Browser-node tests, typecheck, and build prove `browser.evaluate`, `browser.hover`, `browser.selectOption`, `browser.setInputFiles`, `browser.download`, selector waits, and remote CDP endpoint config resolves to attach-only mode, and the live browser smoke proves attach-only navigation through an externally launched Chrome CDP endpoint. Screenshot writes enforce managed artifact retention: 14 days or the newest 100 files. `browser_screenshot` remains artifact-only by default, but `includeImage: true` returns a model-visible image block for visual inspection and `sendToChannel: true` requests final Telegram/Discord attachment delivery through redacted `auto_send_files` metadata, while keeping raw base64 out of details and support bundles. | Partial / BEAM preview | P0. Provider-specific Browserbase/Camofox lifecycle integration and broader hybrid routing policy remain after the local supervised smoke, CDP attach mode, route guardrails, session-state controls, page evaluation, hover/select/upload/download, model-visible screenshot, channel screenshot attachment, retention boundaries, and status-pipeline progress proof. |
| Browser final audit | Hermes treats browser automation as a first-class tool family; Lemon release claims need current proof that the BEAM-supervised browser worker is healthy. | Lemon's `browser.preview` doctor gate and final readiness audit now validate `.lemon/proofs/browser-smoke-latest.json`, requiring local-driver execution, CDP attach mode, route guardrails, page interaction, upload/download, screenshot and model-visible image paths, cookie/state controls, progress redaction, and browser-to-media vision coverage. | Partial / final-audit-gated preview | P1. Add remote-provider lifecycle and broader hybrid routing proof before stable browser parity claims. |
| Vision and image input | Hermes supports clipboard/image input, `vision_analyze`, image URLs/data URLs through API surfaces, and browser vision. | Lemon now accepts OpenAI-compatible image URL/data URL/file-id parts in Chat Completions and Responses. HTTP(S) URLs and file ids remain redacted metadata with bounded prompt placeholders by default. HTTPS URL fetch is now opt-in behind `LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` plus a host allowlist, and fetched image bytes are MIME/size-checked, redacted, and passed through runtime-only image blocks. Base64 data URL images are validated, size/count-limited, redacted from prompts/metadata, and passed through the BEAM run contract into native Lemon runtime image blocks. `browser_screenshot includeImage: true` adds a second model-visible image path for browser screenshots without exposing raw screenshot bytes in result details. `browser_analyze` composes managed browser screenshot capture with `media_analyze_image` so models can inspect the current page through one supervised BEAM-owned vision tool. `media_analyze_image` gives models a supervised local artifact analysis path with deterministic `local_vision` preview and provider-backed `openai_vision`, accepts only project-local image files, writes managed JSON/text analysis artifacts, stores image/prompt fingerprints instead of raw paths/prompts/bytes, can request generated attachment metadata, and routes provider-prefixed OpenAI-compatible models such as `openrouter:openai/gpt-4o-mini` through the matching Lemon provider credentials/base URL while preserving redacted prefixed model metadata. Telegram and Discord finalized-run attachment delivery now share an opt-in generated-file auto-send boundary with configured file count and size limits; explicit file-send requests remain available through the normal attachment path. Focused tests prove raw URLs/data bytes are not returned, Discord generated auto-send requires config opt-in, and image-analysis job metadata stays redacted. A provider-backed media vision smoke now passes through OpenRouter `openai/gpt-4o-mini`; richer browser vision workflows, provider-specific image transport quirks, direct-OpenAI quota proof, and richer live channel media delivery remain preview/out of stable support. | BEAM preview with live media vision proof | P0. Build provider-specific image transport handling, model routing proof, redaction evals, richer browser vision workflows, and Telegram/Discord live delivery boundaries. |
| Image/video generation | Hermes supports image generation providers, video-generation provider plugins, and media delivery. | Lemon generated media is preview. The BEAM-owned support slice records generated-media job metadata in `.lemon/media-jobs/`, summarizes managed media artifacts under `.lemon/media-artifacts/`, records generated final-answer `auto_send_files` before channel delivery, exposes redacted type/status/artifact counts through `media.status`, source-wrapper `./bin/lemon media`, `mix lemon.media`, Telegram/Discord `/media status`, `media_diagnostics.json`, Web `/ops`, runs pluggable media workers under `LemonMedia.MediaJobSupervisor` with queued/running/completed/failed metadata plus PubSub lifecycle events, and omits prompts, raw artifact paths, generated bytes, provider responses, captions, session keys, and channel message bodies from support surfaces. `media_status` now gives models read-only redacted job/artifact/worker visibility. `media_generate_image` gives models a `local_svg` preview plus `openai_image` and `vertex_imagen` provider-backed image-generation paths on that supervisor boundary, writes managed SVG/PNG/JPEG/WebP artifacts, resolves OpenAI or Vertex credentials through Lemon runtime config/secrets when not injected, returns prompt hash/chars instead of raw prompts, retries bounded transient provider failures, redacts provider errors, and can request generated-file Telegram/Discord attachment metadata via `sendToChannel: true`. `media_generate_speech` adds the matching local WAV plus provider-backed OpenAI, ElevenLabs, and Google TTS paths, writes managed MP3/Opus/AAC/FLAC/WAV/PCM artifacts, records text hash/chars instead of raw text, retries transient provider failures, and can request generated-file attachment metadata. `media_transcribe_audio` adds local transcript and provider-backed OpenAI STT on the same supervisor path, restricts audio inputs to project-local files, records only audio fingerprints in job metadata, writes managed JSON/text transcript artifacts, and redacts provider errors. `media_analyze_image` adds local image analysis and provider-backed OpenAI/OpenAI-compatible vision on the same supervisor path, restricts image inputs to project-local files, records only image/prompt fingerprints in job metadata, writes managed JSON/text analysis artifacts, routes provider-prefixed compatible models through matching Lemon provider config, and redacts provider errors. `media_generate_video` adds local MP4 preview and provider-backed OpenAI video create/poll/download on the same supervisor path, writes managed MP4 artifacts, records prompt hashes instead of raw prompt text, retries transient provider failures, redacts provider errors and provider job ids, and can request generated-file attachment metadata. `scripts/live_media_image_smoke.exs`, `scripts/live_media_speech_smoke.exs`, `scripts/live_media_transcription_smoke.exs`, `scripts/live_media_vision_smoke.exs`, and `scripts/live_media_video_smoke.exs` add opt-in redacted proof harnesses for the provider-backed image/TTS/STT/vision/video paths. The provider proof commands now use `mix run --no-start` so one-off `--api-key-secret` runs can boot the persistent encrypted Lemon secret store before the script resolves the credential; `scripts/live_media_vision_smoke.exs --model openrouter:openai/gpt-4o-mini --api-key-secret OPENROUTER_API_KEY --proof-path .lemon/proofs/media-vision-smoke-latest.json` passed on 2026-05-17 with `completed_count: 1`, `failed_count: 0`, and redacted canonical proof metadata. The live Telegram and Discord matrices now include generated-media delivery probes for `media_generate_image` with `provider local_svg` and generated-audio delivery probes for `media_generate_speech` with `provider local_wav`, both using `sendToChannel: true` and the normal attachment path. Telegram generated-SVG delivery passed on 2026-05-16 in topic `35`, and Telegram generated-audio delivery passed on 2026-05-17 in topic `35` with a WAV document and marker proof. Discord generated-SVG delivery passed on 2026-05-16 in channel `1475727417372049419`, and Discord generated-audio delivery passed on 2026-05-17 in the same channel with one generated WAV attachment. The runner preserves generated source metadata and Telegram/Discord renderers gate generated files whether source arrives as an atom or string. The Discord renderer now sends generated files after successful final text create or edit dispatch, so attachment delivery is not lost when a final answer updates an existing presentation message. The current source-wrapper media diagnostics report 29 jobs, 28 artifacts, and provider proofs 2/5, with STT proven through `deepgram_transcribe`, vision proven through `openai_vision`, image blocked at `vertex_imagen_http_error:permission_denied`, TTS blocked at `google_tts_http_error:permission_denied`, and video blocked at `vertex_veo_create_http_error:permission_denied`; successful live image/TTS/video provider proof is still open. | BEAM preview with live channel delivery and media vision proof | P0/P1. Keep provider-backed image/TTS/video work on top of `LemonMedia.MediaJobs`, then run live proofs under usable quota. |
| TTS/voice/STT | Hermes supports voice mode, voice memo transcription, Discord voice, and many TTS backends including command providers. | Lemon now has model-facing preview `media_generate_speech` and `media_transcribe_audio` tools that run local and provider-backed OpenAI TTS/STT through `LemonMedia.MediaJobSupervisor`, record redacted media-job metadata, write managed audio/transcript artifacts, and can request generated attachment metadata. Telegram voice-note transcription supports `openai_transcribe` for real STT plus deterministic no-credential `local_transcript` proof mode, which routes a local transcript preview through the normal Telegram inbound path and marks the inbound message as voice-transcribed without requiring an API key. `scripts/live_telegram_voice_local_smoke.exs` writes `.lemon/proofs/telegram-voice-local-latest.json` with redacted check counts for the local provider, no-api-key path, and preserved voice metadata without raw audio bytes, transcript text, chat ids, sender ids, message bodies, or bot tokens. `mix lemon.doctor --verbose` now promotes that artifact into `channels.telegram.voice_transcription`, so Telegram voice proof status is visible in the same support/readiness lane as Discord channel gates. Telegram and Discord generated-audio delivery are live-proven through the normal generated-file auto-send path. Control-plane `tts.status` preserves explicit stored TTS config values and reports active-provider known/available state, provider readiness counts, and cleanup flags for operator clients without returning secret values or raw provider errors. Control-plane `tts.enable`, `tts.disable`, and `tts.set-provider` now add config-write cleanup summaries without returning input text, audio bytes, credential values, or secret values. Control-plane `voicewake.get` preserves explicit wake-word config values and reports configured/enabled/backend summaries plus cleanup flags without returning audio samples or secret values, and `voicewake.set` now adds write cleanup summaries without returning audio bytes, transcripts, credential values, or secret values. Voice mode, Discord voice, and live provider-backed TTS/STT proof remain open. | BEAM parity target | P1. Add voice-mode supervision, run provider-backed TTS/STT proof under usable quota, and keep Telegram/Discord generated-audio delivery proof green. |
| Memory | Hermes has bounded `MEMORY.md` and `USER.md`, prompt injection, memory add/replace/remove, session search, and external memory providers such as Honcho/Mem0/Supermemory. | Lemon has SQLite memory documents, `search_memory`, Hermes-compatible `session_search`, `memory_topic`, workspace memory-file inspection evals, secret screening, memory docs, `LemonCore.MemoryProvider` / `MemoryProviders` for supervised BEAM-native provider ingest/search fan-out, read-only `memory.status` with redacted provider health and searchable-scope summaries, Web `/ops` provider visibility, and a default `memory` tool for bounded assistant-home `USER.md` / `MEMORY.md` read/add/replace/remove with duplicate checks, unique-substring replace/remove, compact file limits, secret screening, prompt-injection screening, and invisible-control rejection. | Green for Lemon core memory; BEAM preview for compact profile/provider semantics | P1. Add external provider adapters beyond the local provider and prove compact memory in live model/channel flows before claiming stable Hermes parity. |
| Session search | Hermes uses SQLite FTS5 through a single-shape `session_search` tool with discovery, scroll, and browse modes and no LLM calls. | Lemon now exposes `session_search` as a no-LLM model-facing compatibility wrapper over durable BEAM memory and run history: `query` discovers matching sessions, `session_id` plus `around_message_id` scrolls bounded run-history windows, and no args browse recent current-session runs. Lemon-native `search_memory` still covers scoped prior-run recall, and evals cover prior-work recall. | Green for named compatibility shape; Partial for Hermes full-message FTS breadth | Keep deterministic and live-model recall evals green, and later add full transcript-message indexing if needed. |
| Skills | Hermes skills support progressive disclosure, external dirs, required env setup, config injection, hub/audit state, agent-managed skill creation, and dynamic skill commands. | Lemon has project/global skills, `read_skill`, `skill_manage`, usage/curation sidecars, audits, curator manager, draft synthesis, registry install/update/remove, MCP docs, eval coverage, read-only `skills.status` with activation/source/missing-requirement summaries that preserve not-ready states, `skills.bins` bin/requirement cleanup summaries, `skills.install` source/path return-state and approval-context cleanup summaries, and `skills.update` env-key/update-mode summaries that redact sensitive env response values while preserving safe env keys. Source installs can now use `./bin/lemon skill` for the existing skill lifecycle task, and `scripts/verify_source_install` proves `./bin/lemon skill list`. | Green for core skills; Partial for ecosystem commands/distribution | P1. Keep skill lifecycle green and fold skill distribution into plugin/capability-host work. |
| MCP | Hermes supports stdio/HTTP MCP, prefixed dynamic tools, utility resource/prompt tools, filtering, sampling, OAuth metadata, and capability wrappers. | Lemon now has locally proven stdio MCP ingestion, stdio resource/prompt utility access, exact stdio allow/block filtering, an opt-in stdio `sampling/createMessage` callback wrapper, and `LemonMCP.Sampling` reviewed model-backed sampling policy wrapper that redacts summaries, enforces max-token/model allowlists, and only calls delegates after reviewer approval. Sampling is only advertised when a handler or policy is configured. Lemon also has Streamable HTTP MCP tool/resource/prompt ingestion with JSON and per-request SSE response proof, session/protocol headers, OAuth protected-resource and authorization-server metadata discovery, OAuth client-credentials token acquisition with form-post or HTTP Basic token endpoint auth, protected-request retry, refresh-token grant retry and one-shot bearer reacquisition after a later 401, authorization-code PKCE callback/token exchange, exact HTTP filtering, and legacy HTTP+SSE MCP tool/resource/prompt ingestion with exact SSE filtering. `LemonMCP.Transport.Stdio` uses a real stdio port, `LemonMCP.Client` captures responses in the client process, exposes server capability metadata, and can answer server sampling requests through an explicit callback or policy, `LemonSkills.McpSource` starts configured stdio servers, discovers tools, applies exact allow/block lists before registry exposure, wraps tools as `mcp_<server>_<tool>` `AgentTool`s, exposes capable servers through `mcp_<server>_resources_list`, `mcp_<server>_resource_read`, `mcp_<server>_prompts_list`, and `mcp_<server>_prompt_get`, invokes original MCP names, propagates MCP tool errors, and degrades unavailable servers without breaking the registry. `CodingAgent.ToolRegistry` includes MCP tools as the lowest-precedence source after built-ins, WASM, and extensions, and its conflict report exposes MCP counts and shadowed sources. `scripts/live_mcp_stdio_smoke.exs` writes `.lemon/proofs/mcp-stdio-latest.json` and passed with seventeen completed checks for missing-command degradation, client initialization, tool listing, resource list/read, prompt list/get, success call, error call, source discovery, source utility invocation, registry exposure, exact filter enforcement, `notifications/initialized` compatibility, the sampling callback wrapper, the reviewed model-backed sampling policy wrapper, and `mcp_stdio_sampling_ops_approval_bridge`. `scripts/live_mcp_http_smoke.exs` writes `.lemon/proofs/mcp-http-latest.json` and passed with twenty-four completed checks for Streamable HTTP initialize, JSON and per-request SSE responses, session/protocol headers, OAuth protected-resource and authorization-server metadata discovery, OAuth client-credentials token acquisition, client_secret_basic token endpoint auth, refresh-token grant retry, authorization-code PKCE callback/token exchange, OAuth token cache resume without another metadata or token request, configured-source loopback callback capture plus operator approval routing, and bearer reacquisition after a later 401, tool listing, resource list/read, prompt list/get, success and error calls, source discovery, source utility invocation, registry exposure, status capability shape, and exact filter enforcement. `scripts/live_mcp_sse_smoke.exs` writes `.lemon/proofs/mcp-sse-latest.json` and passed with fourteen completed checks for legacy SSE endpoint discovery, tool listing, resource list/read, prompt list/get, success and error calls, source discovery, source utility invocation, registry exposure, status capability shape, and exact filter enforcement. `mix lemon.doctor --verbose` now reports `mcp.preview` from those proof artifacts and passes only when all three transport proofs are complete. Final readiness audit validates the same proof artifacts by default, with `LEMON_MCP_STDIO_PROOF_JSON`, `LEMON_MCP_HTTP_PROOF_JSON`, and `LEMON_MCP_SSE_PROOF_JSON` overrides when release evidence lives elsewhere. | Partial / stdio, Streamable HTTP, and legacy SSE tools/resources/prompts/filtering doctor-gated and final-audit-gated; stdio sampling callback, reviewed model-backed policy, and configured-source ops approval bridge wrappers plus HTTP client-credentials token acquisition, Basic token auth, refresh-token grant, authorization-code PKCE callback, token cache resume, configured-source loopback callback capture plus operator approval routing, and bearer reacquisition proven | P1. Add broader external-server compatibility proof. |
| Plugins | Hermes has opt-in user/project/pip/Nix plugins, platform plugins, image/video/provider/context/memory plugin classes, plugin hooks, slash commands, CLI commands, bundled skills, LLM access, and install/enable flows. | Lemon has skills, MCP, extensions docs, WASM/extension status tools, audits, conflict reporting, explicit extension execution trust policy, global `[runtime.extensions] enabled` / `LEMON_EXTENSIONS_ENABLED` disable switch, code-free manifest validation, code-free registry install/update audit validation, extension memory-provider registration into `LemonCore.MemoryProviders`, redacted support-bundle and Web `/ops` manifest/registry diagnostics, read-only `extensions.status`, redacted BEAM/WASM/MCP/external host-runtime diagnostics with degraded-host and manifest-only counts, BEAM extension-host telemetry proof, WASM tool-wrapper telemetry proof, WASM risky-capability policy proof, WASM sidecar lifecycle proof, and extension registry audit proof surfaced through doctor, `extensions.status`, Web `/ops`, support bundles, Web `/ops`, and JSON-RPC `proofs.status`; generic proof diagnostics, Web proof rows, and the lowerCamelCase control-plane formatter preserve extension/WASM proof-level `redaction` maps on recent proof summaries so raw cwd, session ids, params, paths, manifests, distribution URLs, and tool payload omission remains visible in release support artifacts. | Partial / operator diagnostics | P0/P1. Build full marketplace hosting, sandbox execution breadth, external hosted plugin proofs, and stronger hook/plugin-host telemetry before stable ecosystem claims. |
| Provider plugins/routing | Hermes has model provider plugins, profile distributions, provider routing, fallback providers, and credential pools. | Lemon has `apps/ai` provider abstraction, config/secrets, and `AgentCore.ModelRuntime.StreamOptions` now carries configured OpenAI-compatible provider API keys and base URLs into provider-specific stream options for Z.ai/Kimi/Minimax-style providers. `AgentCore.ModelRuntime.ProviderStatus` powers redacted control-plane `providers.status` and Web `/ops` provider readiness using the runtime credential resolver, without returning raw keys, secret names, base URLs, or env var names. `AgentCore.ModelRuntime.ProviderRouting` defines `runtime.provider_routing` fallback semantics and returns a redacted route-plan preview through the same surfaces, including selected routing profile, selected credential pool, profile distribution weights, pool strategy/provider names, candidate readiness, and credential-reference counts. `LemonCore.ProviderPoolRotator` adds supervised BEAM-native round-robin ordering for credential pools. Coding-agent default model resolution consumes the same fallback/profile/pool ordering before supervised agent startup, selecting a credential-ready fallback provider with the same model id when the configured default provider is not ready while preserving explicit model choices. Default-model streams now retry another ready fallback provider when the first provider fails before useful assistant content or tool calls are emitted, while post-content failures surface normally to avoid duplicated transcript output. Model discovery is available through `mix lemon.models` and source-wrapper `./bin/lemon models`, provider readiness is available through `mix lemon.providers` and source-wrapper `./bin/lemon providers`, and route-specific model/thinking defaults are managed by `mix lemon.policy` and source-wrapper `./bin/lemon policy`; `scripts/verify_source_install` proves catalog, provider readiness, policy listing, and redacted proof-artifact listing alongside setup/config/doctor/update dispatch. `mix lemon.doctor` includes a redacted `providers.routing` check for fallback readiness. `proof_diagnostics.json`, read-only `proofs.status`, `mix lemon.proofs`, source-wrapper `./bin/lemon proofs`, `providers.status`, and Web `/ops` expose the latest redacted provider fallback proof status, provider path, proof object, timestamp, proof hash, and next action without raw artifact paths or filenames. `scripts/live_provider_fallback_smoke.exs` passed with an intentionally invalid OpenAI primary and Z.ai `glm-5-turbo` fallback, writing redacted proof JSON with no raw keys, prompts, or answers. | BEAM live-fallback proof plus source-wrapper model/provider/policy/proofs proof | P1. Add OAuth/custom endpoint variants and keep the live fallback proof green. |
| Delegation/subagents | Hermes `delegate_task` spawns isolated subagents and supports background sessions. | Lemon has `task`, `agent`, parent questions, run graph, joins, leaf/orchestrator policies, deterministic and live-model delegation evals. | Green | Keep side-effect verification, leaf policy, and joined-artifact evals green. |
| Persistent goals | Hermes `/goal` persists a standing objective, auto-continues with a judge, supports pause/resume/clear, and works on gateway surfaces. | Lemon now has `LemonCore.GoalStore`, control-plane `goal.set`/`goal.status`/`goal.pause`/`goal.resume`/`goal.continue`/`goal.loop.once`/`goal.loop.start`/`goal.loop.status`/`goal.loop.stop`/`goal.clear`, persisted `maxContinuations` budget plumbing, objective-byte summaries and cleanup flags for `goal.set`/`goal.status`/`goal.pause`/`goal.resume` without echoing objective text, cleanup summaries for `goal.continue`, `goal.loop.once`, `goal.loop.start`, `goal.loop.status`, `goal.loop.stop`, and `goal.clear`, redacted support-bundle diagnostics, goal lifecycle and loop-status events, supervised one-shot `LemonAutomation.GoalContinuationManager`, preview verdict ticks, bounded autonomous loops, opt-in persisted auto-loop scheduling through `LemonAutomation.GoalLoopManager`/`GoalJudge`, pluggable judge-runner/model metadata, dev/prod router-backed `:goal_judge` default with `LEMON_GOAL_JUDGE_MODEL` override, JSON verdict parsing, default fail-closed, explicit fail-open, budget-exhaustion tests, production-shaped router proof through `GoalJudge.RouterRunner`, `LemonRouter`, a real router `RunProcess`, and `RunCompletionWaiter`, production-shaped persisted-auto scheduler proof through the same path, a credential-backed provider live proof through Z.ai `glm-5-turbo`, TUI `/goal` including budgeted `set`, `continue`, `loop once`, `loop start --auto`, `loop status`, and `loop stop`, Telegram/Discord `/goal` status/set-with-budget/pause/resume/continue/loop/auto/clear commands, and Web `/ops` budget plus loop-status visibility. | BEAM live-judge proof | Keep provider-backed judge proof green while adding richer channel-visible loop behavior. |
| Kanban multi-agent boards | Hermes has durable SQLite boards, task links, comments, workers, workspaces, dispatcher, boards, dashboard, CLI, slash commands, and model-facing `kanban_*` tools. | Lemon now has a durable BEAM-native board foundation in `LemonCore.KanbanStore`: boards, columns, tasks, dependencies, comments, assignees, worker profiles, session/run links, lifecycle events, expiring task leases, redacted support-bundle diagnostics, and control-plane `kanban.board.*` / `kanban.task.*` CRUD methods. `LemonAutomation.KanbanDispatcher` supervises task leasing, expired-lease reclaim, worker execution, completion, and failure marking with focused tests for bounded multi-worker leasing, completion, explicit worker failure, crashed-worker failure marking, expired-lease reclaim, and a production-shaped bounded-concurrency path through the real `KanbanRunWorker` with router/waiter stubs. `apps/lemon_automation/test/lemon_automation/kanban_dispatcher_live_test.exs` passed locally against Z.ai `glm-5-turbo` on 2026-05-15, proving three durable tasks through real `KanbanRunWorker`/router/waiter execution with dispatcher `running_count: 2`, completed run ids, and cleared leases. `kanban.dispatcher.start/status/stop` exposes operator control, the default `KanbanRunWorker` submits leased work through `LemonRouter` with board/task provenance, optional model override, and per-task git worktree cwd when the board workspace is a git repository, the default coding-agent toolset now includes a model-facing `kanban` tool for durable board/task management, Web `/ops` shows redacted board/task state, and TUI `/kanban`, Telegram `/kanban`, and Discord `/kanban` expose board/task/archive/dispatcher controls. Telegram topic live proof now passes for create/task/comment/show/archive redaction in topic `35`. `scripts/live_discord_matrix.py --bot-token-index 0 --register-kanban-slash-command --result-path tmp/discord-kanban-slash-proof.json` and follow-up `--check-kanban-slash-registration` passed through Discord's API for the in-repo `/kanban` schema: command id `1505003302893522954`, version `1505003302893522955`, all expected subcommands, and no missing options. | BEAM live-worker plus Discord registration proof | P0/P1. Add Discord client-interaction proof before claiming broad slash-command parity. |
| Cron/scheduled tasks | Hermes has natural-language cron creation, `/cron`, CLI commands, skill-backed jobs, lifecycle actions, origin/local/platform delivery, workdir support, scheduler lock, and recursive scheduling guardrails. | Lemon has cron manager, Web ops controls, scheduled prompt contract, prior-run memory, origin delivery, `blocked_tools`, and support docs classify cron preview. Cron creation/update now accepts 5-field cron plus supported operator shorthands (`every 30m`, `hourly`, `every 2h`, `daily at 9am`, `weekdays at 09:30`, `weekly monday at 8am`) and stores normalized cron expressions through the same scheduler path; interval shorthands must divide the enclosing cron field exactly, and invalid schedule updates now return operator input errors instead of internal errors. Control-plane operators can create no-agent command cron jobs with `command` instead of `agentId`/`sessionKey`/`prompt`; those jobs run as supervised local shell commands under `CronManager`, store output/error in cron run history, retry through the same scheduled retry policy, and do not create LemonRouter runs or channel summaries. `cron.list` redacts prompt and command text by default, returns prompt/command byte counts plus cleanup summaries, and requires explicit `includeTargetText: true` for trusted raw target-text views. `cron.status` now carries cleanup summaries confirming scheduler-health counters exclude prompt text, command text, output text, error text, message bodies, credentials, and secret values. `cron.audit` now reports action counts, active filters, raw-id and reason-text return flags, and cleanup summaries so operator clients can distinguish authorized lifecycle metadata from excluded prompt/command/output/error/secret material. `cron.add`, `cron.update`, `cron.pause`, `cron.resume`, and `cron.abort` now return lifecycle summaries with target byte counts, changed fields, raw-id flags, and cleanup metadata without echoing prompt/command/output/error text. `cron.run`, `cron.remove`, and `cron.runs` now return lifecycle/run-history summaries with raw-id flags, status counts, output/error byte counts, include flags, and cleanup metadata that makes output previews or operator-requested internals explicit; `cron.runs` redacts sensitive output, error, metadata, run-record, and introspection values before returning them. `cron_diagnostics.json` is now included in support bundles with redacted job/run counts, status/trigger counts, timestamps, hashed identifiers, hashed prompt/command/output/error/session/memory metadata, retry policy, retry lineage hashes, and redacted lifecycle audit shape. `scripts/live_cron_diagnostics_smoke.exs` passed with `cron_diagnostics_counts`, `cron_diagnostics_retry_policy`, `cron_diagnostics_redaction`, and `cron_support_bundle_entry`. Scheduled ticks now suppress duplicate launches while a persisted run for the same job is pending/running and recover active runs older than the job timeout as `:timeout`; focused restart tests prove `CronManager` restart reloads persisted active runs without duplicate scheduled submit and recovers stale active runs during initialization. Scheduled run slots now use deterministic IDs and `LemonCore.Store.put_new/3` via `CronStore.claim_scheduled_run/3`, so competing dispatchers preserve the first claimant instead of overwriting the run. `scripts/live_cron_runtime_restart_smoke.exs` now boots `:runtime_full` twice against one isolated durable store and passed with `runtime_booted`, `cron_api_ready`, `pre_restart_scheduled_run_observed`, `runtime_restarted`, `persisted_cron_state_loaded`, and `post_restart_scheduled_run_observed` checks. Channel-origin forwarded summaries now persist the synthetic base-session completion and enqueue through `LemonChannels` via a narrow `LemonRouter.ChannelsDelivery` bridge without router-side `OutboundPayload` construction; `scripts/live_cron_channel_origin_smoke.exs` proves Telegram- and Discord-shaped channel-peer cron completions through `CronManager`, forwarded run history, the router bridge, and the LemonChannels outbox with redacted proof metadata. Scheduled failures/timeouts can now retry as separate `:retry` runs using `max_retries` and `retry_backoff_ms`; control-plane `cron.pause` / `cron.resume` and model-facing `cron` tool pause/resume actions expose explicit lifecycle controls over the existing `enabled` state. Active cron runs can now be aborted by cron run id through control-plane `cron.abort`, the model-facing `cron` tool, Web `/ops`, and TUI `/cron abort <run-id>`, with the persisted cron run ending in terminal `:aborted` state and late submitter completions ignored. Cron lifecycle actions now persist durable operator audit events in `:cron_audit_events`; authorized clients can query raw operator IDs through `cron.audit`, WebSocket subscribers receive `cron.audit` events, Web `/ops` and control-plane `cron.status` show recent lifecycle audit rows plus active scheduler locks, retry runs, suppressed slots, stale recoveries, scheduled retries, next/last run timestamps, and count maps, while support bundles expose only redacted audit counts/action shape/reason hashes/changed fields. `LemonCore.Doctor.CronDiagnostics` also classifies `:aborted` runs as `aborted` instead of unknown. Web `/ops` create/edit controls expose retry policy fields; focused Store, lifecycle, Web, TUI, EventBridge, diagnostics, schedule-normalization, command-cron, and cron claim tests passed, including 146 focused TUI tests for slash command parsing and WebSocket routing. | Partial / supportable preview | P1. Promote cron after live external-channel proof is complete. |
| Cron final audit | Hermes treats scheduled jobs as a durable operations surface; Lemon release claims need current BEAM proof. | Lemon's `cron.preview` doctor gate and final readiness audit now validate diagnostics/support-bundle redaction, full-runtime restart persistence, and Telegram/Discord-shaped channel-origin proof artifacts before cron preview support can be promoted. | Partial / final-audit-gated preview | P1. Keep deployed external-channel proof separate from local channel-shaped proof before stable cron claims. |
| Messaging breadth | Hermes advertises Telegram, Discord, Slack, WhatsApp, Signal, CLI, email, and many gateway adapters. | Lemon has Telegram, Discord, X, XMTP, legacy gateway ingress, and SMS/voice/email/webhook/farcaster glue. `channels.status` and source-wrapper `./bin/lemon channels` carry redacted Telegram/Discord diagnostics, proof state, shared launch-gate readiness, promoted-platform counts, and cleanup summaries, `channels.logout` returns credential/token/adapter-state cleanup summaries on success, and `transports.status` carries legacy gateway registry/module health summaries. Support docs mark most non-Telegram/Discord channels preview. | Partial | P0 for Telegram/Discord only. Keep other platforms preview until separately proven. |
| Telegram | Hermes supports DMs, groups, privacy-mode guidance, admin alternative, home channel, voice messages, files/images, webhook/polling, proxy, script-output piping, and host-visible `MEDIA:` delivery. | Lemon has live proof for DM recovery, group/forum routing, topic isolation, cancellation, tool rendering, markdown/code, approval buttons, long-output chunking, `/file get`, and restart/dedupe. Telegram voice-note transcription now has a deterministic no-credential `local_transcript` provider plus a redacted proof runner for exercising the inbound voice path locally, while `openai_transcribe` remains the real STT path. Doctor consumes the redacted local voice proof and reports `channels.telegram.voice_transcription` as pass when the artifact is current. `./bin/lemon send` / `mix lemon.send` can send script text or up to 10 local file attachments to `telegram:<chat_id>[:thread_id]` with positional/file/forced-stdin body resolution, attachment captions, sanitized attachment filename/count/byte metadata, default-target env vars, filtered JSON/list/quiet/help modes, sanitized message_id/extra_message_ids and attachment metadata extraction, bounded BEAM-store known-target discovery through `LemonChannels.Telegram.KnownTargetStore`, and injected-delivery unit proof without real Telegram credentials. | Green for text/document/local voice proof and unit-proven script notifications; Partial for rich media/live provider-backed voice/webhook breadth | P0. Add rich media, image analysis/generation delivery, live provider-backed voice/STT/TTS proof, webhook/proxy docs if claimed, and keep live matrix green. |
| Discord | Hermes supports DMs, server mention rules, free-response channels, thread isolation, per-user group sessions, interrupts/concurrency, files, voice, slash commands, intents, permissions, safe mentions, history backfill, auto-threading, script-output piping, and bot-message policy. | Lemon passed second-bot live proof for channel text/file boundary: exact reply, markdown/code, long output, tool success/failure, and text attachment. Discord public-thread prompt/reply proof passed, Discord generated-SVG delivery passed, Discord generated-audio delivery passed with one generated WAV attachment, and `/kanban`, `/checkpoint`, `/media`, plus in-repo `/rollback` command registration paths now exist through the live Discord matrix. The final readiness audit now requires explicit raw and redacted `/rollback` slash-registration proof and the current all-command registration verifier expects 16 Lemon command names; the latest Zeebot rollback registration and all-command registration checks pass with 16 registered commands and no missing commands. The deterministic slash proof covers that 16-command inventory, checkpoint/rollback/kanban/media decoders, and safe local responses for session/model/thinking/resume/cancel/media/trigger/cwd/topic/file paths. The runtime also passively writes redacted client-click proof artifacts when a real slash-command interaction arrives from Discord with live-only fields and Lemon emits a safe response, giving operators a deploy-time promotion path for the remaining slash gate. Outbound/interaction responses disable Discord mention parsing and reply pings by default with focused proof, approval components resolve core approvals, cancel/watchdog keepalive components route through the runtime/router bridge, duplicate `MESSAGE_CREATE` events submit only one Lemon run through the normal inbound/debounce/runtime path including after simulated transport restart through persisted idempotency, `/trigger all` deterministic proof enables unmentioned free-response messages until `/trigger mentions` restores suppression, and deterministic bot-message policy proof shows self bot messages/webhooks are ignored while external bot-authored mentions preserve sender metadata and route through normal trigger policy. `./bin/lemon send` / `mix lemon.send` can send script text or up to 10 local file attachments to `discord:<channel_id>[:thread_id]`, unique known `discord:#channel`, `discord:#channel:thread-name`, or `discord:<channel_id>:thread-name` targets with positional/file/forced-stdin body resolution, attachment captions, sanitized attachment filename/count/byte metadata, default-target env vars, filtered JSON/list/quiet/help modes, sanitized message_id/extra_message_ids and attachment metadata extraction, bounded BEAM-store known-target discovery through `LemonChannels.Discord.KnownTargetStore`, and injected-delivery unit proof without real Discord credentials. Missing or ambiguous Discord known names fail as usage errors instead of guessing. The live gateway restart seed and post-restart verify phases passed on 2026-05-17 with `--restart-seed` and `--restart-verify --restart-runtime-confirmed`: no duplicate seed reply appeared in the 30 second window and a fresh post-restart prompt completed. `scripts/live_discord_matrix.py` now supports `--proof-path` so live matrices can keep raw operator handoff JSON under `tmp/` while writing sanitized `.lemon/proofs` artifacts with hashed identifiers, check counts, reason kinds, and cleanup assertions for `proofs.status`, support bundles, doctor gates, and Web `/ops`. `scripts/live_discord_matrix.py --wait-free-response-trigger` creates a temporary thread, seeds both safe trigger-mode key shapes, sends an unmentioned second-bot message, embeds redacted local channel diagnostics, cleans up the override, and preflights Message Content Intent flags; the latest live proof at `.lemon/proofs/discord-free-response-latest.json` completed with `message_content_intent_declared: true`, trigger mode `all`, cleanup mode `clear`, and redacted proof metadata. The DM proof path now emits a safe setup-failure proof with redacted local channel diagnostics and support-bundle `discord_dm_setup_refused` classification when Discord returns API code `50007`; support bundles expose the redacted DM/free-response/inbound-replay/slash-command readiness and bot-message policy shape through `channel_diagnostics.json`, while `channel_readiness.json` and `channels.status` expose the shared launch-gate summary, safe reason kinds, slash-registration partial evidence, and Discord slash client-click wait-mode next action without IDs, tokens, message bodies, raw proof paths, or raw proof details. The final readiness audit also echoes bounded reason-kind labels from incomplete Discord DM, free-response, and slash client-click proof artifacts without printing Discord IDs, tokens, or message bodies. | Green for text/file/generated-audio channel delivery, script notifications, safe mentions, deterministic components, deterministic local slash breadth, live application-command registration, deterministic bot-message policy, deterministic free-response mode, and live gateway reconnect replay; Partial for DM/voice/live slash client-click execution | P0. Add DM, provider-backed voice/media proof, and operator-clicked command proof before claiming broad Discord parity. |
| Approvals and safety | Hermes has approve/deny/yolo flows, command allowlists, platform authorization, safe mentions, DM pairing, startup advisories, OSV/dependabot, and container hardening. | Lemon has tool policies, approvals, safety contract, untrusted-boundary evals, support-bundle redaction, Telegram approval proof, Discord safe-mention defaults for outbound/direct/interaction responses, deterministic Discord approval-component proof through `LemonCore.ExecApprovals`, deterministic cancel/keepalive component proof, deterministic inbound dedupe proof, browser/web/WASM untrusted tool output, media transcript and image-analysis text marked untrusted with trust metadata, security docs, npm audit release gates, and a detection-only OSV Scanner workflow scoped to first-party Mix, npm, and uv lockfiles with SARIF upload. | Partial | P0/P1. Add live Discord approval/client-click proof, keep OSV findings triaged, and decide whether container-hardening scans need promotion before broad parity claims. |
| Observability/support | Hermes has logs, `/debug`, profile/home paths, gateway status, doctor, dashboard, usage/insights, kanban diagnostics, and detailed health endpoints. | Lemon has doctor bundles, Web `/ops`, run detail, support bundles, runtime health, logs docs, issue templates, release audits, and redacted media job diagnostics for the generated-media foundation, media doctor summaries that expose only safe provider proof reason kinds for failed or skipped image/TTS/STT/vision/video lanes, recent support-bundle, Web `/ops`, and JSON-RPC proof summaries that preserve both generic `cleanup` maps and proof-level `redaction` maps, with API-facing redaction keys normalized to lowerCamelCase for extension/WASM support evidence. Control-plane `usage.status`, source-wrapper `./bin/lemon usage`, Web `/ops`, doctor `usage.status`, and support-bundle `usage_diagnostics.json` now read shared `LemonCore.UsageDiagnostics` summaries maintained by `usage.cost`, including per-provider requests/tokens/cost, quota state, remaining quota estimates, daily totals, and cleanup flags without exposing prompts, responses, message bodies, credentials, or secret values; `usage.cost` now also exposes provider/day/token/request cleanup summaries without prompt, response, message-body, credential, or secret values. Control-plane `config.get` redacts sensitive stored config values and reports key-count/sensitive-key cleanup summaries, `config.set` redacts sensitive write-response echoes and reports cleanup summaries by key name, and `config.patch` now returns applied-key and sensitive-key cleanup summaries without echoing patched values, and `config.schema` returns property summaries without runtime values. Control-plane `memory.status` and `secrets.status` now expose provider/store health, fallback state, counts, and cleanup summaries without memory document text, secret values, raw key material, credentials, or file contents. Control-plane `providers.status`, `proofs.status`, and `extensions.status` now expose provider readiness, live fallback proof state, proof inventory, launch-gate statuses, extension host/runtime state, counts, and cleanup summaries without API keys, secret names, raw proof details, provider responses, raw extension paths, load-error messages, config schemas, or provider modules. Control-plane `runs.active.list`, `runs.recent.list`, `tasks.active.list`, and `tasks.recent.list` now expose compact status, engine, agent/session/run, event, reasoning, duration, and cleanup/include summaries so non-Web clients can monitor orchestration without raw graph or record fetches. Control-plane `run.graph.get` and `run.introspection.list` now expose return-state summaries for full graphs, event payloads, run records, raw run events, introspection payloads, option limits, node counts, event counts, and status/event-type counts so clients can tell when deeper internals were requested; both methods redact sensitive payload, run-record, raw-event, and introspection values before returning those optional internals. Control-plane `sessions.active` now exposes active-run cleanup summaries, and `sessions.list`, `sessions.active.list`, and `session.detail` now expose session summaries with sensitive preview and raw run-internal redaction, and `sessions.patch` exposes patch-key cleanup summaries, and `sessions.reset`/`sessions.delete` expose session cleanup summaries and keep full prompt/answer text behind explicit `includeFullText` opt-in. Control-plane `sessions.compact` now exposes compaction result cleanup summaries without echoing custom compaction summary text. Control-plane `sessions.preview` now marks truncated previews and redacts sensitive preview values, direct `send` acknowledgements expose delivery cleanup summaries without message content, `chat.send` exposes prompt-cleanup submission summaries, and `chat.history` now exposes summary/cleanup metadata with sensitive preview redaction when full text is disabled, and `chat.abort` exposes target/dispatch cleanup summaries, `talk.mode` exposes audio/transcript cleanup summaries, optional bounded preview mode, and real `beforeId` pagination. Control-plane `tts.providers` now exposes provider-count, available-provider, provider-id, voice-count, and cleanup summaries without credential values, secret values, or raw provider errors. Control-plane `agent` now exposes submission summaries with queue mode, prompt byte count, override presence, and prompt-cleanup flags, while `agent.wait` exposes answer byte count and error-state summaries without echoing prompt text and redacts sensitive answer/error values. Control-plane `agent.identity.get` now exposes capability-count, enabled-capability, profile-presence, and cleanup summaries without credentials or secret values. Control-plane `agent.progress` now exposes todo, feature, checkpoint, next-action count, and overall-percentage summaries without next-action content, prompt text, message bodies, credentials, or secret values. Control-plane `agents.files.list/get/set` now expose file count, type, size, content-return, and content-cleanup summaries for agent file/profile operations. Control-plane `logs.tail` now exposes normalized filters, level counts, and cleanup flags while preserving the log array with sensitive key and inline credential-pattern redaction. Control-plane `introspection.snapshot` now exposes section counts, include flags, run counts, harness counts, filters, and cleanup summaries for consolidated operator views. Control-plane `events.subscribe`, `events.unsubscribe`, and `events.subscriptions.list` now maintain per-WebSocket subscription state, report topic/run/session summaries, and expose cleanup flags without returning payloads, message bodies, credentials, or secret values. | Green for core support; Partial for new parity surfaces | P1. Add support-bundle and `/ops` coverage for every new worker surface, including live media delivery results once provider workers land. |
| Observability/support addendum | Shared channel and launch gate status | `LemonCore.Doctor.ChannelReadiness` now backs support-bundle `channel_readiness.json`, control-plane `channels.status`, source-wrapper `./bin/lemon channels`, Web `/ops` Channel Config launch-gate counts, and doctor `channels.readiness` with Telegram/Discord launch-gate status, safe reason kinds, and copy-ready next actions, including Discord slash client-click wait mode, without bot tokens, secret names, chat/channel/guild ids, message bodies, raw proof paths, or raw proof details. `LemonCore.Doctor.ProofLaunchGates` now backs the shared proof-gate view used by `proofs.status`, Web `/ops`, `readiness.status`, and support-bundle `readiness_summary.json` for Discord DM, Discord slash registration, Discord slash client-click, provider media, and terminal backend launch gates. `LemonCore.Doctor.ReadinessSummary` now backs `mix lemon.readiness`, `./bin/lemon readiness`, control-plane `readiness.status`, Web `/ops` Launch Readiness, and support-bundle `readiness_summary.json` with the compact doctor/channel/media/proof rollup used for launch triage. | Green for redacted support surface | P0 gates still need live Discord DM, client-click, and provider-media proof before broad Discord/media claims. |
| Packaging/release/update | Hermes has install scripts, native Windows beta installer, `hermes update`, Docker, Nix, PyPI, and broad install docs. | Lemon has release workflow, local artifact proofs, checksum verifier, versioning/channel docs, `./bin/lemon update` and `mix lemon.update` as stage-1 local maintenance paths, `scripts/verify_source_install` proof for the source wrapper setup/channels/config/doctor/send/media/models/providers/policy/proofs/readiness/secrets/skill/usage/update command family, a non-publishing Python CLI package check that builds the `lemon-cli` wheel and source distribution with `uv`, and `update.run` version/check-only/apply summaries with cleanup flags that exclude download URLs, checksums, downloaded bytes, credentials, and secret values. Remote binary update and PyPI publishing remain outside initial scope. | Partial | P1. Keep install claims scoped or build update/install parity intentionally; decide separately whether `lemon-cli` should be published to PyPI. |
| Testing/evals | Hermes has a large pytest suite, stress tests, plugin/provider tests, website tests, smoke tests, history checks, PyPI publishing checks, and CI supply-chain workflows. | Lemon has `scripts/test fast/quality/clients/eval-fast/live-eval/smoke`, deterministic evals, product smoke, live Telegram scripts, Discord matrix proof, a detection-only OSV Scanner workflow over first-party Mix, npm, and uv lockfiles with SARIF upload, a PR-only History Check workflow that rejects unrelated-history branches with no common ancestor with the target base branch, and a Python CLI workflow that runs `uv sync --locked --dev`, ruff, pytest, wheel build, and source distribution build for `clients/lemon-cli`. The opt-in live-eval lane now includes `live_model_coding_repair_contract`, which requires a provider-backed model to read a failing Elixir fixture, patch source, run the test command, and answer only after the test passes. | Partial | P1. Add release-candidate suites for browser/media/checkpoint/API/terminal/plugin/goal/kanban/LSP as they land, run the expanded live-eval lane against release-candidate providers, triage OSV findings before release, and decide whether Lemon should publish a PyPI-style CLI package. |
| Research/RL/simulations | Hermes has batch trajectory generation, trajectory compression, RL tools, and research-ready positioning. | Lemon has `lemon_sim`, `lemon_sim_ui`, and a separate simulation mission. | BEAM parity target | P2/P1. Use LemonSim as the differentiated BEAM-native research path before claiming RL parity. |

Event subscription delivery addendum: Slice 264 turns the `events.subscribe`
state from introspection-only into actual WebSocket delivery filtering. The
control plane now keeps legacy all-event delivery for new connections, supports
explicit filtered delivery for static event families including goals plus
`run:*` and `session:*`, registers dynamic run/session bus topics through
reference-counted `EventBridge` subscriptions, and makes clear-all unsubscribe
suppress later frames for that connection. Slice 265 also bounds
`events.ingest` at the API boundary with payload-object validation, target-topic
validation, protocol schema coverage, and summary/cleanup responses that do not
echo external payloads. Slice 267 completes the matching fanout path for
ingested custom, metrics, and log events by advertising metrics/log WebSocket
events and preserving target-derived `runId` / `sessionKey` fields for
subscription filtering. Slice 268 applies the same bounded event-boundary shape
to the admin `system-event` method: payload-object validation, target-topic
validation, schema support for `eventType` or `event_type`, and summary/cleanup
responses without echoing payloads.

Provider-media routing diagnostic note: provider-prefixed OpenAI-compatible
routing is intentionally limited to `media_analyze_image` and the media vision
proof path for now. The image, TTS, STT, and video proof scripts report
`provider_prefixed_model_not_supported_for_media_type` when called with
`provider:model`; compatible endpoint proof for those OpenAI-shaped media
endpoints should use `--base-url` with an unprefixed model until live proof
promotes broader routing.

Provider-backed video media note: `media_generate_video` now includes
`vertex_veo` through Google Vertex AI Veo long-running prediction in addition
to `openai_video`; the video proof lane can be satisfied by either provider,
but the current Vertex Veo proof is blocked by
`vertex_veo_create_http_error:permission_denied`.

Provider-backed voice media note: `media_generate_speech` now includes
`elevenlabs_tts` and `google_tts` provider paths, and `media_transcribe_audio`
now includes a `deepgram_transcribe` provider path on the same BEAM media supervisor. The
Deepgram live STT proof completed on 2026-05-17 at
`.lemon/proofs/media-transcription-smoke-latest.json`, so provider-backed media
is now 2/5 complete with STT and vision current. ElevenLabs TTS reached the
worker through the corrected ElevenLabs default voice id, but remains blocked
by redacted `elevenlabs_tts_http_error:payment_required` proof evidence; the
current Google TTS proof reaches Cloud Text-to-Speech but is blocked by
`google_tts_http_error:permission_denied`.

Discord operator diagnostics now include the live promotion gates directly in
`mix lemon.doctor`: config, deterministic slash, and restart/reconnect replay
proof pass, Discord free-response is live-proven, and DM plus real slash client-click remain explicit
warnings until the corresponding live proof artifacts promote them.
Free-response diagnostics now also separate Lemon runtime intent setup from the
external Discord app setting: Lemon reports that it requests the Discord
`message_content` gateway intent, while `message_content_intent_declared`
is the operator's redacted declaration that the privileged Developer Portal
setting is enabled.

Media operator diagnostics now follow the same rule. `mix lemon.doctor` reports
`media.channel_delivery` separately from `media.provider_live`: Telegram and
Discord generated-media/audio delivery are proof-backed, provider-backed STT and
vision are proof-backed, and image, TTS, and video remain explicit
provider-proof warnings until the opt-in live credential/quota proofs pass. The
provider smoke scripts write stable `lemon.media_*_smoke` proof objects,
`media_provider` proof scope, per-provider check names, and redacted skipped
credential-preflight artifacts so `proofs.status`, support bundles, and Web
`/ops` can show the exact promotion state without raw prompts, bytes, paths, or
provider responses. The final readiness audit now also prints bounded
provider-media `reason_kind` labels for incomplete proof artifacts, so release
operators see the safe failure class while the audit still blocks raw provider
responses and media payloads.

The same smoke scripts now also support a deterministic `--local` lane. The
2026-05-17 run completed `local_svg`, `local_wav`, `local_transcript`,
`local_vision`, and `local_mp4`, writing separate
`media-*-local-smoke-latest.json` artifacts with `proof_scope: media_local`.
That raises regression confidence for the BEAM-supervised media workers and
tool registry breadth, but it is not provider-backed parity and does not satisfy
the release audit's image, TTS, STT, vision, or video provider gate.

## Implementation Launch Order

This is the recommended order for turning the matrix into code. Each slice must
include docs, tests, and proof before it moves from preview to stable.

1. **Browser Worker Vertical Slice**
   - Started: `clients/lemon-browser-node` is used through
     `LemonBrowser.LocalServer`, an OTP-supervised local driver.
   - Started: navigate/snapshot/content/click/type/press/scroll/back/screenshot
     tools are default built-ins behind tool policy.
   - Started: screenshots are stored as local artifacts instead of model-facing
     base64.
   - Done: browser tools emit channel-safe `current_action` progress updates
     that flow through the existing tool-status pipeline without raw URLs,
     selectors, typed text, cookies, page text, screenshot bytes, or artifact
     paths.
   - Started: `/ops` renders local browser driver status and recent artifact
     metadata; support bundles include redacted browser diagnostics.
   - Done: artifact cleanup metadata reports counts, bytes, oldest/newest
     timestamps, and managed 14-day / 100-file retention policy without
     embedding screenshot bytes.
   - Done: deterministic local-page proof drives the browser tool boundary
     through the OTP-supervised local server.
   - Done: `scripts/live_browser_smoke.exs` runs one live local browser smoke
     proof with screenshot artifact, cookie set/get, clear-state reset, and
     redacted proof JSON.
   - Done: `browser_screenshot includeImage: true` returns an opt-in
     model-visible screenshot image block while default results and support
     bundles remain metadata-only.
   - Done: `browser_analyze` composes managed screenshot capture with
     `media_analyze_image` for one-step browser vision, covered by focused
     wrapper tests and `scripts/live_browser_smoke.exs`.
   - Done: `browser_get_cookies`, `browser_set_cookies`, and
     `browser_clear_state` expose cookie inspection with default value
     redaction, cookie seeding, and session-state reset controls through the
     BEAM tool boundary.
   - Done: `browser_upload_file` exposes project-local file-input automation
     through the browser worker's `browser.setInputFiles` method, with
     BEAM-side path validation, out-of-project rejection, dangerous/external
     policy gating, redacted selector/path progress, focused wrapper tests, and
    `scripts/live_browser_smoke.exs` proof.
   - Done: `browser_download` exposes supervised download automation through
     the browser worker's `browser.download` method, with optional selector
     click, Playwright download-event waiting, managed project-local output,
     out-of-project output rejection, dangerous/external policy gating,
     redacted selector/path progress, focused wrapper tests, browser-node tests,
     and `scripts/live_browser_smoke.exs` proof.

2. **Checkpoint/Rollback Vertical Slice**
   - Started: checkpoint creation before write/edit/patch when a session id is
     present.
   - Started: `checkpoint` tool supports list, diff preview, per-file/full
     restore, and delete.
   - Started: checkpoint create/restore/delete events are recorded through
     introspection and broadcast on run/session event streams for live operator
     visibility.
   - Done: `checkpoint.status`, Web `/ops`, Telegram/Discord `/checkpoint`,
     and support bundles expose redacted checkpoint metadata without file
     contents, raw paths, or raw session ids; channel checkpoint output remains
     redacted.
   - Done: `exec` accepts configured `checkpoint_paths`, detects destructive
     shell commands, snapshots those file paths before launch through the
     existing filesystem checkpoint store, and returns checkpoint metadata for
     restore. Focused proof passed with `98 tests, 0 failures` across
     `exec`/`process`/`ProcessManager`.
   - Done: `checkpoint.diff` and `checkpoint.restore` expose shared
     control-plane preview/restore operations with session ids hashed in
     responses. Focused proof passed with `35 tests, 0 failures` in the
     optional parity method lane.
   - Done: shared checkpoint storage and filesystem rollback moved to
     `LemonCore.Checkpoint`, and the control-plane diff/restore methods now call
     core directly. Direct core proof passed with `3 tests, 0 failures`; the
     focused control-plane checkpoint/introspection lane passed with `43 tests,
     0 failures`.
   - Done: TUI `/checkpoint diff` and `/checkpoint restore` call those
     control-plane methods. Focused client proof passed with `163 tests, 0
     failures` plus a successful `npm run build`.
   - Done: Web `/ops` exposes copy-ready TUI/control-plane diff and restore
     commands per recent checkpoint through redacted core diagnostics. Focused
     Web/core proof passed with `25 tests, 0 failures`.
   - Done: Web `/ops` exposes direct diff preview and restore-all actions backed
     by `LemonCore.Checkpoint`. Focused Web proof passed with `25 tests, 0
     failures`.
   - Done: Telegram/Discord `/checkpoint` now expose redacted status, redacted
     diff counts, and direct restore actions through `LemonCore.Checkpoint`;
     Telegram requires `/checkpoint restore <id> confirm`, and Discord requires
     the restore slash-command `confirm` boolean. Focused channel proof passed
     with `11 tests, 0 failures`.
   - Done: `scripts/live_discord_matrix.py --bot-token-index 0
     --register-checkpoint-slash-command` and follow-up
     `--check-checkpoint-slash-registration` passed against Discord's live API
     for Zeebot command id `1505032304920367356`, version
     `1505053780025147463`, including status/events/diff/restore subcommands and the
     required restore `confirm` boolean.
   - Done: `scripts/live_telegram_matrix.py --skip-dm --skip-topic
     --topic-checkpoint --checkpoint-topic-id 35 --timeout 120 --result-path
     tmp/telegram-checkpoint-proof.json` passed on 2026-05-15, proving live
     Telegram checkpoint diff/restore in topic `35`, local file restoration,
     and redacted chat output with no raw path/content/session leak.
   - Done in deterministic proof: Discord checkpoint restore/events payload
     decoding now flows through
     `LemonChannels.Adapters.Discord.Transport.slash_command_args_for_interaction/1`
     and is covered by `scripts/live_discord_slash_interaction_proof.exs`.
   - Add real Discord client-click restore proof before broad slash-command
     parity and before stable checkpoint parity.

3. **Telegram/Discord Broadening**
   - Telegram: media delivery and optional voice paths only after media jobs
     exist.
   - Discord: DM, live free-response channel proof, real client-click
     command/component tests, richer media, and voice tests.
   - Keep unsupported non-Telegram/Discord channels out of parity scope.

4. **Media Jobs**
   - Keep image analysis, image generation, TTS/STT, and video as supervised jobs.
   - Route provider config through existing secrets/config systems.
   - Run live provider proofs under usable quota.
   - Deliver artifacts through Telegram/Discord with live proof.

5. **API/Editor Adapter Layer**
   - Done in preview: OpenAI-compatible health, capabilities, models, Chat
     Completions, and Responses endpoints over the control-plane HTTP router.
   - Done in preview: synchronous wait through `agent.wait`, completed answer
     mapping, and wait timeout handling.
   - Done in preview: redacted run status and run cancellation dispatch.
   - Done in preview: opt-in bearer and `x-api-key` auth.
   - Done in preview: Chat Completions and Responses SSE over Lemon run bus
     events.
   - Done in preview: redacted tool-progress SSE from Lemon `:engine_action`
     events without raw tool args/results.
   - Done in preview: stored response retrieval over `resp_<run_id>` and
     `previous_response_id` continuity on the prior Lemon session key.
   - Done in preview: redacted image input normalization with hashed URL/file-id
     references and data URL image pass-through into runtime-only Lemon image blocks.
   - Done in preview: deterministic live HTTP smoke through a real `:httpc`
     client and redacted proof JSON.
   - Done in preview: external Node `fetch` client proof through
     `scripts/live_openai_compat_fetch_client.mjs`
   - Done in preview: official OpenAI Node SDK client proof through
     `scripts/live_openai_compat_openai_sdk_client.mjs`.
   - Done in preview: provider-backed OpenAI-compatible vision smoke through
     OpenRouter `openai/gpt-4o-mini`, including an external Node `fetch`
     client and official OpenAI Node SDK vision sub-proof through the same local
     `/v1/responses` boundary.
   - Next: deployed editor UI compatibility proof plus provider-specific image transport hardening beyond the passing OpenRouter vision proof.
   - Done in preview: ACP initialize/session lifecycle/prompt/cancel/close/list/resume plus official `session/load` alias over the same adapter layer rather than a separate runtime path.
   - Done in preview: newline-delimited JSON stdio packaging through `scripts/lemon_acp_stdio.exs`.
   - Done in preview: stdio prompt waits emit `session/update` notifications from Lemon run bus text deltas and redacted tool-progress events.
   - Done in preview: ACP stdio `initialize` records safe client filesystem
     capability booleans and carries them into sessions, `session/list`,
     prompt responses, and Lemon run metadata for file-tool routing gates.
   - Done in preview: stdio prompt waits can round-trip ACP agent-to-client `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `fs/delete_file`, and `fs/rename_file` requests through a spawned external Node client, with redacted proof showing 9 completed checks and 6 client requests.
   - Done in preview: matching `LemonCore.ExecApprovals.request/1` events for the ACP session key bridge to ACP `session/request_permission` and resolve the blocked approval from the selected ACP option.
   - Done in preview: model-facing `read`, `write`, `edit`, and `patch` add/update/delete/move operations can route through ACP filesystem requests when session metadata records matching client filesystem support.
   - Done in preview: `scripts/live_acp_official_sdk_client.mjs` proves official `@zed-industries/agent-client-protocol@0.4.5` `ClientSideConnection` compatibility for initialize, session new/load/cancel, queued and waited prompts, session updates, permission requests, read/write filesystem callbacks, unsupported-image rejection, and redacted proof output with 8 completed checks. Next: deployed editor UI proof before claiming stable editor parity.

6. **Terminal Backend Layer**
   - Done in preview: shared backend behavior, local runner metadata,
     local PTY execution via `script(1)`, optional Docker CLI container
     execution with cwd mounting, no implicit image pulls, dropped
     capabilities, no-new-privileges, read-only root filesystem by default,
     bounded `/tmp` tmpfs scratch space, and default resource/network policy,
     optional OpenSSH execution when `LEMON_SSH_TERMINAL_TARGET` is configured,
     backend allow/deny policy, optional Docker image allowlists, optional SSH
     target allowlists exposed only as redacted policy metadata, and
     backend-specific approval requirements for the `exec` tool.
   - Done in preview: `scripts/live_terminal_backend_smoke.exs` writes hashed
     proof JSON after running a redacted command through every available
     backend; the latest run completed `local`, `local_pty`, `docker`, and loopback `ssh`,
     skipped zero backends, and failed zero backends.
   - Done in preview: finished processes can be manually restarted through the
     `process` tool as fresh supervised children with restart lineage while
     preserving the original process record.
   - Done in proof: `scripts/live_terminal_process_smoke.exs` writes redacted
     proof JSON for local process completion, bounded-log metadata, manual
     restart lineage, restarted completion, and cleanup; latest run completed 5
     checks with zero failures and zero skips.
   - Harden SSH/Docker with logs, richer resource limits,
     and support diagnostics.

7. **Goals and Kanban**
   - Started: durable per-session goal state exists in `LemonCore.GoalStore`
     with lifecycle events and support-bundle diagnostics.
   - Started: `goal.set`, `goal.status`, `goal.pause`, `goal.resume`,
     `goal.continue`, `goal.loop.once`, `goal.clear`, TUI `/goal`, Telegram
     `/goal`, and Discord `/goal` expose redacted status/set/pause/resume/clear
     controls; the TUI can submit one supervised continuation and one preview
     judge tick through the control plane.
   - Started: Web `/ops` exposes redacted goal counts and recent goal metadata
     without objective text or raw session IDs.
   - Started: judge-model routing, autonomous loop scheduling, full budget
     policy, fail-safe tests, and production-shaped router judge proof.
   - Started: production-shaped persisted-auto scheduler proof through the
     router judge path.
   - Done: provider-backed live model judge proof passed against Z.ai
     `glm-5-turbo`.
   - Started: `LemonCore.KanbanStore` persists boards, columns, tasks,
     dependencies, comments, assignees, worker profiles, session/run links,
     lifecycle events, expiring leases, and redacted support-bundle
     diagnostics.
   - Started: control-plane `kanban.board.create`, `kanban.board.list`,
     `kanban.board.get`, `kanban.board.archive`, `kanban.task.create`,
     `kanban.task.update`, and `kanban.task.comment` expose the durable board
     foundation with board/task/status/count summaries that explicitly mark
     returned titles, descriptions, comments, metadata, session keys, and run
     ids.
   - Started: `LemonAutomation.KanbanDispatcher` leases dependency-unblocked
     tasks, reclaims expired leases, runs worker modules under supervision, and
     records completion/failure back into durable task state.
   - Started: control-plane `kanban.dispatcher.start`,
     `kanban.dispatcher.status`, and `kanban.dispatcher.stop` expose the
     dispatcher to operators with running state, worker, concurrency, and
     cleanup summaries.
   - Started: default `KanbanRunWorker` turns a leased task into a
     `LemonRouter` run request with `origin: :kanban`, board/task provenance,
     isolated per-task git worktree cwd when available, and blocked recursive
     kanban tooling.
   - Started: default coding-agent tools now include `kanban`, an action-based
     model-facing board/task tool backed by `LemonCore.KanbanStore`.
   - Started: Web `/ops` exposes redacted board/task status, counts, leases,
     worker metadata, columns, and workspace hashes.
   - Started: TUI `/kanban` exposes board list/create/show/archive, task
     create/update/comment, and dispatcher start/status/stop controls over the
     control-plane API.
   - Started: Telegram `/kanban` and Discord `/kanban` expose redacted
     board/task/archive/dispatcher controls over the same durable board state.
   - Done: Telegram topic live proof passed for create/task/comment/show/archive
     redaction in topic `35`.
   - Started: dispatcher coverage now proves bounded multi-worker leasing,
     completion, explicit failure, crashed-worker failure marking, and
     expired-lease reclaim.
   - Done: production-shaped dispatcher coverage now drives the real
     `KanbanRunWorker` with router/waiter stubs under bounded concurrency.
   - Done: provider-backed live dispatcher proof passed against Z.ai
     `glm-5-turbo`, proving three durable tasks through real
     `KanbanRunWorker`/router/waiter execution with dispatcher
     `running_count: 2`, completed run ids, and cleared leases.
   - Done: Discord API registration proof passed for the in-repo `/kanban`
     slash-command schema with all expected subcommands and options.
   - Done in deterministic proof: Discord kanban task-create, task-update,
     comment, board, archive, dispatch-start, dispatch-status, and
     dispatch-stop payload decoding now flows through the same runtime decoder
     used by the handler, and the proof writes
     `.lemon/proofs/discord-slash-interaction-proof-latest.json`.
   - Done in deterministic proof: Discord outbound and interaction-response
     paths set `allowed_mentions` to an empty parse list with `replied_user:
     false`, and `scripts/live_discord_safe_mentions_proof.exs` writes
     `.lemon/proofs/discord-safe-mentions-proof-latest.json`.
   - Done in deterministic proof: Discord approval components now resolve
     pending `LemonCore.ExecApprovals` requests using core's expected atom
     decisions, and `scripts/live_discord_approval_component_proof.exs` writes
     `.lemon/proofs/discord-approval-component-proof-latest.json`.
   - Done in deterministic proof: Discord cancel and watchdog keepalive buttons
     route through `LemonChannels.Runtime` / `LemonCore.RouterBridge`, and
     `scripts/live_discord_runtime_components_proof.exs` writes
     `.lemon/proofs/discord-runtime-components-proof-latest.json`.
   - Done in deterministic proof: duplicate Discord `MESSAGE_CREATE` events are
     marked seen before debounce flush and after simulated transport restart
     with an empty in-memory buffer and cleared ETS table, submitting only one
     Lemon run through the runtime path;
     `scripts/live_discord_dedupe_proof.exs` writes
     `.lemon/proofs/discord-dedupe-proof-latest.json`.
   - Done in deterministic proof: Discord `/trigger all` enables unmentioned
     free-response group messages, and `/trigger mentions` restores suppression;
     `scripts/live_discord_trigger_mode_proof.exs` writes
     `.lemon/proofs/discord-trigger-mode-proof-latest.json`.
   - Add real Discord client-click proof before claiming broad slash-command
     parity.

8. **LSP Semantic Diagnostics**
   - Done: first BEAM-preview diagnostic runner landed as the model-facing
     `lsp_diagnostics` tool.
   - Done: `write`, `edit`, and `patch` can opt into post-edit baseline/delta
     diagnostics without failing when a checker is missing.
   - Done: supervised sessions now have `lsp.server.initialize` and capture
     redacted `textDocument/publishDiagnostics` notification counters plus `textDocument/diagnostic` pull-response capture.
   - Done: request timeouts now terminate unhealthy sessions and their launcher
     descendants instead of leaving stuck language-server processes alive.
   - Done: supervised sessions now send `textDocument/didOpen`,
     `textDocument/didChange`, and `textDocument/didClose` notifications while
     status keeps only URI hashes, versions, byte counts, and counters.
   - Done: JavaScript syntax, Python clean/error, TypeScript no-tsconfig skip,
     TypeScript tsconfig diagnostics, Go workspace diagnostics, Rust workspace
     diagnostics, and C compiler diagnostics now cover non-Elixir diagnostics
     behavior.
   - Done: `docs/tools/lsp.md` now documents local checker installs,
     language-server installs, override env vars, ElixirLS launcher support,
     timeout cleanup, control-plane methods, and
     proof lanes.
   - Done: `scripts/live_lsp_server_smoke.exs` proves real supervised stdio
     sessions through initialize, document open, redacted `publishDiagnostics`
     capture, and proof JSON; `--servers pyright,gopls,clangd,rust_analyzer,typescript_language_server,elixir_ls --editor-flow` passed locally with
     `completed_count: 6`, `failed_count: 0`, diagnostics reintroduced and
     cleared a second time, and documents closed for every server.
   - Done: `--project-fixtures` now runs multi-file temporary project fixtures
     with root markers and companion files for all six local language servers;
     the 2026-05-17 proof completed all six editor-flow checks with
     `failed_count: 0` and safe `lsp_project_fixtures_smoke` inventory
     metadata.
   - Done: `--real-repo-fixtures` copies or uses maintained Lemon repository
     fixtures for Python, Go, C, Rust, TypeScript, and Elixir in isolated
     temporary projects, injects breakage, repairs it, reintroduces diagnostics,
     repairs again, and closes documents through real `pyright`, `gopls`,
     `clangd`, `rust_analyzer`, `typescript_language_server`, and `elixir_ls`
     sessions. The 2026-05-17 proof completed all 6 editor-flow checks with
     `failed_count: 0`, safe `lsp_real_repo_fixtures_smoke` inventory metadata,
     source hashes only, and cleanup flags false for raw paths, file contents,
     diagnostics output, raw session ids, and server I/O.
   - Next: add broader editor integration and operational promotion lanes before
     stable parity.

9. **Plugin and Provider Ecosystem**
   - Turn Lemon extensions/MCP/skills into a coherent capability-host story.
   - Done in preview: code-free plugin manifests, explicit extension execution
     trust policy, extension memory-provider registration, provider routing,
     fallback, credential pools, redacted support-bundle/Web diagnostics,
     BEAM/WASM/MCP/external host-runtime/degraded-startup summaries, BEAM
     extension-host telemetry proof, WASM wrapper/policy proof, and code-free
     registry install/update audit proof.
   - Next: add full marketplace hosting, sandbox execution breadth, stronger
     hook telemetry, and external hosted plugin proofs.

10. **Release/Website Support**
    - Update `docs/support.md`, `docs/compare.md`, release notes, screenshots,
      and readiness audits every time a surface moves from preview to stable.

## Acceptance Rule

A parity slice is not complete until:

- the feature has a user-facing doc
- the feature has deterministic tests
- the feature has live proof when it depends on provider/browser/channel
  behavior
- the feature appears in `/ops` or another first-party observability surface
- support bundles include enough redacted metadata for triage
- public support docs say whether the feature is stable or preview
- the feature can fail without taking down the BEAM runtime
