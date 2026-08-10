# Secrets + Keychain Audit Matrix

_Last updated: 2026-02-25_

This document captures the current, tested contract for Lemon secret resolution across keychain, encrypted store, and environment fallback paths.

## Flow Matrix

| Layer | Write Path | Read/Resolve Path | Fallbacks | Primary Files |
|---|---|---|---|---|
| macOS Keychain master key | `LemonCore.Secrets.MasterKey.init/1` -> `Keychain.put_master_key/2` | `LemonCore.Secrets.MasterKey.resolve/1` -> `Keychain.get_master_key/1` | On `:missing` / `:keychain_unavailable` / command failures, tries env master key, then local file | `apps/lemon_core/lib/lemon_core/secrets/keychain.ex`, `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Master key env fallback | Manual set of `LEMON_SECRETS_MASTER_KEY` (external) | `MasterKey.resolve/1` via `resolve_from_env/1` | On missing env, tries `~/.lemon/secrets_master_key`; malformed env still fails as `:invalid_master_key` | `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Local master key file fallback | `~/.lemon/secrets_master_key` | `MasterKey.resolve/1` via local file fallback | Returns `:missing_master_key` or `:invalid_master_key` when no valid source exists | `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Encrypted secret store | `LemonCore.Secrets.set/3` (AES-256-GCM at rest) | `LemonCore.Secrets.get/2`, `resolve/2`, `exists?/2` | `resolve/2` can fallback to env by same secret name (`env_fallback: true`) | `apps/lemon_core/lib/lemon_core/secrets.ex` |
| Coding Agent provider secret refs | Configured `api_key_secret` names in provider config | `CodingAgent.Session.resolve_secret_api_key/1` -> `LemonCore.Secrets.resolve/2` | Store first, env fallback enabled | `apps/coding_agent/lib/coding_agent/session.ex` |

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
- Key material must be base64-encoded 32-byte data. Raw passphrase-like strings are rejected with `:weak_master_key` (there is no password stretching); `allow_legacy_raw_keys: true` restores the old behaviour for setups that already encrypted secrets under such a value.
- Key rotation (re-encryption under a new master key) is not implemented — see the "Key rotation" section of the `LemonCore.Secrets` moduledoc and item 1.5 in `docs/platform-split.md`.
- `status/1` suppresses expected keychain absence (`:missing`, `:keychain_unavailable`) from `keychain_error` while still surfacing hard failures.
- The local source launcher `bin/lemon` also normalizes `LEMON_SECRETS_MASTER_KEY` from `~/.lemon/secrets_master_key` on non-macOS systems so stale desktop/session env does not override the working local key by accident.

## Operator Notes

- `mix lemon.secrets.init` is the preferred bootstrap path everywhere: it stores the generated key in the keychain on macOS and writes the key file (`0600`) on other platforms. It refuses to overwrite an existing key file unless `--force` is passed.
- For local non-macOS development, keep `~/.lemon/secrets_master_key` as the canonical master key file. `bin/lemon` will export that value into `LEMON_SECRETS_MASTER_KEY` before boot when the file exists.
- `secrets.list` and `secrets.status` return metadata only (never plaintext secret values).
- If keychain prompts are denied (`User interaction is not allowed`), Lemon can still operate via env fallback when configured.

## Validation References

- `apps/lemon_core/test/lemon_core/secrets/keychain_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/master_key_test.exs`
- `apps/lemon_core/test/lemon_core/secrets_test.exs`
