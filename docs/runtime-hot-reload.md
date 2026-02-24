# Runtime Hot Reload Guide

This document covers Lemon's runtime code reload capabilities introduced in `PLN-20260224-runtime-hot-reload`.

## Overview

Lemon supports reloading Elixir modules and extension source files without restarting the VM.

Core capabilities:
- reload individual BEAM modules
- reload extension source files (`.ex` / `.exs`)
- reload all modules for an OTP app
- orchestrated system-level reload under a global lock
- control-plane JSON-RPC access via `system.reload`

## Core API

Module: `Lemon.Reload` (`apps/lemon_core/lib/lemon_core/reload.ex`)

Primary functions:
- `reload_module/2`
- `reload_extension/2`
- `reload_app/2`
- `reload_system/1`
- `soft_purge_module/2`

Reload operations emit telemetry:
- `[:lemon, :reload, :start]`
- `[:lemon, :reload, :stop]`
- `[:lemon, :reload, :exception]`

## Control Plane Method

Method: `system.reload`

Implementation:
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/system_reload.ex`

Tests:
- `apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs`

Example request:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "system.reload",
  "params": {
    "modules": ["MyApp.SomeModule"],
    "extensions": ["/absolute/path/to/skill.ex"],
    "apps": ["lemon_core"]
  }
}
```

## Safety Model

`reload_system/1` runs under a global lock (`:global.trans`) to avoid concurrent reload races across processes/nodes.

Recommended operational practice:
1. Prefer targeted reloads (`modules`/`extensions`) over full app reloads.
2. Run targeted smoke tests after reload.
3. Use telemetry to monitor reload timing and failures.

## Validation Commands

```bash
mix test apps/lemon_core/test/lemon_core/reload_test.exs
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs
```
