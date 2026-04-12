# Subagent Reasoning Surfacing Plan

Status: proposed

Last reviewed: 2026-04-12

## Summary

Lemon already captures some subagent reasoning upstream, but it does not treat that data as a first-class surfaced signal through the `task` and delegated-subagent pipeline.

Today:

- external runners such as Codex, Claude, and Droid normalize reasoning/thinking as CLI `:note` actions
- router task/tool status drops `:note` actions entirely
- `task` child-run projection only forwards `current_action`, not reasoning
- internal `task` runs can emit `[thinking] ...` text in partial updates, but task result/poll paths strip that back out
- monitoring APIs persist generic task events, but there is no stable reasoning field for clients to render

The result is uneven behavior:

- top-level assistant messages can expose thinking blocks in web/TUI
- subagent tool progress is visible on the parent task surface
- subagent reasoning is mostly lost, or only available indirectly through raw event blobs

This plan adds a bounded, explicit reasoning path for subagents and tasks.

## Goals

- Surface subagent reasoning in operator-facing surfaces with the same reliability as subagent tool progress.
- Preserve reasoning across the `task` pipeline: runner -> task update -> projection -> router surface -> monitoring API.
- Keep reasoning inspectable after the run through monitoring/task APIs.
- Avoid dumping raw reasoning into noisy chat transports by default.
- Reuse existing parent/child task-surface plumbing instead of inventing a second hierarchy mechanism.

## Non-Goals

- Do not expose unlimited raw chain-of-thought in all user-facing channels.
- Do not rewrite provider-native assistant thinking semantics for top-level chat messages.
- Do not block this work on a general-purpose trace store.
- Do not conflate reasoning with normal tool actions in ways that break existing tool-status rendering.

## Current State

### What exists already

1. External runner normalization:
   - Codex runner emits reasoning as `:note` action events.
   - Claude runner emits thinking blocks as completed `:note` actions.
   - Droid runner emits reasoning events as started/updated/completed `:note` actions.

2. Internal task updates:
   - internal `task` sessions emit `AgentToolResult` updates
   - updates can include `details.current_action`
   - internal assistant thinking is available through `Ai.get_thinking/1`

3. Task persistence:
   - async task records live in `CodingAgent.TaskStore`
   - recent task events are already persisted in bounded form

4. Parent task rebinding:
   - child task progress can be rebound onto the parent task line through `parent_tool_use_id`
   - router already renders nested child actions on dedicated task surfaces

### Where reasoning is lost

1. Router drop on ingest:
   - `LemonRouter.ToolStatusCoalescer.normalize_action_event/1` skips `kind in ["note", :note]`
   - this discards reasoning from Codex/Claude/Droid before any surface can render it

2. Missing projection path:
   - `CodingAgent.Tools.Task.Projection.engine_action_from_update/2` only projects `details.current_action`
   - there is no sibling projection for `details.reasoning` or equivalent metadata

3. Internal task reasoning is flattened:
   - `CodingAgent.Tools.Task.Result.build_update_content/2` emits reasoning as `[thinking] ...` text
   - `visible_content_text/1` strips `[thinking]` markers for previews and poll/get output
   - reasoning therefore survives as transient text but not as structured task state

4. Monitoring shape is too generic:
   - `tasks.active.list` / `tasks.recent.list` expose `events` and `record`, but no stable reasoning summary fields
   - clients would need to scrape raw event blobs

5. Delegated `agent` path is coarse:
   - `CodingAgent.Tools.Agent` persists queue/running/completion state
   - it does not project inner reasoning/tool progress onto parent surfaces the way `task` does

## Desired Semantics

Treat subagent reasoning as a first-class signal with two visibility levels:

1. Live reasoning status
   - bounded
   - incremental
   - optimized for operators
   - shown in web/TUI/monitoring
   - optionally suppressed on chat transports such as Telegram/WhatsApp

2. Persisted reasoning trace
   - bounded per task/run
   - inspectable after completion
   - available through monitoring/task APIs
   - not auto-inlined into normal completion followups

## Proposed Data Model

Add explicit reasoning metadata to task/subagent updates instead of encoding it as only free text.

### Task update details

Extend `AgentToolResult.details` for task/subagent updates with:

```elixir
%{
  engine: "codex" | "claude" | "internal" | ...,
  current_action: %{
    title: "...",
    kind: "tool" | "command" | "file_change" | "web_search" | "subagent",
    phase: "started" | "updated" | "completed"
  },
  action_detail: %{...},
  reasoning: %{
    text: "...",
    phase: "started" | "updated" | "completed",
    source: "runner_note" | "assistant_thinking",
    signature: "...optional...",
    truncated: true | false
  }
}
```

Notes:

- `reasoning.text` should be bounded aggressively.
- `source` distinguishes runner-native note reasoning from internal assistant thinking.
- `signature` is optional and only forwarded when already available upstream.

### TaskStore derived summary fields

Expose these as stable summary fields in task details and monitoring payloads:

- `latest_reasoning`
- `latest_reasoning_phase`
- `latest_reasoning_source`
- `reasoning_count`
- `current_action`

`events` remains the raw escape hatch, but clients should not need to scrape it for the common case.

## Proposed Event Model

### Option A: keep reasoning as `:note`, but stop dropping it

Pros:

- minimal runner churn
- preserves existing runner semantics

Cons:

- router/status code must now understand that some `:note` values are reasoning, others may be warnings or miscellaneous notes

### Option B: introduce explicit reasoning action kind

Pros:

- cleaner downstream semantics
- avoids overloading `:note`

Cons:

- requires updates across runner schemas, runner translation, router normalization, and renderers

### Recommendation

Use a staged approach:

1. Phase 1:
   - keep upstream runner output as `:note`
   - introduce structured `details.reasoning` for task/subagent updates
   - continue to ignore generic unrelated notes in router status

2. Phase 2:
   - if needed, add an explicit normalized `:reasoning` or `"reasoning"` kind at the router layer only
   - avoid forcing all runner APIs to change immediately

This keeps the first implementation small and reversible.

## Proposed Pipeline Changes

### Phase 1: Structured reasoning in `task` updates

Files:

- `apps/coding_agent/lib/coding_agent/tools/task/runner.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`

Changes:

1. Internal task runs:
   - when `maybe_emit_update/8` sees assistant thinking, emit structured `details.reasoning`
   - keep the current text content behavior for compatibility, but stop relying on text markers as the only representation

2. CLI task runs:
   - update `reduce_cli_events/5` so `:note` events from Codex/Claude/Droid are turned into structured `details.reasoning`
   - keep `current_action` unchanged for tool progress
   - for CLI engines, use `source: "runner_note"`

3. Final payloads:
   - extend task result details to include latest reasoning summary, not just visible text

### Phase 2: Project child reasoning onto parent task surfaces

Files:

- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/projection.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`

Changes:

1. Add a sibling projection path to `engine_action_from_update/2`:
   - `reasoning_action_from_update/2` or a unified projection that can emit both action and reasoning payloads

2. Preserve child reasoning identity:
   - stable child reasoning ids
   - same parent binding fields as projected child actions:
     - `parent_tool_use_id`
     - `task_id`
     - `child_run_id`
     - `projected_from: :child_run`

3. Broadcast projected reasoning through the same parent-run bus path used for child actions.

Recommendation:

- keep reasoning projection payloads shaped like action payloads to minimize router churn
- add `detail.reasoning_text` and `detail.reasoning_source`
- use a distinct `kind` at the router layer such as `"reasoning"` even if upstream source remained `:note`

## Router Changes

Files:

- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_renderer.ex`
- `apps/lemon_router/lib/lemon_router/surface_manager.ex`

Changes:

1. Coalescer ingestion:
   - stop dropping projected reasoning events
   - continue to drop generic notes that are not tagged as reasoning

2. Embedded child extraction:
   - current embedded-child expansion only understands `current_action` and `action_detail`
   - extend it to read `result_meta.reasoning` / `partial_result.details.reasoning`

3. Rendering:
   - render reasoning lines with a distinct marker, for example:
     - `… reasoning: considering router fallback`
   - preserve nesting by `parent_tool_use_id`
   - keep tool/action lines visually distinct from reasoning lines

4. Surface policy:
   - web/discord/operator channels: render reasoning by default
   - telegram/whatsapp: suppress by default or cap at 1 latest line

Recommendation:

- add a transport-aware option in coalescer/render opts such as `show_reasoning?: boolean`
- default false for narrow chat transports, true for operator surfaces

## Persistence And API Changes

Files:

- `apps/coding_agent/lib/coding_agent/task_store.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/tasks_active_list.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/tasks_recent_list.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/event_bridge.ex`

Changes:

1. TaskStore:
   - no schema migration is required because records/events are maps
   - continue bounded event retention
   - ensure reasoning updates are appended as structured events

2. Poll/get/join:
   - include latest reasoning summary in `details`
   - do not require clients to parse `[thinking]` text

3. Monitoring list endpoints:
   - add stable fields on each returned task:
     - `latestReasoning`
     - `latestReasoningPhase`
     - `latestReasoningSource`
     - `reasoningCount`
     - `currentAction`
   - keep `events` behind `includeEvents`

4. Event bridge:
   - optional follow-on work: add `task.reasoning` event if live monitoring needs reasoning updates without full list refresh
   - not required for the first pass if clients already refresh task lists aggressively enough

## UI Changes

### Web Monitoring

Files:

- `clients/lemon-web/shared/src/monitoringTypes.ts`
- `clients/lemon-web/web/src/store/monitoringReducers.ts`
- `clients/lemon-web/web/src/components/monitoring/TaskInspector.tsx`
- `clients/lemon-web/web/src/components/monitoring/RunInspector.tsx`

Changes:

1. Extend `MonitoringTask` with first-class reasoning summary fields.
2. Task tree row:
   - show a short latest reasoning snippet for active tasks
3. Task inspector details:
   - add collapsible `Reasoning` section
   - show latest reasoning summary and raw reasoning events when available
4. Run inspector:
   - separate `Tool Calls` from `Tasks`
   - optionally add `Reasoning` summary under each task, instead of burying it in raw JSON

### Web Session UI

Files:

- `clients/lemon-web/web/src/store/sessionEventReducer.ts`
- `clients/lemon-web/web/src/components/ToolTimeline.tsx`

Changes:

1. Parse `task` partial/result reasoning fields the same way TUI currently parses `current_action`.
2. Show task reasoning in tool timeline cards, not only raw `partial` JSON.

### TUI

Files:

- `clients/lemon-tui/src/state.ts`
- `clients/lemon-tui/src/formatters/task.ts`
- `clients/lemon-tui/src/ink/components/ToolPanel.tsx`

Changes:

1. Extend task parsing to capture structured reasoning fields.
2. Show latest reasoning snippet beneath current task action.
3. Keep the existing assistant-message thinking UI unchanged for top-level assistant blocks.

## Delegated `agent` Tool Follow-On

Files:

- `apps/coding_agent/lib/coding_agent/tools/agent.ex`

The delegated `agent` tool currently persists queue/running/completion state, but not inner projected progress. There are two possible directions:

1. Short-term:
   - leave `agent` coarse
   - document that rich nested progress/reasoning is supported by `task`

2. Follow-on:
   - add the same child binding / projected reasoning plumbing used by `task`
   - surface delegated-agent inner progress on parent surfaces

Recommendation:

- keep this out of the first implementation
- finish `task` first, then decide whether `agent` should converge on the same machinery

## Guardrails

Reasoning is high-volume and can be sensitive. Add explicit caps.

Recommended defaults:

- max reasoning chars per event: 240 to 400
- max persisted reasoning events per task: reuse `TaskStore` bounded event list, but only keep the latest few reasoning entries in derived summaries
- chat transport default: suppress reasoning unless explicitly enabled
- monitoring/web/TUI default: show bounded reasoning
- auto-followup completion text: never include reasoning by default

## Rollout Sequence

### PR 1: Structured task reasoning

- add `details.reasoning` to internal and CLI task updates
- add task result summary fields
- extend poll/get to expose latest reasoning
- add unit tests around `task` update/result shaping

### PR 2: Parent surface projection

- project child reasoning alongside child actions
- stop dropping projected reasoning in router coalescing
- render reasoning on task surfaces for non-chat channels
- add router integration tests for nested reasoning rendering

### PR 3: Monitoring and UI

- extend control-plane task list payloads
- add reasoning summary to monitoring reducers/types
- render reasoning in web monitoring and TUI task views

### PR 4: Transport policy and polish

- add config/policy switch for reasoning on status surfaces
- suppress or heavily truncate on Telegram/WhatsApp
- refine formatting and caps based on operator feedback

## Test Plan

### CodingAgent

- `apps/coding_agent/test/coding_agent/tools/task/*`
  - internal task emits structured reasoning
  - CLI task maps runner notes to reasoning details
  - poll/get surfaces latest reasoning
  - reasoning is bounded and does not disappear from structured details

### Router

- `apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`
  - projected reasoning is not dropped
  - generic unrelated notes are still suppressed

- `apps/lemon_router/test/lemon_router/tool_status_renderer_test.exs`
  - reasoning line formatting
  - nested reasoning indentation under parent task
  - channel-specific truncation/suppression

- `apps/lemon_router/test/lemon_router/run_process_test.exs`
  - child reasoning stays attached to the originating task surface

### Control Plane

- task list endpoint tests for reasoning summary fields

### Web/TUI

- formatter and reducer tests for structured reasoning parsing
- task inspector / tool timeline rendering tests

## Open Questions Evaluation

1. **Should reasoning be represented as a dedicated router action kind immediately, or only as enriched `detail` on the first pass?**
   - **Recommendation:** Only as enriched `detail` on the first pass.
   - **Reasoning:** `LemonRouter.ToolStatusCoalescer.normalize_action_event/1` (around line 431) uses a strict allowlist of kinds (`"tool"`, `"command"`, `"file_change"`, `"web_search"`, `"subagent"`). Adding a new `"reasoning"` kind requires updating this allowlist and handling it explicitly across `LemonRouter.ToolStatusRenderer.format_action_line/2` (around line 147). Passing it within `detail` keeps router changes limited to the existing embedded child extraction logic (`embedded_child_action/1`).

2. **Do we want a live `task.reasoning` event on the control-plane feed, or are list refreshes enough?**
   - **Recommendation:** List refreshes and existing tool status streams are enough for the first pass.
   - **Reasoning:** `LemonControlPlane.EventBridge` fans out events to WebSocket clients. Emitting a new event for every reasoning chunk would cause excessive WebSocket traffic for concurrent tasks. Relying on `tasks.active.list` (which already bounds events via `eventLimit`, see `LemonControlPlane.Methods.TasksActiveList.handle/2`) is safer for inspection, while live operator visibility relies on the existing `tool_status_snapshot` path.

3. **Should `agent` converge on the `task` projection stack, or remain intentionally coarse?**
   - **Recommendation:** Remain intentionally coarse for now.
   - **Reasoning:** The `agent` tool (`apps/coding_agent/lib/coding_agent/tools/agent.ex`, line 88) submits entirely separate `RunRequest`s that flow through `LemonRouter.SessionCoordinator`. It does not emit fine-grained parent-bound `AgentToolResult` updates like `task` does. Converging them requires cross-run projection plumbing that is much more complex than the local `task` projection.

4. **Should Discord-style channels show reasoning by default, or only operator UIs?**
   - **Recommendation:** Only operator UIs (TUI, Web).
   - **Reasoning:** Chat transports are already constrained by platform limits. For example, `LemonRouter.ToolStatusCoalescer.combine_prefix_and_status/2` (line 348) has to aggressively budget characters to avoid Telegram's 4096 max length. Adding verbose reasoning lines will rapidly push actionable tool progress out of the visible status block.

## Identified Risks and Missing Questions

- **Risk - TaskStore Bloat:** If `task` updates append every reasoning delta as a new event, `CodingAgent.TaskStore` memory usage will balloon. The plan mentions "bounded event retention," but we must specifically ensure `details.reasoning` replaces the previous reasoning state in the task record rather than appending hundreds of incremental events.
- **Risk - Coalescer Thrashing:** High-frequency reasoning updates (e.g. from internal models streaming thinking tokens) could trigger excessive `ToolStatusCoalescer` processing. The coalescer debounces flushes (via `@default_idle_ms 400`), but we should still limit how often runners push reasoning updates to the bus.
- **Missing Question:** How exactly should `LemonRouter.ToolStatusRenderer` format a reasoning line visually? `format_action_line/2` currently only handles `:started`, `:updated`, and `:completed` phases with specific symbols (`▸`, `✓`, `✗`). We need a distinct visual treatment (e.g., italicized text or a different symbol) so users don't confuse reasoning with actual tool execution.

## Recommended First Cut

Build the smallest coherent version:

1. add structured `details.reasoning` to task updates
2. persist and expose latest reasoning in task poll/get/list APIs
3. project child reasoning onto parent task surfaces
4. render reasoning only in web/TUI/monitoring by default
5. leave delegated `agent` unchanged for now

That gets reasoning visible where operators need it without forcing raw reasoning into every transport or requiring a broad runner rewrite.
