# Changelog

All notable changes to `lemon_core` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

### Security

- URL query assignments now classify `&`-separated `key=value` pairs independently,
  retaining public pairs after unquoted sensitive values in default, `drop_keys`
  and strict modes. Only conservative unquoted URL characters qualify; queries
  containing quotes, fragments or ambiguous syntax retain the legacy output.
  The exact redaction marker is an inert value, quoted or unquoted, preserving
  idempotence without admitting other quoted values. Recognition is frozen on
  the original input so earlier redactions cannot create query context.
  Strict sensitivity, including session/private keys in queries, remains unchanged,
  as do ordinary sensitive-key rules and non-query assignment extents.
- `LemonCore.Redact.text/2` runs a linear-time tokenizer after the regex pass,
  so percent-encoded keys and delimiters (`%74oken=…`, `token%3D…`,
  `%access_key`), assignments nested behind a non-sensitive wrapper
  (`message%20text="api_key=first second"`) and shell-quoted `&`-joined
  assignments are redacted; output is never less redacted than before.
- The redaction tokenizer scans binaries directly instead of building per-byte
  tables, skips views that cannot contain a sensitive key, and decodes a view
  only when it has a hex escape: `Redact.text/1` on 300 KB of mostly plain
  multibyte text with one credential takes about 1 ms instead of 80-200 ms, so
  large session snapshots, event projections and memory writes no longer stall.

### Added

- Optional destination-local provider management boundary with bounded write-only
  credential requests and a durable controller target identity. Provider setup
  remains runtime-optional; core does not depend on the CLI application.
  Node-registry crash/status diagnostics redact request messages, reasons and state.

- `LemonCore.ExecApprovals.expire_owner/1` expires every pending approval of an
  ended run (`{:run, run_id}`) or native session (`{:session, session_id}`) at
  once, with no grace window: the record becomes a redacted `:expired` receipt,
  a live waiter is denied, nothing is granted and `resolve/3` returns
  `{:error, :expired}`. `:approval_resolved` carries the new
  `decision: :expired` (`Events.ApprovalResolved.decisions/0`), and requests with
  `expires_in_ms: :infinity` are covered. `LemonCore.ExecApprovalExpiry` is the
  supervised router for the two end signals: the `LemonCore.Store` finalize-run
  hook (`{LemonCore.ExecApprovalExpiry, :handle_finalize_run}`, wired in
  `config/config.exs`) and `session_ended/1`. Expiry races a resolver or timeout
  through the same atomic exact-record transition: first writer wins.
- `[runtime.tools.semantic_find]` (`enabled` default `false`, optional `model`,
  `max_tokens` 512-200000, default 8000) configures the opt-in `semantic_find`
  coding tool; the `read_only` and `minimal_core` tool profiles allow it when it
  is enabled.

- `LemonCore.Secrets.get_with_revision/2` and `set_if_revision/4` provide
  incarnation-bound conditional credential saves. A revision is scoped to the
  Store process, owner and name; usage reads preserve it, while replacement
  (including identical plaintext), deletion/recreation and storage restart
  invalidate it. Conditional saves share the existing secrets/key-rotation
  mutation lease and use Store's atomic compare-and-swap.

### Fixed

- Markdown session export now backslash-escapes special characters (`_`, `*`,
  backticks, brackets, `<>`, `#`) instead of emitting a literal `\1`
  backreference in place of the character (#64).
- Failed provider-credential mutations restore secret metadata through the owning
  encrypted store, preserving the original provider, timestamps, usage and
  absolute expiry. A credential expiring during compensation remains expired
  instead of becoming an immortal credential.

- Restore refuses before staging or changing state while a source or packaged
  launcher daemon owns the target, including relocated/root-relative stores,
  explicit database file symlinks, unhealthy or starting runtimes, and custom
  runtime PID files. Launcher ownership records are preserved on rejected
  starts. Lifecycle locks in both invoking and target homes prevent startup
  racing file replacement or rollback even when the launcher uses a different
  `HOME`. Backup CLI dispatch no longer bootstraps runtime credentials; refusal
  gives actionable stop/retry guidance.
- Serialize bounded `Bus.Delivery` admission so concurrent publishers below
  capacity do not spuriously trigger overflow recovery. Pending admission has
  bounded reservations and a five-second wait; workers monitor their creator
  and consumer and release blocked publishers when the handle closes.
- Approval expiry reconciles durable pending records on daemon recovery, rejects
  earlier-runtime owners before installing grants, and restores live session
  monitors on expiry-worker restart. Forced session termination and finalized
  runs without a session-history key now expire infinite-deadline requests too.
  Native owner lookup uses the registered agent runtime provider, keeping core
  independent of the native session registry.

- `LemonCore.Backup` snapshots SQLite databases (identified by file header)
  with `VACUUM INTO` instead of a raw file copy, so a backup taken while a
  WAL-mode writer is active is internally consistent. Live `-wal`, `-shm`, and
  `-journal` sidecars of a snapshotted database are excluded from the bundle
  (counted as `sqlite_sidecar`); other files keep the byte-exact copy and
  unchanged-during-copy check. The bundle format, credential inclusion, and
  overwrite/manifest-digest confirmation are unchanged.
- Restore treats stale SQLite `-wal`/`-shm`/`-journal` files beside a database
  it is about to install as overwrite conflicts, displacing them to the
  rollback directory so an old WAL is never replayed into restored data.
  Sidecars the manifest itself lists (bundles written before the `VACUUM INTO`
  change) are bundle content and are classified and installed normally, so
  committed WAL-only rows are never dropped.
- `LemonCore.NodeRegistry` name-or-ID selectors resolve an exact live durable
  ID before a unique live name; an authorized durable ID never falls back to
  another node's name while offline. `native_privacy_context_supported?/1` is
  the single native privacy-descriptor predicate shared by admission and
  pinned dispatch.
- `LemonCore.Durable` performs real descriptor `fsync` plus Darwin `F_FULLFSYNC`
  through its packaged Python 3 helper for files and directories. JSONL sync
  and atomic file-key durability can therefore complete on supported macOS
  filesystems instead of unconditionally refusing Darwin. Unsupported/refused
  barriers remain errors; no plain/global-sync fallback or private-path output.
- Secret reads distinguish backend failure from missing credentials, and set,
  conditional save, deletion and expiry cleanup return persistence failures
  instead of acknowledging an unsuccessful mutation. Reads never remove
  expired records; list cleanup and deletion conditionally remove their exact
  snapshot under the shared mutation lease so a newer replacement survives.
  Conditional saves retain durable operation receipts, deletion preserves them
  in value-free tombstones, and list cleanup leaves receipt-bearing expired
  records unchanged and hidden so historical proof remains available.
- Conditional credential saves recheck the original record's expiry immediately
  before each compare-and-swap, including after blocked key resolution, so a
  refresh cannot revive a credential that expired while encryption was pending.

- Filesystem checkpoints capture bounded recursive directory trees, preserving
  empty directories, modes and symlink identity without following targets.
  Restore validates selected snapshots and parent paths before mutation and
  removes newly created trees when the recorded root was absent. Defaults:
  10 MiB/file, 50 MiB aggregate, 10,000 entries, depth 128 per capture.

## [0.2.0] - 2026-10-13

First release as a standalone package. `lemon_core` used to be the umbrella's
catch-all shared app; this release turns it into a library you can embed. The
theme of every change below is the same: nothing in `lemon_core` knows about
Telegram, run history, durable memory, kanban boards, or `~/.lemon`.

### Fixed

- Shared `LemonCore.Redact` text, nested-data, and sensitive-key APIs now provide
  one credential policy for session/config/profile exports and diagnostics,
  including complete private-key blocks and quoted assignment values. Export
  allowlists and size limits remain owned by their callers.
- Installable from Hex. The `0.1.0` release's `mix.exs` began with
  `Code.require_file("../../hex_package.exs", __DIR__)`, a file that was not in
  the package, so it failed to load in every consumer project; `0.1.0` is
  retired. The shipped `mix.exs` is now self-contained.

### Removed

- This repository's own tooling is no longer in the package: `LemonCore.Quality.*`,
  `LemonCore.Update.*`, and the `mix lemon.quality`, `lemon.architecture.docs`,
  `lemon.check_duplicate_tests`, `lemon.update`, `lemon.bench` and `lemon.help`
  tasks. They remain in the lemon repository.
- Vendor CLI wrapper extension points. Subagent tasks now execute natively, and
  `[runtime.cli]` is rejected.
- `LemonCore.Store`'s domain functions: `put/get/delete_chat_state`, the
  agent/channel/session/runtime `*_policy` functions, and
  `put/delete_progress_mapping` / `get_run_by_progress`. Use
  `LemonCore.ChatStateStore` and `LemonCore.PolicyStore`, which now sit on the
  generic table API; the progress mapping moved to its only consumer (see
  below). The `:chat_state_ttl_ms` store option is gone; chat state always
  expires after 24 hours.
- `LemonCore.Quality.RatchetCheck`, `ArchitectureRulesCheck`,
  `StoreTableOwnershipCheck`, `DocsCatalog`, and `Cleanup`, plus the
  `mix lemon.ratchet` and `mix lemon.cleanup` tasks. `mix lemon.quality` now
  runs only the docs link check, the architecture docs check, the `deps/0`
  policy check, and the duplicate test module guard. `DocsCheck` no longer
  reads `docs/catalog.exs` or enforces review dates.

### Fixed

- `LemonCore.Backup` digests files with `File.stream!(path, bytes)` instead of
  the deprecated `File.stream!(path, modes, bytes)` order, so Elixir 1.20 no
  longer prints a deprecation warning into `lemon backup` JSON output.
- Run finalization is now synchronous and retry-safe. A session-index failure
  is returned to the caller, retrying repairs the index without double-counting
  the run, conflicting summaries fail without exposing the original summary,
  and finalize hooks explicitly use at-least-once delivery. The per-session
  idempotency marker is bounded to the last 32 run ids, so a session index
  entry no longer grows with every run the session has ever finalized.

### Added

- `LemonCore.Secrets.KeyRotation` rotates the secrets master key: `preview/1`
  checks that every stored secret decrypts with the current key and returns a
  confirmation token bound to the key and the exact record set; `rotate/2`
  re-encrypts every secret under a generated key and writes it to the provider
  that supplied the current one. It refuses while a Lemon runtime answers on
  the control port, fails closed on any undecryptable record, leaves external
  sources and environment fallback alone, makes staged ciphertext durable
  before the key moves, confirms the switch against the provider it wrote, and
  converges every record to the new key, so every secret stays readable by
  whichever key loads next if it is interrupted (`Secrets.get/2` reads the
  staged copy). New task: `mix lemon.secrets.rotate_key [--confirm TOKEN]`.
- `LemonCore.Secrets.Lock`: a Store-backed lease, exclusive across OS
  processes on a SQLite store, held by key rotation and by `Secrets.set/3`
  around key resolution and persistence. A lease never expires; it is
  reclaimed only from a holder that is provably gone on this host. `set/3`
  can now return `{:error, :secrets_locked}` (a live holder outlasted the
  30 s wait, configurable as `write_lock_wait_ms`) or
  `{:error, {:secrets_lock_held, host}}` (a lease from another host).
- `LemonCore.Store.sync/1` durability barrier and optional
  `LemonCore.Store.Backend` callbacks `compare_and_swap/5` and `sync/1`. The
  SQLite backend implements compare-and-swap in one `BEGIN IMMEDIATE`
  transaction (atomic across OS processes) and `sync/1` as a `TRUNCATE` WAL
  checkpoint; JSONL fsyncs its table files and directory; ETS answers `sync/1`
  trivially. `LemonCore.Secrets.MasterKey.fetch_from/2` reads one provider's
  key, and `LemonCore.Durable` provides file and verified synchronous
  directory flushes (GNU coreutils `sync DIR`; never claimed on macOS).
- `LemonCore.Contract` centralizes loadability and required-callback checks for
  configuration-injected implementations. `LemonCore.EngineRuntime.validate/1`
  exposes the check used by router startup; optional callbacks remain optional,
  and invalid behaviour metadata returns a structured error instead of escaping
  the validation boundary.
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

### Changed

- `LemonCore.Secrets.KeyProvider.File` replaces the key file through a synced,
  `0600` temporary file, an atomic rename and, where the host has one, a
  synchronous directory flush. Key rotation of a file key refuses on hosts
  without that flush (macOS): keep the key in the Keychain there.
- The SQLite backend finishes its single-row read statement after every
  `get/3`, and resets cached statements before `BEGIN IMMEDIATE` and WAL
  checkpoints, so a read no longer pins a stale snapshot that turned the next
  write on that connection into `:sqlite_busy`. Its connections set
  `checkpoint_fullfsync`, so the `sync/1` checkpoint reaches stable storage on
  macOS too.
- **Breaking for custom key providers:** `use LemonCore.Secrets.KeyProvider` no
  longer defines a default `put/2` returning `{:error, :unavailable}`; read-only
  providers simply omit it, and `KeyProvider.supports_put?/1` now reports real
  writability. Secret reads update usage metadata with compare-and-swap, so a
  read never overwrites a concurrent write.
- `LemonCore.RouterBridge.configure/1` validates the router and run
  orchestrator against explicit behaviours before registration. Command
  functions return `:ok` only for an exact `:ok` callback result. A malformed
  mutation acknowledgement is now `{:error, :outcome_unknown}` because the
  callback may already have applied the side effect; malformed query results
  remain `{:error, {:unexpected_answer, value}}`.
- `LemonCore.RouterBridge` now distinguishes an unregistered router from a
  configured mutation that lost its acknowledgement. Raised, thrown,
  malformed, timed-out, or exited mutations return
  `{:error, :outcome_unknown}` and must not be retried without independent
  idempotency or reconciliation; even a `:noproc` exit may follow an earlier
  side effect inside the callback.
  Successful run submission is normalized to a non-empty binary run id, empty
  session/run keys return structured validation errors, active-session lists
  require non-empty binary ids in every entry, and bridge failure logs contain
  only a safe callback MFA and failure class. Query exceptions return the fixed
  `{:error, :query_failed}` rather than exposing exception contents.
- `LemonCore.RouterBridge.session_busy?/1` now returns
  `{:ok, boolean()} | {:error, term()}`. `active_run/1` and
  `list_active_sessions/0` likewise report `{:error, :unavailable}` instead of
  inventing `:none` or `[]` when the router cannot be consulted. These are
  intentional public return-shape changes; callers must decide how unknown
  router state maps to their own interface.
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
- `LemonCore.ProgressStore` — moved to its only consumer, the (unpublished)
  `lemon_gateway` app, as `LemonGateway.ProgressStore`. `:progress` is no
  longer in `LemonCore.Store`'s default cached tables; gateway registers it
  with `register_cached_table/2` at boot, like any other owner's hot index.
- `LemonCore.Doctor.Checks.Memory` and `LemonCore.Doctor.Checks.Skills` are no
  longer built-in checks. They moved to `lemon_memory`
  (`LemonMemory.Doctor.Checks.Memory`) and `lemon_skills`
  (`LemonSkills.Doctor.Checks.Skills`) and register through
  `config :lemon_core, :doctor_checks`; the `:memory_store` key of
  `:doctor_runtime` is no longer read. The remaining core-resident stores,
  `ConfigReloader` and doctor diagnostics stay because a consumer outside their
  target app (or core itself) still uses them; `docs/platform-split.md`
  ("Known gaps") lists the blocking consumer for each.
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
