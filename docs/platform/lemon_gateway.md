# lemon_gateway

`lemon_gateway` owns optional webhook, SMS, and voice ingress. With
[`[gateway.ingress] enabled = true`](../config.md#gateway-ingress) unset,
it starts an empty supervisor: no ingress, voice task supervisor or health
listener on port 4042. The three surfaces also have individual enable flags.

Gateway submits `LemonCore.RunRequest` through `LemonCore.RouterBridge`.
Integrations that previously submitted execution commands directly must use
this admitted path. [Router](../architecture/overview.md) owns top-level
execution, including its permits, lifecycle, and run events.

The SMS inbox registers its tools through `LemonAgent.ToolRegistry` while it
runs; native execution does not require or start the gateway. Messaging
adapters such as Telegram, Discord, XMTP, and Email live in `lemon_channels`.

See the [gateway README](../../apps/lemon_gateway/README.md) for transport
setup and ingress health.
