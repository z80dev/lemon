#!/usr/bin/env bash
# Lint script for CI/docs policy checks (tasks C9, C10, C11, J17, J18, J19, J20, J22, J23, J24, J25, J26, J27, J28, J29, J30, J31, J32, J33, J34, manual-dispatch)
# Usage: ./scripts/lint_ci_docs.sh
# Exit 0 = all checks pass. Exit 1 = one or more checks failed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

pass() {
  echo "ok:   $*"
}

# ── C9: SECURITY.md must not contain placeholder disclosure email ─────────────
if grep -qE 'security@lemon|replace with actual contact' "$ROOT/SECURITY.md" 2>/dev/null; then
  fail "C9: SECURITY.md still contains placeholder email (security@lemon or 'replace with actual contact')"
else
  pass "C9: SECURITY.md has no placeholder email"
fi

# ── C10: Example config must not enable dangerously_skip_permissions ──────────
if grep -qE '^[^#]*dangerously_skip_permissions\s*=\s*true' "$ROOT/examples/config.example.toml" 2>/dev/null; then
  fail "C10: examples/config.example.toml enables dangerously_skip_permissions = true (must be opt-in / commented)"
else
  pass "C10: dangerously_skip_permissions is not enabled by default in example config"
fi
# Also check docs/config.md
if grep -qE '^[^#]*dangerously_skip_permissions\s*=\s*true' "$ROOT/docs/config.md" 2>/dev/null; then
  fail "C10: docs/config.md enables dangerously_skip_permissions = true (must be opt-in / commented)"
else
  pass "C10: docs/config.md does not enable dangerously_skip_permissions by default"
fi

# ── C11: Primary example config must use api_key_secret refs, not plaintext keys ─
# Check for patterns like: api_key = "sk-..." (real key patterns, not secret refs)
if grep -qE '^api_key\s*=\s*"(sk-|AKIA|ya29\.|opencode-|pplx-)' "$ROOT/examples/config.example.toml" 2>/dev/null; then
  fail "C11: examples/config.example.toml uses plaintext api_key with real key prefixes (use api_key_secret refs)"
else
  pass "C11: examples/config.example.toml does not use plaintext api_key with real key prefixes"
fi

if python3 - "$ROOT/docs/config.md" <<'PYEOF'
import re, sys

content = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"## Example\s+```toml\n(.*?)\n```", content, re.S)
if not match:
    sys.exit(1)

example = match.group(1)
if re.search(r'^\s*api_key\s*=', example, re.M):
    sys.exit(1)

if not re.search(r'^\s*api_key_secret\s*=', example, re.M):
    sys.exit(1)
PYEOF
then
  pass "C11: docs/config.md primary example uses api_key_secret references"
else
  fail "C11: docs/config.md primary example still exposes plaintext api_key values"
fi

# ── J17: release.yml must not reference a nonexistent step output for TIMESTAMP ─
# The TIMESTAMP env var in publish job should use the inline variable, not steps.timestamp.outputs
if grep -qE 'steps\.timestamp\.outputs\.timestamp' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  fail "J17: release.yml references steps.timestamp.outputs.timestamp (no 'timestamp' step exists)"
else
  pass "J17: release.yml does not reference nonexistent steps.timestamp.outputs.timestamp"
fi

# ── J18: CHANGELOG.md must reference CalVer, not SemVer ─────────────────────
if grep -qiE 'semantic versioning|semver\.org' "$ROOT/CHANGELOG.md" 2>/dev/null; then
  fail "J18: CHANGELOG.md references SemVer (should reference CalVer)"
else
  pass "J18: CHANGELOG.md does not reference SemVer"
fi

# ── J19: If docs claim .sig signatures, the release workflow must produce them ─
DOCS_CLAIMS_SIG=false
if grep -qE '\.sig|detached.*ed25519|signature' "$ROOT/docs/release/versioning_and_channels.md" 2>/dev/null; then
  DOCS_CLAIMS_SIG=true
fi
WORKFLOW_MAKES_SIG=false
if grep -qE '\.sig|gpg.*sign|cosign|sigstore' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  WORKFLOW_MAKES_SIG=true
fi
if $DOCS_CLAIMS_SIG && ! $WORKFLOW_MAKES_SIG; then
  fail "J19: docs/release/versioning_and_channels.md claims .sig signatures but release.yml does not produce them"
else
  pass "J19: signature claim in docs is consistent with release.yml"
fi

# ── J20: release-smoke.yml must wire profile input to matrix ─────────────────
# The matrix should use the workflow_dispatch input, not hardcode lemon_runtime_min
if grep -qE 'matrix:' "$ROOT/.github/workflows/release-smoke.yml" 2>/dev/null; then
  # Check if matrix profile section references the input
  if python3 - "$ROOT/.github/workflows/release-smoke.yml" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Find the matrix.profile section
# Look for pattern where profile list has a hardcoded value instead of referencing input
# A correctly wired version uses: ${{ github.event.inputs.profile || 'lemon_runtime_min' }}
if "github.event.inputs.profile" in content:
    print("wired")
    sys.exit(0)
else:
    print("not-wired")
    sys.exit(1)
PYEOF
  then
    pass "J20: release-smoke.yml matrix profile wired to workflow_dispatch input"
  else
    fail "J20: release-smoke.yml matrix profile ignores workflow_dispatch input (always uses hardcoded value)"
  fi
else
  fail "J20: release-smoke.yml: cannot find matrix section"
fi

# ── J22: product-smoke doctor check must not be masked with || true ───────────
# The python3 inline script block must not end with "|| true"
if awk '/Run lemon\.doctor/,/Skill lint/' "$ROOT/.github/workflows/product-smoke.yml" 2>/dev/null | grep -qE '\|\|\s*true'; then
  fail "J22: product-smoke.yml doctor check step is masked with '|| true'"
else
  pass "J22: product-smoke.yml doctor check is not unconditionally masked"
fi

# ── J23: PR workflows must have explicit permissions blocks ──────────────────
check_permissions() {
  local file="$1"
  local name="$2"
  if ! grep -q 'permissions:' "$file" 2>/dev/null; then
    fail "J23: $name lacks an explicit 'permissions:' block"
  else
    pass "J23: $name has explicit permissions"
  fi
}
check_permissions "$ROOT/.github/workflows/quality.yml" "quality.yml"
check_permissions "$ROOT/.github/workflows/release-smoke.yml" "release-smoke.yml"
check_permissions "$ROOT/.github/workflows/docs-site.yml" "docs-site.yml"
check_permissions "$ROOT/.github/workflows/live-eval.yml" "live-eval.yml"
check_permissions "$ROOT/.github/workflows/history-check.yml" "history-check.yml"
check_permissions "$ROOT/.github/workflows/python-cli.yml" "python-cli.yml"

if awk '
  /^permissions:/ {in_block=1; next}
  in_block && /^[^[:space:]]/ {exit}
  in_block {print}
' "$ROOT/.github/workflows/docs-site.yml" 2>/dev/null | grep -qE 'pages:\s*write|id-token:\s*write'; then
  fail "J23: docs-site.yml grants pages/id-token at workflow scope instead of deploy-job scope"
else
  pass "J23: docs-site.yml keeps pages/id-token permissions off the workflow scope"
fi

# ── J24: release notes must come from a validated version changelog section ──
if grep -q 'scripts/prepare_release_notes "$VERSION"' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  pass "J24: release.yml validates version-specific release notes"
else
  fail "J24: release.yml does not call scripts/prepare_release_notes for release notes"
fi

if grep -qE 'Release \$?\{?VERSION\}?|see CHANGELOG\.md for details' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  fail "J24: release.yml contains a generic fallback release-note body"
else
  pass "J24: release.yml has no generic fallback release-note body"
fi

if [ -x "$ROOT/scripts/verify_release_runtime_boot" ] &&
   grep -q 'scripts/verify_release_runtime_boot {artifact-directory}' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'channel_readiness.json' "$ROOT/scripts/verify_release_runtime_boot" 2>/dev/null &&
   grep -q 'readiness_summary.json' "$ROOT/scripts/verify_release_runtime_boot" 2>/dev/null &&
   grep -q 'channel_readiness.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'readiness_summary.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'channel_readiness.json' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'readiness_summary.json' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J24: runtime boot verifier is documented"
else
  fail "J24: runtime boot verifier is missing or undocumented"
fi

if grep -q 'scripts/verify_release_artifacts release-artifacts' "$ROOT/.github/workflows/release.yml" 2>/dev/null &&
   grep -q 'fail_on_unmatched_files: true' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  pass "J24: release.yml verifies assembled artifacts before publishing"
else
  fail "J24: release.yml can publish without verifying assembled artifacts"
fi

if grep -q 'Verify the assembled artifact directory before publishing' "$ROOT/.github/workflows/release.yml" 2>/dev/null &&
   grep -q 'Generate a manifest.json with version, channel, and SHA-256 checksums' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  pass "J24: release.yml summary matches artifact verification behavior"
else
  fail "J24: release.yml summary is stale for artifact verification behavior"
fi

if grep -q 'Builds, tags, and publishes' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  fail "J24: release.yml summary claims the workflow creates tags"
elif grep -q 'manually dispatch with an existing tag input' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  pass "J24: release.yml summary documents manual dispatch truthfully"
else
  fail "J24: release.yml summary does not document manual dispatch"
fi

# ── J25: first-party version metadata must match the umbrella version ────────
if python3 - "$ROOT" <<'PYEOF'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
errors = []

def read_text(path):
    return (root / path).read_text(encoding="utf-8")

def expect(label, value, expected):
    if value != expected:
        errors.append(f"{label}: {value!r} != {expected!r}")

mix_text = read_text("mix.exs")
mix_match = re.search(r'version:\s*"([^"]+)"', mix_text)
if not mix_match:
    errors.append("mix.exs: no version field found")
    mix_version = ""
else:
    mix_version = mix_match.group(1)
    if not re.fullmatch(r"\d{4}\.\d{1,2}\.\d+", mix_version):
        errors.append(f"mix.exs: {mix_version!r} is not CalVer YYYY.MM.PATCH")

package_json_paths = [
    "clients/lemon-tui/package.json",
    "clients/lemon-browser-node/package.json",
    "clients/lemon-web/package.json",
    "clients/lemon-web/server/package.json",
    "clients/lemon-web/shared/package.json",
    "clients/lemon-web/web/package.json",
]

for path in package_json_paths:
    with (root / path).open(encoding="utf-8") as f:
        data = json.load(f)
    expect(path, data.get("version"), mix_version)
    expect(f"{path}:engines.node", data.get("engines", {}).get("node"), ">=24.0.0")

package_lock_roots = [
    "clients/lemon-tui/package-lock.json",
    "clients/lemon-browser-node/package-lock.json",
]

for path in package_lock_roots:
    with (root / path).open(encoding="utf-8") as f:
        data = json.load(f)
    expect(f"{path}:packages['']", data.get("packages", {}).get("", {}).get("version"), mix_version)

with (root / "clients/lemon-web/package-lock.json").open(encoding="utf-8") as f:
    web_lock = json.load(f)
for package in ("server", "shared", "web"):
    expect(
        f"clients/lemon-web/package-lock.json:packages[{package!r}]",
        web_lock.get("packages", {}).get(package, {}).get("version"),
        mix_version,
    )

pyproject = read_text("clients/lemon-cli/pyproject.toml")
pyproject_match = re.search(r'(?m)^version = "([^"]+)"', pyproject)
expect("clients/lemon-cli/pyproject.toml", pyproject_match.group(1) if pyproject_match else None, mix_version)

uv_lock = read_text("clients/lemon-cli/uv.lock")
uv_match = re.search(r'(?ms)\[\[package\]\]\nname = "lemon-cli"\nversion = "([^"]+)"', uv_lock)
expect("clients/lemon-cli/uv.lock:[[package]] lemon-cli", uv_match.group(1) if uv_match else None, mix_version)

banner = read_text("clients/lemon-cli/src/lemon_cli/tui/banner.py")
banner_match = re.search(r"lemon-cli v(\d{4}\.\d{1,2}\.\d+)", banner)
expect("clients/lemon-cli/src/lemon_cli/tui/banner.py", banner_match.group(1) if banner_match else None, mix_version)

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J25: first-party version metadata matches mix.exs"
else
  fail "J25: first-party version metadata is inconsistent"
fi

# ── J26: live eval must stay opt-in, credential-backed, and documented ───────
LIVE_EVAL_WORKFLOW="$ROOT/.github/workflows/live-eval.yml"

if [ -f "$LIVE_EVAL_WORKFLOW" ]; then
  pass "J26: live-eval.yml exists"
else
  fail "J26: live-eval.yml is missing"
fi

if grep -q 'workflow_dispatch:' "$LIVE_EVAL_WORKFLOW" 2>/dev/null &&
   ! grep -qE '(^|[[:space:]])pull_request:|(^|[[:space:]])push:' "$LIVE_EVAL_WORKFLOW" 2>/dev/null; then
  pass "J26: live-eval.yml is manual-only"
else
  fail "J26: live-eval.yml must be workflow_dispatch-only"
fi

if grep -q 'otp-version: "28.5"' "$LIVE_EVAL_WORKFLOW" 2>/dev/null &&
   grep -q 'elixir-version: "1.19.5"' "$LIVE_EVAL_WORKFLOW" 2>/dev/null; then
  pass "J26: live-eval.yml uses supported BEAM toolchain"
else
  fail "J26: live-eval.yml does not use Elixir 1.19.5 / OTP 28.5"
fi

if grep -q 'secrets.LEMON_EVAL_API_KEY' "$LIVE_EVAL_WORKFLOW" 2>/dev/null &&
   grep -q 'scripts/test live-eval' "$LIVE_EVAL_WORKFLOW" 2>/dev/null; then
  pass "J26: live-eval.yml runs the canonical live-eval lane with secret-backed credentials"
else
  fail "J26: live-eval.yml must run scripts/test live-eval with LEMON_EVAL_API_KEY secret support"
fi

if grep -q 'live-eval.yml' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'live-eval.yml' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J26: live-eval workflow is documented"
else
  fail "J26: live-eval workflow is not documented in testing and release docs"
fi

# ── J27: final readiness audit must stay executable and documented ───────────
if [ -x "$ROOT/scripts/audit_1_0_readiness" ]; then
  pass "J27: final 1.0 readiness audit script is executable"
else
  fail "J27: scripts/audit_1_0_readiness is missing or not executable"
fi

READINESS_SCRIPTS=(
  scripts/audit_1_0_readiness
  scripts/prepare_release_notes
  scripts/verify_docs_site
  scripts/verify_release_artifacts
  scripts/verify_release_runtime_boot
  scripts/verify_source_install
)
READINESS_SCRIPT_MODE_ERRORS=()
for script in "${READINESS_SCRIPTS[@]}"; do
  if [ ! -x "$ROOT/$script" ]; then
    READINESS_SCRIPT_MODE_ERRORS+=("$script")
  fi
done

if [ "${#READINESS_SCRIPT_MODE_ERRORS[@]}" -eq 0 ]; then
  pass "J27: release-readiness scripts are executable"
else
  fail "J27: release-readiness scripts are not executable: ${READINESS_SCRIPT_MODE_ERRORS[*]}"
fi

if grep -q 'scripts/audit_1_0_readiness {version} {artifact-directory}' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/audit_1_0_readiness' "$ROOT/docs/plans/lemon-1.0-mainstream-readiness.md" 2>/dev/null; then
  pass "J27: final 1.0 readiness audit is documented"
else
  fail "J27: final 1.0 readiness audit is not documented in release docs and launch ledger"
fi

if grep -q 'gh workflow run live-eval.yml --ref v$VERSION' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'gh run watch {run-id} --exit-status' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_discord_matrix.py --channel-id' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null; then
  pass "J27: final readiness audit prints blocker next steps"
else
  fail "J27: final readiness audit does not print blocker next steps"
fi

if grep -q 'LEMON_DISCORD_LIVE_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_LIVE_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_live_redacted_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_user_inbound_prompt_round_trip' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_markdown_code_rendering' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_long_output_chunking' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_tool_success_failure_rendering' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_file_delivery' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_LIVE_PROOF_JSON=tmp/discord-live-proof.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_LIVE_REDACTED_PROOF_JSON=.lemon/proofs/discord-live-matrix-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/live_discord_matrix.py --channel-id 1475727417372049419' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires Discord external-sender live proof"
else
  fail "J27: final readiness audit does not require documented Discord external-sender live proof"
fi

if grep -q 'LEMON_DISCORD_MEDIA_SLASH_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_MEDIA_SLASH_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_media_slash_redacted_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ALL_SLASH_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ALL_SLASH_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_all_slash_redacted_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_all_slash_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'contains_media_slash_registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'contains_all_slash_registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_media_slash_registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_all_slash_registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--check-media-slash-registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--check-all-slash-registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_MEDIA_SLASH_PROOF_JSON=tmp/discord-media-slash-proof-check.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_MEDIA_SLASH_REDACTED_PROOF_JSON=.lemon/proofs/discord-media-slash-registration-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ALL_SLASH_PROOF_JSON=tmp/discord-all-slash-proof-check.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ALL_SLASH_REDACTED_PROOF_JSON=.lemon/proofs/discord-all-slash-registration-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--check-media-slash-registration' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--check-all-slash-registration' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires Discord media slash proof"
else
  fail "J27: final readiness audit does not require documented Discord media slash proof"
fi

if grep -q '^verify_media_directive_redacted_proofs$' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_TELEGRAM_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'telegram_forum_topic_media_directive_delivery' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_media_directive_delivery' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'contains_media_directive' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'directive_leaked' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--topic-media-directive-delivery' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--wait-media-directive-delivery' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_TELEGRAM_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON=.lemon/proofs/telegram-media-directive-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON=.lemon/proofs/discord-media-directive-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/telegram-media-directive-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/discord-media-directive-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires MEDIA directive proof"
else
  fail "J27: final readiness audit does not require documented MEDIA directive proof"
fi

if grep -q 'verify_discord_dm_redacted_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_free_response_redacted_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_slash_client_click_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_DM_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_FREE_RESPONSE_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_SLASH_CLIENT_CLICK_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_dm_prompt_round_trip' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_free_response_trigger_round_trip' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'message_content_intent_declared' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_slash_client_click_observed' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_slash_client_click_safe_mentions' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--wait-slash-client-click-proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'Discord DM proof reason_kind' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'Discord free-response proof reason_kind' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'Discord slash client-click proof reason_kind' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'real_client_click_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_DM_REDACTED_PROOF_JSON=.lemon/proofs/discord-dm-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_FREE_RESPONSE_REDACTED_PROOF_JSON=.lemon/proofs/discord-free-response-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_SLASH_CLIENT_CLICK_PROOF_JSON=.lemon/proofs/discord-slash-client-click-proof-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--wait-dm-inbound' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--wait-free-response-trigger' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--wait-slash-client-click-proof' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--check-slash-client-click-proof' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires Discord DM/free-response/client-click proof"
else
  fail "J27: final readiness audit does not require documented Discord DM/free-response/client-click proof"
fi

if grep -q 'verify_media_provider_proofs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_media_provider_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_IMAGE_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_SPEECH_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_TRANSCRIPTION_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_VISION_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_VIDEO_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_openai_image' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_vertex_imagen' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_openai_tts' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_elevenlabs_tts' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_google_tts' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_openai_transcribe' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_deepgram_transcribe' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_openai_vision' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_openai_video' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media_provider_vertex_veo' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'safe_reason_label' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media proof reason_kind' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media proof remediation hint' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'media proof rerun command' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'permission_denied' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'payment_required' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'provider_prefixed_model_not_supported_for_media_type' "$ROOT/scripts/live_media_image_smoke.exs" 2>/dev/null &&
   grep -q 'provider_prefixed_model_not_supported_for_media_type' "$ROOT/scripts/live_media_speech_smoke.exs" 2>/dev/null &&
   grep -q '@default_elevenlabs_voice_id' "$ROOT/scripts/live_media_speech_smoke.exs" 2>/dev/null &&
   grep -q 'provider_prefixed_model_not_supported_for_media_type' "$ROOT/scripts/live_media_transcription_smoke.exs" 2>/dev/null &&
   grep -q 'provider_prefixed_model_not_supported_for_media_type' "$ROOT/scripts/live_media_video_smoke.exs" 2>/dev/null &&
   grep -q 'provider-prefixed OpenAI-compatible routing' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'provider-prefixed OpenAI-compatible routing' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'openai_image_http_error:billing_limit_user_error' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'vertex_imagen_http_error:permission_denied' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'google_tts_http_error:permission_denied' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'vertex_veo_create_http_error:permission_denied' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q -- '--provider vertex_imagen' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--provider google_tts' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--provider vertex_veo' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'media_provider_vertex_imagen' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'media_provider_vertex_veo' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'google_tts' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'elevenlabs_tts_http_error:payment_required' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'deepgram_transcribe' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'Deepgram evidence' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'ElevenLabs proof script uses' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'lemon.media_image_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.media_speech_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.media_transcription_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.media_vision_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.media_video_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_IMAGE_PROOF_JSON=.lemon/proofs/media-image-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_SPEECH_PROOF_JSON=.lemon/proofs/media-speech-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_TRANSCRIPTION_PROOF_JSON=.lemon/proofs/media-transcription-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_VISION_PROOF_JSON=.lemon/proofs/media-vision-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_MEDIA_VIDEO_PROOF_JSON=.lemon/proofs/media-video-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_image_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_speech_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_transcription_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_vision_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_video_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_image_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_speech_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_transcription_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_vision_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mix run --no-start scripts/live_media_video_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'provider_live' "$ROOT/apps/lemon_core/lib/lemon_core/doctor/support_bundle.ex" 2>/dev/null &&
   grep -q 'provider_live' "$ROOT/apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs" 2>/dev/null &&
   grep -q '"providerProofs"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/media_status.ex" 2>/dev/null &&
   grep -q 'provider-backed media proof lane state' "$ROOT/apps/lemon_control_plane/README.md" 2>/dev/null &&
   grep -q 'redacted `provider_live` summary' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'JSON-RPC `media.status` also includes redacted provider-backed media proof' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'same `--provider` rerun flag' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-image-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-speech-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-transcription-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-vision-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-video-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-image-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-speech-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-transcription-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-vision-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--proof-path .lemon/proofs/media-video-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--api-key-secret SECRET_NAME' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q -- '--api-key-secret SECRET_NAME' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires provider-backed media proof"
else
  fail "J27: final readiness audit does not require documented provider-backed media proof"
fi

if grep -q 'verify_openai_compat_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_OPENAI_COMPAT_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_openai_compat_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q '.lemon/proofs/openai-compat-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'external_openai_sdk_client' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'external_python_sdk_client' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'non_vision_image_rejection' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_OPENAI_COMPAT_PROOF_JSON=.lemon/proofs/openai-compat-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'openai_compat.api_preview' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/live_openai_compat_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires OpenAI-compatible API proof"
else
  fail "J27: final readiness audit does not require documented OpenAI-compatible API proof"
fi

if grep -q 'verify_browser_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_BROWSER_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_browser_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q '.lemon/proofs/browser-smoke-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'browser_cdp_attach_completed' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'browser_analyze_model_visible_image_included' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'includes_raw_paths' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'includes_screenshot_bytes' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_BROWSER_PROOF_JSON=.lemon/proofs/browser-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'browser.preview' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/live_browser_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q '"liveProof"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/browser_status.ex" 2>/dev/null &&
   grep -q 'browser operator diagnostics through JSON-RPC `browser.status`' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'live browser proof' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J27: final readiness audit requires browser proof"
else
  fail "J27: final readiness audit does not require documented browser proof"
fi

if grep -q 'verify_acp_proofs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_ACP_STDIO_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_ACP_EXTERNAL_CLIENT_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_ACP_OFFICIAL_SDK_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_acp_stdio_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_acp_stdio_external_client.mjs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_acp_official_sdk_client.mjs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.acp_stdio_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.acp_stdio_external_client_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.acp_official_sdk_client_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_ACP_STDIO_PROOF_JSON=.lemon/proofs/acp-stdio-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_ACP_EXTERNAL_CLIENT_PROOF_JSON=.lemon/proofs/acp-stdio-external-client-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_ACP_OFFICIAL_SDK_PROOF_JSON=.lemon/proofs/acp-official-sdk-client-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'acp.preview' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires ACP proof"
else
  fail "J27: final readiness audit does not require documented ACP proof"
fi

if grep -q 'verify_mcp_proofs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MCP_STDIO_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MCP_HTTP_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MCP_SSE_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_mcp_stdio_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_mcp_http_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_mcp_sse_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mcp_stdio_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mcp_http_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'mcp_sse_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_MCP_STDIO_PROOF_JSON=.lemon/proofs/mcp-stdio-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_MCP_HTTP_PROOF_JSON=.lemon/proofs/mcp-http-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_MCP_SSE_PROOF_JSON=.lemon/proofs/mcp-sse-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'mcp.preview' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires MCP proof"
else
  fail "J27: final readiness audit does not require documented MCP proof"
fi

if grep -q 'verify_lsp_proofs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_LSP_REAL_REPO_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_lsp_server_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lsp_project_fixtures_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lsp_real_repo_fixtures_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON=.lemon/proofs/lsp-project-fixtures-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_LSP_REAL_REPO_PROOF_JSON=.lemon/proofs/lsp-real-repo-fixtures-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'lsp.preview' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'Map.put(:proofs, lsp_proof_status(project_dir))' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/lsp_diagnostics_status.ex" 2>/dev/null &&
   grep -q 'recent redacted LSP proof artifacts' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J27: final readiness audit requires LSP proof"
else
  fail "J27: final readiness audit does not require documented LSP proof"
fi

if grep -q 'verify_extension_proofs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_EXTENSION_HOST_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_WASM_TELEMETRY_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_WASM_POLICY_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_EXTENSION_REGISTRY_AUDIT_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_WASM_LIFECYCLE_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_extension_host_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_wasm_telemetry_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_wasm_policy_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_extension_registry_audit_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_wasm_lifecycle_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'extension_host_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'wasm_tool_telemetry_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'wasm_policy_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'extension_registry_audit_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'wasm_lifecycle_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_EXTENSION_HOST_PROOF_JSON=.lemon/proofs/extension-host-smoke-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_WASM_TELEMETRY_PROOF_JSON=.lemon/proofs/wasm-tool-telemetry-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_WASM_POLICY_PROOF_JSON=.lemon/proofs/wasm-policy-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_EXTENSION_REGISTRY_AUDIT_PROOF_JSON=.lemon/proofs/extension-registry-audit-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_WASM_LIFECYCLE_PROOF_JSON=.lemon/proofs/wasm-lifecycle-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'extensions.wasm_lifecycle' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires extension and WASM proof"
else
  fail "J27: final readiness audit does not require documented extension and WASM proof"
fi

if grep -q 'verify_terminal_backend_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_TERMINAL_BACKEND_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_terminal_backend_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q '.lemon/proofs/terminal-backend-latest.json' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'local_pty' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_TERMINAL_BACKEND_PROOF_JSON=.lemon/proofs/terminal-backend-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'terminal.backends_live' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/live_terminal_backend_smoke.exs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q '"liveProof"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/terminal_backends_status.ex" 2>/dev/null &&
   grep -q '"terminalHardening"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/terminal_backends_status.ex" 2>/dev/null &&
   grep -q 'Control-plane `terminal.backends.status` includes the same terminal live-proof' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J27: final readiness audit requires terminal backend proof"
else
  fail "J27: final readiness audit does not require documented terminal backend proof"
fi

if grep -q '"launchGates"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/proofs_status.ex" 2>/dev/null &&
   grep -q 'ProofLaunchGates.status' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/proofs_status.ex" 2>/dev/null &&
   grep -q '"discordDm"' "$ROOT/apps/lemon_core/lib/lemon_core/doctor/proof_launch_gates.ex" 2>/dev/null &&
   grep -q '"discordSlashRegistration"' "$ROOT/apps/lemon_core/lib/lemon_core/doctor/proof_launch_gates.ex" 2>/dev/null &&
   grep -q '"providerMedia"' "$ROOT/apps/lemon_core/lib/lemon_core/doctor/proof_launch_gates.ex" 2>/dev/null &&
   grep -q 'Discord slash registration' "$ROOT/apps/lemon_control_plane/README.md" 2>/dev/null &&
   grep -q 'launch-gate summaries' "$ROOT/apps/lemon_control_plane/README.md" 2>/dev/null &&
   grep -q 'Discord slash registration' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q '`launchGates` summary' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J27: proof status exposes launch-gate summaries"
else
  fail "J27: proof status launch-gate summaries are not documented"
fi

if grep -q '"launchGateStatuses"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/channels_status.ex" 2>/dev/null &&
   grep -q '"launchGateReasonKinds"' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/channels_status.ex" 2>/dev/null &&
   grep -q 'compact gate status/reason maps' "$ROOT/apps/lemon_control_plane/README.md" 2>/dev/null &&
   grep -q 'compact gate status/reason maps' "$ROOT/apps/lemon_control_plane/AGENTS.md" 2>/dev/null &&
   grep -q 'launchGateStatuses' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'launchGateReasonKinds' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J27: channel status exposes compact launch-gate summary maps"
else
  fail "J27: channel status launch-gate summary maps are not documented"
fi

if grep -q 'verify_cron_proofs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_CRON_DIAGNOSTICS_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_CRON_RUNTIME_RESTART_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_CRON_CHANNEL_ORIGIN_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_cron_diagnostics_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_cron_runtime_restart_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/live_cron_channel_origin_smoke.exs' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.cron_diagnostics_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.cron_runtime_restart_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'lemon.cron_channel_origin_smoke' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_CRON_DIAGNOSTICS_PROOF_JSON=.lemon/proofs/cron-diagnostics-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_CRON_RUNTIME_RESTART_PROOF_JSON=.lemon/proofs/cron-runtime-restart-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_CRON_CHANNEL_ORIGIN_PROOF_JSON=.lemon/proofs/cron-channel-origin-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'cron.preview' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'suppressedSlotCount' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/cron_status.ex" 2>/dev/null &&
   grep -q 'retryScheduledCount' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/cron_status.ex" 2>/dev/null &&
   grep -q 'control-plane `cron.status` surfaces cron scheduler health' "$ROOT/docs/support.md" 2>/dev/null; then
  pass "J27: final readiness audit requires cron proof"
else
  fail "J27: final readiness audit does not require documented cron proof"
fi

if grep -q 'verify_public_support_boundaries' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'OpenAI-compatible API server behavior' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'ACP editor integration' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'checkpointing for destructive shell commands' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'first-class browser automation' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'production support for third-party plugins' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'Discord support is bounded to the live-proven path' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'Discord behavior beyond the live-proven text-first and file-delivery boundary' "$ROOT/docs/compare.md" 2>/dev/null &&
   grep -q 'stable Telegram and Discord text-first support' "$ROOT/docs/compare.md" 2>/dev/null; then
  pass "J27: final readiness audit enforces public Hermes-gap support boundaries"
else
  fail "J27: public support docs do not consistently bound unresolved Hermes-only surfaces"
fi

if grep -q 'verify_channel_command_matrix' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md' "$ROOT/docs/README.md" 2>/dev/null &&
   grep -q 'lemon-channel-command-parity-matrix-2026-05-12' "$ROOT/docs/.vitepress/config.js" 2>/dev/null &&
   grep -q 'Stable Telegram text-first command boundary' "$ROOT/docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'Preview Discord command boundary' "$ROOT/docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'Hermes drop-in command parity is not a Lemon 1.0 claim' "$ROOT/docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md" 2>/dev/null; then
  pass "J27: final readiness audit requires bounded channel command parity matrix"
else
  fail "J27: channel command parity matrix is missing, unlinked, or not bounded"
fi

if grep -q 'rollback_command_schema/0' "$ROOT/scripts/live_discord_matrix.py" 2>/dev/null &&
   grep -q -- '--check-rollback-slash-registration' "$ROOT/scripts/live_discord_matrix.py" 2>/dev/null &&
   grep -q -- '--register-rollback-slash-command' "$ROOT/scripts/live_discord_matrix.py" 2>/dev/null &&
   grep -q 'contains_rollback_slash_registration' "$ROOT/scripts/live_discord_matrix.py" 2>/dev/null &&
   grep -q 'verify_discord_rollback_slash_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'verify_discord_rollback_slash_redacted_proof' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ROLLBACK_SLASH_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ROLLBACK_SLASH_REDACTED_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_rollback_slash_registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'contains_rollback_slash_registration' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'expected != 16' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'contains_rollback_slash_registration' "$ROOT/apps/lemon_core/lib/lemon_core/doctor/proof_diagnostics.ex" 2>/dev/null &&
   grep -q 'containsRollbackSlashRegistration' "$ROOT/apps/lemon_control_plane/lib/lemon_control_plane/methods/proofs_status.ex" 2>/dev/null &&
   grep -q '"rollback"' "$ROOT/apps/lemon_core/lib/lemon_core/doctor/channel_diagnostics.ex" 2>/dev/null &&
   grep -q 'Rollback: `/rollback`' "$ROOT/docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'checkpoint/rollback/kanban/media' "$ROOT/docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'contains_rollback_slash_registration' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ROLLBACK_SLASH_PROOF_JSON=tmp/discord-rollback-slash-proof-check.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_ROLLBACK_SLASH_REDACTED_PROOF_JSON=.lemon/proofs/discord-rollback-slash-registration-latest.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--check-rollback-slash-registration' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '--register-rollback-slash-command' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q -- '--check-rollback-slash-registration' "$ROOT/docs/testing.md" 2>/dev/null; then
  pass "J27: rollback slash alias, audit gate, and proof coverage stay documented"
else
  fail "J27: rollback slash alias, audit gate, or proof coverage documentation drifted"
fi

if grep -q 'Do not use both paths' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '-f channel=stable' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'refusing to publish with a dirty tree' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git log -1 --oneline' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git rev-list --count origin/main..HEAD' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git log --oneline origin/main..HEAD' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git push origin main' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: release handoff docs avoid duplicate workflow runs"
else
  fail "J27: release handoff docs do not require pushing readiness changes before tag publish or do not distinguish tag-push and manual-dispatch paths"
fi

if grep -q 'gh run watch {run-id} --exit-status' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'gh run watch {run-id} --exit-status' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'gh run watch {run-id} --exit-status' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'gh run watch {run-id} --exit-status' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null; then
  pass "J27: live-eval handoff requires watching the intended run"
else
  fail "J27: live-eval handoff does not require watching the intended run"
fi

if grep -q 'gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null; then
  pass "J27: live-eval handoff documents repository secret setup"
else
  fail "J27: live-eval handoff does not document repository secret setup"
fi

# ── J28: first-party BEAM toolchain pins must stay current ───────────────────
if python3 - "$ROOT" <<'PYEOF'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
errors = []

for workflow in sorted((root / ".github" / "workflows").glob("*.yml")):
    content = workflow.read_text(encoding="utf-8")
    for field, expected in (("otp-version", "28.5"), ("elixir-version", "1.19.5")):
        for match in re.finditer(rf"{field}:\s*['\"]?([^'\"\s]+)", content):
            if match.group(1) != expected:
                errors.append(f"{workflow.relative_to(root)}: expected {field}: {expected}, found {match.group(1)}")

sim_ui_dockerfile = root / "apps" / "lemon_sim_ui" / "Dockerfile"
sim_ui = sim_ui_dockerfile.read_text(encoding="utf-8")
if "hexpm/elixir:1.19.5-erlang-28.5-" not in sim_ui:
    errors.append("apps/lemon_sim_ui/Dockerfile: build image is not pinned to Elixir 1.19.5 / Erlang 28.5")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J28: first-party BEAM toolchain pins use Elixir 1.19.5 / OTP 28.5"
else
  fail "J28: first-party BEAM toolchain pins are stale"
fi

# ── J29: final audit must include public docs-site verification ──────────────
if [ -x "$ROOT/scripts/verify_docs_site" ]; then
  pass "J29: docs-site verifier script is executable"
else
  fail "J29: scripts/verify_docs_site is missing or not executable"
fi

if grep -q 'scripts/verify_docs_site' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/verify_docs_site' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J29: final readiness audit includes documented docs-site verification"
else
  fail "J29: final readiness audit does not include documented docs-site verification"
fi

# ── J30: final audit must include canonical local release-candidate tests ────
if grep -q 'scripts/test fast' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/test quality' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/test eval-fast' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'scripts/test clients' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null; then
  pass "J30: final readiness audit runs canonical local test lanes"
else
  fail "J30: final readiness audit is missing one or more canonical local test lanes"
fi

if grep -q 'scripts/test fast' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/test quality' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/test eval-fast' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/test clients' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J30: release checklist documents canonical local test lanes"
else
  fail "J30: release checklist does not document all canonical local test lanes"
fi

# ── J31: OSV supply-chain scan parity must stay wired and documented ────────
if grep -q 'google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@c51854704019a247608d928f370c98740469d4b5' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q 'security-events: write' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=mix.lock' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=clients/lemon-cli/uv.lock' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=clients/lemon-web/package-lock.json' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=clients/lemon-tui/package-lock.json' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=clients/lemon-browser-node/package-lock.json' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=apps/lemon_gateway/priv/package-lock.json' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q -- '--lockfile=tools/diagrams/package-lock.json' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q 'fail-on-vuln: false' "$ROOT/.github/workflows/osv-scanner.yml" 2>/dev/null &&
   grep -q 'OSV Scanner workflow' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q '94c523f0c' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null; then
  pass "J31: OSV scanner supply-chain parity workflow is documented"
else
  fail "J31: OSV scanner supply-chain parity workflow is missing or undocumented"
fi

# ── J32: PR history integrity check must stay wired and documented ───────────
if grep -q 'name: History Check' "$ROOT/.github/workflows/history-check.yml" 2>/dev/null &&
   grep -q 'pull_request:' "$ROOT/.github/workflows/history-check.yml" 2>/dev/null &&
   grep -q 'fetch-depth: 0' "$ROOT/.github/workflows/history-check.yml" 2>/dev/null &&
   grep -q 'git merge-base "origin/${GITHUB_BASE_REF}" HEAD' "$ROOT/.github/workflows/history-check.yml" 2>/dev/null &&
   grep -q 'no common ancestor' "$ROOT/.github/workflows/history-check.yml" 2>/dev/null &&
   grep -q 'History Check workflow' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'unrelated-history PRs' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'history-check.yml' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q '94c523f0c' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null; then
  pass "J32: PR history integrity check is wired and documented"
else
  fail "J32: PR history integrity check is missing or undocumented"
fi

# ── J33: Python CLI package checks must stay wired and documented ────────────
if grep -q 'name: Python CLI' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'python-version: "3.13"' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'astral-sh/setup-uv@v6' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'uv sync --locked --dev' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'uv run ruff check src tests' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'uv run pytest' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'uv build --sdist --wheel' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'lemon-cli-distributions' "$ROOT/.github/workflows/python-cli.yml" 2>/dev/null &&
   grep -q 'uv run ruff check src tests' "$ROOT/scripts/test" 2>/dev/null &&
   grep -q 'uv build --sdist --wheel' "$ROOT/scripts/test" 2>/dev/null &&
   grep -q 'lemon-cli' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'Python CLI package workflow' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'PyPI-style CLI package' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null; then
  pass "J33: Python CLI package check workflow is wired and documented"
else
  fail "J33: Python CLI package check workflow is missing or undocumented"
fi

# ── J34: Script-send CLI must stay scoped to Telegram/Discord and documented ─
if grep -q 'defmodule LemonChannels.ScriptSend' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q '@supported_platforms ~w(discord telegram)' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'defmodule Mix.Tasks.Lemon.Send' "$ROOT/apps/lemon_channels/lib/mix/tasks/lemon.send.ex" 2>/dev/null &&
   grep -q 'defp exit_code(:missing_target), do: 2' "$ROOT/apps/lemon_channels/lib/mix/tasks/lemon.send.ex" 2>/dev/null &&
   grep -q 'use - to force stdin' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'attach: :keep' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'normalize_attachments' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'attachment_filename' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'attachment_count' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'telegram_target_aliases' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'discord_target_aliases' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'gateway_section_value(:telegram' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'gateway_section_value(:discord' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'default_account_id("telegram"' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'account: :string' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'thread: :string' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'topic: :string' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'reply_to: :string' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'payload_account_id' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'normalize_thread_option' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'normalize_reply_to' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'filter_known_targets_by_account' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q -- '--account ID' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q -- '--thread ID' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q -- '--topic ID' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q -- '--reply-to ID' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'dry_run: :boolean' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'maybe_deliver(payload, %{dry_run?: true}' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'delivery_message_ids' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'at most #{max} --attach files are supported' "$ROOT/apps/lemon_channels/lib/mix/tasks/lemon.send.ex" 2>/dev/null &&
   grep -q 'alias_suffix' "$ROOT/apps/lemon_channels/lib/mix/tasks/lemon.send.ex" 2>/dev/null &&
   grep -q 'batch_file_params' "$ROOT/apps/lemon_channels/lib/lemon_channels/adapters/discord/outbound.ex" 2>/dev/null &&
   grep -q 'delivery_message_id' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'known_targets("telegram", account_id)' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'resolve_telegram_named_target' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'telegram:@username' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
	   grep -q 'known_targets("discord", account_id)' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'resolve_discord_named_target' "$ROOT/apps/lemon_channels/lib/lemon_channels/script_send.ex" 2>/dev/null &&
   grep -q 'def list_available' "$ROOT/apps/lemon_channels/lib/lemon_channels/telegram/known_target_store.ex" 2>/dev/null &&
   grep -q 'defmodule LemonChannels.Discord.KnownTargetStore' "$ROOT/apps/lemon_channels/lib/lemon_channels/discord/known_target_store.ex" 2>/dev/null &&
   grep -q 'maybe_index_known_target' "$ROOT/apps/lemon_channels/lib/lemon_channels/adapters/discord/transport.ex" 2>/dev/null &&
   grep -q 'LemonChannels.Telegram.KnownTargetStore' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'resolves unique Telegram known chat names' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'resolves unique Telegram known topic names' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'parses default targets from gateway config' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'environment default targets and accounts take precedence over gateway config' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'default account scopes known-name resolution' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'scopes Discord known-name resolution by account' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'filters known targets by account for list mode' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'parses standalone thread and topic target options' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'rejects conflicting thread target options' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'builds and delivers payload with reply target' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'rejects empty reply target' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
	   grep -q 'telegram:#Lemon Ops:Deploys' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'LemonChannels.Discord.KnownTargetStore' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'discord:#ops' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'discord:#ops:deploys' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'builds and delivers Telegram attachment payload' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'builds and delivers multiple Discord attachment payloads' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'preserves Telegram batch attachment message ids' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'dry run validates attachment payload without delivery' "$ROOT/apps/lemon_channels/test/lemon_channels/script_send_test.exs" 2>/dev/null &&
   grep -q 'file delivery uploads a bounded file batch' "$ROOT/apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs" 2>/dev/null &&
   grep -q './bin/lemon send --to telegram:<chat_id>' "$ROOT/README.md" 2>/dev/null &&
   grep -q -- '--attach' "$ROOT/README.md" 2>/dev/null &&
   grep -q -- '--dry-run' "$ROOT/README.md" 2>/dev/null &&
   grep -q 'repeated `--attach` uploads up to 10 files' "$ROOT/README.md" 2>/dev/null &&
   grep -q 'Telegram/Discord known-target windows' "$ROOT/README.md" 2>/dev/null &&
	   grep -q 'exact reusable aliases' "$ROOT/README.md" 2>/dev/null &&
	   grep -q 'env/config defaults' "$ROOT/README.md" 2>/dev/null &&
	   grep -q -- '--account <id>' "$ROOT/README.md" 2>/dev/null &&
	   grep -q 'LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID' "$ROOT/README.md" 2>/dev/null &&
	   grep -q -- '--thread <id-or-name>' "$ROOT/README.md" 2>/dev/null &&
	   grep -q -- '--topic <id-or-name>' "$ROOT/README.md" 2>/dev/null &&
	   grep -q -- '--reply-to <message-id>' "$ROOT/README.md" 2>/dev/null &&
	   grep -q 'discord:#ops' "$ROOT/README.md" 2>/dev/null &&
   grep -q 'telegram:@lemon_ops' "$ROOT/README.md" 2>/dev/null &&
   grep -q './bin/lemon send --to telegram:<chat_id>' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q -- '--attach' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q -- '--dry-run' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'dry_run' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'attachment_filename' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'attachment_count' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'extra_message_ids' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q './bin/lemon send --list telegram' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'known_targets' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q 'exact reusable `aliases`' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q 'config fallbacks' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q -- '--account <id>' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q 'Default account ids' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q -- '--thread <id-or-name>' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q -- '--topic <id-or-name>' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q -- '--reply-to <message-id>' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
	   grep -q 'LemonChannels.Discord.KnownTargetStore' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'discord:#channel:thread-name' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'telegram:@username' "$ROOT/apps/lemon_channels/README.md" 2>/dev/null &&
   grep -q 'MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q -- '--file -' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'bounded `message_id` extraction' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'repeated `--attach` payload construction up to 10 files' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'batch delivery `extra_message_ids` extraction' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'list-mode alias metadata' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'config-backed default targets' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'account-scoped delivery and known-target resolution' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'config-backed default account ids' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'standalone thread/topic target overrides' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'reply-to payload routing' "$ROOT/docs/testing.md" 2>/dev/null &&
	   grep -q 'dry-run validation without delivery' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'attachment usage/input failures return `2`' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'usage/config/input failures return `2`' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'Telegram known-target discovery' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'unique Telegram known-name resolution' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'Discord known-target discovery' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'unique Discord known-name resolution' "$ROOT/docs/testing.md" 2>/dev/null &&
   grep -q 'ScriptSend.run/2' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
   grep -q -- '--attach' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
   grep -q -- '--dry-run' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q 'exact reusable `aliases`' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q 'config fallbacks' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q -- '--account <id>' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q 'LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q -- '--thread <id-or-name>' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q -- '--topic <id-or-name>' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q -- '--reply-to <message-id>' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q 'telegram:@username' "$ROOT/apps/lemon_channels/AGENTS.md" 2>/dev/null &&
	   grep -q 'default_chat_id' "$ROOT/docs/config.md" 2>/dev/null &&
	   grep -q 'default_channel_id' "$ROOT/docs/config.md" 2>/dev/null &&
	   grep -q 'default_account_id' "$ROOT/docs/config.md" 2>/dev/null &&
	   grep -q 'default_chat_id' "$ROOT/examples/config.example.toml" 2>/dev/null &&
	   grep -q 'default_account_id' "$ROOT/examples/config.example.toml" 2>/dev/null &&
	   grep -q 'default_channel_id' "$ROOT/examples/config.example.toml" 2>/dev/null &&
	   grep -q 'default_channel_id' "$ROOT/apps/lemon_core/lib/lemon_core/config/gateway.ex" 2>/dev/null &&
	   grep -q 'Telegram/Discord `./bin/lemon send` script notification path' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'BEAM-store known-target discovery' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'exact list-mode aliases' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'config-backed default targets' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'default account ids' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'account-scoped delivery and known-target resolution' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'standalone thread/topic' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'reply-to payload routing' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
	   grep -q 'unique Telegram/Discord known-name resolution' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'LemonChannels.Discord.KnownTargetStore' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'discord:#channel:thread-name' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'bounded multi-attachment script artifact uploads' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'credential-free dry-run validation' "$ROOT/docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md" 2>/dev/null &&
   grep -q 'Slice 373: Script-send multi-attachment uploads' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
   grep -q 'Slice 374: Script-send batch delivery ids' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
   grep -q 'Slice 375: Script-send dry-run validation' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 376: Telegram named script-send target resolution' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 377: Script-send list aliases' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 378: Script-send config defaults' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 379: Script-send account selection' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 380: Script-send thread and topic options' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 381: Script-send default account ids' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'Slice 382: Script-send reply-to routing' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null &&
	   grep -q 'attachment_filename' "$ROOT/docs/plans/lemon-hermes-agent-harness-parity-scorecard.md" 2>/dev/null; then
  pass "J34: script-send Telegram/Discord command is scoped and documented"
else
  fail "J34: script-send command scope or documentation is missing"
fi

# ── manual-dispatch: release.yml must use input tag, not ref_name, for dispatch ─
# When event_name is workflow_dispatch, github.ref_name is the branch, not the tag.
# The parse step and the gh-release tag_name must prioritize event.inputs.tag.
if grep -qE 'github\.ref_name\s*\|\|.*github\.event\.inputs\.tag' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  fail "extra: release.yml uses 'ref_name || event.inputs.tag' order — manual dispatch will use branch name instead of requested tag"
else
  pass "extra: release.yml tag resolution order is correct for manual dispatch"
fi

if python3 - "$ROOT/.github/workflows/release.yml" <<'PYEOF'
import re, sys

content = open(sys.argv[1], encoding="utf-8").read()
checkout_blocks = re.findall(r'- name: Checkout\n(?: {2,}.*\n)+', content)
if not checkout_blocks:
    sys.exit(1)

for block in checkout_blocks:
    if "uses: actions/checkout@v4" not in block:
        continue
    if "ref: ${{ github.event.inputs.tag || github.ref_name }}" not in block:
        sys.exit(1)
PYEOF
then
  pass "extra: release.yml pins each checkout step to the requested tag ref"
else
  fail "extra: release.yml has a checkout step that does not pin ref to the requested tag"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS check(s) failed." >&2
  exit 1
else
  echo "All checks passed."
fi
