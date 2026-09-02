# Changelog

All notable changes to `lemon_core` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_core` used to be the umbrella's
catch-all shared app; this release turns it into a library you can embed. The
theme of every change below is the same: nothing in `lemon_core` knows about
Telegram, run history, durable memory, kanban boards, or `~/.lemon`.
### Removed

- Vendor CLI wrapper extension points. Subagent tasks now execute natively, and
  `[runtime.cli]` is rejected.


### Added

- `LemonCore.Store.Table` lets a domain wrapper declare table ownership plus
  future cache, retention, persistence, and schema-version metadata without
  generating CRUD functions or changing backend behavior. The existing
  architecture quality gate parses all supported generic Store operations at
  default and explicit server arities and permits owner calls only when their
  literal or module-attribute table matches the declaration.

- `LemonCore.A2A.Protocol`, `LemonCore.A2A.Client`, and `LemonCore.A2AStore`
  provide the generic A2A v1.0 wire helpers, credential-scrubbing HTTP client,
  and typed durable context/task/message storage shared by peer transports and
  agent tools.

- `LemonCore.Events.ChannelDelivery` — a typed `:channel_delivery` payload,
  registered in `LemonCore.Events.registry/0`, which makes `"channels"` a typed
  contract topic with a real publisher for the first time: the channels
  dispatcher broadcasts one after every outbound dispatch (route/peer info,
  intent kind, bounded text preview, result, timings). See
  `docs/platform/bus-events.md` §10.
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
- `LemonCore.Config.Gateway.Channel` and the `:gateway_channels` config key —
  the extension point behind the `[gateway.<id>]` config sections. A module
  registers one section id and owns everything named after it: the sub-table's
  resolution, the `enable_<id>` flag, that platform's environment variables and
  the section's validation rules. `LemonCore.Config.Gateway` now exposes them
  as `channels`/`enabled_channels`, which `LemonCore.Config` flattens back onto
  the legacy map as `gateway[<id>]` and `gateway[:enable_<id>]`, so readers are
  unchanged. With nothing registered a build simply has no channel sections.
- `LemonCore.Doctor.ChannelProofs` and the `:channel_proofs` runtime-module key
  — the doctor reads redacted smoke-proof JSON whose per-channel check names and
  evidence fields are defined by whoever owns the channels, so it asks for that
  vocabulary instead of hardcoding it. Unregistered, the proof diagnostics,
  media check, cron check and launch gates degrade to their generic answers.

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
- **`LemonCore.Bus.broadcast_event/4` coerces instead of relaying a mismatch in
  production.** A registered event type whose payload is not its struct still
  raises in `:dev`/`:test`, so the developer who introduced it sees it. In
  `:prod` the payload is now coerced through `LemonCore.Events.coerce/2` rather
  than passed through untouched: with the `Access` shim gone, subscribers
  pattern-match the struct, so relaying a legacy map would have dropped the
  event at every subscriber instead of degrading it. A payload too malformed to
  coerce is still relayed as-is.
- `LemonCore.Env.string/1` and `string/2` are two clauses with their own specs
  instead of one clause with a `nil` default. The single clause delegated to
  `LemonCore.Config.Helpers.get_env/2`, whose contract is
  `(binary(), binary()) :: binary()`, so the defaulted `nil` violated it and
  Dialyzer concluded `Env.string/1` never returns — which silently poisoned
  every caller's analysis (the `[runtime.tools]`/logging config resolvers and
  `LemonBrowser.LocalServer`). Runtime behaviour is unchanged: an unset or
  empty variable is still `nil` (or the given default).
- **`LemonCore.Config.Validator`'s generic scalar checks are public.**
  `validate_boolean/3`, `validate_positive_integer/3`,
  `validate_non_negative_integer/3`, `validate_ratio/3` and
  `env_var_reference?/1` gained `@doc`/`@spec`, so a channel module validating
  its own section from another package produces messages in the same shape.
- `LemonCore.Testing.HermeticEnv.credential_env_vars/0` is a function, not a
  module attribute passthrough: it unions the built-in provider list with
  `config :lemon_core, :test_credential_env_vars`. An application that owns a
  transport registers the variables that transport reads, so the library does
  not carry a list of platforms it does not implement.
- `LemonCore.InboundMessage`'s moduledoc now spells out the transport-independent
  meaning of every field. The field names are unchanged.

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
- **Breaking: `LemonCore.Events` payload structs no longer implement `Access`.**
  `payload[:key]`, `get_in/2`, `pop_in/2` and `put_in/3` on a payload now raise
  `UndefinedFunctionError`; read the field (`payload.key`) or pattern-match the
  struct instead. The shim existed for exactly one release cycle so that each
  publisher could be typed without its consumers changing in the same commit
  (`docs/platform/bus-events.md` §4.3); every consumer in the umbrella has since
  migrated. A consumer that may still receive a legacy map — one reading events
  relayed from another node, or injected through the control plane's
  `events.ingest` — coerces once at its entry point with
  `LemonCore.Events.coerce/2`, which is unchanged, as are the per-payload
  `new/1` (strict, publishers) and `from_map/1` (lenient, nested-aware)
  constructors. Removing the shim is what makes a payload field rename a compile
  error at the place that maps it, rather than a silent `nil` on the wire.
- **Breaking: every telegram/discord/xmtp concept is gone from `lemon_core`.**
  This closes the first clause of the plan's Phase 1 "done when"
  (`docs/platform-split.md`). Specifically:
  - `LemonCore.Config.Gateway` lost the `:telegram`, `:discord`, `:xmtp`,
    `:enable_telegram`, `:enable_discord` and `:enable_xmtp` struct fields, and
    the resolvers behind them, in favour of `:channels`/`:enabled_channels` and
    the `Gateway.Channel` behaviour above. `LemonCore.Config`'s legacy gateway
    map is unchanged for a build that registers those channels.
  - `LemonCore.Config.Validator.validate_telegram_config/2`,
    `validate_discord_config/2` and `validate_xmtp_config/2` are removed; each
    section is validated by its own channel module.
  - `LemonCore.Doctor.ChannelDiagnostics`, `LemonCore.Doctor.ChannelReadiness`
    and `LemonCore.Doctor.Checks.Channels` moved to `lemon_channels`; core
    resolves the first two through `:doctor_runtime` and receives the check
    through `:doctor_checks`. `mix lemon.channels` moved with them.
  - `LemonCore.InboundMessage.from_telegram/3` is removed. It had no callers:
    adapters build the struct directly, which is what the moduledoc now
    documents.
  - The eight `LEMON_GATEWAY_ENABLE_{TELEGRAM,DISCORD,XMTP}` and
    `LEMON_TELEGRAM_COMPACTION_*` declarations moved out of
    `LemonCore.Env.Declarations` to the registry of the app that now reads
    them, per plan 1.9's rule that ownership follows the reader.
  - `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN` and `XMTP_WALLET_KEY` left
    `HermeticEnv`'s built-in scrub list for the `:test_credential_env_vars`
    registration described above.
  - `LemonCore.Quality.ArchitectureRulesCheck` gained
    `:core_vendor_channel_reference`, which fails the quality gate on any
    mention of a chat platform under `apps/lemon_core/lib`, and retired
    `:core_telegram_store_leak` / `:core_telegram_resume_index_leak`, which the
    broader rule subsumes (`:core_known_target_store_leak` keeps the
    non-vendor half).

### Known gaps

- Secrets key rotation and re-encryption are not implemented; the gap is
  documented in `LemonCore.Secrets`'s moduledoc.
