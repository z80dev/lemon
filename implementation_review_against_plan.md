# Implementation Review Against the Architecture Refactor Plan

This is a static source review of the updated repo in `a5b2e255-0e9c-4e81-9615-e516a5f14285.zip`, compared against the concrete refactor plan that was checked into the repo as `concrete_architecture_refactor_plan.md`.

I could not run `mix` in this environment, so this assessment is based on code structure, diffs, and architectural seams rather than executing the full test matrix.

## Overall verdict

You made **strong, meaningful progress**. I would rate the implementation at roughly **75–80% of the plan**.

The most important thing is that the repo now reflects the intended architecture in the places that matter most:

- router emits semantic delivery contracts instead of channel payloads
- channels own rendering/presentation
- router owns queue semantics via `SessionCoordinator`
- gateway accepts a queue-semantic-free `ExecutionRequest`
- `CodingAgent.Session`, `CodingAgent.Tools.Task`, Telegram transport, and Webhook transport were all materially decomposed
- typed shared-domain store wrappers now exist and are used in important paths
- quality checks and architecture docs are much more trustworthy

The remaining gaps are mostly about **finishing migration and deleting old seams**, not about reversing direction.

---

## Scorecard by phase

## Phase 0 — Restore trust in architecture metadata and quality gates

**Status:** **Mostly complete**

### What landed

- `docs/architecture_boundaries.md` now includes `lemon_mcp` and `lemon_services`.
- `ArchitectureCheck` now includes `lemon_mcp` and `lemon_services`.
- umbrella dep parsing was upgraded from regex to AST-based scanning in `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`.
- `ArchitectureRulesCheck` was added and wired into `mix lemon.quality`.
- duplicate dependency entries in `lemon_control_plane` / `lemon_web` were cleaned up.
- Elixir version floor is now standardized across umbrella apps (`~> 1.19`).

### Evidence

- `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`
- `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`
- `apps/lemon_core/lib/mix/tasks/lemon.quality.ex`
- `docs/architecture_boundaries.md`
- `apps/lemon_control_plane/mix.exs`
- `apps/lemon_web/mix.exs`

### Remaining issue

The `coding_agent_ui` namespace handling is improved, but it is still a little awkward:

- `coding_agent_ui` is still declared as `["CodingAgentUi"]` in `@app_namespaces`
- special-case exact owner overrides are then used for `CodingAgent.UI.*`

That works, but it is more brittle than a clean longest-prefix namespace system.

### Grade

**A-**

---

## Phase 1 — Introduce future contracts without behavior changes

**Status:** **Mostly complete**

### What landed

The key contracts from the plan are now in place:

- `LemonCore.RunRequest`
- `LemonCore.DeliveryIntent`
- `LemonCore.DeliveryRoute`
- `LemonGateway.ExecutionRequest`
- `LemonChannels.Dispatcher`

These are the right architectural primitives. This was a high-leverage change and it happened.

### Evidence

- `apps/lemon_core/lib/lemon_core/run_request.ex`
- `apps/lemon_core/lib/lemon_core/delivery_intent.ex`
- `apps/lemon_core/lib/lemon_core/delivery_route.ex`
- `apps/lemon_gateway/lib/lemon_gateway/execution_request.ex`
- `apps/lemon_channels/lib/lemon_channels/dispatcher.ex`

### What is especially good

`ExecutionRequest` is correctly queue-semantic-free. That is one of the biggest boundary wins in the whole repo.

### Remaining issue

There are still a couple of older shared utility seams that were not finished:

- `LemonChannels.EngineRegistry` still exists
- `LemonChannels.Cwd` and `LemonGateway.Cwd` both still exist

Those do not undo the contract work, but they are leftover primitive duplication.

### Grade

**A-**

---

## Phase 2 — Move channel rendering and platform UX fully into `lemon_channels`

**Status:** **Largely complete**

### What landed

This is one of the strongest parts of the implementation.

You removed the router-side channel adapters entirely:

- `LemonRouter.ChannelAdapter`
- `LemonRouter.ChannelAdapter.Generic`
- `LemonRouter.ChannelAdapter.Telegram`
- `LemonRouter.ChannelsDelivery`

The router now emits semantic intents and the channels app renders them.

New channel-side rendering modules were added:

- `LemonChannels.Dispatcher`
- `LemonChannels.PresentationState`
- `LemonChannels.Adapters.Generic.Renderer`
- `LemonChannels.Adapters.Telegram.Renderer`
- `LemonChannels.Adapters.Telegram.StatusRenderer`

### Evidence

- router no longer references `OutboundPayload`, `Telegram.Truncate`, `GatewayConfig`, or `LemonChannels.EngineRegistry`
- new channel-side renderer modules exist under `apps/lemon_channels/lib/lemon_channels/`

### What is especially good

This is exactly the separation the plan wanted:

- router owns semantics
- channels own presentation and payload shape

### Remaining issue

There are still a few channel-specific runtime seams that feel transitional:

- `LemonChannels.Runtime.session_busy?/1` still reaches into `LemonRouter.SessionRegistry`
- `LemonChannels.EngineRegistry` is still used internally by Telegram paths

These are not router leaks anymore, but they are still legacy-ish channel/runtime coupling.

### Grade

**A**

---

## Phase 3 — Make router the sole owner of queue semantics

**Status:** **Substantially complete**

### What landed

This was a major architectural move, and it happened.

You introduced:

- `LemonRouter.SessionCoordinator`
- `LemonRouter.SessionCoordinatorSupervisor`
- `LemonRouter.ConversationKey`
- `LemonRouter.ResumeResolver`
- `LemonRouter.DeliveryRouteResolver`

The router docs now explicitly say queue semantics belong to `SessionCoordinator`, and the gateway docs now explicitly say they do not belong in gateway workers anymore.

### Evidence

- `apps/lemon_router/lib/lemon_router/session_coordinator.ex`
- `apps/lemon_gateway/lib/lemon_gateway/execution_request.ex`
- `apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex`
- `apps/lemon_router/README.md`
- `apps/lemon_gateway/README.md`

### Boundary improvements achieved

- queue semantics moved to router
- gateway contract is `ExecutionRequest`
- `ThreadWorker` is now a per-conversation launcher/slot waiter, not the product queue owner
- `RunProcess` no longer owns `SessionRegistry` entries directly

### Remaining issues

This phase is not fully “closed” yet.

1. `LemonRouter.SessionRegistry` still exists and is still used by:
   - `LemonRouter.AgentDirectory`
   - `LemonChannels.Runtime.session_busy?/1`
   - some tests and support flows

2. Queue-related config parsing still exists in some gateway transport/config code. That is acceptable as ingress compatibility, but it means there is still some old vocabulary in gateway land.

3. `SessionCoordinator` is now large (~565 LOC). It is the *right* place for the logic, but it is becoming a hotspot.

### Grade

**A-**

---

## Phase 4 — Split typed stores from `LemonCore.Store`

**Status:** **Partially complete**

This phase is the biggest remaining gap.

### What landed

Good progress happened here:

Shared typed wrappers now exist:

- `LemonCore.ChatStateStore`
- `LemonCore.RunStore`
- `LemonCore.PolicyStore`
- `LemonCore.IntrospectionStore`
- `LemonCore.ProgressStore`
- `LemonCore.ProjectBindingStore`

App-owned wrappers also now exist in some important places:

- `LemonRouter.PendingCompactionStore`
- `LemonChannels.Telegram.StateStore`
- `LemonChannels.Telegram.ResumeIndexStore`
- `LemonChannels.Telegram.KnownTargetStore`

And a new quality check now forbids some direct bypasses.

### Evidence

- `apps/lemon_core/lib/lemon_core/chat_state_store.ex`
- `apps/lemon_core/lib/lemon_core/run_store.ex`
- `apps/lemon_core/lib/lemon_core/policy_store.ex`
- `apps/lemon_core/lib/lemon_core/introspection_store.ex`
- `apps/lemon_core/lib/lemon_core/progress_store.ex`
- `apps/lemon_router/lib/lemon_router/pending_compaction_store.ex`
- `apps/lemon_channels/lib/lemon_channels/telegram/state_store.ex`
- `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`

### What remains incomplete

There is still a **lot** of raw generic store usage outside wrappers.

Examples still present:

- `lemon_control_plane` methods:
  - wizard
  - voicewake
  - usage
  - tts
  - node pairing / registry / invoke
  - device pairing
  - exec approvals
  - config set / patch
- `lemon_automation/heartbeat_manager.ex`
- `lemon_gateway/sms/inbox.ex`
- `lemon_router/agent_endpoints.ex`
- some `lemon_games` modules
- some core modules like `exec_approvals.ex`

The quality rules cover some of this, but not all of it yet.

### Important nuance

This does **not** mean the phase failed. It means the migration is underway, but it is nowhere near fully complete.

### Grade

**C+**

---

## Phase 5 — Reduce monolith modules without changing public APIs

**Status:** **Strong progress**

This is another area where the implementation is noticeably good.

### `CodingAgent.Session`

**Very good progress**

The main file shrank from about **1836** non-empty lines to about **885**.

New session submodules were added:

- `background_tasks.ex`
- `compaction_lifecycle.ex`
- `lifecycle.ex`
- `notifier.ex`
- `overflow_recovery.ex`
- `persistence.ex`
- `state.ex`

And pre-existing extracted modules remain:

- `compaction_manager.ex`
- `event_handler.ex`
- `message_serialization.ex`
- `model_resolver.ex`
- `prompt_composer.ex`
- `wasm_bridge.ex`

This is exactly the kind of decomposition the plan wanted.

### `CodingAgent.Tools.Task`

**Excellent progress**

The main file shrank from about **1591** non-empty lines to about **151**.

New task submodules exist:

- `async.ex`
- `execution.ex`
- `followup.ex`
- `params.ex`
- `result.ex`
- `runner.ex`

This is one of the cleanest wins in the whole implementation.

### `LemonChannels.Adapters.Telegram.Transport`

**Good progress, not finished**

The main file shrank from about **4207** non-empty lines to about **3212**.

New extracted transport submodules exist:

- `command_router.ex`
- `memory_reflection.ex`
- `model_preferences.ex`
- `per_chat_state.ex`
- `poller.ex`
- `resume_selection.ex`
- `session_routing.ex`

This is good progress, but the main transport file is still big and still carries a lot.

### `LemonGateway.Transports.Webhook`

**Very good progress**

The main file shrank from about **1247** non-empty lines to about **151**.

New modules exist:

- `config.ex`
- `idempotency.ex`
- `invocation_dispatch.ex`
- `request.ex`
- `request_normalization.ex`
- `response.ex`
- `response_builder.ex`
- `signature_validation.ex`
- `submission.ex`

This is highly aligned with the plan.

### Grade

**A-**

---

## Phase 6 — Delete compatibility code and codify the new boundaries

**Status:** **Mixed: strong on boundary rules, partial on cleanup**

### What landed

Strong wins:

- router-side channel adapters are gone
- `ChannelsDelivery` is gone
- `LemonGateway.Types.Job.queue_mode` is gone
- `LemonGateway.Runtime.submit/1` compatibility path is gone
- `ArchitectureRulesCheck` now codifies many of the intended forbidden references
- gateway no longer derives conversation keys internally from session_key fallback in scheduler

### Evidence

- `apps/lemon_gateway/lib/lemon_gateway/types.ex`
- `apps/lemon_gateway/lib/lemon_gateway/runtime.ex`
- `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`
- scheduler `thread_key/1` requires router-supplied `conversation_key`

### What remains

Several cleanup/deletion tasks are not done yet:

1. `LemonChannels.EngineRegistry` still exists
2. `LemonChannels.Cwd` and `LemonGateway.Cwd` still both exist
3. `LemonRouter.SessionRegistry` still exists and is still operationally important
4. `LemonGateway.submit/1` still exists as a convenience wrapper (this is probably okay, but it is still compatibility-ish)
5. the disabled Discord seam still exists in gateway docs / code

### Grade

**B**

---

## Biggest wins

If I had to call out the five highest-value improvements, they would be:

1. **`ExecutionRequest` + `SessionCoordinator`**
   - This is the most important architectural correction in the repo.

2. **Router no longer constructs channel payloads**
   - The channel boundary is much cleaner now.

3. **`CodingAgent.Tools.Task` extraction**
   - Massive reduction in complexity and much easier future maintenance.

4. **Webhook extraction**
   - Big hotspot substantially improved.

5. **Quality checks now encode real architecture rules**
   - This prevents backsliding.

---

## Biggest misses / remaining work

These are the places I would focus next.

### 1. Finish the store migration

This is the largest unfinished body of work.

Most of the remaining architectural inconsistency is now “raw store APIs leaking everywhere”.

Highest-priority remaining migrations:

- `lemon_control_plane` method modules
- `lemon_automation/heartbeat_manager.ex`
- `lemon_gateway/sms/inbox.ex`
- `lemon_router/agent_endpoints.ex`
- `lemon_core/exec_approvals.ex`

### 2. Remove or delegate duplicate shared primitives

Still duplicated / legacy:

- `LemonChannels.EngineRegistry`
- `LemonChannels.Cwd`
- `LemonGateway.Cwd`

These should either be deleted or turned into tiny delegating wrappers.

### 3. Decide the long-term fate of `SessionRegistry`

Right now it is no longer owned by `RunProcess`, which is good, but it still exists as a router-owned active-session read model and busy-check mechanism.

That may be fine, but it should be made explicit:
- either keep it as the coordinator’s read model
- or replace it with a cleaner `SessionCoordinator` / `AgentDirectory` query API

### 4. Keep shrinking Telegram transport

The decomposition is real, but the transport shell is still too large.

### 5. Tighten architecture rules around raw store usage

Right now `ArchitectureRulesCheck` catches important violations, but the store-boundary rules still only cover part of the problem space.

---

## Final verdict

**You did well.** This is not cosmetic progress. The repo has genuinely moved toward the target architecture.

If I compare “before” vs “after” in staff-engineering terms:

- **Before:** the intended architecture was mostly documented, but several critical ownership boundaries were violated in code.
- **After:** the most important ownership boundaries are now represented in code, and the quality system is starting to enforce them.

The remaining work is mostly:

- finish migrations
- delete old seams
- keep pushing on store discipline

That is a very good place to be.

## Practical summary

If I had to summarize in one sentence:

**You successfully implemented the architectural spine of the plan, but the store migration and a few legacy bridge seams still need another pass before I’d call it finished.**
