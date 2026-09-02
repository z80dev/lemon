# Changelog

All notable changes to `lemon_agent` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_agent` is the `:lemon_agent`
application from the Lemon umbrella; the OTP application name and every
`LemonAgent.*` module name are unchanged.

### Added

- `LemonAgent.ToolRegistry` — runtime tool registration backed by
  `:persistent_term`, so a library or satellite package can add tools to an
  agent without the agent knowing about it at compile time. Built-in tools win
  on a name collision, which keeps a third-party registration from shadowing
  core behaviour by accident. This is the tool-side analogue of the channel
  adapter and engine registries.
- `LemonAgent.Workspace.GoalStore`, `.KanbanStore` and `.HeartbeatStore` — the
  multi-agent work-coordination stores, moved here from `lemon_core`. They are
  built purely on core primitives and every consumer already depended on this
  package.
- `LemonAgent.ProviderConfigResolver` — provider configuration resolution, moved
  here from `lemon_core`, where it had exactly one consumer.
- `LemonAgent.Env` declares the environment variables this package reads, with
  types, defaults and documentation. `LemonCore.Env` aggregates it when present.

### Changed

- `test/support` compiles with the app in the test environment
  (`elixirc_paths`), so `LemonAgent.Test.Mocks` is available to dependent
  apps' suites without `Code.require_file/1`.

- `LemonAgent.Security.ExternalContent` is the canonical implementation for
  wrapping untrusted external content. It stays in this package rather than
  moving to `lemon_core` because it is defined in terms of
  `LemonAgent.Types.AgentToolResult` and `LemonAi.Types.TextContent`; a package that
  knows nothing about agents or models cannot host it.
- The X/Twitter tools (`x_search`, `post_to_x`, `get_x_mentions`) are no longer
  named by this package's built-in tool list. They ship with the `x_api`
  satellite and register themselves through `LemonAgent.ToolRegistry`. If you
  want them, depend on `x_api`; nothing in the platform mentions X any more.

### Notes

- Depends only on `lemon_ai` and `lemon_core`. This is the package to build on
  if you want an agent loop and tools without a router, channels or a gateway.
