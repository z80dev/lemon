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
                                            │ Schema Validate│
                                            │(Schemas module)│
                                            └───────┬────────┘
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
| `LemonControlPlane` | Main module, protocol/server version |
| `LemonControlPlane.Application` | OTP supervision tree |
| `LemonControlPlane.HTTP.Router` | HTTP routing (Bandit/Plug): `/ws` and `/healthz` |
| `LemonControlPlane.WS.Connection` | WebSocket connection handler (`WebSock` behaviour) |
| `LemonControlPlane.Presence` | Connected client tracking (ETS-backed GenServer) |
| `LemonControlPlane.EventBridge` | Bus events → WebSocket fanout (GenServer + Task.Supervisor) |
| `LemonControlPlane.Auth.Authorize` | Role-based access control; `from_params/1`, `authorize/3`, `default_operator/0` |
| `LemonControlPlane.Auth.TokenStore` | Token storage/validation for node/device auth (backed by `LemonCore.Store`) |
| `LemonControlPlane.Methods.Registry` | Method dispatch registry (ETS); `dispatch/3`, `register/1`, `unregister/1` |
| `LemonControlPlane.Protocol.Frames` | Protocol frame encoding/decoding; `parse/1`, `encode_response/2`, `encode_event/4`, `encode_hello_ok/1` |
| `LemonControlPlane.Protocol.Errors` | Standard error constructors; `invalid_request/1`, `not_found/1`, `forbidden/1`, etc. |
| `LemonControlPlane.Protocol.Schemas` | Param schema validation before dispatch; `validate/2` |
| `LemonControlPlane.Method` | Behaviour for method handlers; also provides `require_param/2` helper |

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

### Register the Method

Add to the `@builtin_methods` list in `LemonControlPlane.Methods.Registry`:

```elixir
@builtin_methods [
  # ... existing methods ...
  LemonControlPlane.Methods.MyMethod,
]
```

If the method belongs to a capability group (tts, voicewake, updates, device_pairing, wizard), add it to `@capability_methods` instead. Capability-gated methods can be disabled via the `:lemon_control_plane, :capabilities` application env.

### Add a Schema

Add an entry to `LemonControlPlane.Protocol.Schemas` (`@schemas` map). Schemas are validated before dispatch; methods without schemas accept any params.

```elixir
"my.method" => %{
  required: %{"requiredParam" => :string},
  optional: %{"optionalParam" => :integer}
}
```

Supported types: `:string`, `:integer`, `:boolean`, `:map`, `:list`, `:any`.

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
| `introspection.snapshot` | read | Consolidated snapshot of agents, sessions, channels, transports |
| `logs.tail` | read | Tail recent log lines |
| `models.list` | read | List available AI models |
| `usage.status` | read | Current usage summary |
| `usage.cost` | read | Cost breakdown for a date range |
| `system-presence` | read | Current presence data |
| `system-event` | write | Emit a system event |
| `update.run` | admin | Trigger a system update |

### Session Management

| Method | Scope | Description |
|--------|-------|-------------|
| `sessions.list` | read | List all sessions with pagination |
| `sessions.active` | read | Get currently active session |
| `sessions.active.list` | read | List all active sessions |
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

1. Node calls `node.pair.request` → operator approves via `node.pair.approve`
2. Node calls `node.pair.verify` with the pairing code → gets a challenge
3. Node calls `connect.challenge` with the challenge → receives a session token (TTL: 7 days)
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

## Key Dependencies

- `bandit` - HTTP/WebSocket server
- `websock_adapter` - WebSocket adapter for Plug
- `lemon_router` - Submit agent runs (`LemonRouter.submit/1`)
- `lemon_core` - Store, secrets, event bus, idempotency
- `lemon_channels` - Channel backends (Outbox for `send` method)
- `lemon_skills` - Skill management
- `lemon_automation` - Automation/heartbeat features
- `coding_agent` - Compile-time only (not started at runtime)
- `ai` - AI/model integration
