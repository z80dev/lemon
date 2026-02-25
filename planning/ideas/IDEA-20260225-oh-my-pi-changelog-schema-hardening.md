---
id: IDEA-20260225-oh-my-pi-changelog-schema-hardening
title: [Oh-My-Pi] Changelog Schema Hardening for Agentic Commit Tooling
source: oh-my-pi
source_commit: 80580edd5994
discovered: 2026-02-25
status: proposed
---

# Description
Oh-My-Pi hardened its commit/changelog pipeline by introducing shared changelog categories and schema validation for changelog mutations (including deletion payload validation). This reduces malformed changelog entries and category drift in automated commit flows.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has strong planning docs and commit practices, but no clearly centralized schema-backed changelog mutation contract for agent-generated release notes.
  - Category consistency and validation are mostly convention-driven today.
  - A schema-backed layer could improve reliability for future automated release/changelog tooling.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M**
- Open questions:
  1. Should Lemon standardize changelog categories repo-wide first?
  2. Do we need this in coding-agent tooling, release tooling, or both?
  3. How strict should validation be for manual vs agent-authored entries?

# Recommendation
**investigate** — Useful governance improvement if Lemon expands agent-driven release/changelog automation.
