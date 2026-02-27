---
id: IDEA-20260227-ironclaw-approval-state-thread-resume
title: [IronClaw] Persist Tool Calls and Restore Approval State on Thread Switch
source: ironclaw
source_commit: 759cd7e4ff2b
discovered: 2026-02-27
status: proposed
---

# Description
IronClaw web recently added persistence for tool-call history and explicit restoration of pending approval context when users switch threads/sessions in the UI. This reduces “lost approval prompt” failures and keeps tool execution context stable during thread navigation.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has strong approval primitives (`exec.approvals.*`) and policy layering in router/control-plane.
  - Lemon has monitoring/session views, but no explicit productized guarantee that pending approval state is restored across thread/session switches in every client.
  - Risk: users can lose operational context when moving between threads during long-running runs.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **H**
- Open questions:
  1. Which clients need parity first (`lemon-web`, TUI, Telegram-driven UI flows)?
  2. Should approval prompts be replayable from a canonical event stream (bus/store), or client-local reconstructed state?
  3. Do we need explicit run-level “pending approvals” APIs for resilient reconnection?

# Recommendation
**proceed** — This is a reliability/UX win for long-running agent sessions and aligns with Lemon’s existing approval + orchestration strengths.
