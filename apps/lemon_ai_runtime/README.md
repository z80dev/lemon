# LemonAiRuntime

`LemonAiRuntime` is the Lemon-owned AI runtime/config boundary for auth,
credential resolution, and provider-specific runtime option handling during the
AI extraction.

Current scope:

- `LemonAiRuntime.Auth.*` modules currently delegate to existing `Ai.Auth.*`
  modules.
- `LemonAiRuntime.Credentials` owns Lemon-facing provider API key resolution and
  provider availability checks.
- `LemonAiRuntime.StreamOptions` owns Lemon-facing stream option shaping for
  providers like Vertex, Azure, Bedrock, and Gemini CLI.
- External callers should treat `LemonAiRuntime` as the migration boundary for
  Lemon-owned auth/config/runtime concerns.

Provider protocol implementations still live in `apps/ai`; later slices will
move more ownership into this app.
