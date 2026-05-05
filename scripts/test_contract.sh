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

echo "test runner contract ok"
