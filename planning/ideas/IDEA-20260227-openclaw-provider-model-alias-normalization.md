---
id: IDEA-20260227-openclaw-provider-model-alias-normalization
title: [OpenClaw] Provider/Model Alias Normalization for Gemini Backends
source: openclaw
source_commit: e6be26ef1c1a
discovered: 2026-02-27
status: proposed
---

# Description
OpenClaw added normalization/fallback handling for bare Gemini 3 model IDs when routed through provider-specific backends (`google-antigravity`, `google-gemini-cli`). The objective is to prevent model resolution failures caused by alias drift across provider adapters.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon already supports provider/model parsing and has broad Gemini model catalog coverage (including provider-scoped IDs).
  - Some provider alias handling exists in channel transport paths, but normalization rules are spread across layers.
  - Missing: a single cross-provider normalization contract + compatibility tests focused on alias drift and “bare ID” fallback behavior.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Should normalization happen in `ai/models` lookup, session model resolver, or both with shared utility?
  2. What compatibility matrix should we enforce across `google`, `google-vertex`, `google-gemini-cli`, and `google-antigravity`?
  3. Should config validation warn users when aliases are ambiguous?

# Recommendation
**investigate** — Smaller effort, moderate resilience gain; worthwhile as defensive hardening for model-routing reliability.
