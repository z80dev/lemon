---
id: IDEA-20260224-openclaw-telegram-polling-offsets
title: Per-bot scoped polling offsets for Telegram
source: openclaw
source_commit: 8e821a061
discovered: 2026-02-24
status: proposed
---

# Description
OpenClaw improved Telegram polling by scoping update offsets per bot and properly awaiting shared runner stop. This fixes issues with multi-bot setups where offsets could interfere with each other.

Key features:
- Per-bot scoped polling offsets (isolated offset stores per bot token)
- Shared runner stop synchronization
- Update offset store with proper scoping
- Test coverage for offset scoping behavior

Technical details:
- Each bot token gets its own offset namespace
- Prevents offset collisions in multi-bot configurations
- Proper cleanup when stopping shared runners

# Lemon Status
- Current state: Lemon supports multi-bot Telegram but unclear if offsets are scoped per-bot
- Gap: Need to verify if lemon_channels properly isolates polling offsets per bot

# Investigation Notes
- Complexity estimate: S
- Value estimate: M (multi-bot reliability)
- Open questions:
  - How does Lemon's Telegram transport handle update offsets?
  - Are offsets stored per-bot or globally?
  - Could this explain any multi-bot issues in Lemon?

# Recommendation
investigate - Need to audit Lemon's Telegram offset handling. If offsets are global, this is a bug fix. If already per-bot, this can be closed.

# References
- OpenClaw commit: 8e821a061
- Files affected: telegram/monitor.ts, telegram/update-offset-store.ts, telegram/update-offset-store.test.ts
