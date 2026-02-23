---
id: IDEA-20260224-openclaw-context-overflow-classification
title: Improved context overflow error classification and handling
source: openclaw
source_commit: 4f340b881, 652099cd5
discovered: 2026-02-24
status: proposed
---

# Description
OpenClaw improved error classification to better distinguish between context overflow errors and other types of errors (reasoning-required errors, rate limits). This prevents misclassification that could lead to incorrect error handling.

Key improvements:
- Avoid classifying reasoning-required errors as context overflow
- Correctly identify Groq TPM limits as rate limits instead of context overflow
- Better error pattern matching to distinguish error types

# Lemon Status
- Current state: Lemon has context overflow detection with Chinese pattern support
- Gap: May not have fine-grained classification between context overflow vs rate limits vs reasoning errors

# Investigation Notes
- Complexity estimate: S
- Value estimate: M (error handling accuracy)
- Open questions:
  - How does Lemon currently classify different error types from providers?
  - Are there cases where rate limits are misclassified as context overflow?
  - Does Lemon have specific handling for reasoning-required errors?

# Recommendation
proceed - Error handling accuracy improvement. Should review current error classification patterns and align with OpenClaw's improved logic.

# References
- OpenClaw commits: 4f340b881 (reasoning errors), 652099cd5 (Groq rate limits)
- Files affected: pi-embedded-helpers/errors.ts
