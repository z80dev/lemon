# Lemon AI Runtime App Guide

This app is the Lemon-owned boundary for AI auth/config/runtime concerns that are currently extracted from provider internals.

## Scope (current slice)

- This app now owns Lemon-facing runtime credential lookup and provider-specific
  stream option shaping in addition to the auth facade.
- It exposes `LemonAiRuntime.Auth.*` modules that delegate to `Ai.Auth.*`.
- It exposes `LemonAiRuntime.Credentials`, `LemonAiRuntime.ProviderNames`, and
  `LemonAiRuntime.StreamOptions` for Lemon-owned callers.
- It has no OTP application callback or supervision tree.
- Provider protocol implementations remain in `apps/ai` for now.

## Migration Rules

- Do not move provider protocol implementations into `apps/lemon_ai_runtime` beyond this slice.
- Do not add broad catch-all runtime option modules; keep narrow credential and stream-option boundaries.
- No new external app should introduce new direct `Ai.Auth.*` usage; migrate through `LemonAiRuntime.Auth.*`.
- Callers that only need Codex auth availability should use `LemonAiRuntime.Auth.OpenAICodexOAuth.available?/0`.
- Prefer new Lemon-owned callers to use `LemonAiRuntime` for provider credential checks and stream option shaping.
- This app should stay intentionally thin and composable, deferring larger ownership moves to later slices.

## Ownership and dependencies

- `apps/ai` owns provider protocol modules and OAuth protocol primitives.
- `apps/ai` continues to own `Ai.Auth.OAuthPKCE`.
- `apps/ai` continues to own existing provider-specific auth helpers for now.
- Lemon-owned apps should use this façade to avoid hard-coding `Ai.Auth.*` references.
