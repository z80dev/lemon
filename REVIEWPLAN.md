# Review Remediation Plan

This plan addresses the findings in `REVIEW.md` after the four-phase refactor.

## Current Review Readout

| Area | Review result | Plan status |
| --- | --- | --- |
| Phase 1: AI boundary extraction | Essentially achieved; docs and guardrails are stale | Close out with docs and CI checks |
| Phase 2: execution DTO boundary | Mostly achieved; router still depends on gateway through chat state | Finish router/gateway compile-time decoupling |
| Phase 3: events, async delivery, reasoning | Functional progress; event contract still informal | Canonicalize reasoning action events and delivery receipts |
| Phase 4: gateway/channels cleanup | Channel side improved; gateway still owns too much ingress | Shrink gateway supervision first, then extract legacy transports |
| Architecture policy | Improved, but still blesses transitional coupling | Add current-vs-target drift reporting |

## Milestone 1: Remove Router's Gateway Dependency

Goal: prove the execution boundary landed completely.

### Work

1. Move `LemonGateway.ChatState` to `LemonCore.ChatState`.
   - New owner: `apps/lemon_core/lib/lemon_core/chat_state.ex`
   - Keep fields compatible with existing persisted values:
     - `last_engine`
     - `last_resume_token`
     - `updated_at`
     - `expires_at`
   - Keep `new/0` and `new/1` behavior compatible with atom and string map keys.

2. Update chat-state persistence and callers to use the core struct.
   - Update `LemonCore.ChatStateStore` specs to return/store `LemonCore.ChatState.t() | map() | nil`.
   - Update gateway run completion to write `%LemonCore.ChatState{}`.
   - Update router readers:
     - `apps/lemon_router/lib/lemon_router/resume_resolver.ex`
     - `apps/lemon_router/lib/lemon_router/session_coordinator.ex`
   - Update channel per-chat state helpers where they read/write chat state.

3. Remove compile-time router dependency on gateway.
   - Remove `{:lemon_gateway, in_umbrella: true}` from `apps/lemon_router/mix.exs`.
   - Ensure router tests do not directly start or reference gateway modules except through test-only stubs or configured `LemonCore.EngineRuntime`.

4. Decide how to keep gateway compatibility tests.
   - Move `apps/lemon_gateway/test/chat_state_test.exs` coverage to `apps/lemon_core/test/lemon_core/chat_state_test.exs`.
   - Either delete `LemonGateway.ChatState` or leave a short deprecated alias only if existing persisted external code requires it. Prefer deletion if tests and callers can move cleanly.

### Acceptance Checks

```bash
rg "\bLemonGateway\b" apps/lemon_router/lib
rg "LemonGateway.ExecutionRequest|ExecutionRequest" apps/lemon_router/lib
rg "LemonGateway.ChatState" apps
mix test apps/lemon_core apps/lemon_router apps/lemon_gateway
```

Expected:
- first two `rg` commands return no router lib matches
- `LemonGateway.ChatState` is gone or limited to a deliberate compatibility alias/test
- `apps/lemon_router/mix.exs` no longer depends on `:lemon_gateway`

## Milestone 2: Make Async Delivery Receipts Explicit

Goal: avoid ambiguity between what a submission requested and what the router actually did.

### Work

1. Update router delivery stamping in `apps/lemon_router/lib/lemon_router/session_transitions.ex`.
   - Replace the current receipt shape:

     ```elixir
     %{mode: disposition, status: status}
     ```

   - With:

     ```elixir
     %{
       requested_mode: submission.queue_mode,
       actual_mode: disposition,
       status: status,
       decided_at_ms: LemonCore.Event.now_ms()
     }
     ```

   - Preserve optional fields:
     - `fallback_mode`
     - `active_run_id`

2. Keep `delivery` as the actual mode for compact callers.
   - `entry.delivery` should remain the router's final disposition.
   - `entry.delivery_receipt` should carry requested vs actual details.

3. Update async followup provenance formatting.
   - Search for provenance rendering around async followups and include:
     - `requested_delivery`
     - `actual_delivery`
     - `delivery_status`
     - `fallback_delivery`, when present
     - `active_run_id`, when present

4. Update tests for:
   - queued followup
   - steered followup
   - fallback queued followup
   - active async followup dispatched to an active run
   - compaction preserving receipt fields

### Acceptance Checks

```bash
rg "delivery_receipt|requested_mode|actual_mode|decided_at_ms" apps/lemon_router apps/coding_agent apps/lemon_core
mix test apps/lemon_router apps/coding_agent
```

Expected:
- no new receipt uses depend on `mode`
- provenance displays requested and actual delivery separately

## Milestone 3: Canonicalize Reasoning Events

Goal: keep reasoning as a structured status signal without two competing contracts.

### Decision

Use `:engine_action` with `kind: "reasoning"` as the canonical UI/status surface event. Do not keep `:reasoning_status` as an unwired parallel path.

### Work

1. Add a typed constructor in `LemonCore.Event`.
   - Suggested API:

     ```elixir
     LemonCore.Event.engine_reasoning(%{
       run_id: run_id,
       session_key: session_key,
       text: text,
       source: source,
       phase: phase,
       visibility: :operator
     })
     ```

   - It should build the validated `:engine_action` event shape:
     - `action.kind == "reasoning"`
     - `action.detail.reasoning.text`
     - `action.detail.reasoning.source`
     - `action.detail.reasoning.phase`
     - meta includes `run_id`, `session_key`, and `visibility`

2. Replace hand-built reasoning payloads with the constructor.
   - `apps/coding_agent/lib/coding_agent/tools/task/projection.ex`
   - `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
   - any other producer found by:

     ```bash
     rg "kind: \"reasoning\"|reasoning_status|Event\.engine_action" apps
     ```

3. Remove or explicitly deprecate `LemonCore.Event.reasoning_status/2`.
   - Prefer removal if no callers remain.
   - If kept, document it as non-surface/internal only and add a test that explains why it exists.

4. Update router coalescer tests.
   - Generic `:note` actions remain filtered.
   - Notes with `detail.reasoning` are preserved as reasoning actions.
   - Reasoning actions from child tasks project into the parent task surface.

### Acceptance Checks

```bash
rg "reasoning_status" apps
rg "kind: \"reasoning\"" apps/coding_agent apps/lemon_router apps/lemon_core
mix test apps/lemon_core apps/coding_agent apps/lemon_router
```

Expected:
- reasoning producers use the core constructor or a shared projection helper
- there is one documented canonical reasoning event path

## Milestone 4: Shrink Gateway Startup Scope

Goal: make `lemon_gateway` read as an engine execution runtime, not a transport platform.

### Work

1. Split `LemonGateway.Application` supervision into execution-only and legacy ingress children.
   - Execution children stay in gateway:
     - `LemonGateway.Config`
     - `LemonGateway.EngineRegistry`
     - `LemonGateway.EngineLock`
     - `LemonGateway.RunRegistry`
     - `LemonGateway.ThreadRegistry`
     - `LemonGateway.RunSupervisor`
     - `LemonGateway.ThreadWorkerSupervisor`
     - `LemonGateway.TaskSupervisor`
     - `LemonGateway.Scheduler`
     - optional health server

2. Move these out of default gateway startup:
   - `LemonGateway.TransportRegistry`
   - `LemonGateway.TransportSupervisor`
   - `LemonGateway.CommandRegistry`
   - `LemonGateway.Sms.Inbox`
   - `LemonGateway.Sms.WebhookServer`
   - `LemonGateway.Voice.*` registries, supervisors, and server

3. Choose the smallest transition boundary.
   - Preferred short-term option: create a transitional OTP app such as `lemon_ingress` for gateway-owned legacy transports.
   - Alternative: keep modules in place but start them from the top-level runtime app through an explicit legacy ingress supervisor. This is less clean but smaller.

4. Keep inbound submission path normalized.
   - Gateway-owned legacy ingress must submit `LemonCore.RunRequest` through `LemonCore.RouterBridge`.
   - It must not call `LemonRouter.RunOrchestrator` or gateway execution APIs directly.

5. Move user transport modules over time.
   - Email, Farcaster, and webhook ingress should move toward `lemon_channels` or the transitional ingress app.
   - SMS support tools and voice call infrastructure should become separate ownership areas if they remain product features.

### Acceptance Checks

```bash
rg "TransportRegistry|TransportSupervisor|CommandRegistry|Sms|Voice" apps/lemon_gateway/lib/lemon_gateway/application.ex
rg "RunRequestBuilder|submit_inbound|RouterBridge.submit_run" apps/lemon_channels apps/lemon_gateway
mix test apps/lemon_gateway apps/lemon_channels
```

Expected:
- gateway default supervision starts execution runtime only
- legacy ingress startup is explicit and separately owned
- inbound transport paths still normalize to `LemonCore.RunRequest`

## Milestone 5: Architecture Policy Guardrails

Goal: make quality checks enforce current boundaries while reporting target drift.

### Work

1. Split architecture policy into current and target maps.
   - Keep `allowed_direct_deps/0` as the current enforcing policy.
   - Add `target_allowed_direct_deps/0` for drift reporting.

2. Target policy should remove transitional coupling:
   - `lemon_router` target excludes `:lemon_gateway`.
   - `lemon_gateway` target excludes `:lemon_channels`, `:lemon_automation`, and `:ai` unless still required after gateway shrink.
   - `ai` remains `[]`.

3. Add quality output for target drift.
   - Current policy violations fail.
   - Target policy drift reports actionable warnings.
   - Once Milestone 1 lands, promote router target to current.

4. Add focused regression checks.
   - `apps/ai/lib` must remain Lemon-free.
   - router lib must not reference gateway.
   - router must not construct gateway execution requests.

### Acceptance Checks

```bash
mix lemon.quality
mix test apps/lemon_core/test/lemon_core/quality
rg "\bLemonCore\b" apps/ai/lib
rg "ProviderConfigResolver|Secrets|Onboarding" apps/ai/lib
rg "\bLemonGateway\b" apps/lemon_router/lib
```

Expected:
- quality checks fail on forbidden current dependencies
- target drift is visible before it becomes a hard failure

## Milestone 6: Documentation Closeout

Goal: remove stale migration instructions and make the new ownership boundaries discoverable.

### Work

1. Update `docs/plans/2026-03-19-ai-boundary-extraction-plan.md`.
   - Mark `apps/ai` Lemon dependency removal complete.
   - Replace stale "next step: remove LemonCore calls" sections with remaining work:
     - CI guard
     - optional external repo extraction
     - provider-neutral OAuth/storage interface preservation
     - runtime facade ownership in `lemon_ai_runtime`

2. Update boundary docs after Milestone 1 and Milestone 4.
   - `docs/architecture_boundaries.md`
   - `apps/lemon_router/AGENTS.md`
   - `apps/lemon_gateway/AGENTS.md`
   - `apps/lemon_core/AGENTS.md`

3. Update module docs affected by code movement.
   - `LemonCore.ChatState`
   - `LemonCore.ChatStateStore`
   - `LemonCore.Event`
   - any new legacy ingress supervisor/app

### Acceptance Checks

```bash
rg "apps/ai.*still|Remove `LemonCore|NEXT" docs/plans/2026-03-19-ai-boundary-extraction-plan.md
mix lemon.quality
```

Expected:
- no stale AI-boundary migration text describes completed work as pending
- ownership docs match actual dependencies

## Recommended Execution Order

1. Milestone 1: remove router's gateway dependency.
2. Milestone 2: explicit async delivery receipts.
3. Milestone 3: canonical reasoning event constructor.
4. Milestone 5: architecture policy guardrails for current vs target.
5. Milestone 6: documentation updates for completed milestones.
6. Milestone 4: gateway startup shrink, unless a release requires transport extraction first.

Gateway extraction is intentionally later because it has the highest blast radius. The router dependency removal is smaller, easier to test, and gives the clearest architectural proof point.

## Final Verification Set

Run the full set before considering the review addressed:

```bash
rg "\bLemonCore\b" apps/ai/lib
rg "ProviderConfigResolver|Secrets|Onboarding" apps/ai/lib
rg "\bLemonGateway\b" apps/lemon_router/lib
rg "LemonGateway.ExecutionRequest|ExecutionRequest" apps/lemon_router/lib
rg "reasoning_status" apps
rg "delivery_receipt|requested_mode|actual_mode|decided_at_ms" apps
rg "TransportRegistry|TransportSupervisor|Sms|Voice" apps/lemon_gateway/lib/lemon_gateway/application.ex
mix test apps/lemon_core apps/lemon_router apps/coding_agent apps/lemon_gateway apps/lemon_channels
mix lemon.quality
```

