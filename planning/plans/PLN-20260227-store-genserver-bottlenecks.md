# PLN-20260227: GenServer Bottleneck Fixes

## Status: DONE

## Context

`LemonCore.Store` and several other singleton GenServers are bottlenecks under load.
The `append_introspection_event` call→cast fix proved the pattern. This plan applies
similar fixes across the codebase.

## Fixes

### 1. Store: append_introspection_event call→cast
- **File:** `apps/lemon_core/lib/lemon_core/store.ex`
- **Status:** DONE
- **Impact:** HIGH — every tool call / model call recorded an introspection event synchronously
- **Change:** Converted from `GenServer.call` to `GenServer.cast`. Client-side validation of required fields (event_id, ts_ms, event_type, provenance, payload) preserves error feedback for malformed events. Server handler returns `{:noreply, ...}`.

### 2. Outbox→RateLimiter→Dedupe triple-bottleneck
- **Files:** `apps/lemon_channels/lib/lemon_channels/outbox.ex`, `outbox/rate_limiter.ex`, `outbox/dedupe.ex`
- **Status:** DONE (220 tests, 0 failures)
- **Impact:** HIGH — every outbound message chains 3 synchronous GenServer.calls
- **Change:** Added explicit timeouts + `catch :exit` fallbacks:
  - RateLimiter: 2s timeout, fail-open (`:ok` on timeout — better to over-send than drop)
  - Dedupe: 2s timeout, fail-open (`:new` on timeout — treat as not-duplicate)
  - Outbox.enqueue: 5s timeout, returns `{:error, :timeout}` (callers already handle error tuples)

### 3. Store: list_introspection_events full-table scan
- **Files:** `apps/lemon_core/lib/lemon_core/store.ex`, `store/sqlite_backend.ex`, `store/backend.ex`
- **Status:** DONE (16 tests, 0 failures)
- **Impact:** MEDIUM-HIGH — blocked the Store GenServer while loading + filtering all events
- **Change:** Added `list_recent/3` optional callback to Backend behaviour. SqliteBackend implements it with `ORDER BY updated_at_ms DESC LIMIT ?2`. Store handler uses it for unfiltered queries (the common dashboard case); falls back to full scan when field-level filters are present (run_id, session_key, etc. are encoded in BLOBs).

### 4. Store: get_run_history full-table scan
- **File:** `apps/lemon_core/lib/lemon_core/store.ex`
- **Status:** DONE (included in fix #3)
- **Impact:** MEDIUM — same pattern as introspection, blocks store for duration of scan
- **Change:** When backend supports `list_recent/3`, prefetches `limit * 20` recent rows to find matching session entries. Falls back to full scan if prefetch doesn't yield enough results.

### 5. Outbox enqueue: timeout protection
- **File:** `apps/lemon_channels/lib/lemon_channels/outbox.ex`
- **Status:** DONE (included in fix #2)
- **Impact:** MEDIUM-HIGH — every outbound message blocks on enqueue call
- **Change:** 5s explicit timeout + `catch :exit` returning `{:error, :timeout}`.

### 6. CronManager: add explicit timeouts
- **File:** `apps/lemon_automation/lib/lemon_automation/cron_manager.ex`
- **Status:** DONE (130 tests, 0 failures)
- **Impact:** MEDIUM — cron ops block with no timeout if store is slow
- **Change:** Added `@call_timeout_ms 10_000` to all 6 GenServer.call sites (list, add, update, remove, run_now, runs).

### 7. Channels Registry: add explicit timeouts
- **File:** `apps/lemon_channels/lib/lemon_channels/registry.ex`
- **Status:** DONE (220 tests, 0 failures)
- **Impact:** MEDIUM — plugin lookup during message routing has no timeout
- **Change:** Added `@call_timeout_ms 5_000` to all 7 GenServer.call sites. `get_plugin/1` (the hot routing path) also has `catch :exit` returning `nil` (plugin not found).

## Out of Scope (future)
- Sharding RateLimiter by channel_id
- Splitting Store into domain-specific GenServers
- Presence full-table scan optimization
