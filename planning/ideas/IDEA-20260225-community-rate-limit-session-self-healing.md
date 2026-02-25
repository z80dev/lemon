---
id: IDEA-20260225-community-rate-limit-session-self-healing
title: [Community] Self-Healing Sessions for Persistent Rate-Limit Wedges
source: community
source_url: https://github.com/anthropics/claude-code/issues/26699
discovered: 2026-02-25
status: proposed
---

# Description
Community reports show a painful failure mode where a single long-running session gets stuck permanently in a rate-limited state even after limits reset. Users can continue in new sessions, but the wedged session cannot recover without context-loss reset.

# Evidence
- Claude Code issue #26699 documents session-local permanent "Rate limit reached" failure after transient limits clear.
- Reported symptoms include `/compact` also failing, so built-in recovery paths cannot execute.
- Workaround is destructive (`/clear`/start over), causing context and plan continuity loss.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has compaction, cron, and resume primitives plus a separate idea for post-reset auto-resume.
  - Missing: explicit **session self-healing** state machine for wedged limiter/backoff states (e.g., probe requests, capped backoff reset, fallback model/provider, safe session fork with context carryover).
  - This is adjacent to auto-resume but addresses a distinct bug class: session-local deadlock after global quota clears.

# Value Assessment
- Community demand: **H**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**proceed** — Strong reliability value for long sessions; complements existing auto-resume planning by adding true in-session recovery behavior.
