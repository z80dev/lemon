---
id: IDEA-20260224-oh-my-pi-copilot-strict-mode
title: GitHub Copilot strict mode support in tool schemas
source: oh-my-pi
source_commit: d78c2fd6
discovered: 2026-02-24
status: proposed
---

# Description
Oh-My-Pi added GitHub Copilot provider support for strict mode in OpenAI completions and responses tool schemas. This enables better tool calling reliability when using GitHub Copilot as the AI provider.

Key features:
- GitHub Copilot recognized as a strict mode compatible provider
- Updated `detectStrictModeSupport()` and `supportsStrictMode()` functions
- Test coverage for GitHub Copilot strict mode support
- Works with both openai-completions and openai-responses tool schemas

# Lemon Status
- Current state: Lemon has strict mode support for OpenAI providers
- Gap: GitHub Copilot not explicitly recognized as strict mode compatible

# Investigation Notes
- Complexity estimate: S
- Value estimate: L (provider compatibility)
- Open questions:
  - Does Lemon's AI provider system have a concept of strict mode per provider?
  - Where is strict mode detection implemented?
  - Is GitHub Copilot already supported as a provider in Lemon?

# Recommendation
proceed - Small change for provider compatibility. Should be a simple addition to the strict mode detection logic.

# References
- Oh-My-Pi commit: d78c2fd6
- Files affected: openai-completions.ts, openai-responses.ts, openai-tool-strict-mode.test.ts
