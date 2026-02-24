---
id: IDEA-20260225-community-rate-limit-auto-resume
title: [Community] Auto-Resume Runs After Rate-Limit Reset
source: community
source_url: https://github.com/anthropics/claude-code/issues/26789
discovered: 2026-02-25
status: proposed
---

# Description
Community requests are converging on a specific long-run need: when a coding session hits provider limits, users want a built-in "auto-continue when limit resets" mode so work resumes without manual babysitting.

# Evidence
- Claude Code feature request #26789 explicitly asks for an **"Auto-continue once limit resets"** option during limit events.
- User narrative is consistent: active plan execution gets interrupted, user steps away, progress stalls until manual return.
- This is adjacent to (but narrower than) generic quota-awareness: it requires explicit pause/resume orchestration tied to reset windows.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has primitives: cron scheduling, in-progress checkpoint work, watchdogs, resumable sessions.
  - Missing: first-class "paused-for-limit" state with built-in delayed resume trigger and user-facing confirmation/telemetry.
  - Existing quota-aware idea tracks planning-level mitigation; this adds execution-time auto-resume behavior.

# Value Assessment
- Community demand: **H**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**proceed** — This directly addresses a high-friction workflow break and compounds value from Lemon's existing checkpoint + automation foundations.
