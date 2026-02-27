# Lemon Control Plane - Agent Guide

HTTP/WebSocket API server for controlling the Lemon agent system.

## Quick Orientation

- **What**: The external API surface for the entire Lemon agent system. Clients (TUI, web, mobile, browser extensions) communicate through this app via WebSocket JSON-RPC and REST HTTP endpoints.
- **Where**: `apps/lemon_control_plane/` in the umbrella.
- **Stack**: Bandit HTTP server, Plug router, WebSock for WebSocket, ETS-backed method registry.
- **Port**: 4040 in production, 0 (OS-assigned) in test.
- **Entry point**: `LemonControlPlane.Application` starts the supervision tree.

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
- **Games platform** - REST API for turn-based agent-vs-agent games

## Architecture Overview

```
+-----------------+     HTTP/WebSocket      +------------------+
|  Clients (TUI)  |<----------------------->|  Bandit Server   |
|  Web, Mobile    |      Port 4040          |  (Router plug)   |
+-----------------+                         +--------+---------+
                                                     |
                    +--------------------------------+--------------------------+
                    |                 |               |                         |
             +------v------+  +------v------+  +-----v----------+  +----------v--------+
             |  /healthz   |  | /v1/games/* |  |     /ws        |  |  (404 fallback)   |
             |  (health)   |  | (REST API)  |  |  (WebSocket)   |  |                   |
             +-------------+  +-------------+  +------+---------+  +-------------------+
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

## Key Modules

| Module | File | Purpose |
|--------|------|---------|
| `LemonControlPlane` | `lib/lemon_control_plane.ex` | Main module, protocol/server version |
| `LemonControlPlane.Application` | `lib/lemon_control_plane/application.ex` | OTP supervision tree |
| `LemonControlPlane.HTTP.Router` | `lib/lemon_control_plane/http/router.ex` | HTTP routing (Bandit/Plug): `/ws`, `/healthz`, `/v1/games/*` |
| `LemonControlPlane.HTTP.GamesAPI` | `lib/lemon_control_plane/http/games_api.ex` | REST handler for games platform endpoints |
| `LemonControlPlane.WS.Connection` | `lib/lemon_control_plane/ws/connection.ex` | WebSocket connection handler (`WebSock` behaviour) |
| `LemonControlPlane.Presence` | `lib/lemon_control_plane/presence.ex` | Connected client tracking (ETS-backed GenServer) |
| `LemonControlPlane.EventBridge` | `lib/lemon_control_plane/event_bridge.ex` | Bus events -> WebSocket fanout (GenServer + Task.Supervisor) |
| `LemonControlPlane.Auth.Authorize` | `lib/lemon_control_plane/auth/authorize.ex` | Role-based access control; `from_params/1`, `authorize/3`, `default_operator/0` |
| `LemonControlPlane.Auth.TokenStore` | `lib/lemon_control_plane/auth/token_store.ex` | Token storage/validation for node/device auth (backed by `LemonCore.Store`) |
| `LemonControlPlane.Methods.Registry` | `lib/lemon_control_plane/methods/registry.ex` | Method dispatch registry (ETS); `dispatch/3`, `register/1`, `unregister/1`. Also defines `LemonControlPlane.Method` behaviour. |
| `LemonControlPlane.Protocol.Frames` | `lib/lemon_control_plane/protocol/frames.ex` | Protocol frame encoding/decoding; `parse/1`, `encode_response/2`, `encode_event/4`, `encode_hello_ok/1` |
| `LemonControlPlane.Protocol.Errors` | `lib/lemon_control_plane/protocol/errors.ex` | Standard error constructors; `invalid_request/1`, `not_found/1`, `forbidden/1`, etc. |
| `LemonControlPlane.Protocol.Schemas` | `lib/lemon_control_plane/protocol/schemas.ex` | Param schema validation before dispatch; `validate/2` |

## JSON-RPC Method Structure

### Adding a New Method

**Step 1: Create the method module** in `lib/lemon_control_plane/methods/`:

```elixir
defmodule LemonControlPlane.Methods.MyMethod do
  @moduledoc """
  Handler for the my.method control plane method.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "my.method"

  @impl true
  def scopes, do: [:read]  # or :write, :admin, :approvals, :pairing, :invoke, :event, :control

  @impl true
  def handle(params, ctx) do
    # params: map() | nil - method parameters (already schema-validated)
    # ctx: %{auth: auth_context, conn_id: String.t(), conn_pid: pid()}

    # Use require_param/2 for concise required param extraction:
    with {:ok, required_param} <- LemonControlPlane.Method.require_param(params, "requiredParam") do
      # Do work...
      {:ok, %{"result" => "success"}}
    end
  end
end
```

**Error return formats** (from the `LemonControlPlane.Method` callback spec):
```elixir
{:ok, payload}                                    # success
{:error, {atom(), String.t()}}                    # e.g. {:not_found, "Session not found"}
{:error, {atom(), String.t(), term()}}            # e.g. {:invalid_request, "msg", nil}
```

Use helpers from `LemonControlPlane.Protocol.Errors` for consistency:
```elixir
alias LemonControlPlane.Protocol.Errors

{:error, Errors.invalid_request("message")}
{:error, Errors.not_found("Resource not found")}
{:error, Errors.forbidden("Insufficient permissions")}
{:error, Errors.internal_error("Something went wrong", details)}
```

**Step 2: Register the method** in the `@builtin_methods` list in `LemonControlPlane.Methods.Registry`:

```elixir
@builtin_methods [
  # ... existing methods ...
  LemonControlPlane.Methods.MyMethod,
]
```

If the method belongs to a capability group (tts, voicewake, updates, device_pairing, wizard), add it to `@capability_methods` instead. Capability-gated methods can be disabled via the `:lemon_control_plane, :capabilities` application env.

**Step 3: Add a schema** entry to `LemonControlPlane.Protocol.Schemas` (`@schemas` map). Schemas are validated before dispatch; methods without schemas accept any params.

```elixir
"my.method" => %{
  required: %{"requiredParam" => :string},
  optional: %{"optionalParam" => :integer}
}
```

Supported types: `:string`, `:integer`, `:boolean`, `:map`, `:list`, `:any`.

**Step 4: Write tests** in `test/lemon_control_plane/methods/`.

### Scope Guidelines

| Scope | Use For |
|-------|---------|
| `[]` (empty) | Public methods: `health`, `connect`, `connect.challenge` |
| `[:read]` | Read operations: list, get, status |
| `[:write]` | Write operations: send, chat, agent |
| `[:admin]` | Admin operations: config, install, cron mgmt, sessions mutation |
| `[:approvals]` | Approval management: `exec.approvals.*`, `exec.approval.*` |
| `[:pairing]` | Pairing operations: `node.pair.*`, `device.pair.*` |
| `[:invoke, :event]` | Node-only operations: `node.invoke.result`, `node.event`, `skills.bins` |
| `[:control]` | Device-only operations |

## API Method Reference

### System / Utility

| Method | Scope | Description |
|--------|-------|-------------|
| `health` | none | Basic health check |
| `status` | read | System status (connections, runs, channels, skills) |
| `introspection.snapshot` | read | Consolidated snapshot of agents, sessions, channels, transports (includes `activeSessions` harness progress projection) |
| `logs.tail` | read | Tail recent log lines |
| `models.list` | read | List available AI models |
| `usage.status` | read | Current usage summary |
| `usage.cost` | read | Cost breakdown for a date range |
| `system-presence` | read | Current presence data |
| `system-event` | write | Emit a system event |
| `system.reload` | admin | Runtime reload of module/app/extension/all scopes |
| `update.run` | admin | Trigger a system update |

### Session Management

| Method | Scope | Description |
|--------|-------|-------------|
| `sessions.list` | read | List all sessions with pagination |
| `sessions.active` | read | Get currently active session |
| `sessions.active.list` | read | List all active sessions; includes best-effort `harness` progress (todos/checkpoints/requirements) when coding-agent telemetry is available |
| `sessions.preview` | read | Preview session messages |
| `sessions.patch` | admin | Modify session (toolPolicy, model, thinkingLevel) |
| `sessions.reset` | admin | Clear session history |
| `sessions.delete` | admin | Delete a session |
| `sessions.compact` | admin | Compact session storage |
| `session.detail` | read | Deep session/run internals (tool calls, optional raw run events, run records) |

### Monitoring / Introspection

| Method | Scope | Description |
|--------|-------|-------------|
| `runs.active.list` | read | Active run list from `LemonRouter.RunRegistry` |
| `runs.recent.list` | read | Recent completed/errored/aborted runs |
| `run.graph.get` | read | Parent/child run graph with optional per-node run-store records/events and introspection |
| `run.introspection.list` | read | Introspection timeline for one run (optional run-store internals) |
| `tasks.active.list` | read | Active task/subagent records from `CodingAgent.TaskStore` |
| `tasks.recent.list` | read | Recent terminal task records with status/error classification |

`tasks.active.list` / `tasks.recent.list` infer missing `engine` from task record metadata and task event payloads (for example `details.engine`) when the persisted task record has no explicit engine field.

### Agent Management

| Method | Scope | Description |
|--------|-------|-------------|
| `agent` | write | Submit an agent run (requires `prompt`) |
| `agent.wait` | write | Submit and wait for completion |
| `agent.progress` | read | Get progress for active session |
| `agents.list` | read | List available agents |
| `agent.identity.get` | read | Get agent capabilities/identity |
| `agent.inbox.send` | write | Send message to agent inbox with routing |
| `agent.targets.list` | read | List agent routing targets |
| `agent.directory.list` | read | List agent directory entries |
| `agent.endpoints.list` | read | List agent HTTP endpoints |
| `agent.endpoints.set` | write | Configure agent endpoint |
| `agent.endpoints.delete` | write | Remove agent endpoint |
| `agents.files.list` | read | List agent files |
| `agents.files.get` | read | Get file content |
| `agents.files.set` | admin | Set file content |

### Chat

| Method | Scope | Description |
|--------|-------|-------------|
| `chat.send` | write | Send message to session; returns `runId` and `sessionKey` |
| `chat.abort` | write | Abort a running session or run |
| `chat.history` | read | Get chat history for a session |
| `send` | write | Send a message to a channel (no agent run) |

### Games APIs (Agent-vs-Agent Platform)

HTTP endpoints in `LemonControlPlane.HTTP.GamesAPI` expose turn-based game play for external agents:

- `POST /v1/games/matches` - create match challenge (`rock_paper_scissors` or `connect4`)
- `POST /v1/games/matches/:id/accept` - accept pending match
- `GET /v1/games/matches/:id` - read redacted/public match state
- `POST /v1/games/matches/:id/moves` - submit turn move (requires `idempotency_key`)
- `GET /v1/games/matches/:id/events?after_seq=N&limit=M` - poll match event feed
- `GET /v1/games/lobby` - list active/recent public matches

JSON-RPC admin methods for token lifecycle:

| Method | Scope | Description |
|--------|-------|-------------|
| `games.token.issue` | admin | Issue a bearer token with `games:*` scopes |
| `games.tokens.list` | admin | List issued game tokens (metadata only) |
| `games.token.revoke` | admin | Revoke a game token by id |

### Configuration and Secrets

| Method | Scope | Description |
|--------|-------|-------------|
| `config.get` | read | Get config value(s) |
| `config.set` | admin | Set config value |
| `config.patch` | admin | Partial config update |
| `config.schema` | read | Get config schema |
| `config.reload` | admin | Reload configuration |
| `system.reload` | admin | Runtime reload of module/app/extension/all scopes |
| `secrets.list` | read | List secret metadata (no values) |
| `secrets.set` | admin | Store secret |
| `secrets.delete` | admin | Remove secret |
| `secrets.exists` | read | Check if secret exists |
| `secrets.status` | read | Get secrets store status |

Config keys are whitelisted in `ConfigGet` to prevent atom table exhaustion. Secrets are stored via `LemonCore.Secrets` and never returned in plaintext.

### Cron Jobs

| Method | Scope | Description |
|--------|-------|-------------|
| `cron.list` | read | List cron jobs |
| `cron.add` | admin | Add a cron job (requires name, schedule, agentId, sessionKey, prompt) |
| `cron.update` | admin | Update a cron job |
| `cron.remove` | admin | Remove a cron job |
| `cron.run` | admin | Manually trigger a cron job |
| `cron.runs` | read | List runs for a job (optional output/meta/run-store/introspection payloads) |
| `cron.status` | read | Cron system status + active/recent run counters |

`cron.update` only supports mutable fields (`name`, `schedule`, `enabled`, `prompt`, `timezone`, `jitterSec`, `timeoutMs`). Attempts to update immutable routing fields (`agentId`, `sessionKey`) return `invalid_request`.

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
| `node.invoke.result` | invoke | Node reports result of an invocation (node-only) |
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
| `skills.bins` | invoke | Get skill bin paths (node-only) |
| `skills.install` | admin | Install a skill |
| `skills.update` | admin | Update/configure a skill |

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

### Automation

| Method | Scope | Description |
|--------|-------|-------------|
| `wake` | write | Wake an agent |
| `set-heartbeats` | write | Enable/configure heartbeat monitoring |
| `last-heartbeat` | read | Get last heartbeat for an agent |
| `talk.mode` | write | Set talk mode for a session |
| `browser.request` | write | Send a request to a paired browser node |

### Wizard (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `wizard.start` | admin | Start a wizard flow |
| `wizard.step` | admin | Advance wizard step |
| `wizard.cancel` | admin | Cancel a wizard |

### Events and Subscriptions

| Method | Scope | Description |
|--------|-------|-------------|
| `events.subscribe` | read | Subscribe to event topics (run, system, cron, etc.) |
| `events.unsubscribe` | read | Unsubscribe from event topics |
| `events.subscriptions.list` | read | List current subscriptions |
| `events.ingest` | write | Ingest external events |

## Authentication and Authorization

### Roles and Scopes

| Role | Scopes | How established |
|------|--------|-----------------|
| `operator` | `admin`, `read`, `write`, `approvals`, `pairing` | Default (no token); scope list in `connect` params |
| `node` | `invoke`, `event` | Token from `connect.challenge` after node pairing |
| `device` | `control` | Token from `connect.challenge` after device pairing |

Scope strings in `connect` params: `operator.admin`, `operator.read`, `operator.write`, `operator.approvals`, `operator.pairing`, `node.invoke`, `node.event`, `device.control`.

### Connection Handshake

1. Client connects via WebSocket to `/ws`
2. Client sends `connect` request:
   ```json
   {
     "type": "req",
     "id": "uuid",
     "method": "connect",
     "params": {
       "auth": {"token": "optional-token"},
       "role": "operator",
       "scopes": ["operator.read", "operator.write"]
     }
   }
   ```
3. Server responds with `hello-ok` frame (not a `res` frame) containing `features.methods`, `features.events`, `snapshot`, `auth`, and `policy`
4. All subsequent requests use the established auth context

Without a token, operators receive the scopes listed in `connect` params (or all operator scopes by default). With a valid token, role and scopes are derived from the stored identity.

### Token-Based Auth (Nodes/Devices)

1. Node calls `node.pair.request` -> operator approves via `node.pair.approve`
2. Node calls `node.pair.verify` with the pairing code -> gets a challenge
3. Node calls `connect.challenge` with the challenge -> receives a session token (TTL: 24 hours)
4. Node uses `{"auth": {"token": "..."}}` in future `connect` calls

Token validation is handled by `LemonControlPlane.Auth.TokenStore` (backed by `LemonCore.Store` under `:session_tokens` namespace).

## Presence System

`LemonControlPlane.Presence` tracks all connected WebSocket clients (ETS-backed GenServer):

```elixir
# Get connection counts
LemonControlPlane.Presence.counts()
# => %{total: 5, operators: 2, nodes: 2, devices: 1}

# List all clients
LemonControlPlane.Presence.list()
# => [{conn_id, %{role: :operator, client_id: "...", pid: pid(), connected_at: ms}}]

# Broadcast to all clients
LemonControlPlane.Presence.broadcast("event_name", payload)

# Broadcast with filter
LemonControlPlane.Presence.broadcast("event", payload, fn info ->
  info.role == :operator
end)
```

Presence changes emit a `presence_changed` bus event, which EventBridge forwards to all WS clients as a `presence` event.

## WebSocket Protocol

### Frame Types

**Request (client -> server):**
```json
{"type": "req", "id": "uuid", "method": "health", "params": {}}
```

**Response (server -> client):**
```json
{"type": "res", "id": "uuid", "ok": true, "payload": {}}
{"type": "res", "id": "uuid", "ok": false, "error": {"code": "...", "message": "..."}}
```

**Event (server -> client):**
```json
{"type": "event", "event": "chat", "seq": 1, "payload": {...}, "stateVersion": {...}}
```

**Hello-OK (handshake response, replaces `res` for `connect`):**
```json
{
  "type": "hello-ok",
  "protocol": 1,
  "server": {"version": "...", "connId": "...", "host": "..."},
  "features": {"methods": [...], "events": [...]},
  "snapshot": {"presence": {}, "health": {"ok": true}},
  "policy": {"maxPayload": 1048576, "maxBufferedBytes": 8388608, "tickIntervalMs": 1000},
  "auth": {"role": "operator", "scopes": [...]}
}
```

### Error Codes

| Code | Atom |
|------|------|
| `INVALID_REQUEST` | `:invalid_request` |
| `INVALID_PARAMS` | `:invalid_params` |
| `METHOD_NOT_FOUND` | `:method_not_found` |
| `UNAUTHORIZED` | `:unauthorized` |
| `FORBIDDEN` | `:forbidden` |
| `NOT_FOUND` | `:not_found` |
| `CONFLICT` | `:conflict` |
| `INTERNAL_ERROR` | `:internal_error` |
| `NOT_IMPLEMENTED` | `:not_implemented` |
| `HANDSHAKE_REQUIRED` | `:handshake_required` |
| `ALREADY_CONNECTED` | `:already_connected` |
| `UNAVAILABLE` | `:unavailable` |
| `TIMEOUT` | `:timeout` |

### Events

State-versioned events include a `stateVersion` map for client reconciliation (`presence`, `health`, `cron` keys are bumped on relevant changes).

| Event | Trigger |
|-------|---------|
| `agent` | Run started/completed, tool use (`type`: `started`, `completed`, `tool_use`) |
| `chat` | Chat delta/streaming content |
| `presence` | Connection count changed |
| `tick` | Heartbeat tick (from `:tick` or `:cron_tick` bus events) |
| `heartbeat` | Agent heartbeat or heartbeat alert |
| `exec.approval.requested` | Approval needed |
| `exec.approval.resolved` | Approval decided |
| `cron` | Cron job started/completed |
| `cron.job` | Cron job created/updated/deleted |
| `task.started` | Subtask/subagent started |
| `task.completed` | Subtask/subagent completed |
| `task.error` | Subtask/subagent errored |
| `task.timeout` | Subtask/subagent timed out |
| `task.aborted` | Subtask/subagent aborted/interrupted |
| `run.graph.changed` | Run graph/status changed |
| `shutdown` | System shutting down |
| `health` | Health status changed |
| `talk.mode` | Talk mode changed |
| `node.pair.requested` | Node wants to pair |
| `node.pair.resolved` | Node pairing approved or rejected |
| `node.invoke.request` | Operator invoked a node method |
| `node.invoke.completed` | Node invoke completed |
| `device.pair.requested` | Device wants to pair |
| `device.pair.resolved` | Device pairing approved or rejected |
| `voicewake.changed` | Voicewake config changed |
| `custom` | Custom event via `system-event` with custom type |

## Capability-Gated Methods

Some method groups are enabled/disabled via the `:lemon_control_plane, :capabilities` application env. Disabled capability methods are not registered in the ETS table at startup.

| Capability | Methods |
|------------|---------|
| `voicewake` | `voicewake.get`, `voicewake.set` |
| `tts` | `tts.status`, `tts.providers`, `tts.enable`, `tts.disable`, `tts.convert`, `tts.set-provider` |
| `updates` | `update.run` |
| `device_pairing` | `device.pair.*`, `connect.challenge` |
| `wizard` | `wizard.start`, `wizard.step`, `wizard.cancel` |

Configure via:
```elixir
# Enable all (default)
config :lemon_control_plane, capabilities: :default

# Enable specific capabilities
config :lemon_control_plane, capabilities: [:tts, :voicewake]

# Enable/disable with map
config :lemon_control_plane, capabilities: %{tts: true, wizard: false}
```

## EventBridge

`LemonControlPlane.EventBridge` subscribes to `LemonCore.Bus` topics (`exec_approvals`, `cron`, `system`, `nodes`, `presence`) plus dynamic `run:*` topics. It maps bus event types to WS event names and fans out to all connected clients via a `Task.Supervisor`. Subscribe to run events with `EventBridge.subscribe_run(run_id)`.

Key bus-event-to-WS-event mappings:

| Bus Event Type | WS Event Name |
|----------------|---------------|
| `:run_started` | `agent` (type: started) |
| `:run_completed` | `agent` (type: completed) |
| `:delta` | `chat` |
| `:engine_action` | `agent` (type: tool_use) |
| `:approval_requested` | `exec.approval.requested` |
| `:approval_resolved` | `exec.approval.resolved` |
| `:cron_run_started` | `cron` (type: started) |
| `:cron_run_completed` | `cron` (type: completed) |
| `:cron_job_created` | `cron.job` (type: created) |
| `:cron_job_updated` | `cron.job` (type: updated) |
| `:cron_job_deleted` | `cron.job` (type: deleted) |
| `:tick` / `:cron_tick` | `tick` |
| `:presence_changed` | `presence` |
| `:task_started` | `task.started` |
| `:task_completed` | `task.completed` |
| `:task_error` | `task.error` |
| `:task_timeout` | `task.timeout` |
| `:task_aborted` | `task.aborted` |
| `:run_graph_changed` | `run.graph.changed` |
| `:shutdown` | `shutdown` |
| `:health_changed` | `health` |

The fanout uses `Task.Supervisor` for resilience. If the supervisor is temporarily unavailable (crash/restart), it falls back to inline dispatch. Telemetry events are emitted on `[:lemon, :control_plane, :event_bridge, :broadcast]` and `[:lemon, :control_plane, :event_bridge, :dropped]`.

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
2. Implement `LemonControlPlane.Method` behaviour (`name/0`, `scopes/0`, `handle/2`)
3. Add schema entry to `LemonControlPlane.Protocol.Schemas` `@schemas` map
4. Add to `@builtin_methods` in `Registry` (or `@capability_methods` if gated)
5. Add tests in `test/lemon_control_plane/methods/`

### Add a New REST Endpoint (Games API Pattern)

1. Add the route in `lib/lemon_control_plane/http/router.ex`:
   ```elixir
   get "/v1/my/path" do
     LemonControlPlane.HTTP.MyHandler.call(conn, :my_action)
   end
   ```
2. Create the handler module with action functions that take a `conn` and return via `json/3` or `error/4` helpers.
3. Use Bearer token authentication via the `authenticate/2` pattern if auth is needed.

### Add a New WebSocket Event

1. Add the bus event type mapping in `EventBridge.map_event_type/3`.
2. Add the event name to `Protocol.Frames.supported_events/0`.
3. Optionally add state version tracking in `EventBridge.state_version_key_for/1` if the event affects reconciliation state.

### Test a Method Directly

```elixir
# In iex or test
ctx = %{auth: LemonControlPlane.Auth.Authorize.default_operator(), conn_id: "test", conn_pid: self()}

{:ok, result} = LemonControlPlane.Methods.SessionsList.handle(%{}, ctx)
```

### Debug WebSocket Connections

```elixir
# List active connections
LemonControlPlane.Presence.list()

# Get counts
LemonControlPlane.Presence.counts()

# Inspect presence ETS state
:sys.get_state(LemonControlPlane.Presence)
```

### Event Bridge Debugging

```elixir
# Force an event broadcast
LemonCore.Bus.broadcast("system", LemonCore.Event.new(:tick, %{}))

# Subscribe to run events
LemonControlPlane.EventBridge.subscribe_run("some-run-id")
```

## Testing Guidelines

- Use `async: true` for method tests that don't depend on shared state
- Tests requiring the full runtime should be marked `async: false`
- The `test_helper.exs` stops and restarts `:lemon_channels` (and related apps) to ensure a clean baseline; it also disables Telegram
- Mock external dependencies; test method logic in isolation
- Test error cases: missing params, invalid auth, not found scenarios
- For WebSocket tests, use `test/lemon_control_plane/ws/connection_test.exs` as the reference pattern
- Method tests typically verify: `name/0` returns the correct string, `scopes/0` returns expected scopes, `handle/2` succeeds with valid params, `handle/2` fails correctly with invalid/missing params
- The test suite at `test/lemon_control_plane/methods/control_plane_methods_test.exs` covers many methods in a single file using `describe` blocks per method

### Test File Organization

| Test File | Covers |
|-----------|--------|
| `methods/control_plane_methods_test.exs` | Broad coverage of many individual method modules |
| `methods/agent_routing_methods_test.exs` | Agent inbox, directory, targets, endpoints |
| `methods/agents_files_test.exs` | Agent file management methods |
| `methods/node_methods_test.exs` | Node management and invocation |
| `methods/secrets_methods_test.exs` | Secrets CRUD |
| `methods/skills_methods_test.exs` | Skills status, install, update |
| `methods/system_methods_test.exs` | System event, presence |
| `methods/system_reload_test.exs` | System reload scopes |
| `methods/heartbeat_methods_test.exs` | Heartbeat/wake methods |
| `methods/sessions_patch_test.exs` | Session patching |
| `methods/send_test.exs` / `send_idempotency_test.exs` | Channel send with idempotency |
| `methods/connect_challenge_test.exs` | Token exchange flow |
| `methods/exec_approvals_test.exs` | Approval policy methods |
| `methods/cron_methods_test.exs` | Cron management methods |
| `methods/monitoring_methods_test.exs` | Runs and tasks methods |
| `methods/introspection_methods_test.exs` | Introspection/snapshot methods |
| `methods/registry_test.exs` | ETS registry dispatch |
| `methods/event_type_validation_test.exs` / `event_type_atom_leak_test.exs` | Event type safety |
| `auth/authorize_test.exs` / `authorize_expiration_test.exs` | Authorization logic |
| `auth/token_store_persistence_test.exs` | Token storage |
| `ws/connection_test.exs` | WebSocket connection lifecycle |
| `protocol/errors_test.exs` / `frames_test.exs` / `schemas_test.exs` | Protocol layer |
| `presence_test.exs` | Presence tracking |
| `event_bridge_test.exs` / `event_bridge_tick_test.exs` / `event_bridge_monitoring_test.exs` / `event_bridge_mapping_test.exs` | EventBridge fanout |

## Connections to Other Apps

| Dependency | How Used |
|------------|----------|
| `lemon_core` | `LemonCore.Store` (token persistence, idempotency), `LemonCore.Bus` (event pub/sub), `LemonCore.Secrets`, `LemonCore.Event`, `LemonCore.Telemetry` |
| `lemon_router` | `LemonRouter.submit/1` and `LemonRouter.RunOrchestrator.submit/1` for agent run submission; `LemonRouter.RunRegistry` for active run queries |
| `lemon_channels` | `LemonChannels.Outbox` for `send` method; channel status queries |
| `lemon_games` | `LemonGames.Matches.Service` for match CRUD; `LemonGames.Auth` for bearer token validation; `LemonGames.RateLimit` for move rate limiting |
| `lemon_skills` | Skill status, installation, and binary path queries |
| `lemon_automation` | `LemonAutomation.CronManager` for cron CRUD; heartbeat management |
| `coding_agent` | Compile-time only (not started at runtime); `CodingAgent.TaskStore` for task queries |
| `ai` | AI model listing and configuration |
| `agent_core` | Agent profile and identity queries |

## Key Dependencies

- `bandit` - HTTP/WebSocket server
- `websock_adapter` - WebSocket adapter for Plug
- `plug` - HTTP routing and middleware
- `jason` - JSON encoding/decoding
