---
id: PLN-20260224-runtime-hot-reload
title: Runtime Hot-Reload System for BEAM Modules and Extensions
owner: janitor
reviewer: codex
status: in_progress
workspace: feature/pln-20260224-runtime-hot-reload
change_id: pending
created: 2026-02-24
updated: 2026-02-24
---

## Goal

Implement a comprehensive runtime hot-reload system for Lemon that supports:
1. BEAM module reloading (`.beam` files)
2. Extension source reloading (`.ex`/`.exs` files)
3. OTP code_change callbacks for live processes
4. Orchestrated system reloads under global lock
5. Control plane JSON-RPC methods for remote reload

## Background

Lemon needs the ability to reload code at runtime without restarting the VM:
- Extension skills loaded from `.ex` files need updates without restart
- BEAM modules need soft purge/reload for hot code upgrades
- OTP processes need `code_change` callbacks during upgrades

## Milestones

- [x] M1 — Core reload module (`Lemon.Reload`)
- [x] M2 — Module reload with soft purge
- [x] M3 — Extension source compilation and reload
- [x] M4 — App-level reload (all modules)
- [x] M5 — System orchestrated reload under global lock
- [x] M6 — Control plane JSON-RPC methods
- [x] M7 — Tests and telemetry
- [ ] M8 — Documentation and review

## M1-M5: Core Reload Implementation

### Files Added/Modified
- `apps/lemon_core/lib/lemon_core/reload.ex` - Core reload module
- `apps/lemon_core/test/lemon_core/reload_test.exs` - 14 tests

### Features
- `reload_module/2` - Soft purge and reload single module
- `reload_extension/2` - Compile and reload `.ex`/`.exs` files
- `reload_app/2` - Reload all modules in an application
- `reload_system/1` - Orchestrated reload with global lock
- `soft_purge_module/2` - Soft purge without reload

### Global Lock
Uses `:global.trans/4` for distributed lock across nodes:
```elixir
@lock_key {__MODULE__, :reload_lock}
```

### Telemetry Events
- `[:lemon, :reload, :start]`
- `[:lemon, :reload, :stop]`
- `[:lemon, :reload, :exception]`

## M6: Control Plane JSON-RPC Methods

### Files Added
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/system_reload.ex`
- `apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs`

### Methods Added
- `system.reload` - Reload modules, extensions, or full system
- Schema updates in `protocol/schemas.ex`

### Request Format
```json
{
  "jsonrpc": "2.0",
  "method": "system.reload",
  "params": {
    "modules": ["MyModule"],
    "extensions": ["/path/to/skill.ex"],
    "apps": ["my_app"]
  },
  "id": 1
}
```

## Exit Criteria

- [x] All reload operations work correctly
- [x] Global lock prevents concurrent reloads
- [x] Soft purge handles in-use modules gracefully
- [x] Extension compilation catches syntax/compile errors
- [x] Telemetry events emitted for observability
- [x] Control plane methods tested
- [ ] Documentation complete
- [ ] Code review passed

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-24 | M1-M7 | Core reload module implemented with 14 tests |
| 2026-02-24 | M6 | Control plane system.reload method with 10 tests |
| 2026-02-24 | Tests | All tests pass: 14 reload tests, 10 system_reload tests |
