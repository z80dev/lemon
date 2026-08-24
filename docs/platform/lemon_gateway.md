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

Gateway-native email, webhook, SMS, and voice transport glue remains alongside
the scheduler. External channel adapters such as Telegram and Discord live in
`lemon_channels`.
