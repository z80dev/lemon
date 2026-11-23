# Changelog

## [Unreleased]

### Added

- Prompt skill discovery can use shorter descriptions for coding sessions without
  hiding skill keys or truncating the metadata/instructions loaded by `read_skill`.
- Route MCP stdio launches through the native-process seam and record unsupported whole-workload ownership before client startup and protocol dispatch. Preserve uncertainty after failures while leaving cached reads and proven pre-dispatch refusals unrecorded.

### Changed

- **Breaking:** media tools require `provider`, use provider-specific default
  timeouts, and run jobs through `LemonMedia.MediaJobSupervisor.run_job/2`, which
  cancels timed-out or aborted jobs (#664).
- Share media-tool job, artifact, credential, and response helpers, including
  recursive atom conversion inside lists in redacted job metadata.
- Share skill-state file locking while preserving each store's retry budget.
- Make `LemonSkills.Audit.Engine` deterministic and remove its option-taking
  audit APIs; `BundleAudit` exclusively owns optional model review, preventing
  duplicate reviews and honoring per-call model overrides.
- Remove the unused `LemonSkills.HttpClient.get/1` convenience wrapper.
