# Decoupling Model Selection from Profile Binding

## Problem
Profiles currently provide useful defaults (engine, tool policy, system prompt), but users need to choose model independently at runtime (task/agent/session) without being locked to profile model defaults.

## Goals
- Preserve profile-level behavior and policy defaults.
- Let callers specify model independently from profile.
- Keep explicit engine selection possible.
- Support clear precedence and mismatch visibility.

## Final Design

### 1) Canonical run contract now has top-level `model`
`LemonCore.RunRequest` now includes `:model` so model overrides can be passed explicitly (not only via `meta`).

### 2) Dedicated resolver module
Added `LemonRouter.ModelSelection` to centralize resolution:

- **Model precedence**:
  1. request-level explicit model
  2. meta model (back-compat)
  3. session policy model
  4. profile model
  5. config default model (`LemonCore.Config.cached().agent.default_model`, backed by `[defaults]`)

`SubmissionBuilder` also stores the resolved `history_model` in submission
metadata for routing-feedback history when that feature is enabled. Runtime
modules should not read `Application.get_env(:lemon_router, :default_model)`;
model defaults come from Lemon config or policy stores.

- **Engine precedence**:
  1. resume token engine
  2. explicit `engine_id`
  3. model-implied engine (`codex:*`, `claude:*`, etc.)
  4. profile default engine

### 3) Mismatch warnings (non-blocking)
If explicit engine conflicts with model-implied engine, the system:
- keeps explicit engine (caller intent wins),
- records warning in `job.meta[:model_resolution_warning]`,
- logs warning in orchestrator.

### 4) API/tool surface updates
- `agent` control-plane method accepts `model`.
- `agent.inbox.send` accepts `model`.
- `CodingAgent.Tools.Agent` accepts `model` and forwards it through `RunRequest.model`.
- `CodingAgent.Tools.Task` accepts `model` and `thinking_level` for internal-session subtasks.

## Why this works
Profiles continue to supply persona/tool defaults, while model selection is independently controlled by request/session/runtime layers.

## Validation policy
No hard failures for engine/model mismatches yet; warnings only. This avoids breaking existing flows while making conflicts visible.

## Future extensions
- Add strict mode to reject incompatible engine/model combinations.
- Add capability checks (e.g., tool-calling requirements vs selected model).
- Expose model-resolution diagnostics in run inspection APIs.

## Provider/Credential Resolution Facade

Model *selection* (above) picks an engine and a model string. A separate,
related problem is provider/credential resolution: given a model or provider
name, what are its aliases, is it configured, does it have usable
credentials, and what can a caller actually pick from right now? That logic
used to be reimplemented at each call site. This section tracks the
consolidation of that logic onto one facade, phase by phase.

### Phase 1 (done, commit `74b0f20f`): model-catalog facade

`AgentCore.ModelRuntime.ModelCatalog` (`apps/agent_core/lib/agent_core/model_runtime/model_catalog.ex`)
is now the single owner of "what can be picked from right now":

- Builds the provider/model catalog from `Ai.Models.list_models/0`.
- Filters to providers with usable credentials, including the provider-alias
  credential-fallback rules (e.g. `google-gemini-cli` also credential-checks
  under `google`; `amazon-bedrock` also checks `bedrock`/`aws`), backed by
  the existing `AgentCore.ModelRuntime.Credentials`.
- Applies the picker health blocklist and sort order (newest/most-relevant
  first).
- Exposes `available_catalog/0`, `providers/1`, `models_for_provider/2`,
  `model_at_index/3`, `model_spec/1`, `model_label/1` as the read-only query
  surface, with its own unit tests
  (`apps/agent_core/test/agent_core/model_runtime/model_catalog_test.exs`).

It lives in `agent_core` rather than `ai` because `agent_core` is the
narrowest app that both depends on `ai` directly and is itself a permitted
dependency for apps (like `lemon_channels`) that are not allowed to depend on
`ai` per `docs/architecture_boundaries.md`.

Migrated consumers: `LemonChannels.Adapters.Telegram.Transport.ModelPicker`
and `.CallbackHandler` each carried a ~150-line pasted copy of catalog
building/filtering/sorting (net -530 LOC in `lemon_channels`); both now
delegate to `ModelCatalog`.

**Survey findings for the remaining candidate sites:**
- `apps/lemon_channels/lib/lemon_channels/model_policy*.ex` (the
  `LemonChannels.ModelPolicy` route-precedence store) is clean — it stores
  and resolves *policy* (which model/thinking-level a route prefers) by
  channel/account/peer/thread precedence, and never reimplements
  provider/credential lookups. No migration needed.
- `apps/lemon_router/lib/lemon_router/model_selection.ex` is an
  intentionally separate concern: it maps a model string to one of the six
  CLI *engines* (claude/codex/droid/kimi/opencode/pi) via
  `LemonCore.EngineCatalog.known?/1`, not to an LLM API provider
  (anthropic/openai/google/etc.). It already delegates to `EngineCatalog`
  and does not duplicate anything the provider/credential facade owns. Left
  untouched.

### Remaining phases (not started)

These consumers still resolve provider/model/credential details locally and
are deferred to a later phase, since migrating them is not purely mechanical
(each has provider-specific request-shaping logic beyond "what's
available"):

- `apps/coding_agent/lib/coding_agent/session/model_resolver.ex` and
  `provider_fallback.ex` — per-session model resolution and the live
  fallback-chain walk (which provider to actually try next after a
  failure), as opposed to `ModelCatalog`'s "what's pickable" snapshot.
- `apps/lemon_cli/lib/lemon_cli/onboarding/` and `setup/` provider files —
  interactive onboarding prompts that currently know provider names/env
  vars/setup steps directly; these should eventually read that from
  `AgentCore.ModelRuntime.ProviderNames` instead of their own tables.
- `apps/lemon_core/lib/lemon_core/provider_config_resolver.ex` and
  `provider_pool_rotator.ex` — provider-specific stream-option resolution
  (project/region/deployment-map/API-key assembly per provider) and
  round-robin pool rotation. These sit below the "what's available" facade
  layer (they resolve *how to call* a provider once selected) and need a
  design pass on where that boundary sits relative to `ModelCatalog` and
  `ProviderRouting` before migrating call sites.

Each of these should get the same treatment as phase 1: confirm the
boundary-permitted home for the shared logic, extract behavior-preserving,
add tests if the extracted logic was previously untested, then migrate call
sites one at a time with `mix lemon.quality` and the full test suite green
before moving to the next.
