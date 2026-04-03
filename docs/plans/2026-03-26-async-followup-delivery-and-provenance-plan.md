# Async Followup Delivery And Provenance Plan

Status: shipped (with 3 known open items)

Last reviewed: 2026-07-29 (Codex re-evaluation)

## Progress

### ✅ Quick wins (merged)
- `675d0c7c` — CustomMessage serialization round-trip tests (7 tests)
- `21473b7f` — Agent tool streaming check (matches task tool behavior)
- `260c1f1f` — Merge-safe async_followups list in SessionTransitions
- `eaa4dd07` — Quick-win review note fixes (persistence path test, health_check fallback, 3-way merge)

### ✅ PR 1: Structured ingress + durable storage (merged)
- `7eeb6f90` — CustomMessage now flows through the full async followup lifecycle
  - Live path: `task/followup.ex` and `agent.ex` build structured metadata, call `handle_async_followup/2`
  - Router path: `cli_adapter.ex` → `lemon_runner.ex` detects `meta["async_followups"]` → structured ingress
  - Persistence: `append_custom_message/2`, `json_safe/1` whitelist, explicit `serialize_message/1` clause
  - Serialization: string-key normalization for `details`, content serialization
  - 95 tests across affected suites, 0 failures

### ✅ PR 2: LLM provenance envelope (merged)
- `9ec7c414` — `convert_to_llm/1` now renders async followups as UserMessage with provenance header
  - Format: Markdown code fences (not XML — avoids injection), explicit `[SYSTEM-DELIVERED ASYNC COMPLETION]` header
  - Header includes source, task_id, run_id, delivery
  - Dynamic fence length handles embedded backticks in tool output
  - 193 total tests, 0 failures

### ✅ Delivery policy unification (merged)
- `e0314e33` — Config-driven `default_queue_mode`, explicit dispatch rules per queue_mode
  - New module: `CodingAgent.AsyncFollowups` (queue mode resolver)
  - Router-owned modes (`:steer_backlog`, `:interrupt`, `:collect`) always route through router
  - Agent tool: new `followup_queue_mode` param (separate from submission `queue_mode`)
  - 67 tests across affected suites, 0 failures

### 🔲 Remaining (verified 2026-07-29 Codex re-evaluation)

1. **🔴 High — `details.delivery` metadata can be wrong after router promotion.**
   Both `task` and delegated-agent router followups stamp provenance before router queue-mode rewriting, but `SessionTransitions.maybe_promote_auto_followup/2` can turn `:followup` into `:steer_backlog`. Persisted `details.delivery` and LLM envelope may claim `followup` when router actually did `steer_backlog`. Files: `followup.ex:209`, `agent.ex:629`, `messages.ex:484`.
2. **🟡 Medium — Compaction still erases async-followup provenance.**
   `SessionManager.build_session_context/2` emits a plain user summary for compacted history. Old async followups stop existing as distinct events even though `compaction.ex:929` can reconstruct `CustomMessage` entries before summarization. Restored long sessions lose async provenance where it matters most.
3. **🟡 Medium — Missing full router-path regression test.**
   Router-delivered save/restore and duplicate custom-message persistence already have coverage in `persistence_test.exs`, plus merge coverage in `session_transitions_test.exs`. What's missing is a focused `RunOrchestrator -> SessionTransitions promotion/merge -> LemonRunner -> restored session` regression that would catch the wrong-`delivery` bug above.

### ✅ Previously listed but already done
- ~~Duplicate persistence dedupe regression test~~ — coverage exists in `persistence_test.exs`
- ~~End-to-end router persistence regression test~~ — partial coverage exists
- ~~Consider unified `handle_ingress` path~~ — not needed; current separate `handle_async_followup/2` works

## Summary

This plan defines how to make async `task` and delegated `agent` completions
behave consistently when they land during another active run, while also fixing
the provenance bug where those completions appear to the model as if they were
user messages.

The key decisions are:

- delivery semantics must be explicit and configurable instead of timing-driven
- async completion events must not be stored or injected as `UserMessage`
- provider-layer message roles should stay unchanged; the fix belongs in
  `coding_agent`
- internal async completion events should be represented distinctly in session
  history, then converted intentionally at the LLM boundary

This plan does **not** implement run-scoped routing. If a background completion
belongs to session `S` and another run is active on `S`, steering that
completion into the newer active run remains allowed by design.

## Problem Statement

Current async completion behavior has two separate problems.

### 1. Delivery semantics are inconsistent

The current code path splits based on timing:

- if the parent session is alive and `is_streaming`, task followup tries to use
  live `follow_up`
- otherwise it falls back to router submission
- the router may then promote that followup to `:steer_backlog` if any run is
  active on the session

This means the same async completion can:

- queue after the current run
- inject into a currently active run
- honor `queue_mode` only on some paths

The behavior depends on when the completion lands, not on an explicit policy.

### 2. Async completion provenance is wrong

Today `CodingAgent.Session` wraps both `steer` and `follow_up` payloads as
`%Ai.Types.UserMessage{}`. That makes background task completions look like
ordinary user turns in:

- the live agent context
- persisted session history
- restored session context
- any downstream UI or diagnostics that infer provenance from role

This is the core reason the model can interpret async completion text as if the
user had said it.

## Goals

- Make async completion delivery deterministic from configuration and explicit
  tool input, not timing.
- Preserve the current product direction that late completions may steer into a
  newer active run in the same session.
- Stop representing async completions as user messages.
- Preserve provider compatibility by avoiding changes to `Ai.Types` roles and
  provider request builders.
- Make persisted session history distinguish async followups from user turns.
- Apply the same delivery policy to both `task` and delegated `agent`
  auto-followups.
- Add tests that cover the current race conditions and the new intended
  semantics.

## Non-Goals

- Do not add run-scoped delivery restrictions.
- Do not redesign the provider protocol around deferred tool results.
- Do not introduce a new top-level `Ai.Types` message role.
- Do not move async completion handling into system prompt state.
- Do not solve every existing custom-message provenance case in this pass unless
  directly needed for the async followup path.

## Current Behavior Audit

### Delivery path today

For `task`:

1. `CodingAgent.Tools.Task.Execution` builds `followup_context`.
2. `CodingAgent.Tools.Task.Followup.maybe_send_async_followup/4` formats the
   completion text.
3. If the session pid is alive and currently streaming, it calls live
   `follow_up`.
4. Otherwise it submits a router `RunRequest`.
5. Router `SessionTransitions` may promote auto-followups from `:followup` to
   `:steer_backlog` when the session already has an active run.

For delegated `agent`:

- similar behavior exists, but with separate implementation and slightly
  different live-session checks

### Provenance path today

1. `CodingAgent.Session.handle_cast({:steer, text}, ...)` creates
   `%Ai.Types.UserMessage{}`.
2. `CodingAgent.Session.handle_cast({:follow_up, text}, ...)` creates
   `%Ai.Types.UserMessage{}`.
3. Persistence stores these as ordinary message entries.
4. Restored session context recreates them as `Ai.Types.UserMessage`.

This is semantically wrong for background system-delivered completions.

## Architecture Decisions

### 1. Keep delivery semantics session-scoped, not run-scoped

We are explicitly **not** preserving `parent_run_id` as a gating condition for
promotion into an active run.

Allowed behavior:

1. run `R1` starts async task `T`
2. `R1` ends
3. run `R2` starts on the same session
4. `T` completes
5. completion may be injected into `R2` if configured to steer

That is not a bug for this plan. It is the intended product behavior.

### 2. Delivery policy must be explicit

The same delivery mode must be honored regardless of whether the completion is
delivered via:

- a live parent session pid
- the router fallback path

The live path must stop silently forcing `follow_up`.

### 3. Async completion provenance must be represented inside `coding_agent`

Do not solve this in `Ai` or provider adapters.

Instead:

- represent async completion events as a distinct internal message type in
  `coding_agent` history
- persist that distinct type
- convert it intentionally to an LLM-facing message shape inside
  `CodingAgent.Messages.to_llm/1`

### 4. Do not use system prompt for async completions

System prompt is top-level instruction state. Async completions are in-band
runtime events. Mixing them would:

- make them hard to persist and replay correctly
- blur instruction state with event state
- create awkward update semantics

### 5. Do not use `ToolResultMessage` for late async completions

`ToolResultMessage` is tied to actual tool-call protocol semantics and provider
adapters expect a corresponding call id / function-call output shape.

Async background completions in this code path are not true deferred tool
results in that protocol sense. Retrofitting them into `ToolResultMessage`
would create a more invasive protocol redesign than this problem requires.

## Recommended Internal Representation

Reuse `CodingAgent.Messages.CustomMessage` for async followups rather than
introducing a brand new struct.

Recommended shape:

```elixir
%CodingAgent.Messages.CustomMessage{
  role: :custom,
  custom_type: "async_followup",
  content: completion_text,
  display: true,
  details: %{
    source: :task | :agent,
    delivery: :followup | :steer | :steer_backlog | :interrupt,
    task_id: task_id,
    run_id: run_id,
    delegated: boolean()
  },
  timestamp: System.system_time(:millisecond)
}
```

Why reuse `CustomMessage`:

- session manager already supports `:custom_message` entries
- serialization already partially supports `role: "custom"`
- no new storage entry type is required
- UI/history can distinguish it from user turns immediately

## Recommended LLM Encoding

Convert `CustomMessage{custom_type: "async_followup"}` to
`Ai.Types.AssistantMessage`, not `Ai.Types.UserMessage`.

Recommended encoded content:

```text
<async_followup source="task" delivery="steer_backlog">
This is a system-delivered background completion, not a user message.

[task ...] completed ...
</async_followup>
```

Why assistant-role envelope is the least-wrong option:

- it avoids lying that the user said it
- it avoids abusing top-level system prompt state
- it avoids provider-specific tool-result constraints
- it can be implemented entirely inside `coding_agent`

The content wrapper must stay explicit so the model understands the provenance
even though the transport role is `assistant`.

## Delivery Policy

Introduce a single effective async followup delivery mode, resolved in this
order:

1. explicit tool input `queue_mode`
2. `:coding_agent` app config default
3. current tool-specific fallback default

Recommended config:

```elixir
config :coding_agent, :async_followups,
  default_queue_mode: :steer_backlog,
  llm_encoding: :assistant_envelope
```

Recommended semantics for that config:

- `default_queue_mode`
  - applies only when the tool caller did not explicitly provide `queue_mode`
  - should affect both `task` and delegated `agent` auto-followups
  - should not change the routing behavior of ordinary user-initiated runs
- `llm_encoding`
  - controls how internal async-followup messages are projected into LLM context
  - initial supported value should be `:assistant_envelope`
  - other future values can be added later without changing persistence shape

Resolution order must be tested explicitly:

1. explicit tool `queue_mode`
2. `Application.get_env(:coding_agent, :async_followups, ...)[:default_queue_mode]`
3. tool fallback default

For this plan, the tool fallback default should remain the current per-tool
default unless we decide to collapse those defaults in the same PR.

### Supported delivery modes

- `:followup`
  - queue after the current run naturally completes
- `:steer`
  - inject only if a live active run can take steering; otherwise degrade to
    router `:followup`
- `:steer_backlog`
  - deliver into an active run when possible; otherwise behave like normal
    queued work until an active run exists
- `:interrupt`
  - place the completion ahead of the queue and cancel active work via router
- `:collect`
  - not recommended as an auto-followup default; allowed only if explicitly
    requested by existing tool interfaces

### Live-session dispatch rules

The live-session path should no longer be a blanket `follow_up` fast-path.

Resolved behavior:

- `:followup`
  - if live parent session is available, call `session.follow_up/2`
  - otherwise router submit with `queue_mode: :followup`
- `:steer`
  - if live parent session is available and streaming, call `session.steer/2`
  - otherwise router submit with `queue_mode: :followup`
- `:steer_backlog`
  - always route through router with `queue_mode: :steer_backlog`
- `:interrupt`
  - always route through router with `queue_mode: :interrupt`
- `:collect`
  - always route through router with `queue_mode: :collect`

Reason:

- `:steer_backlog`, `:interrupt`, and `:collect` are router scheduling
  semantics, not plain live-session API calls
- bypassing router for those modes recreates today’s inconsistency

## Files To Modify

### Primary behavior changes

- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/messages.ex`
- `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- `apps/coding_agent/lib/coding_agent/session/message_serialization.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`

### Config and docs

- `config/config.exs` or the most appropriate config file for defaults
- `apps/coding_agent/AGENTS.md`
- `docs/config.md`

### Tests

- `apps/coding_agent/test/coding_agent/messages_test.exs`
- `apps/coding_agent/test/coding_agent/tools/task_async_test.exs`
- `apps/coding_agent/test/coding_agent/tools/agent_test.exs`
- add session-level tests if needed for persistence / restore semantics
- `apps/lemon_router/test/lemon_router/session_transitions_test.exs` only if
  assertions need updates for explicit `:steer_backlog` usage

## Detailed Implementation Plan

### Phase 1: Introduce explicit async-followup message provenance

Objective:

- stop creating `Ai.Types.UserMessage` for async `steer` and `follow_up`
  delivery

Steps:

1. Add a helper in `CodingAgent.Session` to build async followup messages as
   `CustomMessage`.
2. Include source metadata in `details`:
   - `source: :task` or `:agent`
   - `delivery: resolved_queue_mode`
   - `task_id` / `run_id` where available
3. Update live session injection paths to pass structured async metadata instead
   of bare text where needed.
4. Ensure session queues store the custom message structs, not user-message
   structs.

Notes:

- This phase is the semantic fix.
- Queue diagnostics may still remain approximate until a later cleanup; that is
  separate.

### Phase 2: Persist and restore async followup messages distinctly

Objective:

- make session history preserve provenance across save/restore

Steps:

1. Add `serialize_message/1` support for `CustomMessage`.
2. Update `Persistence.persist_message/2` to append `CustomMessage`.
3. Ensure deserialization of `role: "custom"` remains compatible with existing
   custom-message history.
4. Confirm restored sessions do not turn async followups back into user
   messages.

Compatibility rule:

- existing `CustomMessage` content types must keep their current round-trip
  behavior unless explicitly changed in this plan

### Phase 3: Add special LLM conversion for async followups

Objective:

- make only async followups convert to assistant-envelope context

Steps:

1. In `CodingAgent.Messages.convert_to_llm/1`, special-case
   `CustomMessage{custom_type: "async_followup"}`.
2. Convert it to `%Ai.Types.AssistantMessage{}`.
3. Wrap the original completion text in an explicit `<async_followup ...>`
   envelope.
4. Keep all other `CustomMessage` conversion behavior unchanged unless tests
   prove a broader cleanup is required.

Open point:

- if later we want other custom messages to gain non-user provenance, that
  should be a separate design pass

### Phase 4: Unify task followup delivery policy

Objective:

- remove timing-based split behavior from `task` async followups

Steps:

1. Add a resolver for the effective async followup queue mode.
2. Make `task` live delivery honor the resolved mode instead of always using
   `follow_up`.
3. Route router-owned modes through router even when a live parent session pid
   exists.
4. Keep current session-scoped promotion semantics intact.

### Phase 5: Apply the same policy to delegated `agent` followups

Objective:

- make delegated subagent followups match `task`

Steps:

1. Refactor `CodingAgent.Tools.Agent` to share the same delivery policy rules.
2. Stop using a separate one-off live-session behavior there.
3. Ensure delegated auto-followup metadata identifies itself as source
   `:agent`.

## Test Plan

The main test mistake to avoid is asserting accidental transport details instead
of the intended policy. Many current tests effectively assert "what happens
today when the completion lands during this exact session state", which is how
the timing-sensitive behavior became locked in.

The updated tests should assert the resolved delivery policy first, then verify
the transport chosen for that policy.

### Intended-behavior testing pattern

For each async completion test:

1. choose the effective delivery mode explicitly
   - via tool input `queue_mode`, or
   - via app config default when tool input omits it
2. choose the parent-session availability explicitly
   - live and streaming
   - live but idle
   - unavailable
3. assert the intended user-visible semantic
   - queue after current run
   - steer into current run
   - steer backlog through router
   - interrupt through router
4. only then assert the specific transport call
   - `session.follow_up/2`
   - `session.steer/2`
   - router submit with the expected `queue_mode`

This prevents tests from encoding incidental implementation shortcuts.

### Message provenance tests

Add or update tests to verify:

- async followup messages are stored as `CustomMessage`, not `UserMessage`
- persisted session entries serialize as `role: "custom"`
- restored sessions recreate `CustomMessage`
- `to_llm/1` converts `custom_type: "async_followup"` to assistant-role
  envelope
- non-async `CustomMessage` behavior remains unchanged

Recommended additions:

- a direct `Messages.to_llm/1` unit test asserting the exact wrapper text for
  `async_followup`
- a session persistence round-trip test that appends an async followup message,
  serializes it, restores it, and confirms the restored struct is still
  `CustomMessage`

### Delivery policy tests for `task`

Add or update tests to verify:

- `queue_mode: "followup"` uses live `follow_up` when available
- `queue_mode: "steer"` uses live `steer` when available
- `queue_mode: "steer"` falls back to router `:followup` when live steering is
  unavailable
- `queue_mode: "steer_backlog"` always goes through router
- `queue_mode: "interrupt"` always goes through router
- live availability no longer changes the effective semantics for those modes
- when `queue_mode` is omitted, the app-config `default_queue_mode` is used
- explicit tool `queue_mode` overrides the app-config default

Specific existing tests in
`apps/coding_agent/test/coding_agent/tools/task_async_test.exs` to update:

- `"posts completion into the live session when session pid is available"`
  - keep as the `:followup` live-path case
  - rename so the expectation is policy-based, e.g. "uses live follow_up for
    followup delivery when parent session is streaming"
- `"falls back to router followup when session pid is unavailable"`
  - keep as the `:followup` unavailable-session case
- `"falls back to router followup when session pid is alive but idle"`
  - keep as the `:followup` idle-session case
  - this should continue asserting router `:followup`
- `"uses task-level routing overrides for async followup fallback"`
  - broaden this into explicit queue-mode override coverage
  - split into separate tests for `:interrupt`, `:steer`, and
    `:steer_backlog` if needed

New `task_async_test.exs` cases to add:

- omitted `queue_mode` + config default `:steer_backlog` => router submit with
  `:steer_backlog`
- omitted `queue_mode` + config default `:followup` + live streaming session =>
  `session_follow_up`
- explicit `queue_mode: "followup"` overrides config default `:steer_backlog`
- explicit `queue_mode: "steer"` + live streaming session => `session_steer`
- explicit `queue_mode: "steer"` + idle session => router `:followup`
- explicit `queue_mode: "steer_backlog"` + live streaming session => router
  `:steer_backlog`, not live steer
- explicit `queue_mode: "interrupt"` + live streaming session => router
  `:interrupt`, not live steer/follow_up

Test helper changes likely needed in `task_async_test.exs`:

- extend `TaskAsyncSessionSpy` with `steer/2`
- add explicit spy messages for steering, e.g. `{:session_steer, text}`
- keep `get_state/1` returning controllable `is_streaming` state
- add setup helpers for temporarily overriding app config
  `:coding_agent, :async_followups`

### Delivery policy tests for delegated `agent`

Add or update tests to verify:

- delegated auto-followup uses the same queue-mode resolution rules as `task`
- live path and router path produce the same effective delivery mode
- delegated followups carry async provenance metadata
- config default is consulted when delegated run omits `queue_mode`

Specific existing tests in
`apps/coding_agent/test/coding_agent/tools/agent_test.exs` to update:

- `"auto_followup uses live session when session pid is available"`
  - narrow this to the `:followup` or configured-default-followup case
- `"auto_followup falls back to router followup when session pid is unavailable"`
  - keep as the unavailable-session `:followup` case

New `agent_test.exs` cases to add:

- omitted `queue_mode` + config default `:steer_backlog` => delegated followup
  routes through router with `:steer_backlog`
- explicit `queue_mode: "steer"` + live session => delegated completion uses
  `session.steer/2`
- explicit `queue_mode: "steer_backlog"` + live session => delegated
  completion still routes through router
- explicit `queue_mode: "interrupt"` => delegated completion routes through
  router `:interrupt`

Test helper changes likely needed in `agent_test.exs`:

- extend `AgentTestSessionSpy` with `steer/2`
- if the implementation starts checking session streaming state here too, add
  `get_state/1` helpers mirroring `task_async_test.exs`

### Config behavior tests

Add focused tests for config resolution rather than only exercising config
indirectly through larger async flows.

Recommended pattern:

```elixir
setup do
  previous = Application.get_env(:coding_agent, :async_followups)

  on_exit(fn ->
    Application.put_env(:coding_agent, :async_followups, previous)
  end)

  :ok
end
```

Then per test:

```elixir
Application.put_env(:coding_agent, :async_followups,
  default_queue_mode: :steer_backlog,
  llm_encoding: :assistant_envelope
)
```

Config-specific assertions to cover:

- no app config present => existing tool default still applies
- app config default present => omitted `queue_mode` uses configured default
- explicit tool `queue_mode` wins over app config
- invalid or missing config shape degrades safely to tool default

If this logic is extracted into a helper, add direct unit tests for that helper
instead of relying only on integration-style async tests.

### Regression coverage

Keep existing assertions that still reflect intended behavior:

- auto-followup disabled means no followup is sent
- followup text formatting remains stable where intentionally unchanged
- router meta still marks `task_auto_followup` / `delegated_auto_followup`

### Suggested commands

```bash
mix test apps/coding_agent/test/coding_agent/messages_test.exs
mix test apps/coding_agent/test/coding_agent/tools/task_async_test.exs
mix test apps/coding_agent/test/coding_agent/tools/agent_test.exs
mix test apps/lemon_router/test/lemon_router/session_transitions_test.exs
```

If session persistence tests are added:

```bash
mix test apps/coding_agent/test/coding_agent/session
```

## Rollout Notes

- This change is primarily semantic, not a data migration.
- Old saved sessions may still contain historical async completions as user
  messages; that is acceptable unless we explicitly choose to migrate old
  session files.
- New sessions should persist async followups distinctly from the moment this
  lands.

## Risks

### 1. Assistant-role envelope may bias the model differently than intended

Mitigation:

- keep the text wrapper explicit about provenance
- add focused tests around prompt conversion
- validate behavior in a real session after implementation

### 2. Existing tests may assume all custom messages become user messages

Mitigation:

- limit the behavior change to `custom_type: "async_followup"`
- leave all other custom message conversions unchanged in this pass

### 3. Config-driven defaults can make tests order-sensitive

Mitigation:

- keep the affected suites `async: false`
- save and restore app env in every config-touching test or setup block
- prefer explicit per-test `Application.put_env/3` over relying on global test
  config

### 4. Live-session APIs currently accept only text

Mitigation:

- either add structured async followup helper APIs in `CodingAgent.Session`, or
- wrap metadata into the message inside session before enqueuing

Preferred approach:

- add explicit session helpers for async followup injection so source metadata is
  not lost before persistence

## Open Questions

These are implementation questions, not blockers to the plan.

1. Should `queue_mode: :collect` remain accepted for auto-followup defaults, or
   should it be rejected for async completions except when explicitly supplied?
2. Should UI rendering surface async followups with a badge/label distinct from
   ordinary assistant history?
3. Should the session queue diagnostic counters eventually move to agent-owned
   queue state instead of the current mirror queue?

## Recommendation

Implement the provenance fix first, then unify delivery policy.

Order of work:

1. internal async followup representation
2. persistence / restore
3. LLM conversion
4. delivery policy unification for `task`
5. delivery policy unification for delegated `agent`
6. config and documentation updates
7. focused tests

That sequence gives the highest-signal semantic fix early, while keeping the
delivery-policy refactor contained and testable.

## Codex Review Findings

- `assistant`-role LLM encoding looks unsafe with the current loop semantics. `AgentCore.Loop` appends pending followups directly into context before the next model call (`apps/agent_core/lib/agent_core/loop.ex`), so converting `async_followup` to `Ai.Types.AssistantMessage` would make the conversation end on an assistant message immediately before asking for another assistant turn. That conflicts with `AgentCore`'s own `last message must not be assistant` invariant and is likely to produce invalid consecutive-assistant histories for providers in `apps/ai/lib/ai/providers/*`.

- The persistence phase is incomplete as written. `CodingAgent.Session.Persistence.persist_message/2` currently calls `SessionManager.append_message/2`, and `append_message/2` always stores a `:message` entry (`apps/coding_agent/lib/coding_agent/session/persistence.ex`, `apps/coding_agent/lib/coding_agent/session_manager.ex`). Adding `serialize_message/1` support for `CustomMessage` is not enough to persist a distinct `:custom_message`; the implementation must append `SessionEntry.custom_message(...)` or add an equivalent helper.

- The plan does not fully cover router-delivered provenance. Router fallback and router-owned modes eventually land in `CodingAgent.Session.prompt/3` as plain prompt text through `CodingAgent.CliRunners.LemonRunner` (`apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`), and `prompt/3` only builds `Ai.Types.UserMessage` (`apps/coding_agent/lib/coding_agent/session.ex`, `apps/coding_agent/lib/coding_agent/session/state.ex`). If only `Session.steer/2` and `Session.follow_up/2` are changed, the provenance bug remains for dead/idle-parent fallback, `:steer_backlog`, and `:interrupt`.

- The delegated `agent` tool uses `queue_mode` for delegated run submission today, not for completion followup delivery (`apps/coding_agent/lib/coding_agent/tools/agent.ex`). The plan treats explicit or omitted `queue_mode` as the source of async followup policy for delegated runs, which would silently change the meaning of an existing public parameter and could alter delegated run scheduling from the current default `:collect`. This likely needs a separate followup-routing option or an explicit split between submission queue mode and auto-followup queue mode.

- The proposed `details.delivery` field is underspecified and can easily become misleading. In `LemonRouter.SessionTransitions`, `:steer` can degrade to `:followup` and `:steer_backlog` can degrade to `:collect` (`apps/lemon_router/lib/lemon_router/session_transitions.ex`). If the stored metadata records the requested mode, diagnostics and replay will lie about what actually happened; if it is meant to record actual delivery, the plan needs a post-router acknowledgement/update path that is not currently described.

- Missing regression coverage: the test plan focuses on direct `task` and delegated `agent` helpers, but the highest-risk path is end-to-end router delivery into a real session. Add at least one test that exercises router fallback all the way through `RunRequest -> LemonRunner -> CodingAgent.Session` and verifies the restored session history still contains `CustomMessage`, not `UserMessage`.

- Missing edge case: the proposed `<async_followup ...>` wrapper injects raw completion text inside XML-like tags without any escaping rule. A completion that contains `</async_followup>` or attribute-looking text can break the envelope and defeat the provenance hint. The plan should either specify escaping/encoding or use a delimiter format that cannot be trivially terminated by model/tool output.

## Claude Review Findings

### Correctness Issues

1. **AgentCore type contract violation**: `agent_message()` is defined as
   `Ai.Types.message()` = `UserMessage | AssistantMessage | ToolResultMessage`
   (`agent_core/types.ex:46`, `ai/types.ex:127`). Passing
   `CodingAgent.Messages.CustomMessage` into `AgentCore.Agent.steer/2` or
   `follow_up/2` works at runtime (Elixir doesn't enforce typespecs), but
   AgentCore's loop consumes queued messages and feeds them through
   `convert_to_llm`. If any AgentCore internals pattern-match on
   `%Ai.Types.UserMessage{}` (vs. generic map access), CustomMessage will fail
   to match silently. The plan should verify that AgentCore's queue consumption
   path (`loop.ex` get_steering_messages / get_follow_up_messages callbacks) is
   struct-agnostic, or propose wrapping CustomMessage at the AgentCore boundary
   rather than queuing it directly.

2. **`details` atom-to-string key mismatch on round-trip**: The plan puts atom
   keys in `details` (`:source`, `:delivery`, `:task_id`, etc.). After JSON
   serialization and deserialization, `message_serialization.ex:157` passes
   `msg["details"]` through directly, yielding string keys like `"source"`,
   `"delivery"`. Any code that later pattern-matches on `details.source` or
   `details[:source]` will fail. The plan should specify either:
   (a) always using string keys in `details`, or (b) adding key normalization in
   deserialization.

3. **No explicit `serialize_message/1` clause for CustomMessage**: Serialization
   currently falls through to the generic `is_map(msg)` catch-all at
   `message_serialization.ex:49`, which returns the struct as-is (with atom
   keys). This means the `content` field does not pass through
   `serialize_content/1`, and the persisted shape will have atom keys instead of
   the string keys that `deserialize_message(%{"role" => "custom"})` expects.
   Phase 2 says "Add `serialize_message/1` support for CustomMessage" — this is
   correct but should be called out as a **prerequisite**, not an afterthought,
   since the current generic path silently produces broken round-trips.

4. **Agrees with Codex finding on assistant-role encoding**: The consecutive
   `AssistantMessage` concern from the Codex review is valid and represents the
   most critical correctness risk. Additionally: if a follow-up async completion
   is the *first* message in a restored session context (e.g., all prior user
   messages were compacted), the LLM would see a context starting with an
   assistant message and no user message, which most providers reject.

### Feasibility Concerns

5. **Session public API accepts `String.t()`, not structs**: Both `steer/2` and
   `follow_up/2` accept plain text (`@spec steer(server, String.t()) :: :ok` at
   `session.ex:293`). The task followup code calls
   `session_module.follow_up(session_pid, text)` with bare strings. To pass
   source metadata (`:task` vs `:agent`, `task_id`, `run_id`), the plan must
   either: (a) change the API signature (breaking callers), (b) add new
   `async_follow_up/3` functions that accept metadata, or (c) build the
   CustomMessage entirely inside the session handler using only the text and
   some ambient state. Option (c) loses metadata since the session handler
   doesn't know whether the text came from a task or an agent. The plan
   acknowledges this in Risk #4 but doesn't commit to an approach — this should
   be decided before implementation starts.

6. **Agent tool asymmetry with task followup**: The agent tool's
   `send_followup_via_live_session/2` (`agent.ex:543`) does NOT check
   `live_session_streaming?` before calling `follow_up/2`, unlike
   `task/followup.ex:145` which does. Phase 5 says to "share the same delivery
   policy rules" but doesn't explicitly flag this behavioral difference. During
   unification, the streaming check must be added to the agent path (or removed
   from the task path with justification).

### Edge Cases Not Covered

7. **In-flight tasks across deployment**: If a task is spawned with the old code
   and completes after the new code is deployed, the old-format followup text
   arrives via `session.follow_up/2`. The new handler would need to handle both
   structured (CustomMessage) and legacy (plain text) inputs gracefully. The
   rollout notes mention old saved sessions but not in-flight tasks.

8. **`:steer` degradation chain through auto-followup promotion**: When
   `queue_mode: :steer` degrades to router `:followup` (because live steering is
   unavailable), `SessionTransitions.maybe_promote_auto_followup/2`
   (`session_transitions.ex:198-206`) promotes `:followup` to `:steer_backlog`
   if the metadata has `task_auto_followup: true` and there's an active run. So
   the effective chain is `:steer` → `:followup` → `:steer_backlog`. Is this
   intended? The plan doesn't document this double-degradation behavior. If
   someone explicitly requests `:steer`, being silently promoted to
   `:steer_backlog` on fallback may be unexpected.

9. **Multiple concurrent async completions**: If two tasks complete
   simultaneously and both send follow-ups to the same session, the plan doesn't
   discuss ordering guarantees. With the current `GenServer.cast` approach,
   ordering depends on mailbox arrival order, which is nondeterministic across
   nodes. If both are encoded as `AssistantMessage`, this creates consecutive
   assistant messages (compounding the Codex review concern).

10. **`queue_mode: :collect` semantics for auto-followups**: The plan says
    `:collect` is "not recommended as an auto-followup default; allowed only if
    explicitly requested." But `RunRequest` defaults `queue_mode` to `:collect`
    (`lemon_core/run_request.ex:36`). If the config resolution chain fails to
    find any default and falls through to `RunRequest.new`, the effective mode
    will be `:collect`. The plan should either guarantee that the resolution
    chain never falls through, or document what happens if it does.

### Implementation Risks

11. **Config test isolation**: The plan correctly recommends `async: false` for
    config-touching tests, but the existing test files
    (`task_async_test.exs`, `agent_test.exs`) may already run as `async: true`.
    Changing them to `async: false` could expose ordering bugs in those suites
    or significantly slow down the test run. Verify the current async setting
    before committing to this.

12. **No dedicated `message_serialization_test.exs`**: The plan lists
    persistence round-trip tests but doesn't note that there are currently NO
    dedicated serialization/deserialization tests. The existing
    `persistence_test.exs` tests only cover `persist_message` and
    `restore_messages_from_session` at a high level. Adding the serialization
    tests proposed in the plan is good but may require more test infrastructure
    than estimated.

13. **Agrees with Codex finding on router-delivered provenance**: The most
    common fallback path (router → LemonRunner → `Session.prompt/3`) creates
    `UserMessage` and is NOT covered by changes to `steer/2` and `follow_up/2`
    only. This is the highest-risk gap in the plan — the fix would appear to
    work in the live-session path but silently fail for the router fallback
    path, which is the one triggered when sessions are idle or dead (arguably
    the more common case for long-running async tasks).

### Suggestions

14. **Consider user-role encoding with metadata prefix instead of
    assistant-role**: Given the consecutive-assistant-message constraint and the
    "last message must not be assistant" invariant, encoding async followups as
    `UserMessage` with an explicit provenance prefix (e.g.,
    `[System: async task completion, not from user]\n...`) may be simpler and
    avoid provider compatibility issues entirely. The semantic inaccuracy of
    "user role" is offset by the XML wrapper making provenance clear to the
    model. This sidesteps the most critical correctness risk in the plan.

15. **Add a `source` field to the session-level follow_up/steer API**: Rather
    than changing the existing `String.t()` API, add optional keyword opts:
    `follow_up(session, text, source: :task, task_id: id)`. This preserves
    backwards compatibility while enabling metadata flow.

## Codex Re-Review Findings (2026-07)

### Correctness Issues

1. **The earlier assistant-role warning still stands and should now be treated
   as a hard blocker for the proposed `llm_encoding: :assistant_envelope`
   design**. `CodingAgent.Messages.convert_to_llm/1` is still where
   `CustomMessage` is projected to LLM roles
   (`apps/coding_agent/lib/coding_agent/messages.ex:407-418`), and
   `AgentCore.Loop` still refuses to continue from a context whose last message
   is assistant (`apps/agent_core/lib/agent_core/loop.ex:216-225`) while also
   re-injecting follow-up messages as the pending messages for the next outer
   turn (`apps/agent_core/lib/agent_core/loop.ex:400-418`). Nothing in the
   current codebase has relaxed that invariant since March.

2. **The earlier router-delivered provenance finding is still accurate, and it
   now clearly requires a structured ingress path rather than just changing
   `Session.steer/2` and `Session.follow_up/2`**. Router fallback still lands in
   `CodingAgent.Session.prompt/3` through `LemonRunner`
   (`apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex:280-281`),
   `Session.prompt/3` still builds a plain prompt message via
   `State.build_prompt_message/2`
   (`apps/coding_agent/lib/coding_agent/session.ex:558-571`), and
   `State.build_prompt_message/2` still only produces `%Ai.Types.UserMessage{}`
   (`apps/coding_agent/lib/coding_agent/session/state.ex:72-95`). The plan
   still underestimates this path.

3. **Router follow-up merging is now the largest unaddressed provenance bug
   beyond the live-path issue**. `SessionTransitions` still merges adjacent
   `:followup` submissions within the debounce window
   (`apps/lemon_router/lib/lemon_router/session_transitions.ex:221-271`), and
   the merge logic overwrites duplicate metadata keys with `Map.merge/2`
   (`apps/lemon_router/lib/lemon_router/session_transitions.ex:393-403`). If
   the plan stores one `task_id`/`run_id`/`delivery` tuple in `details`, merged
   followups will silently report only the later completion while keeping a
   concatenated prompt body. That makes the earlier Codex concern about
   `details.delivery` being misleading more severe than the March version
   described.

4. **The persistence review is still correct, but the current code reveals a
   sharper failure mode than the earlier review captured**. `Persistence` still
   persists only `%Ai.Types.UserMessage{}`, `%Ai.Types.AssistantMessage{}`, and
   `%Ai.Types.ToolResultMessage{}` via `append_message/2`
   (`apps/coding_agent/lib/coding_agent/session/persistence.ex:10-37`,
   `apps/coding_agent/lib/coding_agent/session_manager.ex:425-428`), and
   `MessageSerialization.serialize_message/1` still falls through to a generic
   `is_map/1` clause for anything else
   (`apps/coding_agent/lib/coding_agent/session/message_serialization.ex:14-18`,
   `apps/coding_agent/lib/coding_agent/session/message_serialization.ex:49-50`).
   The important additional point is that `SessionManager.json_safe/1`
   whitelists only `Ai.Types.*` structs, not `CodingAgent.Messages.*`
   (`apps/coding_agent/lib/coding_agent/session_manager.ex:991-1016`). If a
   `CustomMessage` or its content blocks are persisted through the generic path,
   unknown structs can collapse to `inspect/1` strings instead of round-tripping
   as structured content.

### Feasibility Concerns

5. **`SessionManager` already supports `:custom_message` on the restore side, so
   the plan should treat that part as partially done and explicitly add
   `session_manager.ex` to `Files To Modify`**. The entry constructor already
   exists (`apps/coding_agent/lib/coding_agent/session_manager.ex:238-248`),
   restored session context already emits `"role" => "custom"`
   (`apps/coding_agent/lib/coding_agent/session_manager.ex:585-602`), and
   compaction already reconstructs `Messages.CustomMessage` from
   `:custom_message` entries (`apps/coding_agent/lib/coding_agent/compaction.ex:923-949`).
   The missing work is append/persist plumbing, not storage model invention.

6. **The earlier Claude type-contract finding is real but narrower than it was
   phrased in March**. `AgentCore.Types.agent_message()` is still declared as
   `Ai.Types.message()` (`apps/agent_core/lib/agent_core/types.ex:41-46`), so
   queuing `CustomMessage` still violates the public typespec. But the queue
   consumers themselves are currently struct-agnostic and simply return whatever
   was queued (`apps/agent_core/lib/agent_core/agent.ex:659-672`). This looks
   like a documentation/dialyzer mismatch more than a proven runtime blocker.
   The plan should still widen the type if it queues `CustomMessage` directly.

7. **The earlier delegated-agent `queue_mode` concern is unchanged**.
   Validation still treats `queue_mode` as the delegated run submission mode and
   defaults it to `"collect"`
   (`apps/coding_agent/lib/coding_agent/tools/agent.ex:847-917`), while the
   delegated auto-followup path still ignores that setting and hardcodes router
   fallback to `:followup`
   (`apps/coding_agent/lib/coding_agent/tools/agent.ex:561-587`). Reusing the
   same parameter as the async completion delivery policy would still change the
   meaning of an existing public field.

### Edge Cases Not Covered

8. **Compaction still erases async-followup provenance even if persistence is
   fixed**. `SessionManager.build_session_context/2` still materializes the
   compaction summary as a plain `"role" => "user"` message
   (`apps/coding_agent/lib/coding_agent/session_manager.ex:533-551`). That
   means any async-followup messages compacted out of the kept branch stop being
   distinguishable to the model on restored sessions. The plan currently treats
   persistence/restore as the end of the provenance story, but compaction is
   still a lossy hop.

9. **Merged router followups need an explicit multi-event representation, not a
   single prompt plus merged metadata**. `merge_prompt/2` concatenates prompt
   bodies with a newline
   (`apps/lemon_router/lib/lemon_router/session_transitions.ex:389-391`) while
   `merge_user_message_meta/2` keeps only one value per key
   (`apps/lemon_router/lib/lemon_router/session_transitions.ex:393-403`). The
   plan does not currently say whether two near-simultaneous async completions
   should become one stored custom message, two stored custom messages, or one
   envelope containing an array of completions.

10. **A structured router prompt will currently crash unless the session prompt
    API changes first**. `Session.prompt/3` accepts `text` and immediately calls
    `State.build_prompt_message/2`
    (`apps/coding_agent/lib/coding_agent/session.ex:558-563`), and
    `State.build_prompt_message/2` only has a binary clause
    (`apps/coding_agent/lib/coding_agent/session/state.ex:72-73`). Any attempt
    to solve router provenance by passing a map/struct through `RunRequest.prompt`
    without first widening the session API will fail at runtime.

### Implementation Risks

11. **The March review note about config-test async isolation is now stale for
    the two suites that matter most here**. Both
    `task_async_test.exs` and `agent_test.exs` already run with
    `async: false`
    (`apps/coding_agent/test/coding_agent/tools/task_async_test.exs:1-3`,
    `apps/coding_agent/test/coding_agent/tools/agent_test.exs:1-3`), so the
    plan no longer needs to budget for converting those files. The risk is now
    localized to any new config-mutating tests added elsewhere.

12. **The existing `Messages` test suite still hardcodes the current
    `CustomMessage -> UserMessage` behavior, so phase 3 will create a focused
    but unavoidable test churn point**. The current expectations are explicit in
    `apps/coding_agent/test/coding_agent/messages_test.exs:277-300`. This is
    still an implementation risk, but it is narrower and more obvious now than
    the March wording suggested.

13. **There is still no dedicated message-serialization test file, and the
    current persistence coverage remains too shallow for this change**. The only
    direct persistence tests still cover a single user message append and a
    simple restore case
    (`apps/coding_agent/test/coding_agent/session/persistence_test.exs:7-33`).
    That means the plan should continue to budget for new serialization
    round-trip coverage rather than assuming existing tests will catch
    `CustomMessage` regressions.

## Gemini Review Findings (2026-07)

### Correctness Issues

1.  **Agrees with all prior reviews: `llm_encoding: :assistant_envelope` is fundamentally incompatible with `AgentCore.Loop`'s invariants and will break continuation.** The loop at `apps/agent_core/lib/agent_core/loop.ex:400-418` still unconditionally prepends follow-up messages to the list of pending messages for the *next* turn. The check at `apps/agent_core/lib/agent_core/loop.ex:216-225` still correctly refuses to start a turn if the history ends with an assistant message. Combining these two means that any async followup encoded as an assistant message will cause the *next* turn to fail its precondition check. This is not a minor issue; it is a hard blocker for the proposed encoding strategy.

2.  **Agrees with all prior reviews: The router fallback path remains the largest unaddressed provenance gap.** Router-delivered followups still arrive as plain text to `CodingAgent.Session.prompt/3` via `LemonRunner`, which can only create `Ai.Types.UserMessage`. The plan's focus on `steer/2` and `follow_up/2` only covers the live-session case and will not fix the more common idle/dead-session scenario. The fix *must* involve a structured-data path from `RunRequest` through to `Session`.

3.  **Router followup merging still corrupts provenance metadata.** The `Map.merge/2` logic in `SessionTransitions.merge_user_message_meta/2` (`apps/lemon_router/lib/lemon_router/session_transitions.ex:393-403`) is lossy by design. If two tasks complete in the same debounce window, their `details` maps will be merged, with the later one's values overwriting the earlier one's. The resulting `CustomMessage` would have a concatenated body but only the provenance of the *last* task, making it impossible to correctly trace or debug.

4.  **`CustomMessage` persistence is still broken by default.** As noted in prior reviews, `SessionManager.append_message/2` does not have a clause for `CustomMessage`. Critically, `SessionManager.json_safe/1` (`apps/coding_agent/lib/coding_agent/session_manager.ex:991-1016`) also does not whitelist `CodingAgent.Messages.CustomMessage`, which can lead to the struct being silently converted to an `inspect/1` string during persistence, causing a total loss of structured data.

### Feasibility Concerns

5.  **The proposed solution for the `details` atom/string key mismatch is insufficient.** The plan suggests either always using string keys or normalizing on deserialization. However, `MessageSerialization.deserialize_message/1` for `"role" => "custom"` (`apps/coding_agent/lib/coding_agent/session/message_serialization.ex:156-159`) currently just returns `msg["details"]` as-is. The most robust fix is to use a dedicated function like `Jason.decode(Jason.encode!(details))` to force a full string-key conversion on the way in, and `Code.ensure_compiled(Jason)` to avoid lazy-loading issues.

### Edge Cases Not Covered

6.  **(Security) Unescaped content in the proposed XML envelope creates an injection vector.** The plan proposes `<async_followup...>#{content}</async_followup>`. If `content` contains `</async_followup>`, it prematurely terminates the envelope, allowing the model to interpret the rest of the content outside the intended provenance wrapper. This is a classic injection vulnerability. Any wrapper must either use a format that cannot be terminated by content (e.g., Markdown code fences ` ``` `) or rigorously escape the content (e.g., XML entity encoding).

7.  **Compaction erases async-followup provenance.** `SessionManager.build_session_context/2` (`apps/coding_agent/lib/coding_agent/session_manager.ex:533-551`) materializes the compaction summary as a single `role: "user"` message. Any `CustomMessage` instances that are part of the compacted history are lost and their content is blended into this generic user message. Therefore, on a restored session, the model will lose all special provenance for older, compacted followups.

8.  **The plan's phased approach is in the wrong order.** It proposes implementing provenance (`CustomMessage`) and LLM encoding *before* unifying the delivery policy. However, since the router fallback path (`LemonRunner` -> `Session.prompt/3`) is the most common delivery mechanism for long-running tasks and it only handles plain text, the provenance fix won't work for most cases until the delivery path is made to support structured data. The delivery path refactor must come first.

### Implementation Risks

9.  **The `agent` tool `queue_mode` conflict is a significant API risk.** The plan reuses the `queue_mode` parameter, which currently controls the *submission* of the delegated run, to also control the *completion followup*. This is a breaking change in semantics. A new, dedicated parameter like `followup_queue_mode` is required to avoid ambiguity and unexpected behavior for existing callers of the `agent` tool.

### Suggestions

10. **Use a user-role envelope with a non-XML wrapper as the LLM encoding.** To resolve the hard blocker with the `AgentCore.Loop` invariant, async followups should be projected as `Ai.Types.UserMessage`. To solve the provenance and security issues, use a robust, non-nesting wrapper like Markdown code fences with a clear header.
    ```markdown
    [SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]
    Source: task (ID: task-...)
    Delivery: steer_backlog
    ---
    ```
    The task `implement the new feature` completed successfully.
    ```
    ```
    This is safe, unambiguous for the model, and compatible with all existing provider and `AgentCore` constraints.

11. **Prioritize a structured ingress path for all followup types.** Before any other changes, refactor `Session.prompt/3`, `Session.steer/2`, and `Session.follow_up/2` to delegate to a single internal `handle_ingress(message_struct)` function. Then, update `LemonRunner` and the live-session callers to build and pass a structured `CustomMessage` instead of plain text. This fixes the router-path bug upfront.

12. **For merged followups, store provenance as a list in `details`.** Instead of a scalar `task_id`, the merged `CustomMessage` should contain `details: %{"async_followups" => [%{source: :task, task_id: "a"}, %{source: :task, task_id: "b"}]}`. This preserves the full chain of provenance. The LLM envelope can then render a summary for all completed tasks.

13. **Create a dedicated `CodingAgent.Session.Persistence.append_custom_message/2` function.** This makes the intent explicit and ensures the correct `SessionEntry.custom_message/1` constructor is called, resolving the persistence bug. Also, add `CodingAgent.Messages.CustomMessage` to the `json_safe/1` whitelist in `SessionManager`.

14. **Revised Phase Order:**
    1.  **Phase 1: Structured Ingress.** Create a unified `handle_ingress` in `Session` that accepts message structs. Update all callers (`LemonRunner`, `steer`, `follow_up`) to pass `CustomMessage` structs. This makes all delivery paths structurally aware.
    2.  **Phase 2: Persistence & Serialization.** Implement `append_custom_message` and fix the `json_safe` whitelist and `MessageSerialization` round-trip logic. Add dedicated serialization tests.
    3.  **Phase 3: Safe LLM Encoding.** Implement the user-role envelope with Markdown code fences in `Messages.convert_to_llm/1`.
    4.  **Phase 4: Delivery Policy Unification.** With the structured path in place, now implement the unified queue-mode resolution logic for both `task` and `agent` tools, confident that the chosen mode will be honored. Add a `followup_queue_mode` parameter to the `agent` tool.

## 2026-07 Implementation Readiness Assessment (Codex) — ARCHIVED

> **Note:** This section described the codebase state *before* the provenance work landed.
> All items listed as `still present` below have been addressed in the shipped commits
> (`675d0c7c`, `21473b7f`, `260c1f1f`, `eaa4dd07`, `7eeb6f90`, `9ec7c414`, `e0314e33`, `c2f7b9a8`).
> Kept for historical reference only. See "Remaining" section above for current open items.

### Review finding status (archived)

All items below were `still present` at time of review. All have since been shipped.

### Codex Review Findings — all `fixed`

### Claude Review Findings — all `fixed`

### Codex Re-Review Findings (2026-07) — all `fixed`

### Gemini Review Findings (2026-07) — all `fixed`

### Recommended implementation order — ARCHIVED

> This order was followed. All phases shipped.

### Cross-Workstream Conflict Analysis (Codex) — ARCHIVED

> This analysis is historical. The provenance workstream is shipped. The status projection workstream is deferred (see `memory/topics/async-task-status-review.md`).

## Cross-Workstream Conflict Analysis (Codex) — ARCHIVED

> Historical reference. The provenance workstream shipped. The status projection workstream
> is deferred (architecture cleanup only, not missing product capability).
> The coordination recommendations below were followed during implementation.

*(Full analysis preserved below for archive purposes.)*

Direct overlap or adjacent seam overlap:

- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
  - status workstream depends on this module continuing to emit stable async followup/task identity (`task_id`, `run_id`, queue semantics) even though it does not own status rendering.
  - followup/provenance workstream explicitly changes its live-session vs router fallback behavior.
- `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`
  - status path already depends on `detail.result_meta` coming through Lemon-runner-backed task/poll flows.
  - followup/provenance plan explicitly needs this file for router-delivered structured ingress.
- `apps/lemon_router/lib/lemon_router/session_transitions.ex`
  - status workstream does not center on it, but current async task completions use its auto-followup promotion and merge behavior.
  - followup/provenance workstream explicitly needs merge-safe async provenance here.

Shared infrastructure with strong coupling but mostly non-overlapping edits:

- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
- `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex`
- `apps/lemon_router/lib/lemon_router/surface_manager.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/session/state.ex`
- `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- `apps/coding_agent/lib/coding_agent/session/message_serialization.ex`
- `apps/coding_agent/lib/coding_agent/session_manager.ex`
- `apps/coding_agent/lib/coding_agent/messages.ex`
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`
- `apps/coding_agent/lib/coding_agent/task_store.ex`
- `apps/coding_agent/lib/coding_agent/run_graph.ex`

### What each workstream currently assumes

Live Status Projection currently assumes:

- async child progress can be mapped back to the parent task surface through `TaskProgressBindingStore` and `AsyncTaskSurfaceSubscriber`.
- task roots expose stable `detail.result_meta.task_id`, `detail.result_meta.run_id`, `detail.result_meta.status`, `detail.result_meta.current_action`, and `detail.result_meta.action_detail` for poll rebinding and embedded child rendering.
- router-owned display code still compensates for hybrid ownership in `SurfaceManager`, `RunProcess`, and `ToolStatusCoalescer`.

Async Followup Delivery & Provenance currently assumes:

- async completion delivery still enters the session through text-first APIs: `CodingAgent.Session.prompt/3`, `steer/2`, and `follow_up/2`.
- router fallback still carries binary prompt text and queue metadata, with `SessionTransitions.merge_prompt/2` concatenating strings.
- a safe first fix uses structured provenance in metadata plus structured ingress at `LemonRunner`/`Session`, without sending raw structs through `RunRequest.prompt`.

### Conflicts found

No hard architectural contradiction was found. The workstreams target different layers:

- live status is primarily router-side status-surface ownership and async child projection.
- followup/provenance is primarily session ingress, persistence, and model-context encoding.

The real conflicts are sequencing and contract conflicts:

1. `SessionTransitions` is a shared correctness hotspot.
- Followup/provenance needs merge-safe `async_followups` accumulation instead of current scalar-overwrite `Map.merge/2`.
- If that is not fixed first, concurrent async completions can still lose provenance even if structured ingress lands.
- Status work does not directly depend on that data today, but it shares the same async completion traffic and queue timing.

2. `LemonRunner` is a shared ingress seam.
- Followup/provenance needs it to detect router-carried async metadata and call structured session ingress.
- Status already relies on Lemon-runner-backed task metadata surviving through poll/result flows.
- A parallel change that starts sending non-binary prompt payloads through router before `LemonRunner` and `Session` are updated would break current router assumptions (`merge_prompt/2` still assumes text).

3. The status redesign wants to delete infrastructure the current system still uses.
- The status review explicitly recommends eventually removing `TaskProgressBindingStore`, `TaskProgressBindingServer`, and `CodingAgent.Tools.Task.LiveBridge`.
- That does not block followup/provenance directly, but it means the status branch must not delete or repurpose task/run identity plumbing until router-owned replacements preserve the current `task_id`/`run_id` contract.

4. Metadata namespace drift is an avoidable conflict.
- Status currently relies on `result_meta` and projected-child `detail` fields for display routing.
- Followup/provenance should keep using a dedicated metadata key such as `async_followups` on router submissions, not overload status metadata fields.
- This matches the followup plan's current assessment and avoids accidental collisions with status rendering.

### Shared infrastructure opportunities

- Canonical async identity contract:
  keep `task_id`, `run_id`, `parent_run_id`, and queue-mode semantics stable across both workstreams. Both features already rely on `TaskStore` and `RunGraph`.
- Canonical router-carried async metadata:
  define one dedicated `meta["async_followups"]` list shape for completion provenance. That can be merged in `SessionTransitions` without touching status metadata.
- Router-owned async lifecycle ownership:
  if the AsyncTaskSurface redesign proceeds, it should reuse existing task lifecycle events on `LemonCore.Bus` plus `TaskStore`/`RunGraph`, instead of inventing a second async identity source.
- Shared end-to-end tests:
  add at least one router fallback async completion test that verifies both:
  router queue/merge behavior and session ingress provenance preservation.

### Recommended implementation order

1. Land a small shared-contract cut first.
- Update `apps/lemon_router/lib/lemon_router/session_transitions.ex` to accumulate async provenance as a list instead of overwriting scalar metadata.
- Keep router prompts binary; do not send raw `%CustomMessage{}` through `RunRequest.prompt`.
- Reserve a dedicated router metadata key for async provenance, separate from status metadata.

2. Land followup/provenance structured ingress next.
- `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/session/state.ex`
- `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- `apps/coding_agent/lib/coding_agent/session/message_serialization.ex`
- `apps/coding_agent/lib/coding_agent/session_manager.ex`
- `apps/coding_agent/lib/coding_agent/messages.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`

3. Then do the deeper AsyncTaskSurface/status ownership cleanup.
- `apps/lemon_router/lib/lemon_router/surface_manager.ex`
- `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`

Reason for this order:

- the followup/provenance work fixes a current correctness bug on `main`.
- it only needs a small router contract change up front.
- the status redesign is broader and explicitly intends to remove compatibility layers, so it is safer to do after the ingress/provenance carrier is stabilized.

### Final verdict

These workstreams should not be treated as fully independent, but they also do not need to be strictly sequential end-to-end.

- They can proceed in parallel after a small shared contract agreement on:
  `SessionTransitions` merge behavior, router metadata naming, and keeping prompt transport text-based.
- They should avoid concurrent edits to:
  `apps/lemon_router/lib/lemon_router/session_transitions.ex`
  and
  `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`.
- The status redesign should merge after the ingress/provenance carrier is stable, especially before deleting `TaskProgressBindingStore`/`LiveBridge` compatibility paths.

Practical verdict: parallelizable with coordination, but not safely independent; do the small router metadata/merge contract first, then followup/provenance, then the heavier AsyncTaskSurface cleanup.
