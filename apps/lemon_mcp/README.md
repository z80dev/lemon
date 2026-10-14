# LemonMCP

MCP (Model Context Protocol) client library for the Lemon codebase.

## Overview

LemonMCP implements the client side of the Model Context Protocol (MCP), an open protocol that enables seamless integration between LLM applications and external data sources and tools. It connects Lemon to external MCP servers over stdio, Streamable HTTP, and legacy HTTP+SSE; `LemonSkills.McpSource` uses it to expose those servers' tools, resources, and prompts to agents.

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

- `lemon_core` (in_umbrella) - Request ID generation (`LemonCore.Id`) and the `:inets`/`:ssl` runtime used by the HTTP clients
- `lemon_skills` (in_umbrella) - Hosts `LemonSkills.McpSource`, whose suite lives in this app's tests
- `jason` - JSON encoding/decoding
- `bandit` / `plug` (test only) - Local HTTP and SSE MCP server fixtures for the client tests

## Modules

- `LemonMCP` - Main module with protocol version
- `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
- `LemonMCP.Client` - GenServer client for managing stdio MCP connections, including optional `sampling/createMessage` callback or policy handling
- `LemonMCP.Sampling` - Redacted policy wrapper for reviewed model-backed stdio sampling callbacks
- `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
- `LemonMCP.Client.HTTP` - Streamable HTTP client for external MCP servers, including JSON responses, per-request SSE responses, session/protocol headers, OAuth protected-resource / authorization-server metadata discovery, optional OAuth client-credentials token acquisition with form-post or HTTP Basic client authentication, refresh-token grant retry when a token response supplies a refresh token, authorization-code PKCE callback/token exchange for public clients, injectable token-cache load/save hooks, and one-shot bearer reacquisition after later 401 challenges
- `LemonMCP.Client.SSE` - legacy HTTP+SSE client for external MCP servers

`lemon_mcp` is a library application: it has no application callback and starts
no processes by default. Callers start and supervise the client and transport
processes they use. Lemon's minimal and full OTP releases include the
library with `:load`, which makes these modules available to dynamic consumers
such as `LemonSkills.McpSource` without adding a no-op supervisor.
Release smoke builds both profiles and evaluates this contract inside each
packaged release. The artifact boot verifier repeats it against each min/full
release tarball, including loaded-but-not-started application state and the
absence of an application callback.

## Usage

### Starting a Client Connection

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
)
```

Stdio clients accept `cwd: "/path/to/project"` and string-pair `env` overrides.
The consuming host owns reconnection: subprocess exit terminates the transport
and fails pending client requests. Protocol buffering is capped at 8 MiB.
Never replay a timed-out tool invocation automatically; the remote operation may
already have taken effect.

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

For product-managed HTTP destinations, pass `origin_policy: %{allowed_origins:
["https://example.com"], approved_private_origins: []}`. Origins are exact,
canonical scheme/hostname/effective-port identities, not suffixes or URL paths.
An exact origin must be in both lists to connect to local, private or reserved
addresses. The client validates every DNS answer and connects to the selected
address, preserving the canonical original Host header and TLS SNI/verified
certificate hostname. System CA trust and certificate-chain verification remain
enabled; pinning does not bypass TLS verification.

Hosts that decrypt header references must call `LemonMCP.HTTP.OriginPolicy.pin/2`
before credential resolution and pass the result through the internal
`:destination_pin` option together with `:origin_policy`. The pin is process-local
authority, never a JSON server-definition field. The client reuses it for every
MCP request without resolving the original hostname again. Without an internal
pin it independently validates and pins before its token-cache callback or
initialize request. OAuth metadata and token URLs each undergo their own policy
check and DNS pin; configured MCP headers and bearer tokens never accompany
metadata requests.

All Streamable HTTP requests disable redirects and return `:redirect_forbidden`
without fetching the Location target. Policy/transport failures are classified
atoms, including `:origin_not_allowed`, `:destination_not_public`,
`:invalid_destination_pin`, `:http_transport_unavailable`,
`:http_request_failed`, `:http_error`, `:auth_required`, `:invalid_metadata` and
`:metadata_http_error`. With no policy, existing operator DNS/proxy networking
is retained, except that redirects are still rejected. Policy requests use a
dedicated direct HTTP profile without cookies or connection reuse, preventing
IP-keyed pooled connections from crossing original TLS identities. Interactive
authorization-code providers still own the browser/callback boundary; this
library pins the HTTP requests it executes, not external browser navigation.


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
mix test apps/lemon_mcp/test
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
