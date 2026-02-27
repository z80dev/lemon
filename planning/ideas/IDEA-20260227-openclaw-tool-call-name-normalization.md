---
id: IDEA-20260227-openclaw-tool-call-name-normalization
title: [OpenClaw] Normalize Whitespace-Padded Tool Call Names Before Dispatch
source: openclaw
source_commit: 6b317b1f174d
discovered: 2026-02-27
status: proposed
---

# Description
OpenClaw added dispatch hardening that trims/normalizes tool call names before lookup, preventing avoidable "tool not found" failures when providers emit whitespace-padded names.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon validates non-empty tool-call names (`String.trim(name) != ""`) but dispatch still uses exact matching.
  - `AgentCore.Loop.ToolCalls.find_tool/2` currently does `tool.name == name` without normalization.
  - This creates brittle behavior when upstream model outputs include accidental padding or non-canonical casing.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Should normalization be trim-only, or include Unicode whitespace/case normalization?
  2. Should normalized-vs-raw mismatches emit telemetry for provider quality diagnostics?
  3. Should this logic live in provider adapters, agent core, or both (defense in depth)?

# Recommendation
**proceed** — Low effort reliability hardening with immediate reduction in false-negative tool dispatch failures.
