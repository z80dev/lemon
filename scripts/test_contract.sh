#!/usr/bin/env bash
# Contract checks for the canonical repo-level test runner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/test"
DOC="$ROOT/docs/testing.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$RUNNER" ] || fail "scripts/test must exist and be executable"
bash -n "$RUNNER"

HELP="$($RUNNER help)"
for lane in fast quality clients eval-fast smoke all path; do
  printf '%s\n' "$HELP" | grep -Eq "(^|[[:space:]])$lane([[:space:]]|$|:)" || fail "help output must mention lane: $lane"
  [ -f "$DOC" ] || fail "docs/testing.md must exist"
  grep -Eq "(^|[[:space:]])$lane([[:space:]]|$|:)" "$DOC" || fail "docs/testing.md must mention lane: $lane"
done

printf '%s\n' "$HELP" | grep -q "Usage: scripts/test" || fail "help output must include usage"
printf '%s\n' "$HELP" | grep -q "MIX_ENV=test" || fail "help output must document test env"

contract_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lemon-contract-root.XXXXXX")"
TMPDIR="$contract_tmp_root" "$RUNNER" path >/tmp/lemon-test-contract-path.out 2>&1 &&
  fail "path lane without args should fail"
[ "$?" -eq 64 ] || fail "path lane without args should exit 64"
[ -z "$(find "$contract_tmp_root" -mindepth 1 -maxdepth 1 -type d -name 'lemon-test.*' -print -quit)" ] ||
  fail "runner-created LEMON_TEST_TMPDIR should be cleaned up on exit"
rm -rf "$contract_tmp_root"

provided_tmp="$(mktemp -d "${TMPDIR:-/tmp}/lemon-contract-provided.XXXXXX")"
LEMON_TEST_TMPDIR="$provided_tmp" "$RUNNER" path >/tmp/lemon-test-contract-path-provided.out 2>&1 &&
  fail "path lane without args should fail with provided tmpdir"
[ "$?" -eq 64 ] || fail "path lane without args with provided tmpdir should exit 64"
[ -d "$provided_tmp" ] || fail "caller-provided LEMON_TEST_TMPDIR must not be removed"
rm -rf "$provided_tmp"

echo "test runner contract ok"
