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
