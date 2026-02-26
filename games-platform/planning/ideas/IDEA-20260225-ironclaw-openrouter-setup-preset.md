---
id: IDEA-20260225-ironclaw-openrouter-setup-preset
title: [IronClaw] OpenRouter Preset in Setup Wizard
source: ironclaw
source_commit: 62dc5d046e28
discovered: 2026-02-25
status: proposed
---

# Description
IronClaw added an OpenRouter-first onboarding path in its setup wizard (`62dc5d046e28`), including:
- Top-level OpenRouter provider option
- Auto-filled base URL (`https://openrouter.ai/api/v1`)
- Provider-specific key prompt and display naming (so users see "OpenRouter" instead of a generic OpenAI-compatible label)

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has strong OpenRouter runtime support (provider definitions, models catalog, API-key env wiring).
  - Lemon does not yet expose an equivalent provider-preset onboarding path that minimizes manual setup mistakes for OpenRouter users.
  - Existing setup surfaces are powerful but less opinionated for first-time provider configuration.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Should this land as a new setup flow (wizard extension) or as docs + slash-command assisted setup?
  2. Should provider presets include guardrails for common fallback chains (OpenRouter + direct vendor backup)?
  3. Should this include validation/probe at setup-time to catch bad key/base URL combinations?

# Recommendation
**investigate** — Low implementation cost with meaningful DX upside; likely high leverage for new-user activation and fewer provider misconfiguration tickets.
