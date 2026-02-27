# LemonControlPlane

HTTP and WebSocket control plane API server for the Lemon agent system. Provides a frame-based JSON protocol over WebSocket for real-time bidirectional communication, plus REST endpoints for the games platform.

## Overview

LemonControlPlane is the external interface through which clients (terminal UI, web dashboards, mobile apps, browser extensions) interact with the Lemon agent runtime. It exposes 100+ JSON-RPC-style methods over WebSocket for submitting agent runs, managing sessions, configuring the system, scheduling cron jobs, pairing nodes/devices, and streaming real-time events.

The server runs on [Bandit](https://github.com/mtrudel/bandit) with [Plug](https://github.com/elixir-plug/plug) routing, and uses [WebSockAdapter](https://github.com/phoenixframework/websock_adapter) for WebSocket upgrades.

## Architecture

```
+-----------------+     HTTP/WebSocket      +------------------+
|  Clients (TUI)  |<----------------------->|  Bandit Server   |
|  Web, Mobile    |      Port 4040          |  (Router plug)   |
+-----------------+                         +--------+---------+
                                                     |
                    +--------------------------------+---------------------------+
                    |                 |               |                          |
             +------v------+  +------v------+  +-----v----------+  +-----------v---------+
             |  /healthz   |  | /v1/games/* |  |     /ws        |  |  404 fallback       |
             |  (GET JSON) |  | (REST API)  |  |  (WebSocket)   |  |                     |
             +-------------+  +-------------+  +------+---------+  +---------------------+
                                                      |
                      +-------------------------------+-------------------------------+
                      |                               |                               |
               +------v------+              +---------v---------+           +---------v---------+
               |   Connect   |              |  Request Frame    |           |   Event Bridge    |
               |  Handshake  |              |   Dispatch        |           |  (Bus -> WS)      |
               +-------------+              +--------+----------+           +-------------------+
                                                     |
                                             +-------v--------+
                                             | Schema Validate|
                                             | (Schemas mod)  |
                                             +-------+--------+
                                                     |
                                             +-------v--------+
                                             | Method Registry|
                                             | (ETS lookup)   |
                                             +-------+--------+
                                                     |
                                             +-------v--------+
                                             |  Auth Check    |
                                             |  (scopes)      |
                                             +-------+--------+
                                                     |
                                             +-------v--------+
                                             | Method Handler |
                                             | (100+ methods) |
                                             +----------------+
```

### Request Lifecycle

1. A JSON text frame arrives on the WebSocket connection.
2. `Protocol.Frames.parse/1` decodes and validates the frame structure.
3. If the connection has not yet completed the handshake, only `connect` is allowed; all other methods return `HANDSHAKE_REQUIRED`.
4. For `connect`, `Auth.Authorize.from_params/1` establishes the auth context and a `hello-ok` frame is returned.
5. For all other methods, `Protocol.Schemas.validate/2` checks required/optional parameter types.
6. `Methods.Registry.dispatch/3` looks up the handler module in the ETS table.
7. `Auth.Authorize.authorize/3` verifies the connection has the required scopes for the method.
8. The handler's `handle/2` callback executes and returns `{:ok, payload}` or `{:error, ...}`.
9. `Protocol.Frames.encode_response/2` serializes the result to JSON and pushes it to the client.

### Supervision Tree

```
LemonControlPlane.Supervisor (one_for_one)
  |-- Methods.Registry          (GenServer, ETS-backed method dispatch)
  |-- Presence                  (GenServer, ETS-backed client tracking)
  |-- EventBridge.FanoutSupervisor  (Task.Supervisor for broadcast dispatch)
  |-- EventBridge              (GenServer, Bus -> WebSocket event fanout)
  |-- ConnectionSupervisor     (DynamicSupervisor for WS connections)
  |-- ConnectionRegistry       (Registry for connection process lookup)
  |-- Bandit                   (HTTP server, Plug router)
```

## HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/healthz` | Health check, returns `{"ok": true}` |
| GET | `/ws` | WebSocket upgrade endpoint |
| GET | `/v1/games/lobby` | List active/recent public game matches |
| GET | `/v1/games/matches/:id` | Get match state (redacted per viewer) |
| GET | `/v1/games/matches/:id/events` | Poll match event feed |
| POST | `/v1/games/matches` | Create a match challenge |
| POST | `/v1/games/matches/:id/accept` | Accept a pending match |
| POST | `/v1/games/matches/:id/moves` | Submit a turn move |

The Games API endpoints use Bearer token authentication with scoped claims (e.g., `games:play`), validated through `LemonGames.Auth`.

## WebSocket Protocol

### Frame Types

**Request** (client to server):
```json
{
  "type": "req",
  "id": "<uuid>",
  "method": "<method_name>",
  "params": {}
}
```

**Response** (server to client):
```json
{
  "type": "res",
  "id": "<uuid>",
  "ok": true,
  "payload": {}
}
```

```json
{
  "type": "res",
  "id": "<uuid>",
  "ok": false,
  "error": {"code": "NOT_FOUND", "message": "..."}
}
```

**Event** (server to client, asynchronous):
```json
{
  "type": "event",
  "event": "<event_name>",
  "seq": 1,
  "payload": {},
  "stateVersion": {"presence": 2, "health": 0, "cron": 1}
}
```

**Hello-OK** (handshake completion, replaces `res` for `connect`):
```json
{
  "type": "hello-ok",
  "protocol": 1,
  "server": {
    "version": "0.1.0",
    "commit": "abc123",
    "host": "hostname",
    "connId": "<uuid>"
  },
  "features": {
    "methods": ["health", "status", "agent", "..."],
    "events": ["agent", "chat", "presence", "..."]
  },
  "snapshot": {
    "presence": {},
    "health": {"ok": true}
  },
  "policy": {
    "maxPayload": 1048576,
    "maxBufferedBytes": 8388608,
    "tickIntervalMs": 1000
  },
  "auth": {
    "role": "operator",
    "scopes": ["admin", "read", "write", "approvals", "pairing"]
  }
}
```

### Connection Handshake

1. Client connects to `ws://host:4040/ws`.
2. Client sends a `connect` request:
   ```json
   {
     "type": "req",
     "id": "uuid",
     "method": "connect",
     "params": {
       "role": "operator",
       "scopes": ["operator.read", "operator.write"],
       "auth": {"token": "optional-session-token"},
       "client": {"id": "my-client"}
     }
   }
   ```
3. Server responds with a `hello-ok` frame containing available methods, events, initial snapshot, and the resolved auth context.
4. All subsequent requests use the established auth context.
5. Sending `connect` again on the same connection returns `ALREADY_CONNECTED`.

### Error Codes

| Code | Atom | Description |
|------|------|-------------|
| `INVALID_REQUEST` | `:invalid_request` | Malformed request or missing required fields |
| `INVALID_PARAMS` | `:invalid_params` | Invalid method parameters |
| `METHOD_NOT_FOUND` | `:method_not_found` | Unknown method name |
| `UNAUTHORIZED` | `:unauthorized` | Authentication required or invalid token |
| `FORBIDDEN` | `:forbidden` | Insufficient permissions |
| `NOT_FOUND` | `:not_found` | Requested resource not found |
| `CONFLICT` | `:conflict` | Resource state conflict |
| `RATE_LIMITED` | `:rate_limited` | Too many requests |
| `TIMEOUT` | `:timeout` | Operation timed out |
| `INTERNAL_ERROR` | `:internal_error` | Server error |
| `NOT_IMPLEMENTED` | `:not_implemented` | Method not yet implemented |
| `HANDSHAKE_REQUIRED` | `:handshake_required` | Must complete `connect` handshake first |
| `ALREADY_CONNECTED` | `:already_connected` | Connection already established |
| `UNAVAILABLE` | `:unavailable` | Resource temporarily unavailable |

## Authentication and Authorization

### Roles and Scopes

| Role | Scopes | How Established |
|------|--------|-----------------|
| `operator` | `admin`, `read`, `write`, `approvals`, `pairing` | Default (no token); or explicitly via `connect` params |
| `node` | `invoke`, `event` | Token from `connect.challenge` after node pairing |
| `device` | `control` | Token from `connect.challenge` after device pairing |

Scope strings used in `connect` params: `operator.admin`, `operator.read`, `operator.write`, `operator.approvals`, `operator.pairing`, `node.invoke`, `node.event`, `device.control`.

Without a token, operators receive the scopes listed in `connect` params (or all operator scopes by default). With a valid token, role and scopes are derived from the stored identity.

### Token-Based Authentication (Nodes/Devices)

1. Node calls `node.pair.request` with nodeType and nodeName.
2. Operator approves via `node.pair.approve`.
3. Node calls `node.pair.verify` with the pairing code and receives a challenge.
4. Node calls `connect.challenge` with the challenge and receives a session token (default TTL: 24 hours).
5. Node uses `{"auth": {"token": "..."}}` in future `connect` calls.

Token validation is handled by `Auth.TokenStore`, backed by `LemonCore.Store` under the `:session_tokens` namespace. Tokens are validated on each connection attempt and expired tokens are cleaned up lazily.

### Method Scopes

Each method declares required scopes. A connection must have at least one matching scope. Methods with an empty scope list are public (no auth required).

| Scope | Purpose |
|-------|---------|
| `[]` (empty) | Public: `health`, `connect`, `connect.challenge` |
| `[:read]` | Read operations: list, get, status, describe |
| `[:write]` | Write operations: send, agent, chat, wake, endpoints |
| `[:admin]` | Admin operations: config, secrets, cron, sessions mutation, install, reload |
| `[:approvals]` | Approval management: `exec.approvals.*`, `exec.approval.*` |
| `[:pairing]` | Pairing operations: `node.pair.*`, `device.pair.*` |
| `[:invoke, :event]` | Node-only operations: `node.invoke.result`, `node.event`, `skills.bins` |
| `[:control]` | Device-only operations |

## API Method Inventory

### System and Utility

| Method | Scope | Description |
|--------|-------|-------------|
| `health` | none | Basic health check (uptime, memory, schedulers) |
| `status` | read | System status (connections, runs, channels, skills) |
| `introspection.snapshot` | read | Consolidated snapshot of agents, sessions, channels, transports |
| `logs.tail` | read | Tail recent log lines |
| `models.list` | read | List available AI models |
| `usage.status` | read | Current usage summary |
| `usage.cost` | read | Cost breakdown for a date range |
| `system-presence` | read | Current presence data |
| `system-event` | write | Emit a system event |
| `system.reload` | admin | Runtime reload of module/app/extension/all scopes |
| `update.run` | admin | Trigger a system update (capability-gated) |

### Agent Management

| Method | Scope | Description |
|--------|-------|-------------|
| `agent` | write | Submit an agent run (requires `prompt`) |
| `agent.wait` | write | Submit and wait for completion |
| `agent.progress` | read | Get progress for an active session |
| `agent.identity.get` | read | Get agent capabilities/identity |
| `agent.inbox.send` | write | Send message to agent inbox with routing |
| `agent.targets.list` | read | List agent routing targets |
| `agent.directory.list` | read | List agent directory entries |
| `agent.endpoints.list` | read | List agent HTTP endpoints |
| `agent.endpoints.set` | write | Configure agent endpoint |
| `agent.endpoints.delete` | write | Remove agent endpoint |
| `agents.list` | read | List available agents |
| `agents.files.list` | read | List agent files |
| `agents.files.get` | read | Get file content |
| `agents.files.set` | admin | Set file content |

### Session Management

| Method | Scope | Description |
|--------|-------|-------------|
| `sessions.list` | read | List all sessions with pagination |
| `sessions.active` | read | Get currently active session |
| `sessions.active.list` | read | List all active sessions with harness progress |
| `sessions.preview` | read | Preview session messages |
| `session.detail` | read | Deep session/run internals |
| `sessions.patch` | admin | Modify session (toolPolicy, model, thinkingLevel) |
| `sessions.reset` | admin | Clear session history |
| `sessions.delete` | admin | Delete a session |
| `sessions.compact` | admin | Compact session storage |

### Monitoring and Introspection

| Method | Scope | Description |
|--------|-------|-------------|
| `runs.active.list` | read | Active run list from RunRegistry |
| `runs.recent.list` | read | Recent completed/errored/aborted runs |
| `run.graph.get` | read | Parent/child run graph with optional records/events |
| `run.introspection.list` | read | Introspection timeline for one run |
| `tasks.active.list` | read | Active task/subagent records |
| `tasks.recent.list` | read | Recent terminal task records |

### Chat

| Method | Scope | Description |
|--------|-------|-------------|
| `chat.send` | write | Send message to session; returns `runId` and `sessionKey` |
| `chat.abort` | write | Abort a running session or run |
| `chat.history` | read | Get chat history for a session |
| `send` | write | Send a message to a channel (no agent run) |

### Configuration and Secrets

| Method | Scope | Description |
|--------|-------|-------------|
| `config.get` | read | Get config value(s) |
| `config.set` | admin | Set config value |
| `config.patch` | admin | Partial config update |
| `config.schema` | read | Get config schema |
| `config.reload` | admin | Reload configuration |
| `secrets.list` | read | List secret metadata (no values) |
| `secrets.set` | admin | Store secret |
| `secrets.delete` | admin | Remove secret |
| `secrets.exists` | read | Check if secret exists |
| `secrets.status` | read | Get secrets store status |

### Cron Jobs

| Method | Scope | Description |
|--------|-------|-------------|
| `cron.list` | read | List cron jobs |
| `cron.add` | admin | Add a cron job (requires name, schedule, agentId, sessionKey, prompt) |
| `cron.update` | admin | Update mutable fields of a cron job |
| `cron.remove` | admin | Remove a cron job |
| `cron.run` | admin | Manually trigger a cron job |
| `cron.runs` | read | List runs for a job |
| `cron.status` | read | Cron system status with active/recent run counters |

### Exec Approvals

| Method | Scope | Description |
|--------|-------|-------------|
| `exec.approvals.get` | approvals | Get approval policy for an agent |
| `exec.approvals.set` | approvals | Set approval policy for an agent |
| `exec.approvals.node.get` | approvals | Get approval policy for a node |
| `exec.approvals.node.set` | approvals | Set approval policy for a node |
| `exec.approval.request` | approvals | Request an approval for a tool use |
| `exec.approval.resolve` | approvals | Resolve a pending approval |

### Node Management

| Method | Scope | Description |
|--------|-------|-------------|
| `node.list` | read | List paired nodes |
| `node.describe` | read | Get node details |
| `node.rename` | write | Rename a node |
| `node.invoke` | write | Invoke a method on a node |
| `node.invoke.result` | invoke | Node reports invocation result (node-only) |
| `node.event` | event | Node sends an event (node-only) |
| `node.pair.request` | pairing | Request to pair a node |
| `node.pair.list` | pairing | List pending pairing requests |
| `node.pair.approve` | pairing | Approve a pairing request |
| `node.pair.reject` | pairing | Reject a pairing request |
| `node.pair.verify` | pairing | Verify a pairing code |

### Channels and Transports

| Method | Scope | Description |
|--------|-------|-------------|
| `channels.status` | read | Status of all configured channels |
| `transports.status` | read | Status of all configured transports |
| `channels.logout` | admin | Logout from a channel |

### Skills

| Method | Scope | Description |
|--------|-------|-------------|
| `skills.status` | read | List skills and their status |
| `skills.bins` | read | Get skill bin paths (node-only in practice) |
| `skills.install` | admin | Install a skill |
| `skills.update` | admin | Update/configure a skill |

### Events and Subscriptions

| Method | Scope | Description |
|--------|-------|-------------|
| `events.subscribe` | read | Subscribe to event topics |
| `events.unsubscribe` | read | Unsubscribe from event topics |
| `events.subscriptions.list` | read | List current subscriptions |
| `events.ingest` | write | Ingest external events |

### Games Token Administration (JSON-RPC)

| Method | Scope | Description |
|--------|-------|-------------|
| `games.token.issue` | admin | Issue a bearer token with `games:*` scopes |
| `games.tokens.list` | admin | List issued game tokens (metadata only) |
| `games.token.revoke` | admin | Revoke a game token by id |

### Voice / TTS (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `voicewake.get` | read | Get voicewake settings |
| `voicewake.set` | write | Set voicewake enabled/keyword |
| `tts.status` | read | TTS status |
| `tts.providers` | read | List TTS providers |
| `tts.enable` | write | Enable TTS |
| `tts.disable` | write | Disable TTS |
| `tts.convert` | write | Convert text to speech |
| `tts.set-provider` | write | Set active TTS provider |

### Device Pairing (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `device.pair.request` | pairing | Request to pair a device |
| `device.pair.approve` | pairing | Approve a device pairing |
| `device.pair.reject` | pairing | Reject a device pairing |
| `connect.challenge` | none | Exchange pairing challenge for a session token |

### Wizard (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `wizard.start` | admin | Start a wizard flow |
| `wizard.step` | admin | Advance wizard step |
| `wizard.cancel` | admin | Cancel a wizard |

### Automation

| Method | Scope | Description |
|--------|-------|-------------|
| `wake` | write | Wake an agent |
| `set-heartbeats` | write | Enable/configure heartbeat monitoring |
| `last-heartbeat` | read | Get last heartbeat for an agent |
| `talk.mode` | write | Set talk mode for a session |
| `browser.request` | write | Send a request to a paired browser node |

## Event System

The EventBridge subscribes to `LemonCore.Bus` topics and maps internal bus events to WebSocket event frames. Events are broadcast to all connected clients via a supervised task fanout.

### Subscribed Bus Topics

- `run:*` -- Run lifecycle events (dynamic subscription per run)
- `exec_approvals` -- Approval request/resolution events
- `cron` -- Cron job lifecycle events
- `system` -- System events (shutdown, health, tick, talk mode)
- `nodes` -- Node pairing events
- `presence` -- Connection presence events

### WebSocket Events

| Event | Trigger |
|-------|---------|
| `agent` | Run started/completed, tool use |
| `chat` | Chat delta/streaming content |
| `presence` | Connection count changed |
| `tick` | Heartbeat tick |
| `heartbeat` | Agent heartbeat or alert |
| `exec.approval.requested` | Approval needed |
| `exec.approval.resolved` | Approval decided |
| `cron` | Cron job started/completed |
| `cron.job` | Cron job created/updated/deleted |
| `task.started` | Subtask/subagent started |
| `task.completed` | Subtask/subagent completed |
| `task.error` | Subtask/subagent errored |
| `task.timeout` | Subtask/subagent timed out |
| `task.aborted` | Subtask/subagent aborted |
| `run.graph.changed` | Run graph/status changed |
| `shutdown` | System shutting down |
| `health` | Health status changed |
| `talk.mode` | Talk mode changed |
| `node.pair.requested` | Node wants to pair |
| `node.pair.resolved` | Node pairing approved/rejected |
| `node.invoke.request` | Operator invoked a node method |
| `node.invoke.completed` | Node invoke completed |
| `device.pair.requested` | Device wants to pair |
| `device.pair.resolved` | Device pairing approved/rejected |
| `voicewake.changed` | Voicewake config changed |
| `custom` | Custom event via `system-event` |

### State Versioning

State-versioned events include a `stateVersion` map for client reconciliation. Version counters are bumped for `presence`, `health`, and `cron` keys on relevant events. Clients can use these versions to detect stale state and reconcile without re-fetching.

## Presence System

`LemonControlPlane.Presence` is an ETS-backed GenServer that tracks all connected WebSocket clients. It provides:

- Registration/unregistration on connect/disconnect
- Role-based counting (operators, nodes, devices)
- Client lookup by connection ID
- Broadcast to all or filtered connected clients
- Automatic `presence_changed` bus event emission on changes

## Schema Validation

Method parameters are validated against schemas defined in `Protocol.Schemas` before dispatch. Schemas specify:

- **Required fields** with types -- requests missing these fields are rejected.
- **Optional fields** with types -- provided values are type-checked.
- **Supported types**: `:string`, `:integer`, `:boolean`, `:map`, `:list`, `:any`.

Methods without a schema entry accept any parameters.

## Capability-Gated Methods

Some method groups can be enabled/disabled via application configuration. Disabled capability methods are not registered in the ETS table at startup and return `METHOD_NOT_FOUND`.

| Capability | Methods |
|------------|---------|
| `voicewake` | `voicewake.get`, `voicewake.set` |
| `tts` | `tts.status`, `tts.providers`, `tts.enable`, `tts.disable`, `tts.convert`, `tts.set-provider` |
| `updates` | `update.run` |
| `device_pairing` | `device.pair.*`, `connect.challenge` |
| `wizard` | `wizard.start`, `wizard.step`, `wizard.cancel` |

## Configuration

### Application Environment

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:port` | integer | `4040` (prod), `0` (test) | HTTP server port |
| `:capabilities` | `:default` / list / map | `:default` | Enable/disable capability groups |
| `:git_commit` | string / nil | nil | Git commit hash for server info |

### Capabilities Configuration

```elixir
# Enable all capabilities (default)
config :lemon_control_plane, capabilities: :default

# Enable only specific capabilities
config :lemon_control_plane, capabilities: [:tts, :voicewake]

# Fine-grained control with a map
config :lemon_control_plane, capabilities: %{tts: true, wizard: false}
```

### Port Configuration

```elixir
config :lemon_control_plane, port: 4040
```

In test mode, the port defaults to `0` (OS-assigned) to avoid conflicts.

## Dependencies

### Umbrella Dependencies

| App | Relationship |
|-----|-------------|
| `lemon_core` | Store, secrets, event bus, idempotency, telemetry |
| `lemon_router` | Run submission (`LemonRouter.submit/1`, `LemonRouter.RunOrchestrator`) |
| `lemon_channels` | Channel backends, Outbox for `send` method |
| `lemon_games` | Games platform match service, auth, rate limiting |
| `lemon_skills` | Skill management |
| `lemon_automation` | Cron manager, heartbeat features |
| `coding_agent` | Compile-time only (not started at runtime) |
| `ai` | AI/model integration |

### External Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `bandit` | ~> 1.5 | HTTP/WebSocket server |
| `plug` | ~> 1.16 | HTTP routing and middleware |
| `websock_adapter` | ~> 0.5 | WebSocket adapter for Plug |
| `jason` | ~> 1.4 | JSON encoding/decoding |

## Running

```bash
# Start the umbrella (control plane starts automatically)
iex -S mix

# Run tests
mix test apps/lemon_control_plane

# Run a specific test file
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs
```

The server starts automatically via the OTP application supervision tree. Connect with any WebSocket client to `ws://localhost:4040/ws` and send a `connect` request to begin.
