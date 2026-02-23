---
id: IDEA-20260224-openclaw-synology-chat
title: Synology Chat native channel support
source: openclaw
source_commit: 03586e3d0
discovered: 2026-02-24
status: proposed
---

# Description

OpenClaw added native Synology Chat channel support for webhook-based integration with Synology NAS Chat (DSM 7+). This allows agents to communicate through Synology's chat platform.

Key features:
- Webhook-based integration with Synology NAS Chat
- Outgoing webhooks and incoming messages
- Multi-account support
- DM policies and rate limiting
- HMAC-based constant-time token validation
- Configurable SSL verification for self-signed NAS certs
- 54 unit tests across 5 test suites

# Lemon Status

- Current state: Lemon has Telegram, Discord, and other channels
- Gap: No Synology Chat channel support
- Location: `apps/lemon_channels/lib/lemon_channels/channels/`

# Investigation Notes

- Complexity estimate: M
- Value estimate: M
- Open questions:
  - How popular is Synology Chat among Lemon users?
  - Does the existing channel plugin pattern support this easily?
  - Are there existing webhook-based channels to use as reference?

# Recommendation

**defer** - Nice-to-have channel support but lower priority unless there's user demand. Synology Chat is a niche platform compared to Telegram/Discord.

# References

- OpenClaw PR: #23012
- Commit: 03586e3d0057b5975090d50dadcc5bc95b51f977
