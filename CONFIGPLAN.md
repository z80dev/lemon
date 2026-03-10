# Plan: Make Modular Config Canonical and Reduce User-Facing Config Surfaces

## Summary

Implement one canonical runtime configuration path based on modular config, remove TOML aliases immediately, collapse gateway transport config into that canonical path, centralize provider config resolution, and keep mutable “current value” behavior in runtime policy/state rather than config.

This pass is intentionally not backward compatible for deprecated TOML sections. Runtime must hard-fail when deprecated aliases are present. User-facing configuration after this pass is limited to:

- Global TOML: `~/.lemon/config.toml`
- Project TOML: `<cwd>/.lemon/config.toml`
- Environment overrides
- Lemon secrets referenced from TOML

Boot/test-only OTP app env remains allowed, but it is not part of the user-facing runtime config contract.

## Implementation Changes

### 1. Make modular config the only real implementation
- Make `LemonCore.Config.Modular` the sole parser/resolver for runtime config semantics.
- Remove duplicated parsing/merging logic from `LemonCore.Config`; keep `LemonCore.Config` only as a compatibility facade for existing callers that still expect the legacy struct shape.
- The facade must delegate to modular loading and convert modular output into the legacy struct shape; it must not keep its own parsing rules.
- Keep the existing `LemonCore.Config.load/cached/reload/get` public functions so call sites do not need a broad rename in this pass.
- Keep cache/reload infrastructure, but make it cache/load modular-backed config instead of the old independently-parsed path.
- Validation must run against the modular-backed result everywhere.

### 2. Remove deprecated TOML aliases completely
- Remove support for `[agent]` and `[agents.*]`.
- Remove support for old alias paths like `[agent.tools.*]`; only `[runtime.*]` is valid.
- Keep only:
  - `[defaults]`
  - `[runtime]`
  - `[profiles.<id>]`
  - `[providers.<name>]`
  - `[gateway]`
  - `[tui]`
  - `[logging]`
- Add validator errors for deprecated sections with explicit migration messages:
  - `[agent]` -> use `[defaults]` and `[runtime]`
  - `[agents.<id>]` -> use `[profiles.<id>]`
  - `[agent.tools.*]` -> use `[runtime.tools.*]`
- Runtime startup/reload must fail if deprecated sections are present; warnings are not enough.
- Update docs and AGENTS files to remove all “preferred vs legacy” wording.

### 3. Expand canonical schema so current real config can live there
- Keep `defaults.provider`, `defaults.model`, and `defaults.thinking_level` as config.
- Add `runtime.budget_defaults.max_children` so existing user intent from `[agent.budget_defaults]` has a canonical home.
- Extend provider schema beyond the current generic fields so modular config can represent all supported runtime-resolved provider settings:
  - Common providers: `api_key`, `api_key_secret`, `base_url`, `auth_source`, `oauth_secret`
  - `providers.google_vertex`: `project_secret`, `location_secret`, `service_account_json_secret`
  - `providers.azure_openai_responses`: `api_key_secret`, `base_url`, `resource_name`, `api_version`, `deployment_name_map`
  - `providers.amazon_bedrock`: `region`, `access_key_id_secret`, `secret_access_key_secret`, `session_token_secret`
- Add secret-ref companion fields for sensitive non-provider runtime settings that currently appear in plaintext config:
  - `gateway.telegram.bot_token_secret`
  - `gateway.discord.bot_token_secret`
  - `gateway.sms.auth_token_secret`
  - `gateway.xmtp.wallet_key_secret`
  - `runtime.tools.web.search.api_key_secret`
  - `runtime.tools.web.search.perplexity.api_key_secret`
  - `runtime.tools.web.fetch.firecrawl.api_key_secret`
- Preserve existing plaintext fields for these values for now, but resolve secrets through canonical config first-class so user config can be migrated off plaintext immediately.

### 4. Centralize env/secrets resolution behind modular config
- Provider runtime code must stop reading provider env vars directly for normal request paths.
- Resolve provider settings once from modular config plus env plus secrets in config adapters/resolvers, then pass concrete values to provider implementations through existing stream option shapes.
- Do not redesign provider APIs in this pass; preserve current request option shapes and populate them centrally:
  - Google Vertex: populate `project`, `location`, `service_account_json`
  - Azure OpenAI Responses: populate `api_key` and azure settings in the existing option fields used today
  - Amazon Bedrock: populate the existing header fields currently used for AWS region/credentials
- Remove implicit hidden provider secret-name fallbacks where config can specify the secret explicitly; after this pass, canonical config is the source of truth for secret references.
- Keep environment overrides supported, but only through the modular config layer, not by direct reads scattered across provider modules.

### 5. Collapse gateway transport config into canonical gateway config
- Simplify gateway loading so the runtime gateway config comes from the canonical modular gateway section only.
- Remove runtime merge behavior from:
  - `Application.get_env(:lemon_channels, :gateway)`
  - `Application.get_env(:lemon_channels, :telegram)`
  - `Application.get_env(:lemon_channels, :discord)`
  - `Application.get_env(:lemon_channels, :xmtp)`
- Update `LemonGateway.ConfigLoader`, `LemonCore.GatewayConfig`, `LemonChannels.GatewayConfig`, and transport/supervisor modules so they read a single resolved gateway config and do not re-merge transport-local app env.
- Keep one explicit test-only full replacement seam for gateway config so existing tests remain feasible:
  - `Application.get_env(:lemon_gateway, LemonGateway.Config)` may remain, but only as a test-only override path
  - Production/runtime code paths must ignore that override unless `Mix.env() == :test`
- Collapse transport credential resolution into canonical gateway config + secret refs:
  - SMS config reads canonical `gateway.sms`
  - Voice config moves under canonical `gateway.voice` or a clearly designated canonical gateway subsection and stops mixing app env + env + secrets ad hoc
  - Discord/Telegram/XMTP transport startup reads canonical gateway config only
- Remove stale/unsupported gateway keys from docs and migrated user config, including fields like `gateway.log_level` and `gateway.sms.enabled` that are not part of the real schema.

### 6. Make “current value” behavior runtime state, not config
- Keep default model and default thinking level in config only as defaults.
- Treat current per-session/per-route/per-chat values as runtime policy/state only.
- Keep `ModelPolicy`, session overrides, and project binding overrides as runtime state systems, not config systems.
- Remove app-env fallbacks that act like a second runtime policy plane for these behaviors:
  - `:lemon_router, :default_model`
  - `:lemon_router, :agent_policies`
  - `:lemon_router, :runtime_policy`
- Static agent tool policy must live in `[profiles.<id>.tool_policy]`.
- Dynamic operator/runtime policy must live in store-backed runtime policy/session policy, not app env.
- Document the distinction explicitly: config provides defaults; policy/state provides current effective value.

### 7. Update the actual user-local Lemon config files in the same implementation
- Directly migrate `/Users/z80/.lemon/config.toml` to canonical sections only.
- Rewrite the current file as follows:
  - Move `[agent] default_provider/default_model` into `[defaults]`
  - Add `defaults.thinking_level = "medium"` explicitly unless a different current default is desired in code review
  - Move `[agents.default]` and `[agents.coder]` into `[profiles.default]` and `[profiles.coder]`
  - Move `[agent.tools.web.search]` into `[runtime.tools.web.search]`
  - Remove `[agent.tools.wasm]` and keep only `[runtime.tools.wasm]`
  - Move `[agent.budget_defaults]` into `[runtime.budget_defaults]`
  - Keep `[gateway.*]` subsections, but replace plaintext secret values with secret-ref fields
- Migrate plaintext credentials currently present in the file into Lemon secrets:
  - Telegram bot token
  - Discord bot token
  - Brave search API key
  - Any other plaintext auth material found during implementation in user-local Lemon config files
- Preserve existing secret names already referenced in config; only create new secret names for fields that are currently plaintext and lack a secret ref.
- Archive and remove the legacy generator/input files:
  - `/Users/z80/.lemon/gateway.toml`
  - `/Users/z80/.lemon/config.json`
- Before editing/removing them, copy `config.toml`, `gateway.toml`, and `config.json` into a dated backup directory under `~/.lemon/migrations/`.
- Remove the “Generated from ~/.lemon/gateway.toml and ~/.lemon/config.json” comment from the migrated config.

### 8. Update docs and add regression guards
- Update config docs so they describe only the canonical sections and the actual post-change precedence.
- Update relevant AGENTS docs to remove alias references and describe the new contract:
  - modular config is canonical
  - gateway transport config comes only from canonical gateway config
  - current model/thinking overrides are runtime state
- Add a small architecture/quality guard that fails if targeted runtime modules reintroduce forbidden config access patterns.
- The guard should explicitly allow:
  - `config/*.exs`
  - boot/test infrastructure modules
  - test files
- The guard should block new direct env/app-env reads in the canonical-config domains being cleaned up in this pass.

## Test Plan

- Loader/validator tests:
  - Canonical config loads correctly from global + project + env using the modular path.
  - `[agent]`, `[agents]`, and `[agent.tools.*]` cause hard validation/runtime failures with exact migration guidance.
  - `runtime.budget_defaults.max_children` resolves correctly into coding-agent budget defaults.
  - New secret-ref fields resolve correctly for gateway and tool credentials.
  - New provider-specific schema fields resolve correctly for Google Vertex, Azure OpenAI Responses, and Amazon Bedrock.
- Provider resolution tests:
  - Google Vertex stream options get project/location/service_account_json from canonical config, with no direct provider env dependency.
  - Azure OpenAI Responses gets api key and azure settings from canonical config-driven resolution.
  - Amazon Bedrock gets region/credentials from canonical config-driven resolution.
- Gateway tests:
  - Runtime gateway config ignores `:lemon_channels` transport app-env overlays.
  - Test-only `:lemon_gateway, LemonGateway.Config` override still works in test env.
  - Telegram/Discord/XMTP/SMS/Voice transport startup reads only the canonical gateway config path.
- Runtime state tests:
  - Config defaults still seed model/thinking selection.
  - Session and route policy overrides still take precedence over config defaults.
  - App-env `:default_model`, `:agent_policies`, and `:runtime_policy` no longer affect runtime behavior.
- Local migration verification:
  - `/Users/z80/.lemon/config.toml` loads cleanly after the code change.
  - `/Users/z80/.lemon/gateway.toml` and `/Users/z80/.lemon/config.json` are backed up and removed from active use.
  - No plaintext secrets remain in the migrated user config.
- Regression/architecture checks:
  - Forbidden direct `System.get_env` / `Application.get_env` reads are absent from the cleaned-up runtime modules.

## Assumptions and Defaults

- `LemonCore.Config` remains as a facade for now to avoid a large call-site migration, but it must stop owning independent config semantics.
- Test-only gateway override compatibility is preserved; production runtime no longer has a second gateway transport override plane.
- Plaintext sensitive values remain parseable where already supported, but the implementation will migrate the actual user config to secret refs immediately.
- `defaults.thinking_level` will be written as `"medium"` in the migrated user config unless implementation confirms a different existing intended default.
- `runtime.budget_defaults.max_children = 16` is preserved from the current user config.
- Existing provider secret names already referenced in user config stay unchanged; new names are created only for current plaintext fields.
