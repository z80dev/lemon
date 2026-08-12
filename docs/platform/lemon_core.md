# lemon_core

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_core` is the platform's shared language: the `Bus` and `Event` envelope, the
`Store` and its pluggable backends, secrets, the config loader, the boundary contracts
every other package speaks (`RunRequest`, `ExecutionCommand`, `InboundMessage`,
`DeliveryIntent`, `EngineRuntime`, `RouterBridge`, `SessionKey`, `ResumeToken`,
`RunEvents`, `SubagentRunner` + its registry, run phases), the primitives (clock, id, retry, telemetry, idempotency), and the Extensions
manifest. Everything depends on it, so it must stay product-free. This page will become
the package README once Phase 1 lands: the contract catalog, the `Store.Backend`
behaviour, and the rules for evolving the bus wire format. See §6 of the plan for which
modules stay and which leave.
