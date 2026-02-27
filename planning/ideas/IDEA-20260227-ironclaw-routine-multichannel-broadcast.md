---
id: IDEA-20260227-ironclaw-routine-multichannel-broadcast
title: [IronClaw] Routine Notifications Fanout to All Installed Channels
source: ironclaw
source_commit: e4f2fba762f0
discovered: 2026-02-27
status: proposed
---

# Description
IronClaw added routine delivery fanout so a single routine run can notify all installed channels instead of requiring one-channel targeting. This pushes “always-on” automations toward channel-agnostic delivery by default.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon already has `fanout_routes` support in router output tracking (`LemonRouter.RunProcess.OutputTracker`) and can deliver final answers to secondary routes.
  - Fanout today is route-driven and typically attached per job/meta; there is no first-class “notify all installed channels for this agent/account” routine contract.
  - Missing ergonomics: deterministic channel selection policy, per-channel opt-in/opt-out, and delivery audit summary across channels.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M**
- Open questions:
  1. Should fanout target “all installed channels,” “all enabled channels,” or an explicit policy subset?
  2. How do we prevent duplicate delivery when primary route is already included in fanout derivation?
  3. Where should delivery reporting live (cron run summary, per-route status API, or both)?

# Recommendation
**investigate** — Lemon has most plumbing already; the opportunity is productizing policy-driven multi-channel routine delivery and observability.
