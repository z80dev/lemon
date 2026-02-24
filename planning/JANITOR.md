# JANITOR.md - Implementation Agent Work Log

## 2026-02-24

### Completed Work

#### 0. Debt Phase 13 — Client CI Parity M7/M9/M10
**Plan:** PLN-20260222-debt-phase-13-client-ci-parity-governance
**Status:** in_review (workspace: lemon-phase13, change: wpnpouxs)

Implemented the three remaining actionable milestones from Phase 13:

**M7 — ESLint for lemon-tui and lemon-browser-node:**
- Created `eslint.config.js` in both packages (flat config, eslint v9, typescript-eslint, `globals.node`)
- Added `lint` script and devDependencies: `eslint ^9.39.1`, `typescript-eslint ^8.46.4`, `globals ^16.5.0`
- Added lint steps to `.github/workflows/quality.yml` for both packages

**M9 — Test coverage for lemon-web/server:**
- Extracted 5 pure utility functions from `src/index.ts` → new `src/utils.ts` (exported: `BridgeOptions`, `contentTypeFor`, `parseArgs`, `buildRpcArgs`, `decodeBase64Url`, `parseGatewayProbeOutput`)
- Created `src/utils.test.ts` with 43 unit tests
- Added `vitest ^3.0.0`, `@types/node ^24.0.0` to server devDependencies
- Added `test`/`test:watch` scripts and `vitest.config.ts` to server package
- Added `lemon-web server tests` step to CI

**M10 — Version alignment:**
- `lemon-tui`: `@types/node` ^22→^24, `vitest` ^2→^3
- `lemon-browser-node`: `@types/node` ^22→^24, `vitest` ^2.1.9→^3
- `lemon-web/server`: added `@types/node ^24`, `vitest ^3`
- All packages now at `@types/node ^24.x` and `vitest ^3.x` (except lemon-web/web which uses v4 with Vite)

**Changes:** 10 files (+562 lines, -180 lines)
**Tests added:** 43
**Deferred:** M8 (upstream transitive deps), M11 (monorepo restructuring)

---

#### 1. Pi Model Resolver - Slash Separator Support
**Plan:** PLN-20260224-pi-model-resolver-slash-support  
**Status:** ready_to_land

Implemented support for `provider/model` format (slash separator) in addition to the existing `provider:model` format:

**Changes:**
- `apps/coding_agent/lib/coding_agent/settings_manager.ex`
  - Updated `parse_model_spec/2` to try both `:` and `/` separators
  - Added `normalize_provider/1` helper for consistent provider atom conversion
  - Colon separator takes precedence for backward compatibility

- `apps/coding_agent/test/coding_agent/settings_manager_test.exs`
  - Added 5 new tests for slash separator parsing
  - Updated existing tests for atom provider expectations
  - All 39 tests pass

**New Supported Formats:**
- `openai:gpt-4` (existing colon format)
- `zai/glm-5` (new slash format)
- `openai/gpt-4o` (OpenRouter-style)

**Provider Normalization:**
- Lowercase: `"OpenAI"` → `:openai`
- Dash to underscore: `"openai-codex"` → `:openai_codex`

---

#### 2. Inspiration Ideas Investigation
**Plan:** PLN-20260224-inspiration-ideas-implementation  
**Status:** in_progress

Investigated 11 ideas from upstream research:

| Idea | Status | Finding |
|------|--------|---------|
| Pi Skill Auto-Discovery | completed | Already implemented |
| OpenClaw Config Redaction | completed | Already implemented |
| IronClaw Context Compaction | completed | Already implemented |
| OpenClaw Markup Sanitization | completed | Already implemented |
| Oh-My-Pi Todo Phase Management | completed | ETS-based TodoStore is superior |
| IronClaw WASM Hot-Activation | completed | Full hot-reload via Lemon.Reload |
| Pi Model Resolver | implemented | Slash separator support added |
| Oh-My-Pi Strict Mode | deferred | Needs deeper audit |
| Pi Streaming Highlight | deferred | Nice-to-have UX |
| IronClaw Shell Completion | deferred | Nice-to-have DX |
| Nanoclaw Voice Transcription | deferred | Wait for voice priority |

**6 of 7 high-priority ideas already implemented or now complete.**

---

#### 3. Runtime Hot-Reload System
**Plan:** PLN-20260224-runtime-hot-reload  
**Status:** in_progress

Created comprehensive runtime hot-reload system:

**Core Module (Lemon.Reload):**
- `reload_module/2` - Soft purge and reload BEAM modules
- `reload_extension/2` - Compile and reload .ex/.exs files
- `reload_app/2` - Reload all modules in an application
- `reload_system/1` - Orchestrated reload under global lock

**Control Plane Integration:**
- `system.reload` JSON-RPC method
- 10 tests for control plane methods

**Tests:**
- 14 tests for core reload functionality
- All tests pass

---

### Summary

| Metric | Count |
|--------|-------|
| Plans completed | 1 (model resolver) |
| Ideas investigated | 11 |
| Ideas already implemented | 6 |
| Ideas implemented today | 1 |
| Tests added/updated | 19 |
| Commits | 4 |

#### 4. Long-Running Agent Harnesses - Feature Requirements Tool (M1 Complete)
**Plan:** PLN-20260224-long-running-agent-harnesses  
**Status:** in_progress (M1 complete)

Implemented FeatureRequirements tool to prevent agents from "one-shotting" projects:

**New Module:** `CodingAgent.Tools.FeatureRequirements`

**Core Functions:**
- `generate_requirements/2` - Uses LLM to expand prompts into detailed feature lists
- `save_requirements/2` - Persists to `FEATURE_REQUIREMENTS.json`
- `load_requirements/1` - Loads from project directory
- `update_feature_status/4` - Updates feature status with notes
- `get_progress/1` - Calculates completion statistics
- `get_next_features/1` - Returns actionable features (dependencies met)
- `complete_feature/3` - Convenience for marking complete

**Feature Structure:**
- id, description, status (pending/in_progress/completed/failed)
- dependencies, priority (high/medium/low)
- acceptance_criteria, notes, timestamps

**Tests:** 10 comprehensive tests, all passing

---

#### 5. Long-Running Agent Harnesses - Enhanced TodoStore (M2 Complete)
**Plan:** PLN-20260224-long-running-agent-harnesses  
**Status:** in_progress (M2 complete)

Enhanced TodoStore with dependency tracking and progress:

**New Functions:**
- `get_actionable/1` - Returns todos whose dependencies are completed
- `get_progress/1` - Calculates progress statistics
- `update_status/3` - Updates status with automatic timestamps
- `complete/2` - Marks todo as completed
- `all_completed?/1` - Checks if all todos are done
- `get_blocking/1` - Returns todos blocking others

**Todo Structure:**
- id, content, status (pending/in_progress/completed/blocked)
- dependencies, priority, timestamps
- estimated_effort, metadata

**Tests:** 75 total tests (59 existing + 16 new), all passing

---

#### 6. Long-Running Agent Harnesses - Checkpoint Module (M3 Complete)
**Plan:** PLN-20260224-long-running-agent-harnesses  
**Status:** in_progress (M3 complete)

Created Checkpoint module for save/resume functionality:

**New Module:** `CodingAgent.Checkpoint`

**Core Functions:**
- `create/2` - Creates checkpoint with session state, todos, requirements
- `resume/1` - Restores from checkpoint and returns resume state
- `list/1` - Lists all checkpoints for a session (newest first)
- `get_latest/1` - Gets most recent checkpoint
- `delete/1` - Deletes a specific checkpoint
- `delete_all/1` - Deletes all checkpoints for a session
- `stats/1` - Returns checkpoint statistics
- `exists?/1` - Checks if checkpoint exists
- `prune/2` - Keeps only N most recent checkpoints

**Checkpoint Structure:**
- id, session_id, timestamp
- state, context, todos, requirements
- metadata with version

**Storage:** JSON files in system temp directory

**Tests:** 17 comprehensive tests, all passing

---

### Summary

| Metric | Count |
|--------|-------|
| Plans completed | 1 (model resolver) |
| Plans in progress | 2 (hot-reload, harnesses) |
| Ideas investigated | 11 upstream + 5 community |
| Ideas already implemented | 6 |
| Ideas implemented today | 1 (model resolver) |
| New features started | 3 (FeatureRequirements, TodoStore, Checkpoint) |
| Tests added/updated | 62 (45 + 17 new) |
| Commits | 7 |

### Next Steps

1. **Continue** PLN-20260224-long-running-agent-harnesses (M4-M6: introspection, docs, integration)
2. **Complete** PLN-20260224-runtime-hot-reload (documentation)
3. **Investigate** community ideas (MCP, WASM, multi-agent, channels)

#### 7. Debt Phases 9/10 Close-out + Phase 13 Ready-to-Land
**Plans:** PLN-20260222-debt-phase-09-gateway-reliability-decomposition, PLN-20260222-debt-phase-10-monolith-footprint-reduction, PLN-20260222-debt-phase-13-client-ci-parity-governance  
**Status:** phase-09 landed docs integrated, phase-10 landed docs integrated, phase-13 ready_to_land

Cron merge workspace consolidated pending debt-phase artifacts:

- Imported phase-09 planning artifacts:
  - `planning/reviews/RVW-PLN-20260222-debt-phase-09-gateway-reliability-decomposition.md`
  - `planning/merges/MRG-PLN-20260222-debt-phase-09-gateway-reliability-decomposition.md`
  - phase-09 plan/index updates and async attachment test sync fix (`assert_eventually`)
- Imported phase-10 planning artifacts:
  - `planning/reviews/RVW-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md`
  - `planning/merges/MRG-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md`
- Finalized phase-13 planning state:
  - created `planning/merges/MRG-PLN-20260222-debt-phase-13-client-ci-parity-governance.md`
  - updated `planning/INDEX.md` to move phase-13 into **Ready to Land**
  - updated phase-13 plan/review docs to reflect current test totals and status

Validation executed:

- `mix test apps/lemon_gateway/test/email/inbound_security_test.exs` ✅ (8 tests)
- `mix test apps/lemon_services/test` ✅ (14 tests)
- `clients/lemon-web/server`: `npm run test` + `npm run typecheck` ✅ (54 tests)
- `clients/lemon-web/shared`: `npm run test` ✅ (108 tests)
- `clients/lemon-tui`: `npm run lint` + `npm run typecheck` + `npm test` ✅ (947 tests)
- `clients/lemon-browser-node`: `npm run lint` + `npm run typecheck` + `npm test` ✅ (15 tests)

#### 8. Debt Phase 13 Landing Prep Push (Cron follow-up)
**Plan:** PLN-20260222-debt-phase-13-client-ci-parity-governance  
**Status:** ready_to_land (bookmark pushed)

Follow-up cron run performed final landing prep validation and published the bookmark for review/merge:

- Executed `jj git fetch` in `lemon-cron-merge`
- Re-ran required Elixir validations:
  - `mix test apps/lemon_services/test` ✅ (14 tests)
  - `mix test apps/lemon_gateway/test/email/inbound_security_test.exs` ✅ (8 tests)
- Pushed bookmark:
  - `feature/pln-20260222-debt-phase-13-client-ci-parity-governance` @ `dd5ad4b3`

Next operator step is merge/land from the pushed branch, then transition `planning/INDEX.md` entry from `ready_to_land` to `landed` with landed revision.

#### 9. Runtime Hot-Reload M8 Close-out (Docs + Review)
**Plan:** PLN-20260224-runtime-hot-reload  
**Status:** ready_to_land

Completed the remaining milestone (**M8**) for runtime hot-reload by producing operator docs and planning artifacts:

- Added runtime operations doc:
  - `docs/runtime-hot-reload.md`
- Added review artifact:
  - `planning/reviews/RVW-PLN-20260224-runtime-hot-reload.md`
- Added merge artifact:
  - `planning/merges/MRG-PLN-20260224-runtime-hot-reload.md`
- Updated plan and board state:
  - `planning/plans/PLN-20260224-runtime-hot-reload.md` → status `ready_to_land`
  - `planning/INDEX.md` → moved runtime hot-reload from Active Plans to Ready to Land

Validation executed:

- `mix test apps/lemon_core/test/lemon_core/reload_test.exs` ✅ (14 tests)
- `mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs` ✅ (10 tests)
- `mix test apps/coding_agent/test/coding_agent/checkpoint_test.exs apps/coding_agent/test/coding_agent/tools/todo_store_test.exs` ✅ (92 tests)

#### 10. Long-Running Harnesses M4 Progress Snapshot
**Plan:** PLN-20260224-long-running-agent-harnesses  
**Status:** in_progress (M4 complete)

Implemented the M4 progress-reporting milestone by adding a consolidated progress snapshot API for coding sessions:

- Added module:
  - `apps/coding_agent/lib/coding_agent/progress.ex`
- New API:
  - `CodingAgent.Progress.snapshot/2`
  - Aggregates todo progress, feature-requirement progress, checkpoint stats, and actionable next items
- Added tests:
  - `apps/coding_agent/test/coding_agent/progress_test.exs` (2 tests)
- Updated planning artifact:
  - `planning/plans/PLN-20260224-long-running-agent-harnesses.md` milestones/log now mark M1-M4 complete

Validation executed:

- `mix test apps/coding_agent/test/coding_agent/progress_test.exs` ✅ (2 tests)
- `mix test apps/coding_agent/test/coding_agent/checkpoint_test.exs apps/coding_agent/test/coding_agent/tools/todo_store_test.exs apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs` ✅

#### 11. Long-Running Harnesses M5 Introspection Integration
**Plan:** PLN-20260224-long-running-agent-harnesses  
**Status:** in_progress (M5 complete)

Implemented introspection integration by wiring long-running progress snapshots into control-plane method surface and introspection logs:

- Added control-plane method:
  - `apps/lemon_control_plane/lib/lemon_control_plane/methods/agent_progress.ex`
  - Method: `agent.progress`
  - Input: required `sessionId`, optional `cwd`, `runId`, `sessionKey`, `agentId`
  - Output: `CodingAgent.Progress.snapshot/2` payload for the target session
- Introspection integration:
  - Records `:agent_progress_snapshot` events via `LemonCore.Introspection.record/3`
  - Carries run/session metadata when supplied
- Method registration + validation:
  - `apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex`
  - `apps/lemon_control_plane/lib/lemon_control_plane/protocol/schemas.ex`
- Tests:
  - Extended `apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs`
  - Added coverage for method response and emitted introspection event

Validation executed:

- `mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs apps/coding_agent/test/coding_agent/progress_test.exs` ✅ (7 tests)
- `mix test apps/coding_agent/test/coding_agent/checkpoint_test.exs apps/coding_agent/test/coding_agent/tools/todo_store_test.exs apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs apps/coding_agent/test/coding_agent/progress_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs` ✅ (109 tests)

#### 12. Long-Running Harnesses M6 Close-out (Docs + Review/Merge Artifacts)
**Plan:** PLN-20260224-long-running-agent-harnesses  
**Status:** ready_to_land

Completed milestone **M6** by closing documentation and planning artifacts for the long-running harness stream:

- Added operator documentation:
  - `docs/long-running-agent-harnesses.md`
- Updated app-level AGENTS references:
  - `apps/coding_agent/AGENTS.md` (Long-Running Harnesses module map)
  - `apps/lemon_control_plane/AGENTS.md` (`agent.progress` method reference)
- Added planning artifacts:
  - `planning/reviews/RVW-PLN-20260224-long-running-agent-harnesses.md`
  - `planning/merges/MRG-PLN-20260224-long-running-agent-harnesses.md`
- Updated planning board state:
  - `planning/plans/PLN-20260224-long-running-agent-harnesses.md` → status `ready_to_land`
  - `planning/INDEX.md` → moved long-running harness plan from Active Plans to Ready to Land

Validation executed:

- `mix test apps/coding_agent/test/coding_agent/checkpoint_test.exs apps/coding_agent/test/coding_agent/tools/todo_store_test.exs apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs apps/coding_agent/test/coding_agent/progress_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs` ✅ (109 tests)
