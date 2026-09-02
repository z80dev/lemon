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
Task terminal transitions are first-writer-wins: accepted cancellation cannot
be overwritten by a delayed submit/finalize path, and no post-cancel agent
message or context turn may be recorded. A runner lease remains the terminal
write owner after submission becomes working; a stale reclaimed runner must
not publish failure, timeout, or completion over the newer owner. External A2A and `sessions.active`
errors must use fixed bounded messages; classify failures for logs without
interpolating raw reasons, paths, credentials, or exception messages.
A2A submission `:outcome_unknown` must never trigger a retry or a false failed
task: reconcile the original caller-generated run ID for a bounded interval,
retain a fixed nonterminal reconciliation status if it remains unknown, and
reconcile later task reads from durable run state. Ambiguous abort
acknowledgements do not prove cancellation. Profile chat follows the same
no-retry rule and returns a bounded uncertain receipt with its pre-generated
run ID and `retrySafe: false`; profile errors never inspect raw reasons into a
client response or log.
An inbound A2A `messageId` is a durable replay key. Repeating it for the same
authenticated peer returns the original task and never submits a second router
run; reusing it across peers is a conflict and fails closed.

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

### System / Utility

| Method | Scope | Description |
|--------|-------|-------------|
| `health` | none | Public runtime health with BEAM scheduler/memory summary |
| `status` | read | System status with connections, runs, channels, skills, BEAM VM capacity counters, and cleanup summary |
| `introspection.snapshot` | read | Consolidated snapshot of agents, sessions, channels, transports with section summary (includes `activeSessions` harness progress projection) |
| `logs.tail` | read | Tail recent log lines with filter summary, cleanup flags, and sensitive log-value redaction |
| `models.list` | read | List available AI models plus capability/provider summaries |
| `providers.status` | read | Redacted provider credential readiness, route preview, fallback candidates, config-shape diagnostics, live fallback proof status, and top-level summary |
| `providers.configure` | admin | Preview or apply comment-preserving fallback and credential-pool reference edits; optional `expectedRevision` rejects stale applies, destructive changes require exact operation confirmation, and responses never include credential references |
| `memory.status` | read | Redacted memory-provider registry metadata plus provider health and searchable-scope summaries |
| `proofs.status` | read | Redacted live-proof diagnostics with top-level counts and launch-gate summaries for Discord DM, Discord client-click, provider media, and terminal backends |
| `extensions.status` | read | Redacted extension/plugin load, conflict, provider, WASM diagnostics, and host/runtime summary |
| `usage.status` | read | Current usage, provider, quota, and redaction-safe summary backed by `LemonCore.UsageDiagnostics` |
| `usage.cost` | read | Cost breakdown for a date range plus cleanup summary |
| `system-presence` | read | Current presence/resource data plus summary/cleanup flags |
| `system-event` | write | Emit a bounded admin system event with target validation plus summary/cleanup flags |
| `system.reload` | admin | Runtime reload of module/app/extension/all scopes with lifecycle summary; `compile: true` recompiles source first on mix-run nodes |
| `update.run` | admin | Trigger a system update with version/check-only/apply summary and cleanup flags |

### Session Management

| Method | Scope | Description |
|--------|-------|-------------|
| `sessions.list` | read | List/search sessions with pagination, agent/title/content query, pin/archive filters, lifecycle metadata, and query-redaction summary |
| `sessions.active` | read | Get currently active session plus active-run cleanup summary; returns fixed, reason-free errors when router state cannot be read |
| `sessions.active.list` | read | List all active sessions plus summary/cleanup flags; includes best-effort `harness` progress (todos/checkpoints/requirements) when coding-agent telemetry is available |
| `sessions.stats` | read | Exact aggregate durable-session totals with list/search-compatible filters and bounded redacted agent/origin dimensions; never includes keys, titles, prompts, paths, URLs, or credentials |
| `sessions.preview` | read | Preview truncated session messages plus sensitive-preview redaction, truncation summary, and cleanup flags |
| `sessions.patch` | admin | Modify session policy/model/thinking overrides plus patch summary and cleanup flags |
| `sessions.metadata.patch` | admin | Set/clear a session title and update pin/archive state without echoing title text in the mutation response |
| `sessions.export` | read | Return bounded JSON or Markdown with selected run/tool fields, mandatory sensitive-value redaction, SHA-256 digest, and explicit raw-internal omissions |
| `sessions.prune` | admin | Dry-run-first stale-session prune; archived-only/unpinned by default and execution requires a token bound to the exact current candidate set |
| `sessions.reset` | admin | Clear session history plus cleanup summary |
| `sessions.heartbeat` | admin | Inspect or set/pause/resume/clear one live session's idle-only recurring prompt by logical session key; ambiguous ownership is a conflict |
| `sessions.delete` | admin | Delete canonical run history plus chat/policy/lifecycle metadata and verify the deletion before reporting success |
| `sessions.compact` | admin | Compact session storage plus no-text cleanup summary |
| `session.detail` | read | Deep session/run internals with summary, sensitive preview/run-internal redaction, and explicit opt-ins for full text, raw run events, and run records |
| `session.btw` | write | Ask a bounded no-tools question against a frozen live session or durable session-key history without mutating the parent conversation |

The session lifecycle methods share `LemonCore.SessionLifecycle`. Aggregate
statistics use this service rather than paginated `sessions.list` summaries.
Conversation
content remains canonical in `RunStore`/`RunHistoryStore`; the only additional
table stores title/pin/archive annotations. `sessions.export` never exposes the
service's trusted internal unredacted-history option. Prune preview tokens bind
the operation parameters and each candidate's stable key/index/metadata state,
so any intervening lifecycle change forces a new preview.

### Monitoring / Introspection

| Method | Scope | Description |
|--------|-------|-------------|
| `runs.active.list` | read | Active run list from `LemonRouter.RunRegistry` plus summary and cleanup flags |
| `runs.recent.list` | read | Recent completed/errored/aborted runs plus status/duration summary and cleanup flags |
| `run.graph.get` | read | Parent/child run graph with optional per-node run-store records/events and introspection plus return-state summary and sensitive-internal redaction |
| `run.introspection.list` | read | Introspection timeline for one run plus raw-internal return-state summary and sensitive payload redaction |
| `tasks.active.list` | read | Active task/subagent records from the registered agent runtime plus summary and include/cleanup flags |
| `tasks.recent.list` | read | Recent terminal task records with status/error classification plus summary and include/cleanup flags |

`tasks.active.list` / `tasks.recent.list` infer missing `engine` from task record metadata and task event payloads (for example `details.engine`) when the persisted task record has no explicit engine field.
The run/task list methods also include compact summaries for status, engine, agent/session/run, event, reasoning, and duration counts so non-Web clients can monitor orchestration without fetching run graphs or raw task records.

### Agent Management

| Method | Scope | Description |
|--------|-------|-------------|
| `agent` | write | Submit an agent run with prompt-cleanup summary |
| `agent.wait` | read | Wait for run completion with bounded result summary and sensitive answer/error redaction |
| `agent.progress` | read | Get progress for active session plus bounded progress summary |
| `agents.list` | read | List available agents plus directory summary and cleanup flags |
| `agent.identity.get` | read | Get agent capabilities/identity plus capability and cleanup summary |
| `agent.inbox.send` | write | Send message to agent inbox with routing plus prompt-cleanup summary |
| `agent.targets.list` | read | List agent routing targets plus summary and cleanup flags |
| `agent.directory.list` | read | List agent directory entries plus session summary and cleanup flags |
| `agent.endpoints.list` | read | List agent HTTP endpoints plus route summary |
| `agent.endpoints.set` | write | Configure agent endpoint plus route cleanup summary |
| `agent.endpoints.delete` | write | Remove agent endpoint plus deletion cleanup summary |
| `agents.files.list` | read | List agent files plus file-count and cleanup summary |
| `agents.files.get` | read | Get file content plus bounded content-return summary |
| `agents.files.set` | admin | Set file content plus content-cleanup summary |

### Chat

Profile RPCs are `profiles.list`, `profiles.get`, `profiles.create`,
`profiles.clone`, `profiles.rename`, `profiles.export`, `profiles.delete`,
`profiles.roster`, and `profile.chat`. Reads require `read`, chat requires
`write`, and lifecycle mutations/exports require `admin`. `profile.chat`
refreshes the router profile cache, submits the stable `agent:<id>:main`
session through `LemonCore.RouterBridge`, and never echoes prompt text in its
summary. It assigns the run ID before submission so an `:outcome_unknown`
response can return a bounded, non-retryable reconciliation receipt instead of
inviting duplicate execution. Export summaries report selected/omitted/redacted
counts and never claim to include sessions, memory, credentials, or secret
values.

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
| `system.reload` | admin | Runtime reload of module/app/extension/all scopes with lifecycle summary; `compile: true` recompiles source first on mix-run nodes |
| `secrets.list` | read | List secret metadata plus no-value cleanup summary |
| `secrets.set` | admin | Store secret plus no-value cleanup summary |
| `secrets.delete` | admin | Remove secret plus no-value cleanup summary |
| `secrets.exists` | read | Check if secret exists plus no-value cleanup summary |
| `secrets.status` | read | Get redacted secrets store health, fallback, count, and cleanup summary |

Config keys are whitelisted in `ConfigGet` to prevent atom table exhaustion. Secrets are stored via `LemonCore.Secrets` and never returned in plaintext.

### Cron Jobs

| Method | Scope | Description |
|--------|-------|-------------|
| `cron.list` | read | List cron jobs with redacted prompt/command summaries unless `includeTargetText` is true |
| `cron.add` | admin | Add a cron job with target byte counts and cleanup summaries |
| `cron.update` | admin | Update a cron job with changed-field and cleanup summaries |
| `cron.pause` | admin | Pause a cron job by disabling future scheduled launches with cleanup summaries |
| `cron.resume` | admin | Resume a paused cron job with cleanup summaries |
| `cron.abort` | admin | Abort an active cron run by run id with raw-id and cleanup summaries |
| `cron.audit` | read | List durable cron lifecycle audit events with operator-facing raw-id and cleanup summaries |
| `cron.remove` | admin | Remove a cron job with raw-id and cleanup summaries |
| `cron.run` | admin | Manually trigger a cron job with raw-id and cleanup summaries |
| `cron.runs` | read | List runs for a job with include-option summaries, cleanup flags, and sensitive output redaction |
| `cron.status` | read | Cron system status + active/recent run, retry, scheduler-lock, suppression, stale-recovery, audit counters, and cleanup summaries |

`cron.add` and `cron.update` accept 5-field cron expressions plus supported shorthands such as `every 30m`, `hourly`, `every 2h`, `daily at 9am`, `weekdays at 09:30`, and `weekly monday at 8am`; shorthands are stored as normalized cron expressions, and interval shorthands must divide the enclosing cron field exactly. `cron.add` accepts either prompt jobs (`agentId`, `sessionKey`, `prompt`) or operator-owned no-agent command jobs (`command`, optional `cwd` and `env`); the two target types are mutually exclusive, and write responses return prompt/command byte counts plus cleanup summaries without raw target text. `cron.update` preserves the target type: prompt jobs can update `prompt`, command jobs can update `command`, `cwd`, and `env`, and routing fields (`agentId`, `sessionKey`) remain immutable. Other mutable fields are `name`, `schedule`, `enabled`, `timezone`, `jitterSec`, `timeoutMs`, `maxRetries`, and `retryBackoffMs`. Attempts to update immutable routing fields return `invalid_request`; invalid schedule or target patches also return `invalid_request`. `cron.list` redacts prompt and command text by default, returning byte counts and cleanup summaries; pass `includeTargetText: true` only for trusted operator views that need the raw target text. `cron.pause` and `cron.resume` are explicit lifecycle aliases around `enabled: false/true`. `cron.run` and `cron.remove` return raw ids plus cleanup summaries without prompt, command, output, or error text. `cron.runs` returns run-history summaries with status counts, output/error byte counts, preview/full-output flags, include flags for meta/run-record/introspection payloads, and cleanup metadata that makes operator-requested output previews or internals explicit while redacting sensitive output, error, metadata, run-record, and introspection values. `cron.abort` operates on a cron run id, routes to router cancellation when the underlying Lemon run is still active, persists terminal `aborted` status, and returns raw ids with cleanup summaries but no prompt/command/output/error text. `cron.status` exposes BEAM scheduler-health counters for active locks, failed runs, retry runs, suppressed slots, stale recoveries, scheduled retries, status counts, trigger counts, audit action counts, and cleanup summaries confirming prompt, command, output, error, credential, and secret text are not included. `cron.audit` supports `jobId`, `runId`, `cronRunId`, `action`, `sinceMs`, and `limit` filters, returns raw ids and lifecycle reason text to authorized control-plane clients, and exposes summary flags that distinguish those operator fields from prompt/command/output/error/secret cleanup.

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
summaries make those returned fields explicit so non-Web clients can decide
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
| `node.list` | read | List durable paired nodes with live online/offline status plus summary and cleanup flags |
| `node.describe` | read | Get node details with redacted metadata summary and cleanup flags |
| `node.rename` | write | Rename a node plus summary and cleanup flags |
| `node.invoke` | write | Invoke a method on one authenticated live node plus arg/result cleanup summary |
| `node.invoke.result` | invoke | Owning node reports an invocation result; another node cannot settle it |
| `node.invoke.control.result` | invoke | Owning node acknowledges steer/redirect against the exact live invocation and run identity |
| `node.event` | event | Node sends an event (node-only) plus payload summary and cleanup flags |
| `node.pair.request` | pairing | Request to pair a node plus pairing-code delivery summary |
| `node.pair.list` | pairing | List pending pairing requests plus summary and cleanup flags |
| `node.pair.approve` | pairing | Approve a pairing request plus token/challenge delivery summary |
| `node.pair.reject` | pairing | Reject a pairing request plus cleanup flags |
| `node.pair.verify` | pairing | Verify a pairing code plus status cleanup summary |

Node names are trimmed and reserved durably per controller; a second identity
cannot pair or rename to a reserved name. `node.list` retains offline durable
identities but derives status from `LemonCore.NodeRegistry`, so only a currently
authenticated WebSocket can receive work. Pending invocations are bound to one
node ID, fail when the node disconnects, and accept explicit targeted
cancellation. Registry timeouts fail the source recipient but do not by
themselves claim that destination execution was cancelled. Steer and redirect
are separate invocation-bound controls: the registry pins each one to the
original node connection, credential generation, invocation ID, and run ID,
and reports acceptance only after the worker applies the bounded text to its
live native executor context. Terminal races, disconnects, and acknowledgement
timeouts are rejected rather than guessed successful.

An approved pairing ID may reissue a fresh one-time challenge for its existing
durable node identity, allowing the joining worker to recover from socket loss
after approval or challenge consumption without orphaning the reserved name.
Challenge exchange is an atomic take: concurrent exchanges can issue at most
one credential. Node credential replacement is also serialized per durable
identity. Advancing its session generation immediately invalidates the prior
token, closes the prior live socket, and prevents that socket from settling
work dispatched by another generation.
Named-node requests/results enforce the advertised `maxPayload` (1 MiB by
default) plus shared depth/item-count limits. Raw request arguments exist only
in the targeted live dispatch; durable invocation records retain a content-free
argument summary. The raw terminal result is sent only to the source recipient,
and awaited `browser.request` calls consume that private registry delivery
directly. Durable invocation status and `node.invoke.completed` events contain
content-free summaries, never raw request, result, or error values.

The source-checkout coding worker advertises `coding_agent.run` version 1 and
targeted cancellation. Its payload is a JSON-safe execution request/result
contract; provider credentials, callbacks, executor options, and source BEAM
state remain on the source or destination that owns them. The destination
resolves its own credentials and cwd. This path uses the native
`CodingAgent.Executor` and never a vendor CLI runner.

### Channels and Transports

| Method | Scope | Description |
|--------|-------|-------------|
| `commands.catalog` | read | Return the portable command catalog with aliases, descriptions, arguments, busy policies, semantic capability ids, category counts, and versioned summary; discovery only, never command execution |
| `background.start` | write | Start an isolated full-tool native agent session, validating and normalizing any `thinkingLevel`, and return its durable lifecycle id immediately |
| `background.list` | read | List sanitized durable background-run lifecycle summaries, optionally filtered by status |
| `background.status` | read | Read one sanitized background-run lifecycle summary |
| `background.result` | read | Read the visible answer after completion, or report that the run is not ready |
| `background.cancel` | write | Cancel a queued or running background session by durable id |
| `channels.status` | read | Status of configured channel adapters plus Telegram/Discord diagnostics, proof, shared launch-gate readiness, compact gate status/reason maps, and cleanup summaries |
| `transports.status` | read | Status of configured legacy gateway transports plus registry/module health summary |
| `channels.logout` | admin | Logout from a channel plus credential/state cleanup summary |

The background/side-query provider boundary is fail-closed. Project only the
documented lifecycle fields, derive terminal `errorCode` from status, and map
all provider failures to fixed operation-specific JSON-RPC messages and
`details.code` values. Never stringify provider return maps or attach raw
reason terms: they may contain persisted errors, local paths, provider
metadata, or credentials.

### Skills

| Method | Scope | Description |
|--------|-------|-------------|
| `skills.status` | read | List skills with readiness details plus activation/source/missing-requirement summaries |
| `skills.hermes.catalog` | read | Browse the live official Hermes catalog by category, collection, or query |
| `skills.bins` | invoke | Get skill bin paths plus bin/requirement counts and cleanup summary |
| `skills.install` | admin | Install a skill plus install-source return-state and approval-context cleanup summary; audit blocks require a distinct exact-bundle security-override approval and denial returns a safe permission error |
| `skills.update` | admin | Update/configure a skill plus env-key/update-mode summary with sensitive env response redaction |

### Portable Blueprints

| Method | Scope | Description |
|--------|-------|-------------|
| `blueprints.list` | read | List valid bundles from the canonical local catalog without paths or content |
| `blueprints.inspect` | read | Inspect one catalog `bundleId` through the activation validation path |
| `blueprints.validate` | read | Re-run manifest, policy, lint, and deterministic skill audit checks |
| `blueprints.preview` | read | Return a content-free exact plan plus confirmation digest for one profile |
| `blueprints.activate` | admin | Re-plan and apply only an exact fresh confirmation digest |
| `learn.review` | read | Resolve bounded references and return content-free memory/skill proposals, audit codes, conflicts, and exact confirmation digest |
| `learn.confirm` | admin | Re-resolve and write canonical memory plus an audited draft only for the exact fresh digest |

Keep this surface catalog-scoped: never add caller-provided `root` or `path`
parameters. `bundleId` must resolve directly below `~/.lemon/bundles` with
containment, symlink, and manifest-ID checks. Responses must remain free of
absolute paths, skill bodies, prompt/command text, and secret values. The admin
mutation delegates to `LemonAutomation.Blueprint`, which binds the target
profile and current destination state and creates cron jobs only through
`CronManager.add_new/1`.

`lemon blueprints` is the source and packaged CLI projection over these exact
methods. Its one-shot VM must not load bundle paths or start automation; the
packaged launcher starts the existing runtime when necessary, preview is the
default bundle-ID action, and only `blueprints.activate` carries the exact
fresh confirmation digest to this long-running service.

The Bun TUI uses the same methods for `/blueprints` and `/blueprint`. Its own
projection is intentionally narrower than the RPC: only bounded IDs, counts,
actions, booleans, and digests may enter terminal state. It obtains a fresh
preview before activation, disables offline queuing for the admin request, and
clears refused/stale plans while preserving the profile draft. Keep free-form
manifest prose, prompts, skill text, schedules, commands, environment values,
paths, URLs, tokens, secrets, and raw error terms out of terminal rendering.

Learn methods may accept bounded context references and an explicit root, but
must never return source text, generated prompts, paths, URLs, secret names, or
secret values. `learn.confirm` delegates to `LemonSkills.Learn`; do not persist
review plans or add a second learning store.

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

### Automation

| Method | Scope | Description |
|--------|-------|-------------|
| `wake` | write | Wake an agent plus returned-id, prompt-byte, and cleanup summary |
| `set-heartbeats` | write | Enable/configure heartbeat monitoring plus summary and prompt cleanup flags |
| `last-heartbeat` | read | Get last heartbeat for an agent plus response summary and redaction flags |
| `talk.mode` | write | Get or set talk mode for a session plus audio/transcript cleanup summary |
| `browser.status` | read | Inspect local browser driver status, artifacts, browser nodes, and live browser proof state |
| `browser.request` | write | Send a browser request with route-policy summaries and optional private awaited result delivery |
| `browser.controller.ticket` | write | Mint a short-lived single-use ticket bound to the authenticated principal, controller, profile, session/run, and capabilities |
| `browser.controller.register` | write | Consume a ticket and bind the exact WebSocket process as a browser controller |
| `browser.controller.heartbeat` | write | Refresh liveness for the exact registered controller process |
| `browser.controller.result` | write | Return one command result from the exact registered controller process |
| `browser.controller.status` | read | Inspect redacted controller/binding status without tickets, credentials, or page content |
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
| `goal.loop.stop` | write | Stop a bounded supervised autonomous goal loop, disable persisted auto scheduling, and expose only the bounded router-abort statuses `accepted`, `outcome_unknown`, `unavailable`, `rejected`, or `not_needed` |
| `goal.clear` | write | Clear the durable goal for a session with cleanup summaries |

### Wizard (capability-gated)

| Method | Scope | Description |
|--------|-------|-------------|
| `wizard.start` | admin | Start a wizard flow plus step-count and cleanup summary |
| `wizard.step` | admin | Advance wizard step plus current-step/data-key summary with sensitive response data redacted |
| `wizard.cancel` | admin | Cancel a wizard plus cancellation cleanup summary |

### Events and Subscriptions

| Method | Scope | Description |
|--------|-------|-------------|
| `events.subscribe` | read | Subscribe to event topics (run, session, system, cron, etc.) plus delivery filtering, summary/cleanup flags, and tracked connection state |
| `events.unsubscribe` | read | Unsubscribe from event topics or clear all per-connection subscriptions plus summary/cleanup flags |
| `events.subscriptions.list` | read | List current subscriptions plus run/session subscription summary and cleanup flags |
| `events.ingest` | write | Ingest bounded external events with target validation plus summary/cleanup flags |

## Authentication and Authorization

### Roles and Scopes

| Role | Scopes | How established |
|------|--------|-----------------|
| `operator` | `admin`, `read`, `write`, `approvals`, `pairing` | Configured `LEMON_CONTROL_PLANE_OPERATOR_TOKEN`; legacy tokenless direct-loopback access requires an explicit compatibility opt-in |
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
       "auth": {"token": "configured-operator-token"},
       "role": "operator",
       "scopes": ["operator.read", "operator.write"]
     }
   }
   ```
3. Server responds with `hello-ok` frame (not a `res` frame) containing `features.methods`, `features.events`, `snapshot`, `auth`, and `policy`
4. All subsequent requests use the established auth context

The HTTP router passes the actual socket peer into authorization. An operator
token is required by default for every operator connection and compared in
constant time. `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true`
explicitly restores the legacy tokenless path for direct loopback peers only;
it defaults to `false`, and non-loopback peers always fail closed. Node/device
session tokens derive role and scopes only from known stored identity types.

### Token-Based Auth (Nodes/Devices)

1. Node calls `node.pair.request` -> operator approves via `node.pair.approve`, which returns a one-time challenge
2. Node calls `connect.challenge` with that challenge -> receives a session token (TTL: seven days for this pairing flow)
3. Node uses `{"auth": {"token": "..."}}` in future `connect` calls

`node.pair.verify` is a pairing-code status check; it does not return the
approval challenge or session token.

Token validation is handled by `LemonControlPlane.Auth.TokenStore` (backed by `LemonCore.Store` under `:session_tokens` namespace).

`./bin/lemon node join --pair` automates this exchange for the named coding
worker when its operator connection has pairing scope. The worker persists the
issued session and recovery credentials in a mode-0600 destination file keyed
by durable node ID and records the exact controller URL; reuse fails closed
when that controller does not match. ID-based recovery material is not loaded
unless the caller supplies that exact stored controller URL. After the
seven-day session expires,
`--pair` recovers the same durable node and issues a fresh session while
atomically revoking older sessions and their live sockets. Controller renames remain valid because recovery uses
the node ID and controller's current name. An explicit operator-authorized
`--pair --repair --node-id ID` rotates recovery credentials for compatible
legacy records that lack one.

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
| `agent` | Run started/completed, tool use (`type`: `started`, `completed`, `tool_use`; tool-use events preserve nested `action.detail`, including `result_meta` failure fields such as `error_type` and `exit_code`) |
| `chat` | Chat delta/streaming content |
| `presence` | Connection count changed |
| `tick` | Heartbeat tick (from `:tick` or `:cron_tick` bus events) |
| `heartbeat` | Agent heartbeat or heartbeat alert |
| `exec.approval.requested` | Approval needed, including structured `action` metadata for operator UI controls such as MCP OAuth links |
| `exec.approval.resolved` | Approval decided or timed out, including approval id, decision, and pending approval metadata when available |
| `cron` | Cron job started/completed |
| `cron.job` | Cron job created/updated/deleted |
| `cron.audit` | Cron lifecycle audit event recorded |
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
