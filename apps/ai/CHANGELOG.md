# Changelog

All notable changes to `lemon_ai` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_ai` was extracted from the Lemon
umbrella, where it lives as the `:ai` application; the OTP application name and
every `Ai.*` module name are unchanged, so only the `mix.exs` line differs from
what in-repo code has been using.

### Added

- `Ai.stream/3` and `Ai.complete/3` — one API over eighteen provider modules
  (Anthropic, OpenAI completions and responses, Azure OpenAI, Google Gemini and
  Vertex, AWS Bedrock, Mistral, Groq, Fireworks, OpenRouter, Qwen, MiniMax,
  GitHub Copilot, and the Codex/Gemini CLI bridges), with streaming events
  normalized to the same shapes regardless of provider.
- `Ai.ProviderRegistry` for registering and resolving providers at runtime, so
  a host application can add a provider without a fork.
- Reliability layer around every call: `Ai.RateLimiter` (per-provider token and
  request budgets), `Ai.CircuitBreaker` (opens on repeated provider failure and
  half-opens on a timer), and per-provider retry with respect for `Retry-After`.
- `Ai.CompactingClient` and `Ai.ContextCompactor` — context-window management
  that summarizes and drops history rather than failing the call.
- `Ai.Tokens` and `Ai.Text` for token accounting and text extraction, and
  `Ai.calculate_cost/2` for per-call cost from the model's price table.
- `Ai.Models` catalogue plus `Ai.ModelCache`, covering model IDs, context
  windows, capabilities and pricing.
- `Ai.Env` declares the 28 environment variables this package reads — provider
  credentials, endpoint overrides and client tuning — each with a type, default,
  documentation string and a secret flag. It is self-describing on its own and
  is picked up automatically by `LemonCore.Env` when both packages are present.
- `mix lemon.models` lists the catalogue from the command line.

### Notes

- `lemon_ai` depends on no other Lemon package. It is usable on its own in any
  Elixir project; `lemon_agent` and the rest of the platform build on top of it.
