---
id: IDEA-20260225-openclaw-secrets-onboarding-parity
title: [OpenClaw] Secret-Ref Onboarding Parity Across Built-In and Custom Providers
source: openclaw
source_commit: 66295a7a1489
discovered: 2026-02-25
status: proposed
---

# Description
OpenClaw expanded onboarding auth flows so secret references are handled consistently across built-in providers and custom provider paths (`66295a7a1489`). The change also deepened docs and non-interactive onboarding behavior so API keys are stored/referenced in a consistent way.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has strong secret primitives (`LemonCore.Secrets`) and tool-level env import via `tool_auth`.
  - `LemonCore.Config.Providers.get_api_key/2` still documents secret fallback but returns `nil` for `api_key_secret` fallback path (placeholder behavior).
  - Runtime session paths can resolve secrets, but onboarding/config surfaces are inconsistent, especially for provider config parity and user-facing setup flows.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **H**
- Open questions:
  1. Should provider API key resolution be centralized in `LemonCore.Config.Providers` and reused by all call paths?
  2. What migration path should convert existing plaintext provider keys to secret refs safely?
  3. How should custom provider definitions declare secret-ref fields so setup UX is consistent?

# Recommendation
**proceed** — This is a high-leverage security and reliability improvement that closes a current consistency gap between config parsing, onboarding UX, and runtime provider resolution.
