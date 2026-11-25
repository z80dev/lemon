# Secrets and Keychain Contract

This document defines the tested contract for Lemon secret resolution
across keychain, encrypted store, explicitly enabled external sources, and
environment fallback paths.

## Flow Matrix

| Layer | Write Path | Read/Resolve Path | Fallbacks | Primary Files |
|---|---|---|---|---|
| macOS Keychain master key | `LemonCore.Secrets.MasterKey.init/1` -> `Keychain.put_master_key/2` | `LemonCore.Secrets.MasterKey.resolve/1` -> `Keychain.get_master_key/1` | On `:missing` / `:keychain_unavailable` / command failures, tries env master key, then local file | `apps/lemon_core/lib/lemon_core/secrets/keychain.ex`, `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Master key env fallback | Manual set of `LEMON_SECRETS_MASTER_KEY` (external) | `MasterKey.resolve/1` via `resolve_from_env/1` | On missing env, tries `~/.lemon/secrets_master_key`; malformed env still fails as `:invalid_master_key` | `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Local master key file fallback | `~/.lemon/secrets_master_key` | `MasterKey.resolve/1` via local file fallback | Returns `:missing_master_key` or `:invalid_master_key` when no valid source exists | `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Encrypted secret store | `LemonCore.Secrets.set/3` (AES-256-GCM at rest) | `LemonCore.Secrets.get/2`, `resolve/2`, `exists?/2` | `resolve/2` uses store, enabled external sources (`external_fallback`, default `true` independently of `env_fallback`), then same-name env when `env_fallback: true`. Only a definite store miss (`:not_found`) continues past the store; `:expired` does so only with `expired_fallback: true` | `apps/lemon_core/lib/lemon_core/secrets.ex` |
| External secret sources | Read-only; no external result is persisted | `LemonCore.Secrets.External` invokes 1Password, Bitwarden, or argv-only command adapters under shared supervision | Ordered by priority/id; a source miss continues, but any enabled-source failure stops before env fallback. An invalid or unloadable `[secrets]` table (including unreadable or invalid TOML) returns `{:external_source, :invalid_config}`, never a miss; a validation failure in an unrelated section does not, because `[secrets]` is then re-read from the same trust-filtered merge. A 1Password source is consulted only for names in its `refs` and runs one `op read` for the requested ref; the supervising task waits for the sum of its helper timeouts | `apps/lemon_core/lib/lemon_core/secrets/external.ex`, `apps/lemon_core/lib/lemon_core/secrets/source_runner.ex` |
| External bootstrap credentials | Existing Lemon encrypted secret or same-name env only | `LemonCore.Secrets.resolve_local/2` from a source adapter | Never invokes an external source, preventing recursion; reads env only after a definite store miss, so an unreadable stored bootstrap credential fails the source with `:bootstrap_secret_missing` | `apps/lemon_core/lib/lemon_core/secrets.ex`, `apps/lemon_core/lib/lemon_core/secrets/source/` |
| Coding Agent provider secret refs | Configured `api_key_secret` / `oauth_secret` names in provider config | `LemonAgent.ModelRuntime.Credentials` -> credential-aware OAuth resolution | Ordinary API-key refs use store, enabled external sources, then env; pool `secret:` refs, raw-key secrets and selected OAuth refs consult external sources but never use same-name env fallback. A store or source failure (or a crash in resolution) yields no credential; no caller re-reads the environment | `apps/lemon_agent/lib/lemon_agent/model_runtime/credentials.ex` |

## Selected Login Authority

With `auth_source = "oauth"`, the selected login is authoritative for model
requests. A missing, expired or rejected login fails before provider HTTP; static
keys, ambient API-key variables and legacy/default secrets cannot replace it.
Encoded OAuth records are resolved to access credentials, not sent as raw JSON.
This refusal also applies when the model otherwise allows keyless requests.

Runtime options mark this selection with `api_key_authoritative`. The per-request
credential callback supplies the concrete token. A `nil` or empty-string refusal
cannot revive an earlier authoritative token; ordinary non-authoritative callbacks
retain their cached-key fallback. The options builder does not fetch the login again.
API-key fields returned by `StreamOptions.ProviderSettings` retain the same authority
marker and use credential-aware secret resolution; project/service-account
secret fields retain their existing raw-data contract.

Explicit credential-pool/default routing policy is unchanged: an unavailable
pool entry may still use the separately configured usable default credential.
Normal API-key and keyless requests keep their existing resolution behavior.
Low-level Anthropic-protocol calls use only the target provider's environment
variables; `ANTHROPIC_API_KEY` is not an implicit key for Kimi or another provider.

Setup verification uses the same credential resolver and effective provider/model
configuration as native requests. Its lightweight models request sends the resolved
access credential, never the stored OAuth record or refresh token. An unavailable
selected login fails verification before HTTP; it is not a successful skipped check.
Explicit offline verification and legitimate keyless endpoints remain supported.
Credential-pool/default policy and provider/model header precedence are unchanged.

## Keychain Error Semantics (Current Contract)

`LemonCore.Secrets.Keychain` maps command outcomes to stable errors:

- Exit code `44` -> `{:error, :missing}`
- Non-zero exit codes -> `{:error, {:command_failed, code, stderr_or_output}}`
- Timeout (`Task.yield` expiry) -> `{:error, :timeout}`
- Non-macOS / missing `security` executable -> `{:error, :unavailable}`
- Empty retrieved value -> treated as missing (`{:error, :missing}`)
- Exit code `45` (errSecDuplicateItem) on `add-generic-password` -> `{:error, :eexist}`. `put_master_key/2` never passes `-U` unless called with `force: true` (key rotation), so an existing item is never replaced by `init`.

## Master Key Resolution Precedence

`LemonCore.Secrets.MasterKey.resolve/1` order:

1. Keychain (`:keychain` source)
2. `LEMON_SECRETS_MASTER_KEY` (`:env` source)
3. `~/.lemon/secrets_master_key` (`:file` source)
4. Error (`:missing_master_key`, `:invalid_master_key`, or `{:keychain_failed, reason}`)

The chain itself is configurable — providers implement `LemonCore.Secrets.KeyProvider`:

```elixir
config :lemon_core, :secrets,
  key_providers: [:keychain, :env, :file],
  key_file: "~/.lemon/secrets_master_key",
  env_var: "LEMON_SECRETS_MASTER_KEY"
```

Additional nuance:

- The keychain provider is macOS-only and skips itself on other platforms, so a Linux host with no key configured reports `:missing_master_key` rather than a keychain failure.
- If keychain returns malformed key material, env fallback is attempted first; only then returns `:invalid_master_key`.
- Key material must be base64-encoded 32-byte data. Raw passphrase-like strings are rejected with `:weak_master_key` (there is no password stretching); `allow_legacy_raw_keys: true` restores the old behaviour for setups that already encrypted secrets under such a value. `lemon secrets rotate-key` moves such a setup onto a generated key.
- `status/1` suppresses expected keychain absence (`:missing`, `:keychain_unavailable`) from `keychain_error` while still surfacing hard failures.
- One precedence contract for every entry point (`bin/lemon`, `bin/lemon-gateway`, the release, CLI, Mix tasks, runtime): launchers never choose a key. `bin/lemon` (which `bin/lemon-gateway` runs) only reads the default Keychain item and passes it in `LEMON_SECRETS_KEYCHAIN_PRELOAD`, which stands in for the keychain provider's own read at its configured position (long-lived BEAM processes may be denied Keychain access). If a later provider holds a different valid key than the one that answers, resolution fails with `{:conflicting_master_keys, sources}` instead of letting provider order decide.
- `status/1` reuses its Keychain lookup when resolving the active source.
- CLI setup commands use `MasterKey.scoped/1`: Keychain results (including failures)
  are cached only in the caller for the command lifetime, nested scopes share the
  cache, and successful initialization replaces a cached miss. Cleanup also runs
  on exceptions. Diagnostic `resolve/1` and `status/1` remain fresh outside a
  scope; encrypted-secret reads use the runtime cache below.

### Runtime read cache and usage metadata

Encrypted-secret reads use `MasterKey.resolve_cached/1`: one successful resolved
key is retained in the supervised `LemonCore.RuntimeCache` ETS table, shared by
callers with identical options and provider configuration. A warm read does not
invoke any key provider or spawn `security`. Different options replace the single
cache entry rather than growing an unbounded key cache; failures are not retained.
Cache-owner restarts discard the entry; without the owner, reads resolve uncached.
External changes to a key file or Keychain entry require
`MasterKey.resolve_fresh/1` or a cache-owner restart.
Use supported key rotation rather than replacing a key in use.

Writers continue to resolve the key freshly while holding `Secrets.Lock`, then
invalidate the read cache. This preserves the shared SQLite lease's protection
against another OS process rotating the key. An already-cached reader can still
run while a writer is resolving its key. Rotation invalidates before switching
keys and again on exit, inside the mutation lease, and serializes cache misses
with that transition. This also prevents an in-flight lookup from republishing
the retired key after a successful or interrupted switch. A read that waited
behind rotation re-fetches a changed ciphertext snapshot if needed.

Reads cast usage touches to supervised `LemonCore.Secrets.Usage`; they do not wait
for a metadata write. The worker coalesces identical snapshots per pinned Store
process and secret over a 100 ms batching interval, then performs one exact-record
CAS per pending secret. Counts and last-used timestamps are eventually visible,
remain best effort, and may be lost on conflicts, worker restart or shutdown.
Delayed touches never restore deleted credentials, overwrite replacements or
undo staged ciphertext. No usage touch changes the credential revision,
modification timestamp or secret-change Bus digest. These counters are not an
audit log; credential writes and rotation retain their durability requirements.

## Operator Notes

- `lemon secrets init` is the preferred bootstrap path everywhere: it stores the generated key in the keychain on macOS and writes the key file (`0600`) on other platforms. It first reads every configured provider and refuses with `:master_key_exists` when any holds key material (usable or not, including an env var, an empty or unreadable key file, or a dangling key-file symlink), and with `{:master_key_check_failed, reason}` when a provider cannot be read (for example a transient Keychain failure). Only `--force` replaces a key; forcing a new key makes existing secrets unreadable, so change a key in use with `lemon secrets rotate-key` instead. `lemon setup` auto-initializes only when resolution reports `:missing_master_key`; any other key error is reported with `lemon secrets status` guidance.
- Initialization is race-free: `init`, key rotation and a backup restore hold the cross-process key lock (`.secrets_master_key.lock` next to the key file), the key file is published with a hard link that never replaces an existing file unless `force: true`, and a failed occupancy check is an error (`{:key_file_check_failed, reason}`). Backup restore installs every file with a no-replace hard link, so a key that appears after its conflict check is never replaced.
- Store key verifier: a reserved `:key_check` row in the secrets table holds HMAC-SHA256 of a fixed label under the store's master key. It is kept through secret deletion and expiry. `Secrets.set/3`, `set_if_revision/4` and `restore/3` refuse with `:master_key_mismatch` when the resolved key does not match it; reads report `:master_key_mismatch` instead of `:decrypt_failed`, and `Secrets.resolve/2` / `resolve_local/2` return that error instead of falling back to external or environment credentials. A store without a verifier (written before this change) is migrated by the first write whose key opens every live record; any other key is refused. Rotation checks the verifier and records the pending new key durably before switching (`next`); how a pending switch is settled is described below. Rotation also refuses with `{:multiple_key_sources, sources}` when a second provider holds a key.
- Fail-closed fallback: `Secrets.resolve/2` and `resolve_local/2` continue to external sources or the environment only after a definite store miss (`:not_found`, or `:expired` with `expired_fallback: true`). Every other store error — `:decrypt_failed`, `:invalid_payload`, `:invalid_secret_record`, `:store_unavailable`, `:missing_master_key` (a record exists but no key is configured), `:lock_timeout`, `:master_key_mismatch`, `{:conflicting_master_keys, _}`, `{:keychain_failed, _}`, `{:key_provider_failed, _, _}`, `:invalid_master_key`, `:weak_master_key` — is returned as is, because a stored credential may exist and answering with a different identity would hide the failure. `exists_local?/2` reports the same outcome as `resolve_local/2`.
- Consumer fallback chains (model credentials and provider config, web fetch/search tools, gateway voice/SMS/AI, Discord, XMTP, live evals) keep the tagged `Secrets.resolve/2` result and advance to the next candidate (another secret alias, inline config, an environment variable or another provider) only on `{:error, :not_found}`. Any other error or a crash leaves no credential, so for example an unreadable configured Twilio token never lets an ambient `TWILIO_AUTH_TOKEN` verify webhook signatures. Presence checks that describe the encrypted store only (tool auth, doctor provider diagnostics) pass `external_fallback: false`.
- Rotation clears its pending verifier only when the provider reported a failure before attempting the write (`:unavailable`, `:invalid_value`) and still holds the old key. Every other unsuccessful outcome — timeouts, `{:command_failed, ...}` and other wrapped or unknown errors — stays pending (`{:key_switch_unverified, source}`) even when the old key is observed afterwards, because the write may still land. While a switch is pending, secret writes return `:key_rotation_incomplete`, and a new rotation is admitted only once the provider holds the pending new key; under the previous key it is refused with `:key_rotation_unresolved`, so a retry can never replace the staged ciphertext a delayed write needs. Settle it with `lemon secrets rotate-key --resume` (or `mix lemon.secrets.rotate_key --resume`), which commits once the provider holds the new key, or `--abandon --confirm-abandon`. Rotation and recovery read the providers directly and ignore the launcher's `LEMON_SECRETS_KEYCHAIN_PRELOAD`.
- `--abandon` asserts that the earlier write of the new key was cancelled and can never land (the rotation crashed before switching, or the process that issued the write is gone). It always prints a warning, acts only with `--confirm-abandon`, and requires the provider to still hold the previous key. Before confirming, establish that the write was cancelled and securely preserve a copy of the current master key and of the secrets store. Abandoning does not make the store safe against a write that lands later: records not rewritten since keep a staged copy the new key opens, but every record written after abandoning is encrypted under the previous key only, and the store's verifier rejects the new key.
- Backup restore holds the key lock for the target root and for the configured key file's directory (nested paths such as `~/.lemon/keys/master` included), and its rollback also uses no-replace links.
- An unreadable key file is reported as `{:key_file_unreadable, reason}` (a provider failure), not as a missing key.
- For local non-macOS development, keep `~/.lemon/secrets_master_key` as the canonical master key file and do not also set `LEMON_SECRETS_MASTER_KEY` to a different value: every entry point reads the file through the file provider, and a conflicting env key makes resolution fail.
- `lemon secrets sources status|test` returns only source readiness,
  provenance, counts, byte counts, duration, and stable error kinds. Combined
  stdout/stderr and resolved values are never included.
- External commands are direct argv execution with exact configuration,
  minimal child environments, `100..30000` ms timeouts, `1..1048576` byte
  output bounds, and an optional bounded process-local cache that defaults off.
- If keychain prompts are denied (`User interaction is not allowed`), Lemon can still operate via env fallback when configured.
- Development Mac builds are ad-hoc signed and can prompt for Keychain access
  again after each rebuild. This is distinct from the worker's
  [macOS privacy permissions](agent-safety-contract.md#macos-permissions).
  Signed releases retain a stable signing identity and avoid that rebuild
  re-prompt; no signed DMG is published yet.

#### Recovering from a late publication after `--abandon`

Symptom: secret reads and writes fail with `:master_key_mismatch` and the key provider holds a key you did not expect (the abandoned new key landed).

1. Stop every writer: the runtime (`lemon stop`) and any CLI or Mix command that sets secrets.
2. Preserve both keys and the state: copy the key the provider now holds, the preserved previous key, and the secrets store (or take a `lemon backup` including credentials) to a safe place before changing anything.
3. Restore the key that matches the store's verifier — the previous key preserved before abandoning — into the provider that supplies the key (the Keychain item or the key file).
4. Restart every process that caches the resolved key (the runtime and long-lived readers), so none keeps reading with the wrong one.
5. Verify before rotating: `lemon secrets status` reports the expected source, and existing secrets read back. Only then rotate again with `lemon secrets rotate-key`.

Recovery may be impossible without the preserved previous key: records written after abandoning open only with it. Never reinitialize the key (`lemon secrets init --force`) or delete the store's `:key_check` verifier row to get past the mismatch; both make the affected secrets permanently unreadable or hide which key they need.

## Conditional Credential Saves

Credential refresh callers use the encrypted-store-only revision APIs:

```elixir
{:ok, encoded_credential, revision} = LemonCore.Secrets.get_with_revision(name, opts)
# Refresh outside the secrets mutation lease.
LemonCore.Secrets.set_if_revision(name, refreshed_credential, revision, opts)
```

- `get_with_revision/2` returns `{:ok, plaintext, opaque_revision}` or
  `{:error, reason}`. It never resolves external sources or environment values
  and distinguishes a confirmed missing credential from a backend/process
  failure. `get/2` uses the same strict encrypted-store read.
- `set_if_revision/4` returns `{:ok, metadata}`, `{:error, :stale_revision}` or
  another storage/key/lock error. A revision binds the exact durable credential
  incarnation and its Store process, owner and name. Every successful ordinary
  or conditional set creates a new incarnation, even for identical plaintext.
  Replacement, deletion, delete/recreate and a Store restart invalidate the old
  revision; it cannot authorize a save in another Store or owner/name.
- Revisions are opaque, ephemeral credential-bearing data. Keep them only for
  the refresh in progress; never inspect, log or persist them. A stale save
  must discard its refresh result, not retry it against a newly loaded login.
- Reads only enqueue best-effort exact-record usage touches. Usage counts and
  last-used timestamps become visible after batching and do not invalidate
  outstanding revisions. Reads never delete expired records and never install
  revision metadata into legacy rows.
  Legacy rows derive their revision from their encrypted incarnation until the
  next replacement; re-encryption of a legacy row may invalidate that revision.
- Conditional saves resolve the current encryption key while holding the
  existing `Secrets.Lock`, then persist with Store's atomic compare-and-swap.
  The original record's expiry is checked again immediately before every CAS,
  so expiration during blocked key resolution cannot be cleared by a refresh.
  An exact-record conflict caused only by usage metadata is re-read strictly
  and retried only while the original incarnation remains current. Key rotation
  preserves incarnations on new-format records, and a save after rotation uses
  the newly resolved key.
- Ordinary set, deletion and list expiry cleanup use that same mutation owner.
  Delete binds its snapshot before waiting for the lease and returns
  `:stale_revision` if that snapshot changed. Expiry cleanup conditionally
  removes its listed snapshot; a concurrently replaced record survives.
  `list/1` and `status/1` return errors when storage or cleanup fails instead of
  reporting an empty successful result.
- `:owner` selects the owner (default `"default"`); `:store` selects an existing
  Store instance (default `LemonCore.Store`). Each operation pins its Store
  process so a mid-operation restart cannot silently redirect a mutation.

Provider setup compensation uses `LemonCore.Secrets.snapshot/2` and `restore/3`,
not a plaintext `get`/`set` round trip. Snapshots capture the encrypted-store
credential and metadata without touching usage, including already-expired
credentials. They are opaque, ephemeral credential-bearing data and must never
be inspected, logged or persisted. Callers serialize the entire mutation and
compensation sequence. Restore binds the original Store process, owner and name,
re-encrypts under the current master key using the shared mutation lease, and
preserves provider, original absolute expiry, creation/modification timestamps
and usage metadata. It creates a new incarnation rather than reviving an old
conditional-write revision. Expiry elapsed during a failed mutation remains
enforced after restoration; compensation never extends the credential lifetime.

## Master Key Rotation

`lemon secrets rotate-key` generates a new
master key, re-encrypts every secret in the encrypted store under it, and
writes it to the provider that supplied the current key: the Keychain entry is
updated in place, the key file is replaced by an atomic rename (`0600`)
followed by a synchronous directory flush. Implementation:
`LemonCli.Secrets.KeyRotation`.

A key file is only rotated where that flush is real: GNU coreutils
`sync DIR`, verified at run time. macOS has none (its `sync` ignores
arguments and only schedules a flush), so rotation of a file key there
refuses with `key_file_not_durable` before changing anything. Keep the
master key in the Keychain on macOS (the default provider); to move a file
key there, store it with `security add-generic-password -s "Lemon Secrets"
-a default -w "$(cat ~/.lemon/secrets_master_key)"`, move the file aside,
and confirm `lemon secrets status` reports `source: keychain`.

```bash
lemon secrets rotate-key                    # preview; changes nothing
lemon secrets rotate-key --confirm <token>  # apply exactly that preview
```

- **Preview first.** The preview decrypts every live secret with the current
  key and prints how many will be re-encrypted, how many expired records will
  be deleted, and a confirmation token: a SHA-256 digest over the key source, a
  fingerprint of the current key, and every stored owner/name with its
  ciphertext revision and expiry. Apply refuses the token when anything changed
  since the preview (a secret set, deleted or re-encrypted, or the key itself
  replaced).
- **Fail closed.** If any stored secret does not decrypt with the current key,
  preview and apply report how many (and their owner/name) and change nothing.
  Values and key material never appear in output, errors or logs.
- **Crash safe.** Each record first gains a staged copy encrypted under the new
  key while keeping its current ciphertext; the store is re-read and verified;
  `LemonCore.Store.sync/1` makes the staged copies durable (SQLite WAL
  checkpoint, JSONL fsync) and a backend that cannot confirm it stops the
  rotation before the key moves. The key switch counts only when the provider
  that was written now returns the new key and resolution loads it too;
  otherwise the staged copies are kept, because the write may still land.
  Finally every record is converged to new-key ciphertext: staged copies are
  promoted, and any record only the previous key opens is staged, synced and
  then promoted. `Secrets.get/2` falls back to the staged copy, so after an
  interruption at any point every secret is readable with whichever key loads
  next. A later preview reports such records as `resumed`, and the next
  rotation finishes them.
- **Exclusive.** Rotation holds `LemonCore.Secrets.Lock`, a lease in the
  Store that SQLite makes exclusive across OS processes sharing the store.
  `Secrets.set/3` and `set_if_revision/4` take the same lock from resolving the
  key to storing the record (waiting up to 30 seconds, then
  `{:error, :secrets_locked}`). Deletion and list expiry cleanup also take it
  around conditional removal, so concurrent writes never use the retiring key
  and secret mutations and rotations never interleave. A lease has no expiry;
  it is reclaimed only when
  its holder is provably gone (a dead process in this VM, or an OS pid on this
  host that no longer exists). A lease from another host is never reclaimed:
  callers get `{:error, {:secrets_lock_held, host}}` and an operator deletes
  the `:secrets_lock` row after confirming that holder is gone. OAuth refresh
  paths and MCP token caches report a failed save instead of claiming success.
  Within one VM, waiters monitor the holder and subscribe to its lease-specific
  release notification; normal release wakes them even if the holder stays alive.
  They re-read the lease after subscribing so a release cannot be missed.
  Other OS processes retain the shared-lease poll and dead-holder checks.
  Standalone Store users without the application Bus also retain that poll.
- **Scope.** Only the encrypted store is rotated. External sources and
  same-name environment fallback are read-only and untouched. A master key
  supplied by `LEMON_SECRETS_MASTER_KEY` cannot be rewritten: rotation refuses
  with `read_only_key_source` until that variable is unset.
- **Runtime.** `KeyRotation.rotate/2` itself refuses (`runtime_running`) while
  a Lemon runtime answers on the control-plane port, so both the CLI and the
  Mix task enforce it: a runtime started by `bin/lemon` exports the master key
  into its environment at boot and would keep using the previous key. Stop it,
  rotate, then start it again.
- **Backups.** Store data in existing backups stays encrypted under the
  previous key; keep that key (or a `--include-credentials` backup) if you may
  restore them. See [backups](../user-guide/backups.md).

## Destination secret operation receipts

`Secrets.set(name, value, operation_id: id, node_id: authenticated_node_id, ...)`
installs a value and its private durable proof in **one vault-row mutation** under
`Secrets.Lock`, held from master-key resolution through persistence. The receipt
binds the secret owner, node ID, normalized name and exact value with a private
domain-separated HMAC; provider and expiry are also part of the intent. Public
metadata and RPC projections expose no plaintext, value digest, HMAC, encryption
fields or key material. IDs accept 1–128 ASCII letters/digits/`_`/`:`/`-`.

Admission strictly scans the owner's vault records while holding the same lock,
so an ID cannot be reused for another name on the same authenticated node.
Unavailable or corrupt reads fail closed, never authorize a fresh write.
The encrypted value and proof are embedded in one record, not two sequential
Store writes or a simulated transaction. A duplicate with unchanged intent and
current binding returns without re-encryption, persistence or usage changes;
a conflicting intent or superseded binding returns `secret_operation_conflict`.

`Secrets.receipt(operation_id, node_id: authenticated_node_id, ...)` strictly
queries private vault metadata without resolving a master key, decrypting a value,
replaying a mutation or touching usage. It returns only node/operation IDs,
`status` (`applied` or `not_found`), `name` (null on absence), and
`current_binding_matches`. The asynchronous admin-only `node.secrets.receipt`
RPC projects these as `nodeId`, `operationId`, `status`, `name`, and
`currentBindingMatches`. Worker-owned `:node_id`, never RPC arguments, supplies
the authenticated identity. See [node files and secrets](../user-guide/node-files-and-secrets.md#reconciling-a-secret-installation).

`applied` is historical proof of installation, not credential validity or current
readiness. Current binding compares only the private encrypted revision (including
rotation staging and expiry) and active state; usage counters are ignored.
Ordinary sets preserve past receipts. Deletion removes all encrypted value fields
but retains receipt-only metadata; normal reads, resolution and lists treat that
row as absent. Expired values are excluded from reads/lists without deleting proof.
Rotation skips valid receipt-only rows, preserves proof when pruning expired
values, and re-encrypts live values without migrating their original bindings.
Thus completed rotation invalidates current binding but never loses historical
proof. If staging is rolled back before switching keys, the unchanged original
binding can match again.

Receipts are bounded at 128 per owner/name row. New operations at capacity fail
with `secret_receipt_capacity` without changing the value or pruning prior proof.
Failed queries are errors, not missing proof. Retain the fixed node/operation IDs
after uncertain mutations and reconcile read-only before any new mutation.

## Validation References

- `apps/lemon_core/test/lemon_core/secrets/keychain_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/master_key_test.exs`
- `apps/lemon_core/test/lemon_core/secrets_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/revision_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/external_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/source_contract_test.exs`
- `apps/lemon_core/test/lemon_core/config/secrets_test.exs`
- `apps/lemon_cli/test/lemon_cli/secret_sources_command_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/key_rotation_test.exs`
- `apps/lemon_cli/test/lemon_cli/cli_test.exs` (`secrets rotate-key`)
- `apps/lemon_core/test/lemon_core/secrets/lock_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/read_cache_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/usage_test.exs`
- `apps/lemon_core/test/lemon_core/store/sqlite_backend_test.exs` (`compare_and_swap/5 and sync/1`)
- `apps/lemon_core/test/lemon_core/secrets/receipts_test.exs`
