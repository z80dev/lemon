# lemon_gateway

`lemon_gateway` owns top-level execution permits and lifecycle: global slots,
fail-fast engine-session claims, active-run lookup, cancellation, persistence,
telemetry, and normalized run events. Router alone owns conversation ordering.

Every top-level conversation is dispatched to one configured
`LemonGateway.Executor` implementation. Product configuration binds
`CodingAgent.Executor`, which starts or resumes the native `CodingAgent.Session`.
The executor binding is a product-wiring and test-injection seam, not a public
runtime plugin registry; custom and selectable top-level engines are unsupported.

Subagents run natively in-process: when the native agent invokes its `task`
tool, the delegated work executes as another `CodingAgent.Session` coordinated
by the task lifecycle. Subagents do not consume Gateway top-level
execution slots, and there are no vendor CLI subprocess runners.

Gateway-native webhook, SMS, and voice transport glue remains alongside the
execution runtime and starts only when `:gateway_ingress_enabled` is set for
`:lemon_gateway` (off by default). External channel adapters — Telegram, Discord,
XMTP and Email — live in `lemon_channels`.

## Execution path

Router-owned `SessionCoordinator` decides queue semantics (collect, followup,
steer, interrupt) and hands queue-semantic-free `%LemonCore.ExecutionCommand{}`
values to `LemonGateway.Runtime.submit_execution/1`, the public submission
boundary. Runtime starts a temporary `Run` directly under `RunSupervisor`.
The Run claims its engine session through `EngineSessionClaim` while it starts,
before requesting a permit from `Slots`; contention refuses the start with
`{:error, :session_in_use}` (the router retries it), without holding a permit.
A cancelled Run holds its permit and claim until its executor exits or the
15-second drain deadline passes. Slots queues live Run processes FIFO. A terminal
fence before admission and cancellation/terminal recheck after grant prevent
late execution. The Run drives the executor and publishes `run_started`, `delta`,
`engine_action` and `run_completed` on `run:<run_id>`
(catalog in [Typed Bus Events](bus-events.md)).
Terminal receipts are durable before notification.

Supported product ingress submits `RunRequest` through `RouterBridge`; router
uses the configured `LemonCore.EngineRuntime` implementation. Direct execution
integrations may use `LemonGateway.Runtime.submit_execution/1` or the
`LemonGateway.submit/1` facade with a resolved `ExecutionCommand`.
Those calls do not supply router ordering, durable admission, or backlog limits.
`Runtime.submit/1`, private request structs and supervisor calls are not supported
submission APIs.

The [admission ADR and inventory](../architecture/admission-gates.md) records
all admission owners, defaults and saturation behavior, including unbounded
coordinator population and gateway waiters.

The executor is configured with `config :lemon_gateway, :executor,
CodingAgent.Executor`; `LemonGateway.Executor.validate_configured/0` checks that it is
loadable and implements the required callbacks (`start_run/3`, `cancel/1`,
`steer/2`, `redirect/2`). Every gateway run carries the fixed provenance
`engine: "lemon"`; legacy `engine`, `default_engine`, `engine_preference` keys and
`[gateway.engines.<id>]` tables are no longer supported.

Contributor lifecycle and operations details are in
`apps/lemon_gateway/AGENTS.md`; architecture and transports are in
`apps/lemon_gateway/README.md`.
