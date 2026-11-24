# Changelog

## [Unreleased]

### Added

- Prompt skill discovery can use shorter descriptions for coding sessions without
  hiding skill keys or truncating the metadata/instructions loaded by `read_skill`.
- Route MCP stdio launches through the native-process seam and record unsupported whole-workload ownership before client startup and protocol dispatch. Preserve uncertainty after failures while leaving cached reads and proven pre-dispatch refusals unrecorded.

### Changed

- Share media-tool job, artifact, credential, and response helpers, including
  recursive atom conversion inside lists in redacted job metadata.
- Share skill-state file locking while preserving each store's retry budget.
- Make `LemonSkills.Audit.Engine` deterministic and remove its option-taking
  audit APIs; `BundleAudit` exclusively owns optional model review, preventing
  duplicate reviews and honoring per-call model overrides.
- Remove the unused `LemonSkills.HttpClient.get/1` convenience wrapper.

### Fixed

- `ProfileMemoryTransfer.apply_transfer/2` passes definite failures
  (`:stale_destination`, `:destination_conflict`, `:transfer_conflict`, lock
  abort, verified rollback) through instead of collapsing them to
  `:transfer_pending`, removes the `.memory-transfer-*` staging directory and
  frees the mutation id. The receipt commit releases the frozen source snapshot
  and previews held in the destination Store, and the new `release/5` releases a
  source snapshot held elsewhere (#623).
