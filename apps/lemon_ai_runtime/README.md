# LemonAiRuntime

`LemonAiRuntime` is the Lemon-owned AI runtime/config boundary for auth and
runtime option handling during the AI extraction.

This first slice is intentionally façade-only:

- `LemonAiRuntime.Auth.*` modules currently delegate to existing `Ai.Auth.*`
  modules and perform no additional logic.
- Lemon apps should stop depending on `Ai.Auth.*` directly and use
  `LemonAiRuntime.Auth.*` instead.
- Callers that only need to know whether Codex OAuth is available should check
  `LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token/0` instead of
  reaching into `Ai.Auth.*`.
- External callers should treat `LemonAiRuntime` as the migration boundary for
  Lemon-owned auth/config/runtime concerns.

Later slices will move storage-backed secret resolution and runtime ownership
from `apps/ai` into this app.
