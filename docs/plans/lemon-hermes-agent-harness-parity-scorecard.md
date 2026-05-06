# Lemon ↔ Hermes-Class Agent Harness Parity Scorecard

Status: working scorecard; first parity slice merged, second slice adds executable harness contract evals for memory and skills, third slice wires relevant-skill preselection into the native session prompt path, fourth slice adds an audited agent-facing skill authoring tool, fifth slice adds redacted skill load/write telemetry, sixth slice adds usage counters plus pin/archive curation state, seventh slice audits missed relevant-skill loads, eighth slice exposes usage/curation reports to agents, ninth slice adds conservative curator lifecycle transitions plus review prompts, and tenth slice wires those prompts into an idle background submission path.

## Purpose

Track where Lemon already has Hermes-class agent harness behavior, where it is partial, and where the next PR-sized improvements should land. “Parity” here means comparable harness ergonomics and reliability, not copying Hermes internals.

## Summary

Lemon already has the hard architectural primitives: supervised BEAM sessions, channel routing, CLI engine adapters, task/subagent execution, skill registry, memory search, tool policies, approvals, and a control plane. The biggest near-term gaps are mostly harness-contract gaps: making the native Lemon agent reliably use those primitives every run, then adding tests/evals that prevent regressions.

The first code slice from this scorecard made `read_skill` available in the default native Lemon tool set and aligned `search_memory` with restricted tool policies. The second slice adds deterministic eval checks that verify memory search scope behavior, memory-topic scaffolding, and relevant-skill prompt progressive disclosure. The third slice feeds the current user prompt into native session prompt composition so Lemon can preselect concise relevant-skill hints before the model turn while keeping full skill bodies behind `read_skill`. The fourth slice adds `skill_manage` so agents can turn reusable workflows into audited project/global skills. The fifth slice emits and persists redacted `read_skill` and `skill_manage` telemetry with tool-call and session correlation fields. The sixth slice keeps Hermes-style usage/curation sidecars with counters, agent-authored provenance, and pin/archive workflows. The seventh slice records `:missed_skill_observed` when relevant skills were shown but not loaded. The eighth slice lets agents query usage/curation reports with stale/archive candidate flags before maintaining learned skills. The ninth slice adds `LemonSkills.Curator` and `mix lemon.skill curator` commands for stale/archive/reactivation transitions plus an agent review prompt for umbrella-style consolidation. The tenth slice adds an idle automation manager that submits that prompt through `LemonRouter` when review is due.

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
  - `apps/lemon_skills/lib/lemon_skills/tools/skill_manage.ex`
  - `apps/coding_agent/lib/coding_agent/system_prompt.ex`
  - `apps/lemon_skills/lib/lemon_skills/prompt_view.ex`
  - `docs/user-guide/skills.md`
- Strengths:
  - Registry supports global, project, and `.agents/skills` compatibility paths.
  - Relevance scoring exists.
  - Prompt renderer lists available skills and tells the agent to load relevant skills.
  - Native session prompt refresh passes the current user prompt into relevance scoring and renders concise `<relevant-skills>` hints per turn.
  - `read_skill` can read full content, summaries, sections, and linked files.
  - `skill_manage` can create, edit, patch, delete, and maintain audited project/global skills and supporting files.
  - `read_skill` and `skill_manage` emit redacted load/write telemetry with tool-call and session correlation fields, then project it into introspection events.
  - `LemonSkills.Usage` persists load/write counters, agent-authored creation provenance, and curation state.
  - `skill_manage` can pin/unpin/archive/restore skills; pinned skills are protected from archive/delete, and archived skills are disabled.
  - Session end audits record `:missed_skill_observed` when `<relevant-skills>` hints were not loaded with `read_skill`.
  - Install/update audit gates exist.
- Gaps:
  - Background curator submission now exists, but there is not yet a full behavioral eval proving the submitted agent actually performs useful umbrella consolidation over real skill clusters.
  - Missed-skill detection is observable, but there is not yet a behavioral eval that drives a real model trace through the contract.
- Priority: high.
- Acceptance tests:
  - Native Lemon default tools include `read_skill`.
  - Native Lemon default tools include `skill_manage`, and safe/subagent-restricted profiles deny it as a write-capable tool.
  - System prompt mentions `read_skill` only when the tool is available, or tests enforce both surfaces move together.
  - System prompt mentions `skill_manage` only when the tool is available, or tests enforce both surfaces move together.
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

### Slice 4: Agent skill authoring tool

1. Added `LemonSkills.Tools.SkillManage` for create/edit/patch/delete/write_file/remove_file operations on project and global skills.
2. Wrapped `skill_manage` into the default CodingAgent tool surface, builtin registry, minimal-core policy, and harness contract.
3. Treated `skill_manage` as dangerous in safe/subagent-restricted profiles and documented audited write behavior.

### Slice 5: Skill load/write telemetry

1. Added `LemonSkills.Telemetry` and emitted `[:lemon_skills, :skill, :load]` from `read_skill` for found and missing skill requests.
2. Emitted `[:lemon_skills, :skill, :write]` from `skill_manage` for accepted and rejected write attempts without recording skill bodies, patch strings, or supporting-file contents.
3. Threaded CodingAgent `session_key`, `session_id`, `agent_id`, and optional `run_id` tool options into those events when available.
4. Projected the telemetry into `:skill_load_observed` and `:skill_write_observed` introspection events.
5. Documented event fields and added regression tests for successful/missing loads, successful/rejected writes, and introspection projection.

### Slice 6: Skill usage and curation state

1. Added `LemonSkills.Usage` sidecars for global and project usage metadata.
2. Recorded load/write counters, last-use metadata, and agent-authored creation provenance from skill telemetry.
3. Extended `skill_manage` with `pin`, `unpin`, `archive`, and `restore`; archived skills use the existing disabled-skill config, and pinned skills must be unpinned before archive/delete.
4. Added regression tests for usage counters, provenance, curation state, and archived-skill restore behavior.

### Slice 7: Missed relevant-skill audit

1. Added a session-end audit that parses `<relevant-skills>` from the current prompt and compares those keys with observed `read_skill` tool results.
2. Persisted `:missed_skill_observed` introspection events for relevant skills that were not loaded.
3. Documented the event so operators can query missed skill usage.

### Slice 8: Skill usage and curation report

1. Added `LemonSkills.Usage.report/1` to summarize usage sidecar rows, counters, last activity, and stale/archive candidate flags for agent-authored skills.
2. Added `skill_manage` action `report` so agents can inspect curation candidates before pinning, archiving, restoring, or deleting skills.
3. Documented the report action in skill docs and user guidance.

### Slice 9: Conservative skill curator loop

1. Added `LemonSkills.Curator` for persisted curator state, interval/pause checks, automatic stale/archive/reactivation transitions, and an agent review prompt.
2. Added `mix lemon.skill curator status|run|pause|resume`; `run --prompt` prints the review prompt after applying conservative lifecycle transitions.
3. Documented curator behavior and invariants: only agent-authored skills are considered, pinned/non-agent-authored skills are skipped, archived skills are disabled, and no curator path deletes skills.

### Slice 10: Idle background curator submission

1. Added `LemonAutomation.SkillCurator` to apply enabled/idle/interval gates and submit `LemonSkills.Curator` review prompts through `LemonRouter`.
2. Added `LemonAutomation.SkillCuratorManager` to check router idleness periodically and launch the curator pass in the automation task supervisor.
3. Updated automation dependencies and docs so `lemon_automation` intentionally owns the background scheduler while `lemon_skills` owns curation state and prompt rendering.

## Follow-up backlog

1. Thread native Lemon run identifiers into tool options so persisted skill introspection can be queried by run as well as session.
2. Add a full behavioral eval for the background curator pass: seeded narrow skills → submitted curator prompt → real `read_skill`/`skill_manage` calls → broader umbrella and archived siblings.
3. Clarify memory/session-search/skills/todos in docs and prompt text.
4. Add cron parity scorecard and scheduled job prompt validation.
5. Add behavioral evals that observe actual agent traces: relevant skill → `read_skill`, prior-work prompt → `search_memory`, reusable workflow → `skill_manage`, async task receipt → `join` before final answer.
