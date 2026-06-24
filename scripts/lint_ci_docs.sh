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

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
script = root / "scripts/verify_release_runtime_boot"
requirements = [
    ("docs/release/release_checklist_and_support_policy.md", "scripts/verify_release_runtime_boot {artifact-directory}"),
    ("scripts/verify_release_runtime_boot", "channel_readiness.json"),
    ("scripts/verify_release_runtime_boot", "readiness_summary.json"),
    ("docs/release/release_checklist_and_support_policy.md", "channel_readiness.json"),
    ("docs/release/release_checklist_and_support_policy.md", "readiness_summary.json"),
    ("docs/support.md", "channel_readiness.json"),
    ("docs/support.md", "readiness_summary.json"),
]
missing = []
if not script.exists() or not script.stat().st_mode & 0o111:
    missing.append("scripts/verify_release_runtime_boot is missing or not executable")

contents = {}
for relative_path, token in requirements:
    content = contents.setdefault(
        relative_path,
        (root / relative_path).read_text(encoding="utf-8"),
    )
    if token not in content:
        missing.append(f"{relative_path} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J24: runtime boot verifier is documented"
else
  fail "J24: runtime boot verifier is missing or undocumented"
fi

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / ".github/workflows/release.yml"
content = path.read_text(encoding="utf-8")
tokens = [
    "scripts/verify_release_artifacts release-artifacts",
    "fail_on_unmatched_files: true",
]
missing = [token for token in tokens if token not in content]
if missing:
    print("\n".join(f"{path.relative_to(root)} missing {token!r}" for token in missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J24: release.yml verifies assembled artifacts before publishing"
else
  fail "J24: release.yml can publish without verifying assembled artifacts"
fi

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / ".github/workflows/release.yml"
content = path.read_text(encoding="utf-8")
tokens = [
    "Verify the assembled artifact directory before publishing",
    "Generate a manifest.json with version, channel, and SHA-256 checksums",
]
missing = [token for token in tokens if token not in content]
if missing:
    print("\n".join(f"{path.relative_to(root)} missing {token!r}" for token in missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
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

if python3 - "$LIVE_EVAL_WORKFLOW" <<'PYEOF'
from pathlib import Path
import re
import sys

content = Path(sys.argv[1]).read_text(encoding="utf-8")
if "workflow_dispatch:" not in content:
    sys.exit(1)
if re.search(r"(^|[ \t])pull_request:|(^|[ \t])push:", content, re.M):
    sys.exit(1)
PYEOF
then
  pass "J26: live-eval.yml is manual-only"
else
  fail "J26: live-eval.yml must be workflow_dispatch-only"
fi

if python3 - "$LIVE_EVAL_WORKFLOW" <<'PYEOF'
from pathlib import Path
import sys

content = Path(sys.argv[1]).read_text(encoding="utf-8")
tokens = ['otp-version: "28.5"', 'elixir-version: "1.19.5"']
missing = [token for token in tokens if token not in content]
if missing:
    print("\n".join(f"live-eval.yml missing {token!r}" for token in missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J26: live-eval.yml uses supported BEAM toolchain"
else
  fail "J26: live-eval.yml does not use Elixir 1.19.5 / OTP 28.5"
fi

if python3 - "$LIVE_EVAL_WORKFLOW" <<'PYEOF'
from pathlib import Path
import sys

content = Path(sys.argv[1]).read_text(encoding="utf-8")
tokens = ["secrets.LEMON_EVAL_API_KEY", "scripts/test live-eval"]
missing = [token for token in tokens if token not in content]
if missing:
    print("\n".join(f"live-eval.yml missing {token!r}" for token in missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J26: live-eval.yml runs the canonical live-eval lane with secret-backed credentials"
else
  fail "J26: live-eval.yml must run scripts/test live-eval with LEMON_EVAL_API_KEY secret support"
fi

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
requirements = [
    ("docs/testing.md", "live-eval.yml"),
    ("docs/release/release_checklist_and_support_policy.md", "live-eval.yml"),
]
missing = []
for relative_path, token in requirements:
    content = (root / relative_path).read_text(encoding="utf-8")
    if token not in content:
        missing.append(f"{relative_path} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
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

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = {
    "audit": root / "scripts/audit_1_0_readiness",
    "release_docs": root / "docs/release/release_checklist_and_support_policy.md",
    "launch_ledger": root / "docs/plans/lemon-1.0-mainstream-readiness.md",
}
contents = {name: path.read_text(encoding="utf-8") for name, path in files.items()}

contracts = [
    (
        "final 1.0 readiness audit is documented",
        [
            ("release_docs", "scripts/audit_1_0_readiness {version} {artifact-directory}"),
            ("launch_ledger", "scripts/audit_1_0_readiness"),
        ],
    ),
    (
        "final readiness audit prints blocker next steps",
        [
            ("audit", "gh workflow run live-eval.yml --ref v$VERSION"),
            ("audit", "gh run watch {run-id} --exit-status"),
            ("audit", "scripts/live_discord_matrix.py --channel-id"),
        ],
    ),
    (
        "final readiness audit requires Discord external-sender live proof",
        [
            ("audit", "LEMON_DISCORD_LIVE_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_LIVE_REDACTED_PROOF_JSON"),
            ("audit", "verify_discord_live_redacted_proof"),
            ("audit", "discord_user_inbound_prompt_round_trip"),
            ("audit", "discord_markdown_code_rendering"),
            ("audit", "discord_long_output_chunking"),
            ("audit", "discord_tool_success_failure_rendering"),
            ("audit", "discord_file_delivery"),
            ("release_docs", "LEMON_DISCORD_LIVE_PROOF_JSON=tmp/discord-live-proof.json"),
            (
                "release_docs",
                "LEMON_DISCORD_LIVE_REDACTED_PROOF_JSON=.lemon/proofs/discord-live-matrix-latest.json",
            ),
            ("release_docs", "scripts/live_discord_matrix.py --channel-id 1475727417372049419"),
        ],
    ),
    (
        "final readiness audit requires Discord media slash proof",
        [
            ("audit", "LEMON_DISCORD_MEDIA_SLASH_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_MEDIA_SLASH_REDACTED_PROOF_JSON"),
            ("audit", "verify_discord_media_slash_redacted_proof"),
            ("audit", "LEMON_DISCORD_ALL_SLASH_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_ALL_SLASH_REDACTED_PROOF_JSON"),
            ("audit", "verify_discord_all_slash_redacted_proof"),
            ("audit", "verify_discord_all_slash_proof"),
            ("audit", "contains_media_slash_registration"),
            ("audit", "contains_all_slash_registration"),
            ("audit", "discord_media_slash_registration"),
            ("audit", "discord_all_slash_registration"),
            ("audit", "--check-media-slash-registration"),
            ("audit", "--check-all-slash-registration"),
            (
                "release_docs",
                "LEMON_DISCORD_MEDIA_SLASH_PROOF_JSON=tmp/discord-media-slash-proof-check.json",
            ),
            (
                "release_docs",
                "LEMON_DISCORD_MEDIA_SLASH_REDACTED_PROOF_JSON=.lemon/proofs/discord-media-slash-registration-latest.json",
            ),
            (
                "release_docs",
                "LEMON_DISCORD_ALL_SLASH_PROOF_JSON=tmp/discord-all-slash-proof-check.json",
            ),
            (
                "release_docs",
                "LEMON_DISCORD_ALL_SLASH_REDACTED_PROOF_JSON=.lemon/proofs/discord-all-slash-registration-latest.json",
            ),
            ("release_docs", "--check-media-slash-registration"),
            ("release_docs", "--check-all-slash-registration"),
        ],
    ),
    (
        "final readiness audit requires MEDIA directive proof",
        [
            ("audit", "verify_media_directive_redacted_proofs"),
            ("audit", "LEMON_TELEGRAM_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON"),
            ("audit", "telegram_forum_topic_media_directive_delivery"),
            ("audit", "discord_media_directive_delivery"),
            ("audit", "contains_media_directive"),
            ("audit", "directive_leaked"),
            ("audit", "--topic-media-directive-delivery"),
            ("audit", "--wait-media-directive-delivery"),
            (
                "release_docs",
                "LEMON_TELEGRAM_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON=.lemon/proofs/telegram-media-directive-latest.json",
            ),
            (
                "release_docs",
                "LEMON_DISCORD_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON=.lemon/proofs/discord-media-directive-latest.json",
            ),
            ("release_docs", "--proof-path .lemon/proofs/telegram-media-directive-latest.json"),
            ("release_docs", "--proof-path .lemon/proofs/discord-media-directive-latest.json"),
        ],
    ),
    (
        "final readiness audit requires Discord DM/free-response/client-click proof",
        [
            ("audit", "verify_discord_dm_redacted_proof"),
            ("audit", "verify_discord_free_response_redacted_proof"),
            ("audit", "verify_discord_slash_client_click_proof"),
            ("audit", "LEMON_DISCORD_DM_REDACTED_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_FREE_RESPONSE_REDACTED_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_SLASH_CLIENT_CLICK_PROOF_JSON"),
            ("audit", "discord_dm_prompt_round_trip"),
            ("audit", "discord_free_response_trigger_round_trip"),
            ("audit", "message_content_intent_declared"),
            ("audit", "discord_slash_client_click_observed"),
            ("audit", "discord_slash_client_click_safe_mentions"),
            ("audit", "--wait-slash-client-click-proof"),
            ("audit", "Discord DM proof reason_kind"),
            ("audit", "Discord free-response proof reason_kind"),
            ("audit", "Discord slash client-click proof reason_kind"),
            ("audit", "real_client_click_proof"),
            (
                "release_docs",
                "LEMON_DISCORD_DM_REDACTED_PROOF_JSON=.lemon/proofs/discord-dm-latest.json",
            ),
            (
                "release_docs",
                "LEMON_DISCORD_FREE_RESPONSE_REDACTED_PROOF_JSON=.lemon/proofs/discord-free-response-latest.json",
            ),
            (
                "release_docs",
                "LEMON_DISCORD_SLASH_CLIENT_CLICK_PROOF_JSON=.lemon/proofs/discord-slash-client-click-proof-latest.json",
            ),
            ("release_docs", "--wait-dm-inbound"),
            ("release_docs", "--wait-free-response-trigger"),
            ("release_docs", "--wait-slash-client-click-proof"),
            ("release_docs", "--check-slash-client-click-proof"),
            ("audit", "--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json"),
            ("release_docs", "--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json"),
        ],
    ),
]

missing = []
for label, requirements in contracts:
    for file_key, token in requirements:
        if token not in contents[file_key]:
            missing.append(f"{label}: {files[file_key].relative_to(root)} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J27: final readiness audit structured proof contracts are documented"
else
  fail "J27: final readiness audit structured proof contracts are missing terms"
fi

if python3 - "$ROOT" <<'PYEOF'
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = {
    "audit": root / "scripts/audit_1_0_readiness",
    "image_smoke": root / "scripts/live_media_image_smoke.exs",
    "speech_smoke": root / "scripts/live_media_speech_smoke.exs",
    "transcription_smoke": root / "scripts/live_media_transcription_smoke.exs",
    "video_smoke": root / "scripts/live_media_video_smoke.exs",
    "testing": root / "docs/testing.md",
    "support": root / "docs/support.md",
    "release_docs": root / "docs/release/release_checklist_and_support_policy.md",
    "support_bundle": root / "apps/lemon_core/lib/lemon_core/doctor/support_bundle.ex",
    "support_bundle_test": root / "apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs",
    "media_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/media_status.ex",
    "control_plane_readme": root / "apps/lemon_control_plane/README.md",
}
contents = {key: path.read_text() for key, path in files.items()}

requirements = [
    ("audit", "verify_media_provider_proofs"),
    ("audit", "verify_media_provider_proof"),
    ("audit", "LEMON_MEDIA_IMAGE_PROOF_JSON"),
    ("audit", "LEMON_MEDIA_SPEECH_PROOF_JSON"),
    ("audit", "LEMON_MEDIA_TRANSCRIPTION_PROOF_JSON"),
    ("audit", "LEMON_MEDIA_VISION_PROOF_JSON"),
    ("audit", "LEMON_MEDIA_VIDEO_PROOF_JSON"),
    ("audit", "media_provider_openai_image"),
    ("audit", "media_provider_vertex_imagen"),
    ("audit", "media_provider_openai_tts"),
    ("audit", "media_provider_elevenlabs_tts"),
    ("audit", "media_provider_google_tts"),
    ("audit", "media_provider_openai_transcribe"),
    ("audit", "media_provider_deepgram_transcribe"),
    ("audit", "media_provider_openai_vision"),
    ("audit", "media_provider_openai_video"),
    ("audit", "media_provider_vertex_veo"),
    ("audit", "safe_reason_label"),
    ("audit", "media proof reason_kind"),
    ("audit", "media proof remediation hint"),
    ("audit", "media proof rerun command"),
    ("audit", "permission_denied"),
    ("audit", "payment_required"),
    ("image_smoke", "provider_prefixed_model_not_supported_for_media_type"),
    ("speech_smoke", "provider_prefixed_model_not_supported_for_media_type"),
    ("speech_smoke", "@default_elevenlabs_voice_id"),
    ("transcription_smoke", "provider_prefixed_model_not_supported_for_media_type"),
    ("video_smoke", "provider_prefixed_model_not_supported_for_media_type"),
    ("testing", "provider-prefixed OpenAI-compatible routing"),
    ("support", "provider-prefixed OpenAI-compatible routing"),
    ("testing", "openai_image_http_error:billing_limit_user_error"),
    ("testing", "vertex_imagen_http_error:permission_denied"),
    ("testing", "google_tts_http_error:permission_denied"),
    ("testing", "vertex_veo_create_http_error:permission_denied"),
    ("release_docs", "--provider vertex_imagen"),
    ("release_docs", "--provider google_tts"),
    ("release_docs", "--provider vertex_veo"),
    ("release_docs", "media_provider_vertex_imagen"),
    ("release_docs", "media_provider_vertex_veo"),
    ("release_docs", "google_tts"),
    ("testing", "elevenlabs_tts_http_error:payment_required"),
    ("testing", "deepgram_transcribe"),
    ("release_docs", "Deepgram evidence"),
    ("release_docs", "ElevenLabs proof script uses"),
    ("audit", "lemon.media_image_smoke"),
    ("audit", "lemon.media_speech_smoke"),
    ("audit", "lemon.media_transcription_smoke"),
    ("audit", "lemon.media_vision_smoke"),
    ("audit", "lemon.media_video_smoke"),
    ("release_docs", "LEMON_MEDIA_IMAGE_PROOF_JSON=.lemon/proofs/media-image-smoke-latest.json"),
    ("release_docs", "LEMON_MEDIA_SPEECH_PROOF_JSON=.lemon/proofs/media-speech-smoke-latest.json"),
    ("release_docs", "LEMON_MEDIA_TRANSCRIPTION_PROOF_JSON=.lemon/proofs/media-transcription-smoke-latest.json"),
    ("release_docs", "LEMON_MEDIA_VISION_PROOF_JSON=.lemon/proofs/media-vision-smoke-latest.json"),
    ("release_docs", "LEMON_MEDIA_VIDEO_PROOF_JSON=.lemon/proofs/media-video-smoke-latest.json"),
    ("release_docs", "mix run --no-start scripts/live_media_image_smoke.exs"),
    ("release_docs", "mix run --no-start scripts/live_media_speech_smoke.exs"),
    ("release_docs", "mix run --no-start scripts/live_media_transcription_smoke.exs"),
    ("release_docs", "mix run --no-start scripts/live_media_vision_smoke.exs"),
    ("release_docs", "mix run --no-start scripts/live_media_video_smoke.exs"),
    ("audit", "mix run --no-start scripts/live_media_image_smoke.exs"),
    ("audit", "mix run --no-start scripts/live_media_speech_smoke.exs"),
    ("audit", "mix run --no-start scripts/live_media_transcription_smoke.exs"),
    ("audit", "mix run --no-start scripts/live_media_vision_smoke.exs"),
    ("audit", "mix run --no-start scripts/live_media_video_smoke.exs"),
    ("support_bundle", "provider_live"),
    ("support_bundle_test", "provider_live"),
    ("media_status", '"providerProofs"'),
    ("control_plane_readme", "provider-backed media proof lane state"),
    ("support", "redacted `provider_live` summary"),
    ("support", "JSON-RPC `media.status` also includes redacted provider-backed media proof"),
    ("support", "same `--provider` rerun flag"),
    ("audit", "--proof-path .lemon/proofs/media-image-smoke-latest.json"),
    ("audit", "--proof-path .lemon/proofs/media-speech-smoke-latest.json"),
    ("audit", "--proof-path .lemon/proofs/media-transcription-smoke-latest.json"),
    ("audit", "--proof-path .lemon/proofs/media-vision-smoke-latest.json"),
    ("audit", "--proof-path .lemon/proofs/media-video-smoke-latest.json"),
    ("release_docs", "--proof-path .lemon/proofs/media-image-smoke-latest.json"),
    ("release_docs", "--proof-path .lemon/proofs/media-speech-smoke-latest.json"),
    ("release_docs", "--proof-path .lemon/proofs/media-transcription-smoke-latest.json"),
    ("release_docs", "--proof-path .lemon/proofs/media-vision-smoke-latest.json"),
    ("release_docs", "--proof-path .lemon/proofs/media-video-smoke-latest.json"),
    ("audit", "--api-key-secret SECRET_NAME"),
    ("release_docs", "--api-key-secret SECRET_NAME"),
]

missing = []
for file_key, token in requirements:
    if token not in contents[file_key]:
        missing.append(f"{files[file_key].relative_to(root)} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J27: final readiness audit requires provider-backed media proof"
else
  fail "J27: final readiness audit does not require documented provider-backed media proof"
fi

if proof_contract_labels=$(python3 - "$ROOT" <<'PYEOF'
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = {
    "audit": root / "scripts/audit_1_0_readiness",
    "release_docs": root / "docs/release/release_checklist_and_support_policy.md",
    "support": root / "docs/support.md",
    "browser_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/browser_status.ex",
    "lsp_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/lsp_diagnostics_status.ex",
}
contents = {key: path.read_text() for key, path in files.items()}

contracts = [
    (
        "J27: final readiness audit requires OpenAI-compatible API proof",
        [
            ("audit", "verify_openai_compat_proof"),
            ("audit", "LEMON_OPENAI_COMPAT_PROOF_JSON"),
            ("audit", "scripts/live_openai_compat_smoke.exs"),
            ("audit", ".lemon/proofs/openai-compat-smoke-latest.json"),
            ("audit", "external_openai_sdk_client"),
            ("audit", "external_python_sdk_client"),
            ("audit", "non_vision_image_rejection"),
            ("release_docs", "LEMON_OPENAI_COMPAT_PROOF_JSON=.lemon/proofs/openai-compat-smoke-latest.json"),
            ("release_docs", "openai_compat.api_preview"),
            ("release_docs", "scripts/live_openai_compat_smoke.exs"),
        ],
    ),
    (
        "J27: final readiness audit requires browser proof",
        [
            ("audit", "verify_browser_proof"),
            ("audit", "LEMON_BROWSER_PROOF_JSON"),
            ("audit", "scripts/live_browser_smoke.exs"),
            ("audit", ".lemon/proofs/browser-smoke-latest.json"),
            ("audit", "browser_cdp_attach_completed"),
            ("audit", "browser_analyze_model_visible_image_included"),
            ("audit", "includes_raw_paths"),
            ("audit", "includes_screenshot_bytes"),
            ("release_docs", "LEMON_BROWSER_PROOF_JSON=.lemon/proofs/browser-smoke-latest.json"),
            ("release_docs", "browser.preview"),
            ("release_docs", "scripts/live_browser_smoke.exs"),
            ("browser_status", '"liveProof"'),
            ("support", "browser operator diagnostics through JSON-RPC `browser.status`"),
            ("support", "live browser proof"),
        ],
    ),
    (
        "J27: final readiness audit requires ACP proof",
        [
            ("audit", "verify_acp_proofs"),
            ("audit", "LEMON_ACP_STDIO_PROOF_JSON"),
            ("audit", "LEMON_ACP_EXTERNAL_CLIENT_PROOF_JSON"),
            ("audit", "LEMON_ACP_OFFICIAL_SDK_PROOF_JSON"),
            ("audit", "scripts/live_acp_stdio_smoke.exs"),
            ("audit", "scripts/live_acp_stdio_external_client.mjs"),
            ("audit", "scripts/live_acp_official_sdk_client.mjs"),
            ("audit", "lemon.acp_stdio_smoke"),
            ("audit", "lemon.acp_stdio_external_client_smoke"),
            ("audit", "lemon.acp_official_sdk_client_smoke"),
            ("release_docs", "LEMON_ACP_STDIO_PROOF_JSON=.lemon/proofs/acp-stdio-smoke-latest.json"),
            ("release_docs", "LEMON_ACP_EXTERNAL_CLIENT_PROOF_JSON=.lemon/proofs/acp-stdio-external-client-latest.json"),
            ("release_docs", "LEMON_ACP_OFFICIAL_SDK_PROOF_JSON=.lemon/proofs/acp-official-sdk-client-latest.json"),
            ("release_docs", "acp.preview"),
        ],
    ),
    (
        "J27: final readiness audit requires MCP proof",
        [
            ("audit", "verify_mcp_proofs"),
            ("audit", "LEMON_MCP_STDIO_PROOF_JSON"),
            ("audit", "LEMON_MCP_HTTP_PROOF_JSON"),
            ("audit", "LEMON_MCP_SSE_PROOF_JSON"),
            ("audit", "scripts/live_mcp_stdio_smoke.exs"),
            ("audit", "scripts/live_mcp_http_smoke.exs"),
            ("audit", "scripts/live_mcp_sse_smoke.exs"),
            ("audit", "mcp_stdio_smoke"),
            ("audit", "mcp_http_smoke"),
            ("audit", "mcp_sse_smoke"),
            ("release_docs", "LEMON_MCP_STDIO_PROOF_JSON=.lemon/proofs/mcp-stdio-latest.json"),
            ("release_docs", "LEMON_MCP_HTTP_PROOF_JSON=.lemon/proofs/mcp-http-latest.json"),
            ("release_docs", "LEMON_MCP_SSE_PROOF_JSON=.lemon/proofs/mcp-sse-latest.json"),
            ("release_docs", "mcp.preview"),
        ],
    ),
    (
        "J27: final readiness audit requires LSP proof",
        [
            ("audit", "verify_lsp_proofs"),
            ("audit", "LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON"),
            ("audit", "LEMON_LSP_REAL_REPO_PROOF_JSON"),
            ("audit", "scripts/live_lsp_server_smoke.exs"),
            ("audit", "lsp_project_fixtures_smoke"),
            ("audit", "lsp_real_repo_fixtures_smoke"),
            ("release_docs", "LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON=.lemon/proofs/lsp-project-fixtures-latest.json"),
            ("release_docs", "LEMON_LSP_REAL_REPO_PROOF_JSON=.lemon/proofs/lsp-real-repo-fixtures-latest.json"),
            ("release_docs", "lsp.preview"),
            ("lsp_status", "Map.put(:proofs, lsp_proof_status(project_dir))"),
            ("support", "recent redacted LSP proof artifacts"),
        ],
    ),
    (
        "J27: final readiness audit requires extension and WASM proof",
        [
            ("audit", "verify_extension_proofs"),
            ("audit", "LEMON_EXTENSION_HOST_PROOF_JSON"),
            ("audit", "LEMON_WASM_TELEMETRY_PROOF_JSON"),
            ("audit", "LEMON_WASM_POLICY_PROOF_JSON"),
            ("audit", "LEMON_EXTENSION_REGISTRY_AUDIT_PROOF_JSON"),
            ("audit", "LEMON_WASM_LIFECYCLE_PROOF_JSON"),
            ("audit", "scripts/live_extension_host_smoke.exs"),
            ("audit", "scripts/live_wasm_telemetry_smoke.exs"),
            ("audit", "scripts/live_wasm_policy_smoke.exs"),
            ("audit", "scripts/live_extension_registry_audit_smoke.exs"),
            ("audit", "scripts/live_wasm_lifecycle_smoke.exs"),
            ("audit", "extension_host_smoke"),
            ("audit", "wasm_tool_telemetry_smoke"),
            ("audit", "wasm_policy_smoke"),
            ("audit", "extension_registry_audit_smoke"),
            ("audit", "wasm_lifecycle_smoke"),
            ("release_docs", "LEMON_EXTENSION_HOST_PROOF_JSON=.lemon/proofs/extension-host-smoke-latest.json"),
            ("release_docs", "LEMON_WASM_TELEMETRY_PROOF_JSON=.lemon/proofs/wasm-tool-telemetry-latest.json"),
            ("release_docs", "LEMON_WASM_POLICY_PROOF_JSON=.lemon/proofs/wasm-policy-latest.json"),
            ("release_docs", "LEMON_EXTENSION_REGISTRY_AUDIT_PROOF_JSON=.lemon/proofs/extension-registry-audit-latest.json"),
            ("release_docs", "LEMON_WASM_LIFECYCLE_PROOF_JSON=.lemon/proofs/wasm-lifecycle-latest.json"),
            ("release_docs", "extensions.wasm_lifecycle"),
        ],
    ),
]

missing = []
for label, requirements in contracts:
    for file_key, token in requirements:
        if token not in contents[file_key]:
            missing.append(f"{label}: {files[file_key].relative_to(root)} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)

for label, _requirements in contracts:
    print(label)
PYEOF
); then
  while IFS= read -r label; do
    [ -n "$label" ] && pass "$label"
  done <<< "$proof_contract_labels"
else
  fail "J27: final readiness audit preview proof contracts are incomplete"
fi

if readiness_contract_labels=$(python3 - "$ROOT" <<'PYEOF'
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = {
    "audit": root / "scripts/audit_1_0_readiness",
    "release_docs": root / "docs/release/release_checklist_and_support_policy.md",
    "support": root / "docs/support.md",
    "compare": root / "docs/compare.md",
    "docs_readme": root / "docs/README.md",
    "vitepress": root / "docs/.vitepress/config.js",
    "channel_matrix": root / "docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md",
    "terminal_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/terminal_backends_status.ex",
    "proofs_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/proofs_status.ex",
    "proof_launch_gates": root / "apps/lemon_core/lib/lemon_core/doctor/proof_launch_gates.ex",
    "channels_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/channels_status.ex",
    "cron_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/cron_status.ex",
    "control_plane_readme": root / "apps/lemon_control_plane/README.md",
    "control_plane_agents": root / "apps/lemon_control_plane/AGENTS.md",
}
contents = {key: path.read_text() for key, path in files.items()}

contracts = [
    (
        "J27: final readiness audit requires terminal backend proof",
        [
            ("audit", "verify_terminal_backend_proof"),
            ("audit", "LEMON_TERMINAL_BACKEND_PROOF_JSON"),
            ("audit", "scripts/live_terminal_backend_smoke.exs"),
            ("audit", ".lemon/proofs/terminal-backend-latest.json"),
            ("audit", "local_pty"),
            ("release_docs", "LEMON_TERMINAL_BACKEND_PROOF_JSON=.lemon/proofs/terminal-backend-latest.json"),
            ("release_docs", "terminal.backends_live"),
            ("release_docs", "scripts/live_terminal_backend_smoke.exs"),
            ("terminal_status", '"liveProof"'),
            ("terminal_status", '"terminalHardening"'),
            ("support", "Control-plane `terminal.backends.status` includes the same terminal live-proof"),
        ],
    ),
    (
        "J27: proof status exposes launch-gate summaries",
        [
            ("proofs_status", '"launchGates"'),
            ("proofs_status", "ProofLaunchGates.status"),
            ("proof_launch_gates", '"discordDm"'),
            ("proof_launch_gates", '"discordSlashRegistration"'),
            ("proof_launch_gates", '"providerMedia"'),
            ("control_plane_readme", "Discord slash registration"),
            ("control_plane_readme", "launch-gate summaries"),
            ("support", "Discord slash registration"),
            ("support", "`launchGates` summary"),
        ],
    ),
    (
        "J27: channel status exposes compact launch-gate summary maps",
        [
            ("channels_status", '"launchGateStatuses"'),
            ("channels_status", '"launchGateReasonKinds"'),
            ("control_plane_readme", "compact gate status/reason maps"),
            ("control_plane_agents", "compact gate status/reason maps"),
            ("support", "launchGateStatuses"),
            ("support", "launchGateReasonKinds"),
        ],
    ),
    (
        "J27: final readiness audit requires cron proof",
        [
            ("audit", "verify_cron_proofs"),
            ("audit", "LEMON_CRON_DIAGNOSTICS_PROOF_JSON"),
            ("audit", "LEMON_CRON_RUNTIME_RESTART_PROOF_JSON"),
            ("audit", "LEMON_CRON_CHANNEL_ORIGIN_PROOF_JSON"),
            ("audit", "scripts/live_cron_diagnostics_smoke.exs"),
            ("audit", "scripts/live_cron_runtime_restart_smoke.exs"),
            ("audit", "scripts/live_cron_channel_origin_smoke.exs"),
            ("audit", "lemon.cron_diagnostics_smoke"),
            ("audit", "lemon.cron_runtime_restart_smoke"),
            ("audit", "lemon.cron_channel_origin_smoke"),
            ("release_docs", "LEMON_CRON_DIAGNOSTICS_PROOF_JSON=.lemon/proofs/cron-diagnostics-latest.json"),
            ("release_docs", "LEMON_CRON_RUNTIME_RESTART_PROOF_JSON=.lemon/proofs/cron-runtime-restart-latest.json"),
            ("release_docs", "LEMON_CRON_CHANNEL_ORIGIN_PROOF_JSON=.lemon/proofs/cron-channel-origin-latest.json"),
            ("release_docs", "cron.preview"),
            ("cron_status", "suppressedSlotCount"),
            ("cron_status", "retryScheduledCount"),
            ("support", "control-plane `cron.status` surfaces cron scheduler health"),
        ],
    ),
    (
        "J27: final readiness audit enforces public Hermes-gap support boundaries",
        [
            ("audit", "verify_public_support_boundaries"),
            ("support", "OpenAI-compatible API server behavior"),
            ("support", "ACP editor integration"),
            ("support", "checkpointing for destructive shell commands"),
            ("support", "first-class browser automation"),
            ("support", "production support for third-party plugins"),
            ("support", "Discord support is bounded to the live-proven path"),
            ("compare", "Discord behavior beyond the live-proven text-first and file-delivery boundary"),
            ("compare", "stable Telegram and Discord text-first support"),
        ],
    ),
    (
        "J27: final readiness audit requires bounded channel command parity matrix",
        [
            ("audit", "verify_channel_command_matrix"),
            ("docs_readme", "docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md"),
            ("vitepress", "lemon-channel-command-parity-matrix-2026-05-12"),
            ("channel_matrix", "Stable Telegram text-first command boundary"),
            ("channel_matrix", "Preview Discord command boundary"),
            ("channel_matrix", "Hermes drop-in command parity is not a Lemon 1.0 claim"),
        ],
    ),
]

missing = []
for label, requirements in contracts:
    for file_key, token in requirements:
        if token not in contents[file_key]:
            missing.append(f"{label}: {files[file_key].relative_to(root)} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)

for label, _requirements in contracts:
    print(label)
PYEOF
); then
  while IFS= read -r label; do
    [ -n "$label" ] && pass "$label"
  done <<< "$readiness_contract_labels"
else
  fail "J27: readiness proof and support boundary contracts are incomplete"
fi

if handoff_contract_labels=$(python3 - "$ROOT" <<'PYEOF'
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = {
    "audit": root / "scripts/audit_1_0_readiness",
    "discord_matrix": root / "scripts/live_discord_matrix.py",
    "proof_diagnostics": root / "apps/lemon_core/lib/lemon_core/doctor/proof_diagnostics.ex",
    "proofs_status": root / "apps/lemon_control_plane/lib/lemon_control_plane/methods/proofs_status.ex",
    "channel_diagnostics": root / "apps/lemon_core/lib/lemon_core/doctor/channel_diagnostics.ex",
    "channel_matrix": root / "docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md",
    "support": root / "docs/support.md",
    "release_docs": root / "docs/release/release_checklist_and_support_policy.md",
    "testing": root / "docs/testing.md",
    "completion_audit": root / "docs/plans/lemon-1.0-completion-audit-2026-05-12.md",
}
contents = {key: path.read_text() for key, path in files.items()}

contracts = [
    (
        "J27: rollback slash alias, audit gate, and proof coverage stay documented",
        [
            ("discord_matrix", "rollback_command_schema/0"),
            ("discord_matrix", "--check-rollback-slash-registration"),
            ("discord_matrix", "--register-rollback-slash-command"),
            ("discord_matrix", "contains_rollback_slash_registration"),
            ("audit", "verify_discord_rollback_slash_proof"),
            ("audit", "verify_discord_rollback_slash_redacted_proof"),
            ("audit", "LEMON_DISCORD_ROLLBACK_SLASH_PROOF_JSON"),
            ("audit", "LEMON_DISCORD_ROLLBACK_SLASH_REDACTED_PROOF_JSON"),
            ("audit", "discord_rollback_slash_registration"),
            ("audit", "contains_rollback_slash_registration"),
            ("audit", "expected != 16"),
            ("proof_diagnostics", "contains_rollback_slash_registration"),
            ("proofs_status", "containsRollbackSlashRegistration"),
            ("channel_diagnostics", '"rollback"'),
            ("channel_matrix", "Rollback: `/rollback`"),
            ("channel_matrix", "checkpoint/rollback/kanban/media"),
            ("support", "contains_rollback_slash_registration"),
            ("release_docs", "LEMON_DISCORD_ROLLBACK_SLASH_PROOF_JSON=tmp/discord-rollback-slash-proof-check.json"),
            (
                "release_docs",
                "LEMON_DISCORD_ROLLBACK_SLASH_REDACTED_PROOF_JSON=.lemon/proofs/discord-rollback-slash-registration-latest.json",
            ),
            ("release_docs", "--check-rollback-slash-registration"),
            ("testing", "--register-rollback-slash-command"),
            ("testing", "--check-rollback-slash-registration"),
        ],
    ),
    (
        "J27: release handoff docs avoid duplicate workflow runs",
        [
            ("release_docs", "Do not use both paths"),
            ("release_docs", "-f channel=stable"),
            ("release_docs", "refusing to publish with a dirty tree"),
            ("release_docs", "git log -1 --oneline"),
            ("release_docs", "git rev-list --count origin/main..HEAD"),
            ("release_docs", "git log --oneline origin/main..HEAD"),
            ("release_docs", "git push origin main"),
        ],
    ),
    (
        "J27: live-eval handoff requires watching the intended run",
        [
            ("testing", "gh run watch {run-id} --exit-status"),
            ("release_docs", "gh run watch {run-id} --exit-status"),
            ("completion_audit", "gh run watch {run-id} --exit-status"),
            ("audit", "gh run watch {run-id} --exit-status"),
        ],
    ),
    (
        "J27: live-eval handoff documents repository secret setup",
        [
            ("testing", "gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon"),
            ("release_docs", "gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon"),
            ("completion_audit", "gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon"),
            ("audit", "gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon"),
        ],
    ),
]

missing = []
for label, requirements in contracts:
    for file_key, token in requirements:
        if token not in contents[file_key]:
            missing.append(f"{label}: {files[file_key].relative_to(root)} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)

for label, _requirements in contracts:
    print(label)
PYEOF
); then
  while IFS= read -r label; do
    [ -n "$label" ] && pass "$label"
  done <<< "$handoff_contract_labels"
else
  fail "J27: rollback and release handoff contracts are incomplete"
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

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
requirements = [
    ("scripts/audit_1_0_readiness", "scripts/verify_docs_site"),
    ("docs/release/release_checklist_and_support_policy.md", "scripts/verify_docs_site"),
]
missing = []
for relative_path, token in requirements:
    content = (root / relative_path).read_text(encoding="utf-8")
    if token not in content:
        missing.append(f"{relative_path} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J29: final readiness audit includes documented docs-site verification"
else
  fail "J29: final readiness audit does not include documented docs-site verification"
fi

# ── J30: final audit must include canonical local release-candidate tests ────
if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "scripts/audit_1_0_readiness"
content = path.read_text(encoding="utf-8")
tokens = [
    "scripts/test fast",
    "scripts/test quality",
    "scripts/test eval-fast",
    "scripts/test clients",
]
missing = [token for token in tokens if token not in content]
if missing:
    print("\n".join(f"{path.relative_to(root)} missing {token!r}" for token in missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J30: final readiness audit runs canonical local test lanes"
else
  fail "J30: final readiness audit is missing one or more canonical local test lanes"
fi

if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "docs/release/release_checklist_and_support_policy.md"
content = path.read_text(encoding="utf-8")
tokens = [
    "scripts/test fast",
    "scripts/test quality",
    "scripts/test eval-fast",
    "scripts/test clients",
]
missing = [token for token in tokens if token not in content]
if missing:
    print("\n".join(f"{path.relative_to(root)} missing {token!r}" for token in missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J30: release checklist documents canonical local test lanes"
else
  fail "J30: release checklist does not document all canonical local test lanes"
fi

# ── J31: OSV supply-chain scan parity must stay wired and documented ────────
if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
requirements = [
    (
        "OSV scanner workflow",
        [
            (".github/workflows/osv-scanner.yml", "google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@c51854704019a247608d928f370c98740469d4b5"),
            (".github/workflows/osv-scanner.yml", "security-events: write"),
            (".github/workflows/osv-scanner.yml", "--lockfile=mix.lock"),
            (".github/workflows/osv-scanner.yml", "--lockfile=clients/lemon-cli/uv.lock"),
            (".github/workflows/osv-scanner.yml", "--lockfile=clients/lemon-web/package-lock.json"),
            (".github/workflows/osv-scanner.yml", "--lockfile=clients/lemon-tui/package-lock.json"),
            (".github/workflows/osv-scanner.yml", "--lockfile=clients/lemon-browser-node/package-lock.json"),
            (".github/workflows/osv-scanner.yml", "--lockfile=apps/lemon_gateway/priv/package-lock.json"),
            (".github/workflows/osv-scanner.yml", "--lockfile=tools/diagrams/package-lock.json"),
            (".github/workflows/osv-scanner.yml", "fail-on-vuln: false"),
            ("docs/release/release_checklist_and_support_policy.md", "OSV Scanner workflow"),
            ("docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md", "94c523f0c"),
        ],
    ),
]
contents = {}
missing = []
for label, checks in requirements:
    for relative_path, token in checks:
        content = contents.setdefault(
            relative_path,
            (root / relative_path).read_text(encoding="utf-8"),
        )
        if token not in content:
            missing.append(f"{label}: {relative_path} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J31: OSV scanner supply-chain parity workflow is documented"
else
  fail "J31: OSV scanner supply-chain parity workflow is missing or undocumented"
fi

# ── J32: PR history integrity check must stay wired and documented ───────────
if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
requirements = [
    (".github/workflows/history-check.yml", "name: History Check"),
    (".github/workflows/history-check.yml", "pull_request:"),
    (".github/workflows/history-check.yml", "fetch-depth: 0"),
    (".github/workflows/history-check.yml", 'git merge-base "origin/${GITHUB_BASE_REF}" HEAD'),
    (".github/workflows/history-check.yml", "no common ancestor"),
    ("docs/release/release_checklist_and_support_policy.md", "History Check workflow"),
    ("docs/release/release_checklist_and_support_policy.md", "unrelated-history PRs"),
    ("docs/testing.md", "history-check.yml"),
    ("docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md", "94c523f0c"),
]
contents = {}
missing = []
for relative_path, token in requirements:
    content = contents.setdefault(
        relative_path,
        (root / relative_path).read_text(encoding="utf-8"),
    )
    if token not in content:
        missing.append(f"{relative_path} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J32: PR history integrity check is wired and documented"
else
  fail "J32: PR history integrity check is missing or undocumented"
fi

# ── J33: Python CLI package checks must stay wired and documented ────────────
if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
requirements = [
    (".github/workflows/python-cli.yml", "name: Python CLI"),
    (".github/workflows/python-cli.yml", 'python-version: "3.13"'),
    (".github/workflows/python-cli.yml", "astral-sh/setup-uv@v6"),
    (".github/workflows/python-cli.yml", "uv sync --locked --dev"),
    (".github/workflows/python-cli.yml", "uv run ruff check src tests"),
    (".github/workflows/python-cli.yml", "uv run pytest"),
    (".github/workflows/python-cli.yml", "uv build --sdist --wheel"),
    (".github/workflows/python-cli.yml", "lemon-cli-distributions"),
    ("scripts/test", "uv run ruff check src tests"),
    ("scripts/test", "uv build --sdist --wheel"),
    ("docs/testing.md", "lemon-cli"),
    ("docs/release/release_checklist_and_support_policy.md", "Python CLI package workflow"),
    ("docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md", "PyPI-style CLI package"),
]
contents = {}
missing = []
for relative_path, token in requirements:
    content = contents.setdefault(
        relative_path,
        (root / relative_path).read_text(encoding="utf-8"),
    )
    if token not in content:
        missing.append(f"{relative_path} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  pass "J33: Python CLI package check workflow is wired and documented"
else
  fail "J33: Python CLI package check workflow is missing or undocumented"
fi

# ── J34: Script-send CLI must stay scoped to Telegram/Discord and documented ─
if python3 - "$ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = {
    "script_send": root / "apps/lemon_channels/lib/lemon_channels/script_send.ex",
    "send_task": root / "apps/lemon_channels/lib/mix/tasks/lemon.send.ex",
    "discord_outbound": root / "apps/lemon_channels/lib/lemon_channels/adapters/discord/outbound.ex",
    "telegram_store": root / "apps/lemon_channels/lib/lemon_channels/telegram/known_target_store.ex",
    "discord_store": root / "apps/lemon_channels/lib/lemon_channels/discord/known_target_store.ex",
    "discord_transport": root / "apps/lemon_channels/lib/lemon_channels/adapters/discord/transport.ex",
    "script_send_test": root / "apps/lemon_channels/test/lemon_channels/script_send_test.exs",
    "discord_outbound_test": root / "apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs",
    "root_readme": root / "README.md",
    "channels_readme": root / "apps/lemon_channels/README.md",
    "testing_docs": root / "docs/testing.md",
    "channels_agents": root / "apps/lemon_channels/AGENTS.md",
    "config_docs": root / "docs/config.md",
    "config_example": root / "examples/config.example.toml",
    "gateway_config": root / "apps/lemon_core/lib/lemon_core/config/gateway.ex",
    "parity_matrix": root / "docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md",
    "scorecard": root / "docs/plans/lemon-hermes-agent-harness-parity-scorecard.md",
}
contents = {name: path.read_text(encoding="utf-8") for name, path in files.items()}

contracts = [
    (
        "script-send implementation surface",
        [
            ("script_send", "defmodule LemonChannels.ScriptSend"),
            ("script_send", "@supported_platforms ~w(discord telegram)"),
            ("send_task", "defmodule Mix.Tasks.Lemon.Send"),
            ("send_task", "defp exit_code(:missing_target), do: 2"),
            ("script_send", "use - to force stdin"),
            ("script_send", "attach: :keep"),
            ("script_send", "normalize_attachments"),
            ("script_send", "attachment_filename"),
            ("script_send", "attachment_count"),
            ("script_send", "telegram_target_aliases"),
            ("script_send", "discord_target_aliases"),
            ("script_send", "gateway_section_value(:telegram"),
            ("script_send", "gateway_section_value(:discord"),
            ("script_send", 'default_account_id("telegram"'),
            ("script_send", "LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID"),
            ("script_send", "account: :string"),
            ("script_send", "thread: :string"),
            ("script_send", "topic: :string"),
            ("script_send", "reply_to: :string"),
            ("script_send", "payload_account_id"),
            ("script_send", "normalize_thread_option"),
            ("script_send", "normalize_reply_to"),
            ("script_send", "filter_known_targets_by_account"),
            ("script_send", "--account ID"),
            ("script_send", "--thread ID"),
            ("script_send", "--topic ID"),
            ("script_send", "--reply-to ID"),
            ("script_send", "dry_run: :boolean"),
            ("script_send", "maybe_deliver(payload, %{dry_run?: true}"),
            ("script_send", "delivery_message_ids"),
            ("send_task", "at most #{max} --attach files are supported"),
            ("send_task", "alias_suffix"),
            ("discord_outbound", "batch_file_params"),
            ("script_send", "delivery_message_id"),
            ("script_send", 'known_targets("telegram", account_id)'),
            ("script_send", "resolve_telegram_named_target"),
            ("script_send", "telegram:@username"),
            ("script_send", 'known_targets("discord", account_id)'),
            ("script_send", "resolve_discord_named_target"),
        ],
    ),
    (
        "known-target stores and indexing",
        [
            ("telegram_store", "def list_available"),
            ("discord_store", "defmodule LemonChannels.Discord.KnownTargetStore"),
            ("discord_transport", "maybe_index_known_target"),
        ],
    ),
    (
        "script-send tests",
        [
            ("script_send_test", "LemonChannels.Telegram.KnownTargetStore"),
            ("script_send_test", "resolves unique Telegram known chat names"),
            ("script_send_test", "resolves unique Telegram known topic names"),
            ("script_send_test", "parses default targets from gateway config"),
            ("script_send_test", "environment default targets and accounts take precedence over gateway config"),
            ("script_send_test", "default account scopes known-name resolution"),
            ("script_send_test", "scopes Discord known-name resolution by account"),
            ("script_send_test", "filters known targets by account for list mode"),
            ("script_send_test", "parses standalone thread and topic target options"),
            ("script_send_test", "rejects conflicting thread target options"),
            ("script_send_test", "builds and delivers payload with reply target"),
            ("script_send_test", "rejects empty reply target"),
            ("script_send_test", "telegram:#Lemon Ops:Deploys"),
            ("script_send_test", "LemonChannels.Discord.KnownTargetStore"),
            ("script_send_test", "discord:#ops"),
            ("script_send_test", "discord:#ops:deploys"),
            ("script_send_test", "builds and delivers Telegram attachment payload"),
            ("script_send_test", "builds and delivers multiple Discord attachment payloads"),
            ("script_send_test", "preserves Telegram batch attachment message ids"),
            ("script_send_test", "dry run validates attachment payload without delivery"),
            ("discord_outbound_test", "file delivery uploads a bounded file batch"),
        ],
    ),
    (
        "root README script-send docs",
        [
            ("root_readme", "./bin/lemon send --to telegram:<chat_id>"),
            ("root_readme", "--attach"),
            ("root_readme", "--dry-run"),
            ("root_readme", "repeated `--attach` uploads up to 10 files"),
            ("root_readme", "Telegram/Discord known-target windows"),
            ("root_readme", "exact reusable aliases"),
            ("root_readme", "env/config defaults"),
            ("root_readme", "--account <id>"),
            ("root_readme", "LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID"),
            ("root_readme", "--thread <id-or-name>"),
            ("root_readme", "--topic <id-or-name>"),
            ("root_readme", "--reply-to <message-id>"),
            ("root_readme", "discord:#ops"),
            ("root_readme", "telegram:@lemon_ops"),
        ],
    ),
    (
        "lemon_channels README script-send docs",
        [
            ("channels_readme", "./bin/lemon send --to telegram:<chat_id>"),
            ("channels_readme", "--attach"),
            ("channels_readme", "--dry-run"),
            ("channels_readme", "dry_run"),
            ("channels_readme", "attachment_filename"),
            ("channels_readme", "attachment_count"),
            ("channels_readme", "extra_message_ids"),
            ("channels_readme", "./bin/lemon send --list telegram"),
            ("channels_readme", "known_targets"),
            ("channels_readme", "exact reusable `aliases`"),
            ("channels_readme", "config fallbacks"),
            ("channels_readme", "--account <id>"),
            ("channels_readme", "Default account ids"),
            ("channels_readme", "--thread <id-or-name>"),
            ("channels_readme", "--topic <id-or-name>"),
            ("channels_readme", "--reply-to <message-id>"),
            ("channels_readme", "LemonChannels.Discord.KnownTargetStore"),
            ("channels_readme", "discord:#channel:thread-name"),
            ("channels_readme", "telegram:@username"),
        ],
    ),
    (
        "script-send test documentation",
        [
            ("testing_docs", "MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1"),
            ("testing_docs", "--file -"),
            ("testing_docs", "bounded `message_id` extraction"),
            ("testing_docs", "repeated `--attach` payload construction up to 10 files"),
            ("testing_docs", "batch delivery `extra_message_ids` extraction"),
            ("testing_docs", "list-mode alias metadata"),
            ("testing_docs", "config-backed default targets"),
            ("testing_docs", "account-scoped delivery and known-target resolution"),
            ("testing_docs", "config-backed default account ids"),
            ("testing_docs", "standalone thread/topic target overrides"),
            ("testing_docs", "reply-to payload routing"),
            ("testing_docs", "dry-run validation without delivery"),
            ("testing_docs", "attachment usage/input failures return `2`"),
            ("testing_docs", "usage/config/input failures return `2`"),
            ("testing_docs", "Telegram known-target discovery"),
            ("testing_docs", "unique Telegram known-name resolution"),
            ("testing_docs", "Discord known-target discovery"),
            ("testing_docs", "unique Discord known-name resolution"),
        ],
    ),
    (
        "script-send app guide docs",
        [
            ("channels_agents", "ScriptSend.run/2"),
            ("channels_agents", "--attach"),
            ("channels_agents", "--dry-run"),
            ("channels_agents", "exact reusable `aliases`"),
            ("channels_agents", "config fallbacks"),
            ("channels_agents", "--account <id>"),
            ("channels_agents", "LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID"),
            ("channels_agents", "--thread <id-or-name>"),
            ("channels_agents", "--topic <id-or-name>"),
            ("channels_agents", "--reply-to <message-id>"),
            ("channels_agents", "telegram:@username"),
        ],
    ),
    (
        "script-send config docs",
        [
            ("config_docs", "default_chat_id"),
            ("config_docs", "default_channel_id"),
            ("config_docs", "default_account_id"),
            ("config_example", "default_chat_id"),
            ("config_example", "default_account_id"),
            ("config_example", "default_channel_id"),
            ("gateway_config", "default_channel_id"),
        ],
    ),
    (
        "script-send parity docs",
        [
            ("parity_matrix", "Telegram/Discord `./bin/lemon send` script notification path"),
            ("parity_matrix", "BEAM-store known-target discovery"),
            ("parity_matrix", "exact list-mode aliases"),
            ("parity_matrix", "config-backed default targets"),
            ("parity_matrix", "default account ids"),
            ("parity_matrix", "account-scoped delivery and known-target resolution"),
            ("parity_matrix", "standalone thread/topic"),
            ("parity_matrix", "reply-to payload routing"),
            ("parity_matrix", "unique Telegram/Discord known-name resolution"),
            ("parity_matrix", "LemonChannels.Discord.KnownTargetStore"),
            ("parity_matrix", "discord:#channel:thread-name"),
            ("parity_matrix", "bounded multi-attachment script artifact uploads"),
            ("parity_matrix", "credential-free dry-run validation"),
            ("scorecard", "Slice 373: Script-send multi-attachment uploads"),
            ("scorecard", "Slice 374: Script-send batch delivery ids"),
            ("scorecard", "Slice 375: Script-send dry-run validation"),
            ("scorecard", "Slice 376: Telegram named script-send target resolution"),
            ("scorecard", "Slice 377: Script-send list aliases"),
            ("scorecard", "Slice 378: Script-send config defaults"),
            ("scorecard", "Slice 379: Script-send account selection"),
            ("scorecard", "Slice 380: Script-send thread and topic options"),
            ("scorecard", "Slice 381: Script-send default account ids"),
            ("scorecard", "Slice 382: Script-send reply-to routing"),
            ("scorecard", "attachment_filename"),
        ],
    ),
]

missing = []
for label, requirements in contracts:
    for file_key, token in requirements:
        if token not in contents[file_key]:
            missing.append(f"{label}: {files[file_key].relative_to(root)} missing {token!r}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PYEOF
then
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
