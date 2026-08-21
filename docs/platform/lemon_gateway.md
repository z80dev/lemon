# lemon_gateway

`lemon_gateway` owns top-level run scheduling and lifecycle: global execution
slots, per-conversation serialization, launch locks, active-run lookup,
cancellation, persistence, telemetry, and normalized run events.

Every top-level conversation is dispatched to one configured
`LemonGateway.Executor` implementation. Product configuration binds
`CodingAgent.Executor`, which starts or resumes the native `CodingAgent.Session`.
The executor binding is a product-wiring and test-injection seam, not a public
runtime plugin registry; custom and selectable top-level engines are unsupported.

Vendor CLI integrations belong in `lemon_cli_runners` as delegated task
subagents implementing `LemonCore.SubagentRunner`. They run only when the native
agent invokes the `task` tool and do not consume Gateway top-level execution
slots.

Gateway-native email, webhook, SMS, and voice transport glue remains alongside
the scheduler. External channel adapters such as Telegram and Discord live in
`lemon_channels`.
