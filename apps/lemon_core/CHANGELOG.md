# Changelog

All notable changes to `lemon_core` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_core` used to be the umbrella's
catch-all shared app; this release turns it into a library you can embed. The
theme of every change below is the same: nothing in `lemon_core` knows about
Telegram, run history, durable memory, kanban boards, or `~/.lemon`.

### Added

- `LemonCore.SubagentRunner` and `LemonCore.SubagentRegistry` — the extension
  point behind the agent's `task` tool. An executor (a vendor CLI wrapper, the
  in-process agent, anything else) implements the behaviour and registers when
  its own application starts; the agent reads the registry for its engine list,
  its per-engine tool-description prose, and each engine's default tool policy,
  so no vendor is named in the agent. Runners that declare themselves routable
  publish their id to `:lemon_core, :registered_engines`, which
  `LemonCore.EngineCatalog` unions with its built-in defaults. Registration
  never writes `:known_engines`: that key is the operator's own list, and when
  it is set it is the whole answer, so narrowing it still disables an engine the
  build happens to ship.
- `LemonCore.ResumeFormat` and `LemonCore.ResumeFormats` — the extension point
  behind `LemonCore.ResumeToken`. An engine registers how it spells "resume"
  (a pattern to find its token in text, a renderer to print one) when its own
  application starts, so core no longer carries a table of per-vendor regexes.
  `lemon` is built in; engines with no registered format read and print the
  generic `<engine> resume <value>`.
- `LemonCore.Store` can run as many named instances as you like. Configuration
  comes from `start_link/1` options first and application environment second,
  so an embedding application no longer has to write into `:lemon_core`'s app
  env to configure a store it owns.
- `LemonCore.Store.Hooks` — the extension point that replaced hardcoded calls in
  `finalize_run/2`. Collaborators register `{module, function, args}` hooks
  (kept in `:persistent_term`, so they survive a store restart) and failures in
  one hook are isolated from the run and from other hooks. Reads invert the same
  way through a configurable `:run_history_provider`.
- `LemonCore.Secrets.KeyProvider` — a behaviour with keychain, environment and
  file providers built in, and a configurable chain. Non-macOS hosts now have a
  first-class provisioning path (`mix lemon.secrets.init`, writing a 0600 key
  file) instead of a macOS-Keychain-only one.
- `LemonCore.Paths` — every filesystem location the library uses is resolved
  through one configurable module. The `~/.lemon` defaults are now the
  *reference runtime's* configuration rather than baked-in library behaviour.
- `LemonCore.Env.Registry` — environment variables are declared by the package
  that reads them and aggregated here through `:env_registries`. Registries that
  are not loaded are skipped, so the aggregate always describes what your build
  can actually read.
- `LemonCore.EngineInfoBridge` — a configured-implementation bridge (the same
  shape as `RouterBridge`, pointed the other way) that answers engine-registry,
  transport-registry and gateway-config questions with a documented degraded
  answer when no implementation is registered.
- `LemonCore.Doctor.RuntimeModules` and the `:doctor_checks` config key: any
  application can register its own diagnostics instead of `lemon_core` naming
  foreign modules.
- `LemonCore.UUID` — a vendored UUIDv7 generator.

### Changed

- `LemonCore.ResumeToken` is now a struct plus generic parse/format over the
  registered resume formats. The per-vendor regex families it used to hold
  (codex, claude, kimi, opencode, pi) moved to the packages that wrap those
  CLIs. The API — `format/1`, `format_plain/1`, `extract_resume/1,2`,
  `is_resume_line/1,2` — is unchanged, and remains the entrypoint for callers
  that depend on `lemon_core` alone.
- **`:exqlite`, `:sentry`, `:finch`, `:phoenix_pubsub` and `:file_system` are
  now optional dependencies.** Embedding `lemon_core` no longer drags in a
  SQLite NIF, an HTTP client, an error reporter and a pubsub server. Each one
  degrades explicitly and audibly: the bus falls back to a local `Registry`,
  the store falls back to ETS, the config reloader polls, and the Sentry
  handler is skipped. Detection happens at runtime, not compile time, so the
  same build works with or without them.
- `LemonCore.Store.ReadCache` uses per-store ETS table sets held by reference.
  Two differently-named stores can now run in one node without silently
  sharing a cache; a genuine collision raises `CollisionError` instead of
  failing open.
- `:inets` and `:ssl` are declared applications (they back `LemonCore.Httpc`),
  which fixes a half-loaded `httpc` in pruned builds.
- Cached store tables are per-instance options plus `register_cached_table/1`,
  rather than a fixed list containing channel-specific tables.

### Removed

- `LemonCore.Memory*` — the eight durable-memory modules moved to the new
  `lemon_memory` package as `LemonMemory.*`. The app env key moved with them,
  from `:lemon_core, LemonCore.MemoryStore` to `:lemon_memory, LemonMemory.Store`.
- `LemonCore.GoalStore`, `KanbanStore` and `HeartbeatStore` — moved to
  `lemon_agent` as `LemonAgent.Workspace.*`.
- `LemonCore.ProviderPoolRotator` and `ProviderConfigResolver` — moved to their
  single consumers (`coding_agent` and `lemon_agent` respectively).
- Weak raw master keys are rejected with `:weak_master_key` rather than being
  silently stretched; `allow_legacy_raw_keys: true` is the deprecation escape
  hatch. Stretching would have quietly broken existing ciphertexts.

### Known gaps

- Secrets key rotation and re-encryption are not implemented; the gap is
  documented in `LemonCore.Secrets`'s moduledoc.
