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
| Encrypted secret store | `LemonCore.Secrets.set/3` (AES-256-GCM at rest) | `LemonCore.Secrets.get/2`, `resolve/2`, `exists?/2` | `resolve/2` uses store, enabled external sources, then same-name env when `env_fallback: true` | `apps/lemon_core/lib/lemon_core/secrets.ex` |
| External secret sources | Read-only; no external result is persisted | `LemonCore.Secrets.External` invokes 1Password, Bitwarden, or argv-only command adapters under shared supervision | Ordered by priority/id; a source miss continues, but any enabled-source failure stops before env fallback | `apps/lemon_core/lib/lemon_core/secrets/external.ex`, `apps/lemon_core/lib/lemon_core/secrets/source_runner.ex` |
| External bootstrap credentials | Existing Lemon encrypted secret or same-name env only | `LemonCore.Secrets.resolve_local/2` from a source adapter | Never invokes an external source, preventing recursion | `apps/lemon_core/lib/lemon_core/secrets.ex`, `apps/lemon_core/lib/lemon_core/secrets/source/` |
| Coding Agent provider secret refs | Configured `api_key_secret` names in provider config | `CodingAgent.Session.resolve_secret_api_key/1` -> `LemonCore.Secrets.resolve/2` | Store first, enabled external sources second, env fallback last | `apps/coding_agent/lib/coding_agent/session.ex` |

## Keychain Error Semantics (Current Contract)

`LemonCore.Secrets.Keychain` maps command outcomes to stable errors:

- Exit code `44` -> `{:error, :missing}`
- Non-zero exit codes -> `{:error, {:command_failed, code, stderr_or_output}}`
- Timeout (`Task.yield` expiry) -> `{:error, :timeout}`
- Non-macOS / missing `security` executable -> `{:error, :unavailable}`
- Empty retrieved value -> treated as missing (`{:error, :missing}`)

## Master Key Resolution Precedence

`LemonCore.Secrets.MasterKey.resolve/1` order:

1. Keychain (`:keychain` source)
2. `LEMON_SECRETS_MASTER_KEY` (`:env` source)
3. `~/.lemon/secrets_master_key` (`:file` source)
4. Error (`:missing_master_key`, `:invalid_master_key`, or `{:keychain_failed, reason}`)

The chain itself is configurable — providers implement `LemonCore.Secrets.KeyProvider`:

```elixir
config :lemon_core, LemonCore.Secrets,
  key_providers: [:keychain, :env, :file],
  key_file: "~/.lemon/secrets_master_key",
  env_var: "LEMON_SECRETS_MASTER_KEY"
```

Additional nuance:

- The keychain provider is macOS-only and skips itself on other platforms, so a Linux host with no key configured reports `:missing_master_key` rather than a keychain failure.
- If keychain returns malformed key material, env fallback is attempted first; only then returns `:invalid_master_key`.
- Key material must be base64-encoded 32-byte data. Raw passphrase-like strings are rejected with `:weak_master_key` (there is no password stretching); `allow_legacy_raw_keys: true` restores the old behaviour for setups that already encrypted secrets under such a value. `lemon secrets rotate-key` moves such a setup onto a generated key.
- `status/1` suppresses expected keychain absence (`:missing`, `:keychain_unavailable`) from `keychain_error` while still surfacing hard failures.
- The local source launcher `bin/lemon` also normalizes `LEMON_SECRETS_MASTER_KEY` from `~/.lemon/secrets_master_key` on non-macOS systems so stale desktop/session env does not override the working local key by accident.

## Operator Notes

- `mix lemon.secrets.init` is the preferred bootstrap path everywhere: it stores the generated key in the keychain on macOS and writes the key file (`0600`) on other platforms. It refuses to overwrite an existing key file unless `--force` is passed; forcing a new key makes existing secrets unreadable, so change a key in use with `lemon secrets rotate-key` instead.
- For local non-macOS development, keep `~/.lemon/secrets_master_key` as the canonical master key file. `bin/lemon` will export that value into `LEMON_SECRETS_MASTER_KEY` before boot when the file exists.
- `lemon secrets sources status|test` returns only source readiness,
  provenance, counts, byte counts, duration, and stable error kinds. Combined
  stdout/stderr and resolved values are never included.
- External commands are direct argv execution with exact configuration,
  minimal child environments, `100..30000` ms timeouts, `1..1048576` byte
  output bounds, and an optional bounded process-local cache that defaults off.
- If keychain prompts are denied (`User interaction is not allowed`), Lemon can still operate via env fallback when configured.

## Master Key Rotation

`lemon secrets rotate-key` (or `mix lemon.secrets.rotate_key`) generates a new
master key, re-encrypts every secret in the encrypted store under it, and
writes it to the provider that supplied the current key: the Keychain entry is
updated in place, the key file is replaced by an atomic rename (`0600`)
followed by a synchronous directory flush. Implementation:
`LemonCore.Secrets.KeyRotation`.

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
  `Secrets.set/3` takes the same lock from resolving the key to storing the
  record (waiting up to 30 seconds, then `{:error, :secrets_locked}`), so a
  concurrent `lemon secrets set` never encrypts under the retiring key and two
  rotations never interleave. A lease has no expiry; it is reclaimed only when
  its holder is provably gone (a dead process in this VM, or an OS pid on this
  host that no longer exists). A lease from another host is never reclaimed:
  callers get `{:error, {:secrets_lock_held, host}}` and an operator deletes
  the `:secrets_lock` row after confirming that holder is gone. OAuth refresh
  paths and MCP token caches report a failed save instead of claiming success.
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
- `apps/lemon_core/test/lemon_core/secrets/external_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/source_contract_test.exs`
- `apps/lemon_core/test/lemon_core/config/secrets_test.exs`
- `apps/lemon_cli/test/lemon_cli/secret_sources_command_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/key_rotation_test.exs`
- `apps/lemon_cli/test/lemon_cli/cli_test.exs` (`secrets rotate-key`)
- `apps/lemon_core/test/lemon_core/secrets/lock_test.exs`
- `apps/lemon_core/test/lemon_core/store/sqlite_backend_test.exs` (`compare_and_swap/5 and sync/1`)
- `apps/lemon_core/test/lemon_core/secrets/receipts_test.exs`
