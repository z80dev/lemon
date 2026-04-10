# Async Followup Delivery And Provenance Plan

Status: shipped and working (3 open items remain)

Last reviewed: 2026-04-10 (Codex codebase review)

## Progress

### ✅ Quick wins (merged)
- `675d0c7c` - CustomMessage serialization round-trip tests
- `21473b7f` - Agent tool streaming check aligned with task tool behavior
- `260c1f1f` - Merge-safe `async_followups` list handling in `SessionTransitions`
- `eaa4dd07` - Follow-up review note fixes across persistence and router coverage

### ✅ PR 1: Structured ingress + durable storage (merged)
- `7eeb6f90` - Async followups now enter the system as `CustomMessage` instead of being flattened into ordinary user turns
- Core ingress is live and working:
  - Live path: `CodingAgent.Tools.Task.Followup` and `CodingAgent.Tools.Agent` build structured metadata and call `Session.handle_async_followup/2`
  - Router path: `LemonGateway.Engines.CliAdapter` passes `meta["async_followups"]` into `CodingAgent.CliRunners.LemonRunner`, which also calls `Session.handle_async_followup/2`
  - Persistence path: `CodingAgent.Session.Persistence` stores async followups as `:custom_message` entries with duplicate-entry dedupe

### ✅ PR 2: LLM provenance envelope (merged)
- `9ec7c414` - `CodingAgent.Messages.convert_to_llm/1` renders `CustomMessage{custom_type: "async_followup"}` as a user-role provenance envelope
- Current format:
  - Explicit `[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]` header
  - Source, task_id, run_id, and delivery metadata
  - Markdown code fences with dynamic fence length for safe embedding

### ✅ Delivery policy unification (merged)
- `e0314e33` - Async followup queue mode is now resolved explicitly through `CodingAgent.AsyncFollowups`
- The core system is shipped and working:
  - `task` and delegated `agent` auto-followups both use the same queue-mode resolver
  - Router-owned modes are explicit instead of purely timing-driven
  - Live delivery now depends on resolved queue mode plus live-session state

### 🔲 Remaining (verified 2026-04-10)

1. **🔴 High - `details.delivery` can be wrong after router mutation.**
   The bug is broader than "promotion to `steer_backlog`". Provenance is stamped before router mutation in `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`, `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`, and `apps/coding_agent/lib/coding_agent/tools/agent.ex`. `CodingAgent.Session.State.build_async_followup_message/2` then canonicalizes the latest async-followup entry into scalar `details.delivery`. After that, nothing in the pipeline writes back the router's actual disposition if the router promotes `:followup -> :steer`, falls back to `:followup`, or falls back to `:collect`. The real fix is an explicit delivery reconciliation stage after router disposition is known.
2. **🟡 Medium - Compaction still erases async-followup provenance in compacted history.**
   There is now a partial mitigation: `apps/coding_agent/lib/coding_agent/compaction.ex` reconstructs `CustomMessage` entries before summarization, so compaction sees async followups as structured messages. But `CodingAgent.SessionManager.build_session_context/2` still replaces compacted history with a plain user summary message, so the restored context no longer contains distinct async-followup events.
3. **🟡 Medium - Missing full router-path regression test.**
   Some coverage already exists:
   - `apps/lemon_router/test/lemon_router/session_transitions_test.exs` covers async-followup merge behavior
   - `apps/coding_agent/test/coding_agent/session/persistence_test.exs` covers persistence, save/restore, and duplicate custom-message dedupe
   - `apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs` covers router-delivered async followups entering session history
   What is still missing is one focused end-to-end regression covering `Execution -> Async -> router promotion/fallback -> LemonRunner -> restored session -> LLM projection`, which would catch the wrong-`delivery` bug above.

### Additional gaps found in the 2026-04-10 review

1. **No actual-delivery reconciliation stage exists anywhere in the pipeline.**
   The effective path is `Execution -> Async -> router -> LemonRunner -> Session`, but no stage records the router's final disposition back into persisted async-followup metadata.
2. **`steer_backlog` semantics drifted from the original plan.**
   The current code does not "always go through router with `:steer_backlog`". `CodingAgent.AsyncFollowups.dispatch_target/3` delivers live `:steer` when the parent session is streaming and live `:followup` when the session is alive but idle; only unavailable live delivery routes through the router. This behavior is reflected in `apps/coding_agent/test/coding_agent/tools/task_async_test.exs` and `apps/coding_agent/test/coding_agent/tools/agent_test.exs`.
3. **Legacy router merge drops `delivery` when reconstructing async followups from scalar metadata.**
   Low severity. `LemonRouter.SessionTransitions.extract_async_followup/1` rebuilds entries from `task_*` or `delegated_*` scalar metadata but does not restore `delivery`, so legacy merge reconstruction loses that field unless `meta["async_followups"]` is already present.

### ✅ Previously listed but no longer relevant
- ~~Duplicate persistence dedupe regression test~~ - covered in `apps/coding_agent/test/coding_agent/session/persistence_test.exs`
- ~~End-to-end router persistence regression test~~ - partial coverage exists; the remaining gap is narrower and specifically about final delivery reconciliation
- ~~Unified `handle_ingress` path~~ - no longer relevant; the dedicated `Session.handle_async_followup/2` ingress path is coherent and intentional

## Summary

This plan remains a living reference. The core async-followup provenance system is shipped and working, but three open items still matter:

- persisted `details.delivery` can drift from real router behavior
- compaction still collapses provenance in restored compacted context
- regression coverage still misses the full router promotion/fallback path

The shipped direction is sound:

- async followups are stored as `CustomMessage`
- provenance is preserved across normal persistence/restore
- provider-layer roles were not changed
- LLM projection uses an explicit provenance envelope instead of pretending the text is an ordinary user turn

## Problem Statement

Async completion handling originally had two distinct problems:

1. delivery semantics were timing-sensitive and diverged between live-session and router paths
2. async completions looked like ordinary user turns in persistence and LLM context

The first problem is mostly fixed by explicit queue-mode resolution. The second problem is fixed at the internal representation layer, but the remaining metadata-reconciliation and compaction issues keep this plan open.

## Goals

- Keep async followup delivery explicit and queue-mode driven
- Preserve session-scoped steering behavior across runs in the same session
- Keep async followups distinct from user-authored turns in persisted history
- Preserve provenance through router ingress, persistence, restore, and LLM projection
- Reconcile persisted delivery metadata with the router's actual final disposition
- Add regression coverage for the real cross-module pipeline

## Non-Goals

- Do not add run-scoped routing restrictions
- Do not introduce a new top-level `Ai.Types` role
- Do not redesign provider tool-result protocol around deferred results
- Do not remove the dedicated `handle_async_followup/2` ingress path

## Current Behavior Audit

### Delivery path today

For `task`:

1. `CodingAgent.Tools.Task.Execution` resolves async followup queue mode and builds `followup_context`.
2. `CodingAgent.Tools.Task.Followup` formats the completion and picks a dispatch target via `CodingAgent.AsyncFollowups.dispatch_target/3`.
3. Live dispatch uses `Session.handle_async_followup/2`, which persists the async followup before delivery.
4. Router dispatch submits a `RunRequest` with `meta["async_followups"]`.
5. In `LemonRouter.SessionTransitions`:
   - auto-followups submitted as `:followup` are promoted to `:steer` when a session already has an active run
   - `:steer` falls back to `:followup` if steering is rejected or the active run exits
   - `:steer_backlog` falls back to `:collect` if steering is rejected or the active run exits

For delegated `agent`:

- the same pattern now exists, using the same queue-mode resolver and the same structured async-followup metadata shape

### Provenance path today

1. `CodingAgent.Session.handle_async_followup/2` is the real ingress boundary.
2. `CodingAgent.Session.State.build_async_followup_message/2` normalizes the payload into `CustomMessage{custom_type: "async_followup"}`.
3. That state helper mirrors the latest entry from `details.async_followups` back into scalar `details.source`, `details.task_id`, `details.run_id`, `details.delivery`, `details.agent_id`, and `details.session_key`.
4. `CodingAgent.Session.Persistence.persist_message/2` stores the message as a `:custom_message` entry, with duplicate suppression for repeated message-end persistence.
5. `CodingAgent.SessionManager.build_session_context/2` restores `:custom_message` entries as `role: "custom"` maps.
6. `CodingAgent.Messages.convert_to_llm/1` renders async followups as user-role provenance envelopes.

The main remaining flaw is that steps 2 and 3 happen before router mutation is finalized, and no later stage reconciles the scalar metadata.

## Shipped Architecture Decisions

### 1. Delivery remains session-scoped, not run-scoped

This plan still allows a background completion from an earlier run to steer into a later active run on the same session. That is current product behavior, not a bug.

### 2. Async followups live inside `coding_agent`

The provenance fix stays in `coding_agent`:

- `CustomMessage` is the internal representation
- session persistence owns durability
- `Messages.to_llm/1` owns LLM projection

No provider-layer role changes were required.

### 3. Async followups are not top-level system prompt state

They remain in-band events, persisted in history and replayed through session restore and LLM projection.

## Current Internal Representation

The shipped representation is still effectively:

```elixir
%CodingAgent.Messages.CustomMessage{
  role: :custom,
  custom_type: "async_followup",
  content: completion_text,
  display: true,
  details: %{
    async_followups: [
      %{
        source: :task | :agent,
        task_id: task_id,
        run_id: run_id,
        delivery: :followup | :steer | :steer_backlog | :interrupt | :collect,
        agent_id: agent_id,
        session_key: session_key
      }
    ],
    source: ...,
    task_id: ...,
    run_id: ...,
    delivery: ...,
    agent_id: ...,
    session_key: ...
  },
  timestamp: ...
}
```

The scalar mirrors are convenient for downstream callers but are exactly where the current drift bug becomes visible once router behavior changes after initial stamping.

## Current LLM Encoding

`CodingAgent.Messages.convert_to_llm/1` currently converts async followups to a user-role envelope, not an assistant-role envelope.

Example:

````text
[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]
Source: task (ID: task-123)
Run: run-123
Delivery: followup
---
```text
[task task-123] completed ...
```
````

This is the shipped behavior and the plan should describe it accurately. The key property is the explicit provenance wrapper, not the transport role choice.

## Undocumented Provenance Code

These code paths are now part of the real design and should be treated as first-class provenance behavior even though they were not in the original plan text:

- `CodingAgent.Session.handle_async_followup/2`
  - Real ingress boundary for async followups
  - Persists the async message before deciding live followup vs live steer vs prompt-start
- `CodingAgent.Session.State.build_async_followup_message/2`
  - Canonicalizes the async payload
  - Mirrors `details.async_followups` into scalar `details.*` fields
- `CodingAgent.Session.Persistence`
  - Dedupes duplicate persisted async custom messages during message-end persistence
- `CodingAgent.Tools.Task.Result` and `CodingAgent.Tools.Task.Async`
  - Suppress late automatic async followups after an explicit `task action=join`
- `LemonRouter.SessionTransitions`
  - Preserves `async_followups` lists during followup merge
  - Prevents debounce merging of async followups
- `LemonGateway.Engines.CliAdapter`
  - Passes router async-followup provenance through to `LemonRunner` without flattening it

## Remaining Work

### 1. Add a delivery reconciliation stage

This is the real missing architecture piece.

Requirements:

- record the router's actual final delivery disposition after promotion or fallback
- update both `details.async_followups[*].delivery` and the scalar mirrored `details.delivery`
- preserve compatibility for live-delivered async followups that never touch the router

Likely integration points:

- router effect handling after `SessionTransitions.submit/3`
- or runner/session ingress when router-delivered work starts with already-mutated queue semantics

The important constraint is sequencing: reconciliation must happen after router mutation is known, not when the async followup is first created.

### 2. Preserve provenance across compaction

Current state:

- compaction summarization can now see `CustomMessage` entries
- restored compacted context still collapses them into a plain user summary

Options:

1. keep a structured compaction summary that preserves async-followup provenance
2. keep selected async-followup `CustomMessage` entries alongside the compaction summary
3. encode provenance facts into a dedicated compacted custom message instead of a plain user summary

Any fix should preserve the main product value of compaction while avoiding silent provenance loss.

### 3. Add one full router-path regression

Minimum useful regression:

1. create async followup metadata stamped as `delivery: :followup`
2. route it through `LemonRouter.SessionTransitions` while a session is active so router mutates disposition
3. feed the resulting router-delivered request through `CliAdapter` and `LemonRunner`
4. save and restore the session
5. verify persisted and projected provenance reflects final router disposition, not pre-router intent

## Current Test Coverage

Coverage that already exists:

- `apps/coding_agent/test/coding_agent/messages_test.exs`
  - async-followup LLM envelope formatting
- `apps/coding_agent/test/coding_agent/session/message_serialization_custom_message_test.exs`
  - `CustomMessage` round-trip coverage
- `apps/coding_agent/test/coding_agent/session/persistence_test.exs`
  - persistence/restore, router-delivered save/restore, duplicate-entry dedupe
- `apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs`
  - router-delivered async followups entering session history as custom messages
- `apps/coding_agent/test/coding_agent/tools/task_async_test.exs`
  - queue-mode resolution and live/router dispatch behavior for task followups
- `apps/coding_agent/test/coding_agent/tools/agent_test.exs`
  - queue-mode resolution and live/router dispatch behavior for delegated agent followups
- `apps/lemon_router/test/lemon_router/session_transitions_test.exs`
  - async-followup merge separation and debounce-blocking behavior

Coverage still missing:

- one full promotion/fallback reconciliation regression spanning router mutation through restored-session LLM projection

## Plan Items No Longer Relevant

- **Unified `handle_ingress` path**
  - No longer relevant. The dedicated `Session.handle_async_followup/2` path is coherent, easier to reason about, and already acts as the async provenance ingress boundary.

## References

- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`
- `apps/coding_agent/lib/coding_agent/async_followups.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/session/state.ex`
- `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- `apps/coding_agent/lib/coding_agent/session_manager.ex`
- `apps/coding_agent/lib/coding_agent/compaction.ex`
- `apps/coding_agent/lib/coding_agent/messages.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`
- `apps/lemon_router/lib/lemon_router/session_transitions.ex`
- `apps/lemon_gateway/lib/lemon_gateway/engines/cli_adapter.ex`
