# LemonRouter - Agent Context

## Quick Orientation

`lemon_router` owns conversation semantics.
It turns normalized inbound requests into active runs, keeps one coordinator per conversation key, and emits semantic delivery intents for `lemon_channels`.

It does:

- normalize `LemonCore.RunRequest`
- build router-owned `%LemonRouter.Submission{}` values that wrap gateway `%LemonGateway.ExecutionRequest{}`
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
| `lib/lemon_router/run_starter.ex` | shared child-start mechanics for prepared router submissions |
| `lib/lemon_router/conversation_key.ex` | canonical conversation-key selection |
| `lib/lemon_router/resume_resolver.ex` | structured resume resolution before gateway submission |
| `lib/lemon_router/run_process.ex` | active-run lifecycle shell |
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

Async task/delegated followups are special:
- active auto-followups should prefer `:steer` with `:followup` fallback, not `:steer_backlog` with `:collect` fallback
- async followups with task/delegated provenance must not be merged together during the followup debounce window

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

If the change is semantic, start with `LemonRouter.SurfaceManager`,
`RunProcess.ArtifactTracker`, and the router coalescers.
If the change is platform UX, change `lemon_channels` renderers instead.
`ToolStatusRenderer` may use parent-child metadata already present in action `detail`
such as Claude's `parent_tool_use_id`; preserve that metadata in upstream runners instead
of re-deriving hierarchy in channel adapters.
`ToolStatusCoalescer` also expands embedded subagent progress from
`detail.partial_result.details.current_action` into child actions so task-tool updates can show
inner CLI steps over Telegram and similar channels.
When a tool phase starts immediately after streamed assistant text, `SurfaceManager`
hands the finalized `:answer` message over to the tool-status surface so the next status edits
append under that assistant text instead of reusing an older standalone status message.
`ToolStatusCoalescer` then prefixes the rendered status block with that text until the next
assistant delta starts, at which point the segment is finalized in place and reset.
After `StreamCoalescer` emits `:stream_finalize`, it must not emit any later
`:stream_snapshot` for the same finalized answer; late flushes should discard
buffered answer text instead of overwriting multi-chunk final output with a
truncated snapshot.
If `StreamCoalescer.finalize_run/4` exits or times out, `SurfaceManager.finalize_answer/3`
must fall back to a direct `:final_text` dispatch so the final answer is not lost behind
the last snapshot.
For runs that already streamed answer deltas, `SurfaceManager.finalize_answer/3` should dispatch
the direct `:stream_finalize` answer intent first and then finalize the coalescer state, because
channels key their answer surface by `{route, run_id, :answer}` and the streamed-final path is the
reliable way to update the existing streamed message in place.
Completion-time artifact enrichment must never block answer finalization; if
`RunProcess.ArtifactTracker.finalize_meta/1` fails, `RunProcess` should log and continue with empty
final-answer metadata rather than letting `terminate/2` flush a stale snapshot.
Task roots use dedicated status surfaces keyed by task id, so child actions with
`detail.parent_tool_use_id` keep editing the parent task message even after later assistant text
or unrelated top-level tool calls create newer answer/status turns.
Async task followups (`task action=poll`) are also rebound onto the original task surface by
`task_id` when `SurfaceManager` preserves that metadata in action `detail.result_meta`, so
background Codex/Claude task progress stays attached to the originating `task(...)` line instead
of creating blank standalone `task:` status entries.
Generated images and explicit file-send requests are tracked in
`RunProcess.ArtifactTracker`; channels still receive them only through
`auto_send_files` metadata on the answer finalization path.
The router tool-status coalescer no longer drops older actions after a fixed count;
it keeps the full in-memory action order and leaves presentation budgeting to
the renderer/channel layer.
Aborted runs that never bind to a live gateway run must still synthesize `:run_completed`; otherwise
`SessionCoordinator` will retain the session as busy forever.
Started runs that lose their gateway process before the router binds a monitor must also synthesize
`:run_completed`, but only after a short completion grace window so a real late `:run_completed`
from the bus can win over the synthetic fallback.
Run idle watchdog timeouts can be disabled by setting the resolved timeout to `0`
(for example in tests or local long-running task flows), which leaves runs alive until
the gateway or user explicitly ends them.

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
