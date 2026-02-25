# Secrets + Keychain Audit Matrix

_Last updated: 2026-02-25_

This document captures the current, tested contract for Lemon secret resolution across keychain, encrypted store, and environment fallback paths.

## Flow Matrix

| Layer | Write Path | Read/Resolve Path | Fallbacks | Primary Files |
|---|---|---|---|---|
| macOS Keychain master key | `LemonCore.Secrets.MasterKey.init/1` -> `Keychain.put_master_key/2` | `LemonCore.Secrets.MasterKey.resolve/1` -> `Keychain.get_master_key/1` | On `:missing` / `:keychain_unavailable` / command failures, tries env master key | `apps/lemon_core/lib/lemon_core/secrets/keychain.ex`, `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Master key env fallback | Manual set of `LEMON_SECRETS_MASTER_KEY` (external) | `MasterKey.resolve/1` via `resolve_from_env/1` | No further fallback; returns `:missing_master_key` or `:invalid_master_key` | `apps/lemon_core/lib/lemon_core/secrets/master_key.ex` |
| Encrypted secret store | `LemonCore.Secrets.set/3` (AES-256-GCM at rest) | `LemonCore.Secrets.get/2`, `resolve/2`, `exists?/2` | `resolve/2` can fallback to env by same secret name (`env_fallback: true`) | `apps/lemon_core/lib/lemon_core/secrets.ex` |
| Coding Agent provider secret refs | Configured `api_key_secret` names in provider config | `CodingAgent.Session.resolve_secret_api_key/1` -> `LemonCore.Secrets.resolve/2` | Store first, env fallback enabled | `apps/coding_agent/lib/coding_agent/session.ex` |
| MarketIntel secret adapter | `MarketIntel.Secrets.put/2` (delegated module) | `MarketIntel.Secrets.get/1` -> store first then env | Explicit fallback to env if store path fails/misses | `apps/market_intel/lib/market_intel/secrets.ex` |

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
3. Error (`:missing_master_key`, `:invalid_master_key`, or `{:keychain_failed, reason}`)

Additional nuance:

- If keychain returns malformed key material, env fallback is attempted first; only then returns `:invalid_master_key`.
- `status/1` suppresses expected keychain absence (`:missing`, `:keychain_unavailable`) from `keychain_error` while still surfacing hard failures.

## Operator Notes

- `mix lemon.secrets.init` is the preferred bootstrap path on macOS (stores generated key in keychain).
- Non-macOS environments should set `LEMON_SECRETS_MASTER_KEY` explicitly.
- `secrets.list` and `secrets.status` return metadata only (never plaintext secret values).
- If keychain prompts are denied (`User interaction is not allowed`), Lemon can still operate via env fallback when configured.

## Validation References

- `apps/lemon_core/test/lemon_core/secrets/keychain_test.exs`
- `apps/lemon_core/test/lemon_core/secrets/master_key_test.exs`
- `apps/lemon_core/test/lemon_core/secrets_test.exs`
