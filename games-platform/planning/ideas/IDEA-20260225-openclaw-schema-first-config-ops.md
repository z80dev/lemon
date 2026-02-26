---
id: IDEA-20260225-openclaw-schema-first-config-ops
title: [OpenClaw] Schema-First Config Operations Guidance in Agent Prompts
source: openclaw
source_commit: 975c9f4b5457
discovered: 2026-02-25
status: proposed
---

# Description
OpenClaw added explicit system-prompt guidance telling agents to call `config.schema` before answering config questions or applying config changes. The goal is to stop agents from guessing field names/types and to reduce invalid config edits.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon already exposes `config.schema` in the control plane.
  - Lemon supports config mutation paths (`config.patch`, reload flows), but prompt-level behavior does not consistently steer agents toward schema-first validation before edits.
  - Resulting risk: brittle config assistance and avoidable invalid patch attempts when agents infer keys from memory.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Should schema-first behavior be enforced in prompts only, or also guarded at method handlers?
  2. Do we want a helper tool pattern (`config.safe_patch`) that requires schema lookup metadata?
  3. Which agents/engines should receive this default guidance?

# Recommendation
**investigate** — Small effort, meaningful reliability win for configuration UX and fewer config-edit footguns.
