# lemon_memory

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_memory` is durable agent memory: the document schema, the memory store, the
provider behaviour and its fan-out registry, the ingest pipeline, search, and task
fingerprints. It is a small (~1.9k LOC) but headline-feature domain with a real
extension point, which is why it becomes its own package rather than staying inside
`lemon_core` (decision D4). This page will become the package README: the memory
document shape, writing a `LemonMemory.Provider`, and wiring ingest into a run's
lifecycle through the `Store.Hooks` callback rather than a direct call.
