# Hermes parity implementation initiatives

Status: active
Owner: Codex
Baseline: `ff4adf1e`
Source matrix: [`lemon-hermes-gap-audit-2026-08-11.md`](lemon-hermes-gap-audit-2026-08-11.md)

This program converts the remaining source-pinned Hermes comparison into
vertical Lemon product work. Each lane must reuse Lemon's existing stores,
router, control plane, policy, and supervision boundaries. A lane is not done
when an internal module exists: it must expose a coherent user workflow,
document that workflow, and prove it against a running Lemon instance.

## Wave 1

| Initiative | Branch | Primary ownership | Required proof |
|---|---|---|---|
| Management Web and sessions | `feat/parity-web-admin` | `lemon_web`, shared session lifecycle API, related control-plane methods | Authenticated real-browser workflow against a running source runtime; session mutation and redacted export/prune tests |
| Profiles and provider orchestration | `feat/parity-profiles-models` + TUI client follow-up | First-class user profiles, roster/canonical chat, packaged CLI/control plane/TUI, provider pool/fallback UX | Isolated profile lifecycle plus provider-routing proof through a real control plane or packaged CLI; authenticated real-WebSocket TUI profile proof |
| Operations and secret sources | `feat/parity-ops-lifecycle` | `~/.lemon` data contract, backup/verify/restore, update receipts/rollback where safe, external secret-source boundary | Adversarial tests and isolated-HOME source/package backup/restore and secret-resolution proof |

## Wave 2

Wave 2 begins after Wave 1 settles shared APIs, so it can build on those
boundaries without duplicating them.

1. Bounded document extraction and context references, followed by auditable
   learn-from-source review over the existing memory and skill stores.
2. Skill bundles/profile enablement and automation blueprints with explicit
   review and activation.
3. Product-shell and remote-operation closure: multi-controller connections,
   merged rosters, remote steer/redirect, and a desktop packaging decision
   backed by a runnable prototype rather than a WebView-only claim.

The first initiative now has a shipped vertical: `LemonCore.Context` owns one
bounded preview/resolve contract for files, folders, git diffs, public URLs,
and redacted session exports; its document boundary sniffs PDF, DOCX, XLSX,
PPTX, ipynb, and text content before extraction. The packaged/source
`lemon context` command reuses that service. Archive expansion/traversal,
root/symlink, URL SSRF/redirect, sensitive-output, and operation-budget cases
are covered by focused adversarial tests. Learn-from-source review remains a
separate follow-on over the existing memory/skill stores.

The second initiative now has source/package CLI and authenticated Web
verticals over one `LemonAutomation.Blueprint.Catalog` boundary. The Web path
is `/manage/blueprints`: it keeps manifest prose and executable/source content
out of LiveView state, previews without mutation, requires the exact fresh
digest, fails closed on drift, and reports duplicate-safe replay through the
existing profile and cron services. Suggestions, richer blueprint shapes, and
a TUI catalog remain follow-ons.

## Integration gates

- Every contributor works in an isolated worktree and commits a self-contained
  vertical with its documentation.
- Cross-app service ownership follows `docs/architecture_boundaries.md`; Web
  pages do not become a second persistence or configuration layer.
- Secret values, prompts, raw paths, and unredacted session content must not
  enter status APIs, receipts, logs, or proof artifacts.
- Focused tests run in each lane. After integration, authoritative umbrella and
  client suites run serially to avoid shared build and environment pollution.
- Source and assembled release launchers must both be exercised. Browser work
  requires desktop/mobile screenshots, console inspection, and accessibility
  checks against a real runtime.
- The source-pinned parity audit is updated only for behavior proven in the
  integrated tree. Anything not shipped remains explicitly partial or missing.
