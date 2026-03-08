# Router Queue/Session Authority Decision And Next-Step Implementation Spec

This document does two things:

1. It makes an explicit architecture decision about queue/session authority.
2. It turns the remaining “what to do next” work into an agent-implementable spec with exact files, APIs, acceptance criteria, and verification commands.

This spec is based on the current repository state in the uploaded codebase.

---

## 1. Decision

## 1.1 Chosen architecture

**Queue/session authority belongs in `lemon_router`, not in `lemon_gateway`.**

That is the architecture the codebase has already converged on, and it is the correct one to finish.

Do **not** move queue semantics back into gateway.

---

## 1.2 Why this is the right choice

This is not just preference. It matches the current contracts and separation of concerns:

- `LemonRouter.SessionCoordinator` explicitly states it is the **router-owned owner of per-conversation queue semantics** (`apps/lemon_router/lib/lemon_router/session_coordinator.ex:1-6`).
- `LemonRouter.ConversationKey` is router-owned and resolves conversation identity from `session_key` plus structured resume token (`apps/lemon_router/lib/lemon_router/conversation_key.ex:1-35`).
- `LemonGateway.ExecutionRequest` explicitly documents itself as **queue-semantic-free** and requires a **router-owned conversation_key** (`apps/lemon_gateway/lib/lemon_gateway/execution_request.ex:1-19`, `68-77`).
- `LemonGateway.ThreadWorker` explicitly documents that queue semantics are owned by router and that the worker is only a launcher/slot waiter (`apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex:1-6`).
- `docs/architecture_boundaries.md` already encodes the same rule: gateway owns execution slots and engine lifecycle, while router owns queue semantics, auto-resume request mutation, and conversation-key selection (`docs/architecture_boundaries.md:47-47`).

If gateway were made authoritative instead, it would have to re-own things that are already clearly product/conversation concerns:

- `collect`, `followup`, `steer`, `steer_backlog`, `interrupt`
- followup merge/debounce behavior
- session-vs-resume conversation identity
- structured auto-resume behavior
- per-conversation active-run handoff semantics

That would either:
- bloat `LemonGateway.ExecutionRequest` back into a product-level contract, or
- force gateway to rediscover router-owned concepts internally.

Both are worse than the current direction.

---

## 1.3 Consequences of this decision

From now on, these rules are normative:

1. `lemon_router` owns:
   - conversation key selection
   - queue semantics
   - session busy/active queries
   - session abort semantics
   - router-facing public APIs for those concerns

2. `lemon_gateway` owns:
   - execution slots
   - per-conversation launch ordering **after** router decisions are made
   - engine process lifecycle
   - run cancellation at the run-process level
   - no queue mode semantics

3. `SessionRegistry` may remain **only** as an internal router read-model implementation detail.
   - It is **not** an architectural authority.
   - No external app may read it directly.
   - External apps must go through router APIs / `LemonCore.RouterBridge`.

4. `SessionReadModel` is acceptable only as a router-internal implementation detail.
   - No external app may call it directly.
   - Prefer router/bridge APIs.

---

## 2. Scope of this spec

This spec covers three workstreams:

1. **Codify router-owned session authority and remove ambiguity**
2. **Finish shared primitive cleanup (`EngineCatalog`, `ResumeToken`, `Cwd`)**
3. **Finish cleanup of remaining raw-store callers, stale docs, and shims**

This spec does **not** attempt to:
- redesign queue semantics again
- move queue ownership into gateway
- delete `SessionRegistry` if doing so would create unnecessary churn right now

The target is **architectural clarity**, not speculative rewrite.

---

## 3. Workstream A — codify router-owned session authority

### Goal

Make `lemon_router` the **only public authority** for session/queue state, while allowing `SessionRegistry` to remain as an internal implementation detail if that is the cheapest read-model.

### Problem to fix

The code already chose router ownership, but there is still ambiguity because:

- `Router.abort/2` still contains a compatibility fallback via `SessionReadModel` (`apps/lemon_router/lib/lemon_router/router.ex:143-153`)
- `Router.session_busy?/1` still delegates straight to `SessionReadModel` (`apps/lemon_router/lib/lemon_router/router.ex:156-159`)
- `LemonChannels.Runtime.session_busy?/1` still has a fallback to `LemonRouter.SessionReadModel` (`apps/lemon_channels/lib/lemon_channels/runtime.ex:68-82`)
- `LemonControlPlane.Methods.SessionsActive` still directly reads `LemonRouter.SessionRegistry` and documents it as the backend (`apps/lemon_control_plane/lib/lemon_control_plane/methods/sessions_active.ex:1-34`)
- external tests in `lemon_channels` and `lemon_control_plane` still touch `LemonRouter.SessionRegistry` directly

That makes the chosen architecture look transitional instead of intentional.

---

### A.1 Required public API surface

Implement these router-owned query/control APIs.

#### In `LemonRouter.SessionCoordinator`

Add these functions:

```elixir
@spec active_run_for_session(binary()) :: {:ok, binary()} | :none
def active_run_for_session(session_key)

@spec busy?(binary()) :: boolean()
def busy?(session_key)

@spec list_active_sessions() :: [%{session_key: binary(), run_id: binary()}]
def list_active_sessions()
```

Implementation guidance:

- It is acceptable for these functions to delegate to `SessionReadModel` internally.
- It is also acceptable for them to read `SessionRegistry` directly internally.
- Do **not** expose `SessionRegistry` or `SessionReadModel` as public contracts outside router.

Reason:
- `SessionCoordinator` is the authoritative owner.
- Query APIs should live on the same boundary, even if storage is internal.

#### In `LemonRouter.Router`

Add or standardize these functions:

```elixir
@spec active_run(binary()) :: {:ok, binary()} | :none
def active_run(session_key)

@spec list_active_sessions() :: [%{session_key: binary(), run_id: binary()}]
def list_active_sessions()
```

Update existing functions:

- `abort/2` must call only `SessionCoordinator.abort_session/2`
- `session_busy?/1` must call `SessionCoordinator.busy?/1`

**Remove** the compatibility fallback in `abort/2` that calls `SessionReadModel.active_run/1`.

The target behavior is:

```elixir
def abort(session_key, reason \ :user_requested) do
  LemonRouter.SessionCoordinator.abort_session(session_key, reason)
  :ok
end

def session_busy?(session_key) when is_binary(session_key) do
  LemonRouter.SessionCoordinator.busy?(session_key)
end

def active_run(session_key) when is_binary(session_key) do
  LemonRouter.SessionCoordinator.active_run_for_session(session_key)
end

def list_active_sessions do
  LemonRouter.SessionCoordinator.list_active_sessions()
end
```

Reason:
- Router is the public owner.
- Compatibility fallback keeps the old “maybe router, maybe registry” ambiguity alive.

#### In `LemonCore.RouterBridge`

Add bridge functions so external apps do not need to know about router internals:

```elixir
@spec active_run(binary()) :: {:ok, binary()} | :none
def active_run(session_key)

@spec list_active_sessions() :: list()
def list_active_sessions()
```

Implementation pattern should match existing bridge functions such as `abort_session/2` and `session_busy?/1`.

Behavior:
- return `:none` / `[]` when router is unavailable
- do not raise
- preserve fail-soft behavior

Reason:
- external apps should use RouterBridge, not router internals or registries

---

### A.2 Required call-site migrations

#### File: `apps/lemon_channels/lib/lemon_channels/runtime.ex`

Current problem:
- it still references `LemonRouter.SessionReadModel` dynamically

Required change:
- delete `@session_read_model_mod`
- make `session_busy?/1` use only `LemonCore.RouterBridge.session_busy?/1`
- do not fall back to router internals

Target behavior:

```elixir
def session_busy?(session_key) when is_binary(session_key) and session_key != "" do
  LemonCore.RouterBridge.session_busy?(session_key)
rescue
  _ -> false
end
```

Reason:
- channels should know only the router boundary, not router internal read models

#### File: `apps/lemon_control_plane/lib/lemon_control_plane/methods/sessions_active.ex`

Current problem:
- it reads `Registry.lookup(LemonRouter.SessionRegistry, ...)` directly
- its moduledoc claims it is “backed by SessionRegistry”

Required change:
- call `LemonCore.RouterBridge.active_run(session_key)` instead
- update moduledoc to say it is backed by router-owned session authority and is best-effort/local-node state

Target response logic:

```elixir
run_id =
  case LemonCore.RouterBridge.active_run(session_key) do
    {:ok, run_id} -> run_id
    :none -> nil
  end
```

Reason:
- control plane should query router’s public authority, not router internals

#### File: `apps/lemon_router/lib/lemon_router/agent_directory.ex`

Current problem:
- it still uses `SessionReadModel.list_active()`

Required change:
- call `LemonRouter.Router.list_active_sessions/0` or `SessionCoordinator.list_active_sessions/0`
- do not reference `SessionReadModel` here unless you intentionally keep it private and routed through coordinator

Preferred target:
- use `Router.list_active_sessions/0` if that does not create circular dependency issues inside the same app
- otherwise use `SessionCoordinator.list_active_sessions/0`

Reason:
- keep a single obvious public query surface

---

### A.3 Documentation updates

Update these files:

- `apps/lemon_router/README.md`
- `apps/lemon_router/AGENTS.md`
- `apps/lemon_channels/README.md`
- `docs/architecture_boundaries.md`

Required doc changes:

#### `apps/lemon_router/README.md`
Keep the statement that router owns queue semantics.

Change the wording around `SessionReadModel` to:

- `SessionReadModel` is an internal read-model implementation detail
- external apps must use `LemonRouter.Router` / `LemonCore.RouterBridge`

#### `apps/lemon_router/AGENTS.md`
Change any wording that makes `SessionRegistry` sound like a public boundary.
It should say:

- `SessionCoordinator` is the owner
- `SessionRegistry` is an internal read-model used by router internals

#### `apps/lemon_channels/README.md`
Current wording says busy checks go through `RouterBridge.session_busy?/1` **or the router read model**.

Change it to:

- busy checks go through `LemonCore.RouterBridge` only
- channels must not reference `SessionReadModel` or `SessionRegistry`

#### `docs/architecture_boundaries.md`
Add a concrete runtime-ownership bullet:

- No app outside `lemon_router` may reference `LemonRouter.SessionRegistry` or `LemonRouter.SessionReadModel` directly.
- All cross-app session busy/active/cancel interactions must go through `LemonCore.RouterBridge` (or router public APIs inside the router app).

---

### A.4 Architecture guardrails

Edit `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`.

Add a new rule:

```elixir
%{
  code: :external_router_session_state_dependency,
  message:
    "Apps outside lemon_router must not depend on LemonRouter.SessionRegistry or LemonRouter.SessionReadModel directly",
  files: ["apps/**/*.ex"],
  exclude: ["apps/lemon_router/lib/**/*.ex"],
  patterns: ["LemonRouter.SessionRegistry", "LemonRouter.SessionReadModel"]
}
```

If the checker cannot express `exclude` by glob at that breadth, split into narrower rules for:
- `apps/lemon_channels/lib/**/*.ex`
- `apps/lemon_control_plane/lib/**/*.ex`
- `apps/lemon_gateway/lib/**/*.ex`
- etc.

Also add a rule forbidding direct `Registry.lookup(LemonRouter.SessionRegistry, ...)` outside `apps/lemon_router/lib`.

---

### A.5 Tests to update

#### Router tests
Internal router tests may still verify `SessionRegistry` behavior if you keep it as an internal read-model.

It is acceptable for these internal tests to remain:
- `session_coordinator_test.exs`
- `run_process_test.exs`

But update names/comments so they describe internal read-model behavior, not public authority.

#### External tests
These must stop touching `LemonRouter.SessionRegistry` directly:

- `apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_parallel_sessions_test.exs`
- `apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs`
- any non-router test still registering `LemonRouter.SessionRegistry`

Replacement strategy:
- configure `LemonCore.RouterBridge` to point at a small test stub module
- implement only the needed functions on the stub:
  - `session_busy?/1`
  - `active_run/1`
  - `abort/2` if needed
  - `abort_run/2` if needed

Example test stub:

```elixir
defmodule RouterStub do
  def session_busy?("busy-session"), do: true
  def session_busy?(_), do: false

  def active_run("busy-session"), do: {:ok, "run-123"}
  def active_run(_), do: :none

  def abort(_session_key, _reason), do: :ok
  def abort_run(_run_id, _reason), do: :ok
  def keep_run_alive(_run_id, _decision), do: :ok
  def list_active_sessions, do: [%{session_key: "busy-session", run_id: "run-123"}]
end
```

In test setup:

```elixir
old = Application.get_env(:lemon_core, :router_bridge)
on_exit(fn -> Application.put_env(:lemon_core, :router_bridge, old || %{}) end)
:ok = LemonCore.RouterBridge.configure(router: RouterStub)
```

---

### A.6 Acceptance criteria for Workstream A

All of these must be true:

1. `LemonRouter.Router.abort/2` has no compatibility fallback via `SessionReadModel`.
2. `LemonChannels.Runtime` does not reference `SessionReadModel`.
3. `LemonControlPlane.Methods.SessionsActive` does not reference `Registry.lookup(LemonRouter.SessionRegistry, ...)`.
4. No non-router runtime file references `LemonRouter.SessionRegistry` or `LemonRouter.SessionReadModel`.
5. `docs/architecture_boundaries.md` explicitly states this router-owned authority rule.
6. `ArchitectureRulesCheck` fails if an external app references router session internals.

### A.7 Verification commands for Workstream A

```bash
rg 'LemonRouter\.Session(ReadModel|Registry)' apps --glob '!apps/lemon_router/lib/**' --glob '!**/test/**'
rg 'Registry\.lookup\(LemonRouter\.SessionRegistry' apps --glob '!apps/lemon_router/lib/**' --glob '!**/test/**'
rg '@session_read_model_mod|SessionReadModel' apps/lemon_channels/lib
rg 'Compatibility fallback for any legacy run registrations' apps/lemon_router/lib/lemon_router/router.ex
mix test apps/lemon_router/test
mix test apps/lemon_channels/test
mix test apps/lemon_control_plane/test
mix lemon.quality
```

Expected:
- the `rg` commands return no runtime matches
- tests pass
- `mix lemon.quality` passes

---

## 4. Workstream B — finish shared primitive cleanup

### Goal

Move shared engine-id validation / plain resume formatting / cwd resolution fully into shared primitives so router and channels stop relying on compatibility shims.

### Problem to fix

Current state:
- `LemonCore.Cwd` exists, but `RunOrchestrator` still aliases `LemonGateway.Cwd` (`apps/lemon_router/lib/lemon_router/run_orchestrator.ex:29-30`)
- `LemonChannels.EngineRegistry` still exists as a compatibility shim and handles:
  - engine-id validation
  - plain resume formatting
  - resume parsing via optional gateway runtime delegation (`apps/lemon_channels/lib/lemon_channels/engine_registry.ex:1-120`)
- router still uses `LemonGateway.EngineRegistry` for known-engine checks in:
  - `apps/lemon_router/lib/lemon_router/sticky_engine.ex`
  - `apps/lemon_router/lib/lemon_router/model_selection.ex`

This leaves engine knowledge split across gateway, channels, and router.

---

### B.1 Create `LemonCore.EngineCatalog`

Create file:

- `apps/lemon_core/lib/lemon_core/engine_catalog.ex`

Required API:

```elixir
defmodule LemonCore.EngineCatalog do
  @spec list_ids() :: [String.t()]
  def list_ids

  @spec normalize(String.t() | atom() | nil) :: String.t() | nil
  def normalize(engine_id)

  @spec known?(String.t() | atom() | nil) :: boolean()
  def known?(engine_id)
end
```

Behavior:
- read `Application.get_env(:lemon_core, :known_engines, default_ids)`
- use a default list matching current built-ins:
  - `["lemon", "echo", "codex", "claude", "opencode", "pi", "kimi"]`
- normalize by:
  - converting atoms to strings
  - trimming
  - lowercasing
- `known?/1` must return true only for normalized IDs in `list_ids/0`

Important:
- this module returns **engine IDs only**
- it must not depend on gateway
- it must not return engine modules

Reason:
- router and channels need “is this a known engine id?” far more often than they need “which engine module implements this?”

---

### B.2 Extend `LemonCore.ResumeToken`

Add a plain formatter so channels do not need `LemonChannels.EngineRegistry.format_resume/1`.

In `apps/lemon_core/lib/lemon_core/resume_token.ex`, add:

```elixir
@spec format_plain(t()) :: String.t()
def format_plain(%__MODULE__{engine: engine, value: value}) do
  case engine do
    "codex" -> "codex resume #{value}"
    "claude" -> "claude --resume #{value}"
    "kimi" -> "kimi --session #{value}"
    "opencode" -> "opencode --session #{value}"
    "pi" -> "pi --session #{quote_token(value)}"
    "lemon" -> "lemon resume #{value}"
    _ -> "#{engine} resume #{value}"
  end
end
```

Then change `format/1` to delegate:

```elixir
def format(token), do: "`" <> format_plain(token) <> "`"
```

Reason:
- `Renderer` and `ResumeSelection` need a plain command line, not necessarily backticks
- this is shared logic and belongs in core

---

### B.3 Migrate router off gateway engine knowledge for validation-only use

#### File: `apps/lemon_router/lib/lemon_router/sticky_engine.ex`

Replace:

```elixir
not is_nil(LemonGateway.EngineRegistry.get_engine(engine_id))
```

with:

```elixir
LemonCore.EngineCatalog.known?(engine_id)
```

#### File: `apps/lemon_router/lib/lemon_router/model_selection.ex`

Replace `known_engine_id?/1` implementation with `LemonCore.EngineCatalog.known?/1`.

Reason:
- router only needs ID validation
- router does not need engine module lookup here

---

### B.4 Migrate `RunOrchestrator` to `LemonCore.Cwd`

#### File: `apps/lemon_router/lib/lemon_router/run_orchestrator.ex`

Replace:

```elixir
alias LemonGateway.Cwd, as: GatewayCwd
```

with:

```elixir
alias LemonCore.Cwd, as: SharedCwd
```

Then replace all `GatewayCwd.default_cwd()` calls with `SharedCwd.default_cwd()`.

Reason:
- shared cwd resolver already exists
- router should not reach through gateway for this primitive

---

### B.5 Narrow or remove `LemonChannels.EngineRegistry`

This must be done carefully because it currently also supports runtime-compatible resume parsing via gateway registry delegation.

#### Step B.5.1 — remove its validation and formatting responsibilities

Update these call sites:

- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/update_processor.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/resume_selection.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/renderer.ex`

Required replacements:

- `EngineRegistry.get_engine(engine_id)` -> `LemonCore.EngineCatalog.normalize(engine_id)`
- `EngineRegistry.engine_known?(engine_id)` -> `LemonCore.EngineCatalog.known?(engine_id)`
- `EngineRegistry.format_resume(token)` -> `LemonCore.ResumeToken.format_plain(token)`

#### Step B.5.2 — decide whether `extract_resume/1` can also move now

Preferred target:
- replace `EngineRegistry.extract_resume(text)` with `LemonCore.ResumeToken.extract_resume(text)`

But before doing that, verify whether current runtime behavior depends on custom gateway-registered engines with custom resume syntax.

Verification question:
- Are there any non-built-in engines in the repo that rely on `LemonGateway.EngineRegistry.extract_resume/1` for syntax other than the built-in patterns in `LemonCore.ResumeToken`?

If **no**, delete `LemonChannels.EngineRegistry` entirely.

If **yes**, then do this instead:
- keep `LemonChannels.EngineRegistry`, but reduce it to a tiny compatibility parser module that only owns `extract_resume/1`
- rename its docs to say it is **temporary runtime compatibility for custom engine resume parsing only**
- add a quality rule that new code must not use it for engine-id validation or formatting

The preferred outcome is deletion, but correctness is more important than deletion.

---

### B.6 Architecture guardrails for engine knowledge

Edit `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`.

Add rules:

1. Router must not use `LemonGateway.EngineRegistry` for known-engine validation.
2. Channels must not use `LemonChannels.EngineRegistry` for formatting or engine-id validation once `EngineCatalog` / `ResumeToken.format_plain/1` exist.
3. Router must not use `LemonGateway.Cwd`.

Example patterns:

```elixir
%{
  code: :router_gateway_engine_registry_dependency,
  message: "Router must use LemonCore.EngineCatalog for engine-id validation, not LemonGateway.EngineRegistry",
  files: ["apps/lemon_router/lib/**/*.ex"],
  patterns: ["LemonGateway.EngineRegistry"]
}
```

If some router file still legitimately needs gateway engine module lookup, then narrow the exclude to allow that exact file only. The goal is to force intentional use, not accidental drift.

Also add:

```elixir
%{
  code: :router_gateway_cwd_dependency,
  message: "Router must use LemonCore.Cwd for shared cwd resolution",
  files: ["apps/lemon_router/lib/**/*.ex"],
  patterns: ["LemonGateway.Cwd"]
}
```

---

### B.7 Documentation updates

Update:

- `apps/lemon_channels/README.md`
- `apps/lemon_channels/AGENTS.md`

If `LemonChannels.EngineRegistry` is deleted:
- remove the compatibility-shim section entirely
- update the module table

If it is narrowed:
- state very clearly that it is a temporary custom-resume-parser compatibility shim only
- say new code must use `LemonCore.EngineCatalog` and `LemonCore.ResumeToken`

---

### B.8 Tests to add or update

Add:

- `apps/lemon_core/test/lemon_core/engine_catalog_test.exs`
- update/add `apps/lemon_core/test/lemon_core/resume_token_test.exs` for `format_plain/1`

Update:
- `apps/lemon_router/test/lemon_router/sticky_engine_test.exs`
- `apps/lemon_router/test/lemon_router/model_selection_test.exs`
- Telegram renderer/resume-selection tests
- any channel tests that assert resume formatting

If `LemonChannels.EngineRegistry` is deleted:
- remove or replace its tests
- do **not** delete `apps/lemon_gateway/test/engine_registry_test.exs`; gateway still owns engine module lookup

---

### B.9 Acceptance criteria for Workstream B

All of these must be true:

1. `RunOrchestrator` does not alias `LemonGateway.Cwd`.
2. router known-engine checks use `LemonCore.EngineCatalog`.
3. channel formatting uses `LemonCore.ResumeToken.format_plain/1`.
4. channel validation uses `LemonCore.EngineCatalog`.
5. `LemonChannels.EngineRegistry` is either:
   - deleted, or
   - reduced to temporary custom-parse compatibility only (no validation/formatting)
6. architecture rules prevent drift back to gateway/channels shims.

### B.10 Verification commands for Workstream B

```bash
rg 'LemonGateway\.Cwd' apps/lemon_router/lib
rg 'LemonGateway\.EngineRegistry' apps/lemon_router/lib apps/lemon_channels/lib
rg 'LemonChannels\.EngineRegistry' apps/lemon_channels/lib apps/lemon_router/lib
rg 'format_resume\(' apps/lemon_channels/lib
mix test apps/lemon_core/test/lemon_core/engine_catalog_test.exs
mix test apps/lemon_core/test/lemon_core/resume_token_test.exs
mix test apps/lemon_router/test
mix test apps/lemon_channels/test
mix lemon.quality
```

Expected:
- router has no `LemonGateway.Cwd`
- router/channels do not use the old engine shim for validation/formatting
- tests pass

---

## 5. Workstream C — finish remaining raw-store cleanup and stale docs/shims

### Goal

Close the remaining “back door” where arbitrary modules still call raw `LemonCore.Store.get/put/delete/list` directly, and update docs so they stop teaching the old pattern.

### Problem to fix

Current non-test, non-wrapper runtime raw-store callers still include:

- `apps/lemon_core/lib/lemon_core/model_policy.ex`
- `apps/lemon_core/lib/lemon_core/idempotency.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/agent_identity_get.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/update_run.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/skills_update.ex`
- multiple `lemon_games` modules:
  - `auth.ex`
  - `rate_limit.ex`
  - `matches/service.ex`
  - `matches/event_log.ex`
  - `matches/deadline_sweeper.ex`

Docs still show raw generic-store API examples:

- `apps/lemon_core/README.md:320-327`
- `apps/lemon_core/AGENTS.md:192-204`

---

### C.1 Shared/core wrappers to add

#### `apps/lemon_core/lib/lemon_core/model_policy_store.ex`

Move table ownership for `@model_policy_table :model_policies` into this wrapper.

Required API:

```elixir
defmodule LemonCore.ModelPolicyStore do
  def get(key)
  def put(key, policy)
  def delete(key)
  def list()
end
```

Then update `LemonCore.ModelPolicy` to use this wrapper exclusively.

#### `apps/lemon_core/lib/lemon_core/idempotency_store.ex`

Move raw storage for `@table :idempotency` into a wrapper.

Required API:

```elixir
defmodule LemonCore.IdempotencyStore do
  def get(key)
  def put(key, value)
  def delete(key)
end
```

Then update `LemonCore.Idempotency` to use it.

Reason:
- these are shared-domain modules and should model the storage explicitly

---

### C.2 Control-plane wrappers to add

Create:

- `apps/lemon_control_plane/lib/lemon_control_plane/agent_identity_store.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/update_config_store.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/skills_config_store.ex`

Migrate:

- `methods/agent_identity_get.ex`
- `methods/update_run.ex`
- `methods/skills_update.ex`

Notes:
- `skills_update.ex` currently has a fallback path that writes directly to `LemonCore.Store` if `LemonSkills.Config` is not loaded.
- Replace that fallback with a real store wrapper so the behavior stays the same but the table name is localized.

---

### C.3 `lemon_games` wrappers to add

Because `lemon_games` is app-local, wrapper modules can stay inside `lemon_games`.

Create:

- `apps/lemon_games/lib/lemon_games/auth_store.ex`
- `apps/lemon_games/lib/lemon_games/rate_limit_store.ex`
- `apps/lemon_games/lib/lemon_games/matches/store.ex`
- `apps/lemon_games/lib/lemon_games/matches/event_store.ex`

Migrate:

- `LemonGames.Auth`
- `LemonGames.RateLimit`
- `LemonGames.Matches.Service`
- `LemonGames.Matches.EventLog`
- `LemonGames.Matches.DeadlineSweeper`

Reason:
- app-local wrappers are still better than arbitrary raw table calls scattered across service modules

---

### C.4 Documentation cleanup

#### File: `apps/lemon_core/README.md`

Replace the “Generic Table API” section.

Do **not** advertise:

```elixir
LemonCore.Store.put(:my_table, ...)
LemonCore.Store.get(:my_table, ...)
```

Instead say:

- generic table API exists for backend/wrapper internals and explicitly app-local legacy tables
- shared-domain code should go through wrappers

Show a wrapper example:

```elixir
defmodule MyApp.WidgetStore do
  def put(id, widget), do: LemonCore.Store.put(:widgets, id, widget)
  def get(id), do: LemonCore.Store.get(:widgets, id)
end
```

Then:

```elixir
MyApp.WidgetStore.put(id, widget)
```

#### File: `apps/lemon_core/AGENTS.md`

Make the same change.

---

### C.5 Quality guardrails

Edit `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`.

Add or extend rules so these modules must not keep raw generic store calls after migration:

- `LemonCore.ModelPolicy`
- `LemonCore.Idempotency`
- control-plane methods listed above

For `lemon_games`, either:
- add a general raw-store guardrail for `apps/lemon_games/lib/**/*.ex` excluding `*store.ex`, or
- leave it as a grep-based acceptance criterion if you want to avoid over-tightening in the first PR

Recommended rule:

```elixir
%{
  code: :games_raw_store_bypass,
  message: "lemon_games runtime modules must use app-local store wrappers instead of raw LemonCore.Store access",
  files: ["apps/lemon_games/lib/**/*.ex"],
  exclude: ["apps/lemon_games/lib/**/*store*.ex"],
  patterns: [
    "LemonCore.Store.get(",
    "LemonCore.Store.put(",
    "LemonCore.Store.delete(",
    "LemonCore.Store.list("
  ]
}
```

---

### C.6 Optional shim cleanup

This is lower priority than the above work, but if time allows:

#### File: `apps/lemon_gateway/lib/lemon_gateway/transports/discord.ex`

Current state:
- it is a disabled compatibility stub

Decide one of these:
1. keep it and clearly document it as reserved/disabled
2. remove it from transport registry/config if it is no longer needed for backwards compatibility

Do **not** spend time on this until Workstreams A–C.3 are complete.

---

### C.7 Tests to add or update

Add wrapper tests for each new wrapper module.

At minimum:

- `lemon_core/model_policy_store_test.exs`
- `lemon_core/idempotency_store_test.exs`
- control-plane store wrapper tests
- `lemon_games` wrapper tests

Update existing module tests so they assert behavior through the wrapper-backed modules, not through raw store tables.

---

### C.8 Acceptance criteria for Workstream C

All of these must be true:

1. `LemonCore.ModelPolicy` has no raw `LemonCore.Store.get/put/delete/list` calls.
2. `LemonCore.Idempotency` has no raw `LemonCore.Store.get/put/delete/list` calls.
3. the listed control-plane methods have no raw generic store calls.
4. `lemon_games` runtime modules use store wrappers.
5. `apps/lemon_core/README.md` and `apps/lemon_core/AGENTS.md` no longer teach direct raw store usage as the default pattern.

### C.9 Verification commands for Workstream C

```bash
rg 'LemonCore\.Store\.(get|put|delete|list)\(' apps --glob '!**/*store*.ex' --glob '!**/test/**' --glob '!apps/lemon_core/lib/lemon_core/testing.ex' --glob '!apps/lemon_core/lib/lemon_core/quality/**'
rg 'Generic Table API' apps/lemon_core/README.md apps/lemon_core/AGENTS.md -n -C 2
mix test apps/lemon_core/test
mix test apps/lemon_control_plane/test
mix test apps/lemon_games/test
mix lemon.quality
```

Expected:
- grep returns zero runtime offenders or only intentionally grandfathered files that are documented in the PR
- docs no longer present raw store usage as the default pattern

---

## 6. Recommended PR breakdown

Do not do this in one PR.

Recommended order:

1. `router-session-authority-cleanup`
2. `engine-catalog-and-shared-primitives`
3. `remaining-store-wrapper-migration`
4. `optional-discord-shim-cleanup`

Reason:
- Workstream A removes ambiguity first
- Workstream B removes the biggest remaining shared-primitive seam
- Workstream C closes the raw-store/doc debt
- optional shim cleanup should not block the architectural cleanup

---

## 7. Final “done” definition

This spec is complete when all of the following are true:

- router is the only public owner of queue/session semantics
- no external app references `SessionRegistry` or `SessionReadModel`
- RouterBridge exposes the needed query/control APIs
- router no longer contains legacy abort compatibility fallback
- router uses `LemonCore.Cwd`
- router/channel validation uses `LemonCore.EngineCatalog`
- channel formatting uses `LemonCore.ResumeToken.format_plain/1`
- `LemonChannels.EngineRegistry` is either deleted or reduced to custom-parse compatibility only
- remaining raw-store callers are wrapped
- docs match the chosen architecture
- `mix lemon.quality` passes

---

## 8. Notes for the implementing agent

1. **Do not reopen the router-vs-gateway decision.** It is settled here.
2. **Do not move queue mode into `ExecutionRequest`.**
3. **Do not let channels/control-plane query router registries directly.**
4. **If you keep `SessionRegistry`, keep it private.**
5. **When in doubt, prefer public router API / RouterBridge over router internals.**
6. **Do not delete `LemonChannels.EngineRegistry` until you prove custom-engine resume parsing is not needed.**
7. **If a module owns a storage table, create a wrapper instead of sprinkling raw store calls.**

---

## 9. Execution note

This spec is grounded in static source inspection of the uploaded repository state. It is **not** a claim that tests were run in this analysis environment.
