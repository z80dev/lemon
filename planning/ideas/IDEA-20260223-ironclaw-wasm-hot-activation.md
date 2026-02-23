---
id: IDEA-20260223-ironclaw-wasm-hot-activation
title: [IronClaw] Hot-Activate WASM Channels with Channel-First Prompts
source: ironclaw
source_commit: ea57447
discovered: 2026-02-23
status: completed
---

# Description
IronClaw added hot-activation for WASM channels and channel-first prompts (commit ea57447). This feature:
- Hot-activates WASM channels without restart
- Adds channel-first prompts for better UX
- Unifies artifact resolution into registry module
- Fixes multiple bugs with CARGO_TARGET_DIR and WASM triples
- 1,411 lines of changes across 29 files

Key changes in upstream:
- New `src/registry/artifacts.rs` module
- Modified `src/extensions/manager.rs` for hot-activation
- Added channel runtime wiring in `main.rs`
- Fixed bundled.rs to search all WASM triples

# Lemon Status
- Current state: **ALREADY IMPLEMENTED** - Lemon has comprehensive WASM hot-reload
- Implementation details:

## Extension Hot-Reload
- `CodingAgent.Extensions.clear_extension_cache/0` - Soft-purges and clears extension cache
- `CodingAgent.Extensions.load_extension_file_safe/1` - Uses `Reload.reload_extension/1`
- Extensions can be reloaded without BEAM restart

## WASM Tool Factory
- `CodingAgent.Wasm.ToolFactory` - Builds AgentTool wrappers for WASM tools
- `CodingAgent.Wasm.SidecarSession` - Manages WASM sidecar lifecycle
- Dynamic tool discovery and invocation

## Runtime Reload System
- `Lemon.Reload.reload_extension/2` - Compile and reload `.ex`/`.exs` files
- `Lemon.Reload.reload_system/1` - Orchestrated reload under global lock
- Control plane `system.reload` JSON-RPC method

## Session Integration
- `CodingAgent.Session` handles extension lifecycle
- `CodingAgent.ExtensionLifecycle` manages extension loading/unloading
- WASM tools discovered and loaded per-session

# Verification Results

## 1. Extension Hot-Reload
✅ **Implemented** - `clear_extension_cache/0` + `load_extensions_with_errors/1`
✅ **Soft purge** - Safe module unloading with `Reload.soft_purge_module/1`
✅ **Source tracking** - ETS table tracks extension source paths
✅ **Error handling** - Load errors captured and reported

## 2. WASM Support
✅ **Tool factory** - Dynamic WASM tool wrapper generation
✅ **Sidecar session** - WASM sidecar process management
✅ **Tool discovery** - Runtime WASM tool discovery
✅ **Invoke mechanism** - `SidecarSession.invoke/4` for WASM calls

## 3. Comparison with IronClaw
| Feature | IronClaw | Lemon | Status |
|---------|----------|-------|--------|
| Extension hot-reload | ✅ | ✅ | Parity |
| WASM channel activation | ✅ | ✅ | Parity |
| Channel-first prompts | ✅ | N/A | Different architecture |
| Artifact registry | ✅ | ✅ (ToolRegistry) | Parity |
| Runtime reload API | ✅ | ✅ | Parity |

# Recommendation
**No action needed** - Lemon already has full WASM hot-activation and extension reload capabilities.

Key differences:
- IronClaw uses Rust/WASM with channel-first prompts
- Lemon uses BEAM/Elixir with extension-based WASM tools
- Both support hot-reload without restart
- Lemon's `Lemon.Reload` system is more comprehensive (modules, apps, extensions, code_change)

# References
- IronClaw commit: ea57447
- Lemon implementation:
  - `apps/coding_agent/lib/coding_agent/extensions.ex` (lines 45, 979, 1106)
  - `apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex`
  - `apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex`
  - `apps/lemon_core/lib/lemon_core/reload.ex`
