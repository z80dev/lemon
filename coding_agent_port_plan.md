# Pi Coding Agent Port Plan (Steps 1–2)

Date: 2026-01-29

## Step 1 — Inventory of TypeScript `pi-coding-agent` (pi-mono)

### 1) Entry points & CLI flow
- `src/cli.ts` → `src/main.ts` (process title, CLI entry)
- `src/main.ts` orchestrates:
  - CLI arg parsing (`src/cli/args.ts`)
  - Session/config selection UI (`src/cli/session-picker.ts`, `src/cli/config-selector.ts`)
  - Resource loading, settings, tools, extensions
  - Mode selection: interactive / print / rpc

### 2) Top-level structure
```
src/
  cli/               # CLI helpers and pickers
  core/              # Shared logic (session, tools, extensions, compaction, etc.)
  modes/             # interactive / print / rpc
  utils/             # clipboard, git, image, shell helpers
  config.ts          # paths, env, package assets
  main.ts            # CLI orchestrator
```

### 3) Core module map (non-UI)
- **Session & state**
  - `core/agent-session.ts` — session lifecycle, model cycling, compaction, branching, bash execution, extensions binding, prompt dispatch
  - `core/session-manager.ts` — JSONL session storage (tree structure, migration v1→v3, branch, labels)
  - `core/messages.ts` — custom message types (bashExecution, custom, branchSummary, compactionSummary) + convertToLlm
- **Tools**
  - `core/tools/*` — `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `truncate`, `path-utils`
- **Compaction / summaries**
  - `core/compaction/*` — auto compaction, branch summarization, token estimation
- **Execution / bash**
  - `core/bash-executor.ts` — streaming, abortable shell with truncation + temp file
  - `core/exec.ts` — spawn helper for extensions
- **Extensions**
  - `core/extensions/{types,loader,runner,wrapper}.ts` — extension API, lifecycle hooks, tool wrappers, registry
- **Model registry / selection**
  - `core/model-registry.ts`, `core/model-resolver.ts`
- **Settings & resources**
  - `core/settings-manager.ts` — global + project settings with merge & migrations
  - `core/resource-loader.ts` — load skills, extensions, prompts, themes, AGENTS/CLAUDE context
  - `core/skills.ts`, `core/prompt-templates.ts`, `core/package-manager.ts`, `core/auth-storage.ts`
- **Export**
  - `core/export-html/*` — HTML transcript export

### 4) Modes (UI surface)
- **Interactive (TUI)**: `modes/interactive/*`
  - TUI orchestration: `interactive-mode.ts`
  - 30+ components under `modes/interactive/components/*`
  - Theme in `modes/interactive/theme/*`
- **Print**: `modes/print-mode.ts` — headless, outputs final or JSON event stream
- **RPC**: `modes/rpc/*` — JSON stdin/stdout protocol, extension UI requests over RPC

### 5) CLI pickers (TUI dependent)
- `cli/session-picker.ts`, `cli/config-selector.ts` — use `@mariozechner/pi-tui` for selection UI

### 6) TUI coupling in “core”
`core/` is mostly UI-free, but there **are** UI leaks:
- `core/keybindings.ts` imports `@mariozechner/pi-tui` (KeyId, EditorKeybindings)
- `core/extensions/types.ts` depends on TUI types (`TUI`, `Component`, `EditorTheme`, etc.)
- `core/extensions/loader.ts` bundles `@mariozechner/pi-tui` for extensions
- `core/extensions/runner.ts` references `KeyId`
- `core/agent-session.ts` imports interactive theme (for HTML export rendering)
- `core/resource-loader.ts` loads themes via interactive theme loader

### 7) Runtime assumptions & external dependencies
- **Node/Bun runtime** and process APIs (`process.env`, `process.cwd`, `process.stdin/stdout`)
- **Filesystem**: config dir (`~/.pi/agent`), sessions in `sessions/*.jsonl`, settings in `settings.json`
- **OS**: home dir, temp dir, shell, child processes
- **External binaries**: uses shell, `rg`/`fd` via tools manager (see `utils/shell.ts`, `utils/tools-manager.ts`)
- **Assets**: theme JSON, HTML export templates, docs, examples

### 8) Data formats (important for compatibility)
- **Session files**: JSONL with header entry `{type: "session", version, id, cwd, ...}` + entries with `id`/`parentId` forming a tree
- **Custom entries**: `custom`, `custom_message`, `label`, `session_info`, `branch_summary`, `compaction`

### 9) Key porting hotspots
- Extension system (runtime + tool wrapping + UI interaction)
- Session storage + migrations
- Bash execution streaming + truncation
- Compaction/branch summarization hooks
- Resource loader (skills/prompts/extensions/themes) and agent context files

---

## Step 2 — Elixir Boundary Design (lemon)

### 1) Current Elixir base
- `apps/agent_core` already provides:
  - agent loop + streaming events (`AgentCore.Loop`, `AgentCore.EventStream`)
  - tool execution contract (`AgentCore.Types.AgentTool`)
- `apps/ai` already provides:
  - model definitions, providers, streaming

### 2) Proposed new app: `apps/coding_agent`
Keep UI out of this app; it should be a pure orchestration + tools layer.

#### Suggested module layout
```
apps/coding_agent/lib/coding_agent/
  session.ex                 # AgentSession equivalent
  session_manager.ex         # JSONL persistence + tree ops
  messages.ex                # custom message types + convert_to_llm
  tools/                     # read, write, edit, bash, grep, find, ls, truncate
  bash_executor.ex           # streaming shell + cancellation
  compaction/                # compaction + branch summarization
  extensions/                # plugin API, loader, runner (no UI types)
  resource_loader.ex         # skills/prompts/extensions/themes/context files
  settings_manager.ex        # project + global settings
  keybindings.ex             # optional (no UI deps) or defer
  model_registry.ex
  model_resolver.ex
  export_html/               # optional later
  config.ex                  # path resolution, env, assets
```

### 3) Clean boundary definitions

#### A) Core Session (no UI)
- `CodingAgent.Session` wraps:
  - `AgentCore.Loop` for execution
  - `SessionManager` for persistence
  - `SettingsManager` for defaults
  - `ResourceLoader` for skills/prompts/extensions
  - `Extensions.Runner` for hooks and tool wrapping
- Output = **events** + updated session state (no TUI concerns)

#### B) Tool interface
- Keep parity with `AgentCore.Types.AgentTool` signature
- Add **streaming tool updates** contract (used by bash/grep/long operations)
- All tools run under a **supervised Task** for cancellation support

#### C) UI abstraction (pluggable)
- Define `CodingAgent.UI` behaviour with methods mirroring TS `ExtensionUIContext`
- Provide **HeadlessUI** implementation for print/RPC
- TUI/LiveView (future) lives in a separate app (e.g., `coding_agent_tui` or `coding_agent_web`)

#### D) Extensions boundary
- Elixir-native extension API:
  - lifecycle hooks: `on_session_start`, `on_turn_start`, `on_tool_result`, etc.
  - tool registration + message renderers
  - **UI calls routed via `CodingAgent.UI` behaviour**
- Loader strategy (initial):
  - `config.exs` paths to `.exs` modules or BEAM modules
  - Later: package manager support (npm/git analog) can be deferred

#### E) Resource loading
- Context files: `AGENTS.md` / `CLAUDE.md` (global + project + ancestors)
- Skills/prompts/themes:
  - skills: `SKILL.md` files under configured dirs
  - prompts: template files with metadata
  - themes: keep optional if no UI yet (can store but not required)

#### F) Session persistence
- JSONL compatible format (versioned header + entries)
- Keep migration path (v1→v3) to preserve portability
- Tree operations: branch/fork, labels, compaction summaries

#### G) Compaction + branch summarization
- Pure core module that:
  - estimates tokens
  - decides when to compact
  - generates summary via `AgentCore.Loop` + system prompt
- Provide hooks for extensions to override

### 4) Integration points with existing apps
- `coding_agent` depends on `agent_core` + `ai`
- `coding_agent` does **not** depend on UI apps
- UI apps depend on `coding_agent` (adapters only)

### 5) Explicit decoupling targets (TS → Elixir)
- Move `keybindings`, `theme`, and all UI types **out of core**
- `CodingAgent.Session` should never import UI modules
- Extension UI calls go through a behaviour, not direct TUI APIs

### 6) BEAM leverage (design intent)
- Each session = GenServer process (state + event stream)
- Tools = supervised Tasks with cancellation via monitors
- Extension hooks = pub/sub via `EventStream` or `Registry`
- Multiple concurrent sessions ⇒ easy agent swarms

---

## Immediate artifacts to create (next step)
1. `apps/coding_agent` skeleton with boundary modules listed above
2. JSONL session format + migrations ported first (enables persistence)
3. Minimal headless UI adapter for print/RPC
4. Core tools port (`read`, `write`, `edit`, `bash`) to validate agent loop

---

## Review Findings (Current Elixir Implementation)

Assumptions from you:
- JSONL format does **not** need TS compatibility.
- Extension-injected `custom_message` entries **must** be included in LLM context.
- New summary formatting is acceptable.

Findings (ordered by severity):
1. **`convert_to_llm` mismatch: agent state uses `Ai.Types.*`, converter expects `CodingAgent.Messages.*`.**  
   `apps/coding_agent/lib/coding_agent/session.ex:155`  
   `CodingAgent.Messages.to_llm/1` pattern matches only on CodingAgent structs, but `AgentCore.Agent` stores `Ai.Types.*` messages. This will raise or drop messages at request time.
2. **`custom_message` still not included in LLM context, and restore path can’t represent it.**  
   `apps/coding_agent/lib/coding_agent/session_manager.ex:447`  
   `build_session_context/2` only includes `:message` entries; `restore_messages_from_session/1` only deserializes `user/assistant/tool_result`. You need a path for `custom_message` → agent state.
3. **Compaction is implemented but not wired into the session loop.**  
   `apps/coding_agent/lib/coding_agent/session.ex:512` and `apps/coding_agent/lib/coding_agent/session.ex:918`  
   `compact/2` and `maybe_trigger_compaction/1` are TODO; `CodingAgent.Compaction` never runs.
4. **Compaction cut‑point logic won’t detect tool results.**  
   `apps/coding_agent/lib/coding_agent/compaction.ex:136`  
   Checks `tool_use_id`, but serialized messages use `tool_call_id`. This can cut between tool call/result.
5. **Tool result content types are inconsistent and violate the AgentToolResult contract.**  
   `apps/coding_agent/lib/coding_agent/tools/read.ex:171` and `apps/coding_agent/lib/coding_agent/tools/bash.ex:63`  
   Read/Bash return maps instead of `Ai.Types.TextContent`/`ImageContent`. This will break strict conversion paths.
6. **Steering/follow‑up messages are not persisted to the session file.**  
   `apps/coding_agent/lib/coding_agent/session.ex:564`  
   `handle_agent_event/2` ignores `:message_end` for user messages, so queued steering/follow‑ups are lost.
7. **`custom_message.display` type is still a map.**  
   `apps/coding_agent/lib/coding_agent/session_manager.ex:75`  
   Should be `boolean()` to match intended semantics.
8. **`BashExecutor.sanitize_output/1` can raise on invalid UTF‑8.**  
   `apps/coding_agent/lib/coding_agent/bash_executor.ex:251`
9. **Streaming bash tool leaks an accumulator Agent.**  
   `apps/coding_agent/lib/coding_agent/tools/bash.ex:85`  
   `Agent.start_link/1` is never stopped.
10. **Session directory encoding is inconsistent across modules.**  
    `apps/coding_agent/lib/coding_agent/session_manager.ex:691` vs `apps/coding_agent/lib/coding_agent/config.ex:35`  
    `SessionManager` uses underscore encoding, `Config` uses `--...--`. This will split session storage once both are used.

Alignment with plan:
- UI abstraction (`CodingAgent.UI`, `CodingAgent.UI.Context`, headless implementation) matches the plan well.
- Session persistence and bash executor are aligned to the boundaries, but need the context/summary fixes above to achieve feature parity.

## Suggested Next Steps
1. **Align message types and `convert_to_llm`:** either switch to `Ai.Types.*` everywhere and update `CodingAgent.Messages.to_llm/1` to handle those, or use `CodingAgent.Messages.*` throughout (including session restore).  
2. **Include `custom_message` in context + restore path:** add `custom_message` handling in `build_session_context/2` and `deserialize_message/1` (or map to user messages before AgentCore).  
3. **Wire compaction into `CodingAgent.Session`:** call `CodingAgent.Compaction.compact/3` from `compact/2` and `maybe_trigger_compaction/1`, and append compaction entries.  
4. **Fix tool call/result pairing checks in compaction:** accept both `tool_call_id` and `tool_use_id`.  
5. **Normalize tool result content types:** return `Ai.Types.TextContent`/`ImageContent` in Read/Bash tools.  
6. **Persist steering/follow‑up user messages** when they complete (`:message_end` for user role).  
7. **Stop the bash streaming accumulator Agent** after command completion.  
8. **Unify session directory encoding** (choose Config or SessionManager as source of truth).  
9. **Harden bash output sanitization** (UTF‑8 scrub) and improve process tree kill if needed.

---

## Review Findings (Post-Fix Check)

New decisions:
- `branch_summary` entries **should** be included in LLM context.
- `custom_message` entries **should** be included in compaction summaries.

Findings (ordered by severity):
1. **Auto‑compaction can still crash with real agent state.**  
   `apps/coding_agent/lib/coding_agent/session.ex:889`  
   `CodingAgent.Compaction.estimate_context_tokens/1` expects `CodingAgent.Messages.*`, but `AgentCore.Agent` stores `Ai.Types.*`. This will hit `Messages.get_text/1` and raise `FunctionClauseError`.
2. **`custom_message.display` still coerces `false` to `true`.**  
   `apps/coding_agent/lib/coding_agent/session_manager.ex:526`  
   `apps/coding_agent/lib/coding_agent/session.ex:820`  
   Both use `entry.display || true` / `msg["display"] || true`, so explicit `false` is lost.
3. **Compaction summaries still exclude `custom_message` entries.**  
   `apps/coding_agent/lib/coding_agent/compaction.ex:670`  
   `get_messages_before/2` only collects `:message` entries.
4. **`branch_summary` entries are not injected into LLM context.**  
   `apps/coding_agent/lib/coding_agent/session_manager.ex:517`  
   `extract_messages/1` filters only `:message` and `:custom_message`.

## Detailed Instructions to Address Findings
1. **Fix auto‑compaction token estimation (Ai.Types support).**  
   - Update `CodingAgent.Compaction.estimate_context_tokens/1` to handle `Ai.Types.*` by adding `Messages.get_text/1` clauses (or a new helper) for `Ai.Types.UserMessage`, `Ai.Types.AssistantMessage`, and `Ai.Types.ToolResultMessage`.  
   - Alternatively, convert `agent_state.messages` to `CodingAgent.Messages.*` before token estimation.
2. **Preserve `custom_message.display = false`.**  
   - Replace `entry.display || true` and `msg["display"] || true` with a nil‑aware default: `if is_nil(display), do: true, else: display`.  
   - Apply in both `SessionManager.entry_to_message/1` and `Session.deserialize_message/1`.
3. **Include `custom_message` in compaction summaries.**  
   - In `CodingAgent.Compaction.get_messages_before/2`, accept both `:message` and `:custom_message`.  
   - Add a converter for custom entries to `Messages.CustomMessage` (already exists for raw role `"custom"`; reuse it).
4. **Include `branch_summary` in LLM context.**  
   - Update `SessionManager.extract_messages/1` to include `:branch_summary`.  
   - Add `entry_to_message/1` clause to emit a `CodingAgent.Messages.BranchSummaryMessage` or a raw map with `role: "branch_summary"` that `CodingAgent.Messages.to_llm/1` will convert.

---

## Review Findings (Implementation Check)

Decisions:
- Persist user prompts only on `:message_end` to avoid duplication.
- Compaction should operate on the current branch only.
- JSONL is required for agent/session interaction, but TS/pi-mono compatibility is not required.

Findings (ordered by severity):
1. **User prompts are persisted twice.**  
   `apps/coding_agent/lib/coding_agent/session.ex:379`  
   `apps/coding_agent/lib/coding_agent/session.ex:644`  
   `prompt/3` appends the user message immediately, and `:message_end` appends again, so history and compaction see duplicates.
2. **Compaction cut‑point may come from the wrong branch.**  
   `apps/coding_agent/lib/coding_agent/compaction.ex:651`  
   `apps/coding_agent/lib/coding_agent/compaction.ex:672`  
   `find_cut_point/2` scans all entries, but compaction summaries are built from the current branch.
3. **Settings manager is not wired into sessions.**  
   `apps/coding_agent/lib/coding_agent/session.ex:323`  
   `apps/coding_agent/lib/coding_agent/session.ex:905`  
   `settings_manager` is always `nil`, so compaction thresholds always use defaults.
4. **Default coding_agent test fails.**  
   `apps/coding_agent/test/coding_agent_test.exs:5`  
   `CodingAgent.hello/0` doesn’t exist.
5. **Core orchestration lacks tests.**  
   Only the edit tool has a dedicated test; session/session_manager/compaction/bash flows aren’t covered.

---

## Next Steps Sequence (Detailed)

1. **Triage and align on target behavior (1–2 hours).**
   - Confirm expected behavior for `custom_message.display = false` and `custom_message` in LLM context.
   - Decide whether branch summaries should be auto-created or only explicit.

2. **Fix correctness issues flagged in review (same day).**
   - **Avoid duplicate user messages:**
     - In `apps/coding_agent/lib/coding_agent/session.ex`, remove immediate persistence in `prompt/3` (or guard against double insert) so only `:message_end` persists.
     - Add a regression test to assert a single user message in the session after one prompt.
   - **Compaction cut-point on correct branch:**
     - Ensure `Compaction.find_cut_point/2` receives current-branch entries only.
     - If `find_cut_point/2` is public, add a helper in compaction to accept branch entries and pass those.
     - Add a test: create two branches with different leafs; ensure compaction on leaf A does not pick entries from leaf B.
   - **Settings manager wiring:**
     - In `Session.init/1`, actually use `settings_manager` (not nil) for compaction defaults.
     - Decide and implement defaults for `model`, `thinking_level`, and `system_prompt` if not provided in opts.
     - Add test cases for settings precedence (global vs project vs opts).
   - **Fix failing test:**
     - Update `apps/coding_agent/test/coding_agent_test.exs` to reflect actual module API, or remove the placeholder test.

3. **Harden tool APIs and cancellation behavior (same day).**
   - **Edit tool validation and abort:**
     - In `apps/coding_agent/lib/coding_agent/tools/edit.ex`, validate `path`, `old_text`, and `new_text` up front.
     - Add abort-signal checks at the start and before writing.
     - Add tests for missing params and abort behavior.
   - **Bash tool streaming contract:**
     - Confirm that `AgentTool.execute/4` expects `{:ok, AgentToolResult}` or `AgentToolResult`.
     - Normalize the tool return types if needed; add tests for streaming partial updates.
   - **Read/Write tools:**
     - Ensure `read` returns consistent truncation metadata and handles binary/invalid UTF-8 safely.
     - Add tests for read offsets, truncation, and image reads.

4. **Session context correctness and message conversion (1–2 days).**
   - **Compaction token estimation:**
     - Update `Compaction.estimate_context_tokens/1` to handle `Ai.Types.*` messages via `Messages.get_text/1`.
     - Add tests for mixed message lists (Ai.Types + CodingAgent.Messages).
   - **Custom message semantics:**
     - Preserve `display: false` consistently in `SessionManager.entry_to_message/1` and `Session.deserialize_message/1`.
     - Ensure `custom_message` entries are included in context if required.
     - Add tests for `custom_message` conversion and display flags.
   - **Branch summary integration:**
     - Decide where branch summaries are created (manual call vs automatic on branch change).
     - If automatic, add an explicit API in `Session` to summarize a branch and store a `branch_summary` entry.
     - Ensure `SessionManager.build_session_context/2` includes branch summaries in LLM messages.

5. **Resource loading (skills/prompts/context files) (2–3 days).**
   - Implement `CodingAgent.ResourceLoader`:
     - Read `AGENTS.md` / `CLAUDE.md` from project root and ancestor directories.
     - Load global + project skills (SKILL.md) from `~/.pi/agent/skills` and `.pi/skills` if present.
     - Load prompt templates from configured dirs and expose a lookup API.
   - Add unit tests for:
     - Ancestor traversal and merge order.
     - Skill discovery and prioritization.
     - Prompt template parsing.

6. **Extensions API and loader (3–5 days).**
   - Define extension behaviour contract (hooks, tool registration, custom message renderers).
   - Implement loader:
     - `settings_manager.extension_paths` + `CodingAgent.Config.extensions_dir`.
     - Support `*.exs` or BEAM modules with explicit entry point.
   - Implement extension runner:
     - Lifecycle hooks: `on_session_start`, `on_turn_start`, `on_tool_result`, `on_session_end`.
     - Tool wrapping and registration.
     - Custom message injection with `custom_message` entries.
   - Add tests for:
     - Loading, hook execution order, error isolation.
     - Tool registration and wrapper behavior.

7. **UI abstraction wiring (2–4 days).**
   - Define `CodingAgent.UI.Context` usage points:
     - Add UI calls in session lifecycle where user selection is needed (e.g., session picker/config selection).
     - Surface tool notifications and error messages via `UI.notify`.
   - Implement a basic RPC UI adapter:
     - JSON request/response protocol for `select`, `confirm`, `input`, and `editor`.
     - Timeouts and error handling.
   - Add tests or harnesses for:
     - Headless mode (no‑op).
     - RPC mode (request/response loop).

8. **CLI or integration layer (future milestone).**
   - If the plan includes a CLI, create a thin adapter in a separate app (e.g., `coding_agent_cli`).
   - Keep UI-specific dependencies out of `coding_agent` core.
   - Ensure CLI respects the UI abstraction by plugging in the appropriate `CodingAgent.UI` implementation.

9. **Parity improvements with pi-mono (ongoing).**
   - Add remaining tools (`grep`, `find`, `ls`, `truncate`, path utils).
   - Add export HTML (if required) under `coding_agent/export_html`.
   - Add session listing and session picker logic (UI‑layer only).
   - Track known deltas vs pi-mono in a compatibility checklist.

10. **Testing and quality gates (continuous).**
    - Add `CodingAgent.Session` tests:
      - prompt/steer/follow_up flows, tool execution, streaming, and persistence.
    - Add integration tests for compaction + persistence + restore.
    - Add simple property tests for session tree invariants (parent/leaf correctness).
    - If possible, add a small end‑to‑end test using a mock AI provider.

11. **Documentation refresh (after core stabilizes).**
    - Replace the placeholder `apps/coding_agent/README.md` with usage, architecture, and extension docs.
    - Document JSONL format (version 3), migration behavior, and compatibility notes.
    - Document UI behavior and expected RPC protocol if used.

---

# Review Findings (2026-01-29)

## Core correctness & behavior
1. **Abort handling in `edit` ignores AgentCore abort signal.**
   - `CodingAgent.Tools.Edit.check_aborted/1` checks `Process.get({:aborted, signal})` instead of `AgentCore.AbortSignal.aborted?/1`.
   - Impact: edit operations can continue after cancellation.
   - File: `apps/coding_agent/lib/coding_agent/tools/edit.ex`

2. **Compaction `:force` option is advertised but not honored.**
   - `Session.compact/2` exposes `:force`, but `Compaction.compact/3` never uses it and still returns `:cannot_compact` if no cut point.
   - Impact: manual compaction cannot be forced for short histories.
   - Files: `apps/coding_agent/lib/coding_agent/session.ex`, `apps/coding_agent/lib/coding_agent/compaction.ex`

3. **Extensions are defined but not integrated into Session runtime.**
   - No auto-loading of extensions, no hooks executed, and extension tools are not merged into the tool list.
   - Impact: extensions are effectively inert despite implemented API.
   - Files: `apps/coding_agent/lib/coding_agent/extensions.ex`, `apps/coding_agent/lib/coding_agent/session.ex`

4. **Resource loader is implemented but not applied to prompts.**
   - `ResourceLoader` can load AGENTS/CLAUDE/skills/prompts, but Session never composes these into the system prompt or context.
   - Impact: context files do not affect the agent at runtime.
   - Files: `apps/coding_agent/lib/coding_agent/resource_loader.ex`, `apps/coding_agent/lib/coding_agent/session.ex`

5. **Compaction cut‑point logic ignores `custom_message` entries.**
   - `find_cut_point/2` only scans `:message` entries even though docs list `custom` as valid cut points.
   - Impact: valid cut points may be skipped, leading to earlier cut or no compaction.
   - File: `apps/coding_agent/lib/coding_agent/compaction.ex`

## UI abstraction status
- **RPC UI stays inside `coding_agent` (confirmed).**
- `CodingAgent.UI` behaviour + `Headless` + `RPC` are implemented and UI calls are routed through the behaviour.
- `UI.Context` exists but only stores a module; per‑session UI instance/state isn’t passed through yet.

---

# Next Steps Plan (Detailed)

## Phase 1 — Wire runtime inputs (1–2 days)
1. **Integrate resource loading into Session startup.**
   - Compose a `system_prompt` from:
     - Explicit `:system_prompt` option
     - AGENTS/CLAUDE content (project + ancestors + global)
     - Optional prompt template (by name) if provided
   - Decide merge order and document it (most‑specific to most‑general, then user prompt).
   - Add tests verifying ordering and presence in `AgentCore.Agent` context.

2. **Integrate extensions into Session startup.**
   - Load extensions from:
     - `settings_manager.extension_paths`
     - `CodingAgent.Config.extensions_dir/0`
     - `CodingAgent.Config.project_extensions_dir/1`
   - Merge extension tools into `tools` list.
   - Capture hooks and execute on agent events (`on_message_start/end`, `on_tool_execution_start/end`, `on_agent_start/end`).
   - Add tests for hook execution order and error isolation.

## Phase 2 — Fix correctness gaps (0.5–1 day)
3. **Fix abort signal handling in `edit`.**
   - Replace `Process.get` checks with `AgentCore.AbortSignal.aborted?/1`.
   - Add a targeted unit test that aborts mid‑edit and asserts `{:error, "Operation aborted"}`.

4. **Honor `:force` in compaction.**
   - If `force: true`, allow compaction even when `find_cut_point` returns `:cannot_compact` by choosing a safe fallback cut point (e.g., keep the last user message + any trailing tool results).
   - Update docs and tests for the forced path.

5. **Allow `custom_message` as valid cut point.**
   - Include `:custom_message` entries when evaluating valid cut points.
   - Add tests where the only safe cut is a custom message.

## Phase 3 — UI and RPC hardening (1–2 days)
6. **Keep RPC UI in `coding_agent`, but allow per‑session RPC instance.**
   - Extend `UI.Context` to carry a module + optional server pid/name.
   - Thread this context into `Session` UI calls so multiple sessions can target different RPC UI processes.
   - Add RPC tests for multiple concurrent sessions.

7. **Add minimal UI hooks in Session.**
   - Use `UI.notify` on critical errors.
   - Use `UI.set_working_message` for long tools (already in place for tools start/end).
   - Add UI status updates for compaction start/end and branch summarization.

## Phase 4 — Parity & quality (ongoing)
8. **Model registry/resolver (if needed for parity).**
   - Port minimal model registry to match the pi-mono behavior.
   - Keep the API in `coding_agent` but place provider logic in `ai`.

9. **Session compatibility (optional).**
   - If pi‑mono JSONL compatibility becomes required, add a migration/serializer that can emit pi‑style messages.

10. **Documentation & examples.**
    - Update `README.md` with startup examples, RPC protocol summary, and extension loading configuration.
