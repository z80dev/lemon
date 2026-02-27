---
id: IDEA-20260227-pi-offline-startup-network-timeouts
title: [Pi] Offline-First Startup Mode with Explicit Network Timeout Budget
source: pi
source_commit: 757d36a41b96
discovered: 2026-02-27
status: proposed
---

# Description
Pi introduced coding-agent startup hardening for degraded/offline environments: explicit offline startup behavior and bounded network timeout handling to avoid boot hangs.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has timeout handling in several subsystems, but no clear first-class "offline startup mode" contract across gateway/router/coding-agent flows.
  - Startup can still depend on external checks/providers in ways that are not consistently budgeted or surfaced as an explicit mode.
  - Missing a unified operator story for "boot now, degrade gracefully, reconnect later."

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **H**
- Open questions:
  1. Which startup paths must be guaranteed offline-safe (CLI, control plane, channel workers, skills discovery)?
  2. How should deferred/retry state be represented once network returns?
  3. What observability is needed so operators can distinguish offline-degraded vs misconfigured states?

# Recommendation
**proceed** — Strong reliability/dx value for self-hosted deployments and unstable network environments; aligns with Lemon’s local-first positioning.
