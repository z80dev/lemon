# lemon_gateway

`lemon_gateway` owns top-level run scheduling and lifecycle: global execution
slots, per-conversation serialization, launch locks, active-run lookup,
cancellation, persistence, telemetry, and normalized run events.

Every top-level conversation is dispatched to one configured
`LemonGateway.Executor` implementation. Product configuration binds
`CodingAgent.Executor`, which starts or resumes the native `CodingAgent.Session`.
The executor binding is a product-wiring and test-injection seam, not a public
runtime plugin registry; custom and selectable top-level engines are unsupported.

Subagents run natively in-process: when the native agent invokes its `task`
tool, the delegated work executes as another `CodingAgent.Session` coordinated
by `CodingAgent.Coordinator`. Subagents do not consume Gateway top-level
execution slots, and there are no vendor CLI subprocess runners.

Gateway-native webhook, SMS, and voice transport glue remains alongside the
scheduler and starts only when `:gateway_ingress_enabled` is set for
`:lemon_gateway` (off by default). External channel adapters — Telegram, Discord,
XMTP and Email — live in `lemon_channels`.

## Execution path

Router-owned `SessionCoordinator` decides queue semantics (collect, followup,
steer, interrupt) and hands queue-semantic-free `%LemonCore.ExecutionCommand{}`
values to `LemonGateway.Runtime.submit_execution/1`, the public submission
boundary. `LemonGateway.Scheduler` grants slots by the router-supplied
conversation key; `ThreadWorker` is only a per-conversation launcher; `Run`
acquires `EngineLock`, drives the configured executor, and publishes
`run_started`, `delta`, `engine_action` and `run_completed` events on the
`run:<run_id>` bus topic (catalog in [Typed Bus Events](bus-events.md)).
Terminal receipts are durable before their bus notification. Each worker queues
at most 128 pending launches and the global slot-wait queue holds 1,024 workers;
overflow terminalizes the rejected run with `:execution_queue_full`.

The executor is configured with `config :lemon_gateway, :executor,
CodingAgent.Executor`; `LemonGateway.Executor.validate_configured/0` checks that it is
loadable and implements the required callbacks (`start_run/3`, `cancel/1`,
`steer/2`, `redirect/2`). Every gateway run carries the fixed provenance
`engine: "lemon"`; legacy `engine`, `default_engine`, `engine_preference` keys and
`[gateway.engines.<id>]` tables are no longer supported.

Contributor details (idempotent webhook receipts, slot generations, lock
ownership, operations snippets) are in `apps/lemon_gateway/AGENTS.md`, and the
full architecture and transport table are in `apps/lemon_gateway/README.md`.
