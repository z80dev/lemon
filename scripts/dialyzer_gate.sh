#!/usr/bin/env bash
#
# Dialyzer green gate.
#
# The umbrella as a whole still carries a large Dialyzer backlog (see
# docs/plans/dialyzer-burndown.md). Rather than gate the whole tree "all or
# nothing", this script enforces zero Dialyzer findings for an explicit
# allowlist of apps that have been driven to green and are expected to STAY
# green. Apps graduate onto this list as their findings are burned down; the
# list only ever grows, so the gate ratchets forward and can never silently
# regress a package that was already clean.
#
# Usage:
#   scripts/dialyzer_gate.sh [dialyzer-output-file]
#
# With no argument it runs `mix dialyzer --format dialyzer` itself (slow: needs
# a warm PLT). In CI we run Dialyzer once for full-umbrella visibility and pass
# its captured output here, so the gate re-uses that single analysis.
#
# Exit code: 0 if every gated app is clean, 1 if any gated app has >=1 finding.

set -uo pipefail

# ── The allowlist ───────────────────────────────────────────────────────────
# Each entry is the app's lib/ subdirectory (== app name for every app here),
# which is exactly how Dialyzer prefixes its warning paths ("lib/<app>/...").
#
# PUBLISHED packages (part of the 9 consumer-facing Hex packages) are marked;
# keeping those green is the headline "per-published-package" guarantee.
GATED_APPS=(
  lemon_media          # published
  lemon_memory         # published
  lemon_platform_test  # published
  lemon_web
  lemon_lsp
  lemon_browser
)

out_file="${1:-}"
tmp_created=""

if [[ -z "${out_file}" ]]; then
  out_file="$(mktemp)"
  tmp_created="${out_file}"
  echo "==> Running mix dialyzer (no output file supplied)..."
  # Full-umbrella run: exits non-zero while the backlog exists; we only care
  # about the gated apps, so ignore its exit status and read the warnings.
  mix dialyzer --format dialyzer >"${out_file}" 2>&1 || true
fi

if [[ ! -f "${out_file}" ]]; then
  echo "dialyzer_gate: output file not found: ${out_file}" >&2
  exit 2
fi

echo "==> Dialyzer green gate — gated apps must have zero findings"
printf '%-24s %s\n' "APP" "FINDINGS"
printf '%-24s %s\n' "------------------------" "--------"

failed=0
for app in "${GATED_APPS[@]}"; do
  # Match warning lines of the form "lib/<app>/....ex:<line>:..." only.
  count="$(grep -cE "^lib/${app}/[^:]*\.ex:[0-9]" "${out_file}" || true)"
  printf '%-24s %s\n' "${app}" "${count}"
  if [[ "${count}" -ne 0 ]]; then
    failed=1
  fi
done

echo
if [[ "${failed}" -ne 0 ]]; then
  echo "GATE FAILED — a gated app regressed. Offending findings:" >&2
  for app in "${GATED_APPS[@]}"; do
    grep -E "^lib/${app}/[^:]*\.ex:[0-9]" "${out_file}" >&2 || true
  done
  [[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
  exit 1
fi

echo "GATE PASSED — all ${#GATED_APPS[@]} gated apps are Dialyzer-clean."
[[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
exit 0
