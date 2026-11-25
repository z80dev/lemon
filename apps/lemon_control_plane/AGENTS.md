# LemonControlPlane contributor guide

The control plane is Lemon's authenticated HTTP/WebSocket API and optional A2A
network edge. It delegates domain operations to existing services; it is not
another session store, scheduler or agent runtime. See [README](README.md).

## API ownership

- `Methods.Registry` and protocol schemas define the retained RPC surface.
  Add methods only for a real client; migrate callers when removing a method.
  Do not maintain a second prose method catalog or advertise unavailable APIs.
- A method declares authorization scope, validates bounded parameters and
  delegates to the owning service. Keep read, write, admin, approval and pairing
  capabilities distinct. Node connections are not operators.
- Handlers run inline unless slow external/human-approval work explicitly uses
  async dispatch. Async handlers use `ctx.conn_pid`, not `self()`, as the
  authenticated connection identity; approval events must continue flowing.
- Runtime clients consume the advertised `features.methods`/events. Heartbeats
  use ordinary cron jobs and the automation heartbeat policy, not another RPC
  family or session-liveness store.

## Authentication and execution nodes

- Operator tokens are required by default and compared in constant time.
  `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK` is explicit, default-off
  compatibility for actual direct loopback peers only. Use the socket peer
  supplied by the HTTP router; never trust address/role fields in request params.
- `HTTP.RequestOrigin` guards the main and A2A listeners: loopback peers need a
  loopback (or configured) `Host`, and `/ws` and `/acp/ws` accept only an absent
  `Origin` or an exact trusted origin (own listener, LemonWeb, allowlist) before
  upgrading. A missing socket peer is never loopback.
- After `connect`, the server returns `hello-ok`; subsequent requests use the
  established auth context. Stored identity determines token role/scopes.
  Unknown identity types fail closed, never acquire operator privileges.
- Pairing requires operator authorization. A one-time challenge exchanges for a
  bounded node session. Keep the exchange credential out of status projections.
- Worker session and recovery credentials bind durable node ID and exact
  controller URL. Re-pairing an expired session recovers the same identity and
  revokes old sessions/live sockets. Legacy repair is explicitly authorized.
- Off-loopback controllers require `wss://` unless plaintext is explicitly
  permitted over a verified encrypted overlay. Prefer token env vars to flags;
  credentials never enter URLs, status, logs or errors.
- Named execution accepts only JSON-safe execution data. Provider credentials,
  callbacks and source process state stay local; cwd/credentials resolve at the
  destination. Cancellation/steer/redirect bind invocation, run and authenticated
  session. Report acceptance only after destination acknowledgement; stale or
  disconnected sessions and terminal races fail closed.
- General event fanout excludes nodes; nodes receive only targeted node traffic.
  Non-node clients receive the general event stream; there is no per-connection
  subscription API or durable replay cursor.

## Mutations and management

- `:outcome_unknown` is duplicate-risk, not a retryable rejection. Profile chat
  retains the caller-generated run ID and returns a bounded uncertain receipt
  with `retrySafe: false`. Never inspect raw failure terms into wire responses.
- Sessions use `LemonCore.SessionLifecycle`: bounded/redacted reads, exact-key
  delete confirmation, reset previews bound to a single-use token and the
  session's live state digest, and prune previews bound to the exact candidate
  set and millisecond cutoff. Do not manipulate raw run/index tables in handlers.
  `sessions.reset`, `sessions.delete` and each confirmed `sessions.prune`
  deletion run inside `LemonRouter.with_session_lifecycle_fence/3` and pass its
  generation to the mutation (`fence_generation:`, required by the core): they
  are refused while the session has active, queued or unresolved work, durably
  fence all new execution for the session while they run, and report success
  only after verified deletion.
- Node methods are reachable only through their own scoped RPCs. Do not add a
  generic operator RPC that forwards an arbitrary method or arguments to a node.
  `LemonCore.NodeRegistry` invocations are live-only; the only durable trace is
  `LemonCore.SessionActivity` unresolved presence for a remote
  `coding_agent.run` whose stop is unproven, cleared only by that invocation's
  terminal result or the node's later `node.invoke.active` report omitting it.
- Profiles derive paths from validated IDs in `ProfileStore`; chat uses the
  canonical profile session and router path.
- Provider, memory and blueprint mutations keep their owning service's revision
  and exact-confirmation contracts. Catalog clients submit bounded bundle IDs,
  never arbitrary paths. Projections exclude prompts, skills, URLs, raw paths,
  credentials and arbitrary errors.
- Long-running work remains in the runtime. One-shot CLI clients must not create
  a second router/scheduler or mutate lifecycle stores locally as a shortcut.

## A2A

- A2A peers are independent principals, not operator sockets or execution nodes.
  Core owns protocol/client/persistence helpers; this app owns authentication,
  cards, JSON-RPC/SSE framing, rate limits and supervised task attachment.
- Scope all task reads/mutations to authenticated peer identity. An inbound
  `messageId` durably replays the original task for the same peer, and conflicts
  across peers; never submit a second run for a replay.
- Inbound runs carry `a2a` channel provenance (`meta.channel_context`) derived
  from the authenticated peer and context, naming the same conversation as the
  session key. The router applies the approval floor from it whatever the
  submission origin, intersected with the peer allow-list, and refuses an A2A
  request without it. The provenance is `peer_kind: :automation` (group
  approval floor) unless the operator's global config sets a literal
  `trusted_automation = true` on the peer; the session key keeps its DM shape.
- Terminal transitions are first-writer-wins. Accepted cancellation cannot be
  overwritten by delayed finalization or append a post-cancel context turn.
  Runner leases guard terminal writes against reclaimed workers.
- Unknown submissions reconcile the fixed run ID for a bounded interval and
  retain nonterminal reconciliation if unresolved. Later reads may reconcile
  from durable run state. An ambiguous abort is not proof of cancellation.

## Verification

From the umbrella root: `mix test apps/lemon_control_plane/test`.
Use isolated method fixtures plus real WebSocket scenarios for authentication,
role separation, approvals and targeted events. Establish the suite's supervised
Registry/ETS baseline after other apps stop shared runtime applications; restore
only the application set a test owns. Exercise stale confirmations, replay and
ambiguous mutation outcomes, not only registry membership.
