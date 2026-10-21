# LemonOmp changelog

## [Unreleased]

### Added

- Delegate RPC launches use opt-in durable native-process tracking. The local
  process witness is retained separately from uncertainty about independently
  launched delegate tools; an RPC process exit does not prove their termination.

### Changed

- Mark the omp tool's audited schema construction as managed after routing
  catalog, version, git worktree and shutdown-helper launches through the native
  process ledger. Actual delegate startup still records unsupported ownership
  before launch: the RPC process group cannot attest independently owned work.
- Preserve the pre-disconnect descendant inventory during shutdown and measure
  escalation grace against elapsed monotonic time, including native tracking
  overhead, so root exit cannot skip orphan cleanup or delay KILL escalation.
