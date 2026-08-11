# AI Boundary Extraction Plan

Status: boundary extraction complete; repo extraction still optional/future. 2026-07-02 review: `apps/lemon_ai` confirmed dependency-free (mix.exs); `lemon_ai_runtime` completion/removal is an open decision in the current direction plan.

Last reviewed: 2026-07-02

## Summary

This plan defines how to move Lemon-specific auth, config, and storage concerns
out of `apps/lemon_ai` before extracting `ai` into its own repository.

The key decision is to invert the current boundary first:

- Lemon resolves provider configuration, secrets, and OAuth state
- Lemon passes fully-resolved runtime options into `LemonAi`
- `LemonAi` becomes a generic LLM library responsible only for model metadata,
  request construction, streaming, parsing, and provider-specific protocol logic

`apps/lemon_ai` no longer depends on `lemon_core`; Lemon-owned auth/config/storage
resolution now lives in `apps/lemon_ai_runtime`. Extraction into a separate repo
should happen only after confirming external callers no longer depend on
storage-backed `LemonAi.Auth.*` behavior.

## Problem Statement

Before the boundary extraction, `apps/lemon_ai` was two things at once:

1. a reusable LLM abstraction layer
2. a Lemon-integrated runtime adapter

The reusable part is valuable on its own. The Lemon-integrated part is what
currently blocks extraction.

Those Lemon-owned concerns have moved out of `apps/lemon_ai`:

- secret lookup and persistence
- canonical provider config resolution
- prompt diagnostics persistence
- telemetry sink wiring
- local OAuth callback handling

Before that move, extracting `ai` directly would have either:

- drag Lemon runtime concepts into a new repo, or
- break existing callers that rely on Lemon-owned secret and OAuth behavior

Both outcomes are worse than doing the boundary cleanup first.

## Goals

- Make `apps/lemon_ai` independent of `lemon_core`
- Make auth/config/storage ownership explicitly Lemon-side
- Keep the public `LemonAi` request API stable where practical
- Preserve current provider coverage and behavior during migration
- Make a later repo extraction mechanically simple

## Non-Goals

- Rewriting the provider stack
- Redesigning the `LemonAi.Types` data model
- Collapsing `agent_core` / `coding_agent` abstractions during this work
- Publishing a Hex package in phase 1
- Solving every cross-app callsite in a single PR

## Boundary Rules

These rules should be treated as the target architecture.

### What `LemonAi` should own

- `LemonAi.Types`
- `LemonAi.Models`
- `LemonAi.EventStream`
- provider registry and provider implementations
- request building and response parsing
- stream lifecycle handling
- provider-local retry and protocol normalization
- model capability metadata and cost calculations
- OAuth protocol logic (token refresh HTTP calls, PKCE, etc.) — generic and
  reusable, but refresh functions must **return** new tokens/payloads, not
  persist them

### What Lemon should own

- secret lookup from `LemonCore.Secrets`
- provider config lookup from canonical Lemon config
- OAuth login flows and token persistence
- persistence of refreshed OAuth tokens (the caller in `lemon_ai_runtime`
  stores the result returned by `LemonAi.Auth.*` refresh functions)
- provider-specific runtime credential assembly
- prompt diagnostics persistence and introspection
- telemetry routing policy

### The core rule

**`apps/lemon_ai` must not import or call any `LemonCore.*` module.** No
`LemonCore.Secrets`, no `LemonCore.ProviderConfigResolver`, no Lemon-specific
onboarding modules, no `LemonCore.Introspection`. If `LemonAi` needs
something Lemon-specific, the caller must resolve it first and pass it in.

OAuth refresh protocol logic (HTTP calls, PKCE helpers) can stay in
`LemonAi.Auth.*` — that's generic. But the persistence side (reading/writing
secrets) must live in `lemon_ai_runtime`.

### Allowed data crossing into `LemonAi`

Only resolved runtime inputs should cross the boundary, for example:

- `api_key`
- `access_token`
- `headers`
- `project`
- `location`
- `service_account_json`
- provider-specific resolved options

No Lemon secret names, no config refs, and no storage handles should cross into
`LemonAi`.

## Current Coupling Inventory

As of 2026-04-24, `apps/lemon_ai/lib` has no `LemonCore.*`,
`LemonCore.Secrets`, `LemonCore.ProviderConfigResolver`, or Lemon-specific
onboarding references. The old violation inventory below is kept as
historical context for the migration.

The main categories of current coupling are:

### 1. Secret resolution inside `LemonAi`

Multiple providers still call `LemonCore.Secrets` internally for API key
fallbacks.

Representative examples:

- `LemonAi.Providers.Anthropic`
- `LemonAi.Providers.OpenAICompletions`
- `LemonAi.Providers.OpenAIResponses`
- `LemonAi.Providers.Google`
- `LemonAi.Providers.AzureOpenAIResponses`
- `LemonAi.Models` OpenAI discovery path

### 2. Provider config resolution inside `LemonAi`

Some providers still call `LemonCore.ProviderConfigResolver` internally.

Affected providers:

- `LemonAi.Providers.GoogleVertex`
- `LemonAi.Providers.AzureOpenAIResponses`
- `LemonAi.Providers.Bedrock`

### 3. OAuth resolution and persistence inside `LemonAi`

`LemonAi.Auth.*` modules currently mix:

- OAuth protocol logic
- Lemon secret decoding
- token refresh
- refreshed secret persistence
- local callback listener integration

This is the largest boundary violation because it combines provider logic with
storage ownership.

### 4. Diagnostics and telemetry coupling

`LemonAi` emits via Lemon-owned telemetry and prompt diagnostics sinks today.

This is operationally useful, but it should be adapter-driven rather than a hard
dependency.

### 5. External callers using `LemonAi.Auth.*`

Some Lemon apps call `LemonAi.Auth.*` directly, especially for OAuth-backed provider
resolution.

This means the migration must include caller updates, not just `apps/lemon_ai`
changes.

## Architecture Decision

Introduce a Lemon-side runtime boundary that produces **resolved AI call
options**.

The intended flow is:

1. Lemon loads provider config from canonical config
2. Lemon resolves secret refs and OAuth payloads
3. Lemon refreshes tokens and persists them if needed
4. Lemon constructs final `LemonAi` stream options
5. Lemon calls `LemonAi.stream/3` or `LemonAi.complete/3`
6. `LemonAi` performs the provider call without any Lemon dependency

This keeps provider protocol logic in `LemonAi` while moving ownership of state and
configuration to Lemon.

## Proposed Module Split

Do **not** move Lemon-owned auth/config code into `lemon_core` blindly.
`lemon_core` should remain low-level and broadly reusable inside the umbrella.

Preferred split:

### Keep in `apps/lemon_ai`

- provider modules
- pure OAuth protocol utilities only if they have no storage dependency
- PKCE helpers if they are generic and storage-free
- model registry and request helpers

### Move out of `apps/lemon_ai`

- secret-backed OAuth resolvers
- secret persistence of refreshed OAuth credentials
- local callback listener coupling
- provider config resolution adapters
- prompt diagnostics persistence adapter

### Preferred Lemon-side home

Create a Lemon-owned runtime adapter layer, likely one of:

- `apps/lemon_ai_runtime`
- `apps/lemon_ai_integration`
- `apps/lemon_agent` if the ownership is clearly agent-runtime-specific

Recommendation:

- use a dedicated app such as `lemon_ai_runtime`

Reason:

- this keeps `lemon_core` foundational
- avoids bloating `agent_core` with config/secrets concerns
- gives the eventual external `ai` repo a single integration counterpart on the
  Lemon side

## Public Interface Direction

### Near-term

Keep `LemonAi.stream/3` and `LemonAi.complete/3` intact.

Use `LemonAi.Types.StreamOptions` as the resolved boundary object for now.

### Medium-term

Add a generic field for provider-specific resolved values, such as:

```elixir
provider_options: %{}
```

Reason:

- current fields like `project`, `location`, `access_token`, and
  `service_account_json` already show that resolved runtime state belongs in the
  call options
- a generic map prevents the struct from growing one field per provider

This should be additive first, not a breaking change.

## Migration Phases

### Phase 1: Freeze the boundary contract ✅

### Phase 2: Introduce Lemon-side resolved option builders ✅

`apps/lemon_ai_runtime` exists with credentials, stream options, provider
names, and auth resolvers for all 5 OAuth providers. Already used by
`coding_agent`, `lemon_sim`, `lemon_channels`.

### Phase 3: Remove `LemonCore.*` calls from `apps/lemon_ai` ✅

This was the core remaining work. Historical violations (as of 2025-07-14):

**`LemonCore.Secrets`** (6 providers + `LemonAi.Models` + 5 auth modules):
- `LemonAi.Providers.Anthropic`
- `LemonAi.Providers.OpenAICompletions`
- `LemonAi.Providers.OpenAIResponses`
- `LemonAi.Providers.Google`
- `LemonAi.Providers.AzureOpenAIResponses`
- `LemonAi.Providers.MistralConversations`
- `LemonAi.Models`
- `LemonAi.Auth.AnthropicOAuth`
- `LemonAi.Auth.GitHubCopilotOAuth`
- `LemonAi.Auth.GoogleAntigravityOAuth`
- `LemonAi.Auth.GoogleGeminiCliOAuth`
- `LemonAi.Auth.OpenAICodexOAuth`

**`LemonCore.ProviderConfigResolver`** (3 providers):
- `LemonAi.Providers.AzureOpenAIResponses`
- `LemonAi.Providers.Bedrock`
- `LemonAi.Providers.GoogleVertex`

**`LemonCore.OAuth.LocalCallbackListener`** (3 auth modules):
- `LemonAi.Auth.GoogleAntigravityOAuth`
- `LemonAi.Auth.GoogleGeminiCliOAuth`
- `LemonAi.Auth.OpenAICodexOAuth`

**`LemonCore.Telemetry`** (4 modules):
- `LemonAi.CallDispatcher`
- `LemonAi.CircuitBreaker`
- `LemonAi.CompactingClient`
- `LemonAi.ContextCompactor`

**`LemonCore.Introspection`** (1 module):
- `LemonAi.PromptDiagnostics`

For each: the caller (`lemon_ai_runtime` or the calling app) must resolve
the value and pass it in via options. Providers should require credentials
via `opts` and raise if missing — no `LemonCore.Secrets` fallback, no
`System.get_env` fallback. All "where do I find the key" logic belongs
exclusively in `lemon_ai_runtime`. `LemonAi.Auth.*` refresh functions should
return new tokens rather than persisting them.

`LemonCore.Telemetry` is lower priority — standard observability coupling
is less harmful than secret/config coupling.

### Phase 4-7: (unchanged from original plan)

See PR Sequence below for the mechanical steps. The old phase descriptions
are preserved for reference but the concrete violation list above is the
source of truth for remaining work.

### Phase 4: Remove Lemon secret/config lookups from provider modules

Provider modules should stop calling `LemonCore.Secrets` and
`LemonCore.ProviderConfigResolver`.

Target behavior:

- explicit options first
- optional plain environment-variable fallback only where appropriate
- no Lemon-owned storage or config resolution

### Phase 5: Replace diagnostics and telemetry hard dependencies

Two acceptable end states:

1. `LemonAi` emits plain `:telemetry` events directly
2. `LemonAi` uses small optional adapter behaviours configured by the host app

Recommendation:

- use direct `:telemetry` events for operational events
- move prompt diagnostics persistence to Lemon-side call wrappers

That keeps `LemonAi` generic and avoids a custom integration layer where standard
telemetry already works.

### Phase 6: Split or remove `LemonAi.Auth.*`

There are two workable options:

#### Option A: move all OAuth logic out of `LemonAi`

Pros:

- cleanest package boundary
- `LemonAi` becomes purely request/response focused

Cons:

- Lemon must own more provider-specific auth code

#### Option B: keep only pure OAuth protocol helpers in `LemonAi`

Pros:

- reusable provider auth handshake logic can still ship with `LemonAi`

Cons:

- requires careful enforcement so storage and persistence do not creep back in

Recommendation:

- use Option B
- keep only pure protocol helpers in `LemonAi`
- move all secret decoding, token storage, refresh persistence, and callback
  listener integration into Lemon-owned code

### Phase 7: Extract `apps/lemon_ai` to its own repo

Do this only when:

- `apps/lemon_ai/mix.exs` no longer depends on `lemon_core`
- no production Lemon app depends on `LemonAi.Auth.*` for storage-backed resolution
- docs describe `LemonAi` as a standalone library, not as a Lemon subsystem

Then:

1. move `apps/lemon_ai` into its own git repo
2. publish via git dependency first
3. switch umbrella apps from `in_umbrella: true` to external dep
4. stabilize versioning
5. decide later whether Hex publishing is worth the maintenance cost

## PR Sequence

This should be done as a short sequence of reviewable PRs, not one large
refactor.

### PR 1: plan + boundary docs

- add this plan
- document the target boundary in `apps/lemon_ai`
- document that Lemon owns secret/config resolution

### PR 2: Lemon-side runtime resolver scaffold

- add the Lemon-owned runtime adapter modules
- define the resolved option contract
- keep old `LemonAi` behavior intact for compatibility

### PR 3: caller migration

- migrate `coding_agent`
- migrate `lemon_sim`
- migrate `lemon_channels`
- remove cross-app reliance on `LemonAi.Auth.*`

### PR 4: provider cleanup inside `LemonAi`

- remove `LemonCore.Secrets` lookups
- remove `ProviderConfigResolver` usage
- make providers explicit-input based

### PR 5: diagnostics + telemetry cleanup

- replace `LemonCore.Telemetry` dependency
- move prompt diagnostics persistence outside `LemonAi`

### PR 6: OAuth module split

- keep pure OAuth protocol utilities if still valuable
- move Lemon-owned secret persistence and callback integration out of `LemonAi`

### PR 7: externalization

- move to standalone repo
- update umbrella deps
- update build and release docs

## Risks

### Risk: hidden callsites

There are already external callers using `LemonAi.Auth.*`. Missing one will leave a
partial boundary and cause extraction friction later.

Mitigation:

- inventory all `LemonAi.Auth.*` callsites before implementation
- fail CI on remaining cross-app uses once the migration lands

### Risk: provider regressions

Moving auth/config resolution can easily break provider-specific edge cases.

Mitigation:

- migrate provider-by-provider
- keep integration tests for OAuth-backed and config-heavy providers
- compare before/after resolved request shapes where practical

### Risk: `lemon_core` bloat

Pushing provider-specific resolution into `lemon_core` would make the base app
too high-level.

Mitigation:

- keep `lemon_core` focused on primitives
- place provider/runtime adapters in a separate app

### Risk: interface churn

If the resolved option contract changes too often, callers will thrash.

Mitigation:

- define the target option shape early
- add fields rather than renaming aggressively

## Testing Strategy

### Unit tests

- Lemon runtime resolvers return expected resolved `StreamOptions`
- OAuth secret payload decoding and refresh persistence happen entirely outside
  `LemonAi`
- provider modules accept resolved values and no longer require Lemon state

### Integration tests

- OpenAI Codex with stored OAuth secret
- GitHub Copilot with stored OAuth secret
- Gemini CLI / Antigravity secret payload handling
- Vertex with resolved project/location/token
- Azure with resolved config
- Bedrock with resolved credentials

### Structural tests

- `apps/lemon_ai` has no compile-time dependency on `lemon_core`
- no remaining `LemonCore.*` references inside `apps/lemon_ai`
- no production callers outside `apps/lemon_ai` depend on storage-backed `LemonAi.Auth.*`

## Recommendation

Proceed with a boundary-inversion migration before any repo split.

The correct sequence is:

1. introduce Lemon-side resolved runtime adapters
2. migrate all callers to them
3. remove Lemon dependencies from `apps/lemon_ai`
4. extract `ai` only after the boundary is clean

That gives Lemon a stable ownership model for config, secrets, and OAuth state
while leaving `LemonAi` as the reusable library you actually want to extract.
