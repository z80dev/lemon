# Decoupling Model Selection from Profile Binding

## Problem

Profiles provide useful defaults (tool policy and system prompt), but callers
must be able to choose a model at runtime (task, agent, or session) without
being locked to a profile model default.

## Goals

- Preserve profile-level behavior and policy defaults.
- Let callers specify a model independently from a profile.
- Keep the top-level execution path native and independent of model selection.
- Support clear precedence and resolution diagnostics.

## Final Design

### 1) Canonical run contract has top-level `model`

`LemonCore.RunRequest` includes `:model` so model overrides can be passed
explicitly rather than only through `meta`. The complete top-level path is
`RunRequest` → `ExecutionCommand` → `ExecutionRequest` →
`CodingAgent.Executor`; none of those request shapes carries a runner selector
or passes through a `Job` adapter.

### 2) Dedicated resolver module

`LemonRouter.ModelSelection` centralizes model resolution:

- **Model precedence**:
  1. request-level explicit model
  2. meta model (backward-compatible input)
  3. session policy model
  4. profile model
  5. config default model (`LemonCore.Config.cached().agent.default_model`,
     backed by `[defaults]`)

`SubmissionBuilder` also stores the resolved `history_model` in submission
metadata for routing-feedback history when that feature is enabled. Runtime
modules do not read `Application.get_env(:lemon_router, :default_model)`;
model defaults come from Lemon config or policy stores.

### 3) Fixed execution provenance

The native executor stamps top-level lifecycle events and persisted outcomes
with `engine: "lemon"`. This is run provenance, not a caller choice and not a
model-resolution result. `ResumeToken.engine` remains the persisted token
discriminator; the router accepts only `"lemon"` tokens for top-level resume.
Older `ChatState.last_engine` values remain stored as historical/native
discriminators and are quarantined from resumption when they are not native.

Delegated tasks run as native in-process subagent sessions (`CodingAgent.Session`
via `CodingAgent.Coordinator`) and record their own task provenance, but cannot
affect a product run's executor.

### 4) API/tool surface updates

- `agent` control-plane method accepts `model`.
- `agent.inbox.send` accepts `model`.
- `CodingAgent.Tools.Agent` accepts `model` and forwards it through
  `RunRequest.model`.
- `CodingAgent.Tools.Task` accepts `model` and `thinking_level` for
  internal-session subtasks.

## Why this works

Profiles continue to supply persona and tool defaults, while model selection is
controlled independently by request, session, and policy layers. The executor
does not vary.

## Future extensions

- Add capability checks (for example, tool-calling requirements versus a
  selected model).
- Expose model-resolution diagnostics in run inspection APIs.

## Provider/Credential Resolution Facade

Model *selection* (above) picks a model string. A separate, related problem is
provider and credential resolution: given a model or provider name, what are
its aliases, is it configured, does it have usable credentials, and what can a
caller actually pick from right now? That logic used to be reimplemented at
each call site. This section tracks the consolidation of that logic onto one
facade, phase by phase.

### Phase 1 (done, commit `74b0f20f`): model-catalog facade

`LemonAgent.ModelRuntime.ModelCatalog` (`apps/lemon_agent/lib/lemon_agent/model_runtime/model_catalog.ex`)
is now the single owner of "what can be picked from right now":

- Builds the provider/model catalog from `LemonAi.Models.list_models/0`.
- Filters to providers with usable credentials, including the provider-alias
  credential-fallback rules (e.g. `google-gemini-cli` also credential-checks
  under `google`; `amazon-bedrock` also checks `bedrock`/`aws`), backed by
  the existing `LemonAgent.ModelRuntime.Credentials`.
- Applies the picker health blocklist and sort order (newest/most-relevant
  first).
- Exposes `available_catalog/0`, `providers/1`, `models_for_provider/2`,
  `model_at_index/3`, `model_spec/1`, `model_label/1` as the read-only query
  surface, with its own unit tests
  (`apps/lemon_agent/test/lemon_agent/model_runtime/model_catalog_test.exs`).

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
- `apps/lemon_router/lib/lemon_router/model_selection.ex` is intentionally
  separate from provider/credential lookup: it applies top-level model
  precedence and returns the resolved model. It no longer maps model strings
  to runner identities or consults an engine catalog. Subagent delegation is
  native and in-process through the task APIs, so there is no
  provider-facade migration here.

### Remaining phases (not started)

These consumers still resolve provider/model/credential details locally and
are deferred to a later phase, since migrating them is not purely mechanical
(each has provider-specific request-shaping logic beyond "what's
available"):

- `apps/coding_agent/lib/coding_agent/session/model_resolver.ex` and
  `provider_fallback.ex` — per-session model resolution and the live
  fallback-chain walk (which provider to actually try next after a
  failure), as opposed to `ModelCatalog`'s "what's pickable" snapshot.
- `apps/lemon_cli/lib/lemon_cli/onboarding/providers.ex` (and the
  `LemonCli.Onboarding.Provider` struct it builds from in `onboarding/provider.ex`)
  — **boundary-blocked, not just deferred.** `lemon_cli` is only permitted to
  depend on `ai` and `lemon_core` (`docs/architecture_boundaries.md:18`), and
  `LemonAgent.ModelRuntime.ProviderNames` lives in `agent_core`, which isn't in
  that list. Migrating this file requires a deliberate governance decision
  first — either extend `lemon_cli`'s permitted deps to include `agent_core`,
  or move `ProviderNames` (or an equivalent) down into `ai`, which `lemon_cli`
  already depends on. Don't reach for a dynamic `Code.ensure_loaded?`/`apply`
  workaround to dodge this; it defeats the point of the boundary check.
  (`apps/lemon_cli/lib/lemon_cli/setup/provider.ex` has no local table at
  all — it's a thin wrapper delegating to `Mix.Tasks.Lemon.Onboard` — so
  nothing to migrate there regardless of the governance outcome.)
  Only a thin slice of the onboarding table actually overlaps
  `ProviderNames`: `id`, `aliases`, and `default_secret_name`/
  `default_secret_name_by_mode`. The rest (OAuth module refs into
  `LemonAi.Auth.*`, API-key prompts, choice labels, `oauth_opts_builder`, CLI
  switches, curated `preferred_models`) is onboarding-flow presentation data
  with no facade equivalent and stays local regardless of how the boundary
  question is resolved — same pattern as `arena_domains` presentation data.
  **Reconciliation prerequisite:** the two tables have already drifted, and
  this needs fixing as part of any future migration to stay
  behavior-preserving: `lemon_cli`'s table has aliases `ProviderNames` is
  missing (`"zhipu"` → `zai`, `"kimi-k2"` → `kimi`), and `ProviderNames` has
  an alias `lemon_cli`'s table is missing (`"gemini_cli"` → `google_gemini_cli`).
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
