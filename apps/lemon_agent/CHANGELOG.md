# Changelog

All notable changes to `lemon_agent` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

### Changed

- Anthropic OAuth resolution fails closed: a stored Lemon login that cannot
  refresh or persist now yields no credential instead of falling back to
  ambient Claude Code tokens. OAuth secret resolution passes `:reload_secret`
  so refresh helpers can re-read the secret under their refresh lock.
- OAuth refresh persistence is conditional on the exact encrypted-store login
  revision. A login replacement or logout during a token request wins; the
  obsolete response cannot overwrite it or become selected authentication.
  Storage failures stop refresh resolution without replaying the request.
- Tool execution defaults to a 300,000 ms deadline and at most eight concurrent
  calls. `:infinity` explicitly opts out. `AgentTool.timeout_ms` overrides the
  deadline; native task/wait, delegation, bash, eval, debug, question and browser
  tools retain their own deadlines instead of racing the generic timer.

## [0.2.0] - 2026-10-13

First release as a standalone package. `lemon_agent` is the `:lemon_agent`
application from the Lemon umbrella; the OTP application name and every
`LemonAgent.*` module name are unchanged.

### Removed

- `LemonAgent.Workspace.HeartbeatStore`; heartbeat configuration and results now
  use automation cron jobs and cron history.

### Fixed

- `LemonAgent.ModelRuntime.Credentials` returns the result of storing a
  refreshed OAuth secret instead of `:ok`, so a refused write (for example
  `{:error, :secrets_locked}` during a master-key rotation) fails the
  resolution. A recognised OAuth payload that cannot be resolved now yields no
  credential, rather than the raw payload being used as an API key; the
  warning logs only the error's tag.
- Installable from Hex. The `0.1.0` release's `mix.exs` began with
  `Code.require_file("../../hex_package.exs", __DIR__)`, a file that was not in
  the package, so it failed to load in every consumer project; `0.1.0` is
  retired. The shipped `mix.exs` is now self-contained, and requires
  `lemon_ai` and `lemon_core` as `~> 0.2`.

### Added

- `LemonAgent.ToolRegistry` — runtime tool registration backed by
  `:persistent_term`, so a library or satellite package can add tools to an
  agent without the agent knowing about it at compile time. Built-in tools win
  on a name collision, which keeps a third-party registration from shadowing
  core behaviour by accident. This is the tool-side analogue of the channel
  adapter and engine registries.
- `LemonAgent.Workspace.GoalStore` and `.KanbanStore` — the
  multi-agent work-coordination stores, moved here from `lemon_core`. They are
  built purely on core primitives and every consumer already depended on this
  package.
- `LemonAgent.ProviderConfigResolver` — provider configuration resolution, moved
  here from `lemon_core`, where it had exactly one consumer.
- `LemonAgent.Env` declares the environment variables this package reads, with
  types, defaults and documentation. `LemonCore.Env` aggregates it when present.

### Changed

- `LemonAgent.Security.ExternalContent` is the canonical implementation for
  wrapping untrusted external content. It stays in this package rather than
  moving to `lemon_core` because it is defined in terms of
  `LemonAgent.Types.AgentToolResult` and `LemonAi.Types.TextContent`; a package that
  knows nothing about agents or models cannot host it.
- Vendor-specific social tools are not shipped by the Lemon harness. External
  packages can contribute their own tools through `LemonAgent.ToolRegistry`
  without adding compile-time knowledge to this package.

### Notes

- Depends only on `lemon_ai` and `lemon_core`. This is the package to build on
  if you want an agent loop and tools without a router, channels or a gateway.
