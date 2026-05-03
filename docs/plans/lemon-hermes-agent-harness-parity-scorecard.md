# Lemon ↔ Hermes-Class Agent Harness Parity Scorecard

Status: working scorecard; first parity slice merged, second slice adds executable harness contract evals for memory and skills, and third slice wires relevant-skill preselection into the native session prompt path.

## Purpose

Track where Lemon already has Hermes-class agent harness behavior, where it is partial, and where the next PR-sized improvements should land. “Parity” here means comparable harness ergonomics and reliability, not copying Hermes internals.

## Summary

Lemon already has the hard architectural primitives: supervised BEAM sessions, channel routing, CLI engine adapters, task/subagent execution, skill registry, memory search, tool policies, approvals, and a control plane. The biggest near-term gaps are mostly harness-contract gaps: making the native Lemon agent reliably use those primitives every run, then adding tests/evals that prevent regressions.

The first code slice from this scorecard made `read_skill` available in the default native Lemon tool set and aligned `search_memory` with restricted tool policies. The second slice adds deterministic eval checks that verify memory search scope behavior, memory-topic scaffolding, and relevant-skill prompt progressive disclosure. The third slice feeds the current user prompt into native session prompt composition so Lemon can preselect concise relevant-skill hints before the model turn while keeping full skill bodies behind `read_skill`.

## Capability scorecard

### Tool ergonomics and enforcement

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools.ex`
  - `apps/coding_agent/lib/coding_agent/tool_registry.ex`
  - `apps/coding_agent/lib/coding_agent/tool_policy.ex`
  - `apps/coding_agent/lib/coding_agent/context_guardrails.ex`
  - `apps/coding_agent/lib/coding_agent/security/untrusted_tool_boundary.ex`
- Strengths:
  - File, search, edit, shell, web, task, todo, memory, auth, and extension status tools exist.
  - Dynamic registry has builtin/WASM/extension precedence and conflict reporting.
  - Tool policies model read-only, safe-mode, subagent-restricted, no-external, and minimal-core profiles.
  - Context guardrails spill/truncate oversized tool outputs.
- Gaps:
  - Some prompt-level tool-use rules are not yet backed by evals.
  - Tool naming is Lemon-native; portability aliases may be useful later.
  - Dedicated tools should be preferred over shell equivalents more explicitly.
- Priority: high.
- Acceptance tests:
  - Default tool set contains every tool referenced by the system prompt.
  - Read-only and minimal-core policies allow context-loading tools such as `read_skill` and `search_memory`.
  - Eval harness includes deterministic contracts for memory scopes, memory-topic scaffolding, and relevant-skill prompt progressive disclosure.
  - Eval catches an agent finalizing after promising an action without calling a tool.

### Skills lifecycle and procedural memory

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/lemon_skills/lib/lemon_skills/**`
  - `apps/lemon_skills/lib/lemon_skills/tools/read_skill.ex`
  - `apps/coding_agent/lib/coding_agent/system_prompt.ex`
  - `apps/lemon_skills/lib/lemon_skills/prompt_view.ex`
  - `docs/user-guide/skills.md`
- Strengths:
  - Registry supports global, project, and `.agents/skills` compatibility paths.
  - Relevance scoring exists.
  - Prompt renderer lists available skills and tells the agent to load relevant skills.
  - Native session prompt refresh passes the current user prompt into relevance scoring and renders concise `<relevant-skills>` hints per turn.
  - `read_skill` can read full content, summaries, sections, and linked files.
  - Install/update audit gates exist.
- Gaps:
  - Missed-skill detection is not yet audited as a run outcome.
  - Skill authoring/patching from the agent loop is not as mature as read-only consumption.
  - Per-turn relevant-skill hints are guided, but not yet enforced through observed tool-call telemetry.
- Priority: high.
- Acceptance tests:
  - Native Lemon default tools include `read_skill`.
  - System prompt mentions `read_skill` only when the tool is available, or tests enforce both surfaces move together.
  - Eval harness verifies a skill-relevant fixture prompt surfaces a `<relevant-skills>` block, includes a `read_skill` reminder, and does not inline full skill bodies.
  - Future behavioral eval: a skill-relevant fixture prompt causes the agent/eval harness to call `read_skill` before answering.

### Memory and session recall

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools/search_memory.ex`
  - `apps/coding_agent/lib/coding_agent/tools/memory_topic.ex`
  - `apps/lemon_core/lib/**memory**`
  - `docs/user-guide/memory.md`
- Strengths:
  - Completed runs become structured `MemoryDocument`s.
  - Full-text search supports current/project/home/session/agent/all scopes.
  - Ingest-time secret scanning/redaction needs to be verified and hardened before claiming memory storage safety.
  - Skill synthesis can mine successful runs.
- Gaps:
  - System prompt still mixes workspace memory files, memory topics, and session search in a way that may be confusing.
  - Durable user facts vs procedural skills vs run recall should be documented more sharply.
  - Need evals that force memory search when users reference prior work.
- Priority: high.
- Acceptance tests:
  - `search_memory` defaults to current scope and searches both project and assistant-home memory without broadening missing contexts.
  - `memory_topic` scaffolds `memory/topics/<slug>.md` from the workspace template and replaces the slug placeholder.
  - “Last time / remember when” prompts call `search_memory` before answering.
  - Memory-topic creation does not replace procedural skill authoring.

### Delegation and orchestration

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools/task.ex`
  - `apps/coding_agent/lib/coding_agent/tools/agent.ex`
  - `apps/coding_agent/lib/coding_agent/coordinator.ex`
  - `apps/coding_agent/lib/coding_agent/run_graph*.ex`
  - `docs/subagent-parent-questions.md`
- Strengths:
  - Async task records, run graph, join/poll/get, parent questions, and lane queues exist.
  - External engines can be delegated to via CLI adapters.
- Gaps:
  - Need clearer leaf/orchestrator semantics and toolset-restriction contracts.
  - Need stronger side-effect verification requirements for child results.
  - Need an eval for “parallel research then aggregate before final response.”
- Priority: high after skill/memory slice.

### Cron and durable background jobs

- Current Lemon status: partial.
- Current modules/docs:
  - `apps/lemon_automation/**`
  - `apps/lemon_gateway/lib/lemon_gateway/tools/cron.ex`
  - `docs/long-running-agent-harnesses.md`
- Strengths:
  - Cron manager, heartbeat manager, and scheduled submissions exist.
  - Gateway exposes cron tooling into Lemon engine runs.
- Gaps:
  - Hermes-style self-contained scheduled prompts, origin delivery, run history injection, and job toolset restriction need evaluation.
  - Need guardrails against recursively scheduled jobs.
- Priority: medium-high.

### Messaging and native delivery

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/lemon_channels/**`
  - `apps/lemon_gateway/tools/*telegram*`
  - `apps/lemon_gateway/tools/*discord*`
- Strengths:
  - Telegram, Discord, X, XMTP, and legacy gateway ingress exist.
  - Channel outbox separates rendering/delivery from execution.
- Gaps:
  - Need documented media attachment contract analogous to Hermes `MEDIA:/path` delivery.
  - Need per-channel markdown/rendering docs and evals.
- Priority: medium.

### Browser/web/media tools

- Current Lemon status: partial.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools/webfetch.ex`
  - `apps/coding_agent/lib/coding_agent/tools/websearch.ex`
  - `clients/lemon-browser-node/`
- Strengths:
  - Web search/fetch tools exist.
  - Browser node client exists for CDP/Playwright-related work.
- Gaps:
  - Browser interaction is not yet as first-class in the default native harness as Hermes browser tools.
  - Media generation/TTS/image analysis are not clearly first-class native Lemon tools.
- Priority: medium.

### Safety, approvals, and untrusted content

- Current Lemon status: strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tool_policy.ex`
  - `apps/coding_agent/lib/coding_agent/tool_executor.ex`
  - `apps/coding_agent/lib/coding_agent/security/untrusted_tool_boundary.ex`
  - `SECURITY.md`
- Strengths:
  - Approval gate system exists.
  - Tool policies are explicit.
  - Skill install/update audit exists.
  - Untrusted tool-output boundary exists.
- Gaps:
  - Need more adversarial prompt-injection evals.
  - Need safety docs tying approvals, tool policies, memory redaction, and skill audits together.
- Priority: medium-high.

### Observability and dogfood loop

- Current Lemon status: partial.
- Current modules/docs:
  - `apps/lemon_control_plane/**`
  - `clients/lemon-web/web/README.md`
  - `apps/coding_agent/lib/coding_agent/evals/harness.ex`
- Strengths:
  - Control plane exposes many RPCs.
  - Web UI has sessions/runs/tasks/events visibility.
  - Eval harness exists.
- Gaps:
  - Need first-class traces of skill list/render/load decisions.
  - Need dashboard panels for skill loads, memory searches, approvals, subagent tree, and cron job runs.
- Priority: medium.

## Implementation slices so far

### Slice 1: Native `read_skill` / `search_memory` availability

1. Exposed `read_skill` from `CodingAgent.Tools` and `CodingAgent.ToolRegistry`.
2. Allowed `read_skill` and `search_memory` in relevant read/minimal policies.
3. Updated docs and tests so the prompt/tool contract stays synchronized.

### Slice 2: Memory and skill harness contract evals

1. Added eval checks for default `search_memory` current-scope resolution.
2. Added eval checks for `memory_topic` scaffold behavior.
3. Added eval checks for relevant-skill prompt progressive disclosure and `read_skill` guidance.
4. Added tests that require those checks to appear in `CodingAgent.Evals.Harness.run/1` and `mix lemon.eval` JSON output.

### Slice 3: Native relevant-skill preselection

1. Extended `CodingAgent.SystemPrompt.build/2` with `:skill_context` and `:max_relevant_skills` options.
2. Updated session prompt refresh to pass the current user prompt/steer/follow-up text into skill relevance scoring.
3. Added contract tests for system-prompt, prompt-builder, and session prompt-composer paths that require concise `<relevant-skills>` hints and keep full skill bodies behind `read_skill`.

## Follow-up backlog

1. Add skill-load telemetry fields to run events or session metadata.
2. Add missed-skill audit warnings based on `LemonSkills.find_relevant/2` and observed tool calls.
3. Clarify memory/session-search/skills/todos in docs and prompt text.
4. Add cron parity scorecard and scheduled job prompt validation.
5. Add behavioral evals that observe actual agent traces: relevant skill → `read_skill`, prior-work prompt → `search_memory`, async task receipt → `join` before final answer.
