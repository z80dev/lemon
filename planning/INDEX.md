# Planning Index

Last updated: 2026-02-23

This file is the live board for tracked plans. Keep rows concise and link to canonical plan artifacts.

## Status Legend

- `proposed`: captured but not decomposed
- `planned`: scoped with milestones and test strategy
- `in_progress`: implementation active
- `in_review`: review artifact open, findings being addressed
- `ready_to_merge`: review + tests complete, merge checklist in progress
- `merged`: integrated to target branch
- `blocked`: waiting on dependency/decision/access
- `abandoned`: intentionally closed without merge

## Historical (Pre-Planning-System, Excluded from Migration)

These entries were already completed before the `planning/` workflow was created, so they are tracked here for context only.

| Phase | Focus | Historical Status | Source |
|---|---|---|---|
| 1 | Test/quality determinism foundations | `completed` | `debt_plan.md:10` |
| 2 | Runtime service decoupling | `completed` | `debt_plan.md:11` |
| 3 | Discovery test determinism and duplicate helper cleanup | `completed` | `debt_plan.md:12` |
| 4 | Functional TODO closure (X media + commentary persistence) | `completed` | `debt_plan.md:13` |

> **Note (2026-02-22):** Phase 3 duplicate helper cleanup is done. The remaining discovery test unskipping (11 `@tag :skip` in `discovery_test.exs`) was tracked under Phase 6. Phase 4 X media upload and commentary persistence are merged; residual `on_chain.ex` placeholder stats are intentional (optional feature, now feature-flagged in Phase 11).

## Active Plans

| Plan ID | Title | Status | Owner | Branch | Roadmap Ref | Updated |
|---|---|---|---|---|---|---|
| [PLN-20260222-agent-introspection](plans/PLN-20260222-agent-introspection.md) | End-to-end agent introspection | `in_progress` | `codex` | `feature/pln-20260222-agent-introspection-m1` | `ROADMAP.md:74` | 2026-02-23 |
| [PLN-20260223-lemon-quality-unblock](plans/PLN-20260223-lemon-quality-unblock.md) | Unblock `mix lemon.quality` (duplicate tests + architecture boundaries) | `planned` | `codex` | `feature/pln-20260223-lemon-quality-unblock` | `ROADMAP.md:74` | 2026-02-23 |
| [PLN-20260223-ai-test-expansion](plans/PLN-20260223-ai-test-expansion.md) | Add tests for untested AI app modules | `in_review` | `zeebot` | — | `ROADMAP.md` | 2026-02-23 |
| [PLN-20260223-macos-keychain-secrets-audit](plans/PLN-20260223-macos-keychain-secrets-audit.md) | macOS Keychain secrets path audit and hardening | `planned` | `zeebot` | `feature/pln-20260223-macos-keychain-secrets-audit` | `ROADMAP.md` | 2026-02-23 |
| [PLN-20260222-debt-phase-09-gateway-reliability-decomposition](plans/PLN-20260222-debt-phase-09-gateway-reliability-decomposition.md) | Debt Phase 9 - Gateway runtime reliability decomposition | `planned` | `unassigned` | `feature/pln-20260222-debt-phase-09-gateway-reliability-decomposition` | `debt_plan.md:99` | 2026-02-22 |
| [PLN-20260222-debt-phase-10-monolith-footprint-reduction](plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md) | Debt Phase 10 - Monolith and release footprint reduction | `planned` | `unassigned` | `feature/pln-20260222-debt-phase-10-monolith-footprint-reduction` | `debt_plan.md:123` | 2026-02-22 |
| [PLN-20260222-debt-phase-13-client-ci-parity-governance](plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md) | Debt Phase 13 - Client CI parity and dependency governance | `planned` | `unassigned` | `feature/pln-20260222-debt-phase-13-client-ci-parity-governance` | `debt_plan.md:200` | 2026-02-22 |

## Ready for Review

| Plan ID | Title | Review Doc | Owner | Updated |
|---|---|---|---|---|
| [PLN-20260223-ai-test-expansion](plans/PLN-20260223-ai-test-expansion.md) | Add tests for untested AI app modules | [RVW-PLN-20260223-ai-test-expansion](reviews/RVW-PLN-20260223-ai-test-expansion.md) | `zeebot` | 2026-02-23 |

## Ready to Merge

| Plan ID | Title | Merge Doc | Owner | Updated |
|---|---|---|---|---|

## Blocked

| Plan ID | Title | Blocker | Next Unblock Action | Updated |
|---|---|---|---|---|

## Recently Merged

| Plan ID | Title | Merge Commit | Notes | Updated |
|---|---|---|---|---|
| [PLN-20260222-debt-phase-05-complexity-reduction](plans/PLN-20260222-debt-phase-05-complexity-reduction.md) | Debt Phase 5 - Complexity reduction (M1 inventory) | `117fc08b` | M1 baseline inventory complete; M2-M4 remaining | 2026-02-23 |
| [PLN-20260222-debt-phase-06-ci-test-hardening](plans/PLN-20260222-debt-phase-06-ci-test-hardening.md) | Debt Phase 6 - CI and test signal hardening | `f98750e5` | All milestones complete; 17 skip tags removed | 2026-02-23 |
| [PLN-20260222-debt-phase-07-run-state-concurrency](plans/PLN-20260222-debt-phase-07-run-state-concurrency.md) | Debt Phase 7 - Run-state correctness and concurrency safety | `ca47f7e9` | Atomic transitions, PubSub await, scheduler fix; 21 tests | 2026-02-23 |
| [PLN-20260222-debt-phase-08-store-persistence-scalability](plans/PLN-20260222-debt-phase-08-store-persistence-scalability.md) | Debt Phase 8 - Store and persistence scalability | `9c6c12af` | O(1) append, ReadCache, async DETS load; 298 tests | 2026-02-23 |
| [PLN-20260222-debt-phase-11-placeholder-stub-burndown](plans/PLN-20260222-debt-phase-11-placeholder-stub-burndown.md) | Debt Phase 11 - Placeholder and stub burn-down | `822cb2f6` | Telemetry counts, AI commentary, mu-law encoder; 45+ tests | 2026-02-23 |
| [PLN-20260222-debt-phase-12-deterministic-async-test-harness](plans/PLN-20260222-debt-phase-12-deterministic-async-test-harness.md) | Debt Phase 12 - Deterministic async test harness | `a8387a3d` | AsyncHelpers, 33 sleep sites removed, flake CI gate | 2026-02-23 |
| [PLN-20260223-pi-oh-my-pi-sync](plans/PLN-20260223-pi-oh-my-pi-sync.md) | Pi/Oh-My-Pi Upstream Sync - Models and Tools | `bb34c752` | Upstream parity confirmed; sync plan merged with no additional code deltas | 2026-02-23 |

## Templates

- [PLAN_TEMPLATE.md](./templates/PLAN_TEMPLATE.md)
