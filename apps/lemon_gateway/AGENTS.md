# LemonGateway AGENTS.md

LemonGateway is Lemon's execution runtime. It handles concurrency-slot scheduling,
per-conversation launch isolation, run lifecycle, streaming bus events, cancellation,
and session resumption. Gateway-owned transport, SMS, voice, and command startup is
off by default and starts only when `:gateway_ingress_enabled` is set for
`:lemon_gateway`. Those ingress surfaces are gateway-owned by design; see
`docs/platform/transport-unification.md`.

## Executor Contract

Gateway has one configured singleton executor: `CodingAgent.Executor`. It is selected
through `:lemon_gateway, :executor`; `LemonGateway.Executor` validates its readiness
at startup and before runtime submission. Every gateway run uses that executor and has
the fixed top-level provenance `engine: "lemon"`. Delegated task records retain their
own subagent identity; neither provenance field selects Gateway execution.

This is an intentional breaking removal of the old Gateway engine platform:

- Do not add `LemonGateway.Engine`, `EngineRegistry`, `EngineCase`, `Echo`, gateway
  engine shells, or engine-registration code.
- Do not add `engine`, `default_engine`, `engine_preference`, or
  `[gateway.engines.<id>]` configuration. Gateway configuration cannot select a
  different executor.
- `EngineInfoBridge` retains only its transport-registry and gateway-config
  capabilities. It no longer exposes Gateway engine enumeration.
- `LemonCore.ResumeToken` remains the shared resume-token
  mechanism for the native executor and delegated tasks.

### Migration choices

Choose the extension boundary that matches the work rather than restoring a top-level
Gateway engine:

| Need | Use |
| --- | --- |
| Connect a model/API to an agent | a `LemonAi` provider |
| Add in-process agent capability | a `CodingAgent` tool |
| Delegate bounded work to a subagent | the native `task`/`agent` tools (in-process `CodingAgent.Session`) |

Subagents are native in-process `CodingAgent.Session` executions coordinated by
`CodingAgent.Coordinator`; they never select or replace the Gateway executor.
There are no vendor CLI task runners.

## Quick Orientation

**Entry point:** `LemonGateway.Runtime.submit_execution(%LemonCore.ExecutionCommand{})`.
The removed `LemonGateway.Runtime.submit/1` compatibility path must not return.

**Core loop:**

```
Router -> LemonCore.ExecutionCommand -> Runtime -> ExecutionRequest
       -> Scheduler -> ThreadWorker -> Run -> configured Executor -> bus events
```

Gateway owns slot allocation, worker/process lifecycle, and safety rails.
`ThreadWorker` is a dumb per-conversation launcher; `EngineLock` is
failure-isolation defense in depth, not product queue semantics.
Scheduler slot requests from `ThreadWorker` carry a generation token, so timeout
retries cancel the previous generation before requesting another slot. Run-start
attempts remain bounded across slot grants; permanently unstartable requests emit
one structured terminal completion and are removed before the worker advances.
`EngineLock` may transfer ownership on explicit release or confirmed owner death,
never merely because a live owner is older than the configured observation threshold.

### Execution flow

1. Router-owned `SessionCoordinator` decides collect/followup/steer/interrupt
   semantics and submits queue-semantic-free execution commands.
2. `Runtime` creates a gateway-private `ExecutionRequest`.
3. `Scheduler` routes the request by the router-supplied conversation key and grants
   a concurrency slot.
4. `ThreadWorker` starts a `Run` through `RunSupervisor`.
5. `Run` acquires `EngineLock`, invokes the configured `LemonGateway.Executor`, and
   broadcasts native-executor events and deltas on `LemonCore.Bus("run:<run_id>")`.
6. On completion, `Run` stores resume state, releases the lock and slot, and notifies
   the router-facing observers.

## Key Files

### Execution pipeline

| File | Module | Responsibility |
| --- | --- | --- |
| `lib/lemon_gateway.ex` | `LemonGateway` | Public execution submission and health facade |
| `lib/lemon_gateway/runtime.ex` | `Runtime` | Implements `LemonCore.EngineRuntime`; submission, cancellation, and lookup |
| `lib/lemon_gateway/executor.ex` | `Executor` | Singleton executor boundary and readiness validation |
| `lib/lemon_gateway/execution_request.ex` | `ExecutionRequest` | Gateway-private request with no queue-mode semantics |
| `lib/lemon_gateway/scheduler.ex` | `Scheduler` | Slot allocator and thread routing |
| `lib/lemon_gateway/thread_worker.ex` | `ThreadWorker` | Per-conversation slot waiter and launcher |
| `lib/lemon_gateway/run.ex` | `Run` | Executor lifecycle, bus events, steering, cancellation, and locks |
| `lib/lemon_gateway/engine_lock.ex` | `EngineLock` | Per-session mutex with FIFO wait queue, owner-death release, and over-age live-owner telemetry |
| `lib/lemon_gateway/event.ex` | `Event`, `Event.Delta` | Lifecycle-event constructors and streamed delta struct |

### Configuration and ingress

Gateway config comes from the canonical TOML `[gateway]` section through
`LemonCore.GatewayConfig`; transport config is read only from that path. The
`LemonGateway.Config` application override is test-only. The executor module belongs
to application configuration, not TOML engine selection.

| File | Module | Responsibility |
| --- | --- | --- |
| `lib/lemon_gateway/config.ex` | `Config` | Typed runtime configuration access |
| `lib/lemon_gateway/config_loader.ex` | `ConfigLoader` | Canonical TOML loading and parsing |
| `lib/lemon_gateway/binding_resolver.ex` | `BindingResolver` | Resolves cwd and agent metadata for gateway ingress |
| `lib/lemon_gateway/transport_registry.ex` | `TransportRegistry` | Gateway-ingress transport registration and enablement |
| `lib/lemon_gateway/transport_supervisor.ex` | `TransportSupervisor` | Starts enabled gateway-native transports |
| `lib/lemon_gateway/ingress_supervisor.ex` | `IngressSupervisor` | Gateway-owned transport, command, SMS, and voice startup |

Gateway-native transports normalize requests to `LemonCore.RunRequest` and submit
through `LemonCore.RouterBridge`; they must not invoke router internals directly.
New user-facing channels belong in `lemon_channels` unless they need a synchronous or
live gateway ingress surface.

## Adding Extensions

### Add a model provider

Implement the appropriate `LemonAi` provider contract when a new model/API needs to
serve agent turns. Provider selection stays in the agent/model layer; it does not
change Gateway execution or its singleton executor.

### Add a CodingAgent tool

Add an in-process capability as a `CodingAgent` tool. Gateway-specific tools are
assembled by the native executor's session runner; they are not a Gateway plugin
mechanism. Keep tool action details lossless, including safe failure metadata such as
`error_type`, `timeout_ms`, and `exit_code`.

### Add a delegated subagent

Delegated work runs natively in-process. Add a subagent persona through
`CodingAgent.Subagents` (`.lemon/subagents.json` or `~/.lemon/agent/subagents.json`)
and invoke it through the `task`/`agent` tools; the child run is a
`CodingAgent.Session` coordinated by `CodingAgent.Coordinator`. Do not wrap
external CLIs as Gateway executors or as task runners — vendor CLI subprocess
runners (Claude Code, Codex, Kimi, OpenCode, Pi) were removed.

### Add a transport

Prefer `lemon_channels` for a new messaging channel. Use gateway-native ingress only
for a non-channel surface that needs the Gateway runtime.

- Submit `%LemonCore.RunRequest{}` through `LemonCore.RouterBridge.submit_run/1`.
- Build stable, unique session keys.
- Return `:ignore` from `start_link/1` when disabled.
- Resolve binding cwd and agent metadata through `BindingResolver`.

## Operations and Debugging

Useful runtime inspection:

```elixir
:sys.get_state(LemonGateway.Scheduler)
:sys.get_state(LemonGateway.EngineLock)
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)
DynamicSupervisor.which_children(LemonGateway.RunSupervisor)
Registry.lookup(LemonGateway.RunRegistry, "run_uuid")
LemonGateway.Executor.validate_configured()
LemonGateway.Config.get(:max_concurrent_runs)
```

For stuck runs, inspect scheduler in-flight slots and `EngineLock` waiters. For an
unready runtime, inspect `LemonGateway.Executor.validate_configured/0` and the
configured `:executor` module; do not look for a registry entry or a selected engine.
For auto-resume, inspect `LemonCore.ChatStateStore` and the native executor's resume
state. For transport startup, inspect `TransportRegistry`; Telegram, Discord, XMTP,
and email remain channel-owned.

### Test application isolation

Umbrella tests share one BEAM and one OTP application controller. A test module that
stops globally named runtime applications must capture which applications were
running and restore that exact running set in `setup_all` cleanup. In particular,
stopping `:lemon_control_plane` deletes its method-registry ETS table; leaving it
stopped makes later control-plane tests fail for reasons unrelated to their code.
Use `Application.ensure_all_started/1` for restoration so transitive runtime
dependencies return through their production supervision trees.

## Integration Points

1. Submit execution through `LemonGateway.Runtime.submit_execution/1`.
2. Set `meta.notify_pid` to receive `{:lemon_gateway_run_completed, execution_request, completed}`.
3. Subscribe to `LemonCore.Bus` topic `"run:<run_id>"` for real-time run events.
4. Cancel through `LemonGateway.Runtime.cancel_by_run_id/2`.
5. Let `LemonCore.ChatStateStore` retain native and task resume state.

## Dependencies

- `coding_agent` provides the configured native executor and its in-process tools.
- `lemon_core` provides execution contracts, Store, Bus, Telemetry, resume formats,
  bindings, secrets, and canonical gateway configuration.
- `lemon_channels` owns Telegram/Discord/XMTP channel adapters and consumes gateway
  bus events; LemonGateway does not depend on it directly.
