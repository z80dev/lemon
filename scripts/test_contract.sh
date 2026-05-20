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
for lane in fast quality clients eval-fast live-eval smoke all path; do
  printf '%s\n' "$HELP" | grep -Eq "(^|[[:space:]])$lane([[:space:]]|$|:)" || fail "help output must mention lane: $lane"
  [ -f "$DOC" ] || fail "docs/testing.md must exist"
  grep -Eq "(^|[[:space:]])$lane([[:space:]]|$|:)" "$DOC" || fail "docs/testing.md must mention lane: $lane"
done

printf '%s\n' "$HELP" | grep -q "Usage: scripts/test" || fail "help output must include usage"
printf '%s\n' "$HELP" | grep -q "MIX_ENV=test" || fail "help output must document test env"
printf '%s\n' "$HELP" | grep -q "BEAM test lanes scrub ambient provider/platform credentials" || fail "help output must document credential scrubbing"
grep -q "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1" "$DOC" || fail "docs/testing.md must document live credential opt-in"
grep -q "scripts/test live-eval" "$DOC" || fail "docs/testing.md must document live-eval"
grep -q "LemonCore.Testing.HermeticEnv" "$DOC" || fail "docs/testing.md must mention shared hermetic env helper"
grep -q "OPENAI_API_KEY" "$RUNNER" || fail "runner must scrub common provider credentials"
grep -q "TELEGRAM_BOT_TOKEN" "$RUNNER" || fail "runner must scrub common platform credentials"
python3 - "$RUNNER" "$ROOT/apps/lemon_core/lib/lemon_core/testing/hermetic_env.ex" <<'PY' || fail "runner and HermeticEnv scrub lists must match"
import re
import sys

runner = open(sys.argv[1], encoding="utf-8").read()
elixir = open(sys.argv[2], encoding="utf-8").read()

runner_match = re.search(r"SCRUB_CREDENTIAL_ENV_VARS=\((.*?)\n\)", runner, re.S)
elixir_match = re.search(r"@credential_env_vars ~w\((.*?)\n  \)", elixir, re.S)
if not runner_match or not elixir_match:
    raise SystemExit(1)

def vars(block):
    return sorted(word for line in block.splitlines() if not line.strip().startswith("#") for word in line.split())

if vars(runner_match.group(1)) != vars(elixir_match.group(1)):
    raise SystemExit(1)
PY

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

live_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lemon-contract-live-root.XXXXXX")"
env -u LEMON_EVAL_API_KEY -u INTEGRATION_API_KEY -u ANTHROPIC_API_KEY \
  TMPDIR="$live_tmp_root" "$RUNNER" live-eval >/tmp/lemon-test-contract-live-eval.out 2>&1 &&
  fail "live-eval without credentials should fail"
[ "$?" -eq 66 ] || fail "live-eval without credentials should exit 66"
grep -q "requires a live model credential" /tmp/lemon-test-contract-live-eval.out ||
  fail "live-eval without credentials should explain missing credential"
[ -z "$(find "$live_tmp_root" -mindepth 1 -maxdepth 1 -type d -name 'lemon-test.*' -print -quit)" ] ||
  fail "runner-created live-eval LEMON_TEST_TMPDIR should be cleaned up on exit"
rm -rf "$live_tmp_root"

artifact_tmp="$(mktemp -d "${TMPDIR:-/tmp}/lemon-artifact-contract.XXXXXX")"
printf 'min-runtime' > "$artifact_tmp/lemon-2026.05.0-stable-linux-x86_64-lemon_runtime_min.tar.gz"
printf 'full-runtime' > "$artifact_tmp/lemon-2026.05.0-stable-linux-x86_64-lemon_runtime_full.tar.gz"
python3 - "$artifact_tmp" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
artifacts = []

for path in sorted(root.glob("*.tar.gz")):
    artifacts.append(
        {
            "file": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": path.stat().st_size,
        }
    )

(root / "manifest.json").write_text(
    json.dumps({"version": "2026.05.0", "channel": "stable", "artifacts": artifacts}, indent=2),
    encoding="utf-8",
)
PY
"$ROOT/scripts/verify_release_artifacts" "$artifact_tmp" >/tmp/lemon-artifact-contract-valid.out 2>&1 ||
  fail "release artifact verifier should accept complete min/full Linux manifest"

incomplete_artifact_tmp="$(mktemp -d "${TMPDIR:-/tmp}/lemon-artifact-contract-incomplete.XXXXXX")"
cp "$artifact_tmp/lemon-2026.05.0-stable-linux-x86_64-lemon_runtime_min.tar.gz" "$incomplete_artifact_tmp/"
python3 - "$incomplete_artifact_tmp" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "lemon-2026.05.0-stable-linux-x86_64-lemon_runtime_min.tar.gz"
(root / "manifest.json").write_text(
    json.dumps(
        {
            "version": "2026.05.0",
            "channel": "stable",
            "artifacts": [
                {
                    "file": path.name,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "size": path.stat().st_size,
                }
            ],
        },
        indent=2,
    ),
    encoding="utf-8",
)
PY
"$ROOT/scripts/verify_release_artifacts" "$incomplete_artifact_tmp" >/tmp/lemon-artifact-contract-incomplete.out 2>&1 &&
  fail "release artifact verifier should reject manifests missing lemon_runtime_full"
grep -q "missing required release artifact profile" /tmp/lemon-artifact-contract-incomplete.out ||
  fail "release artifact verifier should explain missing required profiles"

rm -rf "$artifact_tmp" "$incomplete_artifact_tmp"

[ -x "$ROOT/scripts/verify_source_install" ] || fail "source install verifier must be executable"
bash -n "$ROOT/scripts/verify_source_install"
grep -q './bin/lemon setup runtime --profile runtime_min --non-interactive' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon setup wrapper"
grep -q './bin/lemon channels --project-dir' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon channels wrapper"
grep -q './bin/lemon config validate --project-dir' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon config wrapper"
grep -q './bin/lemon doctor --json' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon doctor wrapper"
grep -q './bin/lemon media --project-dir' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon media wrapper"
grep -q './bin/lemon models --provider anthropic --limit 1' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon models wrapper"
grep -q './bin/lemon providers --provider anthropic --project-dir' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon providers wrapper"
grep -q './bin/lemon policy list' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon policy wrapper"
grep -q './bin/lemon proofs --project-dir' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon proofs wrapper"
grep -q './bin/lemon readiness --project-dir' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon readiness wrapper"
grep -q './bin/lemon secrets status' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon secrets wrapper"
grep -q './bin/lemon skill list' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon skill wrapper"
grep -q './bin/lemon usage' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon usage wrapper"
grep -q './bin/lemon update --check --no-skill-sync --verbose' "$ROOT/scripts/verify_source_install" ||
  fail "source install verifier must exercise the ./bin/lemon update wrapper"
"$ROOT/scripts/verify_source_install" --help >/tmp/lemon-source-install-help.out 2>&1 &&
  fail "source install verifier help should exit 2 like other usage paths"
[ "$?" -eq 2 ] || fail "source install verifier help should exit 2"
grep -q "Verifies the supported source-install path" /tmp/lemon-source-install-help.out ||
  fail "source install verifier help should describe its contract"

echo "test runner contract ok"
