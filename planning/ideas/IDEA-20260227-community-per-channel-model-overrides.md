---
id: IDEA-20260227-community-per-channel-model-overrides
title: [Community] Persistent Per-Channel Model Overrides
source: community
source_url: https://github.com/openclaw/openclaw/issues/12246
discovered: 2026-02-27
status: proposed
---

# Description
Community operators are asking for durable per-channel model policy (e.g., one Discord channel uses a cheaper model while another uses a deeper reasoning model), rather than ephemeral per-session overrides.

# Evidence
- OpenClaw issue #12246 describes channel-specific model controls as a recurring operational need.
- Reported pain: session-level overrides are temporary and get lost after resets/restarts.
- Pattern appears in multi-channel production setups where cost/performance tradeoffs differ by room/workflow.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon already supports model resolution and session-level overrides.
  - Telegram adapter has persisted chat/thread default model preferences (`telegram_default_model`), which proves the value but is channel-specific.
  - Missing: a cross-channel policy layer for default model + thinking profile by route (channel/account/peer/thread), with consistent precedence rules.

# Value Assessment
- Community demand: **H**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**proceed** — Promote Telegram’s local pattern into a unified route-level model policy system across adapters.
