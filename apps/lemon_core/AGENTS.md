# LemonCore contributor guide

Core owns shared contracts, config, secrets, Store, Bus and lifecycle services.
It has no umbrella dependencies. Browser/media/LSP drivers live in their own
apps; optional consumers register at runtime. See [README](README.md),
[configuration](../../docs/config.md) and [architecture boundaries](../../docs/architecture_boundaries.md).

## Config and profiles

- `Config.Modular` is the canonical implementation; `Config` is its facade.
  Precedence is environment > project `.lemon/config.toml` > user
  `~/.lemon/config.toml`. Cached reads and explicit reload are distinct.
- Config defines defaults, not current session/chat policy. Use `PolicyStore`
  for runtime overrides; do not add a second app-env policy plane.
- Platform channel modules resolve/validate their own `[gateway.<id>]` sections
  through the registered config behavior, rather than growing core vendor code.
- Deprecated config sections fail with migration guidance, not silent fallback.
  Preserve unknown TOML keys/comments when changing a selected profile table.
- `ProfileStore` is metadata/filesystem service, not a runtime orchestrator.
  Validate IDs before deriving paths, reject symlink/special homes, serialize
  writes per config path and atomically replace in the same directory.
- Profile deletion requires exact-ID confirmation and moves the home to trash
  before config removal. Exports omit sessions, memory, binaries, artifacts and
  secret-like paths; redact the selected text/config/skill files.

## Secrets and redaction

- Secrets use AES-256-GCM with per-secret salt/HKDF. Master keys are base64
  32-byte values; raw strings need explicit legacy opt-in. Master-key rotation
  goes through `Secrets.KeyRotation` only: preview token bound to the exact
  record set, fail closed on any undecryptable record, durable staged copies
  before the key moves, and records stay readable by the next-loaded key at
  every step (staged ciphertext fallback). Writers that encrypt (`set/3`) hold
  `Secrets.Lock` from key resolution to persistence; never write secret
  records around it.
- Master-key lookup is Keychain, env, then private key file. On non-Keychain
  hosts, the launcher normalizes env from canonical `~/.lemon/secrets_master_key`.
  Preserve 0600 permissions. See [resolution contract](../../docs/security/secrets-and-keychain.md).
- Secret resolution is encrypted store, explicitly enabled external sources in
  priority/id order, then env. A source error stops resolution; only a successful
  missing result proceeds. `env_fallback: false` disables both fallback kinds.
  Bootstrap auth uses `resolve_local/2` to prevent recursion.
- External source programs are argv-only, supervised and bounded in time/output.
  Never copy their stdout/stderr into errors, logs or diagnostics. Cache defaults
  off and is bounded/process-local.
- `Secrets.EnvCatalog` owns operator import/check names; `Env` declarations are
  release-dependent runtime configuration, not that credential catalog.
- Secret lists/status/tests expose presence and safe metadata, never values or
  prefixes. Reads update usage metadata, not the secret's modification time.
- Use the shared redaction boundary for secret-bearing text/maps. Redaction does
  not replace domain allowlists, output limits or authorization checks.

## Persistence and lifecycle

- Domain stores are ordinary modules over the generic Store table API. Shared
  callers use their owner wrapper, not ad-hoc table access or domain methods on
  `LemonCore.Store`. Agent workspace stores belong in `lemon_agent`; channel
  indices belong in `lemon_channels`; the progress-message index belongs in
  `lemon_gateway`. Owners register hot tables with `register_cached_table/2`.
  A store stays in core only while a consumer outside its target app needs it
  (see platform-split "Known gaps"); doctor checks for other apps' domains
  live in those apps and register through `:doctor_checks`.
- Operator session list/search/stats/export/prune uses `SessionLifecycle`.
  Reads are bounded/redacted; stats preserve exact totals with capped dimensions.
  Delete requires exact-key confirmation and verified completion; prune requires
  the preview's exact candidate token and millisecond cutoff.
- Distinguish strict persistence failures from absence when enforcing durable
  uniqueness, replay fences or destructive confirmation. A missing-looking
  compatibility read is not evidence that a mutation is safe to repeat.
- SQLite decode failures remain explicit corruption errors. Preserve atom/tuple/
  struct keys through the backend codec; do not substitute lossy JSON encoding.
- Expired chat state is deleted by compare-and-delete so a concurrent refresh
  survives. Run finalization remains serialized and idempotent with bounded
  recent-run indexing, not a lifetime-growing set.
- Backup restore verifies the complete bundle before mutation. Credentials are
  opt-in; overwrite permission binds manifest digest and expanded destination.
  See [backup contract](../../docs/user-guide/backups.md).

## Runtime and event boundaries

- `RouterBridge` lets producers call registered router behavior without a compile
  dependency. Success requires a non-empty binary run ID. Unregistered means
  unavailable; a configured mutation that raises/exits/throws/times out or returns
  malformed acknowledgement is `:outcome_unknown`, even for `:noproc`.
- Unknown mutation outcomes may already have side effects: retain fixed identity
  and reconcile; never retry without independent idempotency. A definite returned
  error promises no mutation. Abort/keepalive `:ok` acknowledges dispatch, not
  synchronous application by the target process.
- Query failures stay unavailable/query-failed, never silently idle/empty. Logs
  and errors exclude callbacks, arguments, stacktraces and raw exception reasons.
- Exec approval resolve/cancel/expiry is atomic, first-writer-wins. A losing
  transition installs no grants. Timeout and owner-end expiry broadcast
  resolution so clients clear pending UI. A pending approval expires at once
  (`decision: :expired`, no grace window) when its run (Store finalize-run hook)
  or native session (process monitor, including forced shutdown) ends, through
  `ExecApprovalExpiry`. Recovery expires earlier-runtime pending records but
  preserves live owners across expiry-worker restarts. Audit payloads contain
  hashes/IDs/decisions, not
  commands or prompt text.
- Bus envelopes use millisecond wall-clock timestamps. In-memory dedupe TTL uses
  monotonic time; durable idempotency uses wall-clock time. Do not mix clocks.

## Verification and packaging

From the umbrella root: `mix test apps/lemon_core/test`.
Use existing isolated store/testing helpers; test crash/restart and concurrent
mutation boundaries with explicit synchronization. Restore global config/env.

Core is one of five published packages (0.2.0 on Hex);
keep package metadata self-contained and optional dependencies optional.
`scripts/verify_packages` exercises consumers of actual tarballs. See
[package status](../../docs/platform-split.md).
