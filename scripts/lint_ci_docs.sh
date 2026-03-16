#!/usr/bin/env bash
# Lint script for CI/docs policy checks (tasks C9, C10, C11, J17, J18, J19, J20, J22, J23, manual-dispatch)
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

if awk '
  /^permissions:/ {in_block=1; next}
  in_block && /^[^[:space:]]/ {exit}
  in_block {print}
' "$ROOT/.github/workflows/docs-site.yml" 2>/dev/null | grep -qE 'pages:\s*write|id-token:\s*write'; then
  fail "J23: docs-site.yml grants pages/id-token at workflow scope instead of deploy-job scope"
else
  pass "J23: docs-site.yml keeps pages/id-token permissions off the workflow scope"
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
