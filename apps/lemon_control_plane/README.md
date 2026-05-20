# LemonControlPlane

HTTP and WebSocket control plane API server for the Lemon agent system. Provides a frame-based JSON protocol over WebSocket for real-time bidirectional communication.

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
             |  /healthz   |  |     /ws        |  |  404 fallback       |
             |  (GET JSON) |  |  (WebSocket)   |  |                     |
             +-------------+  +------+---------+  +---------------------+
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
| GET | `/v1/health` | OpenAI-compatible preview health metadata |
| GET | `/v1/capabilities` | OpenAI-compatible preview capability metadata |
| GET | `/v1/models` | OpenAI-compatible model list shape backed by Lemon model metadata, including `supportsVision` |
| POST | `/v1/chat/completions` | Preview adapter that submits a Lemon run and returns queued `chat.completion` metadata by default, assistant text with `wait: true`, or SSE chunks with `stream: true`; accepts redacted URL/file-id image metadata, data URL image pass-through, and opt-in allowlisted HTTPS image URL fetch, and rejects runtime image bytes for known text-only models before submission |
| POST | `/v1/responses` | Preview adapter that submits a Lemon run and returns a queued `response` object by default, output text with `wait: true`, or Responses-style SSE events with `stream: true`; accepts redacted URL/file-id image metadata, data URL image pass-through, opt-in allowlisted HTTPS image URL fetch, and `previous_response_id` for session continuation, and rejects runtime image bytes for known text-only models before submission |
| GET | `/v1/responses/:response_id` | Preview stored response retrieval for `resp_<run_id>` over the Lemon run store |
| GET | `/v1/runs/:run_id` | Preview redacted run status metadata |
| POST | `/v1/runs/:run_id/cancel` | Preview run cancellation dispatch through the Lemon router |
| POST | `/acp` | Preview Agent Client Protocol JSON-RPC bridge for initialize, session lifecycle, prompt, cancel, and close over Lemon router runs |

The `/v1` generation endpoints are compatibility adapters, not a separate
runtime path. They submit through the Lemon router and return `lemon.runId` by
default; clients can use `/ws` events, call `agent.wait`, or set `wait: true`
with optional `timeout_ms` / `timeoutMs` to synchronously wait through the same
`agent.wait` path. With `stream: true`, the HTTP process subscribes to the run
topic and returns `text/event-stream` chunks from Lemon run bus events,
including redacted tool-progress events for `:engine_action` updates. Run
status responses intentionally omit raw run events and assistant answer text.
Stored Responses use `resp_<run_id>` ids, and `previous_response_id` reuses the
prior response session key by default. Image input has a split boundary:
HTTP(S) URLs and file ids are hashed/redacted into run metadata and bounded
prompt placeholders by default, while base64 data URLs are validated,
size/count-limited, redacted from prompts and metadata, and passed as
runtime-only image blocks to native Lemon providers. HTTPS image URL fetch is
available only when `:openai_compat_image_url_fetch` or
`LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` is set and the host is present in
`:openai_compat_image_url_allowed_hosts`,
`LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`, or
`LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST`; fetched images use the same
runtime-only image path. Raw image references are omitted from HTTP responses
and status payloads.
Set `:openai_compat_api_token`,
`LEMON_OPENAI_COMPAT_API_TOKEN`, or `LEMON_OPENAI_COMPAT_TOKEN` to require
`Authorization: Bearer <token>` or `x-api-key: <token>` on `/v1`.

The `/acp` endpoint is also an adapter over the existing router/run graph. It
supports JSON-RPC `initialize`, `session/new`, `session/resume`, `session/list`,
`session/prompt`, `session/cancel`, and `session/close`. `session/prompt`
accepts ACP `text` and `resource_link` blocks, submits a supervised Lemon run,
and either waits through `agent.wait` or returns queued metadata when
`_meta.lemon.wait` is `false`. The same handler is available to spawned
line-oriented stdio clients through `scripts/lemon_acp_stdio.exs`, using ACP's
newline-delimited JSON stream shape. Waiting stdio prompts emit intermediate
`session/update` notification lines for Lemon text deltas and redacted tool
progress before the final response. The stdio bridge can round-trip
`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`,
`fs/delete_file`, and `fs/rename_file` client requests while the prompt waits,
and carries only safe filesystem capability booleans into Lemon run metadata.
The capability response intentionally leaves image, audio, embedded-resource,
MCP HTTP, and MCP SSE support disabled until those paths have safe artifact and
streaming contracts. Set
`:acp_api_token` or `LEMON_ACP_API_TOKEN` to require bearer or `x-api-key` auth
for HTTP.

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
| `health` | none | Public runtime health with BEAM scheduler/memory summary |
| `status` | read | System status with connections, runs, channels, skills, BEAM VM capacity counters, and cleanup summary |
| `introspection.snapshot` | read | Consolidated snapshot of agents, sessions, channels, transports plus section summary |
| `logs.tail` | read | Tail recent log lines with filter summary, cleanup flags, and sensitive log-value redaction |
| `models.list` | read | List available AI models plus capability/provider summaries |
| `providers.status` | read | Redacted provider credential readiness, route preview, fallback candidates, config-shape diagnostics, live fallback proof status, and top-level summary |
| `memory.status` | read | Redacted memory-provider registry metadata plus provider health and searchable-scope summaries |
| `proofs.status` | read | Redacted live-proof diagnostics with top-level counts and launch-gate summaries for Discord DM, Discord slash registration, Discord client-click, provider media, and terminal backends |
| `readiness.status` | read | Compact launch-readiness summary for doctor, Telegram/Discord gates, shared proof-gate counts/statuses, provider-media proof, proof totals, unresolved gates with summary reason-kind lists, and cleanup flags |
| `extensions.status` | read | Redacted extension/plugin load, conflict, provider, WASM diagnostics, and host/runtime summary |
| `usage.status` | read | Current usage, provider, quota, and redaction-safe summary backed by `LemonCore.UsageDiagnostics` |
| `usage.cost` | read | Cost breakdown for a date range plus cleanup summary |
| `system-presence` | read | Current presence/resource data plus summary/cleanup flags |
| `system-event` | write | Emit a bounded admin system event with target validation plus summary/cleanup flags |
| `system.reload` | admin | Runtime reload of module/app/extension/all scopes with lifecycle summary; `compile: true` recompiles source first on mix-run nodes |
| `update.run` | admin | Trigger a system update with version/check-only/apply summary and cleanup flags (capability-gated) |

### Agent Management

| Method | Scope | Description |
|--------|-------|-------------|
| `agent` | write | Submit an agent run with prompt-cleanup summary |
| `agent.wait` | read | Wait for run completion with bounded result summary and sensitive answer/error redaction |
| `agent.progress` | read | Get progress for an active session plus bounded progress summary |
| `agent.identity.get` | read | Get agent capabilities/identity plus capability and cleanup summary |
| `agent.inbox.send` | write | Send message to agent inbox with routing plus prompt-cleanup summary |
| `agent.targets.list` | read | List agent routing targets plus summary and cleanup flags |
| `agent.directory.list` | read | List agent directory entries plus session summary and cleanup flags |
| `agent.endpoints.list` | read | List agent HTTP endpoints plus route summary |
| `agent.endpoints.set` | write | Configure agent endpoint plus route cleanup summary |
| `agent.endpoints.delete` | write | Remove agent endpoint plus deletion cleanup summary |
| `agents.list` | read | List available agents plus directory summary and cleanup flags |
| `agents.files.list` | read | List agent files plus file-count and cleanup summary |
| `agents.files.get` | read | Get file content plus bounded content-return summary |
| `agents.files.set` | admin | Set file content plus content-cleanup summary |

### Session Management

| Method | Scope | Description |
|--------|-------|-------------|
| `sessions.list` | read | List all sessions with pagination plus summary and cleanup flags |
| `sessions.active` | read | Get currently active session plus active-run cleanup summary |
| `sessions.active.list` | read | List all active sessions with harness progress plus summary and cleanup flags |
| `sessions.preview` | read | Preview truncated session messages plus sensitive-preview redaction, truncation summary, and cleanup flags |
| `session.detail` | read | Deep session/run internals with summary, sensitive preview/run-internal redaction, and explicit opt-ins for full text, raw run events, and run records |
| `sessions.patch` | admin | Modify session policy/model/thinking overrides plus patch summary and cleanup flags |
| `sessions.reset` | admin | Clear session history plus cleanup summary |
| `sessions.delete` | admin | Delete a session plus cleanup summary |
| `sessions.compact` | admin | Compact session storage plus no-text cleanup summary |

### Monitoring and Introspection

| Method | Scope | Description |
|--------|-------|-------------|
| `runs.active.list` | read | Active run list from RunRegistry plus summary and cleanup flags |
| `runs.recent.list` | read | Recent completed/errored/aborted runs plus status/duration summary and cleanup flags |
| `run.graph.get` | read | Parent/child run graph with optional records/events plus return-state summary and sensitive-internal redaction |
| `run.introspection.list` | read | Introspection timeline for one run plus raw-internal return-state summary and sensitive payload redaction |
| `tasks.active.list` | read | Active task/subagent records plus summary and include/cleanup flags |
| `tasks.recent.list` | read | Recent terminal task records plus summary and include/cleanup flags |

Run and task list methods include compact status, engine, agent/session/run,
event, reasoning, and duration summaries for orchestration dashboards without
requiring raw graph or record fetches.

### Chat

| Method | Scope | Description |
|--------|-------|-------------|
| `chat.send` | write | Send message to session; returns `runId`, `sessionKey`, and prompt-cleanup summary |
| `chat.abort` | write | Abort a running session or run plus target cleanup summary |
| `chat.history` | read | Get chat history for a session with summary, `beforeId` pagination, optional preview truncation, and sensitive-preview redaction when full text is disabled |
| `send` | write | Send a message to a channel (no agent run) plus delivery cleanup summary |

### Configuration and Secrets

| Method | Scope | Description |
|--------|-------|-------------|
| `config.get` | read | Get config value(s) with sensitive stored values redacted plus cleanup summary |
| `config.set` | admin | Set config value with sensitive response values redacted plus cleanup summary |
| `config.patch` | admin | Partial config update plus value-cleanup summary |
| `config.schema` | read | Get config schema plus property summary |
| `config.reload` | admin | Reload configuration plus lifecycle and cleanup summary |
| `secrets.list` | read | List secret metadata plus no-value cleanup summary |
| `secrets.set` | admin | Store secret plus no-value cleanup summary |
| `secrets.delete` | admin | Remove secret plus no-value cleanup summary |
| `secrets.exists` | read | Check if secret exists plus no-value cleanup summary |
| `secrets.status` | read | Get redacted secrets store health, fallback, count, and cleanup summary |

### Cron Jobs

| Method | Scope | Description |
|--------|-------|-------------|
| `cron.list` | read | List cron jobs with redacted prompt/command summaries unless `includeTargetText` is true |
| `cron.add` | admin | Add a cron job with target byte counts and cleanup summaries |
| `cron.update` | admin | Update mutable fields of a cron job with changed-field and cleanup summaries |
| `cron.pause` | admin | Pause a cron job by disabling future scheduled launches with cleanup summaries |
| `cron.resume` | admin | Resume a paused cron job with cleanup summaries |
| `cron.abort` | admin | Abort an active cron run by run id with raw-id and cleanup summaries |
| `cron.audit` | read | List durable cron lifecycle audit events with operator-facing raw-id and cleanup summaries |
| `cron.remove` | admin | Remove a cron job with raw-id and cleanup summaries |
| `cron.run` | admin | Manually trigger a cron job with raw-id and cleanup summaries |
| `cron.runs` | read | List runs for a job with include-option summaries, cleanup flags, and sensitive output redaction |
| `cron.status` | read | Cron system status with active/recent run, retry, scheduler-lock, suppression, stale-recovery, audit counters, and cleanup summaries |

`cron.audit` supports `jobId`, `runId`, `cronRunId`, `action`, `sinceMs`, and
`limit` filters. It is operator-facing and returns raw cron/job/router IDs and
lifecycle reason text to authorized clients; the response summary makes that
explicit while confirming prompt, command, output, error, credential, and secret
text are excluded. Support bundles use a redacted diagnostics shape instead.
`cron.run` and `cron.remove` return raw ids plus cleanup summaries without
prompt, command, output, or error text. `cron.runs` returns run-history summaries
with status counts, output/error byte counts, preview/full-output flags,
run-record and introspection include flags, and cleanup metadata that makes
operator-requested output previews or internals explicit while redacting
sensitive output, error, metadata, run-record, and introspection values.
`cron.add` and `cron.update` normalize supported schedule shorthands, including
`every 30m`, `hourly`, `every 2h`, `daily at 9am`, `weekdays at 09:30`, and
`weekly monday at 8am`, into stored 5-field cron expressions. Interval
shorthands must divide the enclosing cron field exactly, such as 60 minutes or
24 hours. `cron.add` accepts either prompt jobs (`agentId`, `sessionKey`,
`prompt`) or operator-owned no-agent command jobs (`command`, optional `cwd` and
`env`); the two target types are mutually exclusive. `cron.update` preserves the
target type: prompt jobs can update `prompt`, command jobs can update `command`,
`cwd`, and `env`, and `agentId` / `sessionKey` remain immutable. `cron.list`
redacts prompt and command text by default, returning byte counts and cleanup
summaries; pass `includeTargetText: true` only for trusted operator views that
need the raw target text.

### Kanban

| Method | Scope | Description |
|--------|-------|-------------|
| `kanban.board.create` | write | Create a board plus board return-state summary |
| `kanban.board.list` | read | List boards plus filter, status-count, and cleanup summary |
| `kanban.board.get` | read | Get one board with tasks plus task-count/status and cleanup summary |
| `kanban.board.archive` | write | Archive a board plus archive-state summary |
| `kanban.task.create` | write | Create a task plus task/dependency/comment cleanup summary |
| `kanban.task.update` | write | Update a task plus task/run/session return-state summary |
| `kanban.task.comment` | write | Add a task comment plus comment-count summary |
| `kanban.dispatcher.start` | write | Start a board dispatcher plus worker/concurrency summary |
| `kanban.dispatcher.status` | read | Read dispatcher state plus running/worker summary |
| `kanban.dispatcher.stop` | write | Stop a dispatcher plus stopped-state summary |

Kanban board and task methods intentionally return operator-authored names,
titles, descriptions, comments, metadata, session keys, and run ids. Their
summaries make those returned fields explicit so non-Web clients can choose
when to render the full payload.

### Exec Approvals

| Method | Scope | Description |
|--------|-------|-------------|
| `exec.approvals.get` | approvals | Get approval policy plus active pending approvals with summary and redacted structured `action` metadata for operator surfaces such as MCP OAuth |
| `exec.approvals.set` | approvals | Set global approval policy plus mode summary and cleanup flags |
| `exec.approvals.node.get` | approvals | Get approval policy for a node plus summary and cleanup flags |
| `exec.approvals.node.set` | approvals | Set node approval policy plus mode summary and cleanup flags |
| `exec.approval.request` | approvals | Request an approval for a tool use plus action cleanup summary |
| `exec.approval.resolve` | approvals | Resolve a pending approval plus decision cleanup summary |

### Node Management

| Method | Scope | Description |
|--------|-------|-------------|
| `node.list` | read | List paired nodes plus summary and cleanup flags |
| `node.describe` | read | Get node details with redacted metadata summary and cleanup flags |
| `node.rename` | write | Rename a node plus summary and cleanup flags |
| `node.invoke` | write | Invoke a method on a node plus arg/result cleanup summary |
| `node.invoke.result` | invoke | Node reports invocation result (node-only) plus result/error cleanup summary |
| `node.event` | event | Node sends an event (node-only) plus payload summary and cleanup flags |
| `node.pair.request` | pairing | Request to pair a node plus pairing-code delivery summary |
| `node.pair.list` | pairing | List pending pairing requests plus summary and cleanup flags |
| `node.pair.approve` | pairing | Approve a pairing request plus token/challenge delivery summary |
| `node.pair.reject` | pairing | Reject a pairing request plus cleanup flags |
| `node.pair.verify` | pairing | Verify a pairing code plus status cleanup summary |

### Channels and Transports

| Method | Scope | Description |
|--------|-------|-------------|
| `channels.status` | read | Status of configured channel adapters plus Telegram/Discord diagnostics, proof, shared launch-gate readiness, compact gate status/reason maps, and cleanup summaries |
| `transports.status` | read | Status of configured legacy gateway transports plus registry/module health summary |
| `channels.logout` | admin | Logout from a channel plus credential/state cleanup summary |

### Skills

| Method | Scope | Description |
|--------|-------|-------------|
| `skills.status` | read | List skills with readiness details plus activation/source/missing-requirement summaries |
| `skills.bins` | read | Get skill bin paths plus bin/requirement counts and cleanup summary |
| `skills.install` | admin | Install a skill plus install-source return-state and approval-context cleanup summary |
| `skills.update` | admin | Update/configure a skill plus env-key/update-mode summary with sensitive env response redaction |

### Events and Subscriptions

| Method | Scope | Description |
|--------|-------|-------------|
| `events.subscribe` | read | Subscribe to event topics with per-connection state, delivery filtering, and summary/cleanup flags |
| `events.unsubscribe` | read | Unsubscribe from event topics or clear all per-connection subscriptions |
| `events.subscriptions.list` | read | List current subscriptions plus run/session subscription summary and cleanup flags |
| `events.ingest` | write | Ingest bounded external events with target validation plus summary/cleanup flags |

### Voice / TTS (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `voicewake.get` | read | Get voicewake settings plus config summary and redaction flags |
| `voicewake.set` | write | Set voicewake enabled/keyword plus audio/transcript cleanup summary |
| `tts.status` | read | TTS status plus active-provider readiness, provider counts, and redaction flags |
| `tts.providers` | read | List TTS providers plus provider/voice summary |
| `tts.enable` | write | Enable TTS plus config-write cleanup summary |
| `tts.disable` | write | Disable TTS plus config-write cleanup summary |
| `tts.convert` | write | Convert text to speech plus provider/format/audio-byte cleanup summary |
| `tts.set-provider` | write | Set active TTS provider plus config-write cleanup summary |

### Device Pairing (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `device.pair.request` | pairing | Request to pair a device plus pairing-code delivery summary |
| `device.pair.approve` | pairing | Approve a device pairing plus token/challenge delivery summary |
| `device.pair.reject` | pairing | Reject a device pairing plus cleanup flags |
| `connect.challenge` | none | Exchange pairing challenge for a session token plus token-delivery summary |

### Wizard (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `wizard.start` | admin | Start a wizard flow plus step-count and cleanup summary |
| `wizard.step` | admin | Advance wizard step plus current-step/data-key summary with sensitive response data redacted |
| `wizard.cancel` | admin | Cancel a wizard plus cancellation cleanup summary |

### Automation

| Method | Scope | Description |
|--------|-------|-------------|
| `wake` | write | Wake an agent plus returned-id, prompt-byte, and cleanup summary |
| `set-heartbeats` | write | Enable/configure heartbeat monitoring plus summary and prompt cleanup flags |
| `last-heartbeat` | read | Get last heartbeat for an agent plus response summary and redaction flags |
| `talk.mode` | write | Get or set talk mode for a session plus audio/transcript cleanup summary |
| `browser.status` | read | Inspect local browser driver status, artifacts, browser nodes, and live browser proof state |
| `browser.request` | write | Send a browser request with route-policy and result cleanup summaries |
| `media.status` | read | Inspect redacted generated-media job/artifact metadata plus provider-backed media proof lane state |
| `checkpoint.status` | read | Inspect redacted checkpoint-store metadata plus filtered lifecycle event counts/history |
| `checkpoint.diff` | read | Preview filesystem changes for a checkpoint with path/diff cleanup summary |
| `checkpoint.restore` | write | Restore all or selected checkpoint paths with restore cleanup summary |
| `lsp.diagnostics.status` | read | Inspect redacted diagnostics checker capability metadata plus recent LSP proof artifacts/checks and summary |
| `lsp.server.start` | write | Start a supervised LSP stdio session with session cleanup summary |
| `lsp.server.initialize` | write | Run initialize and send the LSP initialized notification with protocol cleanup summary |
| `lsp.document.open` | write | Send a textDocument/didOpen notification with document cleanup summary |
| `lsp.document.change` | write | Send a textDocument/didChange notification with document cleanup summary |
| `lsp.document.close` | write | Send a textDocument/didClose notification with document cleanup summary |
| `lsp.server.request` | write | Send a JSON-RPC request over a supervised LSP stdio session with protocol cleanup summary |
| `lsp.server.stop` | write | Stop a supervised LSP stdio session with session cleanup summary |
| `terminal.backends.status` | read | Inspect registered terminal backend metadata, capabilities, policy, live proof state, Docker hardening, and top-level summary |
| `goal.set` | write | Set the durable goal for a session with redacted objective summaries |
| `goal.status` | read | Inspect one goal or list durable goals with redacted objective summaries |
| `goal.pause` | write | Pause the durable goal for a session with redacted objective summaries |
| `goal.resume` | write | Resume the durable goal for a session with redacted objective summaries |
| `goal.continue` | write | Submit one supervised continuation run for an active goal with cleanup summaries |
| `goal.loop.once` | write | Run one preview judge tick for an active goal with cleanup summaries |
| `goal.loop.start` | write | Start a bounded supervised autonomous goal loop with cleanup summaries; pass `auto: true` to persist opt-in scheduling |
| `goal.loop.status` | read | Inspect the bounded goal loop and persisted auto state for a session with cleanup summaries |
| `goal.loop.stop` | write | Stop a bounded supervised autonomous goal loop with cleanup summaries and disable persisted auto scheduling |
| `goal.clear` | write | Clear the durable goal for a session with cleanup summaries |

## Event System

The EventBridge subscribes to `LemonCore.Bus` topics and maps internal bus events to WebSocket event frames. Events fan out through a supervised task, then each WebSocket connection applies its current `events.subscribe` / `events.unsubscribe` topic state before pushing a frame. New connections keep legacy all-event delivery until they set explicit subscriptions; `events.unsubscribe` with no topics clears the connection to no event delivery.

### Subscribed Bus Topics

- `run:*` -- Run lifecycle events (dynamic subscription per run)
- `session:*` -- Session lifecycle and task events (dynamic subscription per session)
- `channels` -- Channel-related events
- `exec_approvals` -- Approval request/resolution events
- `cron` -- Cron job lifecycle events
- `goals` -- Durable goal lifecycle events
- `goals` -- Durable goal lifecycle, continuation, and loop verdict events
- `system` -- System events (shutdown, health, tick, talk mode)
- `nodes` -- Node pairing events
- `presence` -- Connection presence events

### WebSocket Events

| Event | Trigger |
|-------|---------|
| `agent` | Run started/completed, tool use; tool-use events preserve nested `action.detail` metadata, including `result_meta` failure fields such as `error_type` and `exit_code` |
| `chat` | Chat delta/streaming content |
| `goal` | Durable goal set/pause/resume/complete/clear, supervised continuation, or loop verdict |
| `presence` | Connection count changed |
| `tick` | Heartbeat tick |
| `heartbeat` | Agent heartbeat or alert |
| `exec.approval.requested` | Approval needed, including structured `action` metadata for operator UI controls such as MCP OAuth links |
| `exec.approval.resolved` | Approval decided or timed out, including approval id, decision, and pending approval run/session/agent/tool metadata when available |
| `cron` | Cron job started/completed |
| `cron.job` | Cron job created/updated/deleted |
| `cron.audit` | Cron lifecycle audit event recorded |
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

Method parameters are validated against schemas defined in `Protocol.Schemas` before dispatch. Server-to-client event payloads that need stable client contracts also have event schemas in the same module and can be checked with `validate_event/2`.

- **Required fields** with types -- requests missing these fields are rejected.
- **Optional fields** with types -- provided values are type-checked.
- **Supported types**: `:string`, `:integer`, `:boolean`, `:map`, `:list`, `:any`.

Methods or events without a schema entry accept any parameters. Approval events currently have schema-backed payload contracts so operator clients can rely on `exec.approval.requested` and `exec.approval.resolved` metadata, including `decision: "timeout"` when a pending approval expires.

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
| `lemon_skills` | Skill management |
| `lemon_automation` | Cron manager, heartbeat features |
| `coding_agent` | Compile-time only (not started at runtime) |
| `lemon_ai_runtime` | Provider credential readiness checks through the runtime facade |
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
