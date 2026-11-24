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
- `LemonSkills.McpSource` replaces its single serialized discovery job with
  per-scope configuration loads and per-server refresh workers. A project scope
  is held by the processes that discovered it and evicted (closing the clients
  no other scope uses) when the last one exits; `:max_project_scopes` (default
  16, `config :lemon_skills, :mcp_max_project_scopes`) caps loaded project
  scopes with least-recently-used eviction. A load replaces only its own
  scope's servers and cached tools. `discover_tools/2` serves the committed
  snapshot and waits at most `:discovery_wait_ms` (default 10 s,
  `:mcp_discovery_wait_ms`) for servers without a usable connection.
  Startup and discovery failures use the jittered exponential reconnect
  backoff and crash-storm breaker; unconnected servers no longer make the
  periodic refresh retry everything.

### Removed

- **Breaking:** the MCP sampling bridge (`sampling` server config entries,
  `:sampling_policy` validation and the `mcp_<server>_sampling` ExecApprovals
  reviewer). Sampling could never produce a result; servers now receive
  method-not-found and a `sampling` config entry is ignored.
