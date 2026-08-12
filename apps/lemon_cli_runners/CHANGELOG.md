# Changelog

All notable changes to `lemon_cli_runners` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release. `lemon_cli_runners` is the former `LemonAgent.CliRunners.*`
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

### Changed

- Module namespace: `LemonAgent.CliRunners.*` → `LemonCliRunners.*`.
- The run event vocabulary (`Action`, `StartedEvent`, `ActionEvent`,
  `CompletedEvent`, `EventFactory`) is no longer defined here: it belongs to
  `LemonCore.RunEvents`, alongside `LemonCore.ResumeToken`. Every runner in this
  package translates its vendor's JSONL dialect into those structs.
- App-env keys `:cli_timeout_ms`, `:cli_cancel_grace_ms`, and
  `:cli_session_lock_max_age_ms` are read from `:lemon_cli_runners`
  (previously `:lemon_agent`).
