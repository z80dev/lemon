# Planning Index

Last updated: 2026-03-07

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
| [PLN-20250308-auto-compact-context-retry](plans/PLN-20250308-auto-compact-context-retry.md) | Auto-Compact and Retry on ContextLengthExceeded | ready_to_land | janitor | feature/pln-20250308-auto-compact-context-retry | pending | - | 2026-03-08 |

## Ready for Review

| Plan ID | Title | Review Doc | Owner | Updated |
|---|---|---|---|---|
| — | — | — | — | — | — |

## Ready to Land

| Plan ID | Title | Landing Doc | Owner | Updated |
|---|---|---|---|---|
| — | — | — | — | — |


## Blocked

| Plan ID | Title | Blocker | Next Unblock Action | Updated |
|---|---|---|---|---|

## Recently Landed

| Plan ID | Title | Landed Revision | Notes | Updated |
|---|---|---|---|---|
| [PLN-20260303-rate-limit-auto-resume](plans/PLN-20260303-rate-limit-auto-resume.md) | Auto-Resume Runs After Rate-Limit Reset | `62833edb` | Rate limit pause tracking, ResumeScheduler, RunGraph integration, 69 tests | 2026-03-06 |
| [PLN-20260302-secrets-store-preferred-path](plans/PLN-20260302-secrets-store-preferred-path.md) | Encrypted Secrets Store as Preferred Path | `b49c9c72` | Core resolution enhancement, provider config integration, migration tooling | 2026-03-06 |
| [PLN-20260223-secrets-store-preferred](plans/PLN-20260223-secrets-store-preferred.md) | Encrypted Secrets Store as Preferred Secret Access Path | `cdd51b12` | Store-first resolution for AI providers, channels, skills; import/check tasks | 2026-03-06 |
| [PLN-20260302-tool-call-name-normalization](plans/PLN-20260302-tool-call-name-normalization.md) | Normalize Whitespace-Padded Tool Call Names | `6f3d3ace` | Tool name normalization + telemetry in agent_core and coding_agent | 2026-03-02 |
| [PLN-20260301-mcp-tool-integration](plans/PLN-20260301-mcp-tool-integration.md) | MCP Tool Integration | `d29fd4b7` | MCP client/server, tool registry integration, 54+ tests | 2026-03-01 |
| [PLN-20260226-agent-games-platform](plans/PLN-20260226-agent-games-platform.md) | Agent-vs-Agent Game Platform (REST API + Live Spectator Web) | `61e6c71e` | Merged with TicTacToe addition; 71 tests pass | 2026-03-01 |
| [PLN-20260224-long-running-agent-harnesses](plans/PLN-20260224-long-running-agent-harnesses.md) | Long-Running Agent Harnesses and Task Management | `75f434c7` | Idle watchdog, keepalive, checkpointing, progress tracking | 2026-02-28 |
| [PLN-20260224-inspiration-ideas-implementation](plans/PLN-20260224-inspiration-ideas-implementation.md) | Implement Inspiration Ideas from Upstream Research | `c7d2c70c` | Chinese overflow patterns, grep grouped output, auto-reasoning gate | 2026-02-28 |
| [PLN-20260224-runtime-hot-reload](plans/PLN-20260224-runtime-hot-reload.md) | Runtime Hot-Reload System for BEAM Modules and Extensions | `6bb85309` | Lemon.Reload, /reload command, extension lifecycle | 2026-02-28 |
| [PLN-20260224-deterministic-ci-test-hardening](plans/PLN-20260224-deterministic-ci-test-hardening.md) | Deterministic CI and test signal hardening | `99d95b28` | AsyncHelpers, flake-detection CI job, 33 sleep sites removed | 2026-02-28 |
| [PLN-20260223-macos-keychain-secrets-audit](plans/PLN-20260223-macos-keychain-secrets-audit.md) | macOS Keychain secrets path audit and hardening | `93fd362d` | Secrets flow matrix, fallback precedence tests, auth helper hardening | 2026-02-28 |
| [PLN-20260222-debt-phase-13-client-ci-parity-governance](plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md) | Debt Phase 13 - Client CI parity and dependency governance | `e548cedd` | Client vitest configs, dependency governance, ESLint parity | 2026-02-28 |
| [PLN-20260222-debt-phase-10-monolith-footprint-reduction](plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md) | Debt Phase 10 - Monolith and release footprint reduction | `3b102fdc` | Config/doc drift cleanup, Ai.Models decomposition blueprint | 2026-02-28 |
| [PLN-20260222-debt-phase-05-m2-submodule-extraction](plans/PLN-20260222-debt-phase-05-m2-submodule-extraction.md) | Debt Phase 5 M2: Ai.Models submodule extraction | `7c7de1c5` | Extracted 15 provider modules from 11K line models.ex | 2026-02-28 |
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
| [PLN-20260302-tool-call-name-normalization](plans/PLN-20260302-tool-call-name-normalization.md) | Tool Call Name Normalization | `9248e1aa` | Unicode whitespace normalization, telemetry, 4 new tests | 2026-03-02 |

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
| [IDEA-20260227-ironclaw-approval-state-thread-resume](ideas/IDEA-20260227-ironclaw-approval-state-thread-resume.md) | Persist Tool Calls and Restore Approval State on Thread Switch | ironclaw | `proposed` | M | H | **Proceed** - Improve long-run approval continuity across client thread switches |
| [IDEA-20260227-openclaw-provider-model-alias-normalization](ideas/IDEA-20260227-openclaw-provider-model-alias-normalization.md) | Provider/Model Alias Normalization for Gemini Backends | openclaw | `proposed` | S | M | **Investigate** - Add shared alias normalization contract + compatibility tests |
| [IDEA-20260227-community-reverse-permission-hierarchy](ideas/IDEA-20260227-community-reverse-permission-hierarchy.md) | Reverse Permission Hierarchy with Explicit Command Allowlists | community | `proposed` | M | H | **Investigate** - Harden command-level trust boundaries beyond tool-level approvals |
| [IDEA-20260227-community-channel-capability-negotiation](ideas/IDEA-20260227-community-channel-capability-negotiation.md) | Channel Capability Negotiation (Attachments, Rich Blocks, Streaming) | community | `proposed` | M | H | **Proceed** - Unify rich-output adaptation across channels and future adapters |
| [IDEA-20260227-ironclaw-routine-multichannel-broadcast](ideas/IDEA-20260227-ironclaw-routine-multichannel-broadcast.md) | Routine Notifications Fanout to All Installed Channels | ironclaw | `proposed` | M | M | **Investigate** - Productize policy-driven multi-channel routine broadcast + delivery reporting |
| [IDEA-20260227-openclaw-device-auth-migration-diagnostics](ideas/IDEA-20260227-openclaw-device-auth-migration-diagnostics.md) | Device Auth Migration Diagnostics and Guided Recovery | openclaw | `proposed` | S | M | **Proceed** - Add unified auth diagnostics + remediation guidance for migration failures |
| [IDEA-20260227-community-per-channel-model-overrides](ideas/IDEA-20260227-community-per-channel-model-overrides.md) | Persistent Per-Channel Model Overrides | community | `proposed` | M | H | **Proceed** - Promote Telegram-only defaults into cross-channel route-level model policy |
| [IDEA-20260227-community-session-thread-decoupling](ideas/IDEA-20260227-community-session-thread-decoupling.md) | Decouple Session Persistence from Thread Binding | community | `proposed` | M | H | **Investigate** - Formalize/test non-thread durable-session contract across adapters |
| [IDEA-20260227-openclaw-tool-call-name-normalization](ideas/IDEA-20260227-openclaw-tool-call-name-normalization.md) | Normalize Whitespace-Padded Tool Call Names Before Dispatch | openclaw | `proposed` | S | M | **Proceed** - Low-cost dispatch hardening against provider formatting drift |
| [IDEA-20260227-openclaw-telegram-reply-media-context](ideas/IDEA-20260227-openclaw-telegram-reply-media-context.md) | Include Replied Media Metadata in Telegram Reply Context | openclaw | `proposed` | M | M | **Investigate** - Improve media-thread continuity for Telegram reply workflows |
| [IDEA-20260227-community-channel-lifecycle-ops](ideas/IDEA-20260227-community-channel-lifecycle-ops.md) | Programmatic Channel Lifecycle Operations (Create/Archive/Configure) | community | `proposed` | M | M | **Investigate** - Add capability-gated channel admin primitives beyond message send/receive |
| [IDEA-20260227-community-topology-adaptive-orchestration](ideas/IDEA-20260227-community-topology-adaptive-orchestration.md) | Topology-Adaptive Multi-Agent Orchestration Policies | industry | `proposed` | L | H | **Investigate** - Layer topology policy on existing task/agent orchestration primitives |
| [IDEA-20260227-oh-my-pi-lenient-schema-validation-fallback](ideas/IDEA-20260227-oh-my-pi-lenient-schema-validation-fallback.md) | Lenient Tool-Schema Validation Fallback for Provider Drift | oh-my-pi | `proposed` | M | M | **Investigate** - Add safe coercion/recovery path with explicit telemetry |
| [IDEA-20260227-pi-offline-startup-network-timeouts](ideas/IDEA-20260227-pi-offline-startup-network-timeouts.md) | Offline-First Startup Mode with Explicit Network Timeout Budget | pi | `proposed` | M | H | **Proceed** - Improve degraded-mode startup reliability for self-hosted operators |
| [IDEA-20260227-community-channel-onboarding-plugin-diagnostics](ideas/IDEA-20260227-community-channel-onboarding-plugin-diagnostics.md) | Channel Onboarding Plugin Diagnostics and Guided Recovery | community | `proposed` | M | H | **Proceed** - Reduce first-run setup failures with actionable remediation |
| [IDEA-20260227-industry-airgapped-agent-profile](ideas/IDEA-20260227-industry-airgapped-agent-profile.md) | Air-Gapped/Offline Deployment Profile for Self-Hosted Agents | industry | `proposed` | L | H | **Investigate** - Package offline profile and readiness diagnostics for enterprise/self-hosted use |
| [IDEA-20260302-ironclaw-fulljob-routine-mode](ideas/IDEA-20260302-ironclaw-fulljob-routine-mode.md) | FullJob Routine Mode with Scheduler Dispatch | ironclaw | `proposed` | M | H | **Investigate** - Scheduled job execution and channel-first prompts |
| [IDEA-20260302-pi-skill-auto-discovery](ideas/IDEA-20260302-pi-skill-auto-discovery.md) | Auto-Discover Skills in .agents Paths by Default | pi | `completed` | S | H | **Already implemented** - Lemon has skill auto-discovery parity |
| [IDEA-20260302-openclaw-mistral-provider-support](ideas/IDEA-20260302-openclaw-mistral-provider-support.md) | Full Mistral AI Provider Support | openclaw | `proposed` | M | M | **Investigate** - Add Mistral as a provider option |
| [IDEA-20260302-community-ai-agent-production-readiness](ideas/IDEA-20260302-community-ai-agent-production-readiness.md) | AI Agent Production Readiness - Context Windows & Operational Awareness | community | `proposed` | L | H | **Proceed** - Address production deployment blockers |
| [IDEA-20260306-ironclaw-auto-compact-context-retry](ideas/IDEA-20260306-ironclaw-auto-compact-context-retry.md) | Auto-Compact and Retry on ContextLengthExceeded | ironclaw | `proposed` | M | H | **Proceed** - Automatic recovery from context limit errors |
| [IDEA-20260306-oh-my-pi-strict-mode-openai](ideas/IDEA-20260306-oh-my-pi-strict-mode-openai.md) | Tool Schema Strict Mode for OpenAI Providers | oh-my-pi | `proposed` | S | M | **Investigate** - May improve OpenAI tool call reliability |
| [IDEA-20260306-openclaw-synology-chat-adapter](ideas/IDEA-20260306-openclaw-synology-chat-adapter.md) | Synology Chat Channel Adapter | openclaw | `proposed` | M | M | **Defer** - Niche self-hosted channel, lower priority |
| [IDEA-20260306-community-mcp-industry-standard](ideas/IDEA-20260306-community-mcp-industry-standard.md) | MCP Now Industry Standard - Full Ecosystem Support | community | `proposed` | M | H | **Proceed** - MCP is now table stakes for AI frameworks |
| [IDEA-20260306-community-production-readiness-gaps](ideas/IDEA-20260306-community-production-readiness-gaps.md) | Production Readiness Gaps - Context & Operational Awareness | community | `proposed` | L | H | **Proceed** - Major enterprise adoption differentiator |

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

### Research Addendum (2026-02-27)

- New upstream delta captured from IronClaw: UI persistence/restoration of tool-call + approval context across thread switches.
- New upstream hardening signal from OpenClaw: provider/model alias normalization for Gemini backends to avoid routing drift.
- New community demand signal: reverse permission hierarchy with explicit command/path allowlists for safer autonomous execution.
- New channel-UX demand signal (OpenClaw issue cluster): capability negotiation for attachments, rich blocks, and native streaming instead of plain-text-only fallbacks.

### Research Addendum (2026-02-27, late pass #2)

- New upstream feature signal from IronClaw: routines can broadcast notifications to all installed channels from one run (`e4f2fba762f0`).
- New upstream reliability signal from OpenClaw: stronger device-auth migration diagnostics and guided recovery paths (`cb9374a2a10a`).
- New community demand signal (OpenClaw issue #12246): durable per-channel model overrides, not just ephemeral session overrides.
- New community reliability signal (OpenClaw issue #23414): decouple durable session mode from channel thread binding requirements.

### Research Addendum (2026-02-27, late pass #3)

- New upstream hardening signal from OpenClaw: trim/normalize whitespace-padded tool call names before dispatch to reduce false "tool not found" errors (`6b317b1f174d`).
- New upstream Telegram-context signal from OpenClaw: include replied media metadata/files in reply context, not only text/caption (`aae90cb0364e`).
- New community automation demand signal: programmatic channel lifecycle operations (create/configure/archive channels) instead of message-only adapters (OpenClaw issue #7661).
- New industry orchestration signal: topology-adaptive multi-agent routing (parallel/sequential/hierarchical/hybrid) can outperform static orchestration choices (AdaptOrch + AWS evaluation framing).

### Research Addendum (2026-02-27, late pass #4)

- New upstream reliability signal from Oh-My-Pi: lenient schema/argument validation fallback for malformed provider payloads with circular-reference-safe handling (`d78321b5fda9`, `cde857a5b6be`).
- New upstream startup-resilience signal from Pi: explicit offline startup mode + bounded network timeout handling to avoid boot hangs in degraded environments (`757d36a41b96`).
- New community onboarding friction signal (OpenClaw issue #24781): users can complete channel credential entry yet still fail at generic "plugin not available" errors without guided remediation.
- New industry deployment signal: self-hosted agent adoption is increasingly tied to offline/air-gapped operational posture and deterministic bootstrap expectations (Cloudflare Moltworker narrative + adjacent ecosystem guidance).

### Research Addendum (2026-03-02)

New upstream deltas captured from inspiration research:
- **IronClaw v0.11.0**: FullJob routine mode with scheduler dispatch (commit 04d3b00) - scheduled job execution pattern
- **IronClaw v0.11.0**: Hot-activate WASM channels with channel-first prompts (commit ea57447) - dynamic channel activation
- **Pi v0.54.0**: Auto-discover skills in .agents paths by default (commit 39cbf47e) - **Lemon already has parity**
- **OpenClaw**: Full Mistral AI provider support (commit d92ba4f8a) - adds Mistral as first-class provider

New community/industry signals captured:
- **Production readiness gap**: Industry analysis shows AI agents lack context window awareness, operational awareness (OS/environment), and produce "agentic slop"
- **Multi-agent orchestration**: OpenAI Agents SDK and community converging on structured output-based orchestration patterns
- **OpenClaw vs Claude Code**: Community views OpenClaw as "Swiss Army knife" vs Claude Code "surgical scalpel" - different use cases

**New Idea Artifacts Created:**
1. `IDEA-20260302-ironclaw-fulljob-routine-mode.md` - Scheduled job execution patterns
2. `IDEA-20260302-pi-skill-auto-discovery.md` - Skill discovery parity confirmation
3. `IDEA-20260302-openclaw-mistral-provider-support.md` - Mistral provider evaluation
4. `IDEA-20260302-community-ai-agent-production-readiness.md` - Production readiness improvements

### Research Addendum (2026-03-07)

New upstream deltas captured from inspiration research:
- **IronClaw v0.13.1, v0.13.0**: Auto-compact and retry on ContextLengthExceeded (`6f21cfa`) - automatic context management
- **Oh-My-Pi v13.5.8, v13.5.7**: Tool schema strict mode for OpenAI providers (`6c52f8cf6`, `3a9ff9720`) - stricter JSON schema validation
- **Oh-My-Pi v13.0+**: Consolidated hashline edit operations, simplified developer role handling
- **OpenClaw**: Synology Chat adapter added - self-hosted NAS messaging support
- **Pi v0.55.4**: Incremental highlight for streaming write tool calls - UX improvement

New community/industry signals captured:
- **MCP is now official industry standard** - OpenAI adopted March 2025; 12+ frameworks now MCP-native
- **Production readiness gaps** - 45% of engineering leaders cite tool calling accuracy as top challenge
- **Context window blindness** - Agents don't track/manage context usage leading to failures
- **Air-gapped deployment demand** - Enterprise increasingly requires offline/air-gapped operational posture

**New Idea Artifacts Created:**
1. `IDEA-20260306-ironclaw-auto-compact-context-retry.md` - Automatic context compaction on limit errors
2. `IDEA-20260306-oh-my-pi-strict-mode-openai.md` - OpenAI strict mode for tool schemas
3. `IDEA-20260306-openclaw-synology-chat-adapter.md` - Synology Chat channel evaluation
4. `IDEA-20260306-community-mcp-industry-standard.md` - MCP ecosystem positioning
5. `IDEA-20260306-community-production-readiness-gaps.md` - Production readiness improvements

## Templates

- [PLAN_TEMPLATE.md](./templates/PLAN_TEMPLATE.md)
- [IDEA_TEMPLATE.md](./templates/IDEA_TEMPLATE.md) (create when first idea promoted to plan)