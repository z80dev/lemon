# Lemon Control Plane - Agent Guide

HTTP/WebSocket API server for controlling the Lemon agent system.

## Quick Orientation

- **What**: The external API surface for the entire Lemon agent system. Clients (TUI, web, mobile, browser extensions) communicate through this app via WebSocket JSON-RPC and REST HTTP endpoints.
- **Where**: `apps/lemon_control_plane/` in the umbrella.
- **Stack**: Bandit HTTP server, Plug router, WebSock for WebSocket, ETS-backed method registry.
- **Port**: 4040 in production, 0 (OS-assigned) in test.
- **Entry point**: `LemonControlPlane.Application` starts the supervision tree.

## Purpose and Responsibilities

The application also owns Lemon's optional A2A v1.0 network edge. Keep A2A
authentication, Agent Cards, JSON-RPC/SSE framing, rate limiting, and supervised
task reattachment in `LemonControlPlane.A2A.*`. Conversation persistence and
generic wire/client helpers belong to `lemon_core`; agent-facing outbound peer
actions belong to `lemon_skills`. A2A peers are independent principals and
must never be treated as named execution nodes or operator WebSocket clients.

The control plane provides the external interface for clients (TUI, web, mobile, browser extensions) to:

- **Submit agent runs** - Send prompts to agents via `agent` or `chat.send`
- **Manage sessions** - List, reset, delete conversation sessions
- **Configure the system** - Get/set config values, reload config
- **Manage secrets** - Store and retrieve API keys securely
- **Schedule cron jobs** - Create recurring agent runs
- **Install skills** - Manage agent capabilities
- **Pair nodes/devices** - Connect restricted clients, including named native coding execution nodes
- **Stream real-time events** - WebSocket events for runs, chat deltas, approvals

## Architecture Overview

```
+-----------------+     HTTP/WebSocket      +------------------+
|  Clients (TUI)  |<----------------------->|  Bandit Server   |
|  Web, Mobile    |      Port 4040          |  (Router plug)   |
+-----------------+                         +--------+---------+
                                                     |
                    +--------------------------------+--------------------------+
                    |                 |               |                         |
             +------v------+  +-----v----------+  +----------v--------+
             |  /healthz   |  |     /ws        |  |  (404 fallback)   |
             |  (health)   |  |  (WebSocket)   |  |                   |
             +-------------+  +------+---------+  +-------------------+
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
| `LemonControlPlane.HTTP.Router` | `lib/lemon_control_plane/http/router.ex` | HTTP routing (Bandit/Plug): `/ws`, `/healthz`, preview `/v1` OpenAI-compatible endpoints, preview `/acp` JSON-RPC endpoint |
| `LemonControlPlane.OpenAICompat` | `lib/lemon_control_plane/openai_compat.ex` | Preview `/v1/models`, `/v1/chat/completions`, `/v1/responses`, `/v1/runs/*`, and stored response adapter over Lemon model metadata, router-submitted runs, optional `agent.wait` synchronous completion, SSE streaming with redacted tool progress, run-store response retrieval, `supportsVision` model metadata, redacted URL/file-id image metadata plus data URL and opt-in allowlisted URL runtime image pass-through with known text-only model rejection before submission, redacted run status, and cancellation dispatch |
| `LemonControlPlane.ACP` | `lib/lemon_control_plane/acp.ex` | Preview Agent Client Protocol JSON-RPC bridge for initialize, store-backed session lifecycle, text/resource-link prompt submission through Lemon router runs, wait/queued prompt behavior, run-bus `session/update` projection, ACP filesystem client-request summaries, cancel/close, and honest capability negotiation |
| `LemonControlPlane.ACP.NDJSON` | `lib/lemon_control_plane/acp/ndjson.ex` | Newline-delimited JSON transport helper used by `scripts/lemon_acp_stdio.exs` for spawned ACP stdio clients, including intermediate `session/update` notification lines and permission/read/write/delete/rename client requests while prompt waits are active |
| `LemonControlPlane.WS.Connection` | `lib/lemon_control_plane/ws/connection.ex` | WebSocket connection handler (`WebSock` behaviour) |
| `LemonControlPlane.Presence` | `lib/lemon_control_plane/presence.ex` | Connected client tracking (ETS-backed GenServer) |
| `LemonControlPlane.NodeStore` | `lib/lemon_control_plane/node_store.ex` | Durable node identities, unique-name reservations, pairing challenges, and invocation status |
| `LemonControlPlane.EventBridge` | `lib/lemon_control_plane/event_bridge.ex` | Bus events -> WebSocket fanout (GenServer + Task.Supervisor) |
| `LemonControlPlane.Auth.Authorize` | `lib/lemon_control_plane/auth/authorize.ex` | Role-based access control; peer-aware `from_params/2`, constant-time operator-token validation, `authorize/3`, `default_operator/0` |
| `LemonControlPlane.Auth.TokenStore` | `lib/lemon_control_plane/auth/token_store.ex` | Token storage/validation for node/device auth (backed by `LemonCore.Store`) |
| `LemonControlPlane.AgentIdentityStore` | `lib/lemon_control_plane/agent_identity_store.ex` | Typed wrapper for persisted agent identity records |
| `LemonControlPlane.UpdateStore` | `lib/lemon_control_plane/update_store.ex` | Typed wrapper for update config and pending-update state |
| `LemonControlPlane.SkillsConfigStore` | `lib/lemon_control_plane/skills_config_store.ex` | Typed wrapper for fallback persisted skill config |
| `LemonControlPlane.Methods.Registry` | `lib/lemon_control_plane/methods/registry.ex` | Method dispatch registry (ETS); `dispatch/3`, `register/1`, `unregister/1`. Also defines `LemonControlPlane.Method` behaviour. |
| `LemonControlPlane.Methods.CommandsCatalog` | `lib/lemon_control_plane/methods/commands_catalog.ex` | Read-only `commands.catalog` discovery projection over `LemonChannels.CommandCatalog`; execution remains with consuming surfaces and runtime owners. |
| `LemonControlPlane.Methods.Background*` / `SessionBtw` | `lib/lemon_control_plane/methods/background_commands.ex` | Provider-backed lifecycle RPCs for isolated `/bg` sessions and bounded no-tools `/btw` questions; the control plane owns only validation and wire projection. |
| `LemonControlPlane.Methods.SessionHeartbeat` | `lib/lemon_control_plane/methods/session_heartbeat.ex` | Admin projection for status/set/pause/resume/clear of a live durable coding-session heartbeat; validates provider state before returning it. |
| `LemonControlPlane.Methods.Profiles*` / `ProfileChat` | `lib/lemon_control_plane/methods/profiles.ex` | Lifecycle, node-aware roster, credential-safe export, and stable canonical chat projection over `LemonCore.ProfileStore` and the existing router. |
| `LemonControlPlane.Protocol.Frames` | `lib/lemon_control_plane/protocol/frames.ex` | Protocol frame encoding/decoding; `parse/1`, `encode_response/2`, `encode_event/4`, `encode_hello_ok/1` |
| `LemonControlPlane.Protocol.Errors` | `lib/lemon_control_plane/protocol/errors.ex` | Standard error constructors; `invalid_request/1`, `not_found/1`, `forbidden/1`, etc. |
| `LemonControlPlane.Protocol.Schemas` | `lib/lemon_control_plane/protocol/schemas.ex` | Param and event payload schema validation; `validate/2`, `validate_event/2` |
| `LemonCore.NodeRegistry` | `apps/lemon_core/lib/lemon_core/node_registry.ex` | Live name/ID resolution, targeted delivery, timeout/cancellation, disconnect failure, and invocation ownership |

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

The per-method inventory (method, scope, one-line description) is the
"API Method Inventory" section of `README.md`; keep it there, not here.
`LemonControlPlane.Protocol.Schemas` is the executable definition and
`test/lemon_control_plane/methods_parity_test.exs` keeps the two aligned.

## Authentication and Authorization

Roles, scopes, the connection handshake and token-based auth for nodes and
devices are documented in `README.md` ("Authentication and Authorization").
The rule that matters when adding a method: declare its scope in the method
module and never widen a scope to make a test pass.

## WebSocket Protocol

Frame types, error codes and the event catalogue are in `README.md`
("WebSocket Protocol" and "Event System"); presence and capability gating
are there too.

## EventBridge

`LemonControlPlane.EventBridge` subscribes to `LemonCore.Bus` topics (`exec_approvals`, `channels`, `cron`, `goals`, `system`, `nodes`, `presence`) plus dynamic `run:*` and `session:*` topics. It maps bus event types to WS event names and fans out via a `Task.Supervisor`; each non-node WebSocket connection then applies its own topic filter before pushing the event frame. Authenticated node connections are excluded from this general fanout and receive only targeted `node_event` traffic. New non-node connections keep legacy all-event delivery until they set explicit subscriptions, while a clear-all unsubscribe suppresses later events for that connection. Subscribe to run events with `EventBridge.subscribe_run(run_id)` or generic dynamic topics with `EventBridge.subscribe_topics/1`.

WebSocket method handlers are inline unless their optional
`dispatch_mode/0` callback returns `:async`. Reserve async dispatch for work
that waits on human approval or slow external systems and does not require
`self()` to be the connection process. Approval-gated skill install/update
handlers are async so `exec.approval.*` events, approval resolution requests,
and liveness probes continue flowing while the mutation waits. Such handlers
must use `ctx.conn_pid` for the authenticated socket identity.

Key bus-event-to-WS-event mappings:

| Bus Event Type | WS Event Name |
|----------------|---------------|
| `:run_started` | `agent` (type: started) |
| `:run_completed` | `agent` (type: completed) |
| `:delta` | `chat` |
| `:engine_action` | `agent` (type: tool_use) |
| `:goal_set` / `:goal_paused` / `:goal_resumed` / `:goal_completed` / `:goal_cleared` | `goal` |
| `:goal_continuation_submitted` / `:goal_loop_verdict` / `:goal_loop_status` | `goal` |
| `:approval_requested` | `exec.approval.requested` with pending approval `action` metadata |
| `:approval_resolved` | `exec.approval.resolved` with approval id, decision, and pending approval metadata when available; timeouts use `decision: "timeout"` |
| `:cron_run_started` | `cron` (type: started) |
| `:cron_run_completed` | `cron` (type: completed) |
| `:cron_job_created` | `cron.job` (type: created) |
| `:cron_job_updated` | `cron.job` (type: updated) |
| `:cron_job_deleted` | `cron.job` (type: deleted) |
| `:cron_lifecycle_action` | `cron.audit` |
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

### Join a Named Coding Execution Node

Start the controller normally, then run from the destination source checkout:

```bash
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join \
  --name worker-1 \
  --controller wss://controller.example/ws \
  --pair \
  --cwd /srv/project
```

Later starts omit `--pair` and reuse the controller-bound token. Re-run with
`--pair` when that seven-day session expires. Use
`LEMON_NODE_TOKEN` to supply an existing token without placing it in shell
history. A name must be unique on the controller, and the destination cwd must
already exist.

Non-loopback plaintext `ws://` is rejected by default. A Tailscale deployment
may use `--controller ws://controller:4040/ws --allow-insecure-controller`
only after verifying that the complete path stays on the authenticated,
encrypted overlay; otherwise use `wss://`.

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
3. Add an event payload schema to `Protocol.Schemas` (`@event_schemas`) when clients depend on the event shape.
4. Optionally add state version tracking in `EventBridge.state_version_key_for/1` if the event affects reconciliation state.

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

Control-plane WebSocket operator authentication uses
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`. The HTTP router must pass the actual socket
peer to `WS.Connection`; tokenless operator compatibility must remain default-off
and, when explicitly enabled, direct-loopback-only. Do not restore params-only
node/device roles or map an unknown session-token identity to operator scopes.
Keep credentials out of URLs, auth contexts, logs, status formatting, and error
payloads.

- Use `async: true` for method tests that don't depend on shared state
- Tests requiring the full runtime should be marked `async: false`
- The `test_helper.exs` stops and restarts `:lemon_channels` (and related apps),
  then explicitly ensures `:lemon_control_plane` is running. Umbrella app suites
  share one BEAM, so the suite must establish its own supervised Registry/ETS
  baseline even when an earlier app suite stopped the control plane; it also
  disables Telegram.
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
| `methods/blueprints_test.exs` | Catalog containment, content-free review, exact confirmation, profile activation, and duplicate-safe replay |
| `methods/system_methods_test.exs` | System event, presence |
| `methods/config_reload_test.exs` | Config reload lifecycle summaries |
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
| `tui_profiles_wire_e2e_test.exs` | Authenticated real-Bandit profile lifecycle/canonical-chat proof driven by the typed Bun TUI client |
| `protocol/errors_test.exs` / `frames_test.exs` / `schemas_test.exs` | Protocol layer |
| `presence_test.exs` | Presence tracking |
| `event_bridge_test.exs` / `event_bridge_tick_test.exs` / `event_bridge_monitoring_test.exs` / `event_bridge_mapping_test.exs` | EventBridge fanout |

## Connections to Other Apps

| Dependency | How Used |
|------------|----------|
| `lemon_core` | `LemonCore.Store` (token persistence, idempotency), `LemonCore.NodeRegistry` (live named-node delivery), `LemonCore.Bus` (event pub/sub), `LemonCore.Secrets`, `LemonCore.Event`, `LemonCore.Telemetry` |
| `lemon_router` | `LemonRouter.submit/1` and `LemonRouter.RunOrchestrator.submit/1` for agent run submission; `LemonRouter.RunRegistry` for active run queries |
| `lemon_channels` | `LemonChannels.Outbox` for `send` method; channel status queries |
| `lemon_skills` | Skill status, installation, and binary path queries |
| `lemon_automation` | `LemonAutomation.CronManager` for cron CRUD and heartbeat management; `LemonAutomation.Blueprint` for safe catalog-scoped skill + cron activation |
| _(none)_ | The agent is reached through `LemonControlPlane.AgentRuntime`; an agent registers a provider at boot. No compile-time dependency. |
| `ai` | AI model listing and configuration |

## Key Dependencies

- `bandit` - HTTP/WebSocket server
- `websock_adapter` - WebSocket adapter for Plug
- `plug` - HTTP routing and middleware
- `jason` - JSON encoding/decoding
