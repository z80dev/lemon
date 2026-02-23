# PLN-20260222: Debt Phase 8 — Store & Persistence Scalability

## Status: Complete

## Goal
Remove known single-process and O(n) persistence bottlenecks so long sessions and high-traffic runtime paths remain performant.

## Milestones

- [x] **M1** — Baseline measurement (identify bottleneck patterns in code)
- [x] **M2** — SessionManager append-only persistence + Store hotspot decomposition
- [x] **M3** — RunGraphServer startup/cleanup backpressure
- [x] **M4** — Tests pass, format clean, documentation updated

## Workstreams

### 1. SessionManager write-path refactor (M2)
- `save_to_file/2` currently rewrites the entire JSONL file on every save
- `append_entry/2` uses `entries ++ [entry]` — O(n) list copy each time
- **Fix applied:**
  - Added `entries_rev` field to Session struct for O(1) prepend storage
  - `append_entry/2` now uses `[entry | entries_rev]` — O(1) instead of O(n)
  - Added `entries/1` function to materialize chronological order on demand
  - Added `entry_count/1` for efficient count without materialization
  - Added `append_to_file/2` for incremental single-line JSONL appends
  - `save_to_file/2` remains for full rewrites (compaction, migration)

### 2. LemonCore.Store hotspot decomposition (M2)
- Single GenServer handles all domains (chat, runs, progress, policies, run_history)
- High-traffic cast paths (append_run_event, put_chat_state) share mailbox with blocking calls
- **Fix applied:**
  - Created `LemonCore.Store.ReadCache` module with public ETS tables
  - High-frequency reads (get_chat_state, get_run, get_run_by_progress) bypass GenServer
  - Writes eagerly update cache before async GenServer cast for consistency
  - GenServer handlers also sync cache on backend writes for durability
  - Cache covers :chat, :runs, :progress domains

### 3. RunGraphServer startup/cleanup backpressure (M3)
- `maybe_load_from_dets/1` does synchronous `:dets.foldl` during init
- `do_cleanup/1` scans full ETS table synchronously in handle_info
- **Fix applied:**
  - DETS loading is now async via `Task.start` during init
  - `ensure_table/1` provides fallback synchronous load if needed before data-dependent calls
  - Periodic cleanup offloaded to async Task (non-blocking handle_info)
  - Cleanup processes records in chunks of 500 with `Process.sleep(0)` between chunks
  - Added `loading` state flag and `cleanup_ref` tracking

## Exit Criteria
- [x] Session append latency is stable as history grows (O(1) prepend via entries_rev)
- [x] Store process mailbox growth under load is bounded (reads bypass GenServer via ReadCache)
- [x] RunGraphServer startup and cleanup no longer block request handling (async load + Task cleanup)

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-22T00:00 | M1 start | Analyzed SessionManager, Store, RunGraphServer source code |
| 2026-02-22T00:10 | M1 done | Identified O(n) append, single-process bottleneck, sync DETS load |
| 2026-02-22T00:20 | M2 start | SessionManager: added entries_rev, entries/1, append_to_file/2 |
| 2026-02-22T00:30 | M2 cont | Store: created ReadCache, wired ETS bypass for reads |
| 2026-02-22T00:40 | M2 done | All Store and SessionManager tests pass |
| 2026-02-22T00:50 | M3 start | RunGraphServer: async DETS load, chunked cleanup |
| 2026-02-22T01:00 | M3 done | All RunGraphServer tests pass |
| 2026-02-22T01:10 | M4 | Updated tests, mix format, documentation |
