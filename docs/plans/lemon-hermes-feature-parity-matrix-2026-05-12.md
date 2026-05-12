# Lemon ↔ Hermes Feature Parity Matrix

Status: active audit ledger

Last reviewed: 2026-05-12

## Purpose

This document is the source-grounded feature matrix required by the Lemon 1.0
mainstream readiness plan. It compares Lemon against the refreshed upstream
Hermes baseline available at `/home/z80/dev/hermes-agent` `origin/main` and
classifies launch-relevant gaps by what a user can actually experience.

This is stricter than the older harness scorecard. The scorecard proves many
agent-loop contracts. This matrix decides whether Lemon can credibly match
Hermes as a product and daily-use agent system.

## Source Snapshot

Hermes source evidence used for this pass:

- `/home/z80/dev/hermes-agent` `origin/main` at `dd0923bb8`
- `README.md`
- `AGENTS.md`
- `website/docs/reference/tools-reference.md`
- `website/docs/reference/slash-commands.md`
- `website/docs/user-guide/features/tools.md`
- `website/docs/user-guide/features/memory.md`
- `website/docs/user-guide/features/skills.md`
- `website/docs/user-guide/features/mcp.md`
- `website/docs/user-guide/features/cron.md`
- `website/docs/user-guide/features/acp.md`
- `website/docs/user-guide/features/api-server.md`
- `website/docs/user-guide/checkpoints-and-rollback.md`
- `website/docs/user-guide/features/built-in-plugins.md`
- `website/docs/user-guide/messaging/telegram.md`
- `website/docs/user-guide/messaging/discord.md`
- `gateway/platforms/telegram.py`
- `gateway/platforms/discord.py`
- `hermes_cli/security_advisories.py`
- `.github/workflows/osv-scanner.yml`

Lemon source evidence used for this pass:

- `docs/plans/lemon-1.0-mainstream-readiness.md`
- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`
- `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md`
- `docs/plans/lemon-1.0-interface-supportability-audit-2026-05-11.md`
- `apps/coding_agent/lib/coding_agent/tools.ex`
- `docs/testing.md`
- `docs/skills.md`
- `docs/user-guide/skills.md`
- `docs/user-guide/memory.md`
- `docs/support.md`
- `docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md`

## Status Legend

- `Green`: Lemon has comparable user-visible capability and proof for the 1.0
  boundary.
- `Partial`: Lemon has meaningful implementation, but proof or user-visible
  breadth is weaker than Hermes.
- `Open`: Lemon lacks a comparable stable feature or proof.
- `Deferred`: intentionally outside stable 1.0, only acceptable with explicit
  public support language.

## P0 Launch Blockers and Guardrails From This Matrix

1. Run the direct Discord live matrix for its intended stable boundary, including
   DM/channel/thread routing, mention/free-response behavior, session isolation,
   approvals where supported, cancellation, restart/reconnect, duplicate
   avoidance, markdown/code rendering, long output, tool success/failure, and
   file delivery. `scripts/live_discord_matrix.py` now provides discovery,
   bot-API diagnostic, non-bot inbound wait, and manual-matrix modes for exact
   prompt/reply, markdown/code, long-output, tool success/failure, and file
   delivery checks; only real non-bot inbound modes can close this blocker.
2. Keep the direct Telegram live matrix green for the stable text-first plus
   document-delivery boundary. Fresh 2026-05-12 DM and forum-topic probes passed
   after fixing interrupted-session restore, `scripts/live_telegram_matrix.py
   --timeout 90` repeats that base proof, the topic-isolation runner passed
   overlapping runs across topics `35` and `16456`, and the topic-cancel runner
   proved bare `/cancel` aborts a long-running tool call inside topic `35`
   without a late success reply. The tool-rendering runner proved successful and
   intentionally failing shell tool-status rendering plus Markdown/code-block
   entities inside topic `35`. The topic-approval runner proved real Telegram
   approval-button resolution in topic `35`. The topic-long-output runner proved
   chunking for a combined 9,409-character reply in topic `35`, and the
   topic-file-get runner proved document delivery in topic `35`. The
   restart/dedupe runner proved a handled topic message was not replayed after a
   runtime restart and that a fresh post-restart prompt still worked.
3. Keep browser automation, vision, image generation, TTS, and rich media
   delivery out of stable 1.0 launch claims unless a later release note promotes
   a narrower proven path. `docs/support.md` and `docs/compare.md` already mark
   these as preview or unsupported for 1.0.
4. Keep Hermes-style multi-backend terminal execution out of the stable 1.0
   comparison. Lemon's 1.0 shell boundary is local-first source/release-runtime
   operation, not Docker/SSH/container-backend parity.
5. Keep current upstream-only surfaces outside stable 1.0 claims unless
   explicitly promoted later: ACP editor integration, OpenAI-compatible API
   server behavior, automatic checkpoint rollback, Hermes-style built-in plugin
   breadth, external memory providers, and supply-chain advisory parity.

## Matrix

| Area | Hermes evidence | Lemon evidence | Status | Launch action |
| --- | --- | --- | --- | --- |
| Install and setup | README advertises one-line install, Linux/macOS/WSL2/Termux support, `hermes setup`, `hermes model`, `hermes gateway setup`, `hermes doctor`, and `hermes update`. | Lemon has source setup, `mix lemon.setup`, `mix lemon.doctor`, local release proofs, and Linux `x86_64` tarball scope in the readiness plan and support docs. | Partial | P1 unless launch claims match Hermes install breadth. Keep Linux/source scope honest or add a one-line installer and broader OS proof. |
| Provider/model switching | README says Hermes supports Nous Portal, OpenRouter, NVIDIA NIM, Xiaomi MiMo, z.ai/GLM, Kimi, MiniMax, Hugging Face, OpenAI, custom endpoints, and switching with `hermes model`. Slash docs expose `/model`, custom providers, fast mode, reasoning, and global persistence. | Lemon supports multiple engines/providers through `apps/ai`, setup docs, config/secrets, gateway engines, and live-eval env knobs. `scripts/test live-eval` passed against a real Z.ai `glm-5-turbo` provider on 2026-05-12 with 31 checks passing and 0 failing. | Green for release-candidate provider proof; Partial for Hermes provider breadth | P1 for broader provider-switching parity unless public launch claims broad Hermes-like provider coverage. Keep the provider-backed live-eval lane green for release candidates. |
| CLI/TUI | Hermes README and AGENTS describe a full TUI with multiline editing, autocomplete, history, interrupt/redirect, streaming tool output, session picker, approvals, and slash command dispatch. | Lemon TUI proof covers source-runtime echo, rendered tool failure, stats, overlays, and cancellation. | Partial | P1: keep TUI proof green; compare slash-command breadth if Lemon markets CLI parity. |
| Editor/API integration | Current Hermes docs expose ACP editor integration for VS Code, Zed, and JetBrains, plus an OpenAI-compatible API server with Chat Completions, Responses, streaming, tool progress, image input, and named conversations. | Lemon has a JSON-RPC control plane, Web UI, TUI, and `lemon_mcp`, but no ACP server or OpenAI-compatible Chat Completions/Responses API equivalent in the 1.0 support boundary. Public support/compare docs explicitly exclude ACP and OpenAI-compatible API server behavior from stable 1.0 claims. | Deferred for stable 1.0 | Do not market editor/API backend parity for 1.0. Reopen only if release notes promote this surface. |
| Slash commands | Hermes slash reference lists session, config, tools/skills, browser, cron, memory/session, voice, debug, update, restart, approvals, and dynamic skill commands across CLI and messaging. | `docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md` now enumerates Lemon Telegram and Discord command surfaces against Hermes messaging commands. Telegram is sufficient for the stable text-first boundary; Discord remains preview until the non-bot manual matrix passes. Lemon does not claim Hermes drop-in slash-command parity for 1.0. | Partial | P0 only for Discord promotion and accidental public overclaiming. Keep Telegram command live proof green, run the Discord non-bot manual matrix before stable Discord, and do not market unsupported Hermes command areas. |
| Tool registry breadth | Hermes tools reference documents 55 built-in tools across browser, file, terminal, web, memory, session search, skills, cronjob, delegation, code execution, messaging, image generation, TTS, vision, RL, Home Assistant, Feishu, and MCP dynamic tools. | Lemon native coding tools include read, read_skill, skill_manage, memory_topic, search_memory, write/edit/patch, bash, grep/find/ls, webfetch/websearch, todo, task/agent, parent_question, tool_auth, extension status, and X tools. | Partial | P0: decide stable toolset claims. Browser/media/vision/TTS/RL/Home Assistant/Feishu are gaps unless explicitly out of scope. |
| Terminal and process backends | Hermes supports local, Docker, SSH, Singularity, Modal, Daytona, Vercel Sandbox, background process management, PTY, sudo handling, resource controls, and container hardening. | Lemon has `bash` and process tooling through coding agent/runtime, but no equivalent multi-backend terminal surface in stable 1.0. The stable support boundary is local-first source/release-runtime operation. | Deferred for stable 1.0 | Do not claim Docker/SSH/container backend parity for 1.0. Reopen when expanding execution backends. |
| File editing | Hermes has `read_file`, `write_file`, `patch`, `search_files`, fuzzy patching, and guidance against raw shell file reads. | Lemon has read, write, edit, hashline_edit, patch, grep, find, ls, and strong tool lifecycle tests. | Green | Keep deterministic file/tool lifecycle tests green. |
| Checkpoints and rollback | Current Hermes supports opt-in filesystem checkpoints before file tools and destructive terminal commands, `/rollback`, per-file restore, diff preview, and checkpoint store maintenance. | Lemon has normal git/worktree discipline and support bundles, but no first-class checkpoint/rollback feature for agent file mutations. Public support and comparison docs explicitly exclude automatic filesystem checkpointing or rollback from stable 1.0. | Deferred for stable 1.0 | Do not claim comparable destructive-operation recovery for 1.0. Reopen only if automatic checkpointing is implemented and proven. |
| Web search/fetch | Hermes has `web_search` and `web_extract` via configured backends. | Lemon has `websearch` and `webfetch`; support docs mark text web tools stable for reproducible runs. | Partial | Verify provider/backend setup and deterministic support boundary; run live-model or integration proof if launch claims web parity. |
| Browser automation | Hermes has 12 browser tools: navigate, snapshot, click, type, scroll, press, console, images, vision, CDP, dialogs, back. | Lemon has text web tools and `clients/lemon-browser-node`, but browser automation is not first-class stable in the default native harness. Public support/compare docs keep first-class browser automation outside stable 1.0. | Deferred for stable 1.0 | Do not claim browser-tool parity for 1.0. Reopen when browser tools become a supported stable surface. |
| Vision, image generation, TTS | Hermes exposes `vision_analyze`, `image_generate`, and `text_to_speech`, with Telegram/Discord delivery expectations for media and voice. | Lemon support docs mark generated media, image analysis, and TTS/voice preview or out of scope unless promoted. Telegram has text-first plus document-delivery proof, not rich multimodal parity. | Deferred for stable 1.0 | Keep launch claims text-first and document-delivery bounded. Reopen only if multimodal/media behavior is promoted and proven. |
| Memory | Hermes has bounded `MEMORY.md` and `USER.md`, automatic prompt injection, `memory` add/replace/remove, session search, and optional external memory providers. | Lemon stores run memory documents in SQLite, has `search_memory`, `memory_topic`, workspace memory-file inspection evals, secret screening, and memory docs. Live eval now proves prior-work recall, durable memory-topic capture, and workspace memory-file lookup against a real provider. | Green for Lemon 1.0 memory boundary; Partial for Hermes `USER.md`/external-provider semantics | Keep Lemon's memory semantics explicit in docs; broader Hermes-style user-profile/external memory provider parity is post-1.0 unless promoted. |
| Session search | Hermes uses SQLite FTS5 with summarization through `session_search`, and docs distinguish session search from memory. | Lemon `search_memory` covers prior runs and scopes; evals cover prior-work recall. | Green | Keep deterministic and live-model recall evals green. |
| Skills | Hermes skills live under `~/.hermes/skills`, support progressive disclosure, slash commands, external dirs, required env setup, config injection, hub/audit state, agent-managed `skill_manage`, and dynamic skill commands. | Lemon has project/global skills, `read_skill`, `skill_manage`, usage/curation sidecars, audits, curator manager, draft synthesis, registry install/update/remove, MCP integration docs, and strong eval coverage. | Green | Keep skill lifecycle, audit, curator, and live-model skill evals green. |
| MCP | Hermes supports stdio/HTTP MCP servers, prefixed dynamic tools, utility resource/prompt tools, include/exclude filtering, and capability-aware wrappers. | Lemon docs describe MCP server discovery/invocation in `lemon_skills`, config/env/files, conflict precedence, status, validation, and disabling. | Partial | P1: add or verify parity tests for stdio/HTTP, filtering, utility tools, conflict behavior, and degraded startup. |
| Delegation/subagents | Hermes `delegate_task` spawns isolated subagents and supports background sessions. | Lemon has `task`, `agent`, parent questions, run graph, joins, leaf/orchestrator policies, deterministic and live-model delegation evals. | Green | Keep live-model delegation side-effect verification green. |
| Cron/scheduled tasks | Hermes has natural-language cron creation, `/cron`, CLI cron commands, skill-backed jobs, lifecycle actions, origin/local/platform delivery, workdir support, scheduler lock, recursive scheduling guardrail. | Lemon has cron manager, Web ops controls, scheduled prompt contract, prior-run memory, origin delivery, `blocked_tools`, and support docs classify cron preview. | Partial | P1 if cron remains preview. P0 if stable launch claims Hermes-like unattended automations. |
| Messaging platforms breadth | Hermes README advertises Telegram, Discord, Slack, WhatsApp, Signal, CLI, email, and many gateway adapters. | Lemon has Telegram, Discord, X, XMTP, legacy gateway ingress, SMS/voice/email/webhook/farcaster glue, but support docs mark most non-Telegram channels preview. | Partial | P0 for Telegram/Discord chosen stable boundary; P1/deferred for other platforms unless promoted. |
| Telegram DM/group/topic behavior | Hermes Telegram docs support DMs, groups, privacy-mode guidance, admin alternative, home channel, voice messages, files/images, webhook/polling, proxy, and Docker host-visible `MEDIA:` delivery. | Lemon has Telegram adapters, delivery with topic/thread IDs, live proof for a small single-chat path, and support docs for text-first/media boundary. Fresh 2026-05-12 live probes verified DM recovery from an interrupted persisted tool call, group forum-topic routing in Lemonade Stand topic `35`, overlapping topic isolation across topics `35` and `16456`, topic-scoped cancellation of a long-running tool call in topic `35`, successful and failing shell tool-status rendering, Markdown/code-block entities, approval-button resolution in topic `35`, long-output chunking in topic `35`, `/file get` document delivery in topic `35`, and restart/dedupe behavior in topic `35`. `scripts/live_telegram_matrix.py --timeout 90` repeats the base DM/topic proof; topic-isolation, topic-cancel, topic-tool-rendering/markdown, topic-approval, topic-long-output, topic-file-get, and topic-restart/dedupe variants are also available. | Green for text-first + document delivery boundary | Broader media upload/image behavior remains launch-critical only if Lemon claims rich-media parity. |
| Discord DM/channel/thread behavior | Hermes Discord docs define DMs, server mention rules, free-response channels, thread isolation, per-user group sessions, interrupts/concurrency, files, voice, slash commands, intents, and permissions. | Lemon has Discord adapter/support code and send-file tooling, but stable support docs still classify Discord preview and no equivalent live inbound proof is recorded. `scripts/live_discord_matrix.py --list-channels` and `--bot-api-smoke` passed against bot `Zeebot-Debug`, guild `1475727416549969980`, and channel `general` `1475727417372049419`, but this only proves bot API reachability. `apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs` proves the adapter ignores bot-authored messages and webhooks before routing. The runner now has `--manual-matrix` for non-bot exact prompt/reply, markdown/code, long-output, tool success/failure, and file-delivery checks. | Open | P0 if Discord is stable for 1.0. Run `scripts/live_discord_matrix.py --channel-id 1475727417372049419 --manual-matrix --timeout 180` with non-bot user messages, or keep Discord preview. |
| Approvals and safety | Hermes has `/approve`, `/deny`, `/yolo`, command allowlists, DM pairing/security docs, safe mentions for Discord, platform authorization, startup advisory checks for compromised packages, and OSV/dependabot workflows. | Lemon has tool policies, approvals, safety contract, untrusted-boundary evals, support-bundle redaction, Telegram approval callbacks, security docs, docs-tooling audit policy, and fresh live Telegram topic approval proof. Discord mention safety and supply-chain advisory parity need verification. | Partial | P0: prove Discord approvals/safety rendering if Discord is stable. P1: decide whether supply-chain advisory checking is required for 1.0 parity. |
| Observability/support | Hermes has logs, `/debug` upload, profile/home paths, gateway status, doctor, and usage/insights commands. | Lemon has doctor bundles, Web `/ops`, run detail, support bundles, runtime health, logs docs, issue templates, and release audit scripts. | Green | Keep supportability tests green; add live channel run IDs/message IDs to proof packs. |
| Packaging/release/update | Hermes has install script, `hermes update`, release docs, and broad platform install claims. | Lemon has release workflow, local artifact proofs, checksum verifier, versioning/channels, but no public release artifact proof yet. | Partial | Existing release artifact blocker remains; do not treat as parity substitute. |
| Testing/evals | Hermes docs point to a large pytest suite, website tests, and RL/data-generation environments. | Lemon has `scripts/test fast/quality/clients/eval-fast/live-eval/smoke`, deterministic harness evals, product smoke, live Telegram matrix scripts, and a Discord non-bot manual matrix runner. `scripts/test live-eval` passed against a real provider on 2026-05-12. | Partial | P0 remains only for live Discord non-bot proof and public release artifact proof. Keep deterministic, live-model, and live Telegram suites green for release candidates. |
| Research/RL/training | Hermes has Atropos RL environments, batch trajectory generation, trajectory compression, RL tools, and research-ready positioning. | Lemon has `lemon_sim` and eval harnesses, but no equivalent RL training/product claim. | Deferred | Keep out of Lemon 1.0 launch claims unless intentionally promoted later. |
| Plugin/ecosystem | Current Hermes has bundled opt-in plugins, user/project/pip-entrypoint plugin discovery, plugin hooks/tools/slash commands, memory providers, context engines, observability, Spotify, Google Meet, image backends, achievements, and kanban dashboard plugins. | Lemon has skills, extensions docs, MCP, and WASM/extension status tools, but not a public plugin marketplace or comparable built-in plugin suite in the 1.0 support boundary. | Deferred | Keep plugin marketplace and Hermes-style built-in plugin breadth out of 1.0 claims unless intentionally promoted and tested. |

## Immediate Execution Order

1. Run the live Discord proof script against the real bot/channel/thread setup
   with non-bot user messages. Bot API smoke has passed but does not count as
   Lemon inbound proof.
2. Keep the Telegram live matrix green for the text-first plus document-delivery
   boundary; only add rich-media/image upload proof if launch claims expand.
3. Keep ACP/API server parity, automatic rollback, multi-backend terminal
   execution, browser/multimodal tools, and plugin ecosystem breadth outside
   stable 1.0 claims unless a later release note promotes a narrower proven
   path.
4. Update `docs/support.md`, `docs/compare.md`, and release notes only if live
   channel proof or release artifacts promote a surface from preview to stable.
