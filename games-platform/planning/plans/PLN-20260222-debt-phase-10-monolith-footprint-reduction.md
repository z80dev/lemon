# PLN-20260222: Debt Phase 10 — Monolith and Release Footprint Reduction

**Date:** 2026-02-22
**Owner:** janitor
**Reviewer:** janitor
**Status:** ready_to_land

---

## Goal

Improve maintainability and release ergonomics by decomposing oversized modules, externalizing bundled JS assets, and cleaning up stale config/doc drift.

---

## Milestones

- [x] **M1** — Config/doc drift cleanup
- [x] **M2** — Gateway JS asset analysis and externalization strategy
- [x] **M3** — Ai.Models data layer decomposition plan
- [x] **M4** — Release footprint measurement and baseline

---

## M1: Config/Doc Drift Cleanup

### Scope

1. **Stale MarketIntel config comment cleanup**
   - `apps/market_intel/config/config.exs` lines 51-54: trailing comment referencing "old flat keys (enable_dex, enable_polymarket, etc.)" that are no longer read. The migration is complete — the `:ingestion` map in `config/config.exs` is the canonical source. Remove the stale migration comment.

2. **Legacy `x_account_id` backfill in `MarketIntel.Config`**
   - `apps/market_intel/lib/market_intel/config.ex` lines 105-110: `maybe_backfill_legacy_x_account_id/1` reads a flat `:x_account_id` key from Application env. No config file sets this key — it is a migration shim from before the `:x` nested config existed. The backfill is dead code.
   - Decision: Keep the backfill for now (it is defensive and has no runtime cost). Add a comment marking it as legacy debt. A future cleanup can remove it when the test coverage is also updated.

3. **MarketIntel README stale "Future Enhancements" section**
   - `apps/market_intel/README.md` lines 218-229: Contains a wish-list with unchecked items that are not tracked as backlog items. Convert to a tracked backlog reference pointing to the debt plan.

4. **MarketIntel AGENTS.md stub documentation**
   - `apps/market_intel/AGENTS.md` lines 48, 58, 62-67, 230, 263: Documents multiple stubs (Twitter fetch, DB persistence, holder stats, deep analysis). These are accurate descriptions of current state. Mark the stubs as known debt items with a reference to this plan.

5. **MarketIntel SECRETS_GUIDE.md and SETUP.md**
   - Largely accurate and well-written. No stale content found.

### Findings: Codebase-Wide TODO/FIXME Scan

A comprehensive scan of all `.ex` and `.exs` files under `apps/` found:
- **Zero TODO/FIXME/HACK comments** in source code (the only hits were in `truncate.ex` which detects TODO comments in user code for smart truncation, not an actual TODO)
- **Zero stale adapter TODOs** — the codebase is clean of scattered TODO markers
- The `@deprecated "Use list_models/0"` annotation in `Ai.Models` is correct and functional

### Actions Taken

- Removed stale migration comment from `apps/market_intel/config/config.exs`
- Added legacy debt annotation to `maybe_backfill_legacy_x_account_id` in `apps/market_intel/lib/market_intel/config.ex`
- Replaced "Future Enhancements" wish-list in `apps/market_intel/README.md` with tracked backlog reference
- Added stub status annotations in `apps/market_intel/AGENTS.md`

---

## M2: Gateway JS Asset Analysis

### Current State

The `apps/lemon_gateway/priv/` directory contains:

| File | Size | Purpose |
|------|------|---------|
| `xmtp_bridge.mjs` | 28 KB (981 lines) | XMTP transport bridge, launched via `Port` from `PortServer` |
| `package.json` | 228 B | Declares `@xmtp/node-sdk` (5.3.0) and `viem` (2.31.7) |
| `package-lock.json` | 8.6 KB | Lock file for above deps |
| `diagnose_voice.sh` | 2.4 KB | Voice diagnostic script |
| `setup_voice_tunnel.sh` | 5.2 KB | Voice tunnel setup |
| `start_voice_localtunnel.sh` | 5.5 KB | Localtunnel launcher |
| `start_voice_only.sh` | 1.4 KB | Voice-only starter |
| `webhooks/` | 1 KB | Webhook templates (Make.com, n8n, Zapier) |

**Total priv size:** 80 KB

### Key Finding: node_modules is Already Externalized

The debt plan references `priv/node_modules` as a committed footprint concern. However:
- `node_modules/` is in `.gitignore` and is **not committed to the repository**
- The `package.json` + `package-lock.json` are committed (total: ~9 KB) for reproducible `npm install` at deployment
- The `xmtp_bridge.mjs` is a single-file bridge (28 KB) loaded via `Application.app_dir(:lemon_gateway, "priv/xmtp_bridge.mjs")` in `PortServer`

### Assessment

The gateway JS footprint is **already minimal** at 80 KB total (priv). The original debt signal about "large bundled JS runtime assets" was based on a state where `node_modules` may have been committed; that has since been resolved. No further externalization is needed at this time.

### Recommendations

1. **No action required** — the priv directory is lean and `node_modules` are already externalized
2. If the XMTP bridge grows, consider: (a) building it into a self-contained bundle, or (b) moving it to a separate npm package/service
3. The shell scripts in priv (voice-related, ~14 KB) could be moved to a `scripts/` directory if they are not needed at runtime via `Application.app_dir`

---

## M3: Ai.Models Data Layer Decomposition Plan

### Current Structure

`apps/ai/lib/ai/models.ex` — **11,203 lines**, decomposed as:

| Section | Lines (approx) | Content |
|---------|------|---------|
| Module header + aliases | 1-34 | Moduledoc, aliases, constants |
| `@anthropic_models` | 35-329 | 20+ Anthropic model definitions |
| `@kimi_coding_models` | 330-360 | Kimi coding models |
| `@openai_models` | 361-799 | 40+ OpenAI model definitions |
| `@amazon_bedrock_models` (initial) | 800-1579 | 60+ Bedrock model definitions |
| `@google_models` | 1580-1883 | 25+ Google models |
| `@kimi_models` | 1884-1926 | Kimi models |
| `@opencode_models` | 1927-2317 | 30+ Opencode models |
| `@xai_models` | 2318-2516 | 15+ xAI models |
| `@mistral_models` | 2517-2607 | Mistral models |
| `@cerebras_models` | 2608-2650 | Cerebras models |
| `@deepseek_models` | 2651-2693 | DeepSeek models |
| `@qwen_models` | 2694-2760 | Qwen models |
| `@minimax_models` | 2761-2803 | Minimax models |
| `@zai_models` | 2804-2866 | ZAI models |
| Provider models extension block | 2867-10687 | Large Map.merge blocks extending provider maps |
| Combined registry + provider list | 10688-10769 | `@models` map, `@providers` list |
| Public API functions | 10770-11202 | ~430 lines of query/utility functions |

**Total model definitions:** ~795 `%Model{}` structs across 25 providers.

### Decomposition Strategy

The file has a clear separation between **data** (lines 35-10687, ~10,650 lines = 95%) and **logic** (lines 10688-11202, ~515 lines = 5%).

**Recommended approach:** Extract per-provider data modules into `apps/ai/lib/ai/models/` directory:

```
apps/ai/lib/ai/models/
  anthropic.ex          # defmodule Ai.Models.Anthropic — returns @anthropic_models map
  openai.ex             # defmodule Ai.Models.OpenAI
  amazon_bedrock.ex     # defmodule Ai.Models.AmazonBedrock
  google.ex             # defmodule Ai.Models.Google
  opencode.ex           # defmodule Ai.Models.Opencode
  xai.ex                # defmodule Ai.Models.XAI
  ...                   # (one module per provider)
```

Each module would:
1. Define a `models/0` function returning the `%{model_id => %Model{}}` map
2. Import `Ai.Types.{Model, ModelCost}` for struct definitions
3. Contain only data — no logic

The parent `Ai.Models` module would:
1. Import all provider modules
2. Build the combined `@models` registry at compile time
3. Retain all public API functions unchanged
4. Shrink to ~500-600 lines (orchestration + API)

### Coordination Note

Phase 5 M2 is working on the actual extraction. This analysis provides the decomposition blueprint for that work. The key insight is that the module is **95% data, 5% logic** — the extraction is mechanical and low-risk.

### Estimated Impact

- `Ai.Models` main module: 11,203 lines -> ~500-600 lines (95% reduction)
- Compilation: Faster incremental recompilation when only one provider's data changes
- Diffs: Provider-specific changes isolated to their own files
- No behavioral changes — public API remains identical

---

## M4: Release Footprint Measurement

### Source Code Measurements

| Component | Size | Notes |
|-----------|------|-------|
| `apps/ai/lib/ai/models.ex` | 11,203 lines (373 KB) | 795 model structs, 25 providers |
| `apps/coding_agent/lib/coding_agent/session.ex` | 3,261 lines (115 KB) | Mixed GenServer + WASM + compaction + serialization |
| `apps/lemon_gateway/priv/` | 80 KB total | xmtp_bridge.mjs (28 KB) + package files (9 KB) + scripts (14 KB) |
| All `apps/*/lib/**/*.ex` | ~154,243 lines | Full codebase source |
| All `apps/*/test/**/*.exs` | ~212,357 lines | Full test suite |

### priv/ Directory Footprint (All Apps)

| App | priv/ Size |
|-----|-----------|
| `coding_agent` | 36 KB |
| `lemon_gateway` | 80 KB |
| `lemon_skills` | 84 KB |
| `lemon_web` | 4 KB |
| `market_intel` | 8 KB |
| **Total** | **212 KB** |

### Key Finding

The release footprint concern is primarily about **source code complexity** (models.ex at 11K lines, session.ex at 3.2K lines) rather than binary artifact size. The `priv/` directories are lean, and `node_modules/` is already gitignored. The main win from decomposition is **maintainability and compilation speed**, not artifact size reduction.

---

## CodingAgent.Session Decomposition Analysis

### Current Structure (3,261 lines)

The session.ex contains several distinct concern areas:

| Concern | Lines (approx) | Functions |
|---------|------|-----------|
| Public API + GenServer callbacks | 1-520 | start_link, prompt, steer, abort, subscribe, init |
| Handle_call/cast/info handlers | 521-1530 | Core GenServer message handling |
| Health/diagnostics | 1534-1600 | build_diagnostics, count_tool_results, etc. |
| Model resolution | 1602-1700 | resolve_session_model, lookup_model, etc. |
| Provider/API key resolution | 1700-1900 | provider_env_vars, resolve_secret_api_key, etc. |
| System prompt composition | 1897-1970 | compose_system_prompt, refresh_system_prompt |
| Event broadcasting + UI | 1970-2070 | broadcast_event, complete_event_streams, etc. |
| Message serialization/deserialization | 2070-2360 | serialize_message, deserialize_message, etc. |
| Tree navigation + branch summarization | 2360-2450 | is_branch_switch?, maybe_summarize_abandoned_branch |
| Auto-compaction lifecycle | 2450-2860 | maybe_trigger_compaction, apply_compaction_result, etc. |
| WASM sidecar lifecycle | 2860-3110 | maybe_start_wasm_sidecar, reload_wasm_tools, etc. |
| Overflow recovery | 2540-2730 | maybe_start_overflow_recovery, continue_after_overflow_compaction, etc. |
| Background task management | 3110-3261 | start_background_task, start_tracked_background_task, etc. |

### Recommended Extraction Targets

1. **`CodingAgent.Session.Serialization`** (~290 lines) — All serialize_*/deserialize_* functions
2. **`CodingAgent.Session.WasmLifecycle`** (~250 lines) — WASM sidecar start/reload/tool creation
3. **`CodingAgent.Session.CompactionLifecycle`** (~400 lines) — Auto-compaction + overflow recovery
4. **`CodingAgent.Session.ModelResolver`** (~300 lines) — Model/provider/API key resolution
5. **`CodingAgent.Session.BackgroundTasks`** (~150 lines) — Task supervisor helpers

### Coordination Note

Phase 5 M2 is working on the actual Session extraction. This analysis provides the decomposition blueprint.

---

## Progress Log

### 2026-02-22 — Initial Analysis and M1 Cleanup

- Completed codebase-wide scan for TODO/FIXME/HACK markers — found zero scattered TODO debt
- Analyzed `Ai.Models` structure: 795 model definitions, 25 providers, 95% data / 5% logic
- Analyzed `CodingAgent.Session` structure: identified 5 extraction targets totaling ~1,390 lines
- Measured gateway priv footprint: 80 KB total, node_modules already externalized via .gitignore
- Cleaned stale config comment in `apps/market_intel/config/config.exs`
- Added legacy debt annotation to `MarketIntel.Config.maybe_backfill_legacy_x_account_id`
- Replaced untracked wish-list in `apps/market_intel/README.md` with backlog reference
- Added stub status annotations in `apps/market_intel/AGENTS.md`
- M1 config/doc drift cleanup complete
- M2 gateway JS analysis complete — no action needed
- M3 Ai.Models decomposition plan complete — blueprint ready for Phase 5 M2
- M4 release footprint measurement complete

### 2026-02-22 — Validation and Phase Wrap-Up

- Validated all four changed files:
  - `apps/market_intel/config/config.exs`: stale migration comment removed cleanly; canonical `:ingestion` note in place
  - `apps/market_intel/lib/market_intel/config.ex`: legacy debt annotation on `maybe_backfill_legacy_x_account_id/1` is accurate and correctly references this plan
  - `apps/market_intel/README.md`: "Future Enhancements" wish-list replaced with tracked backlog reference pointing to M1 and `AGENTS.md`
  - `apps/market_intel/AGENTS.md`: stub status annotations are accurate and cross-reference this plan
- `mix compile --no-optional-deps` — exit 0, no warnings
- `mix test apps/market_intel` — exit 0, no regressions
- All milestones marked complete; plan status set to Complete
- Remaining items deferred to future phases:
  - Actual `Ai.Models` per-provider extraction (Phase 5 M2, blueprint in M3)
  - Actual `CodingAgent.Session` sub-module extraction (Phase 5 M2, blueprint in CodingAgent section)
  - Removal of `maybe_backfill_legacy_x_account_id/1` once all environments confirmed migrated (M1 note)
  - Shell scripts in `lemon_gateway/priv/` could move to `scripts/` if not needed at runtime (M2 note)

### 2026-02-25 — Planning-System Close-Out Alignment

- Re-claimed plan ownership under `janitor` for planning-board consistency.
- Normalized plan metadata status from legacy `Complete` to planning-system `ready_to_land`.
- Added missing review artifact: `planning/reviews/RVW-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md`.
- Added missing merge artifact: `planning/merges/MRG-PLN-20260222-debt-phase-10-monolith-footprint-reduction.md`.
- Updated `planning/INDEX.md` active row to `ready_to_land` and added Ready-to-Land table entry.
- Re-ran canonical validation suite for this plan:
  - `mix compile --no-optional-deps` ✅
  - `mix test apps/market_intel` ✅
