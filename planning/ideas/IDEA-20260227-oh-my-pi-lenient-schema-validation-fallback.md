---
id: IDEA-20260227-oh-my-pi-lenient-schema-validation-fallback
title: [Oh-My-Pi] Lenient Tool-Schema Validation Fallback for Provider Drift
source: oh-my-pi
source_commit: d78321b5fda9
discovered: 2026-02-27
status: proposed
---

# Description
Oh-My-Pi added a lenient argument-validation fallback path (plus circular-reference-safe handling) so tool execution can proceed safely when providers emit slightly malformed or schema-incompatible payloads.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has strong schema/tool validation and several hardening layers, but failure handling is still mostly binary (valid vs reject).
  - There is no explicit, documented "lenient fallback" mode that attempts safe coercion/recovery while preserving a strict audit trail.
  - This leaves reliability risk when provider schema output drifts (especially across rapidly changing model backends).

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M**
- Open questions:
  1. Which coercions are safe by default (string→number, enum alias normalization, nullable flattening)?
  2. How should fallback attempts be surfaced in run telemetry and user-facing diagnostics?
  3. Should fallback be global, provider-specific, or opt-in by tool policy?

# Recommendation
**investigate** — Medium effort reliability gain; useful defense against upstream provider/schema churn without fully relaxing safety guarantees.
