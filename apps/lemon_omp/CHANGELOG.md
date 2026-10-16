# LemonOmp changelog

## [Unreleased]

### Added

- Delegate RPC launches use opt-in durable native-process tracking. The local
  process witness is retained separately from uncertainty about independently
  launched delegate tools; an RPC process exit does not prove their termination.
