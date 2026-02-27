---
id: IDEA-20260227-community-channel-capability-negotiation
title: [Community] Channel Capability Negotiation (Attachments, Rich Blocks, Streaming)
source: community
source_url: https://github.com/openclaw/openclaw/issues/18426
discovered: 2026-02-27
status: proposed
---

# Description
OpenClaw community demand is clustering around channel-specific capability gaps (file upload, rich message blocks, true streaming) rather than just “add another channel.” Users want agents to adapt output based on what each channel supports and gracefully degrade when a capability is unavailable.

# Evidence
- OpenClaw issues request Slack file/image upload (#18426), Block Kit payload support (#12602), and native stream APIs (#4391).
- Additional issue volume around outbound delivery edge cases implies capability mismatches are a practical pain point.
- Community expectations are shifting from basic text relay to rich, channel-native interactions.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has robust adapters for Telegram/Discord/X/XMTP and transport architecture for expansion.
  - Missing: explicit capability registry/negotiation layer that lets tools/renderers query channel support (attachments, structured UI blocks, stream semantics).
  - Without capability contracts, richer tool outputs risk becoming adapter-specific one-offs.

# Value Assessment
- Community demand: **H**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**proceed** — Strong product leverage: improves existing channels and makes future adapter additions safer and faster.
