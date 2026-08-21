# Changelog

All notable changes to `lemon_cli_runners` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

### Removed

- **Breaking:** Gateway engine shells and their `LemonGateway.EngineRegistry`
  registration were removed. Gateway now invokes its configured singleton native
  executor and cannot be selected, extended, or replaced by a vendor CLI or custom
  engine. Claude Code, Codex, Kimi, OpenCode, and Pi remain supported only as
  `LemonCore.SubagentRunner` implementations for delegated tasks. Their
  `[runtime.cli.<vendor>]` settings and `LemonCore.ResumeFormats` registrations are
  retained for that task-runner role.

## [0.1.0] — Historical initial release

First release. `lemon_cli_runners` was the former `LemonAgent.CliRunners.*`
namespace, carved out of `lemon_agent`. Vendor CLI wrappers churn with vendor
releases; a separate package can version fast without forcing releases of the
agent framework.

### Added

- `LemonCliRunners.JsonlRunner` — base behaviour + GenServer for
  JSONL-streaming CLI subprocesses: port spawning, line buffering, session
  locking, stderr capture, graceful shutdown.
- Per-vendor runner/schema/subagent triples for Claude Code, Codex, Kimi,
  OpenCode, and Pi.
- `LemonCliRunners.Env` — the `:cli_runners`-area environment variable
  declarations, moved out of `LemonAgent.Env`.
- `LemonCliRunners.Application` — registers each vendor subagent with
  `LemonCore.SubagentRegistry`, and each vendor's resume syntax with
  `LemonCore.ResumeFormats`, at boot. The package is now an OTP application
  (with an empty supervision tree) purely so it can announce itself.
- `resume_format/0` on every `*Subagent`: the vendor owns how its CLI spells
  "resume" (`codex resume X`, `claude --resume X`, `opencode --session ses_X`,
  pi's quoted transcript paths), including the wider invocations users paste
  back. `LemonCore.ResumeToken` prints and parses these without naming a vendor.
- Every `*Subagent` module implements `LemonCore.SubagentRunner`: `id/0`,
  `describe/0` (the tool-description prose, including per-vendor caveats such as
  "ignores `model`"), and a total `cancel/1`.
- `resolve_cli_settings/1` on every `*Subagent`: the vendor owns what its
  `[runtime.cli.<engine>]` config section means — its keys and its defaults
  (e.g. claude's `dangerously_skip_permissions` defaulting `true`) — moved out
  of `LemonCore.Config.Agent`. `LemonCliRunners.Application` registers each
  with `LemonCore.Config.CliResolvers` at boot, so config resolution needs no
  vendor table in core; the resolved shape runners read is unchanged.
- **Historical (removed after 0.1.0):**
  `LemonCliRunners.Engines.{Claude,Codex,Kimi,Opencode,Pi}` were Gateway engine
  shells moved from `LemonGateway.Engines.*`. They implemented
  `LemonGateway.Engine` over `LemonGateway.Engines.CliAdapter` and registered with
  `LemonGateway.EngineRegistry.register_default/1` at boot. The singleton-executor
  cutover removed those shells and the registry; vendor support continues through
  the package's `LemonCore.SubagentRunner` implementations only.

### Changed

- Module namespace: `LemonAgent.CliRunners.*` → `LemonCliRunners.*`.
- The run event vocabulary (`Action`, `StartedEvent`, `ActionEvent`,
  `CompletedEvent`, `EventFactory`) is no longer defined here: it belongs to
  `LemonCore.RunEvents`, alongside `LemonCore.ResumeToken`. Every runner in this
  package translates its vendor's JSONL dialect into those structs.
- App-env keys `:cli_timeout_ms`, `:cli_cancel_grace_ms`, and
  `:cli_session_lock_max_age_ms` are read from `:lemon_cli_runners`
  (previously `:lemon_agent`).
