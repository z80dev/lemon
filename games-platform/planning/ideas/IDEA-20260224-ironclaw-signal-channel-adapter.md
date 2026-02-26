---
id: IDEA-20260224-ironclaw-signal-channel-adapter
title: [Ironclaw] Native Signal Channel Adapter via signal-cli HTTP Daemon
source: ironclaw
source_commit: b0b3a50fa38d
discovered: 2026-02-24
status: proposed
---

# Description
Ironclaw added a native Signal channel integration using a `signal-cli` HTTP daemon. This extends the messaging surface to privacy-focused users and teams.

# Lemon Status
- Current state: **doesn't have**
- Gap analysis:
  - Lemon channel adapters currently include Discord, Telegram, X API, and XMTP.
  - No Signal adapter exists in `apps/lemon_channels/lib/lemon_channels/adapters/`.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M**
- Open questions:
  1. Should Signal live in `lemon_channels` adapter layer or gateway transport first?
  2. What auth/onboarding UX is acceptable for self-hosted `signal-cli`?
  3. Are there reliability constraints for group threading and media parity?

# Recommendation
**investigate** — Good channel expansion candidate with clear user segment fit; prioritize after core channel reliability and current in-progress channel work.
