---
id: IDEA-20260227-community-session-thread-decoupling
title: [Community] Decouple Session Persistence from Thread Binding
source: community
source_url: https://github.com/openclaw/openclaw/issues/23414
discovered: 2026-02-27
status: proposed
---

# Description
Community feedback highlights a design pain: long-lived orchestrator sessions should remain durable even when channel thread primitives are unavailable or disabled. Session lifetime and thread routing are related but not the same concern.

# Evidence
- OpenClaw issue #23414 reports orchestrator workflows breaking when session persistence is tied to thread support.
- Non-thread channels still need durable background sessions for handoffs, followups, and sub-agent coordination.
- Multi-channel agent operators increasingly run mixed environments where thread semantics vary by platform.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon already has strong thread-worker/session-key architecture and queue modes (`collect`, `followup`, `steer`, etc.).
  - There is no explicit documented contract that durable session mode is independent from thread capability across all channels.
  - Missing validation/tests proving parity for non-thread transports in orchestrator-style flows.

# Value Assessment
- Community demand: **M**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**investigate** — Formalize and test a session/thread separation contract to prevent channel-capability coupling regressions.
