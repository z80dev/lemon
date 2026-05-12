# Lemon Channel Command Parity Matrix

Status: active audit ledger

Last reviewed: 2026-05-12

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

- `/home/z80/dev/hermes-agent` `origin/main` at `dd0923bb8`
- `website/docs/reference/slash-commands.md`

Lemon source evidence:

- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/commands.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/command_router.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/file_operations.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/chat_preferences.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/topic_command.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/model_picker.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/discord/transport.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/discord/file_operations.ex`
- `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md`
- `scripts/live_telegram_matrix.py`
- `scripts/live_discord_matrix.py`

## Lemon Command Inventory

Stable Telegram text-first command boundary:

| Command | Lemon surface | Status | Evidence |
| --- | --- | --- | --- |
| `/new [project]` | Telegram text command | Stable | `Commands.new_command?/2`, `CommandRouter.handle_inbound_message/3`; routed to `handle_new_session` |
| `/resume [selector]` | Telegram text command | Stable | `Commands.resume_command?/2`, `ResumeSelection`; covered by focused Telegram resume tests |
| `/cancel` | Telegram text command and callback button | Stable | `Commands.cancel_command?/2`; live forum-topic cancellation proof passed on 2026-05-12 |
| `/model` | Telegram text command plus reply-keyboard picker | Stable | `Commands.model_command?/2`, `ModelPicker`; deterministic model preference tests exist |
| `/thinking [level|clear|status]` | Telegram text command | Stable | `Commands.thinking_command?/2`, `ChatPreferences.handle_thinking_command/3` |
| `/trigger [mentions|all|clear|status]` | Telegram text command | Stable | `Commands.trigger_command?/2`, `ChatPreferences.handle_trigger_command/3` |
| `/cwd [project_id|path|clear]` | Telegram text command | Stable | `Commands.cwd_command?/2`; interface proof pack covers `/cwd` |
| `/topic <name>` | Telegram text command | Stable for group/forum use | `Commands.topic_command?/2`, `TopicCommand`; live forum-topic proof passed in group `-1003842984060`, topic `35` |
| `/file put [--force] <path>` | Telegram text command with file attachment | Stable when file transfer is enabled | `FileOperations.handle_file_command/2`; support docs define stable file boundary |
| `/file get <path>` | Telegram text command | Stable when file transfer is enabled | Live `/file get` document delivery proof passed in topic `35` |
| `/reload` | Telegram text command | Dev/operator command | `Commands.reload_command?/2`; not a public end-user stability promise |

Preview Discord command boundary:

| Command | Lemon surface | Status | Evidence |
| --- | --- | --- | --- |
| `/lemon prompt [engine]` | Discord slash command | Preview until external-sender live proof passes | `@lemon_command`, `handle_lemon_interaction/2`; no external-sender inbound live proof yet |
| `/session new [project]` | Discord slash command | Preview | `@session_command`, `handle_session_interaction/2` |
| `/session info` | Discord slash command | Preview | `@session_command`, `handle_session_interaction/2` |
| `/resume [selector]` | Discord slash command | Preview | `@resume_command`, `handle_resume_interaction/2` |
| `/cancel` | Discord slash command and status button | Preview | `@cancel_command`, `handle_cancel_interaction/2`; deterministic component rendering exists |
| `/model` | Discord slash command plus select components | Preview | `@model_command`, `handle_model_interaction/2`, `handle_model_component/4` |
| `/thinking [level|clear|status]` | Discord slash command | Preview | `@thinking_command`, `handle_thinking_interaction/2` |
| `/trigger [mentions|all|clear|status]` | Discord slash command | Preview | `@trigger_command`, `handle_trigger_interaction/2` |
| `/cwd [project_id|path|clear]` | Discord slash command | Preview | `@cwd_command`, `handle_cwd_interaction/2` |
| `/topic <name> [message]` | Discord slash command | Preview | `@topic_command`, `handle_topic_interaction/2`; supports forum-post/thread creation paths |
| `/file put <attachment> [path] [force]` | Discord slash command | Preview | `@file_command`, `FileOperations.handle_file_put/5` |
| `/file get <path>` | Discord slash command | Preview | `@file_command`, `FileOperations.handle_file_get/3` |
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
| Rollback: `/rollback` | Out of 1.0 scope | Lemon does not claim automatic checkpoint rollback parity. |
| Background: `/background` | Out of channel 1.0 scope | Lemon has agent/subagent/delegation and background runtime paths, but no stable channel command parity. |
| MCP reload: `/reload-mcp` | Out of 1.0 scope | MCP exists but no stable channel reload command. |
| YOLO/approvals: `/yolo`, `/approve`, `/deny` | Partial | Lemon has approval callbacks/buttons and safety policies. It does not expose Hermes-style YOLO or approve/deny text commands as stable channel commands. |
| Commands/help: `/commands`, `/help` | Partial | Discord command menus and Telegram command behavior exist through platform surfaces, but no complete paginated Hermes-style command browser is stable. |
| Update/restart: `/update`, `/restart` | Out of 1.0 scope | Lemon release update and runtime restart remain operator/runtime tasks, not stable messaging commands. |
| Debug upload: `/debug` | Out of channel 1.0 scope | Lemon support bundles are stable through doctor/Web/release paths, not channel debug upload. |
| Dynamic skill commands: `/<skill-name>` | Out of 1.0 channel scope | Lemon skills are stable through tools/docs/evals, not dynamic channel slash commands. |

## Current Classification

Telegram command support is sufficient for the text-first plus document-delivery
1.0 boundary, because the launch-critical commands have deterministic coverage
and live proof for DM/group/forum-topic use.

Discord command support is stable only for the live-proven text-first and
file-delivery boundary. `scripts/live_discord_matrix.py --manual-matrix` passed
with the second Lemonade Stand bot as sender, and the resulting
`tmp/discord-live-proof.json` is the release-candidate proof consumed by
`scripts/audit_1_0_readiness` through `LEMON_DISCORD_LIVE_PROOF_JSON`.

Hermes drop-in command parity is not a Lemon 1.0 claim. The public support
boundary must continue to say that ACP/API parity, rollback/checkpointing,
browser/media/TTS, plugin ecosystem breadth, Discord DM/thread/voice behavior,
and dynamic skill slash commands are outside stable 1.0 unless a later release
promotes and proves a narrower path.

## Launch Actions

1. Keep Telegram command proofs green in the live Telegram matrix.
2. Keep the Discord external-sender manual matrix JSON attached to the final
   readiness audit and rerun it for release candidates.
3. Add deterministic Discord command tests for `/lemon`, `/session info`,
   `/cancel`, `/cwd`, `/trigger`, `/file get`, and `/topic` before promoting
   Discord from preview.
4. Do not market Hermes drop-in slash-command parity for 1.0.
