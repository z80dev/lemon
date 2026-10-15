# Changelog

All notable changes to `lemon_ai` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

### Added

- `LemonAi.Auth.AnthropicOAuth` implements Claude Pro/Max sign-in natively:
  `build_authorize_url/1`, `parse_authorization_input/1`,
  `exchange_code_for_secret/3`, `describe_secret/1` and a `login_device_flow/1`
  that uses a loopback listener or Anthropic's hosted code page.
- `LemonAi.Auth.OAuthFlow`: shared RFC 8628 device-code polling (injectable
  `:sleep`), token requests and single-flight refresh with `force_refresh`.
- `XAIOAuth` and `KimiCodeOAuth` device-code logins with refreshable payloads,
  registered in `OAuthSecretResolver`; Anthropic-protocol Kimi requests send a
  Kimi OAuth token as a bearer with Kimi CLI fingerprint headers.
- `OpenRouterOAuth` (PKCE, durable API key) and `ZaiOAuth` (GLM Coding Plan
  sign-in that mints an API key) sign-ins.
- `OpenAICodexOAuth.login_device_code/1` (headless ChatGPT device flow) and a
  `:token_url` option on `exchange_code_for_secret/3`;
  `GitHubCopilotOAuth.decode_secret/1` is public.

### Changed

- **Breaking:** `AnthropicOAuth.login_device_flow/1` no longer runs
  `claude setup-token` or copies Claude Code's credentials file; it requires
  `:on_auth` and `:on_prompt`. A pasted setup token is still accepted.
  `LEMON_ANTHROPIC_CLAUDE_PATH` is removed.
- Anthropic refresh is single-flight per secret name on the local node and
  re-reads the stored secret through the new `:reload_secret` option. It runs
  five minutes before expiry, uses only `platform.claude.com`, and returns
  `{:error, :reauth_required}` when the token endpoint rejects the refresh
  token, even if the access token has not expired.
- The Claude Code user agent uses the newer of the installed CLI version and
  2.1.296, detected once per `PATH` instead of on every request.

### Fixed

- Correct uppercase Base64 alphabet values when validating padded image blocks;
  valid JPEG, GIF and WebP inputs no longer fail canonical-padding checks.
- Gemini CLI / Cloud Code Assist now consumes bounded non-success streaming
  response bodies and closes their transports before classifying or retrying.
  Failures retain typed HTTP status, retry metadata and actionable classification
  without exposing upstream body text, credentials or Req transport structs.

## [0.2.0] - 2026-10-13

First release as a standalone package. `lemon_ai` was extracted from the Lemon
umbrella, where it lives as the `:lemon_ai` application; the OTP application name and
every `LemonAi.*` module name are unchanged, so only the `mix.exs` line differs from
what in-repo code has been using.

### Fixed

- OAuth token requests refuse redirects and redact untrusted endpoint error
  payloads. Device-code deadlines include HTTP and authorization callback time;
  full OpenRouter/Z.AI callbacks bind the redirect endpoint, and Z.AI requires state.
- Copilot, Antigravity and Gemini CLI secret resolution now serializes refresh
  and persistence per stored login, reloads waiting callers, and rejects
  deleted/replaced logins and expired tokens. Google revoked refresh grants
  require reauthentication.
- Model discovery caches are scoped to endpoint, API, credential, headers and
  model defaults; cache identifiers contain a digest rather than auth values.
  Redirects and credential/query-bearing discovery URLs are rejected.
- Custom Google provider options no longer read the built-in Google account's
  key or URL. Custom Anthropic and Google models honor explicit keyless auth.
- The Anthropic, GitHub Copilot, Google Antigravity and Google Gemini CLI
  OAuth helpers no longer report success when a refreshed secret could not be
  stored: a `:persist_secret` callback returning `{:error, _}` (or raising)
  now makes `resolve_api_key_from_secret/3` return
  `{:error, :oauth_secret_persistence_failed}`, as the Codex helper already
  did, instead of handing out a token whose rotated refresh token was lost.
- Installable from Hex. The `0.1.0` release's `mix.exs` began with
  `Code.require_file("../../hex_package.exs", __DIR__)`, a file that was not in
  the package, so it failed to load in every consumer project; `0.1.0` is
  retired. The shipped `mix.exs` is now self-contained.

### Added

- `LemonAi.stream/3` and `LemonAi.complete/3` — one API over eighteen provider modules
  (Anthropic, OpenAI completions and responses, Azure OpenAI, Google Gemini and
  Vertex, AWS Bedrock, Mistral, Groq, Fireworks, OpenRouter, Qwen, MiniMax,
  GitHub Copilot, and the Codex/Gemini CLI bridges), with streaming events
  normalized to the same shapes regardless of provider.
- `LemonAi.ProviderRegistry` for registering and resolving providers at runtime, so
  a host application can add a provider without a fork.
- Reliability layer around every call: `LemonAi.RateLimiter` (per-provider token and
  request budgets), `LemonAi.CircuitBreaker` (opens on repeated provider failure and
  half-opens on a timer), and in-provider retry for 429/529/5xx and transport errors
  (Anthropic, OpenAI Chat Completions, Responses and Codex): 4 attempts, capped
  exponential backoff with jitter from ~1s, honoring `retry-after`/`retry-after-ms`
  and Anthropic rate-limit reset headers. Server waits beyond the in-provider cap are
  returned to the caller as `AssistantMessage.retry_after_ms`
  (`config :lemon_ai, :provider_retry`).
- `LemonAi.CallDispatcher` queues callers FIFO when a provider is at its in-flight cap
  and only returns `{:error, :max_concurrency}` after a bounded wait
  (`queue_timeout_ms`, default 120s; `0` fails fast).
- `LemonAi.Tokens` and `LemonAi.Text` for token accounting and text extraction, and
  `LemonAi.calculate_cost/2` for per-call cost from the model's price table.
- `LemonAi.Models` catalogue plus `LemonAi.ModelCache`, covering model IDs, context
  windows, capabilities and pricing — including Claude Opus 5.5 / Opus 5 / Opus 4.8 /
  Opus 4.7 / Sonnet 5 / Fable 5.x and OpenAI GPT-5.5 / GPT-5.5 Pro / GPT-6 Astra, Sol
  and Luna. Explicit `adaptive_thinking` and `reasoning_efforts` capability flags on
  each model drive Anthropic adaptive thinking and reasoning-effort clamping
  (`LemonAi.Models.reasoning_effort_for/2`) instead of model-id substring checks.
- Anthropic tool results carry image blocks inside `tool_result.content` for vision
  models instead of dropping them.
- OpenAI Chat Completions and AWS Bedrock responses report cost from usage and catalog
  pricing instead of $0.
- `LemonAi.Env` declares the 28 environment variables this package reads — provider
  credentials, endpoint overrides and client tuning — each with a type, default,
  documentation string and a secret flag. It is self-describing on its own and
  is picked up automatically by `LemonCore.Env` when both packages are present.
- `mix lemon.models` lists the catalogue from the command line.

### Changed

- The 25 provider-module model catalogs moved from Elixir struct literals to 26
  JSON resources under `priv/models/`, loaded and embedded at compile time by
  `LemonAi.Models.Catalog`. Google uses a base file plus Antigravity extras;
  the `:google_antigravity` registry is derived from both, while
  `:"openai-codex"` derives from the direct OpenAI catalog plus OAuth-only IDs.
  Existing provider module names and `models/0` return values are unchanged.
  Catalog files are external compiler resources; malformed top-level data and
  entries fail with source/model context, while field types, token-size ranges,
  costs, and compatibility overrides are validated. API, provider, input, and
  compatibility keys normalize through fixed atom allowlists.

### Notes

- `lemon_ai` depends on no other Lemon package. It is usable on its own in any
  Elixir project; `lemon_agent` and the rest of the platform build on top of it.
