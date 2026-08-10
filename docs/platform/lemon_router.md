# lemon_router

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_router` owns run lifecycle and session orchestration: single-flight execution,
queueing and steering, coalescing, policy resolution, the watchdog, and delivery
routing. It reaches the execution runtime only through the `LemonCore.EngineRuntime`
behaviour (never `LemonGateway.*` directly) and channels only through the
Dispatcher/Outbox facade — the single allowed compile-time edge. This page will become
the package README: the run state machine and phase events, the public `LemonRouter`
facade, and which modules are internal. Source today is `apps/lemon_router`; the facade
gets hardened in Phase 2.6 so that other apps stop touching `RunRegistry` /
`RunSupervisor` / `RunOrchestrator`.
