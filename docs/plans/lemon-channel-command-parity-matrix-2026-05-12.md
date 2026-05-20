# Lemon Channel Command Parity Matrix

Status: active audit ledger

Last reviewed: 2026-05-16

## Purpose

This document closes the command-surface inventory gap from the Lemon 1.0
Hermes feature matrix. It compares Hermes messaging slash commands against the
current Lemon Telegram and Discord channel commands, then classifies what is
stable, preview, explicitly out of 1.0 scope, or still launch-blocking.

It does not claim full Hermes slash-command parity. It defines the supported
Lemon 1.0 command boundary and the proof required before any broader Discord
surface can move out of preview.

## Source Snapshot

Hermes source evidence:

- `/home/z80/dev/hermes-agent` `origin/main` at `4ad5fa702`
- `website/docs/reference/slash-commands.md`
- `website/docs/user-guide/features/goals.md`
- `website/docs/user-guide/features/kanban.md`
- `website/docs/user-guide/messaging/telegram.md`
- `website/docs/user-guide/messaging/discord.md`

Lemon source evidence:

- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/commands.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/command_router.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/file_operations.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/chat_preferences.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/topic_command.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/model_picker.ex`
- `apps/lemon_channels/lib/lemon_channels/goal_status_message.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/discord/transport.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/discord/file_operations.ex`
- `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md`
- `scripts/live_telegram_matrix.py`
- `scripts/live_discord_matrix.py`
- `scripts/live_discord_slash_interaction_proof.exs`

## Lemon Command Inventory

Stable Telegram text-first command boundary:

| Command | Lemon surface | Status | Evidence |
| --- | --- | --- | --- |
| `/new [project]` | Telegram text command | Stable | `Commands.new_command?/2`, `CommandRouter.handle_inbound_message/3`; routed to `handle_new_session` |
| `/resume [selector]` | Telegram text command | Stable | `Commands.resume_command?/2`, `ResumeSelection`; covered by focused Telegram resume tests |
| `/cancel` | Telegram text command and callback button | Stable | `Commands.cancel_command?/2`; live forum-topic cancellation proof passed on 2026-05-12 |
| `/model` | Telegram text command plus reply-keyboard picker | Stable | `Commands.model_command?/2`, `ModelPicker`; deterministic model preference tests exist |
| `/goal [set [--max-continuations N] &lt;objective&gt;|pause|resume|continue|loop once|loop start [--auto]|loop status|loop stop|clear|status]` | Telegram text command | Preview goal state and supervised continuation controls | Uses `LemonCore.GoalStore` plus configurable automation manager modules through `GoalStatusMessage`; status text redacts objective content and raw session ids while showing the max-continuation budget, run id, verdict, loop status, and auto-loop state |
| `/thinking [level|clear|status]` | Telegram text command | Stable | `Commands.thinking_command?/2`, `ChatPreferences.handle_thinking_command/3` |
| `/trigger [mentions|all|clear|status]` | Telegram text command | Stable | `Commands.trigger_command?/2`, `ChatPreferences.handle_trigger_command/3` |
| `/cwd [project_id|path|clear]` | Telegram text command | Stable | `Commands.cwd_command?/2`; interface proof pack covers `/cwd` |
| `/topic &lt;name&gt;` | Telegram text command | Stable for group/forum use | `Commands.topic_command?/2`, `TopicCommand`; live forum-topic proof passed in group `-1003842984060`, topic `35` |
| `/file put [--force] &lt;path&gt;` | Telegram text command with file attachment | Stable when file transfer is enabled | `FileOperations.handle_file_command/2`; support docs define stable file boundary |
| `/file get &lt;path&gt;` | Telegram text command | Stable when file transfer is enabled | Live `/file get` document delivery proof passed in topic `35` |
| `/checkpoint` | Telegram text command | Preview read-only status | Reports redacted checkpoint counts/recent ids; restore remains in Web/control-plane/tool surfaces |
| `/reload` | Telegram text command | Dev/operator command | `Commands.reload_command?/2`; not a public end-user stability promise |

Discord command boundary:

| Command | Lemon surface | Status | Evidence |
| --- | --- | --- | --- |
| `/lemon prompt [engine]` | Discord slash command | Stable only for live-proven channel text prompts | External-sender manual matrix passed for the text-first boundary; deterministic local slash proof covers the empty-prompt interaction response path |
| `/session new [project]` | Discord slash command | Stable naming surface; broader reset parity partial | `@session_command`, `handle_session_interaction/2`; deterministic local slash proof covers safe local response behavior |
| `/session info` | Discord slash command | Stable naming surface; broader `/status` parity partial | `@session_command`, `handle_session_interaction/2`; deterministic local slash proof covers safe local response behavior |
| `/resume [selector]` | Discord slash command | Stable for supported text/file scope | `@resume_command`, `handle_resume_interaction/2`; deterministic local slash proof covers the no-selector response path |
| `/cancel` | Discord slash command and status button | Stable for supported text/file scope; deterministic cancel component and persisted inbound-dedupe proof exist; live reconnect proof still needed for broader parity | `@cancel_command`, `handle_cancel_interaction/2`; deterministic component routing, slash no-active-run response, and duplicate `MESSAGE_CREATE` suppression are covered by proof scripts |
| `/model` | Discord slash command plus select components | Stable for current provider-selection boundary | `@model_command`, `handle_model_interaction/2`, `handle_model_component/4`; deterministic local slash proof covers the model picker response path |
| `/goal set`, `/goal pause`, `/goal resume`, `/goal continue`, `/goal loop_once`, `/goal loop_start`, `/goal loop_status`, `/goal loop_stop`, `/goal clear`, `/goal status` | Discord slash command | Preview goal state and supervised continuation controls | Uses `LemonCore.GoalStore` plus configurable automation manager modules through `GoalStatusMessage`; `/goal set` accepts optional `max_continuations`, `/goal loop_start` accepts optional `auto`, and status text redacts objective content and raw session ids while showing the budget, run id, verdict, loop status, and auto-loop state |
| `/thinking [level|clear|status]` | Discord slash command | Stable naming surface | `@thinking_command`, `handle_thinking_interaction/2`; deterministic local slash proof covers status, set, and clear response paths |
| `/trigger [mentions|all|clear|status]` | Discord slash command | Live-proven for unmentioned second-bot thread prompts after `/trigger all` | `@trigger_command`, `handle_trigger_interaction/2`; `scripts/live_discord_trigger_mode_proof.exs` proves default mention suppression, `/trigger all` free-response routing, and `/trigger mentions` suppression restore. Deterministic bot-message policy proof shows self bot messages/webhooks are ignored while external bot-authored messages preserve sender metadata and route through normal trigger policy. `scripts/live_discord_matrix.py --wait-free-response-trigger` seeds a temporary thread trigger override, embeds redacted local channel diagnostics, cleans it up, and now preflights Message Content Intent flags. The latest proof at `.lemon/proofs/discord-free-response-latest.json` completed with `message_content_intent_declared: true`, trigger mode `all`, cleanup mode `clear`, and redacted proof metadata. |
| `/cwd [project_id|path|clear]` | Discord slash command | Stable naming surface | `@cwd_command`, `handle_cwd_interaction/2`; deterministic local slash proof covers status and clear response paths |
| `/topic &lt;name&gt; [message]` | Discord slash command | Preview | `@topic_command`, `handle_topic_interaction/2`; supports forum-post/thread creation paths; deterministic local slash proof covers the missing-name response path |
| `/file put &lt;attachment&gt; [path] [force]` | Discord slash command | Stable for text-file attachment boundary | `@file_command`, `FileOperations.handle_file_put/5`; external-sender manual matrix passed attachment delivery; deterministic local slash proof covers missing-attachment validation |
| `/file get &lt;path&gt;` | Discord slash command | Stable for text-file attachment boundary | `@file_command`, `FileOperations.handle_file_get/3`; deterministic local slash proof covers missing-path validation |
| `/checkpoint` | Discord slash command | Preview read-only status plus deterministic decoder proof | Reports redacted checkpoint counts/recent ids; restore remains in Web/control-plane/tool surfaces. Deterministic local slash proof covers status, events, diff, and restore payload decoding. |
| `/kanban boards`, `/kanban create`, `/kanban show`, `/kanban archive`, `/kanban task_create`, `/kanban task_update`, `/kanban comment`, `/kanban dispatch_start`, `/kanban dispatch_status`, `/kanban dispatch_stop` | Discord slash command | Preview durable board controls with live API registration proof and deterministic decoder proof | Uses `LemonCore.KanbanStore` plus configurable automation dispatcher modules through `KanbanStatusMessage`; redacts board names, task titles, descriptions, and comments while exposing ids/counts/status. `scripts/live_discord_matrix.py --bot-token-index 0 --register-kanban-slash-command --result-path tmp/discord-kanban-slash-proof.json` registered the in-repo schema from `LemonChannels.Adapters.Discord.Transport.kanban_command_schema/0`, and `--check-kanban-slash-registration` passed through Discord's API for command id `1505003302893522954`, version `1505003302893522955`, with no missing subcommands or options. `scripts/live_discord_slash_interaction_proof.exs` covers all durable kanban subcommand decoders locally. |
| `/reload` | Discord slash command | Dev/operator command | `@reload_command`, `handle_reload_interaction/2` |

## Hermes Messaging Command Comparison

| Hermes messaging command area | Lemon 1.0 status | Launch decision |
| --- | --- | --- |
| Start/reset session: `/new`, `/reset` | Partial | Telegram has `/new`; Discord has `/session new`. Lemon does not expose Hermes `/reset` as a separate stable command. Accept as naming difference for 1.0 or add alias later. |
| Session status: `/status` | Partial | Discord has `/session info`; Telegram currently uses `/cwd`, `/model`, `/thinking`, `/trigger`, and resume flows, not a single `/status` command. Not stable parity yet. |
| Stop/interrupt: `/stop`, `/cancel` | Partial | Lemon supports `/cancel`; no broad `/stop` kill-all command in stable channel scope. Keep `/stop` out of 1.0 claims. |
| Model selection: `/model` | Green for Lemon boundary | Telegram and Discord implement model selection. Provider breadth and live-eval proof remain separate launch gates. |
| Reasoning: `/reasoning` | Equivalent naming difference | Lemon uses `/thinking`. Document as Lemon terminology, not Hermes drop-in parity. |
| Fast mode: `/fast` | Out of 1.0 scope | No stable Lemon channel command. Keep fast-mode parity out of launch claims. |
| Personality: `/personality` | Out of 1.0 scope | No stable Lemon channel command. |
| Retry/undo: `/retry`, `/undo` | Out of 1.0 scope | No stable Lemon channel commands. |
| Home channel: `/sethome` | Out of 1.0 scope | Lemon uses configuration and bindings rather than Hermes home-channel command. |
| Compress/title: `/compress`, `/title` | Out of 1.0 scope | No stable Lemon channel commands. Memory/session behavior remains covered by evals, not slash parity. |
| Resume: `/resume` | Partial/green for supported scope | Telegram and Discord implement resume selection. Keep deterministic tests and live Telegram proof green. |
| Usage/insights: `/usage`, `/insights` | Out of 1.0 scope | Lemon support path is Web operations and support bundles, not channel usage commands. |
| Voice: `/voice` | Out of 1.0 scope | Voice/TTS remains preview or out of stable support. |
| Rollback: `/rollback` | Preview BEAM rollback alias | Lemon now has preview file-tool checkpoints, a native `checkpoint` tool for list/diff/restore/delete, Telegram/Discord `/checkpoint` diff/restore controls, and a Hermes-style `/rollback` alias for the same redacted checkpoint status/events/diff/restore flow with explicit restore confirmation. Broad stable rollback still waits on Discord client-click restore proof and wider shell checkpoint parity. |
| Goals: `/goal` | BEAM live-judge proof | Lemon now has durable per-session goal state, control-plane `goal.set`/`goal.status`/`goal.pause`/`goal.resume`/`goal.continue`/`goal.loop.once`/`goal.loop.start`/`goal.loop.status`/`goal.loop.stop`/`goal.clear`, support-bundle diagnostics, lifecycle/loop-status events, TUI one-shot continuation, one preview loop tick, bounded loop controls, opt-in persisted auto scheduling, judge-model routing, persisted budgets, production-shaped router judge proof, production-shaped persisted-auto scheduler proof, an opt-in provider-backed live judge harness, a credential-backed Z.ai `glm-5-turbo` live proof, plus Telegram/Discord `/goal` status/set-with-budget/pause/resume/continue/loop/auto/clear commands. |
| Kanban: `/kanban` and kanban tools | BEAM live-worker plus Discord registration proof | Lemon now has durable BEAM-native boards, dispatcher, model-facing `kanban`, Telegram topic live proof, provider-backed live worker proof, and Discord `/kanban` application-command registration proof. Full Discord client-interaction breadth remains broader channel parity work. |
| Background: `/background` | Out of channel 1.0 scope | Lemon has agent/subagent/delegation and background runtime paths, but no stable channel command parity. |
| MCP reload: `/reload-mcp` | Out of 1.0 scope | MCP exists but no stable channel reload command. |
| YOLO/approvals: `/yolo`, `/approve`, `/deny` | Partial | Lemon has approval callbacks/buttons and safety policies. It does not expose Hermes-style YOLO or approve/deny text commands as stable channel commands. |
| Commands/help: `/commands`, `/help` | Partial | Discord command menus and Telegram command behavior exist through platform surfaces, but no complete paginated Hermes-style command browser is stable. |
| Update/restart: `/update`, `/restart` | Out of 1.0 scope | Lemon release update and runtime restart remain operator/runtime tasks, not stable messaging commands. |
| Debug upload: `/debug` | Out of channel 1.0 scope | Lemon support bundles are stable through doctor/Web/release paths, not channel debug upload. |
| Dynamic skill commands: `/&lt;skill-name&gt;` | Out of 1.0 channel scope | Lemon skills are stable through tools/docs/evals, not dynamic channel slash commands. |

## Current Classification

Telegram command support is sufficient for the text-first plus document-delivery
boundary, because the launch-critical commands have deterministic coverage and
live proof for DM/group/forum-topic use.

Preview Discord command boundary:

Discord command support is stable only for the live-proven text-first and
file-delivery boundary. `scripts/live_discord_matrix.py --manual-matrix` passed
with the second Lemonade Stand bot as sender, and the resulting
`tmp/discord-live-proof.json` is the release-candidate proof consumed by
`scripts/audit_1_0_readiness` through `LEMON_DISCORD_LIVE_PROOF_JSON`.

The next Discord promotion gates are human/open-channel DM proof, successful
live free-response channel proof, live gateway reconnect replay proof,
real client-click command/component proof, and approval behavior where supported. DM setup
failures caused by Discord API `50007` are now safe support evidence classified
as `discord_dm_setup_refused`, not promotion evidence. Public-thread
prompt/reply, safe mentions, deterministic cancel/keepalive controls,
deterministic trigger mode, deterministic bot-message policy, full live
application-command name registration, and persisted duplicate `MESSAGE_CREATE`
suppression already have focused proof. The deterministic slash interaction
proof now covers the current 16-command inventory, key
checkpoint/rollback/kanban/media decoders, and safe local response paths, but it is not
real Discord client-click evidence. The Discord transport now has passive
client-click proof recording for real slash-command interactions with live
Discord fields and safe Lemon responses; that proof path is ready for
post-deploy/operator-click promotion. The primary promotion handoff is
`scripts/live_discord_matrix.py --wait-slash-client-click-proof`, which asks for
a fresh real click and rejects stale artifacts; the one-shot
`--check-slash-client-click-proof` path remains available for already captured
artifacts. No broad slash parity claim should be made until an actual
client-click proof artifact exists and passes validation.

Hermes drop-in command parity is not a Lemon 1.0 claim. The public support
boundary must continue to say that ACP/API parity, rollback/checkpointing,
browser/media/TTS, plugin ecosystem breadth, autonomous goal continuation,
kanban boards, Discord DM/thread/voice behavior, and dynamic skill slash
commands are outside
stable 1.0 unless a later release promotes and proves a narrower path.

## Launch Actions

1. Keep Telegram command proofs green in the live Telegram matrix.
2. Keep the Discord external-sender manual matrix JSON attached to the final
   readiness audit and rerun it for release candidates.
3. Add real Discord client-click command/component proof before promoting
   broader Discord command parity; deterministic local breadth is now covered
   by `scripts/live_discord_slash_interaction_proof.exs`.
4. Promote `/goal` only while provider-backed live model judge proof and
   channel-visible runner behavior stay green; keep kanban promotion tied to
   live worker proof and the Discord `/kanban` registration/schema proof.
5. Do not market Hermes drop-in slash-command parity for 1.0.
