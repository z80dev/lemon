# PLN-20260223: Encrypted Secrets Store as Preferred Secret Access Path

**Status:** Proposed
**Branch:** `feature/pln-20260223-secrets-store-preferred`
**Created:** 2026-02-23
**Depends on:** [PLN-20260223-macos-keychain-secrets-audit](PLN-20260223-macos-keychain-secrets-audit.md)

## Goal

Make the encrypted secrets store (`LemonCore.Secrets`) the canonical, preferred method for all secret access across the umbrella — replacing direct `System.get_env` calls for API keys, tokens, and credentials. Environment variables become a bootstrapping/fallback mechanism rather than the primary path.

## Motivation

Today, most apps bypass the encrypted store and read secrets directly from environment variables:

- **`ai`** — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AZURE_OPENAI_API_KEY`, `OPENAI_CODEX_API_KEY`, `CHATGPT_TOKEN`
- **`lemon_channels`** — `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_BEARER_TOKEN`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`, `X_API_CONSUMER_KEY`, `X_API_CONSUMER_SECRET`, `X_API_ACCESS_TOKEN_SECRET`
- **`coding_agent`** — `PERPLEXITY_API_KEY`, `OPENROUTER_API_KEY`, `FIRECRAWL_API_KEY`
- **`lemon_skills`** — `GITHUB_TOKEN`

This leaves secrets unencrypted in shell history, `.env` files, and process environment tables. The encrypted store already exists and works — it just isn't wired in everywhere.

`MarketIntel.Secrets` demonstrates the target pattern: store-first resolution with env fallback.

## Milestones

- [ ] **M1** — Shared secrets resolution behaviour and adapter
  - Extract the store-first-then-env pattern from `MarketIntel.Secrets` into a reusable behaviour or helper in `LemonCore.Secrets`
  - Define a standard `resolve/2` contract all apps can call: `LemonCore.Secrets.resolve(name, opts)`
  - Ensure the resolution order is: encrypted store -> env var -> `{:error, :not_found}`

- [ ] **M2** — Migrate AI provider secret access
  - Replace `System.get_env("ANTHROPIC_API_KEY")` etc. in `ai` providers with `LemonCore.Secrets.resolve/2`
  - Cover: Anthropic, OpenAI (completions + responses + codex), Bedrock (3 AWS keys), Azure OpenAI, Google
  - Maintain backward compatibility: existing env vars still work as fallback

- [ ] **M3** — Migrate channel and agent secret access
  - `lemon_channels` X API adapter and OAuth1 client — replace all `System.get_env` calls
  - `coding_agent` websearch (`PERPLEXITY_API_KEY`, `OPENROUTER_API_KEY`) and webfetch (`FIRECRAWL_API_KEY`)
  - `lemon_skills` discovery (`GITHUB_TOKEN`)

- [ ] **M4** — Import tooling and operational migration
  - `mix lemon.secrets.import_env` task: scan known env var names, import present values into the encrypted store
  - `mix lemon.secrets.check` task: report which secrets are in-store vs env-only vs missing
  - Update `mix lemon.secrets.status` to show per-app resolution source

- [ ] **M5** — Documentation and deprecation notices
  - Update operator/setup docs to recommend `mix lemon.secrets.init` + `mix lemon.secrets.set` as the primary setup path
  - Add deprecation log warnings when secrets are resolved from env vars (configurable, off by default)
  - Document migration guide for moving from env vars to the store

## Scope

### In Scope
- Wiring all umbrella apps to resolve secrets through `LemonCore.Secrets.resolve/2`
- Keeping env var fallback for backward compatibility (no breaking changes)
- Import tooling to migrate existing env-based secrets into the store
- Audit/check tooling for operators to verify their secret sources
- Deprecation warnings (opt-in) for env-based resolution

### Out of Scope
- Removing env var fallback entirely (future consideration)
- Non-macOS keychain backends (Linux secret service, etc.)
- Runtime secret rotation or TTL enforcement
- Secrets UI or web dashboard
- Changes to the encryption scheme itself (covered by keychain audit plan)

## Success Criteria

- [ ] Zero direct `System.get_env` calls for API keys/tokens/credentials in app code (outside test/config)
- [ ] All secret access goes through `LemonCore.Secrets.resolve/2` with env fallback
- [ ] `mix lemon.secrets.import_env` successfully imports env-based secrets into the store
- [ ] `mix lemon.secrets.check` reports resolution source for all known secrets
- [ ] Existing env-var-only setups continue to work with no configuration changes
- [ ] `mix lemon.quality` passes after all migrations
- [ ] Test coverage for resolution paths in each migrated app

## Test Strategy

- Unit tests per provider/adapter verifying store-first resolution and env fallback
- Integration test for `import_env` task: set env vars, run import, verify store contents
- Integration test for `check` task: mixed store/env/missing scenarios
- Regression: ensure apps still boot and function with only env vars set (no store)
- Regression: ensure apps function with only store set (no env vars)

## Progress Log

| Timestamp | Milestone | Note |
|-----------|-----------|------|
| 2026-02-23T00:00 | -- | Plan created; proposed as roadmap entry for secrets-store-preferred migration |
