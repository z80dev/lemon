# Changelog

All notable changes to `lemon_router` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. The theme of this release is that
`LemonRouter` is now a facade you can program against, rather than a set of
internals other applications reached into.

### Added

- `LemonRouter` is the supported API surface: `submit/1`, `abort/2`,
  `abort_run/2`, plus the new `available?/0`, `active_runs/0`, `run_active?/1`,
  `active_run_count/0` and `counts/0`. These were designed from the thirteen
  real call sites rather than invented, and the facade owns the defensiveness
  each caller used to reimplement (process probes, registry lookups,
  supervisor counts, rescue and catch ladders). **A router that is not running
  now reports nothing-active instead of raising.**
- `counts/0` returns the full zeroed shape (`:active`, `:queued`,
  `:completed_today`) when the router is down, not an empty map — callers read
  those keys unguarded.
- `LemonRouter.Env` declares the environment variables this package reads.

### Changed

- The router is the single writer of chat state (`LemonCore.ChatState`). The
  gateway's writes were redundant — the overflow delete was already duplicated
  by the router on the same event, and the completion event carries the resume
  token into the router anyway — so gateway's chat-state coupling is now zero.
- `LemonRouter.RunSupervisor` and `RunOrchestrator` are `@moduledoc false`.
  They are internals; use the facade. (There has never been a `RunRegistry`
  module — it is a plain `Registry` started in the router's supervision tree.)
- Durable memory now comes from the `lemon_memory` package, following the
  extraction out of `lemon_core`.
- `:exqlite` is a direct dependency because `RoutingFeedbackStore` talks to
  SQLite; `lemon_core` only carries it optionally.

### Known gaps

- This package still depends on `lemon_media` for artifact recording
  (`LemonRouter.MediaJobRecorder`), which is not yet published. That
  dependency has to be resolved — published or inverted — before
  `lemon_router` can go to hex.
