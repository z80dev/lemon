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

- `lemon_core` (in_umbrella) - Shared RPC lifecycle/framing contracts, subprocess-group cleanup, request IDs, and the `:inets`/`:ssl` runtime used by the HTTP clients
- `lemon_skills` (in_umbrella) - Hosts `LemonSkills.McpSource`, whose suite lives in this app's tests
- `jason` - JSON encoding/decoding
- `bandit` / `plug` (test only) - Local HTTP and SSE MCP server fixtures for the client tests

## Modules

- `LemonMCP` - Main module with protocol version
- `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
- `LemonMCP.Client` - Stdio MCP protocol client backed by `LemonCore.Rpc.Client`, with supervised notification callbacks
- `LemonMCP.Transport.Stdio` - Raw-byte stdio transport and subprocess owner implementing `LemonCore.Rpc.Transport`
- `LemonMCP.Framing.Stdio` - Bounded JSON-line framing that tolerates merged stderr log lines
- `LemonMCP.Client.HTTP` - Streamable HTTP client for external MCP servers, including JSON responses, per-request SSE responses, session/protocol headers and supervised per-request workers; OAuth comes from `LemonMCP.HTTP.OAuth`
- `LemonMCP.HTTP.OAuth` - OAuth protected-resource / authorization-server metadata discovery, client-credentials token acquisition with form-post or HTTP Basic client authentication, refresh-token grant retry when a token response supplies a refresh token, authorization-code PKCE callback/token exchange for public clients, and injectable token-cache load/save hooks
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
and fails pending client requests. The shared core RPC state machine owns request
correlation, caller monitors, deadlines, and the initialization timeout; the MCP
wrapper keeps only protocol state. Each operation uses the shorter of its public
timeout argument and `:timeout_ms`, returning `{:error, :timeout}` on expiry.
There is no separate caller-side timer. Caller death discards its outstanding
request, and duplicate, unknown, or late response IDs do not complete another call.

Protocol frames are capped at 8 MiB. Stderr remains merged into stdout, but
non-protocol lines are discarded without exposing their contents in errors.
The transport forwards raw chunks; the framing module alone adds outbound
newlines and assembles inbound frames. Closing a client fails pending calls,
stops its private callback supervisor and RPC process, and terminates the server's
process group. Never replay a timed-out tool invocation automatically; the remote
operation may already have taken effect.

Lemon answers no server-to-client request. Every one, `sampling/createMessage`
included, receives a `-32601` method-not-found error, and no client (stdio,
Streamable HTTP or legacy SSE) advertises the `sampling` capability, even when a
caller passes it in `:capabilities`.

Stdio notification callbacks run in tasks under a private supervisor owned by
that client. A slow callback cannot block ordinary responses, other
notifications or request deadlines, and a raised/thrown callback failure does
not terminate the connection. Server requests never reach notification handlers.

HTTP and SSE clients also own private, capped notification task supervisors.
Closing or killing the client terminates those callbacks. The per-client
`max_notification_tasks` option defaults to 32 (caller policy, not a measured
throughput limit); callbacks beyond the cap are dropped without blocking
protocol responses or starting unsupervised work. Notification handlers are
best-effort invalidation signals, not durable delivery.

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
`:metadata_http_error`. With no policy, MCP requests retain existing operator
DNS/proxy networking, except that redirects are still rejected; OAuth requests
are always pinned (below). Policy and OAuth requests use a
dedicated direct HTTP profile without cookies or connection reuse, preventing
IP-keyed pooled connections from crossing original TLS identities. Interactive
authorization-code providers still own the browser/callback boundary; this
library pins the HTTP requests it executes, not external browser navigation.

OAuth discovery is bound to the configured server, with or without a policy.
Protected-resource metadata must name the configured MCP URL as its `resource`
(same canonical origin, path and query), and authorization-server metadata must
return an `issuer` identical to the issuer Lemon requested; anything else fails
with `:invalid_oauth_metadata` instead of being patched. Token and authorization
endpoints come only from that validated issuer metadata (never from the
protected-resource document; cached metadata is revalidated before use).
Metadata, issuer and token URLs must be HTTPS or literal-loopback HTTP
(`:insecure_oauth_endpoint`). Without `allowedOrigins`, the token endpoint must
share the issuer's origin (`:origin_not_allowed`), and every OAuth connection is
DNS-pinned to public addresses only, except the configured server's own origin
and, for a literal-loopback server, other literal-loopback origins. With a
policy, each OAuth URL must also be allowlisted. Validation runs before any
client secret, code verifier or refresh token is sent. Authorization endpoints
under a policy must themselves be allowlisted before the URL reaches a provider,
observer or approval, since browser navigation is never pinned. Server JSON
cannot supply Lemon's internal fields (`authorization_server_metadata`, etc.).

Grants are bound to the issuer and client that produced them: the token cache
payload records `issuer` and `client_id`. When a live session or a cached grant
meets a different discovered issuer, the client fails with
`:oauth_issuer_changed` before any refresh token or client secret is sent, and
does not fall back to a fresh grant; the operator must re-authorize (clear the
cached token). Cache entries for another client are ignored; entries without
both a recorded issuer and the exact client id keep only their access token.

Operator credentials are bound by the optional `oauth: [issuer: ...]` key. With
it, the discovered issuer must be identical (`:oauth_issuer_mismatch`) before
any token request. Without it, a client secret is sent only to an issuer on the
configured server's own origin (`:oauth_issuer_required` otherwise), and a
configured `refresh_token` is refused at startup with `:oauth_issuer_required`.

After the handshake, HTTP and legacy SSE clients keep only session, grant and
capability state in the client process; every request runs in a supervised
worker answered with `GenServer.reply/2`, so `state/1` and concurrent requests
never wait for a slow server. A request's deadline is the shorter of its public
timeout argument and `:timeout_ms`: when it expires (or the SSE stream is lost)
the worker is killed first and the caller receives `{:error, :outcome_unknown}`.
The request may have executed; never replay it. A caller that exits also stops
its request. Without an origin policy each request uses its own `httpc`
connection, so one slow response cannot queue another behind it.

When the server later rejects that bearer token with another 401 challenge,
one background grant refresh serves every request that saw the 401, and each of
those requests is retried once with the new token. If the previous token
response included a refresh token, Lemon first requests
`grant_type=refresh_token` and rotates the stored refresh token when the token
endpoint returns a replacement. If no refresh token is available or refresh
fails, Lemon falls back to a fresh client-credentials bearer. When only the
interactive authorization-code provider could issue a new grant, the request
fails fast with the auth-required error while authorization runs in the
background; later requests use the new grant. A request whose deadline passes
while its refresh is pending is answered with the auth-required error and never
sent again.
The default token endpoint auth method is `:client_secret_post`; use
`:client_secret_basic` for servers that require HTTP Basic client
authentication at the token endpoint.

Public-client authorization-code + PKCE flows use an
`:authorization_code_provider` callback. The callback receives the
authorization request, should send the operator through `authorization_url`,
and returns `{:ok, %{code: code, state: state}}` with the request's state. A
bare code, a missing state or a different state is rejected before the token
exchange:

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

The stdio protocol wrapper and its shared core RPC engine progress through:

1. `:disconnected` - Initial state
2. `:initializing` - Connection established, handshake in progress
3. `:ready` - Handshake complete, ready for tool operations

The shared engine bounds initialization with `:timeout_ms`. Only a response
matching the initialize request ID can make the MCP wrapper ready.

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
- `:capabilities` - Client capabilities map (`sampling` is never advertised)
- `:timeout_ms` - Maximum request and initialization timeout in milliseconds (default: 30000; `:infinity` disables the configured bound)

## Server notifications

All three clients accept `notification_handler: fn notification -> ... end`.
The callback receives `%{method: method, params: params}` for server JSON-RPC
notifications (a method with no request ID); omitted params become `%{}`.
For example, a host can react to `notifications/tools/list_changed`,
`notifications/resources/list_changed`, `notifications/prompts/list_changed` or
`notifications/resources/updated` by refreshing its own cache.

The option must be `nil` (the default, which ignores notifications) or an arity-one
function. Each callback runs independently: exceptions and slow callbacks do not
block or terminate the client. Stdio uses the client's private task supervisor,
which stops outstanding callbacks when the connection closes. HTTP/SSE callbacks
remain unlinked tasks. Delivery order and task completion are not guaranteed;
hosts own cache lifecycle.

Stdio and legacy SSE deliver notifications from their incoming streams. Streamable
HTTP delivers notifications included in POST responses, including SSE-formatted
responses; this client does not open a separate GET notification stream.

## License

Part of the Lemon project.
