# lemon_channels

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_channels` is ingress and egress: the channel core (Registry, Outbox, Dispatcher,
PresentationState), the `LemonChannels.Plugin` behaviour, and the built-in adapters
(telegram, discord, whatsapp, xmtp, email, webhook). `Plugin` is the best
extension point in the tree and the intended first contribution for outside builders —
a new adapter should require no changes to the platform. It talks to the router only
through `LemonCore.RouterBridge`. This page will become the package README: the six
`Plugin` callbacks with a worked example, runtime adapter registration, and the
outbound rendering pipeline.

XMTP and WhatsApp retain adapter-specific public `PortServer` callback/process
identities, bridge scripts, event tags, and module-scoped warning logging while
sharing line-delimited JSON port lifecycle, restart, and reconnect handling in
`LemonChannels.PortBridge`.
