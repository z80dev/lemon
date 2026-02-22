# Lemon Control Plane - Agent Guide

HTTP/WebSocket API server for controlling the Lemon agent system.

## Purpose and Responsibilities

The control plane provides the external interface for clients (TUI, web, mobile, browser extensions) to:

- **Submit agent runs** - Send prompts to agents via `agent` or `chat.send`
- **Manage sessions** - List, reset, delete conversation sessions
- **Configure the system** - Get/set config values, reload config
- **Manage secrets** - Store and retrieve API keys securely
- **Schedule cron jobs** - Create recurring agent runs
- **Install skills** - Manage agent capabilities
- **Pair nodes/devices** - Connect browser extensions and mobile devices
- **Stream real-time events** - WebSocket events for runs, chat deltas, approvals

## Architecture Overview

```
┌─────────────────┐     HTTP/WebSocket      ┌──────────────────┐
│  Clients (TUI)  │◄───────────────────────►│  Bandit Server   │
│  Web, Mobile    │      Port 4040          │  (Router plug)   │
└─────────────────┘                         └────────┬─────────┘
                                                    │
                           ┌────────────────────────┼────────────────────────┐
                           │                        │                        │
                    ┌──────▼──────┐        ┌────────▼────────┐      ┌───────▼────────┐
                    │   /healthz  │        │      /ws        │      │  (404 fallback)│
                    │  (health)   │        │  (WebSocket)    │      │                │
                    └─────────────┘        └────────┬────────┘      └────────────────┘
                                                    │
                       ┌────────────────────────────┼────────────────────────────┐
                       │                            │                            │
                ┌──────▼──────┐            ┌────────▼────────┐          ┌────────▼────────┐
                │   Connect   │            │  Request Frame  │          │  Event Bridge   │
                │  Handshake  │            │   Dispatch      │          │  (Bus → WS)     │
                └─────────────┘            └────────┬────────┘          └─────────────────┘
                                                    │
                                            ┌───────▼────────┐
                                            │ Method Registry│
                                            │  (ETS lookup)  │
                                            └───────┬────────┘
                                                    │
                                            ┌───────▼────────┐
                                            │  Auth Check    │
                                            │  (scopes)      │
                                            └───────┬────────┘
                                                    │
                                            ┌───────▼────────┐
                                            │ Method Handler │
                                            │  (100+ methods)│
                                            └────────────────┘
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `LemonControlPlane` | Main module, protocol version |
| `LemonControlPlane.Application` | OTP supervision tree |
| `LemonControlPlane.HTTP.Router` | HTTP routing (Bandit/Plug) |
| `LemonControlPlane.WS.Connection` | WebSocket connection handler |
| `LemonControlPlane.Presence` | Connected client tracking |
| `LemonControlPlane.EventBridge` | Bus events → WebSocket fanout |
| `LemonControlPlane.Auth.Authorize` | Role-based access control |
| `LemonControlPlane.Methods.Registry` | Method dispatch registry |
| `LemonControlPlane.Protocol.Frames` | Protocol frame encoding/decoding |

## JSON-RPC Method Structure

### Adding a New Method

Create a new file in `lib/lemon_control_plane/methods/`:

```elixir
defmodule LemonControlPlane.Methods.MyMethod do
  @moduledoc """
  Handler for the my.method control plane method.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "my.method"

  @impl true
  def scopes, do: [:read]  # or :write, :admin, :approvals, etc.

  @impl true
  def handle(params, ctx) do
    # params: map() | nil - method parameters
    # ctx: %{auth: auth_context, conn_id: String.t(), conn_pid: pid()}
    
    required_param = params["requiredParam"]
    
    if is_nil(required_param) do
      {:error, {:invalid_request, "requiredParam is required", nil}}
    else
      # Do work...
      {:ok, %{"result" => "success"}}
    end
  end
end
```

### Register the Method

Add to the `@builtin_methods` list in `LemonControlPlane.Methods.Registry`:

```elixir
@builtin_methods [
  # ... existing methods ...
  LemonControlPlane.Methods.MyMethod,
]
```

### Scope Guidelines

| Scope | Use For |
|-------|---------|
| `[]` (empty) | Public methods: `health`, `connect` |
| `[:read]` | Read operations: list, get, status |
| `[:write]` | Write operations: send, chat, agent |
| `[:admin]` | Admin operations: config, install, cron mgmt |
| `[:approvals]` | Approval management: `exec.approvals.*` |
| `[:pairing]` | Pairing operations: `node.pair.*`, `device.pair.*` |

### Error Response Format

```elixir
# Standard error tuple
{:error, {:invalid_request, "message", nil}}
{:error, {:not_found, "Resource not found", nil}}
{:error, {:forbidden, "Insufficient permissions", nil}}
{:error, {:internal_error, "Something went wrong", details}}
```

## Session Management APIs

| Method | Scope | Description |
|--------|-------|-------------|
| `sessions.list` | read | List all sessions with pagination |
| `sessions.active` | read | Get currently active session |
| `sessions.active.list` | read | List all active sessions |
| `sessions.preview` | read | Preview session messages |
| `sessions.patch` | admin | Modify session (title, meta) |
| `sessions.reset` | admin | Clear session history |
| `sessions.delete` | admin | Delete a session |
| `sessions.compact` | admin | Compact session storage |

Example usage:
```elixir
# List sessions
{:ok, %{"sessions" => sessions, "total" => total}} = 
  LemonControlPlane.Methods.SessionsList.handle(%{"limit" => 50}, ctx)

# Send message to session
{:ok, %{"runId" => run_id}} = 
  LemonControlPlane.Methods.ChatSend.handle(%{
    "sessionKey" => "session-123",
    "prompt" => "Hello!"
  }, ctx)
```

## Agent Management APIs

| Method | Scope | Description |
|--------|-------|-------------|
| `agent` | write | Submit an agent run |
| `agent.wait` | write | Submit and wait for completion |
| `agents.list` | read | List available agents |
| `agent.identity.get` | read | Get agent capabilities/identity |
| `agent.inbox.send` | write | Send message to agent inbox |
| `agent.targets.list` | read | List agent routing targets |
| `agent.directory.list` | read | List agent directory entries |
| `agent.endpoints.list` | read | List agent HTTP endpoints |
| `agent.endpoints.set` | write | Configure agent endpoint |
| `agent.endpoints.delete` | write | Remove agent endpoint |
| `agents.files.list` | read | List agent files |
| `agents.files.get` | read | Get file content |
| `agents.files.set` | admin | Set file content |

## Configuration and Secrets APIs

### Configuration

| Method | Scope | Description |
|--------|-------|-------------|
| `config.get` | read | Get config value(s) |
| `config.set` | admin | Set config value |
| `config.patch` | admin | Partial config update |
| `config.schema` | read | Get config schema |
| `config.reload` | admin | Reload configuration |

Config keys are whitelisted in `ConfigGet` to prevent atom table exhaustion.

### Secrets

| Method | Scope | Description |
|--------|-------|-------------|
| `secrets.list` | read | List secret metadata (no values) |
| `secrets.set` | admin | Store secret |
| `secrets.delete` | admin | Remove secret |
| `secrets.exists` | read | Check if secret exists |
| `secrets.status` | read | Get secrets store status |

Secrets are stored via `LemonCore.Secrets` and never returned in plaintext over the API.

## Authentication and Authorization

### Roles

| Role | Description |
|------|-------------|
| `operator` | Default admin/operator client |
| `node` | Paired browser extension or node |
| `device` | Paired mobile/device |

### Authentication Flow

1. Client connects via WebSocket
2. Client sends `connect` method with auth params:
   ```json
   {
     "type": "req",
     "id": "uuid",
     "method": "connect",
     "params": {
       "auth": {"token": "optional-jwt"},
       "role": "operator",
       "scopes": ["operator.read", "operator.write"]
     }
   }
   ```
3. Server responds with `hello-ok` frame containing features, methods, snapshot
4. Subsequent requests use the established auth context

### Token-Based Auth

For nodes/devices, use challenge-response pairing:
- `node.pair.request` / `device.pair.request` - Initiate pairing
- `node.pair.approve` / `device.pair.approve` - Operator approves
- Token is generated and returned to the node
- Node uses token in subsequent `connect` calls

## Presence System

`LemonControlPlane.Presence` tracks all connected WebSocket clients:

```elixir
# Get connection counts
LemonControlPlane.Presence.counts()
# => %{total: 5, operators: 2, nodes: 2, devices: 1}

# List all clients
LemonControlPlane.Presence.list()
# => [{conn_id, %{role: :operator, client_id: "...", pid: pid()}}]

# Broadcast to all clients
LemonControlPlane.Presence.broadcast("event_name", payload)

# Broadcast with filter
LemonControlPlane.Presence.broadcast("event", payload, fn info -> 
  info.role == :operator 
end)
```

## WebSocket Protocol

### Frame Types

**Request (client → server):**
```json
{"type": "req", "id": "uuid", "method": "health", "params": {}}
```

**Response (server → client):**
```json
{"type": "res", "id": "uuid", "ok": true, "payload": {}}
{"type": "res", "id": "uuid", "ok": false, "error": {"code": "...", "message": "..."}}
```

**Event (server → client):**
```json
{"type": "event", "event": "chat", "seq": 1, "payload": {...}}
```

**Hello-OK (handshake response):**
```json
{"type": "hello-ok", "protocol": 1, "server": {...}, "features": {...}}
```

### Events

| Event | Description |
|-------|-------------|
| `agent` | Run started/completed, tool use |
| `chat` | Chat delta/streaming content |
| `presence` | Connection count changed |
| `exec.approval.requested` | Approval needed |
| `exec.approval.resolved` | Approval decided |
| `cron` | Cron job started/completed |
| `tick` | Heartbeat tick |
| `node.pair.requested` | Node wants to pair |
| `device.pair.requested` | Device wants to pair |
| `talk.mode` | Talk mode changed |
| `shutdown` | System shutting down |
| `health` | Health status changed |

## Common Tasks

### Run Tests

```bash
# All tests
mix test apps/lemon_control_plane

# Specific test file
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs

# Specific test
mix test --grep "name/0 returns correct method name"
```

### Add a New API Method

1. Create module in `lib/lemon_control_plane/methods/my_method.ex`
2. Implement `LemonControlPlane.Method` behaviour
3. Add to `@builtin_methods` in `Registry`
4. Add tests in `test/lemon_control_plane/methods/`

### Test a Method Directly

```elixir
# In iex or test
ctx = %{auth: LemonControlPlane.Auth.Authorize.default_operator(), conn_id: "test", conn_pid: self()}

{:ok, result} = LemonControlPlane.Methods.SessionsList.handle(%{}, ctx)
```

### Debug WebSocket Connections

Check presence state:
```elixir
:sys.get_state(LemonControlPlane.Presence)
```

List active connections:
```elixir
LemonControlPlane.Presence.list()
```

### Event Bridge Debugging

Force an event broadcast:
```elixir
LemonCore.Bus.broadcast("system", LemonCore.Event.new(:tick, %{}))
```

## Testing Guidelines

- Use `async: true` for method tests that don't depend on shared state
- Tests requiring the full runtime should be marked `async: false`
- The `test_helper.exs` ensures `lemon_channels` is started for integration tests
- Mock external dependencies; test method logic in isolation
- Test error cases: missing params, invalid auth, not found scenarios
- For WebSocket tests, use the connection test as a reference pattern

## Key Dependencies

- `bandit` - HTTP/WebSocket server
- `websock_adapter` - WebSocket adapter for Plug
- `lemon_router` - Submit agent runs
- `lemon_core` - Store, secrets, event bus
- `lemon_channels` - Channel backends
- `lemon_skills` - Skill management
