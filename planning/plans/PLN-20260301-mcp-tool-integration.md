---
id: PLN-20260301-mcp-tool-integration
title: MCP (Model Context Protocol) Tool Integration
status: in_progress
created: 2026-03-01
author: janitor
owner: janitor
workspace: lemon-mcp-integration
change_id: pending
---

# MCP Tool Integration

Implement Model Context Protocol (MCP) support for Lemon to enable standardized tool discovery and invocation across AI agents.

## Summary

MCP is emerging as an industry standard for AI agent tool integration. This plan implements:
1. MCP client for consuming external MCP servers/tools
2. MCP server capability for exposing Lemon tools to external consumers
3. Tool registry integration for MCP-compatible tools
4. Dynamic tool discovery from MCP servers

## Scope

### In Scope
- MCP client implementation (stdio and HTTP transports)
- MCP server implementation for exposing Lemon tools
- Tool registry integration with MCP discovery
- JSON-RPC message handling per MCP spec
- Tool listing and invocation protocol
- Resource and prompt capabilities (basic)
- Configuration schema for MCP servers
- Tests for MCP protocol handling

### Out of Scope
- Full MCP resource subscription lifecycle
- Advanced prompt templating system
- Binary/data transport optimizations
- MCP marketplace/directory integration
- Authentication/authorization for MCP servers (phase 2)

## Success Criteria
- [ ] Can connect to external MCP servers via stdio
- [ ] Can discover and invoke tools from MCP servers
- [ ] Lemon tools can be exposed via MCP server endpoint
- [ ] Tool registry includes MCP-discovered tools
- [ ] Configuration supports MCP server definitions
- [ ] Tests cover protocol message handling
- [ ] Documentation for MCP integration

## Milestones

### M1: MCP Client Foundation
- [ ] Define MCP message types (Request, Response, Notification, Error)
- [ ] Implement JSON-RPC framing for stdio transport
- [ ] Implement initialize handshake
- [ ] Add tool/list and tool/call support
- [ ] Create `LemonMcp.Client` module

### M2: MCP Server Foundation
- [ ] Implement server-side initialize handling
- [ ] Add tool listing endpoint
- [ ] Add tool invocation endpoint
- [ ] Create `LemonMcp.Server` module
- [ ] Integrate with existing Lemon tools

### M3: Tool Registry Integration
- [ ] Extend skill/tool registry for MCP sources
- [ ] Dynamic tool discovery from configured MCP servers
- [ ] Tool caching and refresh logic
- [ ] Error handling for unavailable MCP servers

### M4: Configuration and Polish
- [ ] Config schema for MCP server definitions
- [ ] Transport configuration (stdio command, HTTP URL)
- [ ] Logging and telemetry for MCP operations
- [ ] Documentation and examples

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-01 22:00 | janitor | Created plan | planned | - |

## Related
- Parent plan: -
- Related plans: IDEA-20260224-community-mcp-tool-integration
- References:
  - https://modelcontextprotocol.io/
  - https://github.com/modelcontextprotocol/specification
