# Lemon ↔ Hermes-Class Agent Harness Parity Scorecard

Status: working scorecard; first through forty-first parity slices merged core learning, memory, skill, delegation, tool-lifecycle, transcript, scheduling, and live-model eval contracts; forty-second slice sanitizes OpenAI-compatible tool-call arguments before request encoding; forty-third slice preserves recoverable truncated streamed tool-call arguments; forty-fourth slice honors provider retry delays; forty-fifth slice normalizes context-length provider errors; forty-sixth slice normalizes Req-style rate-limit headers; forty-seventh slice normalizes OpenAI Responses HTTP errors; forty-eighth slice adds a live-model delegation side-effect verification eval; forty-ninth slice adds leaf/orchestrator toolset contracts; fiftieth slice sanitizes OpenAI Responses tool-call arguments before request encoding; fifty-first slice sanitizes OpenAI Responses tool-call identity fields before request encoding; fifty-second slice sanitizes OpenAI Responses tool schema fields before request encoding; fifty-third slice makes internal task children leaf workers by default; fifty-fourth slice rejects secret-looking memory documents before ingest; fifty-fifth slice adds live-model durable-topic memory coverage; fifty-sixth slice documents the composed agent safety contract; fifty-seventh slice adds a deterministic untrusted prompt-injection contract; fifty-eighth slice preserves structured tool failure metadata in LemonRunner action events; fifty-ninth slice exposes tool failure metadata in router status intents; sixtieth slice preserves nested engine action metadata at the control-plane event boundary; sixty-first slice treats Anthropic overloaded HTTP 529 responses as transient retryable provider errors; sixty-second slice records skill prompt-render decisions in telemetry and introspection; sixty-third slice adds a deterministic workspace memory-file inspection contract; sixty-fourth slice normalizes millisecond retry-after provider headers; sixty-fifth slice parses provider rate-limit reset duration headers; sixty-sixth slice adds live-model workspace memory-file inspection coverage; sixty-seventh slice adds live-model relevant-skill audit coverage.

## Purpose

Track where Lemon already has Hermes-class agent harness behavior, where it is partial, and where the next PR-sized improvements should land. “Parity” here means comparable harness ergonomics and reliability, not copying Hermes internals.

## Summary

Lemon already has the hard architectural primitives: supervised BEAM sessions, channel routing, CLI engine adapters, task/subagent execution, skill registry, memory search, tool policies, approvals, and a control plane. The biggest near-term gaps are mostly harness-contract gaps: making the native Lemon agent reliably use those primitives every run, then adding tests/evals that prevent regressions.

The first code slice from this scorecard made `read_skill` available in the default native Lemon tool set and aligned `search_memory` with restricted tool policies. The second slice adds deterministic eval checks that verify memory search scope behavior, memory-topic scaffolding, and relevant-skill prompt progressive disclosure. The third slice feeds the current user prompt into native session prompt composition so Lemon can preselect concise relevant-skill hints before the model turn while keeping full skill bodies behind `read_skill`. The fourth slice adds `skill_manage` so agents can turn reusable workflows into audited project/global skills. The fifth slice emits and persists redacted `read_skill` and `skill_manage` telemetry with tool-call and session correlation fields. The sixth slice keeps Hermes-style usage/curation sidecars with counters, agent-authored creation provenance, and pin/archive workflows. The seventh slice records `:missed_skill_observed` when relevant skills were shown but not loaded. The eighth slice lets agents query usage/curation reports with stale/archive candidate flags before maintaining learned skills. The ninth slice adds `LemonSkills.Curator` and `mix lemon.skill curator` commands for stale/archive/reactivation transitions plus an agent review prompt for umbrella-style consolidation. The tenth slice adds an idle automation manager that submits that prompt through `LemonRouter` when review is due. The eleventh slice adds an eval that seeds narrow agent-authored skills, renders the curator prompt, uses real `read_skill` and `skill_manage` tool calls to create an umbrella skill, and archives absorbed siblings. The twelfth slice closes the remaining tool-call lifecycle hardening gaps by turning task-supervisor startup failures into normal error `tool_result` messages and testing that full turns feed exactly one result per tool call into the next model call. The thirteenth slice adds explicit prompt triggers for when agents should write skills, memory topics, or search prior run memory. The fourteenth slice validates and safely coerces tool arguments against tool JSON schemas before starting side-effecting tool tasks. The fifteenth slice adds a deterministic learning trace eval that exercises prior-run search, durable topic creation, reusable skill creation, and usage reporting with the real tools. The sixteenth slice emits `:missed_learning_observed` when a learning-triggered session ends without the corresponding learning tools. The seventeenth slice adds an immutable `ToolSchemaSnapshot` so the provider schema and executable tools share a run-local snapshot id. The eighteenth slice adds a scripted contract eval that catches completed file/code action claims when the transcript has no tool call or tool result. The nineteenth slice stores run/session/agent provenance on native sessions so built-in learning tools and session events can be queried by run id. The twentieth slice sharpens agent-facing guidance so run recall, durable memory topics, procedural skills, and transient todos no longer compete as ambiguous memory surfaces. The twenty-first slice adds an AgentCore loop eval that consumes scripted model tool calls and asserts the returned messages include real `read_skill` and `skill_manage` tool results. The twenty-second slice adds the matching AgentCore loop eval for prior-work prompts that call `search_memory` and search current project plus home scopes before finalizing. The twenty-third slice adds an AgentCore loop eval that queues a real async task, dynamically joins the returned task id, and verifies the final answer includes the joined child output. The twenty-fourth slice extends that contract to two async children joined together before aggregation. The twenty-fifth slice adds `max_tool_turns`, a typed `:loop_budget_exhausted` event, and a terminal assistant fallback when a model keeps requesting tools. The twenty-sixth slice reconciles empty terminal provider messages with accumulated streamed content. The twenty-seventh slice turns scheduled cron runs into self-contained prompts that name forked-session isolation, prior-run memory semantics, origin delivery, and recursive scheduling guardrails. The twenty-eighth slice ports another Hermes streaming edge case by merging chunked OpenAI-compatible tool-call function-name deltas while ignoring repeated suffixes. The twenty-ninth slice adds an AgentCore streaming regression for tool-only streams whose final provider message arrives with empty content. The thirtieth slice adds typed `:tool_task_crashed` details when a tool task process exits before producing a result. The thirty-first slice adds typed details for tool-returned errors, raised exceptions, caught exits/throws, and unexpected return values. The thirty-second slice adds opt-in per-tool task timeouts that terminate supervised tool tasks and emit typed `:tool_task_timeout` results. The thirty-third slice makes router-style `blocked_tools` effective in native sessions and blocks cron tooling for scheduled runs. The thirty-fourth slice adds `mix lemon.eval --live-model`, an explicit provider-backed lane that proves an independent model calls `search_memory` for prior-work recall before answering. The thirty-fifth slice makes parallel tool execution return results and transcript messages in the original assistant tool-call order even when supervised tasks finish out of order. The thirty-sixth slice extends the live-model lane to prove a provider-backed model uses `read_skill` and `skill_manage` to capture a reusable workflow as an agent-authored skill. The thirty-seventh slice adds a reusable AgentCore transcript validator and rejects invalid assistant tool-call histories before provider conversion. The thirty-eighth slice extends the live-model lane to verify curator-style umbrella consolidation over real skill candidates. The thirty-ninth slice extends the live-model lane to verify scheduled-run memory recall while the `cron` tool is filtered by `blocked_tools`. The fortieth slice extends the live-model lane to verify a provider-backed model starts two async child tasks, joins both ids, and answers from the joined outputs. The forty-first slice adds a deterministic delegation artifact eval that requires the parent loop to join the child, read the produced artifact, and only then finalize. The forty-second slice hardens OpenAI-compatible transcript conversion so persisted assistant tool-call arguments with invalid UTF-8 are sanitized before JSON request encoding. The forty-third slice keeps recoverable partial OpenAI-compatible tool-call arguments at stream finalization instead of replacing them with an empty map. The forty-fourth slice honors retry delay hints from OpenAI-compatible providers before falling back to jittered retry backoff. The forty-fifth slice classifies context-window HTTP failures as explicit context-length errors and routes OpenAI-compatible terminal HTTP errors through the shared provider error normalizer. The forty-sixth slice preserves rate-limit metadata when providers hand `Ai.Error` Req-style header maps whose values are lists. The forty-seventh slice routes OpenAI Responses API terminal HTTP errors through the shared normalizer too. The forty-eighth slice extends the live-model lane to require delegation side-effect verification by reading a child-created artifact before finalizing. The forty-ninth slice adds explicit `:orchestrator` and `:leaf_worker` tool policies plus deterministic and live-model contracts for blocking recursive delegation from leaf workers. The fiftieth slice applies the same invalid-UTF-8 argument sanitation to OpenAI Responses function calls before request encoding. The fifty-first slice sanitizes OpenAI Responses function-call `call_id`, `id`, and `name` before request encoding too. The fifty-second slice sanitizes OpenAI Responses tool names, descriptions, and parameter schemas before request encoding. The fifty-third slice makes internal task-spawned child sessions leaf workers by default unless an explicit policy overrides it. The fifty-fourth slice adds shared durable-memory secret screening and rejects unsafe documents before store writes or skill synthesis. The fifty-fifth slice extends the live-model lane to prove an independent model chooses `memory_topic` for durable project context while avoiding prior-run search and procedural skill writes. The fifty-sixth slice adds `docs/security/agent-safety-contract.md` as the composed safety reference for tool policies, approvals, memory screening, skill audits, and redacted telemetry. The fifty-seventh slice adds a deterministic eval that wraps adversarial untrusted tool output, preserves the warning boundary, and sanitizes nested external-content end markers. The fifty-eighth slice starts on the Hermes lifecycle follow-up by carrying AgentCore structured tool failure metadata through LemonRunner action completion events. The fifty-ninth slice carries that failure metadata into router status intent bodies for downstream UI and observability consumers.

## Capability scorecard

Latest slice: the opt-in live-model lane now verifies relevant-skill loading with `read_skill` and confirms the missed-skill audit stays clean.

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
  - Tool-task startup failures emit exactly one error `tool_result` instead of crashing the loop.
  - Tool-task process crashes emit exactly one error `tool_result` with typed `:tool_task_crashed` details.
  - Tool-returned errors, exceptions, caught exits/throws, and unexpected return values emit typed error details.
  - Configured tool task timeouts terminate the running task and emit exactly one typed `:tool_task_timeout` result.
  - Full turns append exactly one `tool_result` per tool call before the next model turn.
  - Invalid tool-call transcripts are rejected before provider calls.
  - Parallel tool batches append `tool_result` messages in assistant tool-call order, not completion order.
  - Invalid schema-shaped arguments emit a structured error `tool_result` before any tool task starts.
  - A per-run tool schema snapshot event records the frozen executable tool names.
  - Eval catches an agent finalizing after promising an action without calling a tool.
  - Repeated tool-use turns stop at `max_tool_turns` with `:loop_budget_exhausted` and a user-visible fallback.
  - Streaming preserves accumulated assistant content when the final provider message has an empty content list.
  - OpenAI-compatible streaming merges chunked function-name deltas without duplicating repeated suffix chunks.
  - Streaming preserves accumulated tool calls when the final provider message has an empty content list.
  - OpenAI-compatible request conversion sanitizes invalid UTF-8 in assistant tool-call arguments before encoding provider JSON.
  - OpenAI-compatible streaming preserves recoverable truncated tool-call arguments at terminal finalization.

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
  - Session end audits record `:missed_learning_observed` when prompts ask for prior memory, durable context, or reusable workflows and the run does not call the corresponding learning tools.
  - Prompt composition now tells agents when to capture reusable workflows as skills and when to write durable context as memory topics.
  - Install/update audit gates exist.
- Gaps:
  - The live-model lane now covers basic reusable skill capture through `read_skill` and `skill_manage`.
  - Background curator submission now has deterministic scripted coverage and opt-in live-model coverage for useful umbrella consolidation over real skill clusters.
  - No active high-priority harness gap remains for relevant-skill loading, missed-skill auditing, or reusable skill capture.
- Priority: high.
- Acceptance tests:
  - Native Lemon default tools include `read_skill`.
  - Native Lemon default tools include `skill_manage`, and safe/subagent-restricted profiles deny it as a write-capable tool.
  - System prompt mentions `read_skill` only when the tool is available, or tests enforce both surfaces move together.
  - System prompt mentions `skill_manage` only when the tool is available, or tests enforce both surfaces move together.
  - Prompt tests require learning-trigger text for reusable workflows, recurring command sequences, project conventions, memory topics, and end-of-run capture.
  - Eval harness runs a scripted learning trace over `search_memory`, `memory_topic`, `skill_manage create`, and `skill_manage report`.
  - Eval harness verifies a skill-relevant fixture prompt surfaces a `<relevant-skills>` block, includes a `read_skill` reminder, and does not inline full skill bodies.
  - Eval harness drives `AgentCore.Loop` through real `read_skill` and `skill_manage` tool results before finalizing.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through `read_skill` and `skill_manage create` before answering a reusable-workflow prompt.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through relevant-skill `read_skill` usage and verifies no missed-skill audit event is recorded.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through curator-style skill reads, umbrella creation, and sibling archives.

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
  - Ingest-time secret screening is shared by memory ingest and skill synthesis, with regressions for documented secret patterns.
  - Skill synthesis can mine successful runs.
- Gaps:
  - No active high-priority harness gap remains for choosing among prior-run search, durable-topic capture, and workspace memory-file inspection.
- Priority: high.
- Acceptance tests:
  - `search_memory` defaults to current scope and searches both project and assistant-home memory without broadening missing contexts.
  - `memory_topic` scaffolds `memory/topics/<slug>.md` from the workspace template and replaces the slug placeholder.
  - Eval harness drives `AgentCore.Loop` through a `search_memory` tool result for a “last time” prompt before finalizing.
  - Eval harness drives `AgentCore.Loop` through real `grep` and `read` results for a workspace `memory/topics/*.md` note before finalizing.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model to call `search_memory` before answering a prior-work prompt.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model to call `memory_topic` for durable project context while avoiding `search_memory` and `skill_manage`.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model to inspect workspace memory files with `grep` and `read` while avoiding `search_memory` and `memory_topic`.
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
  - Eval harness drives a real async task through `join` before the final answer.
  - Eval harness joins and aggregates two async child task results before the final answer.
  - Eval harness verifies a child-produced artifact by reading the artifact after join and before final answer.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through two async child tasks and one wait-all join before finalizing.
  - Tool policies now define explicit `:orchestrator` and `:leaf_worker` profiles, with leaf workers blocked from recursive `task`/`agent` delegation.
  - Internal task-spawned child sessions default to the `:leaf_worker` policy while preserving explicit task `tool_policy` overrides.
  - External engines can be delegated to via CLI adapters.
- Gaps:
  - Live-model delegation now has parallel child/join, side-effect verification, and leaf toolset coverage.
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
  - Scheduled prompts include forked-session isolation, prior-run memory semantics, origin delivery, and a recursive scheduling guardrail.
  - Scheduled submissions attach `blocked_tools: ["cron"]`, and CodingAgent policy filtering honors router-style `blocked_tools`.
- Gaps:
  - Job toolset restriction now has focused regression coverage and opt-in live-model coverage.
  - Recursive scheduling through direct cron tooling is structurally blocked, but non-tool API entrypoints remain operator-controlled rather than model-facing.
- Priority: medium-high.
- Acceptance tests:
  - `RunSubmitter.build_params/2` embeds the cron prompt contract: isolated forked session, prior-run memory, origin delivery, and recursive scheduling guardrail.
  - `RunSubmitter.build_params/2` attaches a cron tool policy that blocks a `cron` tool.
  - Opt-in `mix lemon.eval --live-model` filters a `cron` tool out with `blocked_tools` and drives the model through prior scheduled-run memory before finalizing.

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
  - `docs/security/agent-safety-contract.md`
- Strengths:
  - Approval gate system exists.
  - Tool policies are explicit.
  - Skill install/update audit exists.
  - Untrusted tool-output boundary exists.
  - The agent safety contract now ties tool exposure, approval scopes, durable-memory screening, skill audit enforcement, and redacted telemetry together.
  - The deterministic eval lane now checks that adversarial untrusted tool output stays inside the external-content boundary.
- Gaps:
  - Need live-model prompt-injection evals against external content.
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
  - Skill prompt render/load/write decisions are available through redacted telemetry and introspection events.
- Gaps:
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

### Slice 11: Scripted curator behavior eval

1. Added `skill_curator_behavior_contract` to `CodingAgent.Evals.Harness.run/1`.
2. The eval seeds two narrow project skills through real `skill_manage create` calls, runs `LemonSkills.Curator`, verifies the review prompt requires `read_skill` and `skill_manage`, then calls real `read_skill` and `skill_manage` operations to create an umbrella skill and archive the absorbed siblings.
3. Added harness contract tests so `mix lemon.eval` keeps this procedural-memory behavior in the eval suite.

### Slice 12: Tool call lifecycle hardening

1. Made `AgentCore.Loop.ToolCalls` handle `Task.Supervisor.start_child/2` failures and exits as synthetic error `tool_result` messages.
2. Preserved `tool_execution_start`, `tool_execution_end`, and `tool_result:emit` events for failed-start tool calls so UI and telemetry consumers still see a complete lifecycle.
3. Added a regression test that uses a missing task supervisor and verifies the tool body is not run, the loop does not crash, and exactly one error `tool_result` is appended.
4. Added a full-turn regression test that verifies a model response with N tool calls appends exactly N `tool_result` messages, passes those results into the next model turn, and only then emits the final answer.

### Slice 13: Learning trigger prompt guidance

1. Added a `<learning-workflow>` prompt section covering when to use `skill_manage`, `memory_topic`, and `search_memory`.
2. Wired that guidance into main Lemon system prompts and PromptBuilder prompts when relevant skill context is present and skill/memory tools are available.
3. Added regression tests for reusable workflow, recurring command sequence, project convention, durable-memory, prior-work search, and end-of-run capture triggers.

### Slice 14: Tool argument schema validation

1. Added pre-dispatch validation/coercion for tool call arguments against each tool's JSON-style parameter schema.
2. Coerced safe provider/model drift before task startup: string booleans, string integers/numbers, JSON-encoded objects/arrays, and scalar values for arrays.
3. Rejected missing or unparseable arguments as structured `:invalid_tool_arguments` tool results without starting the tool task.
4. Added structured `:unknown_tool` details for unmatched tool calls before task startup.

### Slice 15: Scripted learning trace eval

1. Added `learning_tool_trace_contract` to `CodingAgent.Evals.Harness.run/1`.
2. The eval checks learning prompt triggers, calls real `search_memory` for prior work, creates a durable topic with `memory_topic`, creates a reusable project skill with `skill_manage`, and verifies the skill appears in `skill_manage report`.
3. Added a harness contract test so `mix lemon.eval` keeps the end-to-end learning artifact path in the eval suite.

### Slice 16: Missed learning audit

1. Extended session-end auditing to detect learning-triggered transcripts under `<learning-workflow>` prompts.
2. Records `:missed_learning_observed` with trigger classes, missing learning tools, and any used learning tools when prior-memory, durable-memory, or reusable-skill triggers were not followed by the expected tool call.
3. Added regression tests for both missed-learning recording and suppression when `search_memory`, `memory_topic`, and `skill_manage` were used.

### Slice 17: Per-run tool schema snapshot

1. Added `AgentCore.Types.ToolSchemaSnapshot` with snapshot id, fingerprint, frozen tool structs, and tool names.
2. AgentCore now snapshots tools at loop start, emits `{:tool_schema_snapshot, snapshot}`, and records telemetry with snapshot id/fingerprint/tool names.
3. The LLM provider context and tool execution path both use the frozen snapshot tools, including when a configured snapshot is supplied explicitly.
4. Added regression tests for snapshot event ordering and provider/executor parity.

### Slice 18: Tool-use claim contract eval

1. Added `tool_use_claim_contract` to the deterministic eval harness.
2. The eval detects a final assistant message that claims a completed file/code side effect when no tool call or tool result appears in the transcript.
3. The same eval allows the completed-action claim when a matching transcript includes tool activity, preventing the contract from banning legitimate summaries.

### Slice 19: Native run provenance for learning tools

1. `CodingAgent.CliRunners.LemonRunner` now passes its `run_id` into `CodingAgent.Session`.
2. Native sessions keep `run_id`, logical `session_key`, and `agent_id` in state and pass them through tool construction, including extension reloads.
3. Session lifecycle, tool dispatch, missed-skill, and missed-learning introspection events include the same provenance fields when available.
4. Added regression tests proving LemonRunner sets native session provenance and `read_skill` events from native sessions are queryable by run id.

### Slice 20: Learning surface guidance

1. Reworded `<learning-workflow>` to choose among `read_skill`, `search_memory`, `memory_topic`, `skill_manage`, and `todo`.
2. Clarified the main system prompt memory workflow: run history search, workspace note inspection, durable topic creation, reusable skill capture, and active-run todos now have separate instructions.
3. Updated user docs for memory and skills with the same boundaries.
4. Added prompt regression assertions for `read_skill` and `todo` guidance.

### Slice 21: Agent-loop learning trace eval

1. Added `agent_loop_learning_trace_contract` to the eval harness.
2. The eval seeds a project skill, runs the real `AgentCore.Loop` with scripted model tool calls, and asserts `read_skill` returns the seeded skill.
3. The same loop creates a reusable project skill through `skill_manage` and verifies the agent-authored skill is active before the final response.

### Slice 22: Agent-loop memory trace eval

1. Added `agent_loop_memory_trace_contract` to the eval harness.
2. The eval runs the real `AgentCore.Loop` with a scripted `search_memory` tool call for a “last time” prompt.
3. It verifies the loop returns a real `search_memory` tool result, coerces the string limit argument, and searches both project and assistant-home scopes before the final answer.

### Slice 23: Agent-loop async join trace eval

1. Added `agent_loop_async_join_trace_contract` to the eval harness.
2. The eval uses the real `task` tool with an async `run_override`, then dynamically reads the queued `task_id` from the previous tool result and calls `task` with `action=join`.
3. It verifies the loop has both queued and joined task results, and that the final answer appears after the join result and includes the child output.

### Slice 24: Agent-loop parallel join trace eval

1. Added `agent_loop_parallel_join_trace_contract` to the eval harness.
2. The eval runs two real async `task` calls, dynamically joins both queued task ids, and verifies the join result includes both child outputs.
3. It verifies the final answer aggregates both joined child outputs.

### Slice 25: Bounded tool-loop terminal fallback

1. Added `max_tool_turns` to `AgentCore.Agent` and `AgentCore.Loop` config, defaulting to 25 with `:infinity` for explicit unbounded runs.
2. AgentCore now emits `{:loop_budget_exhausted, details}` after the configured number of tool-use turns and completes with a terminal assistant fallback instead of calling the model again.
3. Added a loop regression test proving the model is called once at `max_tool_turns: 1`, the tool call receives its result, and the final event is `:agent_end`.

### Slice 26: Empty final streaming response reconciliation

1. Added an AgentCore streaming regression test for a provider stream where deltas carry visible content but the terminal SDK message has `content: []`.
2. AgentCore now preserves the accumulated streamed assistant content while retaining terminal metadata from the final provider message.

### Slice 27: Scheduled cron prompt contract

1. Hardened `LemonAutomation.CronMemory.build_prompt/3` so scheduled task runs are self-contained about forked-session isolation, prior-run memory, origin delivery, and recursive scheduling boundaries.
2. Added `RunSubmitter` regression coverage requiring those prompt-contract lines to stay present when cron jobs are submitted.
3. Updated the cron scorecard gap from broad prompt parity to the remaining structural toolset and recursive-scheduling enforcement work.

### Slice 28: Chunked streamed tool-call names

1. Updated the OpenAI-compatible completions streamer so function-name deltas are merged when providers split a tool name across chunks.
2. Kept repeated suffix chunks idempotent so duplicate name deltas do not corrupt the final tool name.
3. Added a provider regression test that streams `read_`, `file`, then a repeated `file` suffix and verifies the final tool call is `read_file`.

### Slice 29: Tool-only empty final streaming response

1. Added an AgentCore streaming regression for provider streams that emit a tool call and then finish with an empty terminal message.
2. Verified final message reconciliation preserves the accumulated `ToolCall` block in both the returned message and updated conversation context.

### Slice 30: Structured tool-task crash envelope

1. Added typed `:tool_task_crashed` details to tool results emitted when a supervised tool task exits before returning a result.
2. Added a regression that kills the tool task process and verifies exactly one error `tool_result`, matching conversation context, and end event are emitted.

### Slice 31: Typed tool execution error envelopes

1. Added typed details for tool functions that return `{:error, reason}`, raise exceptions, catch exits/throws, or return unsupported shapes.
2. Preserved the visible text content for existing tool errors while making `details.error_type` machine-readable.
3. Added focused regressions for returned tool errors, raised exceptions, and unexpected return values.

### Slice 32: Optional per-tool task timeouts

1. Added `tool_timeout_ms` to `AgentLoopConfig` and `AgentCore.Agent` opts, defaulting to unbounded for compatibility.
2. Tool execution now schedules per-task timeouts when configured, terminates overdue supervised tasks, and emits typed `:tool_task_timeout` results.
3. Added a focused regression proving a long-running tool is terminated and contributes exactly one error result and end event.

### Slice 33: Cron recursive-tool block

1. Scheduled run submissions now attach a tool policy with `blocked_tools: ["cron"]`.
2. Native CodingAgent tool policy filtering now honors router-style `blocked_tools`, not only CodingAgent-style `deny`.
3. Added focused regressions for the cron submission policy and blocked-tools enforcement.

### Slice 34: Opt-in live memory recall eval

1. Added `mix lemon.eval --live-model` for explicit provider-backed behavioral checks outside deterministic CI.
2. Added `live_model_memory_trace_contract`, which gives a live model a prior-work prompt and verifies it calls the real `search_memory` tool before answering.
3. Documented the `LEMON_EVAL_*` / `INTEGRATION_*` configuration surface and kept the live lane out of default `eval-fast`.

### Slice 35: Parallel tool result ordering

1. AgentCore now tracks the assistant tool-call order for each parallel tool batch.
2. Returned `tool_results`, updated loop context, and current-turn `new_messages` are sorted back to assistant order before the next model turn.
3. Added a regression where a later tool call finishes first but the transcript still preserves the original call order.

### Slice 36: Opt-in live skill learning eval

1. Added `live_model_skill_learning_contract` to `mix lemon.eval --live-model`.
2. The eval seeds a project skill, then requires the provider-backed model to call `read_skill` and create a project skill with `skill_manage`.
3. It verifies the new skill is active and agent-authored before accepting the final marker response.

### Slice 37: Tool transcript validator

1. Added `AgentCore.Loop.TranscriptValidator` as a reusable pre-provider contract for assistant tool calls and tool results.
2. `Loop.Streaming` now validates transformed context messages before converting them to provider-specific messages.
3. Added regressions for missing, duplicate, unexpected, and orphaned tool results, plus a loop-level check that invalid transcripts never call the model.

### Slice 38: Opt-in live skill curator eval

1. Added `live_model_skill_curator_contract` to `mix lemon.eval --live-model`.
2. The eval seeds two narrow Kubernetes rollout skills, renders the real curator prompt, and requires the provider-backed model to read both skills.
3. It verifies the model creates a broader umbrella skill, archives the absorbed siblings, and finishes with the expected live eval marker.

### Slice 39: Opt-in live cron block eval

1. Added `live_model_cron_block_contract` to `mix lemon.eval --live-model`.
2. The eval applies a `blocked_tools: ["cron"]` policy to a live eval tool set and verifies the `cron` tool is filtered before the model turn.
3. It requires the provider-backed model to use `search_memory` for prior scheduled-run context and finish with the expected cron blocked-tool marker.

### Slice 40: Opt-in live parallel delegation eval

1. Added `live_model_parallel_delegation_contract` to `mix lemon.eval --live-model`.
2. The eval requires a provider-backed model to start exactly two async child tasks with `auto_followup` disabled, preserve both task ids, and join them with `mode` `wait_all`.
3. It verifies the final answer includes the expected marker and both joined child outputs.

### Slice 41: Delegation artifact verification eval

1. Added `agent_loop_delegation_artifact_trace_contract` to the deterministic eval suite.
2. The eval queues an async child, joins the returned task id, reads the child-produced artifact, and requires the final answer to include the verified artifact contents.
3. It keeps child side-effect verification in the default eval lane while leaving provider-backed side-effect behavior for a later live-model slice.

### Slice 42: OpenAI-compatible tool-call argument sanitization

1. Sanitized assistant tool-call names and nested argument values before OpenAI-compatible request encoding.
2. Added a regression that stores invalid UTF-8 inside an assistant tool-call argument and verifies the provider request still encodes valid JSON.
3. This ports one Hermes provider-weirdness invariant without changing Lemon's provider boundary shape.

### Slice 43: Truncated streamed tool-call argument recovery

1. Preserved best-effort parsed tool-call arguments when an OpenAI-compatible stream ends with recoverable truncated JSON.
2. Replaced the simple closing-brace fallback with stack-based completion so nested arrays/objects close in the correct order.
3. Added a regression that streams a truncated `{"files":["mix.exs"` argument and verifies finalization keeps `%{"files" => ["mix.exs"]}`.

### Slice 44: Provider retry delay normalization

1. Moved retry-delay extraction for `retry-after`, `x-ratelimit-reset-after`, `Please retry in`, reset-after, and `retryDelay` hints into `Ai.Providers.RetryHelper`.
2. Wired OpenAI-compatible streaming retries to honor provider-supplied retry delays before falling back to jittered exponential backoff.
3. Added focused retry-helper coverage plus an OpenAI-compatible 429 regression that verifies the retry waits for the supplied header.

### Slice 45: Context-length provider error normalization

1. Classified context-window HTTP failures as explicit `:context_length` provider errors in `Ai.Error`.
2. Routed OpenAI-compatible terminal HTTP responses through the shared error normalizer instead of local string formatting.
3. Added regressions for OpenAI context-length classification and streamed OpenAI-compatible HTTP error output.

### Slice 46: Req-style rate-limit header normalization

1. Made `Ai.Error.extract_rate_limit_info/1` accept maps as well as header tuple lists.
2. Normalized header keys with `to_string/1` and unwrapped first list values, matching Req response header shape.
3. Added coverage for rate-limit and retry-after extraction from Req-style header maps.

### Slice 47: OpenAI Responses HTTP error normalization

1. Materialized async non-2xx OpenAI Responses bodies before logging and parsing provider errors.
2. Routed terminal OpenAI Responses HTTP errors through `Ai.Error.parse_http_error/3`.
3. Added a regression that verifies a streamed Responses context-length failure surfaces the normalized context-length message.

### Slice 48: Live-model delegation artifact verification

1. Added an opt-in live-model eval that asks the provider-backed loop to delegate artifact creation, join the child task, read the child-created file, and only then answer.
2. Verified the eval fails cleanly without live-model credentials and appears only in the `--live-model` lane.
3. Kept the eval side effect local to a temporary project and checked the artifact exists before passing.

### Slice 49: Leaf/orchestrator toolset contracts

1. Added explicit `:orchestrator` and `:leaf_worker` tool-policy profiles.
2. Added a deterministic eval that proves orchestrators retain delegation tools while leaf workers keep normal work tools but lose `task` and `agent`.
3. Added an opt-in live-model eval that filters `task` from a leaf worker and requires the provider-backed model to use `read` without recursive delegation.

### Slice 50: OpenAI Responses tool-call argument sanitation

1. Sanitized nested OpenAI Responses tool-call argument values before JSON request encoding.
2. Added a regression proving invalid UTF-8 inside nested function-call arguments is sanitized instead of breaking Responses request construction.

### Slice 51: OpenAI Responses tool-call identity sanitation

1. Sanitized OpenAI Responses function-call ids before splitting and encoding.
2. Sanitized function-call names and item ids before request encoding.
3. Added a regression proving invalid UTF-8 in `call_id`, `id`, and `name` fields still produces valid request strings.

### Slice 52: OpenAI Responses tool schema sanitation

1. Sanitized OpenAI Responses tool names and descriptions before request encoding.
2. Sanitized nested tool parameter schema values before request encoding.
3. Added a regression proving invalid UTF-8 in tool schema fields still produces an encodable request schema.

### Slice 53: Internal task child leaf-worker default

1. Defaulted internal `task` children to the `:leaf_worker` tool policy.
2. Preserved explicit task `tool_policy` overrides and non-internal CLI engine behavior.
3. Updated task docs and AGENTS guidance to document the recursive delegation boundary.

### Slice 54: Durable memory secret screening

1. Added `LemonCore.MemorySafety` as the shared predicate for secret-looking memory summaries.
2. Rejected unsafe memory documents before config loading or store writes in `MemoryIngest`.
3. Reused the same predicate for skill synthesis candidate filtering and added focused regressions.

### Slice 55: Live-model durable topic memory contract

1. Added `live_model_memory_topic_contract` to the opt-in live-model eval lane.
2. Exposed `search_memory`, `memory_topic`, and `skill_manage` together so the provider-backed model must choose durable topic capture for project context.
3. Asserted the eval creates `deployment-incident-handoff.md`, avoids prior-run search and procedural skill writes, and finalizes with the expected marker.

### Slice 56: Agent safety contract documentation

1. Added `docs/security/agent-safety-contract.md` as the composed safety reference.
2. Registered the doc in `docs/catalog.exs` and linked it from `docs/README.md`.
3. Updated this scorecard so the remaining safety/governance gap is adversarial prompt-injection eval depth.

### Slice 57: Untrusted prompt-injection eval

1. Added `untrusted_prompt_injection_contract` to the deterministic eval harness.
2. Exercised the real untrusted tool-output boundary with adversarial external content that tries to close the wrapper and override system/tool policy.
3. Asserted the wrapper warning remains present and nested end markers are sanitized while the real boundary marker is preserved.

### Slice 58: LemonRunner structured tool failure metadata

1. Preserved `AgentToolResult.details.error_type` and adjacent failure fields in LemonRunner completed action metadata.
2. Added a native runner regression for an unknown tool call, proving `ActionEvent` observers see `result_meta.error_type` and `result_meta.tool_name`.
3. Documented the `action.detail.result_meta` surface in the LemonRunner module docs.

### Slice 59: Router status tool failure metadata

1. Added `body.tool_failures` to router tool-status intents when completed actions include `result_meta.error_type`.
2. Kept the rendered status text unchanged while exposing compact structured failure fields for UI and observability consumers.
3. Added a ToolStatusCoalescer regression covering an unknown-tool failure propagated through status intent dispatch.

### Slice 60: Control-plane tool-use metadata mapping

1. Fixed EventBridge `:engine_action` mapping to read canonical nested `payload.action` fields while preserving legacy flat payload fallback.
2. Preserved `action.detail.result_meta` in WebSocket `agent` tool-use events so UI/control-plane observers can inspect structured tool failures.
3. Added an EventBridge regression that broadcasts a nested unknown-tool completion and asserts the control-plane event carries `error_type` and `tool_name`.

### Slice 61: Anthropic overloaded error normalization

1. Classified HTTP 529 provider responses as transient instead of generic server errors.
2. Made HTTP 529 retryable so Anthropic `overloaded_error` responses follow the same recovery path as 502/503/504 provider failures.
3. Updated provider-error regressions to assert Anthropic overloaded responses are transient and retryable.

### Slice 62: Skill prompt-render observability

1. Added `[:lemon_skills, :skill, :prompt_render]` telemetry with redacted skill keys/counts for available and relevant prompt surfaces.
2. Projected prompt-render telemetry into `:skill_prompt_render_observed` introspection events with run/session/agent provenance.
3. Passed native session provenance through prompt composition and added regressions for direct prompt rendering and native session introspection lookup.

### Slice 63: Workspace memory-file inspection contract

1. Added `agent_loop_workspace_memory_file_contract` to the eval harness.
2. Seeded a workspace `memory/topics/*.md` note and drove `AgentCore.Loop` through real `grep` and `read` tool results before finalizing.
3. Added harness regressions so the workspace memory-file lane stays distinct from prior-run `search_memory` and durable `memory_topic` coverage.

### Slice 64: Millisecond retry-after header normalization

1. Taught shared parsed provider errors to extract `retry-after-ms` and `x-ms-retry-after-ms` as millisecond retry delays.
2. Taught provider retry backoff extraction to honor the same millisecond headers before falling back to reset-after or body hints.
3. Added Azure-style and retry-helper regressions so millisecond retry delays remain distinct from seconds-based `retry-after`.

### Slice 65: Rate-limit reset duration parsing

1. Parsed OpenAI-style reset duration strings such as `1ms` and `6m0s` into future reset times.
2. Parsed ISO 8601 reset timestamps before Unix timestamp fallbacks so date strings are no longer truncated to leading years.
3. Treated long numeric reset values as Unix milliseconds while preserving seconds-based Unix timestamp support.

### Slice 66: Live-model workspace memory-file inspection

1. Added `live_model_workspace_memory_file_contract` to the opt-in live-model eval lane.
2. Seeded a workspace `memory/topics/release-handoff.md` note and exposed `grep`, `read`, `search_memory`, and `memory_topic` together.
3. Required the provider-backed model to find and read the workspace memory file while avoiding prior-run search and durable-topic creation.

### Slice 67: Live-model relevant-skill audit coverage

1. Added `live_model_relevant_skill_usage_contract` to the opt-in live-model eval lane.
2. Seeded a relevant project skill, required the provider-backed model to call `read_skill`, and checked the final answer marker.
3. Ran the session missed-skill audit over the live transcript and asserted no `:missed_skill_observed` event was recorded for the loaded skill.

## Follow-up backlog

1. Continue provider-weirdness regressions for provider-normalized response error shapes beyond context length and Responses request sanitation.
