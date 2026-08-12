# lemon_platform_test

**Status:** stub — package does not exist yet. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_platform_test` is the contract-test kit: ExUnit case templates that run
behaviour-compliance suites against someone else's implementation of `LemonChannels.Plugin`,
`LemonGateway.Engine`, `LemonCore.SubagentRunner`, `LemonCore.Store.Backend`, or
`LemonMemory.Provider`. It is how an
extension author finds out their adapter is wrong before their users do, and how we find
out a behaviour change broke them. It is new code, seeded from the shared tests our own
adapters already use. This page will become the package README: `use` lines per behaviour,
what each suite asserts, and how to opt out of optional callbacks.
