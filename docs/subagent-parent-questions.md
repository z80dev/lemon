# Subagent Parent Questions

Design note for adding a structured child-to-parent clarification path for Lemon subagents.

Last reviewed: 2026-03-13
Owner: @z80

---

## Summary

Lemon already has strong parent-to-child control:

- parent/child run lineage in `CodingAgent.RunGraph`
- async task lifecycle and followup routing in `CodingAgent.Tools.Task`
- deferred routing via `CodingAgent.Session.follow_up/2`

What Lemon does not have today is a structured reverse path where a spawned subagent can pause, ask its parent for a clarification or decision, and then resume execution after the parent answers.

This document proposes a narrow `ask_parent` tool for subagents plus a small parent-facing `parent_question` tool for resolving those requests. The goal is to preserve bounded delegation while giving children a safe escalation path for decisions that cannot be resolved locally.

---

## Problem

Today a subagent has two unsatisfying options when it needs clarification:

1. guess and continue
2. stop early and return a partial result asking the parent to rerun or manually continue

Both are suboptimal.

Guessing hurts correctness. Returning early hurts orchestration because the parent must translate a partial result back into a new child run instead of answering a structured question and letting the same child continue.

At the same time, a general-purpose bidirectional chat channel between child and parent would be a mistake. It would encourage prompt ping-pong, reduce the value of delegation, and complicate lineage, telemetry, and failure handling.

The design target is therefore:

- narrow, structured escalation
- explicit pause/resume semantics
- visible lineage and telemetry
- minimal changes to the current task/session architecture

---

## Existing Relevant Architecture

The current codebase already provides most of the primitives needed for this feature.

### Existing capabilities

- `CodingAgent.Tools.Task.Execution` creates child task context including `run_id`, `task_id`, `parent_run_id`, `session_key`, and `agent_id`.
- `CodingAgent.Tools.Task.Async` emits task lifecycle events to `LemonCore.Bus` and `LemonCore.Introspection`, and already broadcasts to both child and parent run topics.
- `CodingAgent.Tools.Task.Followup` can route async completion text back into the live parent session or through router fallback.
- `CodingAgent.Session.follow_up/2` can queue a message into the parent session.
- `CodingAgent.Session` already accepts `extra_tools`, so child-only tooling can be injected without exposing it globally.
- `CodingAgent.TaskStore` and `CodingAgent.RunGraph` already persist bounded task/run state with DETS-backed recovery.

### Relevant files

- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/params.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/session/state.ex`
- `apps/coding_agent/lib/coding_agent/task_store.ex`
- `apps/coding_agent/lib/coding_agent/run_graph.ex`
- `apps/coding_agent/lib/coding_agent/tools.ex`
- `apps/coding_agent/lib/coding_agent/tool_registry.ex`

---

## Goals

- Let a spawned subagent ask its parent a structured clarification question.
- Preserve the child run instead of forcing a new run after the answer arrives.
- Keep the mechanism narrow enough that it is used for decisions, not casual conversation.
- Expose request/answer lifecycle through the same bus and introspection patterns already used for task events.
- Keep Phase 1 limited to in-process parent/child task sessions.

## Non-Goals

- full free-form parent/child chat
- arbitrary child-to-parent tool execution
- multi-hop conversation trees between sibling subagents
- cross-node or remote-agent support in Phase 1
- UI-first workflow before runtime semantics are stable

---

## Proposed Tool

Add a built-in tool named `ask_parent`.

This tool should only be available inside subagent sessions that were launched with a live parent context. It should not be part of the default global tool set for normal top-level sessions.

### Parameters

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "Concrete question for the parent."
    },
    "why_blocked": {
      "type": "string",
      "description": "Why the subagent cannot safely proceed without input."
    },
    "options": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Optional mutually exclusive choices the parent can pick from."
    },
    "recommended_option": {
      "type": "string",
      "description": "Optional recommended option from the child."
    },
    "can_continue_without_answer": {
      "type": "boolean",
      "description": "Whether the child may continue with a fallback if the parent does not answer."
    },
    "fallback": {
      "type": "string",
      "description": "What the child will do if the timeout is reached and continuation is allowed."
    },
    "timeout_ms": {
      "type": "integer",
      "description": "How long to wait for the parent answer before timing out."
    }
  },
  "required": ["question", "why_blocked"]
}
```

### Tool result

The tool should return a normal tool result whose visible text is short and operational:

```text
Parent question submitted as request <request_id>. Waiting for answer.
```

`details` should include:

- `request_id`
- `status`
- `parent_run_id`
- `child_run_id`
- `task_id`
- `timed_out`
- `answered`

---

## Runtime Model

### High-level flow

1. A child session calls `ask_parent`.
2. Lemon validates that the session has a live parent context and no open parent-question request for the same child run.
3. Lemon persists a parent-question request record.
4. Lemon emits `:parent_question_requested` to child and parent run topics and records introspection.
5. Lemon sends a structured follow-up message into the parent session.
6. The child blocks waiting for an answer or timeout.
7. The parent answers through a resolver path.
8. Lemon persists the answer, emits `:parent_question_answered`, and wakes the waiting `ask_parent` tool execution.
9. The `ask_parent` tool returns the parent answer as a normal tool result and the child continues.

### Why the answer returns as a tool result

The simplest Phase 1 path is to have `ask_parent` wait and then return the answer as its own tool result:

- the child run is preserved
- the parent answer becomes explicit tool-result context for the child model
- no separate child resume protocol is needed
- the mechanism works for both sync and async child sessions

The returned tool text should be explicit and machine-friendly, for example:

```text
Parent answer for request <request_id>:

Answer: Keep the current session model.
Rationale: Avoid widening the auth surface in this change.
```

---

## New Persistent State

Add a new store module, likely `CodingAgent.ParentQuestions`, modeled after `CodingAgent.TaskStore`.

### Record shape

```elixir
%{
  id: request_id,
  status: :waiting | :answered | :timed_out | :cancelled | :error,
  inserted_at: integer(),
  updated_at: integer(),
  parent_run_id: String.t(),
  child_run_id: String.t(),
  task_id: String.t() | nil,
  parent_session_key: String.t() | nil,
  parent_agent_id: String.t() | nil,
  child_session_id: String.t() | nil,
  child_session_pid: pid() | nil,
  question: String.t(),
  why_blocked: String.t(),
  options: [String.t()],
  recommended_option: String.t() | nil,
  can_continue_without_answer: boolean(),
  fallback: String.t() | nil,
  timeout_ms: non_neg_integer() | nil,
  answer: String.t() | nil,
  answered_at: integer() | nil,
  meta: map()
}
```

Events should be bounded the same way `TaskStore` events are bounded.

### Why a dedicated store

This feature has state distinct from task completion:

- open request lifecycle
- answer payload
- timeout and resume semantics
- one-open-question-per-child-run enforcement

Overloading `TaskStore` would make polling and retention behavior harder to reason about.

---

## Parent-Side Delivery

Phase 1 should deliver the question into the parent using the existing live-session path.

### Parent delivery format

Use `CodingAgent.Session.follow_up/2` on the parent session with a stable, structured message:

```text
[subagent question <request_id>]
Child task: <description>
Blocked because: <why_blocked>
Question: <question>
Options:
- ...
Recommended: <recommended_option>

Use the `parent_question` tool to resolve request <request_id>.
```

This keeps the existing parent experience intact while preserving enough structure for future UI or control-plane affordances.

### Resolver path

Phase 1 should expose a minimal parent-facing tool:

- `parent_question` with `action="list"` and `action="answer"`

Under the hood that tool resolves requests through:

- `CodingAgent.ParentQuestions.answer(request_id, answer_text, opts \\ [])`

Useful future surfaces:

- control-plane RPC method for resolving a request
- TUI/web affordance for answering from a request list

---

## Child-Side Waiting Semantics

The `ask_parent` tool itself should block until one of these occurs:

- parent answer received
- timeout reached and `can_continue_without_answer == true`
- timeout reached and continuation is not allowed
- parent session disappears or cannot be reached

### Success path

If answered:

- mark request `:answered`
- return an `AgentToolResult` containing the parent answer so the tool call is part of normal child history

### Timeout path

If timed out and continuation is allowed:

- mark request `:timed_out`
- return a non-error tool result with `status: "timed_out"`

If timed out and continuation is not allowed:

- mark request `:timed_out`
- return an error result so the child can surface the block clearly

### Parent unavailable

If parent session context is missing or dead:

- do not silently downgrade to best effort
- fail immediately with an explicit error

This should remain a true escalation primitive, not hidden retry behavior.

---

## Event Model

Add new lifecycle events parallel to existing task lifecycle events.

### Proposed event types

- `:parent_question_requested`
- `:parent_question_answered`
- `:parent_question_timed_out`
- `:parent_question_cancelled`
- `:parent_question_error`

### Event payload base

```elixir
%{
  request_id: request_id,
  parent_run_id: parent_run_id,
  child_run_id: child_run_id,
  task_id: task_id,
  session_key: parent_session_key,
  agent_id: parent_agent_id,
  question: question,
  why_blocked: why_blocked,
  options: options,
  recommended_option: recommended_option,
  can_continue_without_answer: can_continue_without_answer,
  timeout_ms: timeout_ms,
  meta: meta
}
```

Broadcast strategy should mirror task lifecycle broadcasting:

- `run:<child_run_id>`
- `run:<parent_run_id>` when different

Introspection should also capture these events with `run_id`, `parent_run_id`, `session_key`, and `agent_id`.

---

## Tool Availability

`ask_parent` should not be universally registered.

Phase 1 availability rule:

- inject as an `extra_tool` only when `CodingAgent.Tools.Task` launches an internal child session
- require `parent_run_id`
- require live parent session context
- require a parent session module that exports `follow_up/2`

The parent-side resolver tool can live in the default toolset because it is inert unless there are open requests for the current session.

This is the smallest safe scope and fits the existing `extra_tools` path already supported by `CodingAgent.Session`.

### Concrete injection point

The natural place to add the tool is during child session option construction in:

- `CodingAgent.Tools.Task.Params.build_session_opts/3`

That function already composes child-specific session options and can append `extra_tools` for child runs.

---

## API Sketch

### New store module

```elixir
defmodule CodingAgent.ParentQuestions do
  @spec new_request(map()) :: String.t()
  @spec get(String.t()) :: {:ok, map(), [term()]} | {:error, :not_found}
  @spec append_event(String.t(), term()) :: :ok
  @spec mark_answered(String.t(), String.t(), map()) :: :ok
  @spec mark_timed_out(String.t()) :: :ok
  @spec mark_cancelled(String.t(), term()) :: :ok
  @spec open_request_for_child_run(String.t()) :: {:ok, map()} | {:error, :not_found}
  @spec answer(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
end
```

### New tool

```elixir
defmodule CodingAgent.Tools.AskParent do
  @spec tool(String.t(), keyword()) :: AgentCore.Types.AgentTool.t()
end
```

### New runtime helper

```elixir
defmodule CodingAgent.ParentQuestionCoordinator do
  @spec request(map(), keyword()) :: AgentCore.Types.AgentToolResult.t() | {:error, term()}
  @spec answer(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
end
```

The coordinator layer is optional but likely useful for keeping store, bus, and session interactions out of the raw tool module.

---

## Suggested Phase 1 Implementation Steps

1. Add `CodingAgent.ParentQuestions` plus its owning server if separate ETS/DETS ownership is needed.
2. Add lifecycle event emission helpers parallel to `CodingAgent.Tools.Task.Async`.
3. Add `CodingAgent.Tools.AskParent`.
4. Inject the tool into eligible internal child sessions using `extra_tools`.
5. Add internal answer API.
6. Wire answer handling to `Session.steer/2` for the child.
7. Add tests for request, answer, timeout, and missing-parent behavior.
8. Add control-plane/UI affordances only after runtime semantics are stable.

---

## Guardrails

The design only works if the feature stays narrow.

### Required guardrails

- one open parent-question request per child run
- reject duplicate or near-duplicate open questions from the same child
- timeout required or defaulted
- no generic free-form conversation primitive
- no sibling-to-sibling communication path
- parent answers are text decisions, not executable actions
- every request and answer emits telemetry and introspection

### Prompt guidance

The tool description should instruct the model to use `ask_parent` only when:

- a product or architectural decision is needed
- the child lacks authority to choose between options
- continuing without a decision would likely cause rework or correctness risk

The tool description should explicitly discourage use for:

- exploratory file discovery
- routine implementation choices
- status updates
- narrative discussion

---

## Failure Modes and Recovery

### Child asks too often

Risk:

- models may overuse the tool and collapse parallelism

Mitigation:

- strong tool description
- one-open-question limit
- follow-up evals that penalize unnecessary escalation

### Parent never answers

Risk:

- child hangs indefinitely

Mitigation:

- explicit timeout
- optional fallback
- timeout event emission

### Parent dies mid-request

Risk:

- request is left in limbo

Mitigation:

- monitor parent session pid when available
- convert to `:error` or `:timed_out` instead of waiting forever

### Child session dies before answer arrives

Risk:

- late answer cannot be delivered

Mitigation:

- mark request cancelled or errored
- retain record for diagnosis

---

## Testing Plan

Add tests for at least the following:

- child creates a request and parent receives it
- parent answer resumes the same child run
- timeout with `can_continue_without_answer: true`
- timeout with `can_continue_without_answer: false`
- missing parent context
- parent session exits before answering
- duplicate open question rejection
- event broadcast to both child and parent run topics
- introspection records for request and answer
- tool is absent from top-level sessions and present only in eligible child sessions

Likely test areas:

- `apps/coding_agent/test/coding_agent/tools/`
- `apps/coding_agent/test/coding_agent/subagent_integration_test.exs`
- `apps/coding_agent/test/coding_agent/tools/task_async_test.exs`
- `apps/coding_agent/test/coding_agent/introspection_test.exs`

---

## Open Questions

These questions should not block Phase 1:

- Should the parent resolve requests through a dedicated tool, a control-plane method, or both?
- Should a child be able to continue doing local analysis while waiting, or should `ask_parent` always be a hard block?
- Should parent-question requests appear in `TaskStore` summaries, or remain a separate view?
- Do we want router-mediated delivery for non-live parent sessions in a later phase?

---

## Recommended Phase 1 Decision

Implement `ask_parent` as a subagent-only extra tool for internal `task` sessions, backed by a dedicated `ParentQuestions` store and resolved by returning the parent answer as the `ask_parent` tool result after the parent answers through `parent_question`.

This uses Lemon's current architecture well:

- existing lineage from `RunGraph`
- existing live messaging from `Session.follow_up/2`
- existing task lifecycle broadcasting patterns
- existing child-only tool injection through `extra_tools`

It adds the missing reverse escalation path without turning subagents into general-purpose chat participants.
