# Planning Index

Last updated: 2026-02-25

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
| [PLN-20260223-macos-keychain-secrets-audit](plans/PLN-20260223-macos-keychain-secrets-audit.md) | macOS Keychain secrets path audit and hardening | `ready_to_land` | `janitor` | `feature/pln-20260223-macos-keychain-secrets-audit` | `pending` | `ROADMAP.md` | 2026-02-25 |
| [PLN-20260224-deterministic-ci-test-hardening](plans/PLN-20260224-deterministic-ci-test-hardening.md) | Deterministic CI and test signal hardening | `ready_to_land` | `janitor` | `feature/pln-20260224-deterministic-ci-test-hardening` | `pending` | `ROADMAP.md` | 2026-02-25 |
| [PLN-20260222-debt-phase-10-monolith-footprint-reduction](plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md) | Debt Phase 10 - Monolith and release footprint reduction | `ready_to_land` | `janitor` | `feature/pln-20260222-debt-phase-10-monolith-footprint-reduction` | `pending` | `debt_plan.md:123` | 2026-02-25 |
| [PLN-20260222-debt-phase-05-m2-submodule-extraction](plans/PLN-20260222-debt-phase-05-m2-submodule-extraction.md) | Debt Phase 5 M2: Ai.Models submodule extraction | `ready_to_land` | `janitor` | `feature/pln-20260222-debt-phase-05-m2-submodule-extraction` | `pending` | `debt_plan.md:40` | 2026-02-25 |
| [PLN-20260222-debt-phase-13-client-ci-parity-governance](plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md) | Debt Phase 13 - Client CI parity and dependency governance | `ready_to_land` | `janitor` | `feature/pln-20260222-debt-phase-13-m7-eslint-parity` | `pending` | `debt_plan.md:200` | 2026-02-26 |
| [PLN-20260224-inspiration-ideas-implementation](plans/PLN-20260224-inspiration-ideas-implementation.md) | Implement Inspiration Ideas from Upstream Research | `ready_to_land` | `janitor` | `feature/pln-20260224-inspiration-ideas-implementation` | `pending` | `ROADMAP.md` | 2026-02-25 |
| [PLN-20260224-long-running-agent-harnesses](plans/PLN-20260224-long-running-agent-harnesses.md) | Long-Running Agent Harnesses and Task Management | `ready_to_land` | `janitor` | `feature/pln-20260224-long-running-harnesses` | `pending` | — | 2026-02-25 |

## Ready for Review

| Plan ID | Title | Review Doc | Owner | Updated |
|---|---|---|---|---|

## Ready to Land

| Plan ID | Title | Landing Doc | Owner | Updated |
|---|---|---|---|---|
| [PLN-20260223-macos-keychain-secrets-audit](plans/PLN-20260223-macos-keychain-secrets-audit.md) | macOS Keychain secrets path audit and hardening | [MRG-PLN-20260223-macos-keychain-secrets-audit.md](merges/MRG-PLN-20260223-macos-keychain-secrets-audit.md) | `janitor` | 2026-02-25 |
| [PLN-20260222-debt-phase-10-monolith-footprint-reduction](plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md) | Debt Phase 10 - Monolith and release footprint reduction | [MRG-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md](merges/MRG-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md) | `janitor` | 2026-02-25 |
| [PLN-20260222-debt-phase-05-m2-submodule-extraction](plans/PLN-20260222-debt-phase-05-m2-submodule-extraction.md) | Debt Phase 5 M2: Ai.Models submodule extraction | [MRG-PLN-20260222-debt-phase-05-m2-submodule-extraction.md](merges/MRG-PLN-20260222-debt-phase-05-m2-submodule-extraction.md) | `janitor` | 2026-02-25 |
| [PLN-20260222-debt-phase-13-client-ci-parity-governance](plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md) | Debt Phase 13 - Client CI parity and dependency governance | [MRG-PLN-20260222-debt-phase-13-client-ci-parity-governance.md](merges/MRG-PLN-20260222-debt-phase-13-client-ci-parity-governance.md) | `janitor` | 2026-02-26 |
| [PLN-20260224-deterministic-ci-test-hardening](plans/PLN-20260224-deterministic-ci-test-hardening.md) | Deterministic CI and test signal hardening | [MRG-PLN-20260224-deterministic-ci-test-hardening.md](merges/MRG-PLN-20260224-deterministic-ci-test-hardening.md) | `janitor` | 2026-02-25 |
| [PLN-20260224-runtime-hot-reload](plans/PLN-20260224-runtime-hot-reload.md) | Runtime Hot-Reload System for BEAM Modules and Extensions | [MRG-PLN-20260224-runtime-hot-reload.md](merges/MRG-PLN-20260224-runtime-hot-reload.md) | `janitor` | 2026-02-25 |
| [PLN-20260224-long-running-agent-harnesses](plans/PLN-20260224-long-running-agent-harnesses.md) | Long-Running Agent Harnesses and Task Management | [MRG-PLN-20260224-long-running-agent-harnesses.md](merges/MRG-PLN-20260224-long-running-agent-harnesses.md) | `janitor` | 2026-02-25 |
| [PLN-20260224-inspiration-ideas-implementation](plans/PLN-20260224-inspiration-ideas-implementation.md) | Implement Inspiration Ideas from Upstream Research | [MRG-PLN-20260224-inspiration-ideas-implementation.md](merges/MRG-PLN-20260224-inspiration-ideas-implementation.md) | `janitor` | 2026-02-25 |

## Blocked

| Plan ID | Title | Blocker | Next Unblock Action | Updated |
|---|---|---|---|---|

## Recently Landed

| Plan ID | Title | Landed Revision | Notes | Updated |
|---|---|---|---|---|
| [PLN-20260222-debt-phase-09-gateway-reliability-decomposition](plans/PLN-20260222-debt-phase-09-gateway-reliability-decomposition.md) | Debt Phase 9 - Gateway runtime reliability decomposition | `034fc111` | Close-out: async email test fix landed | 2026-02-25 |
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
| [IDEA-20260224-openclaw-env-backed-secret-refs](ideas/IDEA-20260224-openclaw-env-backed-secret-refs.md) | Env-Backed Secret References and Plaintext-Free Auth Persistence | openclaw | `proposed` | M | H | **Proceed** - Strong security value; closes secret-ref implementation gap |
| [IDEA-20260224-ironclaw-signal-channel-adapter](ideas/IDEA-20260224-ironclaw-signal-channel-adapter.md) | Native Signal Channel Adapter via signal-cli HTTP Daemon | ironclaw | `proposed` | M | M | **Investigate** - Good channel expansion after core channel priorities |
| [IDEA-20260224-oh-my-pi-model-role-badge](ideas/IDEA-20260224-oh-my-pi-model-role-badge.md) | Model Picker Role Badges in /model UX | oh-my-pi | `proposed` | S | L | **Defer** - Helpful UI polish but lower strategic impact |
| [IDEA-20260224-community-quota-aware-agent-runs](ideas/IDEA-20260224-community-quota-aware-agent-runs.md) | Quota-Aware Long-Run Planning and Resume Checkpoints | community | `proposed` | M | M | **Investigate** - Improve long-session completion under usage limits |
| [IDEA-20260225-ironclaw-openrouter-setup-preset](ideas/IDEA-20260225-ironclaw-openrouter-setup-preset.md) | OpenRouter Preset in Setup Wizard | ironclaw | `proposed` | S | M | **Investigate** - Low-cost onboarding DX win for OpenRouter users |
| [IDEA-20260225-openclaw-cron-jobid-hardening](ideas/IDEA-20260225-openclaw-cron-jobid-hardening.md) | Canonical jobId Handling and Validation for cron.runs | openclaw | `proposed` | S | M | **Investigate** - Align cron alias parsing across tool + RPC layers |
| [IDEA-20260225-community-rate-limit-auto-resume](ideas/IDEA-20260225-community-rate-limit-auto-resume.md) | Auto-Resume Runs After Rate-Limit Reset | community | `proposed` | M | H | **Proceed** - High-demand long-run reliability feature |
| [IDEA-20260225-community-guardrailed-agentic-workflows](ideas/IDEA-20260225-community-guardrailed-agentic-workflows.md) | Guardrailed Markdown Agentic Workflows with Mandatory Human Review | industry | `proposed` | M | H | **Investigate** - Productize approvals + cron into auditable workflows |
| [IDEA-20260225-openclaw-secrets-onboarding-parity](ideas/IDEA-20260225-openclaw-secrets-onboarding-parity.md) | Secret-Ref Onboarding Parity Across Built-In and Custom Providers | openclaw | `proposed` | M | H | **Proceed** - Close provider secret-ref consistency gaps across onboarding/runtime |
| [IDEA-20260225-ironclaw-kind-aware-extension-registry](ideas/IDEA-20260225-ironclaw-kind-aware-extension-registry.md) | Kind-Aware Extension Registry to Prevent Tool/Channel Name Collisions | ironclaw | `proposed` | S | M | **Investigate** - Add explicit (name, kind) collision hardening for extension ecosystems |
| [IDEA-20260225-community-rate-limit-session-self-healing](ideas/IDEA-20260225-community-rate-limit-session-self-healing.md) | Self-Healing Sessions for Persistent Rate-Limit Wedges | community | `proposed` | M | H | **Proceed** - Add in-session recovery when one run remains wedged after reset |
| [IDEA-20260225-community-trace-driven-agent-evaluation](ideas/IDEA-20260225-community-trace-driven-agent-evaluation.md) | Trace-Driven Agent Evaluation with Degradation Alerts and HITL Audits | industry | `proposed` | M | H | **Investigate** - Build scoring/drift/audit layer on top of run introspection |
| [IDEA-20260225-openclaw-schema-first-config-ops](ideas/IDEA-20260225-openclaw-schema-first-config-ops.md) | Schema-First Config Operations Guidance in Agent Prompts | openclaw | `proposed` | S | M | **Investigate** - Encourage schema lookup before config edits/answers to reduce guesswork |
| [IDEA-20260225-oh-my-pi-changelog-schema-hardening](ideas/IDEA-20260225-oh-my-pi-changelog-schema-hardening.md) | Changelog Schema Hardening for Agentic Commit Tooling | oh-my-pi | `proposed` | M | M | **Investigate** - Add schema-backed changelog categories/payload validation for automation reliability |
| [IDEA-20260225-community-episodic-git-verified-handoffs](ideas/IDEA-20260225-community-episodic-git-verified-handoffs.md) | Episodic Runs with Git-Verified Handoffs and Termination Guards | community | `proposed` | M | H | **Proceed** - Layer anti-drift/anti-loop episode controls on top of harness checkpoints |
| [IDEA-20260225-community-autonomous-agent-consent-scopes](ideas/IDEA-20260225-community-autonomous-agent-consent-scopes.md) | Consent Scopes and Exposure Guardrails for Always-On Agents | industry | `proposed` | M | H | **Investigate** - Productize unified consent profiles + exposure posture checks |

### Summary

- **High Priority (Proceed/Verify)**: 5 ideas - Skill discovery, security sanitization, config redaction, context compaction, env-backed secret refs
- **Medium Priority (Investigate)**: 5 ideas - Todo management, model resolver, WASM activation, strict mode, Signal/quota-aware workflows
- **Low Priority (Defer)**: 4 ideas - Streaming highlight, shell completion, voice transcription, model-role badge UX

### Community Research Summary (2026-02-24)

New findings from community research:

| Priority | Ideas | Key Themes |
|----------|-------|------------|
| **Proceed** | 3 | MCP integration, WASM sandboxing, Long-running harnesses |
| **Investigate** | 3 | Multi-agent orchestration, Channel adapters, Quota-aware task planning |

**Key Insights:**
1. **MCP is becoming an industry standard** - Multiple frameworks competing on MCP support
2. **Multi-channel is table stakes** - OpenClaw's success driven by Discord/Telegram/Slack support
3. **WASM sandboxing is the future** - Microsoft, NVIDIA, and others investing heavily
4. **Long-running agents need better harnesses** - Common pain point of agents "one-shotting" tasks
5. **Quota friction hurts long sessions** - Users report limits interrupting multi-hour coding flows

**Strategic Opportunities:**
- Discord adapter would capture OpenClaw-style community use cases
- MCP support would enable ecosystem integration
- Enhanced WASM would differentiate from sidecar-based approaches

### Research Addendum (2026-02-25)

- New upstream delta captured from IronClaw: OpenRouter-first setup wizard preset.
- New cron hardening idea captured from OpenClaw: canonical `jobId` handling for `cron.runs` paths.
- New community demand signal: explicit auto-resume after provider limit reset (execution-time continuity).
- New industry pattern signal: markdown-authored agentic workflows with mandatory human review gates.
- Additional upstream deltas captured: OpenClaw schema-first config guidance and Oh-My-Pi changelog schema hardening.
- Additional community/industry signals captured: episodic git-verified handoffs for overnight runs, plus consent-scope hardening for always-on autonomous agents.

## Templates

- [PLAN_TEMPLATE.md](./templates/PLAN_TEMPLATE.md)
- [IDEA_TEMPLATE.md](./templates/IDEA_TEMPLATE.md) (create when first idea promoted to plan)
