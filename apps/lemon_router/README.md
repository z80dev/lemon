# LemonRouter

`lemon_router` owns request normalization, conversation identity, queue semantics, and semantic output tracking.
It sits between channel transports and `lemon_gateway`.

## Current Flow

```text
Channel transport or gateway-native ingress
  -> LemonRouter.Router.handle_inbound/1
  -> LemonRouter.RunOrchestrator
  -> LemonRouter.SessionCoordinator
  -> LemonRouter.RunProcess
  -> LemonGateway.Runtime.submit_execution/1
  -> LemonGateway.Scheduler / ThreadWorker / Run
  -> LemonCore.Bus run events
  -> LemonRouter semantic coalescers / output tracking
  -> LemonCore.DeliveryIntent
  -> LemonChannels.Dispatcher
  -> channel-specific renderer / outbox
```

## Ownership

- Router owns:
  - `RunRequest` normalization
  - policy, model, and engine resolution
  - resume resolution and conversation-key selection
  - queue semantics: `collect`, `followup`, `steer`, `steer_backlog`, `interrupt`
  - pending-compaction prompt rewriting
  - semantic stream and tool-status coalescing
- Router does not own:
  - Telegram or Discord rendering details
  - `OutboundPayload` construction
  - Telegram message-id presentation state
  - gateway slot scheduling or engine lifecycle

## Key Modules

| Module | Responsibility |
| --- | --- |
| `LemonRouter.Router` | Main inbound entrypoint, session-key resolution, pending-compaction application, control-plane abort/keepalive hooks |
| `LemonRouter.RunOrchestrator` | Builds router-owned submissions from `LemonCore.RunRequest` and hands them to `SessionCoordinator` |
| `LemonRouter.SessionCoordinator` | Single owner of per-conversation queue semantics and active-run handoff |
| Router internal session read model | Internal read model over coordinator-owned active session state |
| `LemonRouter.ConversationKey` | Canonical conversation-key selection from structured resume or session key |
| `LemonRouter.ResumeResolver` | Structured resume resolution before gateway submission |
| `LemonRouter.RunProcess` | Active-run lifecycle wrapper around one execution |
| `LemonRouter.StreamCoalescer` | Semantic answer coalescing that emits `DeliveryIntent` snapshots/finalization |
| `LemonRouter.ToolStatusCoalescer` | Semantic tool-status coalescing that emits `DeliveryIntent` snapshots/finalization |
| `LemonRouter.PendingCompactionStore` | Router-owned typed wrapper for pending-compaction markers |
| `LemonRouter.AgentEndpointStore` | Router-owned typed wrapper for persistent endpoint aliases |
| `LemonRouter.AgentInbox` | BEAM-local send API with selectors, fanout, and queue-mode selection |
| `LemonRouter.AgentDirectory` | Active/durable session discovery |
| `LemonRouter.AgentEndpoints` | Persistent route aliases |

## Important Contracts

- Inbound callers should provide structured resume data through `LemonCore.RunRequest.resume` when they already know it.
- Engine ID validation and normalization should use `LemonCore.EngineCatalog`; default cwd resolution should use `LemonCore.Cwd`.
- Router emits `LemonCore.DeliveryIntent`, not `LemonChannels.OutboundPayload`.
- Gateway input is `LemonGateway.ExecutionRequest`, not `LemonGateway.Types.Job`.
- Telegram-specific state is owned by `lemon_channels` wrappers:
  - `LemonChannels.Telegram.StateStore`
  - `LemonChannels.Telegram.ResumeIndexStore`
- External apps must query busy/active session state through `LemonRouter.Router` or `LemonCore.RouterBridge`, not router-internal read-model or registry details.

## Session And Queue Semantics

`SessionCoordinator` serializes by conversation key:

- `{:resume, engine, token}` when a structured resume token is available
- `{:session, session_key}` otherwise

Queue-mode behavior lives here:

- `:collect` appends
- `:followup` debounces/merges recent followups, except async task/delegated followups which stay separate
- `:steer` attempts in-run steer and falls back to followup
- `:steer_backlog` attempts in-run steer and falls back to collect
- active async task/delegated auto-followups are promoted to `:steer` so completions try to reach the live parent run before falling back to a queued followup
- `:interrupt` cancels the active run and inserts the new request at the front

## Output Semantics

Router coalescers only track semantic state:

- accumulated text
- sequence numbers
- semantic tool/action state
- run/session metadata needed for `DeliveryIntent`

Channels decides:

- send vs edit
- truncation
- reply markup
- media batching
- Telegram resume indexing by platform message id

## Testing

Run the app suite from the umbrella root:

```bash
mix test apps/lemon_router
```

Useful focused suites during refactors:

```bash
mix test apps/lemon_router/test/lemon_router/router_test.exs
mix test apps/lemon_router/test/lemon_router/run_orchestrator_test.exs
mix test apps/lemon_router/test/lemon_router/session_coordinator_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/lemon_router/test/lemon_router/stream_coalescer_test.exs
mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
```

Run architecture checks after boundary changes:

```bash
mix lemon.quality
```
