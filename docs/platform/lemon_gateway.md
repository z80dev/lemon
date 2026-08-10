# lemon_gateway

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_gateway` is the engine execution runtime and nothing else: the `Engine`
behaviour, the engine registry, scheduler and locks, and the `LemonCore.EngineRuntime`
implementation the router binds to. Its email/farcaster/webhook/sms/voice transports
move to `lemon_channels` as `Plugin` implementations (decision D2), leaving one
transport concept in the platform, and its `CodingAgent` dependency inverts in Phase 2.1
so engines self-register at boot. This page will become the package README: writing an
`Engine`, registering it, and the scheduling/locking guarantees callers can rely on.
