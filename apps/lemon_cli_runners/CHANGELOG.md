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
- `LemonCliRunners.Types` — `ResumeToken`, `Action`, `StartedEvent`,
  `ActionEvent`, `CompletedEvent`, `EventFactory`.
- `LemonCliRunners.Env` — the `:cli_runners`-area environment variable
  declarations, moved out of `LemonAgent.Env`.

### Changed

- Module namespace: `LemonAgent.CliRunners.*` → `LemonCliRunners.*`.
- App-env keys `:cli_timeout_ms`, `:cli_cancel_grace_ms`, and
  `:cli_session_lock_max_age_ms` are read from `:lemon_cli_runners`
  (previously `:lemon_agent`).
