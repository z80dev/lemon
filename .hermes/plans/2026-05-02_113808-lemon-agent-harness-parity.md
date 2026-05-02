# Lemon Agent Harness Parity Plan

## Goal

Make Lemon a stronger local-first agent harness on par with Hermes Agent while preserving Lemon's BEAM-native advantages: supervised processes, streaming events, live steering, multi-engine routing, and local messaging channels.

This plan is intentionally discovery-first. The next work should turn broad parity goals into measurable gaps, then land one thin vertical slice that improves daily agent usefulness without destabilizing the architecture.

## Current context from inspection

- Repo: `/home/z80/dev/lemon`.
- Current branch: `main`, ahead of `origin/main` by 1 commit.
- Current worktree is dirty; do not overwrite these user changes without reviewing first:
  - `apps/coding_agent/lib/coding_agent/tools/grep.ex`
  - `apps/coding_agent/test/coding_agent/tools/grep_test.exs`
  - `docs/for-dummies/06-the-agent.md`
- Lemon already has many harness foundations:
  - OTP session/process supervision and lane-aware queues.
  - Native Lemon engine plus CLI engines for Claude, Codex, OpenCode, Droid, Pi, and Echo.
  - Telegram/Discord/X/XMTP channel adapters and gateway/runtime split.
  - Session persistence, memory search, compaction, routing feedback, skill catalog/synthesis.
  - Tool registry with builtin/WASM/extension precedence, policies, approvals, and conflict reporting.
  - Task/subagent orchestration with async task tracking, parent questions, run graph, and progress APIs.
  - Long-running harness primitives: `FEATURE_REQUIREMENTS.json`, todo dependency tracking, checkpoints, `agent.progress`.
- Recent architecture review/remediation docs indicate Lemon has been moving in the right direction: `ai` is now cleaner, router/gateway boundaries have improved, gateway startup has been narrowed, and event/async delivery contracts have been rationalized.

## Working definition of “on par with Hermes”

Treat Hermes as the benchmark for agent harness ergonomics, not as an implementation target. The parity surface should include:

1. **Tool ergonomics and enforcement**
   - Reliable file/search/edit/terminal/web/browser/media/message tools.
   - Clear rules that prevent bad tool usage patterns.
   - Output limits, spill files, background process management, and verification discipline.

2. **Procedural memory and skills**
   - Mandatory skill discovery/loading where relevant.
   - Skill authoring/patching lifecycle.
   - Skill-linked reference/templates/scripts.
   - Clear split between durable user memory, procedural skills, session recall, and transient todos.

3. **Delegation and orchestration**
   - Synchronous delegation for parallel research/coding/review.
   - Durable scheduled/background jobs for work that outlives the current turn.
   - Safe toolset restriction for children/jobs.
   - Verifiable side-effect handles from subagents.

4. **Messaging/native delivery**
   - First-class Telegram/Discord delivery, including media attachments and scheduled task delivery to origin.
   - Good rendering for markdown, code, files, images, audio.

5. **Developer experience**
   - Fast setup/doctor/quality loop.
   - Inspectable sessions/events/logs.
   - Web/TUI/control-plane observability.
   - Strong docs and examples.

6. **Safety and policy**
   - Approval gates for destructive/external side effects.
   - Read-only/safe-mode profiles.
   - Untrusted tool-output boundaries and prompt injection defenses.
   - Clear separation between user profile memory and system/environment facts.

## Proposed approach

Use a scorecard plus vertical-slice implementation strategy:

1. Build a parity scorecard comparing Lemon’s current capabilities to Hermes-like harness capabilities.
2. Convert gaps into an ordered backlog with acceptance tests.
3. Pick one first vertical slice that improves agent quality immediately.
4. Implement behind feature flags where behavior changes user-visible flows.
5. Validate through targeted tests, `mix lemon.quality`, and one dogfood session over Telegram/TUI.

## Recommended first vertical slice

**Skill and memory discipline in the native Lemon agent loop.**

Reasoning:

- Lemon already has a skill registry, synthesis, memory store, session search, and prompt builder.
- Hermes-like quality depends heavily on the agent reliably loading the right procedural context before acting.
- This is high leverage: it improves every future coding, debugging, research, and ops task.
- It is less risky than rewriting gateway/router execution and can be tested at the prompt/tool-selection boundary.

Target behavior:

- At run start, Lemon should expose available skills compactly and instruct the model to load relevant ones before answering/acting.
- The skill-loading rule should be enforceable or at least auditable:
  - tool calls/events show which skills were listed/loaded;
  - runs can be flagged when a skill matched but was not loaded;
  - tests cover matching behavior and prompt contract.
- Memory types should be explicit in the prompt and tools:
  - durable user facts;
  - general memory notes;
  - procedural skills;
  - session search for prior work;
  - todo/progress for current-session state.

## Step-by-step plan

### Phase 0 — Protect the current worktree

1. Inspect existing local changes before touching code:
   - `git status --short --branch`
   - `git diff -- apps/coding_agent/lib/coding_agent/tools/grep.ex apps/coding_agent/test/coding_agent/tools/grep_test.exs docs/for-dummies/06-the-agent.md`
2. Either continue on this branch only if those edits are intentionally part of the same effort, or create a worktree:
   - `mkdir -p .worktrees`
   - `git worktree add .worktrees/harness-parity -b harness-parity`
3. Keep parallel agent work in separate `.worktrees/*` directories per `AGENTS.md`.

### Phase 1 — Create the parity scorecard

Create `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md` with:

- Capability categories:
  - tools;
  - browser/web/media;
  - terminal/process management;
  - delegation/subagents;
  - cron/scheduled jobs;
  - messaging delivery;
  - memory/session search;
  - skills lifecycle;
  - prompt/system-contract enforcement;
  - safety/approvals;
  - observability/evals;
  - install/setup/docs.
- For each category:
  - current Lemon modules/docs;
  - Hermes-like target behavior;
  - status: shipped / partial / missing / unknown;
  - acceptance tests;
  - priority.

Files to inspect while writing:

- `README.md`
- `AGENTS.md`
- `apps/coding_agent/README.md`
- `apps/coding_agent/AGENTS.md`
- `apps/lemon_skills/README.md`
- `docs/user-guide/skills.md`
- `docs/user-guide/memory.md`
- `docs/long-running-agent-harnesses.md`
- `docs/extensions.md`
- `apps/lemon_gateway/README.md`
- `apps/lemon_automation/README.md`
- `apps/lemon_control_plane/README.md`

### Phase 2 — Audit skill/memory prompt path

Trace how Lemon currently builds the native agent prompt and tool set:

- `apps/coding_agent/lib/coding_agent/system_prompt.ex`
- `apps/coding_agent/lib/coding_agent/prompt_builder.ex`
- `apps/coding_agent/lib/coding_agent/resource_loader.ex`
- `apps/coding_agent/lib/coding_agent/workspace.ex`
- `apps/coding_agent/lib/coding_agent/tools/memory_topic.ex`
- `apps/lemon_skills/lib/**`
- `apps/lemon_core/lib/**memory**` and `**session_search**` modules.

Questions to answer:

- Are available skills surfaced to the model every run, compactly enough to be useful?
- Does Lemon have a first-class `skill_view`/`skill_list` tool equivalent, or only mix tasks/registry internals?
- Can the prompt require loading relevant skills before acting?
- Can the runtime detect/audit missed skill loads?
- Where are durable memories injected, and how are they separated from session search and transient todo state?

### Phase 3 — Implement first vertical slice

Likely changes:

- Add or improve skill tools in `apps/coding_agent/lib/coding_agent/tools/`:
  - `skills_list` / `skill_view` equivalents if not already exposed.
  - Optional `skill_patch` later; start read-only if needed for safety.
- Add prompt contract updates in:
  - `CodingAgent.SystemPrompt`
  - `CodingAgent.PromptBuilder`
  - relevant bootstrap docs under `~/.lemon/agent/workspace` or repo docs if those are source-controlled.
- Add skill-load audit metadata to run/session events if practical:
  - skill list surfaced;
  - skill files loaded;
  - matched-but-not-loaded warnings if matcher exists.
- Update documentation:
  - `apps/coding_agent/README.md`
  - `docs/user-guide/skills.md`
  - `docs/user-guide/memory.md`
  - `AGENTS.md` if architecture or workflow changes.

Initial acceptance criteria:

- A native Lemon run can list available skills.
- A native Lemon run can load a skill’s `SKILL.md` and linked files.
- The system prompt clearly instructs the model to load relevant skills before acting.
- Tests prove prompt/tool registration behavior.
- Documentation explains how skills differ from memory/session search/todos.

### Phase 4 — Add harness evals

Add deterministic eval cases around agent harness behavior:

- “User asks to configure Hermes/Lemon” → agent loads relevant skill before answer.
- “User asks for code review” → agent loads code-review/requesting-code-review skill equivalent if present.
- “User references prior work” → agent uses session search/memory tool instead of guessing.
- “User asks to schedule” → agent chooses cron/scheduled job path and includes self-contained prompt.
- “User asks for long-running implementation” → agent creates todo/progress plan and uses background process semantics correctly.

Likely files:

- `apps/coding_agent/test/**`
- `apps/lemon_skills/test/**`
- `apps/lemon_core/test/**memory**`
- existing eval harness under `CodingAgent.Evals.Harness` / `Mix.Tasks.Lemon.Eval`.

### Phase 5 — Expand backlog after first slice

After skill/memory discipline lands, prioritize the remaining parity backlog:

1. **Tool-use policy enforcement**
   - Prefer dedicated tools over shell equivalents where possible.
   - Better “act, don’t just promise” prompt + evals.
   - Verification-before-finalization checks.

2. **Delegation parity**
   - Make subagent result contracts stricter.
   - Require verifiable handles for side effects.
   - Add toolset restrictions and clearer leaf/orchestrator semantics.

3. **Cron/job parity**
   - Self-contained prompt validation.
   - Origin delivery semantics.
   - Context chaining between jobs.
   - Safer job management UX.

4. **Tool output and spill parity**
   - Standard caps across tools.
   - Stable spill references.
   - Retrieval path for full output.

5. **Messaging/media parity**
   - Native attachment syntax/handling for Telegram/Discord.
   - Better Markdown rendering rules per channel.

6. **Observability/dogfood loop**
   - Control-plane dashboard for skill loads, memory usage, tool calls, approvals, subagent tree, and cron runs.

## Files likely to change first

- `apps/coding_agent/lib/coding_agent/system_prompt.ex`
- `apps/coding_agent/lib/coding_agent/prompt_builder.ex`
- `apps/coding_agent/lib/coding_agent/tools.ex`
- `apps/coding_agent/lib/coding_agent/tool_registry.ex`
- `apps/coding_agent/lib/coding_agent/tools/skill*.ex` or equivalent new modules
- `apps/lemon_skills/lib/**`
- `apps/coding_agent/test/**skill**`
- `apps/lemon_skills/test/**`
- `docs/user-guide/skills.md`
- `docs/user-guide/memory.md`
- `apps/coding_agent/README.md`
- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`

## Validation commands

Run targeted tests first, then broader quality:

```bash
mix test apps/lemon_skills apps/coding_agent
mix test apps/coding_agent/test/coding_agent/tools
mix lemon.quality
```

Additional grep-style checks after implementation:

```bash
rg "skill" apps/coding_agent/lib/coding_agent/system_prompt.ex apps/coding_agent/lib/coding_agent/prompt_builder.ex
rg "SkillsList|SkillView|skill_view|skills_list" apps/coding_agent apps/lemon_skills
rg "memory|session_search|todo" apps/coding_agent/lib/coding_agent/system_prompt.ex docs/user-guide
```

## Risks and tradeoffs

- **Prompt bloat:** skill lists can consume context. Use compact summaries and load full skill text only on demand.
- **Over-triggering skills:** mandatory loading can slow simple tasks. Mitigate with good relevance summaries and audits, not forced loading of every possible skill.
- **Duplicate memory systems:** Lemon has memory topics, session search, skill synthesis, and todos. The prompt must keep their roles distinct.
- **Architecture drift:** skill/memory logic should not leak app dependencies across boundaries. Keep registry/domain logic in `lemon_skills`/`lemon_core`, agent-facing tools in `coding_agent`.
- **Dirty worktree:** current grep/doc edits may be unrelated. Avoid mixing the parity slice into those changes unless intentional.

## Open questions

- Should Lemon mirror Hermes tool names (`skill_view`, `session_search`, `cronjob`) for model portability, or use Lemon-native names and adapt in the prompt?
- Should skills be loaded by the model explicitly via tools, or preselected by deterministic runtime matching?
- Should missed-skill detection block final answers, warn in telemetry, or only feed evals initially?
- Which interface is the primary dogfood surface for this effort: Telegram, TUI, Web UI, or all three?
- Are we optimizing Lemon as a standalone Hermes-like user agent, or as a BEAM harness that can run multiple external agent engines equally well?

## Suggested immediate next task

Start with Phase 1 and Phase 2 in a clean worktree, then come back with a scorecard and a concrete PR-sized implementation plan for skill/memory discipline. Do not begin broad refactors until the scorecard identifies which gaps are real versus already implemented.
