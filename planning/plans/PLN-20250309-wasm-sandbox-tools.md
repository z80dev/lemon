---
id: PLN-20250309-wasm-sandbox-tools
title: WASM Tools MCP Integration and Registry
status: in_progress
author: janitor
owner: janitor
workspace: feature/pln-20250309-wasm-sandbox-tools
change_id: pending
created: 2026-03-09
updated: 2026-03-09
---

# WASM Tools MCP Integration and Registry

Integrate Lemon's WASM tool execution with the Model Context Protocol (MCP) for standardized tool discovery and invocation. Adds dynamic WASM module registry and MCP-compatible tool exposure.

## Summary

Lemon already has a sophisticated WASM runtime using wasmtime with component model support. This plan adds:

1. **MCP Server for WASM Tools**: Expose WASM tools via MCP protocol
2. **WASM Module Registry**: Dynamic loading and caching of WASM modules
3. **MCP Client Integration**: Consume external MCP servers as WASM-compatible tools
4. **Tool Composition**: Chain WASM tools with MCP tools seamlessly

## Current State

Lemon has robust WASM infrastructure:
- `lemon-wasm-runtime`: Rust-based wasmtime runtime with component model
- `CodingAgent.Wasm.SidecarSession`: Elixir integration for WASM tool execution
- WIT interface with host capabilities (HTTP, exec, secrets, logging)
- Resource limits, security policies, and sandboxing

## Scope

### In Scope
- MCP server endpoint for exposing WASM tools
- WASM module registry with dynamic loading
- MCP client integration for external tool consumption
- Tool composition between WASM and MCP sources
- Telemetry for WASM tool execution
- Tests for all new functionality

### Out of Scope
- Browser-based WASM execution
- WASM tool marketplace UI
- Language-specific WASM SDKs
- Distributed WASM execution

## Success Criteria
- [ ] WASM tools exposed via MCP server endpoint
- [ ] Dynamic WASM module loading from registry
- [ ] External MCP tools consumed as Lemon tools
- [ ] Tool composition works across WASM/MCP boundaries
- [ ] Telemetry events for WASM tool lifecycle
- [ ] All tests pass (>20 new tests)
- [ ] Documentation for WASM + MCP integration

## Milestones

### M1: WASM MCP Server ✅
- [x] Create `LemonMCP.WasmServer` module
- [x] Expose WASM tools via MCP tools/list endpoint
- [x] Implement MCP tools/call for WASM invocation
- [x] Add WASM tool metadata to MCP responses
- [x] Write tests for MCP server integration (16 tests)

### M2: WASM Module Registry
- [ ] Create `CodingAgent.Wasm.Registry` module
- [ ] Implement dynamic module loading
- [ ] Add module caching and versioning
- [ ] Support registry sources (local, HTTP, IPFS)
- [ ] Write tests for registry operations

### M3: MCP Client for External Tools
- [ ] Extend `LemonMCP.Client` to support tool consumption
- [ ] Convert MCP tools to WASM-compatible format
- [ ] Implement tool aliasing for MCP tools
- [ ] Add MCP tool caching
- [ ] Write tests for MCP client integration

### M4: Tool Composition
- [ ] Enable WASM tools to invoke MCP tools
- [ ] Enable MCP tools to invoke WASM tools
- [ ] Unified tool namespace across sources
- [ ] Cross-source tool chaining
- [ ] Write tests for tool composition

### M5: Telemetry and Observability
- [ ] Add telemetry for WASM tool execution
- [ ] Add telemetry for MCP operations
- [ ] Expose metrics: load time, execution time, cache hits
- [ ] Integrate with Lemon's telemetry system
- [ ] Write tests for telemetry events

### M6: Documentation and Polish
- [ ] Document WASM + MCP integration
- [ ] Add examples of tool composition
- [ ] Document registry configuration
- [ ] Final review and landing

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-09 00:00 | janitor | Created plan | planned | - |
| 2026-03-09 00:10 | janitor | Started M1: WASM MCP Server | in_progress | - |
| 2026-03-09 00:30 | janitor | Completed M1: WASM MCP Server | completed | f0474b19, 4583cc68 |

### M1 Completed

**LemonMCP.WasmServer** module implemented:
- MCP server that exposes WASM tools via Model Context Protocol
- Tool discovery from WASM paths
- Tool invocation with proper context
- Telemetry events for execution tracking
- Statistics and monitoring
- 16 comprehensive tests, all passing

**Files Added:**
- `apps/lemon_mcp/lib/lemon_mcp/wasm_server.ex` - Main server implementation
- `apps/lemon_mcp/test/lemon_mcp/wasm_server_test.exs` - Test suite

## Related
- Parent plan: -
- Related plans: PLN-20260301-mcp-tool-integration, IDEA-20260224-community-wasm-sandbox-tools
- References:
  - https://modelcontextprotocol.io/
  - https://github.com/modelcontextprotocol/specification
