# Changelog

## [Unreleased]

### Added

- Prompt skill discovery can use shorter descriptions for coding sessions without
  hiding skill keys or truncating the metadata/instructions loaded by `read_skill`.
- Route MCP stdio launches through the native-process seam and record unsupported whole-workload ownership before client startup and protocol dispatch. Preserve uncertainty after failures while leaving cached reads and proven pre-dispatch refusals unrecorded.
- `LemonSkills.Frontmatter.parse_yaml/2`: the shared YAML frontmatter parser
  (direct `:yamerl`, no `Application.start/1`; duplicate-key rejection and a
  size cap) used by skill manifests, subagent definitions and rules (#671).

### Changed

- `LemonSkills.Context` (with `Context.Document` and `Context.URLFetcher`), the
  bounded context-reference preview/resolve service behind `lemon context` and
  `LemonSkills.Learn`, moved here from `lemon_core` (`LemonCore.Context`). Its
  references, limits and results are unchanged; `@url:` fetching stays on the
  shared `LemonCore.Net.HTTP` address policy (#724).

- **Breaking:** media provider HTTP clients, the Google JWT exchange and the
  artifact writer moved to `lemon_media` (`LemonMedia.Providers`,
  `LemonMedia.GoogleAuth`, `LemonMedia.Artifact`); `MediaCommon.write_artifact/2`,
  `transient_status?/1`, `provider_error_kind/1` and `reject_blank_values/1`
  were removed. The media tools keep their schemas and result shapes (#722).
- **Breaking:** media tools require `provider`, use provider-specific default
  timeouts, and run jobs through `LemonMedia.MediaJobSupervisor.run_job/2`, which
  cancels timed-out or aborted jobs (#664).
- **Breaking:** a YAML skill manifest that repeats a top-level key or exceeds
  64 KiB of frontmatter no longer parses (`Manifest.Parser.parse/1` returns
  `:error`) instead of resolving duplicates last-wins (#671).
- Share media-tool job, artifact, credential, and response helpers, including
  recursive atom conversion inside lists in redacted job metadata.
- Share skill-state file locking while preserving each store's retry budget.
- Make `LemonSkills.Audit.Engine` deterministic and remove its option-taking
  audit APIs; `BundleAudit` exclusively owns optional model review, preventing
  duplicate reviews and honoring per-call model overrides.
- Remove the unused `LemonSkills.HttpClient.get/1` convenience wrapper.
- Skill lockfile and audit-state writes wait up to ten seconds (was one) for
  the metadata lock, so a burst of concurrent writers in one VM no longer gets
  spurious `{:error, :lock_timeout}` refusals (#499).

### Fixed

- `recall` filters ownership before its result limit for legacy sessions (via `Project.search_history/4`) and no longer searches memory providers; the `:search_fn` option is removed (**Breaking** for callers that injected it) (#656).
- `ProfileMemoryTransfer.apply_transfer/2` passes definite failures
  (`:stale_destination`, `:destination_conflict`, `:transfer_conflict`, lock
  abort, verified rollback) through instead of collapsing them to
  `:transfer_pending`, removes the `.memory-transfer-*` staging directory and
  frees the mutation id. The receipt commit releases the frozen source snapshot
  and previews held in the destination Store, and the new `release/5` releases a
  source snapshot held elsewhere (#623).
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
