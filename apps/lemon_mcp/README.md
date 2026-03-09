# LemonMCP

MCP (Model Context Protocol) client and server bridge for the Lemon codebase.

## Overview

LemonMCP provides both client and server implementations for the Model Context Protocol (MCP), an open protocol that enables seamless integration between LLM applications and external data sources and tools. On the server side, it exposes CodingAgent tools over MCP so external clients can use them.

This library targets MCP protocol version **"2024-11-05"**.

## Installation

Add `lemon_mcp` to your mix dependencies:

```elixir
def deps do
  [
    {:lemon_mcp, in_umbrella: true}
  ]
end
```

## Dependencies

- `coding_agent` (in_umbrella) - Tools exposed via MCP server
- `agent_core` (in_umbrella) - Agent runtime support
- `jason` - JSON encoding/decoding
- `bandit` / `plug` - HTTP transport server
- `uuid` - Request ID generation

## Modules

- `LemonMCP` - Main module with protocol version
- `LemonMCP.Application` - OTP application supervision tree
- `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
- `LemonMCP.Client` - GenServer client for managing MCP connections
- `LemonMCP.Server` - MCP server process
- `LemonMCP.Server.Handler` - Server request handler
- `LemonMCP.ToolAdapter` - Adapter that exposes CodingAgent tools over MCP
- `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
- `LemonMCP.Transport.Http` - HTTP/SSE transport for MCP servers

## Usage

### Starting a Client Connection

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
)
```

### Listing Available Tools

```elixir
{:ok, tools} = LemonMCP.Client.list_tools(client)
# Returns a list of tool definitions with name, description, and inputSchema
```

### Calling a Tool

```elixir
{:ok, result} = LemonMCP.Client.call_tool(
  client,
  "read_file",
  %{"path" => "/path/to/file.txt"}
)
# Returns {:ok, [%{type: "text", text: "content"}]}
```

### Closing the Connection

```elixir
:ok = LemonMCP.Client.close(client)
```

## Protocol Message Types

### Lifecycle Messages

- `InitializeRequest` / `InitializeResponse` - Protocol initialization handshake
- `InitializedNotification` - Client confirms initialization

### Tool Messages

- `ToolListRequest` / `ToolListResponse` - List available tools (`tools/list`)
- `ToolCallRequest` / `ToolCallResponse` - Invoke a tool (`tools/call`)

### Error Handling

- `JSONRPCError` - JSON-RPC 2.0 error responses with standard error codes

## Client State Machine

The client progresses through these states:

1. `:disconnected` - Initial state
2. `:initializing` - Connection established, handshake in progress
3. `:ready` - Handshake complete, ready for tool operations

## Error Codes

Standard JSON-RPC 2.0 error codes:

- `-32700` - Parse error
- `-32600` - Invalid request
- `-32601` - Method not found
- `-32602` - Invalid params
- `-32603` - Internal error

## Testing

Run the test suite:

```bash
mix test
```

## Configuration Options

When starting a client:

- `:command` - (required) Command to spawn the MCP server
- `:args` - Arguments to pass to the command
- `:env` - Environment variables
- `:client_name` - Client name for handshake (default: "lemon-mcp")
- `:client_version` - Client version for handshake (default: "0.1.0")
- `:capabilities` - Client capabilities map
- `:timeout_ms` - Request timeout in milliseconds (default: 30000)

## License

Part of the Lemon project.
