---
id: IDEA-20260224-openclaw-env-backed-secret-refs
title: [OpenClaw] Env-Backed Secret References and Plaintext-Free Auth Persistence
source: openclaw
source_commit: 18546f31e61f
discovered: 2026-02-24
status: proposed
---

# Description
OpenClaw landed a cluster of auth/secrets changes to persist API credentials as secret references (not plaintext) and to support env-backed key refs during onboarding (`18546f31e61f`, `121f204828cb`, `a4427a823a7a`).

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has secrets infrastructure (`LemonCore.Secrets`, keychain integration) and provider config fields like `api_key_secret`.
  - `LemonCore.Config.Providers.get_api_key/2` currently documents secret fallback but returns `nil` for `api_key_secret` path (placeholder behavior).
  - No unified "import env -> store secret ref -> scrub plaintext" onboarding path is clearly exposed.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **H**
- Open questions:
  1. Should secret-ref resolution happen at config load or provider request time?
  2. What migration should be applied for existing plaintext keys in config files?
  3. How should `tool_auth` integrate with secret-ref persistence across providers?

# Recommendation
**proceed** — Strong security/operability value, aligns with existing Lemon secrets architecture, and closes a documented partial implementation gap.
