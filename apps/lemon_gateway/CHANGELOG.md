# Changelog

All notable changes to `lemon_gateway` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. The gateway is now the native run
scheduler and lifecycle owner rather than a selectable engine host.

### Added

- `LemonGateway.Executor`, the four-callback contract used by the single
  configured top-level executor.
- `LemonGateway.Workspace`, which reads
  `config :lemon_gateway, :workspace_dir` without depending on CodingAgent.
- `LemonGateway.Config.replacement_config/0`, so the application that owns an
  environment key is the one that reads it.

### Changed

- `LemonGateway.Run` invokes the configured executor directly while retaining
  scheduling, launch locks, cancellation, persistence, telemetry, normalized
  events, and exactly-once terminalization.
- Top-level runtime provenance is fixed to `"lemon"` and no longer selects
  execution.
- Ingress (the HTTP webhook listener and the Twilio SMS utility) is
  gateway-owned by design because it needs synchronous HTTP responses.

### Removed

- The public `LemonGateway.Engine` extension contract, `EngineRegistry`, Echo,
  custom engine configuration, engine selection, and engine-specific resume
  parsing.
- Vendor top-level engine shells and `Engines.CliAdapter`. Codex, Claude, Kimi,
  OpenCode, and Pi remain available only as delegated task runners in
  `lemon_cli_runners`.
- The `droid` integration and `FACTORY_API_KEY`.
- The Farcaster transport and its configuration.
- The email transport, replaced by `LemonChannels.Adapters.Email`.
- The dependency on any specific coding agent. Product configuration supplies
  `CodingAgent.Executor` dynamically.

### Known gaps

- Voice support is deferred and undocumented.
