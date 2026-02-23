# Planning Index

Last updated: 2026-02-24 (added 4 new inspiration ideas)

This file is the live board for tracked plans. Keep rows concise and link to canonical plan artifacts.

## Status Legend

- `proposed`: captured but not decomposed
- `planned`: scoped with milestones and test strategy
- `in_progress`: implementation active
- `in_review`: review artifact open, findings being addressed
- `ready_to_land`: review + tests complete, landing checklist in progress
- `landed`: integrated to target trunk revision
- `blocked`: waiting on dependency/decision/access
- `abandoned`: intentionally closed without landing

## Historical (Pre-Planning-System, Excluded from Migration)

These entries were already completed before the `planning/` workflow was created, so they are tracked here for context only.

| Phase | Focus | Historical Status | Source |
|---|---|---|---|
| 1 | Test/quality determinism foundations | `completed` | `debt_plan.md:10` |
| 2 | Runtime service decoupling | `completed` | `debt_plan.md:11` |
| 3 | Discovery test determinism and duplicate helper cleanup | `completed` | `debt_plan.md:12` |
| 4 | Functional TODO closure (X media + commentary persistence) | `completed` | `debt_plan.md:13` |

> **Note (2026-02-22):** Phase 3 duplicate helper cleanup is done. The remaining discovery test unskipping (11 `@tag :skip` in `discovery_test.exs`) was tracked under Phase 6. Phase 4 X media upload and commentary persistence are landed; residual `on_chain.ex` placeholder stats are intentional (optional feature, now feature-flagged in Phase 11).

## Active Plans

| Plan ID | Title | Status | Owner | Workspace | Change ID | Roadmap Ref | Updated |
|---|---|---|---|---|---|---|---|
| [PLN-20260223-macos-keychain-secrets-audit](plans/PLN-20260223-macos-keychain-secrets-audit.md) | macOS Keychain secrets path audit and hardening | `planned` | `zeebot` | `feature/pln-20260223-macos-keychain-secrets-audit` | `pending` | `ROADMAP.md` | 2026-02-23 |
| [PLN-20260222-debt-phase-09-gateway-reliability-decomposition](plans/PLN-20260222-debt-phase-09-gateway-reliability-decomposition.md) | Debt Phase 9 - Gateway runtime reliability decomposition | `planned` | `unassigned` | `feature/pln-20260222-debt-phase-09-gateway-reliability-decomposition` | `pending` | `debt_plan.md:99` | 2026-02-22 |
| [PLN-20260222-debt-phase-10-monolith-footprint-reduction](plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md) | Debt Phase 10 - Monolith and release footprint reduction | `planned` | `unassigned` | `feature/pln-20260222-debt-phase-10-monolith-footprint-reduction` | `pending` | `debt_plan.md:123` | 2026-02-22 |
| [PLN-20260222-debt-phase-13-client-ci-parity-governance](plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md) | Debt Phase 13 - Client CI parity and dependency governance | `planned` | `unassigned` | `feature/pln-20260222-debt-phase-13-client-ci-parity-governance` | `pending` | `debt_plan.md:200` | 2026-02-22 |
| [PLN-20260224-obfuscated-command-detection](plans/PLN-20260224-obfuscated-command-detection.md) | Obfuscated command detection in bash/exec tools | `landed` | `agent` | `feature/obfuscated-command-detection` | `svnuxqzr` | `IDEA-20260224-openclaw-obfuscated-command-detection` | 2026-02-23 |
| [PLN-20260224-ws-flood-protection](plans/PLN-20260224-ws-flood-protection.md) | Gateway WebSocket unauthorized request flood protection | `landed` | `claude` | `feature/ws-flood-protection` | `svnuxqzr` | `IDEA-20260224-openclaw-ws-flood-protection` | 2026-02-24 |
| [PLN-20260224-gemini-search-grounding](plans/PLN-20260224-gemini-search-grounding.md) | Add Gemini (Google Search grounding) as web_search provider | `landed` | `zeebot` | `feature/gemini-search-grounding` | `svnuxqzr` | `IDEA-20260224-openclaw-gemini-search-grounding` | 2026-02-23 |
| [PLN-20260224-deterministic-ci-test-hardening](plans/PLN-20260224-deterministic-ci-test-hardening.md) | Deterministic CI and test signal hardening | `in_progress` | `janitor` | `feature/pln-20260224-deterministic-ci` | `pending` | `ROADMAP.md` | 2026-02-24 |

## Ready for Review

| Plan ID | Title | Review Doc | Owner | Updated |
|---|---|---|---|---|

## Ready to Land

| Plan ID | Title | Landing Doc | Owner | Updated |
|---|---|---|---|---|

## Blocked

| Plan ID | Title | Blocker | Next Unblock Action | Updated |
|---|---|---|---|---|

## Recently Landed

| Plan ID | Title | Landed Revision | Notes | Updated |
|---|---|---|---|---|
| [PLN-20260224-inspiration-ideas-implementation](plans/PLN-20260224-inspiration-ideas-implementation.md) | Implement Inspiration Ideas from Upstream Research | `4e840d98` | Chinese overflow patterns, grep grouped+round-robin, auto-reasoning gate; 217 tests pass | 2026-02-24 |
| [PLN-20260224-gemini-search-grounding](plans/PLN-20260224-gemini-search-grounding.md) | Add Gemini (Google Search grounding) as web_search provider | `svnuxqzr` | Added Gemini provider support with grounding citations and redirect URL resolution | 2026-02-23 |
| [PLN-20260222-agent-introspection](plans/PLN-20260222-agent-introspection.md) | End-to-end agent introspection | `bec7bfae` | Final stacked landing `M2 -> M3 -> M4`; post-landing smoke tests passed | 2026-02-23 |
| PLN-20260223-diag-extend | Extend diag script with service/health/logs/config | `84e34b45` | Team test: Claude + Codex parallel work | 2026-02-23 |
| [PLN-20260223-transport-registry-dedup](plans/PLN-20260223-transport-registry-dedup.md) | Deduplicate transport_enabled? functions in TransportRegistry | `92c8ca86` | Eliminated ~64 lines of duplication across 6 transport clauses | 2026-02-23 |
| [PLN-20260223-poll-jobs-rename](plans/PLN-20260223-poll-jobs-rename.md) | Rename poll_jobs tool to await (Oh-My-Pi sync) | `26be7b4d` | Upstream naming parity; 14 tests pass | 2026-02-23 |
| [PLN-20260223-code-smell-cleanup](plans/PLN-20260223-code-smell-cleanup.md) | Code Smell Cleanup - Header Utils and Content-Type Parsing | — | Extracted header_key_match?/2 and parse_content_type/1; 28 tests pass | 2026-02-23 |
| [PLN-20260222-debt-phase-05-complexity-reduction](plans/PLN-20260222-debt-phase-05-complexity-reduction.md) | Debt Phase 5 - Complexity reduction (M1 inventory) | `117fc08b` | M1 baseline inventory complete; M2-M4 remaining | 2026-02-23 |
| [PLN-20260222-debt-phase-06-ci-test-hardening](plans/PLN-20260222-debt-phase-06-ci-test-hardening.md) | Debt Phase 6 - CI and test signal hardening | `f98750e5` | All milestones complete; 17 skip tags removed | 2026-02-23 |
| [PLN-20260222-debt-phase-07-run-state-concurrency](plans/PLN-20260222-debt-phase-07-run-state-concurrency.md) | Debt Phase 7 - Run-state correctness and concurrency safety | `ca47f7e9` | Atomic transitions, PubSub await, scheduler fix; 21 tests | 2026-02-23 |
| [PLN-20260222-debt-phase-08-store-persistence-scalability](plans/PLN-20260222-debt-phase-08-store-persistence-scalability.md) | Debt Phase 8 - Store and persistence scalability | `9c6c12af` | O(1) append, ReadCache, async DETS load; 298 tests | 2026-02-23 |
| [PLN-20260222-debt-phase-11-placeholder-stub-burndown](plans/PLN-20260222-debt-phase-11-placeholder-stub-burndown.md) | Debt Phase 11 - Placeholder and stub burn-down | `822cb2f6` | Telemetry counts, AI commentary, mu-law encoder; 45+ tests | 2026-02-23 |
| [PLN-20260222-debt-phase-12-deterministic-async-test-harness](plans/PLN-20260222-debt-phase-12-deterministic-async-test-harness.md) | Debt Phase 12 - Deterministic async test harness | `a8387a3d` | AsyncHelpers, 33 sleep sites removed, flake CI gate | 2026-02-23 |
| [PLN-20260223-pi-oh-my-pi-sync](plans/PLN-20260223-pi-oh-my-pi-sync.md) | Pi/Oh-My-Pi Upstream Sync - Models and Tools | `bb34c752` | Upstream parity confirmed; sync plan landed with no additional code deltas | 2026-02-23 |
| [PLN-20260223-lemon-quality-unblock](plans/PLN-20260223-lemon-quality-unblock.md) | Unblock `mix lemon.quality` | — | Dedupe test modules, TextGeneration bridge, CI quality guard | 2026-02-23 |
| [PLN-20260223-ai-test-expansion](plans/PLN-20260223-ai-test-expansion.md) | AI app test expansion | `ce421ec8` | 155 tests across Models, Anthropic, Google, Bedrock | 2026-02-23 |

## Ideas to Investigate

| Idea ID | Title | Source | Status | Complexity | Value | Updated |
|---|---|---|---|---|---|---|
| [IDEA-20260224-openclaw-gemini-search-grounding](ideas/IDEA-20260224-openclaw-gemini-search-grounding.md) | Add Gemini (Google Search grounding) as web_search provider | openclaw | `landed` | M | H | 2026-02-23 |
| [IDEA-20260224-openclaw-vertex-claude-routing](ideas/IDEA-20260224-openclaw-vertex-claude-routing.md) | Allow Claude model requests to route through Google Vertex AI | openclaw | `proposed` | M | M | 2026-02-24 |
| [IDEA-20260224-openclaw-ws-flood-protection](ideas/IDEA-20260224-openclaw-ws-flood-protection.md) | Gateway WebSocket unauthorized request flood protection | openclaw | `landed` | M | H | 2026-02-24 |
| [IDEA-20260224-openclaw-obfuscated-command-detection](ideas/IDEA-20260224-openclaw-obfuscated-command-detection.md) | Detect obfuscated commands that bypass allowlist filters | openclaw | `landed` | M | H | 2026-02-24 |
| [IDEA-20260224-openclaw-cron-web-ui-parity](ideas/IDEA-20260224-openclaw-cron-web-ui-parity.md) | Web UI cron edit parity with full run history and compact filters | openclaw | `proposed` | L | M | 2026-02-24 |
| [IDEA-20260224-openclaw-context-overflow-classification](ideas/IDEA-20260224-openclaw-context-overflow-classification.md) | Improved context overflow error classification and handling | openclaw | `proposed` | S | M | 2026-02-24 |
| [IDEA-20260224-oh-my-pi-job-delivery-acknowledgment](ideas/IDEA-20260224-oh-my-pi-job-delivery-acknowledgment.md) | Job delivery acknowledgment mechanism for async jobs | oh-my-pi | `proposed` | M | M | 2026-02-24 |
| [IDEA-20260224-oh-my-pi-editorconfig-caching](ideas/IDEA-20260224-oh-my-pi-editorconfig-caching.md) | EditorConfig caching and configurable tab width | oh-my-pi | `proposed` | M | M | 2026-02-24 |
| [IDEA-20260224-oh-my-pi-copilot-strict-mode](ideas/IDEA-20260224-oh-my-pi-copilot-strict-mode.md) | GitHub Copilot strict mode support in tool schemas | oh-my-pi | `proposed` | S | L | 2026-02-24 |
| [IDEA-20260224-ironclaw-wasm-fallback-source](ideas/IDEA-20260224-ironclaw-wasm-fallback-source.md) | WASM extension fallback to build-from-source when download fails | ironclaw | `proposed` | M | M | 2026-02-24 |
| [IDEA-20260224-openclaw-japanese-fts](ideas/IDEA-20260224-openclaw-japanese-fts.md) | Japanese query expansion support for full-text search | openclaw | `proposed` | S | M | 2026-02-24 |
| [IDEA-20260224-openclaw-synology-chat](ideas/IDEA-20260224-openclaw-synology-chat.md) | Synology Chat native channel support | openclaw | `proposed` | M | M | 2026-02-24 |
| [IDEA-20260224-ironclaw-docker-detection](ideas/IDEA-20260224-ironclaw-docker-detection.md) | Docker sandbox detection and platform guidance | ironclaw | `proposed` | L | H | 2026-02-24 |
| [IDEA-20260224-ironclaw-skills-catalog](ideas/IDEA-20260224-ironclaw-skills-catalog.md) | Skills catalog with ClawHub integration and search | ironclaw | `proposed` | L | M | 2026-02-24 |
| [IDEA-20260224-openclaw-channel-enable-config](ideas/IDEA-20260224-openclaw-channel-enable-config.md) | Per-channel enabled configuration for bundled channels | openclaw | `proposed` | S | M | 2026-02-24 |
| [IDEA-20260224-openclaw-telegram-polling-offsets](ideas/IDEA-20260224-openclaw-telegram-polling-offsets.md) | Per-bot scoped polling offsets for Telegram | openclaw | `proposed` | S | M | 2026-02-24 |

## Templates

- [PLAN_TEMPLATE.md](./templates/PLAN_TEMPLATE.md)
