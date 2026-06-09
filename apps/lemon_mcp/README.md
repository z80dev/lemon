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
- `LemonMCP.Client` - GenServer client for managing stdio MCP connections, including optional `sampling/createMessage` callback or policy handling
- `LemonMCP.Sampling` - Redacted policy wrapper for reviewed model-backed stdio sampling callbacks
- `LemonMCP.Server` - MCP server process
- `LemonMCP.Server.Handler` - Server request handler
- `LemonMCP.ToolAdapter` - Adapter that exposes CodingAgent tools over MCP
- `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
- `LemonMCP.Transport.HTTP` - Streamable HTTP JSON-RPC transport for MCP servers
- `LemonMCP.Client.HTTP` - Streamable HTTP client for external MCP servers, including JSON responses, per-request SSE responses, session/protocol headers, OAuth protected-resource / authorization-server metadata discovery, optional OAuth client-credentials token acquisition with form-post or HTTP Basic client authentication, refresh-token grant retry when a token response supplies a refresh token, authorization-code PKCE callback/token exchange for public clients, injectable token-cache load/save hooks, and one-shot bearer reacquisition after later 401 challenges
- `LemonMCP.Client.SSE` - legacy HTTP+SSE client for external MCP servers

## Usage

### Starting a Client Connection

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
)
```

`sampling/createMessage` is disabled by default. Prefer a `sampling_policy`
when requests should pass through redacted review and local limits before a
model-backed delegate is called:

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "node",
  args: ["server.js"],
  sampling_policy: [
    mode: :reviewed_model,
    max_tokens: 1_024,
    allowed_models: ["lemon"],
    reviewer: fn summary ->
      # summary includes request_hash, message_count, roles, content_kinds,
      # text_char_count, max_tokens, and requested_model, but not raw text.
      :approve
    end,
    delegate: fn params, summary ->
      call_model(params, summary)
    end
  ]
)
```

Pass a raw `sampling_handler` function only for low-level integrations that
already own review and policy checks. Either option advertises the sampling
capability only when Lemon can answer server sampling requests:

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "node",
  args: ["server.js"],
  sampling_handler: fn params ->
    {:ok,
     %{
       "role" => "assistant",
       "content" => %{"type" => "text", "text" => "sampled"},
       "model" => "lemon",
       "stopReason" => "endTurn"
     }}
  end
)
```

When sampling is configured through `LemonSkills.McpSource`, use
`reviewer: :ops_approval` to route reviewed sampling through
`LemonCore.ExecApprovals`. The source bridge creates redacted
`mcp_<server>_sampling` approvals for approval surfaces before any delegate sees
raw sampling params. Approval summaries include the safe request hash, model,
token, message, role, and content-kind metadata.

Configured Streamable HTTP sources with local PKCE redirect URIs also route
authorization requests through `LemonCore.ExecApprovals` as `mcp_<server>_oauth`
approvals before token exchange. Approval surfaces receive an OAuth link plus
resource, redirect, and scope context; denial or timeout stops the authorization
attempt.

Streamable HTTP servers protected by OAuth client credentials can be started
with an `:oauth` option:

```elixir
{:ok, client} = LemonMCP.Client.HTTP.start_link(
  url: "https://example.com/mcp",
  oauth: [
    client_id: "client",
    client_secret: "secret",
    scopes: ["tools"],
    token_auth_method: :client_secret_basic
  ]
)
```

When the server later rejects that bearer token with another 401 challenge,
the client reuses the discovered OAuth metadata and retries that MCP request
once. If the previous token response included a refresh token, Lemon first
requests `grant_type=refresh_token` and rotates the stored refresh token when
the token endpoint returns a replacement. If no refresh token is available or
refresh fails, Lemon falls back to a fresh client-credentials bearer.
The default token endpoint auth method is `:client_secret_post`; use
`:client_secret_basic` for servers that require HTTP Basic client
authentication at the token endpoint.

Public-client authorization-code + PKCE flows use an
`:authorization_code_provider` callback. The callback receives the
authorization request, should send the operator through `authorization_url`,
and returns the callback code with the same state:

```elixir
{:ok, client} = LemonMCP.Client.HTTP.start_link(
  url: "https://example.com/mcp",
  oauth: [
    flow: :authorization_code_pkce,
    client_id: "public-client",
    redirect_uri: "http://127.0.0.1:43189/callback",
    scopes: ["tools"],
    authorization_code_provider: fn request ->
      {:ok, %{code: fetch_operator_code(request.authorization_url), state: request.state}}
    end
  ]
)
```

OAuth access/refresh material is process-local unless a cache is supplied.
Low-level integrations can pass `oauth_token_cache: [load: ..., save: ...]`
or the compatibility `oauth_token_loader` / `oauth_token_persister` callbacks
to load cached tokens before the initialize request and save every successful
client-credentials, refresh-token, or PKCE token response. `lemon_mcp` keeps
the callbacks storage-agnostic; configured Lemon skill sources persist tokens
through `LemonCore.Secrets` when `oauth.token_secret` is set and can host a
localhost PKCE callback listener for configured local `redirect_uri` values.
Long-running interactive authorization providers should pass a GenServer
`:timeout` option large enough for the operator flow.

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

The server validates that lifecycle/tool params are maps, that required string fields are present, and that tool `arguments` are maps when provided.

`LemonMCP.ToolAdapter` distinguishes between:

- tool-declared failures, which return MCP tool results with `isError: true`
- adapter/tool crashes, which surface as server/transport errors instead of successful tool responses

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
- `:sampling_policy` - `LemonMCP.Sampling` policy opts for reviewed model-backed sampling
- `:sampling_handler` - low-level raw callback for `sampling/createMessage`
- `:timeout_ms` - Request timeout in milliseconds (default: 30000)

## License

Part of the Lemon project.
