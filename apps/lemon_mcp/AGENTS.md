# LemonMCP App - Agent Guidelines

## Purpose and Responsibilities

The `lemon_mcp` app implements both sides of the **Model Context Protocol (MCP)**, an open JSON-RPC 2.0 protocol that lets LLM applications discover and call external tools.

### Key Responsibilities

- **MCP Client**: Spawn external MCP servers as subprocesses (via stdio), perform the handshake, and proxy tool calls to them — enabling Lemon to consume third-party tool servers (e.g. `@modelcontextprotocol/server-filesystem`)
- **MCP Server**: Accept inbound MCP connections over HTTP and expose Lemon's own `CodingAgent` tools to external MCP clients
- **Protocol Layer**: Encode/decode JSON-RPC 2.0 messages, validate lifecycle ordering, and map between Lemon's internal tool types and the MCP wire format

Protocol version targeted: **"2024-11-05"**

## Architecture Overview

```
                     CLIENT SIDE                           SERVER SIDE
                 ___________________               ________________________
                |                   |             |                        |
                |  LemonMCP.Client  |             | LemonMCP.Transport.HTTP|
                |    (GenServer)    |             |  (Plug.Router / Bandit)|
                |___________________|             |________________________|
                         |                                    |
                         v                                    v
              LemonMCP.Transport.Stdio           LemonMCP.Server.Handler
               (GenServer, Port-based)           (pure request dispatcher)
                         |                                    |
                         v                                    v
               External MCP server              LemonMCP.Server (GenServer)
               process via stdin/stdout          - holds tool registration
                                                 - tracks init state
                                                          |
                                                          v
                                               LemonMCP.ToolAdapter
                                               - bridges to CodingAgent tools
                                               - converts parameter schemas
```

Both sides share `LemonMCP.Protocol` for all struct definitions and encode/decode helpers.

## File Structure

```
lib/
  lemon_mcp.ex                     # Public façade: protocol_version/0, parse_request/1,
                                   #   create_response/2, create_error/3-4, encode!/1
  lemon_mcp/
    application.ex                 # OTP application; supervision tree (currently no children)
    protocol.ex                    # All MCP message structs + encode/decode + builder helpers
    client.ex                      # GenServer client (stdio transport, state machine)
    server.ex                      # GenServer server (tool registry, init tracking)
    tool_adapter.ex                # CodingAgent → MCP bridge; also a __using__ macro
    server/
      handler.ex                   # Pure request router: initialize/initialized/tools/list/tools/call
    transport/
      stdio.ex                     # GenServer wrapping an Erlang Port for subprocess I/O
      http.ex                      # Plug.Router + Bandit HTTP transport for server side

test/
  lemon_mcp/
    protocol_test.exs
    client_test.exs
    server_test.exs
    tool_adapter_test.exs
    server/
      handler_test.exs
    transport/
      stdio_test.exs
```

## Module Reference

| Module | Role |
|--------|------|
| `LemonMCP` | Thin public API; delegates to `Protocol` |
| `LemonMCP.Protocol` | All structs and encode/decode; also server builder helpers (`parse_request/1`, `create_response/2`, `create_error_response/4`, `error_code/1`, `server_capabilities/1`, `initialize_result/4`) |
| `LemonMCP.Client` | GenServer; owns stdio transport lifecycle, request correlation, timeout handling |
| `LemonMCP.Transport.Stdio` | GenServer backed by an Erlang `Port`; newline-delimited JSON framing; calls `message_handler` callback for each inbound line |
| `LemonMCP.Server` | GenServer; holds tool list or `tool_provider` module reference; tracks `initialized` flag; also declares the `@behaviour` for tool provider modules |
| `LemonMCP.Server.Handler` | Pure functions; routes `JSONRPCRequest` structs to handlers; validates params; calls into `Server` GenServer |
| `LemonMCP.Transport.HTTP` | `Plug.Router` mounted via Bandit; injects `mcp_server` PID into `conn.assigns`; supports single and batch JSON-RPC; exposes `POST /mcp` and `GET /health` |
| `LemonMCP.ToolAdapter` | Struct + functions that bridge `CodingAgent.Tools.*` modules to MCP format; also a `__using__` macro that generates a `@behaviour LemonMCP.Server` implementation at compile time |

## Key Types

### Protocol Structs (all in `LemonMCP.Protocol`)

```elixir
# Lifecycle
%Protocol.InitializeRequest{}   # client → server: jsonrpc, id, method, params
%Protocol.InitializeResponse{}  # server → client: jsonrpc, id, result | error
%Protocol.InitializedNotification{}  # client → server: no id (notification)

# Tool operations
%Protocol.ToolListRequest{}     # tools/list request
%Protocol.ToolListResponse{}    # result: %{tools: [...]}
%Protocol.ToolCallRequest{}     # params: %{name: String, arguments: map()}
%Protocol.ToolCallResponse{}    # result: %{content: [...], isError: bool}

# Generic JSON-RPC
%Protocol.JSONRPCRequest{}      # id, method, params — used by server routing
%Protocol.JSONRPCResponse{}     # id, result — used by all server responses
%Protocol.JSONRPCError{}        # code, message, data — embedded in responses

# Data types
%Protocol.Tool{}                # name, description, inputSchema (JSON Schema map)
%Protocol.ToolCallResult{}      # content: [%{type, text}], isError: boolean
```

**Content items** follow MCP spec: `%{type: "text", text: "..."}` is the common case; image and resource variants also exist.

### ToolAdapter Struct

```elixir
%LemonMCP.ToolAdapter{
  cwd: String.t(),               # working directory passed to CodingAgent tools
  tool_opts: keyword(),          # forwarded to each tool's tool/2 call
  tool_modules: %{String.t() => module()}  # name → CodingAgent.Tools.* module
}
```

### Client State Machine

The `LemonMCP.Client` GenServer holds an internal `state` field (not to be confused with the GenServer `state` map):

```
:disconnected  ->  :initializing  ->  :ready
                        ^-- sends InitializeRequest on init
                                       ^-- after InitializeResponse + InitializedNotification
```

Calls to `list_tools/2` and `call_tool/4` return `{:error, {:not_ready, current_state}}` unless in `:ready`.

## Common Modification Patterns

### Adding a New Tool to the ToolAdapter

The built-in tool map is a compile-time constant in `LemonMCP.ToolAdapter`:

```elixir
@builtin_tools %{
  "my_tool" => CodingAgent.Tools.MyTool,
  # ...existing entries...
}
```

The `ToolAdapter` calls `module.tool(cwd, tool_opts)` to get the tool struct, then converts its `parameters` list to a JSON Schema `inputSchema`. Parameter type atoms (`:string`, `:integer`, `:boolean`, etc.) are mapped via `map_parameter_type/1`.

### Implementing a Custom Tool Provider (Server Side)

Two options:

**Option A — `__using__` macro (compile-time adapter):**

```elixir
defmodule MyApp.MCPProvider do
  use LemonMCP.ToolAdapter, cwd: "/path/to/project", exclude_tools: ["browser"]
end
```

This generates `list_tools/0` and `call_tool/2` backed by `ToolAdapter`.

**Option B — manual `@behaviour LemonMCP.Server`:**

```elixir
defmodule MyApp.MCPProvider do
  @behaviour LemonMCP.Server

  @impl true
  def list_tools do
    [%LemonMCP.Protocol.Tool{name: "my_tool", description: "...", inputSchema: %{...}}]
  end

  @impl true
  def call_tool("my_tool", args) do
    {:ok, %LemonMCP.Protocol.ToolCallResult{content: [%{type: "text", text: "done"}], isError: false}}
  end

  def call_tool(_, _), do: {:error, :unknown_tool}
end
```

Then start the server with `tool_provider: MyApp.MCPProvider`.

### Adding a New MCP Method to the Server

1. Add a match arm in `LemonMCP.Server.Handler.handle_request/2`
2. Implement a `handle_<method>/2` function in `Handler`
3. Add any persistent state needed to `LemonMCP.Server` and a `handle_call` clause
4. Add the capability to `Protocol.server_capabilities/1` if it's a new capability type

### Starting the HTTP Transport

```elixir
{:ok, _pid} = LemonMCP.Transport.HTTP.start_link(
  port: 4048,
  server_name: "My Server",
  server_version: "1.0.0",
  tool_provider: MyApp.MCPProvider
)
```

The HTTP transport automatically starts a `LemonMCP.Server` internally and stores the server PID in `:persistent_term` under `{LemonMCP.Transport.HTTP, :mcp_server}`. Retrieve it via `LemonMCP.Transport.HTTP.get_server_pid/0`.

**Configuration alternative** (app config):

```elixir
config :lemon_mcp, :http_transport,
  enabled: true,
  port: 4048,
  ip: {127, 0, 0, 1},
  server_name: "Lemon MCP Server",
  server_version: "0.1.0"
```

### Connecting a Client to an External MCP Server

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"],
  env: [{"HOME", System.get_env("HOME")}],
  timeout_ms: 15_000
)

# Wait for :ready (handshake is async during init)
{:ok, tools} = LemonMCP.Client.list_tools(client)
{:ok, content} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/tmp/test.txt"})
# content is a list of %{type: "text", text: "..."} maps
```

## Error Handling Distinctions

The `ToolAdapter` distinguishes two categories of tool failure:

| Failure type | Return value | MCP representation |
|---|---|---|
| Tool-declared error (`{:error, reason}` from `execute/4`) | `{:ok, %ToolCallResult{isError: true}}` | Successful tool call with `isError: true` in content |
| Adapter/tool crash (exception during `execute/4`) | `{:error, {:tool_crash, message}}` | Propagates as a server-level error (not a tool result) |

This matters because the `Handler` treats `{:error, reason}` from `Server.call_tool/3` as a JSON-RPC error response (`-32600`), whereas an `{:ok, %ToolCallResult{isError: true}}` becomes a successful protocol response with `isError` set.

## Error Codes Reference

Standard JSON-RPC 2.0 codes used throughout:

| Atom | Code | Meaning |
|------|------|---------|
| `:parse_error` | -32700 | Invalid JSON |
| `:invalid_request` | -32600 | Request structure wrong |
| `:method_not_found` | -32601 | Unknown method / unknown tool |
| `:invalid_params` | -32602 | Missing or malformed params |
| `:internal_error` | -32603 | Unexpected server failure |
| `:server_not_initialized` | -32002 | `tools/list` or `tools/call` before `initialized` |

Use `Protocol.error_code(:atom)` to convert; falls back to `-32603` for unknown atoms.

## Supervision Tree

The application's supervision tree is currently minimal:

```
LemonMCP.Supervisor (one_for_one)
  (empty — no children started by default)
```

`LemonMCP.Server` and `LemonMCP.Transport.HTTP` are started on demand by callers, not by the application supervisor. If you need them always running, add them to `LemonMCP.Application.start/2`.

## Testing Guidance

### Running Tests

```bash
# All lemon_mcp tests (from umbrella root)
mix test apps/lemon_mcp

# Specific file
mix test apps/lemon_mcp/test/lemon_mcp/server/handler_test.exs
```

### Test Patterns in Use

**Server tests** (`server_test.exs`, `handler_test.exs`) start real `LemonMCP.Server` GenServers in `setup` with inline tool lists and a `tool_handler` function. No mocking needed — the server is pure in-process state.

**ToolAdapter tests** (`tool_adapter_test.exs`) define minimal tool modules inline using `AgentTool` / `AgentToolResult` structs, then build `%ToolAdapter{}` structs directly (bypassing `new/2`). This avoids needing real `CodingAgent` tool modules:

```elixir
defmodule MyFakeTool do
  def tool(_cwd, _opts) do
    %AgentCore.Types.AgentTool{
      name: "my_tool",
      description: "...",
      parameters: [],
      label: "My Tool",
      execute: fn _id, _params, _signal, _on_update -> "some result" end
    }
  end
end

adapter = %LemonMCP.ToolAdapter{
  cwd: "/tmp",
  tool_opts: [],
  tool_modules: %{"my_tool" => MyFakeTool}
}
```

**Stdio transport tests** (`transport/stdio_test.exs`) require an actual executable to be present. Tests that spawn processes should be tagged or skipped in CI environments without the target command available.

**Client tests** (`client_test.exs`) similarly depend on spawning real processes; they are integration-level.

### Testing a New Tool Provider Module

```elixir
defmodule MyProviderTest do
  use ExUnit.Case, async: true

  alias LemonMCP.{Protocol, Server, Server.Handler}

  setup do
    {:ok, server} = Server.start_link(tool_provider: MyApp.MCPProvider)
    # Must mark initialized before tools/list or tools/call will work
    Server.mark_initialized(server)
    %{server: server}
  end

  test "lists my tools", %{server: server} do
    tools = Server.list_tools(server)
    assert Enum.any?(tools, &(&1.name == "my_tool"))
  end

  test "calls my tool via handler", %{server: server} do
    request = %Protocol.JSONRPCRequest{
      id: "1", method: "tools/call",
      params: %{"name" => "my_tool", "arguments" => %{}}
    }
    response = Handler.handle_request(request, server)
    assert response.result[:isError] == false
  end
end
```

## Gotchas

- **Server must be initialized before tool operations.** `tools/list` and `tools/call` both return `-32002 server_not_initialized` until `Handler.handle_initialized/2` has been called (which calls `Server.mark_initialized/1`). In tests, call `Server.mark_initialized(server)` explicitly in setup.

- **`create_error/4` vs `create_error_response/4`**: `Protocol.create_error/4` embeds the error inside `result` (a quirk); `Protocol.create_error_response/4` puts it at the top level as `error:` per the JSON-RPC spec. The `Handler` uses `create_error_response/4` for proper wire format. Prefer `create_error_response/4` in server-side code.

- **Protocol version check is exact-match only.** `Handler.handle_initialize/2` calls `compatible_version?/1` which checks against a `supported_versions/0` list. Currently only `"2024-11-05"` is accepted. A client sending a different version string will get an `:invalid_request` error.

- **Stdio transport stderr merges into stdout.** `Port.open/2` is started with `:stderr_to_stdout`, so stderr from the MCP server subprocess arrives as ordinary data lines. This can cause spurious JSON parse warnings if the subprocess logs to stderr on startup (e.g. `npx` install output).

- **ToolAdapter `new/2` options use `include_tools`/`exclude_tools` but the `__using__` macro does not pass `include_tools`.** If you need to restrict tools via the macro, pass `:exclude_tools` explicitly.

- **HTTP transport port defaults to `0` in test env.** `@default_port` is set at compile time via `Mix.env()`. In test, a random available port is assigned, which avoids conflicts. To find the actual port in tests, inspect the Bandit supervisor or use the server PID.

- **`LemonMCP.Application` supervision tree is empty.** The application starts but supervises nothing by default. All server/transport processes must be started explicitly by the consuming app (e.g. `lemon_channels`). If you want fault-tolerant MCP services, add them to a supervisor in the host app rather than modifying `LemonMCP.Application`.

- **`ToolAdapter` calls `module.tool/2` during both `list_tools/1` and `call_tool/3`.** The tool definition is fetched twice per operation. If constructing the `AgentTool` struct is expensive, this could matter.

## How This App Connects to Other Umbrella Apps

- **`coding_agent`** (dependency): `ToolAdapter` maps `CodingAgent.Tools.*` module names to MCP tool definitions. All `@builtin_tools` entries reference `CodingAgent.Tools` modules.
- **`agent_core`** (dependency): `AgentCore.Types.AgentToolResult` and `AgentCore.Types.AgentTool` are used by `ToolAdapter` for result conversion.
- **Consumers**: Any app wanting to expose Lemon tools over MCP or consume external MCP servers depends on `{:lemon_mcp, in_umbrella: true}` and calls `LemonMCP.Client.start_link/1` or `LemonMCP.Transport.HTTP.start_link/1`.
