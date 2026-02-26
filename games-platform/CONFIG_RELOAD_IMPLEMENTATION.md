# Lemon Config Reload Implementation

**Status:** Phase 1 & 2 Complete
**Started:** 2026-02-22
**Design Doc:** [CONFIG_RELOAD_DESIGN.md](./CONFIG_RELOAD_DESIGN.md)

---

## Overview

This document tracks the implementation of the Lemon runtime config reload system. The implementation follows the design in `CONFIG_RELOAD_DESIGN.md` and is being executed in phases.

---

## Implementation Progress

### Phase 1: Core Infrastructure (Manual API)
- [x] `LemonCore.ConfigReloader` GenServer
- [x] Reload lock and serialization
- [x] Source digest tracking (files, env, secrets)
- [x] Redacted diff computation
- [x] Event broadcast on `LemonCore.Bus`
- [x] `config.reload` control-plane method
- [x] Status API and telemetry

### Phase 2: Change Detection
- [x] File watcher integration (`file_system`)
- [x] Polling fallback (5s interval)
- [x] Debounce logic (250ms)
- [x] `.env` file watching
- [x] TOML config file watching
- [x] Secrets event emission on `set/3` and `delete/2`
- [x] Supervision tree updated

### Phase 3: Subscribers & Propagation
- [ ] `LemonGateway.ConfigSubscriber`
- [ ] `LemonRouter.ConfigSubscriber`
- [ ] `LemonChannels.ConfigSubscriber`
- [ ] `LemonGateway.Config.reload/0`
- [ ] Scheduler max_concurrent update

### Phase 4: Secrets Integration
- [ ] Digest polling (10s)
- [ ] Secret-dependent component mapping

### Phase 5: Advanced Reconcile
- [ ] Transport supervisor reconcile
- [ ] Adapter enable/disable transitions
- [ ] WS event mapping
- [ ] Authoritative dotenv mode
- [ ] SIGHUP hook

---

## Task Log

### Task 1: Phase 1 + Phase 2 Implementation
- **Agent:** Claude
- **Completed:** 2026-02-22
- **Status:** Done
- **Scope:** Phase 1 (Core Infrastructure) + Phase 2 (Change Detection)

---

## Files Created

| File | Status | Notes |
|------|--------|-------|
| `apps/lemon_core/lib/lemon_core/config_reloader.ex` | Done | Main orchestrator GenServer |
| `apps/lemon_core/lib/lemon_core/config_reloader/digest.ex` | Done | Source fingerprinting (mtime+size+SHA256) |
| `apps/lemon_core/lib/lemon_core/config_reloader/watcher.ex` | Done | File watcher with polling fallback |
| `apps/lemon_control_plane/lib/lemon_control_plane/methods/config_reload.ex` | Done | Control-plane method |
| `apps/lemon_core/test/lemon_core/config_reloader_test.exs` | Done | ConfigReloader tests |
| `apps/lemon_core/test/lemon_core/config_reloader/digest_test.exs` | Done | Digest tests |

## Files Modified

| File | Status | Notes |
|------|--------|-------|
| `apps/lemon_core/lib/lemon_core/application.ex` | Done | Added ConfigReloader + Watcher to supervision tree |
| `apps/lemon_core/lib/lemon_core/secrets.ex` | Done | Added event emission on set/delete |
| `apps/lemon_core/mix.exs` | Done | Added `file_system` optional dependency |
| `apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex` | Done | Added ConfigReload to builtin methods |
| `apps/lemon_control_plane/lib/lemon_control_plane/protocol/schemas.ex` | Done | Added config.reload schema |

---

## Testing Status

| Test Suite | Status | Notes |
|------------|--------|-------|
| Unit: Digest file fingerprint | Done | Tests existing, missing, content changes |
| Unit: Digest source comparison | Done | Tests change detection across sources |
| Unit: Redaction | Done | Tests sensitive field masking |
| Unit: Diff computation | Done | Tests added/removed/changed keys |
| Integration: Bus event broadcast | Done | Tests config_reloaded event |
| Integration: Force reload | Done | Tests forced reload path |
| Integration: Source scoping | Done | Tests reload with specific sources |

---

## Notes & Decisions

1. **Lock mechanism**: Used simple boolean in GenServer state. GenServer already serializes
   `handle_call`, so the lock primarily guards against async cast overlap.

2. **Content hashing**: Added SHA-256 hash on top of ConfigCache's mtime+size fingerprint
   for more reliable change detection (handles same-second writes).

3. **Watcher directories**: Watches parent directories (not individual files) since editors
   typically use temp-file-rename patterns.

4. **Secret events**: Wrapped Bus broadcast in `rescue` to never block secret operations.

5. **file_system as optional**: Marked `optional: true` so watcher gracefully falls back
   to polling when native library is unavailable.

---

## References

- [CONFIG_RELOAD_DESIGN.md](./CONFIG_RELOAD_DESIGN.md) - Full design document
- [file_system hex docs](https://hexdocs.pm/file_system/readme.html)
- [Elixir config and releases](https://hexdocs.pm/elixir/main/config-and-releases.html)
