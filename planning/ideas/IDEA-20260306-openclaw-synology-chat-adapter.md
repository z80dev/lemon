---
id: IDEA-20260306-openclaw-synology-chat-adapter
title: Synology Chat Channel Adapter
source: openclaw
source_commit: cc8e6e993, 60dd6a30e
discovered: 2026-03-06
status: proposed
---

# Description
OpenClaw recently added full support for Synology Chat as a channel adapter. Synology Chat is a self-hosted messaging solution popular in NAS/home-lab environments, expanding OpenClaw's channel coverage to include this self-hosted ecosystem.

**Key behaviors:**
- Incoming webhook URL support for message receiving
- Outgoing webhook for message delivery
- User ID resolution for mentions and direct messages
- Message delivery confirmation and error handling
- Full npm package publishing for plugin distribution

**Implementation notes:**
- Uses Synology Chat's webhook API
- Handles authentication via tokens
- Supports both incoming and outgoing webhooks

# Lemon Status
- **Current state**: No Synology Chat support
- **Gap analysis**: Lemon has Telegram, Discord, X, XMTP, SMS but lacks Synology Chat

# Investigation Notes
- **Complexity estimate**: M
- **Value estimate**: M
- **Open questions**:
  - How large is the Synology Chat user base?
  - Does this align with Lemon's target users (self-hosting overlap)?
  - Should we prioritize other channels first (Slack, WhatsApp)?

# Recommendation
**Defer** - While nice for self-hosting parity, Synology Chat is niche compared to Slack/WhatsApp. Consider after higher-priority channels.

**Strategic note:** This signals OpenClaw's commitment to covering all self-hosted messaging options. Lemon should watch if this drives adoption in home-lab/self-hosting communities.

# References
- OpenClaw commits: `cc8e6e993` ("fix(synology-chat): align docs metadata and declare runtime deps"), `60dd6a30e` ("test: fix msteams shared attachment fetch mock typing")
- Related: Synology Chat is a self-hosted alternative to Slack/Teams
