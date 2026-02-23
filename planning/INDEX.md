# Planning Index

Last updated: 2026-02-24

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
| [PLN-20260224-inspiration-ideas-implementation](plans/PLN-20260224-inspiration-ideas-implementation.md) | Implement Inspiration Ideas from Upstream Research | `in_progress` | `janitor` | `feature/pln-20260224-inspiration-ideas` | `pending` | `ROADMAP.md` | 2026-02-24 |
| [PLN-20260224-runtime-hot-reload](plans/PLN-20260224-runtime-hot-reload.md) | Runtime Hot-Reload System for BEAM Modules and Extensions | `in_progress` | `janitor` | `feature/pln-20260224-runtime-hot-reload` | `pending` | — | 2026-02-24 |

| [PLN-20260224-long-running-agent-harnesses](plans/PLN-20260224-long-running-agent-harnesses.md) | Long-Running Agent Harnesses and Task Management | `in_progress` | `janitor` | `feature/pln-20260224-long-running-harnesses` | `pending` | — | 2026-02-24 |

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
| [PLN-20260224-pi-model-resolver-slash-support](plans/PLN-20260224-pi-model-resolver-slash-support.md) | Add Slash Separator Support for Provider/Model Format | `5c7098c1` | Pi parity: slash separator support for provider/model format | 2026-02-24 |
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

## Templates

## Ideas to Investigate

Research findings from upstream projects (oh-my-pi, pi, openclaw, ironclaw, nanoclaw) for potential adoption.

| Idea ID | Title | Source | Status | Complexity | Value | Recommendation |
|---|---|---|---|---|---|---|
| [IDEA-20260223-pi-skill-discovery](ideas/IDEA-20260223-pi-skill-discovery.md) | Auto-Discover Skills in .agents Paths | pi | `completed` | M | H | **Already implemented** - Feature exists in Lemon |
| [IDEA-20260223-openclaw-markup-sanitization](ideas/IDEA-20260223-openclaw-markup-sanitization.md) | Sanitize Untrusted Markup in Chat Payloads | openclaw | `completed` | M | H | **Already implemented** - Full XSS protection at gateway + UI |
| [IDEA-20260223-openclaw-config-redaction](ideas/IDEA-20260223-openclaw-config-redaction.md) | Redact Sensitive Values in Config Get Output | openclaw | `completed` | S | H | **Already implemented** - Full parity with broader pattern coverage |
| [IDEA-20260223-ironclaw-context-compaction](ideas/IDEA-20260223-ironclaw-context-compaction.md) | Auto-Compact and Retry on ContextLengthExceeded | ironclaw | `completed` | L | M | **Already implemented** - Full parity with comprehensive telemetry |
| [IDEA-20260223-oh-my-pi-todo-phase-management](ideas/IDEA-20260223-oh-my-pi-todo-phase-management.md) | In-Memory Todo Phase Management for ToolSession | oh-my-pi | `completed` | L | L | **Already implemented** - ETS-based TodoStore is superior |
| [IDEA-20260223-pi-model-resolver](ideas/IDEA-20260223-pi-model-resolver.md) | Provider/Model Split Resolution for Gateway Model IDs | pi | `proposed` | M | M | **Implement** - Add slash separator support for provider/model format |
| [IDEA-20260223-ironclaw-wasm-hot-activation](ideas/IDEA-20260223-ironclaw-wasm-hot-activation.md) | Hot-Activate WASM Channels with Channel-First Prompts | ironclaw | `completed` | L | M | **Already implemented** - Full WASM hot-reload via Lemon.Reload |
| [IDEA-20260223-oh-my-pi-strict-mode](ideas/IDEA-20260223-oh-my-pi-strict-mode.md) | Tool Schema Strict Mode for OpenAI Providers | oh-my-pi | `proposed` | M | M | **Defer** - Needs deeper audit |
| [IDEA-20260223-pi-streaming-highlight](ideas/IDEA-20260223-pi-streaming-highlight.md) | Incremental Highlight for Streaming Write Tool Calls | pi | `proposed` | M | L | **Defer** - Nice-to-have UX |
| [IDEA-20260223-ironclaw-shell-completion](ideas/IDEA-20260223-ironclaw-shell-completion.md) | Shell Completion Generation via clap_complete | ironclaw | `proposed` | M | L | **Defer** - Nice-to-have DX |
| [IDEA-20260223-nanoclaw-voice-transcription](ideas/IDEA-20260223-nanoclaw-voice-transcription.md) | Voice Transcription as Nanorepo Skill | nanoclaw | `proposed` | M | M | **Defer** - Wait for voice priority |
| [IDEA-20260224-community-mcp-tool-integration](ideas/IDEA-20260224-community-mcp-tool-integration.md) | MCP (Model Context Protocol) Tool Integration | community | `proposed` | M | H | **Proceed** - Industry standard, partial implementation exists |
| [IDEA-20260224-community-multi-agent-orchestration](ideas/IDEA-20260224-community-multi-agent-orchestration.md) | Multi-Agent Orchestration and Routing | community | `proposed` | M | H | **Investigate** - High community demand, OpenClaw pattern |
| [IDEA-20260224-community-wasm-sandbox-tools](ideas/IDEA-20260224-community-wasm-sandbox-tools.md) | WASM Sandbox for AI Tool Execution | community | `proposed` | M | H | **Proceed** - Industry trend, enhances existing WASM support |
| [IDEA-20260224-community-channel-adapters](ideas/IDEA-20260224-community-channel-adapters.md) | Additional Channel Adapters (Discord, Slack, WhatsApp) | community | `proposed` | M | H | **Investigate** - High demand, OpenClaw's key differentiator |
| [IDEA-20260224-community-long-running-agent-harnesses](ideas/IDEA-20260224-community-long-running-agent-harnesses.md) | Long-Running Agent Harnesses and Task Management | community | `proposed` | M | M | **Proceed** - Addresses common pain point, builds on todo system |

### Summary

- **High Priority (Proceed/Verify)**: 4 ideas - Skill discovery, security sanitization, config redaction, context compaction
- **Medium Priority (Investigate)**: 4 ideas - Todo management, model resolver, WASM activation, strict mode
- **Low Priority (Defer)**: 3 ideas - Streaming highlight, shell completion, voice transcription

### Community Research Summary (2026-02-24)

New findings from community research:

| Priority | Ideas | Key Themes |
|----------|-------|------------|
| **Proceed** | 3 | MCP integration, WASM sandboxing, Long-running harnesses |
| **Investigate** | 2 | Multi-agent orchestration, Channel adapters |

**Key Insights:**
1. **MCP is becoming an industry standard** - Multiple frameworks competing on MCP support
2. **Multi-channel is table stakes** - OpenClaw's success driven by Discord/Telegram/Slack support
3. **WASM sandboxing is the future** - Microsoft, NVIDIA, and others investing heavily
4. **Long-running agents need better harnesses** - Common pain point of agents "one-shotting" tasks

**Strategic Opportunities:**
- Discord adapter would capture OpenClaw-style community use cases
- MCP support would enable ecosystem integration
- Enhanced WASM would differentiate from sidecar-based approaches

## Templates

- [PLAN_TEMPLATE.md](./templates/PLAN_TEMPLATE.md)
- [IDEA_TEMPLATE.md](./templates/IDEA_TEMPLATE.md) (create when first idea promoted to plan)
