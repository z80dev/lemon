---
id: IDEA-20260227-community-reverse-permission-hierarchy
title: [Community] Reverse Permission Hierarchy with Explicit Command Allowlists
source: community
source_url: https://github.com/anthropics/claude-code/issues/28707
discovered: 2026-02-27
status: proposed
---

# Description
Community requests are pushing for a deny-by-default “reverse permission hierarchy”: user-approved command patterns are allowlisted first, and anything outside those patterns is blocked/prompted even if it looks similar. The aim is to prevent tool abuse via script/path substitution.

# Evidence
- Claude Code issue #28707 requests path-sensitive allowlisting to avoid accidental escalation from similarly named scripts.
- Related approval UX requests emphasize making approval scope explicit and safer for autonomous/long-running agents.
- Broader trend: users want policy controls that are precise enough for production repos, not just broad tool-level toggles.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has rich approval controls (`always`/`never`/interactive, per-node + global profiles).
  - Missing: first-class command-pattern/path allowlists with precedence/deny rules as a hardened hierarchy.
  - Existing controls are strong at tool granularity but less explicit for command-shape trust boundaries.

# Value Assessment
- Community demand: **H**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**investigate** — High trust/safety value for enterprise and autonomous workflows; fits Lemon’s policy-engine direction.
