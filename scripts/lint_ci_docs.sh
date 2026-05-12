#!/usr/bin/env bash
# Lint script for CI/docs policy checks (tasks C9, C10, C11, J17, J18, J19, J20, J22, J23, J24, J25, J26, J27, J28, J29, J30, manual-dispatch)
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
  fail "J24: release.yml does not call scripts/prepare_release_notes for GitHub Release body"
fi

if grep -qE 'Release \$?\{?VERSION\}?|see CHANGELOG\.md for details' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  fail "J24: release.yml contains a generic fallback release-note body"
else
  pass "J24: release.yml has no generic fallback release-note body"
fi

if [ -x "$ROOT/scripts/verify_github_release_artifacts" ] &&
   [ -x "$ROOT/scripts/verify_release_runtime_boot" ] &&
   grep -q 'scripts/verify_github_release_artifacts {tag-or-version}' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J24: public GitHub Release artifact verifier is documented"
else
  fail "J24: public GitHub Release artifact verifier or runtime boot verifier is missing or undocumented"
fi

if grep -q 'scripts/verify_release_runtime_boot' "$ROOT/scripts/verify_github_release_artifacts" 2>/dev/null &&
   grep -q 'scripts/verify_release_runtime_boot {artifact-directory}' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J24: published artifact verifier boots downloaded release artifacts"
else
  fail "J24: published artifact verifier does not run documented runtime boot verification"
fi

if grep -q 'verify-published-artifacts:' "$ROOT/.github/workflows/release.yml" 2>/dev/null &&
   grep -q 'scripts/verify_github_release_artifacts "v${{ needs.validate.outputs.version }}"' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  pass "J24: release.yml verifies published GitHub Release artifacts"
else
  fail "J24: release.yml does not verify published GitHub Release artifacts after upload"
fi

if grep -q 'scripts/verify_release_artifacts release-artifacts' "$ROOT/.github/workflows/release.yml" 2>/dev/null &&
   grep -q 'fail_on_unmatched_files: true' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
  pass "J24: release.yml verifies assembled artifacts before publishing"
else
  fail "J24: release.yml can publish without verifying assembled artifacts"
fi

if grep -q 'Verify the assembled artifact directory before publishing' "$ROOT/.github/workflows/release.yml" 2>/dev/null &&
   grep -q 'generate support bundles' "$ROOT/.github/workflows/release.yml" 2>/dev/null; then
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
  scripts/verify_github_release_artifacts
  scripts/verify_release_artifacts
  scripts/verify_release_runtime_boot
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

if grep -q 'scripts/verify_github_release_artifacts $VERSION' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'gh workflow run live-eval.yml --ref v$VERSION' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'gh run watch {run-id} --exit-status' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'Option A: push the tag' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'Do not run both paths' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null; then
  pass "J27: final readiness audit prints blocker next steps"
else
  fail "J27: final readiness audit does not print blocker next steps"
fi

if grep -q 'remote_preflight' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'git ls-remote --tags origin' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'gh run list --workflow release.yml' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'gh run list --workflow live-eval.yml' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'gh secret list' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'remote preflight evidence' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit reports remote launch preflight evidence"
else
  fail "J27: final readiness audit does not report remote launch preflight evidence"
fi

if grep -q 'LEMON_DISCORD_LIVE_PROOF_JSON' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_user_inbound_prompt_round_trip' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_markdown_code_rendering' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_long_output_chunking' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_tool_success_failure_rendering' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'discord_file_delivery' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'LEMON_DISCORD_LIVE_PROOF_JSON=tmp/discord-live-proof.json' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'scripts/live_discord_matrix.py --channel-id 1475727417372049419' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null; then
  pass "J27: final readiness audit requires Discord non-bot live proof"
else
  fail "J27: final readiness audit does not require documented Discord non-bot live proof"
fi

if grep -q 'verify_public_support_boundaries' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'OpenAI-compatible API server behavior' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'ACP editor integration' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'automatic filesystem checkpointing or rollback' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'first-class browser automation' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'production support for third-party plugins' "$ROOT/docs/support.md" 2>/dev/null &&
   grep -q 'stable Discord support until the non-bot live matrix passes' "$ROOT/docs/compare.md" 2>/dev/null &&
   grep -q 'preview Discord/gateway adapters' "$ROOT/docs/compare.md" 2>/dev/null; then
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

if grep -q 'Do not use both paths' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'Do not run both paths' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q -- '-f channel=stable' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q -- '-f channel=stable' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'refusing to publish with a dirty tree' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'refusing to publish with a dirty tree' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'refusing to publish with a dirty tree' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'git log -1 --oneline' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'git log -1 --oneline' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git log -1 --oneline' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'git rev-list --count origin/main..HEAD' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'git rev-list --count origin/main..HEAD' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git rev-list --count origin/main..HEAD' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'git log --oneline origin/main..HEAD' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'git log --oneline origin/main..HEAD' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git log --oneline origin/main..HEAD' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null &&
   grep -q 'git push origin main' "$ROOT/scripts/audit_1_0_readiness" 2>/dev/null &&
   grep -q 'git push origin main' "$ROOT/docs/release/release_checklist_and_support_policy.md" 2>/dev/null &&
   grep -q 'git push origin main' "$ROOT/docs/plans/lemon-1.0-completion-audit-2026-05-12.md" 2>/dev/null; then
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
