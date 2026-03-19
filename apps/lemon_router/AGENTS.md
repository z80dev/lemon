# LemonRouter - Agent Context

## Quick Orientation

`lemon_router` owns conversation semantics.
It turns normalized inbound requests into active runs, keeps one coordinator per conversation key, and emits semantic delivery intents for `lemon_channels`.

It does:

- normalize `LemonCore.RunRequest`
- resolve policy, model, engine, cwd, and structured resume
- choose conversation keys
- enforce queue semantics in `SessionCoordinator`
- manage active run lifecycle in `RunProcess`
- track pending compaction in router-owned storage
- coalesce semantic answer/tool-status output and dispatch `DeliveryIntent`

It does not:

- parse Telegram transport protocol details
- construct `LemonChannels.OutboundPayload`
- own Telegram message-id state or truncation rules
- own gateway slot allocation or engine lifecycle

## Core Flow

```text
Inbound transport
  -> Router.handle_inbound/1
  -> RunOrchestrator.submit/1
  -> SessionCoordinator.submit/3
  -> RunProcess
  -> LemonGateway.Runtime.submit_execution/1
  -> run events on LemonCore.Bus
  -> StreamCoalescer / ToolStatusCoalescer
  -> LemonCore.DeliveryIntent
  -> LemonChannels.Dispatcher
```

## Files To Read First

| File | Why it matters |
| --- | --- |
| `lib/lemon_router/router.ex` | inbound entrypoint, session-key resolution, pending-compaction rewrite path |
| `lib/lemon_router/run_orchestrator.ex` | request normalization and submission building |
| `lib/lemon_router/session_coordinator.ex` | queue semantics owner |
| `lib/lemon_router/conversation_key.ex` | canonical conversation-key selection |
| `lib/lemon_router/resume_resolver.ex` | structured resume resolution before gateway submission |
| `lib/lemon_router/run_process.ex` | active-run lifecycle shell |
| `lib/lemon_router/async_task_surface.ex` | router-owned async task surface lifecycle scaffold for the redesign |
| `lib/lemon_router/run_process/compaction_trigger.ex` | overflow detection and pending-compaction marking |
| `lib/lemon_router/stream_coalescer.ex` | semantic answer coalescing |
| `lib/lemon_router/tool_status_coalescer.ex` | semantic tool-status coalescing |
| `lib/lemon_router/pending_compaction_store.ex` | router-owned pending-compaction wrapper |

## Ownership Rules

- Router may reference `LemonChannels.Dispatcher`, but not `LemonChannels.OutboundPayload`.
- Router may emit `LemonCore.DeliveryIntent`, but channel renderers decide payload shape.
- Router owns pending-compaction prompt mutation.
- Router uses `PendingCompactionStore`; it must not touch Telegram message-index tables directly.
- Queue semantics belong in `SessionCoordinator`, not in gateway workers.
- External apps must use `LemonRouter.Router` or `LemonCore.RouterBridge` for busy/active session queries. Router-internal read-model and registry details are not public boundaries.

## Queue Semantics

`SessionCoordinator` owns:

- active run pointer per conversation key
- internal registry-backed read-model updates as an implementation detail
- pending queue/backlog
- followup merge/debounce
- steer and steer-backlog fallback
- interrupt behavior

Conversation keys are:

- `{:resume, engine, token}` when resume is known
- `{:session, session_key}` otherwise

## Delivery Semantics

Router output is semantic:

- `:stream_snapshot`
- `:stream_finalize`
- `:tool_status_snapshot`
- `:tool_status_finalize`
- `:final_text`
- `:file_batch`
- `:watchdog_prompt`

`lemon_channels` owns:

- send vs edit
- reply markup
- truncation
- Telegram resume indexing by message id
- platform presentation state

## Config Contract

- Default model and thinking level live in config (`[defaults]`) as defaults only.
- Current per-session/per-route/per-chat values are runtime policy/state managed by `LemonCore.PolicyStore`, not config.
- Direct `Application.get_env(:lemon_router, :default_model)`, `Application.get_env(:lemon_router, :agent_policies)`, and `Application.get_env(:lemon_router, :runtime_policy)` reads are forbidden in runtime modules. These values must come from config defaults or `PolicyStore`.
- Provider config resolution is centralized in `LemonCore.ProviderConfigResolver`.

## Stores

Use typed wrappers when you touch shared state:

- `LemonCore.ChatStateStore`
- `LemonCore.RunStore`
- `LemonCore.PolicyStore`
- `LemonCore.ProgressStore`
- `LemonRouter.AgentEndpointStore`
- `LemonRouter.PendingCompactionStore`

Telegram-specific router tests should assert against channels-owned wrappers:

- `LemonChannels.Telegram.StateStore`
- `LemonChannels.Telegram.ResumeIndexStore`

## Common Changes

### Add or change queue behavior

Start in `session_coordinator.ex`.
Do not add queue-mode branches to `lemon_gateway`.

### Change model or engine resolution

Start in `run_orchestrator.ex`, `resume_resolver.ex`, `model_selection.ex`, and `sticky_engine.ex`.
Use `LemonCore.EngineCatalog` for engine ID validation/normalization and `LemonCore.Cwd` for default cwd selection.

### Change output behavior

If the change is semantic, update router coalescers or `RunProcess.OutputTracker`.
If the change is platform UX, change `lemon_channels` renderers instead.
`ToolStatusRenderer` may use parent-child metadata already present in action `detail`
such as Claude's `parent_tool_use_id`; preserve that metadata in upstream runners instead
of re-deriving hierarchy in channel adapters.
`ToolStatusCoalescer` also expands embedded subagent progress from
`detail.partial_result.details.current_action` into child actions so task-tool updates can show
inner CLI steps over Telegram and similar channels.
When a tool phase starts immediately after streamed assistant text, `RunProcess.OutputTracker`
hands the finalized `:answer` message over to the tool-status surface so the next status edits
append under that assistant text instead of reusing an older standalone status message.
`ToolStatusCoalescer` then prefixes the rendered status block with that text until the next
assistant delta starts, at which point the segment is finalized in place and reset.
Task roots use dedicated status surfaces keyed by the task-root surface id, so child actions with
`detail.parent_tool_use_id` keep editing the parent task message even after later assistant text
or unrelated top-level tool calls create newer answer/status turns.
Async task followups (`task action=poll`) are also rebound onto the original task surface by
`task_id` when upstream runners preserve that metadata in action `detail`, `detail.args`, or
`detail.result_meta`, so
background Codex/Claude task progress stays attached to the originating `task(...)` line instead
of creating blank standalone `task:` status entries.
The redesign also has a router-owned `AsyncTaskSurface` process per surface/root key with
`pending_root -> bound -> live -> terminal_grace -> reaped` lifecycle semantics.
`RunProcess.OutputTracker` now seeds and reuses that router-owned identity from task-root start
events and task poll rebinding, but the existing LiveBridge / projected-child tool-status path
remains the active rendering behavior until later migration steps wire them together.
Explicit projected-child `surface` / `root_action_id` metadata must seed that reusable identity too,
and terminal task poll/result statuses drive `AsyncTaskSurface` to `:terminal_grace`; only a later
task-surface coalescer reap should advance an already-terminal surface to `:reaped`.
When an async task surface transitions to `:reaped`, it replies once with the terminal snapshot,
then drops its public registration before stopping so an immediate `ensure_started(surface_id)`
creates a fresh `:pending_root` surface instead of surfacing the stale pid; invalid surface
metadata now returns an explicit `{:invalid_metadata, ...}` error instead
of crashing the GenServer.
`AsyncTaskSurfaceSupervisor.ensure_started/2` must also treat
`DynamicSupervisor.start_child(...)= {:error, {:already_started, pid}}` as provisional during
that unregister-before-exit window: only a pid that is still registered for the surface and not
marked `:reaped` in the registry-owned public state is usable; stale reaping pids must be awaited
and retried until a fresh surface wins, but temporarily busy live surfaces must still be reused.
Repeated embedded-only `current_action` updates for the same parent/title reuse the same child row
until the embedded title changes, so repeated task polls do not duplicate inner status lines.
Projected child events may also carry explicit `surface` / `root_action_id` metadata; prefer that
binding when present instead of relying only on previously seen parent actions in the run process.
Task-scoped status coalescers are reaped after they go idle with no running task actions, so
per-task router processes do not accumulate indefinitely; later updates recreate the surface if
needed, but parent run finalization must not recreate a task surface that has already reaped, and
the run process now drops stale task-surface bindings as soon as that task coalescer exits.
Aborted runs that never bind to a live gateway run must still synthesize `:run_completed`; otherwise
`SessionCoordinator` will retain the session as busy forever.
Started runs that lose their gateway process before the router binds a monitor must also synthesize
`:run_completed`, but only after a short completion grace window so a real late `:run_completed`
from the bus can win over the synthetic fallback.
Watchdog keepalive prompts increment their semantic sequence on each idle cycle so repeated prompts
remain visible through channel renderer and outbox dedupe.

### Change compaction behavior

Update:

- `router.ex` for inbound prompt rewriting
- `run_process/compaction_trigger.ex` for marker creation and overflow handling
- `pending_compaction_store.ex` for storage access if needed

## Testing

Run:

```bash
mix test apps/lemon_router
```

Useful focused suites:

```bash
mix test apps/lemon_router/test/lemon_router/router_test.exs
mix test apps/lemon_router/test/lemon_router/run_orchestrator_test.exs
mix test apps/lemon_router/test/lemon_router/session_coordinator_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/lemon_router/test/lemon_router/stream_coalescer_test.exs
mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
```

After boundary changes:

```bash
mix lemon.quality
```
