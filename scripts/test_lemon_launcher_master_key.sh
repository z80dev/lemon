#!/usr/bin/env bash
# bin/lemon never chooses a secrets master key: it only preloads the Keychain
# item for the runtime's keychain provider, and never exports the key file or
# overrides an inherited LEMON_SECRETS_MASTER_KEY. Precedence and conflict
# detection live in LemonCore.Secrets.MasterKey, shared by every entry point.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-master-key.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT

load_function() {
  eval "$(awk -v name="$2" '$0 == name "() {" || $0 == name "() (" {copy=1} copy {print} copy && /^[})]$/ {exit}' "$1")"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home/.lemon"
cat >"$TEST_DIR/bin/security" <<'SH'
#!/bin/sh
[ "$1" = find-generic-password ] || exit 1
[ -n "${FAKE_KEYCHAIN_ITEM:-}" ] || exit 44
printf '%s\n' "$FAKE_KEYCHAIN_ITEM"
SH
chmod +x "$TEST_DIR/bin/security"
printf 'file-key\n' >"$TEST_DIR/home/.lemon/secrets_master_key"

run_case() (
  # $1 inherited env key, $2 fake keychain item; prints "env|preload".
  export HOME="$TEST_DIR/home" PATH="$TEST_DIR/bin:$PATH"
  # The launcher's former key-file export read these on non-Darwin hosts.
  export LEMON_HOME_DIR="$HOME/.lemon"
  unset LEMON_SECRETS_KEYCHAIN_PRELOAD
  if [ -n "$1" ]; then export LEMON_SECRETS_MASTER_KEY="$1"; else unset LEMON_SECRETS_MASTER_KEY; fi
  if [ -n "$2" ]; then export FAKE_KEYCHAIN_ITEM="$2"; else unset FAKE_KEYCHAIN_ITEM; fi
  # shellcheck disable=SC2329 # invoked by the loaded launcher function
  info() { :; }
  # shellcheck disable=SC2329 # invoked by the loaded launcher function
  uname() { echo Linux; }
  load_function "$ROOT/bin/lemon" load_secrets_master_key
  load_secrets_master_key
  printf '%s|%s\n' "${LEMON_SECRETS_MASTER_KEY:-}" "${LEMON_SECRETS_KEYCHAIN_PRELOAD:-}"
)

# A conflicting inherited env key is passed through untouched (the runtime
# then reports conflicting keys), not silently replaced by the key file.
[ "$(run_case env-key "")" = "env-key|" ] || fail "env key overridden: $(run_case env-key "")"
# The key file is read by the runtime's file provider, never exported.
[ "$(run_case "" "")" = "|" ] || fail "key file exported: $(run_case "" "")"
# The Keychain item only reaches the keychain provider's preload slot.
[ "$(run_case env-key kc-key)" = "env-key|kc-key" ] || fail "keychain: $(run_case env-key kc-key)"
[ "$(run_case "" kc-key)" = "|kc-key" ] || fail "keychain preload: $(run_case "" kc-key)"

grep -q 'LEMON_SECRETS_MASTER_KEY=' "$ROOT/bin/lemon-gateway" &&
  fail "bin/lemon-gateway still exports LEMON_SECRETS_MASTER_KEY"
echo "launcher master key: ok"
