# JANITOR.md - Implementation Agent Work Log

## 2026-02-24

### Completed Work

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

---

#### 7. Runtime Hot-Reload - M8 Documentation and Review Close-out
**Plan:** PLN-20260224-runtime-hot-reload  
**Status:** ready_to_land

Completed M8 and moved the plan to `ready_to_land`.

**Artifacts Added:**
- `docs/runtime-hot-reload.md`
- `planning/reviews/RVW-PLN-20260224-runtime-hot-reload.md`
- `planning/merges/MRG-PLN-20260224-runtime-hot-reload.md`

**Docs Updated:**
- `docs/README.md`
- `docs/catalog.exs`
- `planning/plans/PLN-20260224-runtime-hot-reload.md`
- `planning/INDEX.md`
