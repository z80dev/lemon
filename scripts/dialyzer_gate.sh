#!/usr/bin/env bash
#
# Dialyzer green gate.
#
# The umbrella as a whole still carries a large Dialyzer backlog. Rather than
# gate the whole tree "all or nothing", this script enforces zero Dialyzer findings for an explicit
# allowlist of apps that have been driven to green and are expected to STAY
# green. Apps graduate onto this list as their findings are burned down; the
# list only ever grows, so the gate ratchets forward and can never silently
# regress a package that was already clean.
#
# Usage:
#   scripts/dialyzer_gate.sh [dialyzer-output-file]
#
# With no argument it runs Dialyzer itself (slow: needs a warm PLT). In CI we
# run Dialyzer once for full-umbrella visibility and pass its captured output
# here, so the gate re-uses that single analysis.
#
# Exit code: 0 if every gated app is clean, 1 if any gated app has >=1 finding,
# 2 if the Dialyzer output is missing or unusable (see "Output sanity" below).

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# ── The allowlist ───────────────────────────────────────────────────────────
# Each entry is an umbrella app directory under apps/. Findings are attributed
# to an app by asking which app owns the file Dialyzer names (see
# `app_findings` below), so a finding in an app's `lib/mix/tasks/*.ex` or
# `lib/<app>.ex` counts against it just like one under `lib/<app>/`.
#
# PUBLISHED packages (part of the consumer-facing Hex packages — 12 as of
# D14, which adds lemon_browser and lemon_skills) are marked; keeping those
# green is the headline "per-published-package" guarantee.
GATED_APPS=(
  lemon_media          # published
  lemon_memory         # published
  lemon_platform_test  # published
  lemon_browser        # published
  lemon_web
  lemon_lsp
  lemon_cli
  lemon_evals
  lemon_honcho
  lemon_tcg
  lemon_mcp
  x_api
)

out_file="${1:-}"
tmp_created=""

if [[ -z "${out_file}" ]]; then
  out_file="$(mktemp)"
  tmp_created="${out_file}"
  echo "==> Running mix dialyzer (no output file supplied)..."
  # Full-umbrella run: exits non-zero while the backlog exists; we only care
  # about the gated apps, so ignore its exit status and read the warnings.
  #
  # --ignore-exit-status is REQUIRED, not cosmetic: with `list_unused_filters:
  # true` (root mix.exs) dialyxir treats a stale .dialyzer_ignore.exs entry as
  # an error and then throws the entire formatted warning list away
  # (Dialyxir.Dialyzer.Runner.run), printing only "unused filters present".
  # Without this flag a stale ignore entry would silently produce an empty
  # report — i.e. a green gate for every app at once.
  mix dialyzer --format dialyzer --ignore-exit-status >"${out_file}" 2>&1 || true
fi

if [[ ! -f "${out_file}" ]]; then
  echo "dialyzer_gate: output file not found: ${out_file}" >&2
  exit 2
fi

# ── Output sanity ───────────────────────────────────────────────────────────
# A report the gate cannot trust must fail loudly rather than pass everything.
# Two ways that happens in practice: the run never finished (no summary line),
# or dialyxir discarded the warnings it had already formatted (stale ignore
# filter, see above) leaving a summary that claims findings but lists none.
total_line="$(grep -m1 -E '^Total errors: [0-9]+' "${out_file}" || true)"
warning_lines="$(grep -cE '^lib/[^:]*\.ex:[0-9]' "${out_file}" || true)"

if [[ -z "${total_line}" ]]; then
  echo "dialyzer_gate: ${out_file} has no 'Total errors:' summary line — the" >&2
  echo "  Dialyzer run did not complete. Refusing to report a green gate." >&2
  [[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
  exit 2
fi

total_errors="$(sed -E 's/^Total errors: ([0-9]+).*/\1/' <<<"${total_line}")"
if [[ "${total_errors}" -gt 0 && "${warning_lines}" -eq 0 ]]; then
  echo "dialyzer_gate: ${out_file} claims '${total_line}' but lists no findings." >&2
  echo "  dialyxir swallows the whole warning list when .dialyzer_ignore.exs has" >&2
  echo "  a stale entry; re-run with --ignore-exit-status (or fix the stale" >&2
  echo "  filter). Refusing to report a green gate on an empty report." >&2
  grep -A5 -E '^Unused filters:' "${out_file}" >&2 || true
  [[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
  exit 2
fi

# Dialyzer prints paths relative to the app root ("lib/foo/bar.ex:12:3: ..."),
# with no app name, so attribute each finding by asking which app owns the file.
# Every lib/ path in the umbrella is unique across apps, and this catches the
# paths a "^lib/<app>/" prefix match misses (lib/mix/tasks/*.ex, lib/<app>.ex).
app_findings() {
  local app="$1" line path
  while IFS= read -r line; do
    path="${line%%:*}"
    if [[ -f "apps/${app}/${path}" ]]; then
      printf '%s\n' "${line}"
    fi
  done < <(grep -E '^lib/[^:]*\.ex:[0-9]' "${out_file}" || true)
}

echo "==> Dialyzer green gate — gated apps must have zero findings"
echo "    (source: ${out_file}, ${total_line})"
printf '%-24s %s\n' "APP" "FINDINGS"
printf '%-24s %s\n' "------------------------" "--------"

failed=0
declare -A findings_by_app=()
for app in "${GATED_APPS[@]}"; do
  if [[ ! -d "apps/${app}" ]]; then
    echo "dialyzer_gate: allowlisted app has no apps/${app} directory" >&2
    [[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
    exit 2
  fi

  findings_by_app["${app}"]="$(app_findings "${app}")"
  if [[ -z "${findings_by_app["${app}"]}" ]]; then
    count=0
  else
    count="$(grep -c '' <<<"${findings_by_app["${app}"]}")"
  fi

  printf '%-24s %s\n' "${app}" "${count}"
  if [[ "${count}" -ne 0 ]]; then
    failed=1
  fi
done

echo
if [[ "${failed}" -ne 0 ]]; then
  echo "GATE FAILED — a gated app regressed. Offending findings:" >&2
  for app in "${GATED_APPS[@]}"; do
    [[ -n "${findings_by_app["${app}"]}" ]] || continue
    while IFS= read -r line; do
      echo "  ${app}: ${line}" >&2
    done <<<"${findings_by_app["${app}"]}"
  done
  [[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
  exit 1
fi

echo "GATE PASSED — all ${#GATED_APPS[@]} gated apps are Dialyzer-clean."
[[ -n "${tmp_created}" ]] && rm -f "${tmp_created}"
exit 0
