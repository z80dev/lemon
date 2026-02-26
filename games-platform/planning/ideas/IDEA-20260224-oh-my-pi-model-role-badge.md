---
id: IDEA-20260224-oh-my-pi-model-role-badge
title: [Oh-My-Pi] Model Picker Role Badges in /model UX
source: oh-my-pi
source_commit: 1648b2ad0e42
discovered: 2026-02-24
status: proposed
---

# Description
Oh-My-Pi improved `/model` UX by displaying a role badge (e.g., commit role/context) in the model selector. This helps users understand which model profile is active before dispatch.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon supports `/model` selection in Telegram flows.
  - Current docs/tests emphasize provider/model selection, but not explicit role badges or context tags in picker UI.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **L**
- Open questions:
  1. Should badges show engine role, profile, workspace, or all three?
  2. Does this belong only in Telegram, or also web/TUI surfaces?

# Recommendation
**defer** — Useful polish for model clarity, but lower strategic impact than security, reliability, and channel capabilities.
