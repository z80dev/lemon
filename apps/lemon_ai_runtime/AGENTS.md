# Lemon AI Runtime App Guide

This app is the Lemon-owned boundary for AI auth/config/runtime concerns that are currently extracted from provider internals.

## Scope (current slice)

- This app is **facade-only** for this extraction slice.
- It exposes `LemonAiRuntime.Auth.*` modules that delegate to `Ai.Auth.*`.
- It has no OTP application callback or supervision tree.
- Provider behavior and OAuth protocol implementations remain in `apps/ai` for now.

## Migration Rules

- Do not move provider auth/config/storage behavior into `apps/lemon_ai_runtime` beyond this slice.
- Do not add `LemonAiRuntime.Options` in this phase.
- No new external app should introduce new direct `Ai.Auth.*` usage; migrate through `LemonAiRuntime.Auth.*`.
- This app should stay intentionally thin and composable, deferring real ownership moves to later slices.

## Ownership and dependencies

- `apps/ai` owns provider protocol modules and OAuth protocol primitives.
- `apps/ai` continues to own `Ai.Auth.OAuthPKCE`.
- `apps/ai` continues to own existing provider-specific auth helpers for now.
- Lemon-owned apps should use this façade to avoid hard-coding `Ai.Auth.*` references.

