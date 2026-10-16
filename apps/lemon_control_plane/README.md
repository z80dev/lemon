# LemonControlPlane

<!-- Maintenance: strict Credo cleanup keeps runtime behavior unchanged. -->

Authenticated HTTP/WebSocket access to Lemon's assistant runtime. The TUI and
one-shot CLI use its frame-based protocol; handlers delegate to router, session,
profile, cron, skill and blueprint services. The control plane also transports
named native execution-node requests and hosts an optional separate A2A listener.

## Start and connect

From a source checkout, configure a high-entropy operator token and start Lemon:

```bash
export LEMON_CONTROL_PLANE_OPERATOR_TOKEN="$(openssl rand -hex 32)"
./bin/lemon start
```

Connect to the configured `/ws` endpoint (default local port 4040), and send:

```json
{
  "type": "req",
  "id": "connect-1",
  "method": "connect",
  "params": {
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],
    "auth": {"token": "your-configured-operator-token"},
    "client": {"id": "my-client"}
  }
}
```

Use `wss://` for remote access. Never put auth in the URL. The first successful
response is `type: "hello-ok"`, not a normal response frame. It supplies protocol
version, server/connection info, available `features.methods` and `features.events`,
initial snapshot, resolved auth scopes and payload/buffer/tick policy. Discover
the actual supported surface there; do not assume an old method inventory.
A second connect is rejected as already connected.

Operator scopes include read, write, admin, approvals and pairing. Request only
what the client needs; a method requires a matching authorized scope. Before
handshake, ordinary method calls are rejected. Unknown methods, invalid params,
missing auth and insufficient scopes remain distinct protocol errors.

Tokenless loopback is disabled by default. The compatibility setting
`LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true` is only for direct local
clients and must not be used behind a reverse proxy whose socket peer appears
local. Node identity never falls back to operator access.

## Frames and events

After handshake, requests use `type`, correlation `id`, `method` and `params`:

```json
{"type":"req","id":"status-1","method":"status","params":{}}
```

Responses carry the same ID with `ok: true, payload: ...` or
`ok: false, error: {code, message, ...}`. Events are independent frames:

```json
{"type":"event","event":"presence","seq":1,"payload":{},"stateVersion":{"presence":2}}
```

The event bridge maps Bus run/chat/approval/cron/goal/presence traffic to socket
events. Non-node clients receive the general event stream; nodes receive only
targeted node traffic. State-version counters let clients reconcile changed
presence, health and cron data. They are not durable event replay cursors.

Completed `agent` events include an authoritative `cancelled` boolean taken
from the durable completion's metadata, plus a bounded, redacted `error` value.
Clients must not infer cancellation from error wording or from whether the
correlated `chat.abort` acknowledgement has arrived; the terminal event can
legitimately arrive first. Failure and budget-stop completions remain
`cancelled: false` unless a cancellation producer explicitly marked them.

Slow/approval-gated handlers run asynchronously so events and approval resolution
can continue while their correlated request remains pending.

### System status

`status` (`operator.read`) reports the real Lemon release CalVer, env/stamped
build metadata, offline provider credential presence, per-channel redacted health,
and runtime lifecycle availability alongside the existing counters. See the
[system method reference](../../docs/reference/control-plane.md#status) for exact
fields and their limits; credential presence is not a provider network probe.
Admin-only `system.restart` and `system.stop` return acceptance before the
connection schedules their side effects. Restart requires `LEMON_LAUNCHER`;
stop is graceful and does not require a launcher. See the
[lifecycle contract](../../docs/reference/control-plane.md#systemrestart-and-systemstop).


### Verified approval resolution

`exec.approval.resolve` requires the approvals scope and accepts:

```json
{"approvalId":"approval-id","decision":"approve_once","expectedSessionKey":"agent:bot:main","expectedRunId":"run-id"}
```

`approvalId` and `decision` are required. `expectedSessionKey` and `expectedRunId`
are optional nonempty strings (at most 1024 bytes); clients approving an exact
run should provide both. Decisions are `approve_once`, `approve_session`,
`approve_agent`, `approve_global` or `deny`; existing camelCase decision inputs
remain accepted, but responses always use canonical snake_case.

Success is a verified owner receipt, not merely removal from the pending list:

```json
{
  "resolved":true,"approvalId":"approval-id","sessionKey":"agent:bot:main","runId":"run-id",
  "decision":"approve_once","outcome":"approved","approved":true,"replayed":false,
  "resolvedAtMs":1791936000000,
  "summary":{
    "approvalId":"approval-id","resolved":true,"decision":"approve_once","outcome":"approved",
    "cleanup":{"includesAction":false,"includesRationale":false,"includesSecretValues":false}
  }
}
```

`deny` succeeds with `decision:"deny"`, `outcome:"denied"` and `approved:false`.
`sessionKey`/`runId` can be null for an unbound native request. Expected identities
are checked by the owning service and the exact snapshot is replaced atomically:
a stale preview cannot approve another invocation. A completed same-decision
request is idempotent only with both exact expected identities and retained owner
state; it returns `replayed:true`, the original timestamp, and no repeated grants
or events. Without both identities, an already-completed request is rejected.

Pending-approval snapshots and `exec.approval.requested` events redact nested
credentials and credential-bearing rationale text before delivery. Review targets
remain visible; authorization still binds to the owning service's original action
and exact run/session, not the redacted wire copy.

Failures use normal error frames with `details:{approvalId,reason}`:

| Code | `reason` |
| --- | --- |
| `NOT_FOUND` | `not_found` (including missing retained state) |
| `CONFLICT` | `mismatch`, `expired`, `cancelled`, `conflict` (another decision won), `already_resolved`, `resolution_in_progress` |
| `UNAVAILABLE` | `store_unavailable` |
| `INVALID_REQUEST` | malformed IDs, bindings or decisions |

No failure returns `resolved:true`. Terminal state retains only IDs, decision,
outcome, timestamp and a snapshot digest; action, rationale and secrets are omitted.
Named-node approvals use the controller ID and its controller pending identity;
the destination still resolves only its own invocation/run/session-bound worker ID.

Context-owned runs also isolate standing session/agent grants by their private
trusted invocation context, without changing any public session/profile identity.
Another principal or changed policy must obtain its own approval even for the
same public bot session. This private field is not an RPC parameter and is absent
from pending lists, approval events and resolution receipts. Explicit operator
global/node grants remain independent.

Authenticated sockets receive an RFC WebSocket ping every 25 seconds. Browser,
Bun and other conforming clients automatically pong, keeping long-running
outbound streams alive without application-level requests. The listener retains
its 60-second inbound dead-peer timeout for clients that do not respond.

Tool action details use a bounded, credential-redacted wire projection of
visible text/images and selected public result metadata. Hidden thinking,
signatures, callbacks and runtime state are excluded; complete diff snapshots
are omitted rather than truncated into misleading edits. Unexpected JSON
encoding failures drop only the offending event frame and leave the socket
connected for later output and completion.
Malformed method responses are replaced with a correlated
`RESPONSE_ENCODING_FAILED` internal error and `retrySafe: false`, not a socket
disconnect or a fabricated success. Encoding logs contain only a static failure
classification; clients must reconcile any potentially completed mutation.

Ordinary `chat.send` requests may supply `cwd`: a nonempty absolute existing
directory forwarded to the native coding session and its tools. Relative,
missing and non-directory paths are rejected before submission. Profile-bound
(`profileId`) and canonical profile sessions reject caller workspace overrides;
their workspace remains server-owned.

`chat.send` and `profile.chat` accept optional `images` arrays containing
`{"type":"image","mime_type":"image/png","data":"<standard Base64>"}`.
PNG, JPEG, GIF and WebP are supported, with at most five images and 10 MiB
aggregate decoded bytes. Invalid Base64, unsupported/mismatched MIME headers
and over-limit attachments are rejected before submission; errors and summaries
never echo encoded image data. `prompt: ""` is valid for image-only messages.
The default WebSocket JSON frame limit is 16 MiB; an explicitly configured lower
`:max_payload` remains authoritative.

Image-bearing followups stay separate so their prompt/attachment association
is retained. Images cannot use text-only in-flight steering: `steer`/`redirect`
queue the intact request as a followup, and `steer_backlog` queues it as collect.
Queued attachment data has an independent 16 MiB encoded-memory budget.

A lost mutation acknowledgement does not prove failure. In particular,
`chat.send` and `profile.chat` may return `UNAVAILABLE` with the fixed run ID and
`retrySafe: false`; reconcile instead of blindly submitting again. Session delete,
prune, provider edits and blueprint activation retain their owning service's
preview/revision/exact-confirmation requirements. Public management history and
errors are bounded and redacted, not raw run/store dumps.

## Profiles, placement-aware chat, and routines

Profile methods use the canonical `LemonCore.ProfileStore` lifecycle and reload
the router profile registry after mutations:

| Method | Scope | Request | Successful payload |
| --- | --- | --- | --- |
| `profiles.list` | read | `{}` | `{profiles,count}` |
| `profiles.get` | read | `{id}` | `{profile,summary}` |
| `profiles.create` | admin | `{id,[name,description,avatar,model,systemPrompt,node,mcpServers,toolPolicy]}` | `{profile,summary}` |
| `profiles.update` | admin | `{id,[name,description,avatar,model,systemPrompt,node,mcpServers,toolPolicy]}` | `{profile,summary}` |
| `profiles.clone` | admin | `{sourceId,id,[name,description,avatar,model,systemPrompt,node,mcpServers,toolPolicy]}` | `{profile,summary}` |
| `profile.chat` | write | `{id,prompt,[model,queueMode,images]}` | `{runId,profileId,sessionKey,node,summary}` |
| `profiles.sync` | admin | `{id,[nodeId,mutationId]}` | `{profileId,nodeId,mutationId,acknowledged,revisionDigest}` |
| `profiles.sync.status` | read | `{id,nodeId,mutationId}` | `{profileId,nodeId,mutationId,status,acknowledged,revisionDigest}` |
| `node.mcp.discover` | admin | `{nodeId,server}` | `{connected,server:{name,status},tools:[{name,executionName,description,inputSchema,readOnly}],count,truncated}` |
| `node.profile.paths` | read | `{nodeId,profileId}` | `{profileId,nodeId,workspacePath,skillsPath}` |
| `mcp.execution_names` | read | `{server:{name,url},toolNames:[name]}` | `{server:{name},tools:[{name,executionName}],count}` |

`profiles.update` preserves omitted fields, clears optional text with `""`, and
uses `"local"` to clear node placement. `mcpServers` is a list of
`{name,url,headers,[enabledTools,allowedOrigins,approvedPrivateOrigins]}` Streamable
HTTP server definitions, with string-to-string header objects. Names must be
unique; limits are 32 servers and 64 KiB total. `enabledTools` is an exact
raw-tool-name allowlist (no glob expansion): omitted permits all, `[]` none,
and a provided list exposes only those executable tools. Resource/prompt utility
tools are not implicitly granted by an explicit native-tool allowlist.
Create/update/clone/get/list profile projections omit MCP `headers` completely.
Headers are execution-only secrets: not logged, emitted in management events,
or stored in run history. A full replacement list replaces previous headers;
omit `mcpServers` to preserve existing connections, or send `[]` to remove them.
Header values support `${LEMON_SECRET:NAME}` references, including literal
prefix/suffix text. References are resolved through the executing host's
encrypted secret store immediately before MCP attachment—not by the controller.
No environment or external-source fallback/expansion occurs. Missing, malformed
or failing references fail closed with `secret_resolution_failed`; resolved
values never replace the stored/reference-bearing execution definition.
General `node.invoke.request` events contain only
`{invokeId,nodeId,method,timeoutMs,cleanup:{includesArgs:false}}`. Invocation
arguments are sent only on the targeted destination node connection.

Names accept at most 120 Unicode scalar values (defensive 512-byte UTF-8 cap).
`systemPrompt` preserves exact UTF-8, including whitespace, through 131,072
bytes; chat prompts and each persona file remain separately bounded to 65,536
bytes. Invalid UTF-8/NUL or oversized values are rejected, never truncated.
Profile projections include credential-free `mcpConfigFingerprint`: lowercase
SHA-256 of compact JSON server arrays
`[name,url,sortedHeaderPairs,enabledTools|null,allowedOrigins|null,approvedPrivateOrigins|null]`,
in server order. It binds private configuration for lost-response reconciliation
without exposing headers; omission of optional fields differs from an empty list.

`toolPolicy` is the existing native policy object, not a second permission
store: optional `profile`, `allow` (`"all"` or exact registry-name array), `deny`,
`blocked_tools`, `require_approval`, `approvals` (name to `"always"`/`"never"`),
and boolean `no_reply`. Lists/maps accept at most 16,384 entries, names at most
256 UTF-8 bytes. `allow: []` denies all; `{}` clears the stored profile floor,
while omission preserves it. Every canonical/arbitrary profile chat and cron
run inherits the current durable floor. Allow sets intersect, deny/blocked and
required-approval sets union, `"always"` dominates `"never"`, and `no_reply` ORs
with session, invocation and destination ceilings. Corrupt/unreadable profile
storage fails closed. Active sessions retain startup policy; callers must fence
new admission and cancel/settle active runs before acknowledging a restrictive
grant change. Rich execution frames allow 131,072 JSON items within the
configured byte limit (default 16 MiB); unrelated traversal stays at 10,000,
and explicit smaller transport limits remain authoritative.

`chat.send {sessionKey,prompt,[profileId,agentId,cwd,images,queueMode,invocationMcpServers,invocationToolPolicy]}` can use a
profile's persona, model and node on arbitrary task/DM/group session keys.
Named profile requests carry JSON-safe system prompt/bootstrap instructions
and MCP servers to the worker and omit controller-default cwd. Provider
credentials and assistant workspace paths are resolved destination-locally.
MCP tools attach through the existing owner-bound session client lifecycle.
With `profileId`, `invocationMcpServers` uses the same server shape and replaces
the complete default connector list for this run. Omission inherits the profile;
`[]` attaches none. Supplied definitions never merge owner headers or connectors.
Only operator-authorized requests reach this seam.
`invocationToolPolicy` also requires `profileId` and uses the same validated
native shape. Omission or `{}` adds no restriction; `allow: []` denies all.
It intersects rather than replaces persistent/session/node floors, so caller
grants cannot widen denied or required-approval tools. Profile executions never
inherit ambient machine-global MCP connections, including explicit `[]`.
Profile-owned skills load metadata from the destination profile's
`workspace/.lemon/skill/<key>/SKILL.md`, independently of execution cwd;
`read_skill` lazily loads the full body through the owning skill registry.
Image-only remote runs retain the shared five-image/10 MiB decoded admission
limit and native model-vision checks. Only known native image blocks encode to
wire JSON; empty text without valid images and arbitrary structs are rejected.

Product connector definitions must include `allowedOrigins` containing the
exact canonical HTTP(S) endpoint origin. `approvedPrivateOrigins` is a subset
explicitly permitting private destinations. The executing host validates
all DNS answers and pins the real transport to an approved address before
decrypting headers. Host/TLS certificate identity remains the original origin;
redirects are rejected. No-policy operator configurations retain intentional
legacy behavior; product clients must not omit policy.

`mcp.execution_names` is a synchronous operator-read projection for building
closed native allowlists before a profile or HTTP session exists. It accepts
only public server `name`/`url` and at most 256 raw selectable tool names, then
uses the owning native alias function. No profile/node identity, headers,
credentials, DNS lookup or HTTP initialization is required or performed.
The result returns only server name and `{name,executionName}` mappings.
It does not assert that a tool exists, is connected, is read-only or permitted;
live destination discovery and native policy remain separate authorities.

`node.mcp.discover` is an asynchronous operator-admin method targeting an
execution node, never a controller-local or unauthenticated URL fetch.
Discovery uses a temporary owner-bound MCP session with no executable tools,
then closes it. It returns raw tool names and complete input schemas, bounded
to 256 tools, 128-byte names, 4 KiB descriptions, 32 KiB per schema and 1 MiB
total. Oversized/credential-bearing schemas are omitted, not rewritten;
`truncated` marks omitted metadata. `readOnly` defaults false unless the server
advertises boolean `readOnlyHint: true`; it is advisory, not authorization.
`executionName` is the actual native registry alias used in `toolPolicy`. For
profile HTTP clients it hashes public server name, canonical URL and validated
raw tool name, and stays stable across secret rotation and DNS pinning. Never
guess aliases from display names. These clients defer to native deny/approval
policy rather than adding an unconditional MCP approval gate. Server hints
cannot bypass native restrictions; legacy global/ACP aliases and approval rules
remain unchanged.

`profiles.sync` provisions the four controller-owned persona instruction files
and a credential-free revision record on the target, verifying persisted files
before acknowledging. Explicit `nodeId` supports provisioning before a move;
otherwise current placement selects an exact stored durable ID first, even if
offline, and resolves a unique configured name only when no ID record exists. Local profiles
require an explicit target. Sync never switches controller placement and never
copies MCP headers, provider credentials, USER.md, skills or memory. Mutation
correlation is optional (`null` when absent); a non-null mutation/digest binding
is durably reserved before persona writes. The worker retains one latest
binding, rejecting reuse with different content, not an unbounded ledger.
`profiles.sync.status` sends only the requested identity and current source
digest, never persona content. It returns `status: "acknowledged"` only when
the exact binding and stored files verify, `"pending"` for a matching reserved
but unfinished write, or `"unknown"` (null digest) for absent/superseded/mismatched
bindings. Transport, corrupt storage and bad acknowledgements are RPC errors,
not unknown. Status never writes, repairs or resends. Explicit `nodeId` targets
use durable ID-only dispatch, never name fallback even offline. Implicit sync
also preserves stored ID ownership against same-named nodes; legacy actual
names remain supported when there is no exact ID record. Placement changes only in a separate
`profiles.update` after acknowledgment.

`node.profile.paths` is a trusted operator read on an explicit durable node ID.
The worker derives its actual `ProfileStore` workspace/skill paths, including
custom state roots, without creating files or changing placement. Selected
skill provisioning must use the returned `skillsPath`, then the owning node
filesystem stat/CAS APIs, not infer a path from controller state or host cwd.
Lookup grants no filesystem authority: native OS-home/explicit `--allowed-root`
ceilings still apply. Custom state outside admitted roots requires the machine
operator to admit its existing parent root.

`cron.add {name,schedule,[profileId,agentId,sessionKey,prompt,...]}` persists
`profileId` for agent jobs; `cron.list` job rows expose `profileId` (null when
unset). Each agent run resolves current profile placement/persona rather than
snapshotting the node at job creation. Shell jobs remain scheduler-local.
Profile placement is rejected for shell jobs. Explicit routine `cwd` and model
pins remain supported; an explicit remote cwd is interpreted on the worker.
See [profiles](../../docs/user-guide/profiles.md) for configuration and boundaries.

### Private cron admission

Only trusted operators (`admin` scope) configure external admission:

- `cron.admission.set {routineId, token}` stores/rotates a dedicated token in the
  controller's encrypted secret store and returns `{secretName, set: true}`.
  The token is never returned. IDs are nonempty and at most 256 bytes; tokens
  are nonempty, at most 4096 bytes, and cannot contain CR/LF.
- `cron.add` and `cron.update` accept an optional `admission` map with exactly
  `{url, token_secret, routine_id, creator_id, workspace_id}` (snake-case keys).
  `token_secret` is the returned secret name, not the token. This is supported
  only for agent jobs with a `profileId`. Updating with `admission: null`
  removes the hook; omitting the field preserves it. Public add/update/list
  responses expose only `admissionConfigured`.

Operators allow exact callback origins using
`LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` (comma-separated), or
`:lemon_automation, :cron_admission_allowed_origins` in deployment config.
The environment override takes precedence. An empty allowlist admits no
callback. HTTPS is required except explicitly allowlisted HTTP origins at
literal `127.0.0.1` or `[::1]`; `localhost` and all other HTTP hosts are denied.
Callback URLs forbid userinfo, query and fragment. Redirects and HTTP retries
are disabled; the encrypted token is never sent to an untrusted origin.

Before any dispatch the controller POSTs JSON with Bearer authentication:

```text
{jobId, profileId, routineId, creatorId, workspaceId,
 cronRunId, routerRunId, triggeredBy, scheduledForMs}
```

`cronRunId` and `routerRunId` are the scheduler's fixed receipt IDs.
`triggeredBy` is `"schedule"`, `"manual"`, `"wake"`, or `"retry"`;
`scheduledForMs` is the claimed scheduled slot or null for nonscheduled work.
The endpoint returns HTTP 200 JSON
`{allow: true | false, context: <exact echoed request object>}`. Only an exact
context match and `allow: true` admits execution. A matching `allow: false`
records `denied`; any other reply, unavailable credential, timeout/disconnect,
or removed origin trust records `admission_unavailable`. Both are failed cron
run outcomes (also `meta.admission_outcome`), with no router submission and no
automatic retry. The next ordinary occurrence rechecks admission. The callback
must only read policy and project already-authorized invocation configuration;
it must not provision credentials or launch work itself.

For shared/Team profiles, an approved response can additionally contain exactly
one `invocation` object:

```text
{allow: true, context: <exact echoed request object>,
 invocation: {invocationContextKey, memoryContextKey, invocationMcpServers,
              invocationToolPolicy, invocationProof, sharedMemoryGrant: false}}
```

All six invocation fields are required. Unknown top-level, invocation, server,
or policy fields fail closed. Both context keys are 1–128 ASCII characters
matching `[A-Za-z0-9][A-Za-z0-9_.:-]*`; they bind the creator's current execution
and private memory scope. Scheduled callbacks cannot grant shared memory.
The server list uses canonical `chat.send` MCP definitions (`name`, `url`,
`headers`, optional `enabledTools`, `allowedOrigins`, `approvedPrivateOrigins`).
It replaces the whole profile connector list, never merging the profile owner's
default credentials. An empty replacement never falls back to that list, but
a projected invocation must include its required core proof server or admission
fails closed. Header values must be exact `${LEMON_SECRET:NAME}` references, or
`Bearer ${LEMON_SECRET:NAME}` for Authorization. No literal tokens or
controller-side secret resolution occur.
URLs forbid userinfo, queries, fragments, and interpolation; HTTPS is required
except literal-loopback HTTP with the exact origin present in both
`allowedOrigins` and `approvedPrivateOrigins`.

`invocationToolPolicy` is the canonical native policy map (`profile`, `allow`,
`deny`, `blocked_tools`, `require_approval`, `approvals`, `no_reply`). It is
restrictively intersected with the cron tool block and the current profile
floor: allowlists intersect, denials/approval gates union, and an `always`
approval cannot be replaced with `never`. Unsupported policy shapes do not
become permissive defaults.

`invocationProof` uses the shared native factory's exact descriptor:

```text
{runId: <routerRunId>, serverName, serverUrl,
 headerName: "X-Lemon-Bot-Invocation",
 secretName: "lemon_bot/invocations/<routerRunId>"}
```

Exactly one replacement server must match the descriptor's name/URL and carry
that exact header with value
`${LEMON_SECRET:lemon_bot/invocations/<routerRunId>}`. The callback must use the
actual creator's current native invocation builder for this fixed run, not copy
a previous descriptor or proof secret. Before launch, the shared Core factory
validates the proof again against the actual profile-built request, then stamps
canonical private memory/proof attestations. Authentication remains at the
owning boundary: the configured authenticated cron allow receipt, or actual
operator authorization for direct chat. No synthetic operator context is used.

The projection is consumed only after an authenticated allow receipt with an
exact context echo. It remains a private worker argument, not job metadata,
cron run history, an audit field, or a grant from prompt/client text. The
destination request receives the context key and secret-reference-bearing
connector definitions through the normal owning profile/node path.
The two-field response remains valid for existing single-principal jobs.


Admission configuration is durable only in the private owning job record.
Job events, management projections, audit records, run history, and router
requests never include its token or secret reference.


## Session snapshot and reconciliation

`sessions.snapshot` is the read-scoped recovery authority used by TUI and
browser chat. It composes existing owners; it does not persist deltas, schedule
work, or create another session store.

Fresh managed native runs register their existing live owner before execution,
so recovery does not require a lifecycle index created by the first finalized
run. Managed user entries carry owner-written `lemonRun` provenance in the
existing native journal: logical run ID, logical session key and native UUID.
Terminal association follows the selected user entry's exact owned binding,
not the order in which start events reach storage. Declared malformed or
foreign bindings remain unknown; legacy untagged journals retain conservative
prompt/time matching. This metadata does not enter provider input or create
another ownership store.

Requests accept:

```json
{"type":"req","id":"recover-1","method":"sessions.snapshot","params":{"sessionKey":"agent:default:main","cwd":"/srv/project","limit":50}}
```

`sessionKey` is required (at most 1,024 bytes); optional native workspace `cwd`
is bounded to 4,096 bytes, and `limit` is 1–100 messages. The workspace locates
the native session; it grants no additional authority. The native header must
match the logical session's stored resume identity.

A successful payload contains:

- `status: "ok"` and the requested `sessionKey`;
- `identity: {sessionKey, sessionId, branchId, revision, runId, attempt}`;
- `consistency: {boundary: "stable_owner_reads", atomic: false, eventCursor: null}`;
- `snapshot`: `phase`, boolean `terminal`, bounded
  `answer: {text, canonical, truncated}`, history-compatible `messages`,
  current `actions`, `approvals`, `children`, `processes`, `todos`, and `plan`.

Collection projections report `status: "ok"` with `items` and `truncated`,
or `unavailable`/`forbidden`; they never substitute an empty collection for an
unavailable owner. Plan reports `status` plus bounded `value` when available.
Phases are `running`, `completed`, `failed`, `cancelled`, `idle`, or `unknown`.
`unknown` is not idle. A missing terminal tool receipt is outcome-unknown, not
a permanently running tool or fabricated success. Process receipts retain their
fixed identities and never cause a launch retry. Legacy process records without
launch provenance retain their owner-scoped identity and status but report an
outcome-unknown classification, never confirmed launch admission. Todo and
process projections require the corresponding domain-owner read APIs; their
absence is explicit `unavailable`.

The encoded response is capped at 131,072 bytes. Message rows use a 40,960-byte
collection budget, actions 16,384, answer text 16,384, each other collection
8,192, and plan text 8,192. Nested values and item counts have additional caps.
These are credential-redacted recovery previews, not private full exports.
Clients must display omission/unavailability rather than treating a bounded
preview as a complete answer or proof that a process stopped.
The bound applies to the JSON recovery response, **not** the underlying native
journal/agent owner read. Selected-branch collection and revision hashing still
work on the retained native transcript; their working set and owner-to-handler
reply can grow with that authoritative transcript. This change does not claim
constant-memory source reads or replace journal retention with another store.

Revision and attempt are opaque equality tokens, **not ordered counters**.
A live attempt identifies the native execution instance; a retained attempt
uses its fixed run ID when that association is known. The selected native
branch, not simply the newest session run or an idle live session's retained
invocation ID, determines completion. Ambiguous prompt/start-interval association
remains unknown. Answer-so-far belongs only to the current selected user turn;
before that turn produces text, it is empty rather than the previous answer.

The server compares two complete owner-read collections. If they differ, it
returns `status: "retry", reason: "snapshot_raced"` with no snapshot. Optional
`expectedIdentity` must contain the complete prior identity; mismatch returns
`identity_changed`, also without a snapshot. There is no atomic cross-owner
transaction or global durable cursor.

Queue consumers may additionally request
`continuationFrom: {identity: <complete prior accepted identity>, runId: <acknowledged active run>}`.
The successful response's boolean `continuation` is true only for a canonical
terminal of that fixed run on the same native session, with the prior leaf
present in the full selected journal. A same-run live execution token must match;
known retained-owner handoff may use the fixed run ID instead. Unknown attempt
provenance, another owner/run or a non-descendant branch returns false. The proof
uses the existing full owner read, not bounded message previews, and adds no
history export or replay cursor. Normal completion may change leaf and revision.
`expectedIdentity` retains its retry semantics independently of this optional
request; absent a continuation request the response reports false.

The TUI also fences the pre-read projection and active run, not only delivered
events and selection. It uses a newly verified terminal transition to advance at
most one `queued-local` head through its existing drain guard. Repeated terminal
reads, a newer acknowledged send and uncertain/in-flight queue entries cannot
authorize another submission. This is not retry permission for any prior send.


Clients bind reads to their selected session/request generation, discard late
responses, and retry when relevant events or overflow/reconnect indications arrive
while a read is pending, even when no missed data packet was delivered.
Retries are bounded; persistent races/unavailability retain honest known state
and expose recovery failure. After a replacement snapshot, untagged events for
an unknown run request another reconciliation instead of assuming branch
ownership. Recovered active answer text stays replacement-only: uncertain
pre-snapshot deltas must not be appended to it. Terminal completion replaces
partial text once and cannot be revived by a late start/progress packet.

Transport overflow emits WebSocket `stream.resync` and fences/disconnects the
lagging connection. Reconnect and authenticate again, then use the same snapshot
path. A router rendering-loss indication also uses `stream.resync`, but requests
reconciliation without requiring the healthy socket to disconnect. Do not replay
offline mutations. Browser panes and the EventBridge use bounded tagged Bus
delivery epochs so queued messages from a replaced subscription cannot mutate
the recovered view or fence newly connected recipients.

Authorization is checked on each snapshot read. Operators intentionally have
global session inspection through `operator.read`; paired nodes have no such
privilege. Approval payloads additionally require `operator.approvals`.
Reconnect authentication uses the current credential, never the previous
socket's privileges. Process/child projections use exact session ownership,
and foreign native headers are rejected. This is not a new per-session
operator authorization model.

## Durable session inspection

`sessions.get` (`operator.read`) accepts `{sessionKey}` and returns `{session}`
from the daemon's canonical lifecycle index, including title, pin/archive state
and run counts, using the same camelCase session projection as `sessions.list`
(`sessionKey`, `runCount`, `updatedAtMs`, etc.). `sessions.history` accepts
`{sessionKey, limit}` (1–200, default 50) and returns `{session, history}` with
redacted structured **run history**.
Unknown keys return `not_found`; these methods do not invent an empty session or
read a separate client-local store. Keys are non-empty and bounded to 1,024 bytes.

This management history is distinct from native branch messages returned by
`chat.history` with `cwd`. `session.detail` remains the richer routing/run
inspection surface and includes durable title/pin/archive metadata when present,
so reopening a named session restores its display name.

## Native session navigation

Use the same `sessionKey` and native workspace `cwd` for these operations.
Both are required, non-empty strings, bounded to 1,024 and 4,096 UTF-8 bytes
respectively. NUL bytes are rejected. Native runtime failures expose only safe
reason classifications, never exception terms or raw filesystem errors.
Successful tree and rewind receipts include the validated request `sessionKey`
so clients can reject stale or mismatched targets before applying their results.

`sessions.tree` requires `operator.read`. Optional `limit` is 1–500 (default
100); `offset` is 0–1,000,000 (default 0). The result contains `sessionId`,
`leafId`, `entries`, `branches`, `totalEntries`, `offset`, and `hasMore`.
Each entry contains `id`, `parentId`, `type`, `role`, `text`, `timestamp`,
`isActive`, `isLeaf`, `rewindable`, and `label` (the entry's current bookmark
label, `null` when none). Text is a redacted native preview, not thoughts or
tool-result bodies. Branch summaries contain `leafId` and `active`.

`sessions.navigate` requires `operator.write`. It switches the active branch to
`entryId` (at most 256 bytes) and returns `sessionId`, `entryId`, `leafId`,
`prompt`, and `summarizing`. The abandoned branch stays in the tree, so no
preview or confirmation is required; a streaming session is refused with a
`busy` conflict. Selecting a user message lands the leaf *before* it and returns
its text as `prompt` (the same convention as rewind; `null` for other entries).
Optional `summarize` (default `false`) asks a *live* session to summarize the
abandoned branch in the background. `summarizing` is `true` only when a summary
was actually started: a live session leaving a branch of at least two messages
for a different one. A stopped session has no model runtime, so it only moves
the leaf. The next prompt, live or after resume, sees the new branch's history,
model and thinking state.
A background summary is bound to the destination revision. If another prompt,
branch switch or journal change wins the race, the stale result is discarded
without changing the active branch. An accepted result updates both the journal
and the live model context, so continuing and resuming see the same summary.

`sessions.label` requires `operator.write`. It appends a label entry bookmarking
`entryId` with `label`: a string of at most 120 characters (control characters
and whitespace runs become one space) or `null`/empty to clear it. Labels never
change the model-visible context and are resolved across the whole tree, so any
entry — including one on a preserved branch — can be bookmarked. The result is
`sessionId`, `entryId`, and the resulting `label`. Labels in this result and in
`sessions.tree` are strictly redacted, like tree text.

Native startup and stopped navigation, labeling and rewind share journal
admission: a mutation either completes before resume loads the file or is sent
to its published live owner. Live navigation/label receipts are captured in the
same session turn as the mutation. A lost or invalid mutation receipt returns
`reason: "outcome_unknown"` with `retrySafe: false`; inspect the session before
retrying. Confirmed rewind has the same uncertain-outcome contract. Definite
refusals such as `busy` or `entry_not_found` remain ordinary failures.

`sessions.rewind` requires `operator.write`, including previews. Supply an
`entryId` of at most 256 bytes identifying a rewindable user message.
`restoreFiles` defaults to `false`; `dryRun` defaults to `true`.

```json
{"type":"req","id":"preview-1","method":"sessions.rewind","params":{"sessionKey":"agent:default:main","cwd":"/srv/project","entryId":"user-entry-id","restoreFiles":true}}
```

A preview returns `confirmationToken`, `prompt`, `discardedMessages`,
`restorePaths`, `unrestorableTools`, `entryId`, and `sessionId`, plus the
`restoreFiles` and `allowPartialRestore` choices. Show the preview before
executing: send the same target and both choices with `dryRun: false` and the
returned `confirmationToken` (at most 256 bytes). Missing confirmation is
rejected before runtime delegation; stale or mismatched previews are rejected
by the native runtime. Execution echoes that token and both choices, and returns
`prompt`, `leafId`, `restoredPaths`, `entryId`, and `sessionId`. The prompt can be
placed back in the composer. A failed restoration/rollback must not be treated
as proof that no files changed.

File restoration fails closed when the discarded history contains shell
commands. A user may explicitly consent to restoring only checkpointed files
by requesting a **new preview** with `restoreFiles: true` and
`allowPartialRestore: true` (default `false`). Changing this flag at confirmation
invalidates the previous token. Previews and receipts include redacted
`unrestorableCommands`, their total `unrestorableCommandCount`, and
`canAllowPartialRestore`. The client must explain “restore N checkpointed files;
effects of M shell commands are not reverted” and list those commands before
confirmation. A successful partial restoration returns `partialRestore: true`.
Missing non-shell checkpoints, unavailable/truncated command text, or more than
100 shell invocations cannot be bypassed with partial consent. Applied AST
rewrites require checkpoints even after interruption or failure; AST search and
dry-run previews remain read-only. Other shell effects are never undone or
represented as restored.

`sessions.fork` requires `operator.write` and accepts the source `sessionKey`
and `cwd`, plus an optional `entryId` (at most 256 bytes) that ends the child's
history at that entry (inclusive) instead of the source's current leaf. The server generates an independent canonical child key,
copies native resume state through the runtime, and registers the child in the
durable session index with independent lifecycle metadata. The result is
`{sessionKey: "<child>", sourceSessionKey: "<source>"}`. It is discoverable in
`sessions.list` immediately, with zero runs of its own; no synthetic run is
created. If acknowledgement or registration is uncertain, error details retain
the generated keys and `retrySafe: false`; reconcile instead of retrying.
Existing plain keys such as `tui-*` are valid fork sources when their durable
session index identifies the source agent. Children still use canonical keys
for that same agent; an unknown source never falls back to a guessed default.

Name a child with the existing `sessions.metadata.patch` method using
`{sessionKey, title}` (`operator.admin`); `title: null` clears its name.
Find named sessions with `sessions.list` using `{query}` (`operator.read`).
No separate naming or search API is needed.

To name a new conversation **before its first turn**, explicitly call
`sessions.create` (`operator.write`) with a canonical `sessionKey` and native
workspace `cwd`, then use the same metadata patch. Creation returns
`{sessionKey, sessionId, created}` and is idempotent for that key/workspace.
It persists an empty native journal and zero-run session index; it does not send
a prompt, enter plan mode, or manufacture history. Existing native sessions
return `created: false`; a mismatched workspace or non-native identity is not
silently rebound. Metadata patches still refuse unknown session IDs by default.

When reopening native conversations, pass `cwd` to `chat.history`. Its
successful native response is authoritative, including an empty active branch
after rewind. Visible user/assistant text and sanitized native tool calls/results
are projected, preserving call identity and actual output for resumed tool cards.
Abandoned turns, thought blocks, and structural tree entries are excluded.
`limit`, `beforeId`, and `includeFullText` remain available. Native pages are
chronological, defaulting to the latest messages; a `beforeId` cursor selects
messages following that entry, matching the existing cursor contract.
Calls without `cwd`, or runtimes reporting missing/unsupported native history,
retain legacy run-history support; storage failures are not treated as empty
native history.

`sessions.compact` requires `operator.admin` and accepts `sessionKey`, optional
native `cwd`, and optional `focus` instructions. Manual compaction defaults to
`force: true`. Model-backed summarization runs outside the WebSocket connection
process so heartbeats and other control frames continue while it is working.
A disconnected client must inspect session status before retrying: the durable
summary may have committed even when its acknowledgement was lost.

## Profile memory

The `memory.*` methods address a managed profile by `profileId`; they never accept
a workspace path or arbitrary installation-wide scope. Reads require `operator.read`;
add and delete require `operator.admin`. All run asynchronously so a named-node
request does not block the connection's events or heartbeat.

| Method | Parameters | Successful payload |
|---|---|---|
| `memory.list` | `{profileId, query?, limit?, cursor?}` | `{items, nextCursor}` |
| `memory.search` | `{profileId, query, limit?}` | `{items, nextCursor}` |
| `memory.get` | `{profileId, id}` | `{item}` |
| `memory.add` | `{profileId, text, kind?}` | `{item}` |
| `memory.delete` | `{profileId, id, confirm}` | `{deleted: true, id}` |

All five methods also accept private operator selectors:

* `{memoryScope: "private", memoryContextKey: "<verified stable actor key>"}` selects
  **only** that actor's documents in this profile/home. A valid item ID is not proof
  of ownership: list/search/get/delete enforce the same selector in the owning store.
* `{memoryScope: "shared"}` selects only provenance-proven canonical shared documents.
  `memoryContextKey` may be omitted or null here, never a non-null private key.
* Omitting **both** fields retains the legacy unrestricted trusted-operator view,
  including retained workspace files. Product Team UI/backend requests must never
  omit selectors. Malformed/partial selectors fail rather than falling back.

Every explicitly scoped success appends `memoryScope` and `memoryContextKey`
(null for shared) to the table's payload. The backend validates the exact echo
before using results and must strip internal context keys from model/client-facing
responses. Keys are 1–128 ASCII characters matching
`[A-Za-z0-9][A-Za-z0-9_.:-]*`; authenticated services derive them from verified Bot,
actor and audience ownership, not client/model/tool metadata or grant epochs.

For example, a private empty list is:

```json
{"items":[],"nextCursor":null,"memoryScope":"private","memoryContextKey":"private_bot_v1.actor"}
```

`limit` is 1–50 (default 25). Managed `query` accepts at most 512 Unicode codepoints
and 2,048 UTF-8 bytes, without truncation; malformed UTF-8/NUL is rejected.
Unfiltered list browses a recent window. Explicitly scoped queries use the owning
index before its candidate limit, plus full accepted canonical preference text.
A match need not appear in the redacted/2 KiB preview; callers must not re-filter
native matches against that preview. `nextCursor` is null at the candidate set's end.
Pass a returned cursor to `memory.list` with the same profile/query/selector;
stale or mismatched cursors fail. This is not an unbounded archive export.

Each item is exactly `{id, kind, text, source, createdAtMs, updatedAtMs}`.
`text` is an operator-redacted preview of at most 2 KiB, not a full raw memory
record. `source` is `workspace` or `durable`; raw paths, credentials, provenance
contents and arbitrary provider errors are excluded. Workspace preferences use
`kind: "user"` or `"memory"`; durable records retain their supported memory kind.

Adding defaults to `kind: "memory"`; `"user"` selects human preferences. Explicit
private/shared selections write canonical facts through `LemonMemory.Preferences`
in the existing `LemonMemory.Store`, never raw `USER.md`/`MEMORY.md` files.
Only the omitted legacy operator mode writes those files. All paths reuse owning
`remember` secret/prompt-injection screening and compact preference limits;
`text` is bounded to 4,096 bytes. This is not a second store.
Read/list the item before deletion and set `confirm` to its **exact item id**;
booleans or another id are rejected. Opaque item ids bind profile and revision:
workspace preferences bind exact text plus the whole file revision, while durable
ids bind the document revision. Refresh the item after any concurrent change.
Durable deletion uses the lifecycle service's revision-bound preview/confirmation
and atomic compare-and-delete.

For a named-node profile the controller sends only JSON-safe method parameters
over the existing node invocation channel. The destination derives the profile
workspace locally; neither the controller's workspace nor credentials cross the
boundary. Durable records must match both the profile agent id and the assistant
home identity. Explicit selections additionally require persisted actor/shared proof.
No unavailable destination falls back to controller memory. A lost mutation receipt
is `UNAVAILABLE` with
`{code: "MEMORY_OUTCOME_UNKNOWN", profileId, invokeId, retrySafe: false}`; re-read
memory before deciding whether to repeat the mutation.

Explicitly scoped remote requests require the live authenticated connection to
advertise that exact `memory.*` method with `{version: 1, contextVersion: 1}`.
Persisted capabilities do not prove a current worker supports private memory.
Dispatch is pinned to the checked durable ID and connection PID. Old, unqueryable
or reconnected workers fail before enqueue, without private-to-legacy mutation.
A missing/mismatched response selector echo also fails closed.

No memory-content event is broadcast. Remote terminal replies use
`node.invoke.result` with `result: {ok: true, payload: <payload above>}` or
`result: {ok: false, error: "<bounded service classification>"}`; the existing
authenticated node/session/invocation ownership checks still apply.

### Copying scoped memory before moving a profile

`memory.transfer` requires `operator.admin` and runs asynchronously. It does
**not** change profile placement. Supply `{profileId, nodeId, mutationId}` where
`nodeId` is the explicit durable destination node ID (not its display name).
The source is the profile's current placement, pinned to its durable node ID or
`"local"` for controller-local memory.

Use a fresh `mutationId` for each independent move attempt, retaining that same
ID through preview, confirmation, and reconciliation. It is at most 128 bytes,
using letters, digits, `_`, `.`, `:`, or `-`. Reusing an ID for another profile or
destination is a conflict. Source and destination must differ.

Preview before an overwrite:

```json
{"type":"req","id":"move-preview","method":"memory.transfer","params":{"profileId":"researcher","nodeId":"destination-node-id","mutationId":"move-unique-id","action":"preview"}}
```

The payload is:

```json
{"profileId":"researcher","mutationId":"move-unique-id","sourceNodeId":"source-node-id","nodeId":"destination-node-id","snapshotDigest":"<sha256>","destinationDigest":"<sha256>","confirmationToken":"<opaque-token>","sourceCounts":{"documents":12,"preferences":2},"destinationCounts":{"documents":2,"preferences":1},"overwrite":true}
```

Only counts and digests are exposed. `documents` counts selected durable records;
`preferences` counts complete preference files present (USER.md/MEMORY.md, 0–2),
not individual notes. Explain that the destination's selected profile memory and
both preference-file slots will be replaced by the incoming scope; unrelated
profiles, persona files, and other files are retained. After explicit approval,
send the same IDs with `action: "apply"`, `snapshotDigest`, `destinationDigest`,
and `confirmationToken` from the preview. The token binds the exact incoming
snapshot, current destination snapshot, profile, both nodes, and mutation.
A changed source or destination invalidates the plan; create a new move preview
with a fresh mutation ID instead of automatically overwriting or merging.

Without a confirmation token, `action: "apply"` (the default) permits only a
create-only copy to an empty selected destination scope. Divergent existing
memory requires an exact confirmed preview. Success returns:

```json
{"profileId":"researcher","mutationId":"move-unique-id","sourceNodeId":"source-node-id","nodeId":"destination-node-id","snapshotDigest":"<sha256>","copied":true}
```

The destination persists a receipt bound to those identities and digest before
acknowledging success. Same-operation replay returns that exact receipt.
Once apply may have been dispatched, repeating the operation queries only its
destination receipt and never replays the copy. An uncertain outcome returns
`UNAVAILABLE` with `{code: "MEMORY_TRANSFER_OUTCOME_UNKNOWN", profileId, nodeId,
mutationId, retrySafe: false}`. Retain the mutation ID and reconcile before
changing placement or starting a different move attempt.

For a strictly read-only receipt query, call `memory.transfer.status`
(`operator.read`) with `{profileId, nodeId, mutationId}`. It inspects the
destination's durable journal only—even if no controller intent exists—and
never freezes a snapshot, starts an apply, or replays a mutation. Its payload is:

```json
{"profileId":"researcher","nodeId":"destination-node-id","mutationId":"move-unique-id","sourceNodeId":"source-node-id","snapshotDigest":"<sha256>","status":"completed","receipt":{"profileId":"researcher","mutationId":"move-unique-id","sourceNodeId":"source-node-id","nodeId":"destination-node-id","snapshotDigest":"<sha256>","copied":true}}
```

`status` is `completed`, `pending`, or `unknown`. Pending operations have a null
receipt; an absent journal entry is `unknown` with null actual source, digest,
and receipt, **not** proof that a mutation was never applied. Offline/query
failures return `UNAVAILABLE`, not an empty successful result. The response and
receipt must match the exact profile, destination, mutation and expected source
digest before the caller switches placement. This method does not change the
controller journal or profile placement.

Transfer uses a private, frozen owning-service snapshot, not redacted list/get
previews. Scoped run/project documents, canonical private/shared preference facts,
and complete retained assistant `USER.md`/`MEMORY.md` bytes are selected. Both agent
and assistant home identity are checked, destination identities rebound locally,
and private actor keys preserved. Unknown legacy files/rows remain unproven;
copying bytes never creates sharing authority. Retained metadata cannot attest its
own authority: export uses persisted owning-store ownership, and import cannot
promote pre-index private/shared claims. Source memory is retained.
Source snapshots are bounded to 500 documents,
64 KiB per preference file, and 2 MiB encoded total. The node JSON item/depth
policy also applies, with headroom reserved for invocation wrappers; complex
records can reach that bound before 500 documents. Excess or unsafe source data
fails closed rather than being silently truncated or redacted.

No session journals/chat transcripts, credentials, cookies, daily-note files,
or general host files are copied. Home-scoped repository learnings rebind to the
destination profile workspace; other repository groups retain opaque identities
without transporting source repository paths. Their exact facts remain visible
as profile memory, but destination repository-specific recall cannot infer a
new repository mapping.

Private worker methods are `memory.transfer.prepare`, `.snapshot`, `.validate`,
`.preview`, `.apply`, `.status`, and `.inspect` over the authenticated invocation
channel. Each method requires this connection's fresh
`{version: 1, contextVersion: 1}` advertisement and exact ID/PID dispatch binding,
before a source snapshot read or destination apply. Old provenance-unaware
workers cannot strip actor ownership into a legacy copy or attest such a receipt.
Full snapshot content is never included in management responses,
broadcast events, controller operation journals, or logs. Only after `copied`
is durably acknowledged should the caller perform persona sync and explicitly
change profile placement.

## Named execution nodes

On the destination host, supply the controller's operator credential for pairing:

```bash
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join --name worker-1 \
  --controller wss://controller.example/ws --pair --cwd /srv/project
```

The worker saves its own private session/recovery credentials, bound to durable
node ID and exact controller URL; it does not retain the operator token. Later
starts omit `--pair`; use it again after session expiry to recover the same
identity and revoke old sessions. Legacy repair requires explicit
`--pair --repair --node-id ID` authorization.

The destination owns cwd and provider credentials. Only JSON-safe execution data
crosses the wire, not callbacks or source BEAM state. Cancellation and bounded
steer/redirect are invocation-bound and require destination acknowledgement.
Plaintext off loopback requires explicit `--allow-insecure-controller` and a
verified encrypted overlay; otherwise use TLS.

Durable node names are unique and never equal another durable node ID.
Name-or-ID selectors (profile `node`, `agent` node targets) resolve an exact
live durable ID first, and an authorized durable ID never falls back to another
node's name while offline; private execution then pins that ID, connection and
generation.

### Live named-node runs

`coding_agent.run` workers stream live deltas, tool actions and checkpoints through
the authenticated node socket. The controller's normal executor/gateway/router
path publishes them on `run:<runId>` and `session:<sessionKey>`; existing `chat`
and `agent` WebSocket projections are unchanged. A gateway started event is emitted
once on dispatch, and `node.invoke.result` remains the sole terminal outcome.

**Node-only RPC: `node.invoke.event`** (scope `invoke` or `event`):

```json
{"invokeId":"invoke-id","seq":1,"event":{"type":"delta","text":"Hello"}}
```

Success payload:

```json
{"invokeId":"invoke-id","seq":1,"received":true,"duplicate":false}
```

Sequence starts at 1 and covers every event in the invocation, not just text.
Only the node ID, live connection and credential generation owning the invocation
may submit frames. Already-accepted sequence numbers return `duplicate:true`
without republishing; a gap is rejected. Supported envelopes:

| `event.type` | Other fields |
| --- | --- |
| `delta` | `text` |
| `started` | `title` (optional; the controller does not emit a second start) |
| `action` | `action:{id,kind,title,detail}`, `phase:"started"|"updated"|"completed"`, optional `ok,message,level` |
| `checkpoint_created`, `checkpoint_restored`, `checkpoint_deleted` | `checkpointId,checkpointKind,tool,action,pathCount,paths,restoredCount` |
| `approval_requested` | `approvalId,tool,action,rationale,expiresAtMs` |

Events are limited to 64 KiB JSON with the normal depth/item limits. Workers send
one frame awaiting acknowledgement and retain at most 64 queued frames. An
oversized event, exhausted queue, rejected frame or acknowledgement timeout cancels
destination execution and returns a failed terminal result rather than dropping
events. The terminal result waits for all live-frame acknowledgements. Disconnect,
node replacement, invocation timeout or cancellation ends the invocation; reconnect
does not resume/replay cancelled work, and old-session frames cannot revive it.
Completed native runners may already have stopped while their final events await
acknowledgement. Cancelling this transport-only state releases its invocation and
pending approvals without calling the stopped runner or disrupting other runs.
Cancellation also tolerates a live runner exiting concurrently.

Remote tool approvals enter the controller's existing approval store and emit
`exec.approval.requested/resolved`; resolve the **controller** approval ID with
`exec.approval.resolve` as usual. Worker approval IDs are separate and never used
as controller store keys. The broker sends only the owning worker a targeted event:

```json
{"event":"node.invoke.approval","payload":{"nodeId":"node-id","invokeId":"invoke-id","runId":"run-id","approvalId":"worker-approval-id","decision":"approve_once"}}
```

The other decisions are `approve_session`, `approve_agent`, `approve_global` and
`deny`. Delivery is invocation-bound and callable only by the invocation recipient,
not by operator or node RPC callers. The worker resolves only an approval it observed
for that live invocation and run. Approval waits are capped at ten minutes;
disconnect/timeout/caller death cancels pending requests and never authorizes tools.
Cancellation and steer/redirect keep their existing terminal and acknowledgement
semantics.

### Attached-machine methods

Machine operations target the **durable `nodeId`**, not a node name or connection
ID. They execute through the authenticated invocation channel on the destination.
Slow calls dispatch asynchronously, preserving event traffic. Raw file content,
terminal input/output and secret values are never written to invocation records
or general events; audit lines contain only operation and outcome classifications.
`node.invoke` cannot bypass the admin-scoped file, secret or terminal methods.

Internal callers inspecting a node before dispatch can pin that live connection
with `NodeRegistry.invoke_node(..., expected_pid: inspected.pid,
expected_generation: inspected.generation)`. PID replacement or credential
generation change returns the definite pre-dispatch error `{:node_connection_changed,nodeId}`.
Native requests also require `required_native_privacy_context: 1`, which checks
the actual resolved connection's complete native descriptor inside the registry
owner before invocation allocation or delivery: `coding_agent.run` version 2,
`executionContext` version 1, and `nativePrivacyContext` version 1. An absent or
unsupported descriptor returns `{:native_privacy_context_unsupported,nodeId}`.
These are internal admission options, not remotely supplied PID values or a
post-response privacy check.

| Method | Scope | Request | Success payload |
| --- | --- | --- | --- |
| `providers.management.list` | admin | `{}` | Redacted provider listing for the controller |
| `providers.management.api_key.set` | admin | `{targetId,providerId,value}` | Updated redacted listing |
| `providers.management.disconnect` | admin | `{targetId,providerId}` | Updated redacted listing |
| `providers.management.default.set` | admin | `{targetId,providerId,modelId}` | Updated redacted listing |
| `node.providers.management.list` | admin | `{nodeId}` | Redacted provider listing for the destination |
| `node.providers.management.api_key.set` | admin | `{nodeId,targetId,providerId,value}` | Updated destination listing |
| `node.providers.management.disconnect` | admin | `{nodeId,targetId,providerId}` | Updated destination listing |
| `node.providers.management.default.set` | admin | `{nodeId,targetId,providerId,modelId}` | Updated destination listing |
| `node.pair.invite` | pairing | `{nodeName,nodeId?,purpose?,labels?,expiresInMs?}` | `{inviteId,inviteCode,joinCommand,expiresAtMs,summary}` |
| `node.pair.invite.revoke` | pairing | `{inviteId}` | `{inviteId,revoked:true}` |
| `node.capabilities.get` | read | `{nodeId}` | `{nodeId,os,measuredAtMs,stale,items}` |
| `node.runtime.features` | read | `{nodeId}` | `{nodeId,protocol,lemonVersion,methods,features,botReady,missingFeatures}` |
| `node.host.info` | read | `{nodeId}` | `{hostname,os,osVersion,arch,cpuCount,memTotalBytes,memFreeBytes,diskTotalBytes,diskFreeBytes,uptimeSec,lemonVersion,defaultCwd,user}` |
| `node.fs.list` | admin | `{nodeId,path,showHidden?}` | `{path,entries,limit,truncated}` |
| `node.fs.stat` | admin | `{nodeId,path}` | `{path,type,size,mtimeMs,mode,mime,readable,writable}` |
| `node.fs.read` | admin | `{nodeId,path,offset?,length?}` | `{path,dataBase64,offset,length,size,mime,eof}` |
| `node.fs.write` | admin | `{nodeId,path,dataBase64,expectedModifiedAtMs?,offset?,truncate?,mkdirs?}` | `{path,offset,bytesWritten,size,mtimeMs}` |
| `node.fs.mkdir` | admin | `{nodeId,path}` | `{path,created:true}` |
| `node.fs.move` | admin | `{nodeId,path,destination,expectedModifiedAtMs,overwrite?}` | `{path,destination,moved:true}` |
| `node.fs.delete.preview` | admin | `{nodeId,path,recursive?}` | `{path,stat,childCount,childrenDigest,candidateCount,confirmationToken,expiresAtMs}` |
| `node.fs.delete` | admin | `{nodeId,path,confirm,confirmationToken}` | `{path,deleted:true}` |
| `node.secrets.set` | admin | `{nodeId,name,value,operationId?}` | `{name,set:true}`; with an operation ID also `{operationId,status:"applied",currentBindingMatches}` |
| `node.secrets.list` | admin | `{nodeId}` | `{names,limit,truncated}` |
| `node.secrets.delete` | admin | `{nodeId,name}` | `{name,deleted:true}` |
| `node.secrets.receipt` | admin | `{nodeId,operationId}` | `{nodeId,operationId,status,name,currentBindingMatches}` |
| `node.process.run` | admin | `{nodeId,processId,cwd,argv,stdinBase64,timeoutMs,maxOutputBytes}` (all required) | `{processId,nodeId,state,exitCode,stdoutBase64,stderrBase64,outputTruncated}` |
| `node.process.get` | admin (read-only) | `{nodeId,processId}` | Same receipt; additionally permits `state:"not_found"` |
| `node.process.cancel` | admin | `{nodeId,processId}` | Same receipt; absent ID becomes a durable cancelled tombstone |
| `node.shell.open` | admin | `{nodeId,cwd?,cols?,rows?}` | `{shellId}` |
| `node.shell.input` | admin | `{shellId,dataBase64}` | `{shellId,accepted:true}` |
| `node.shell.resize` | admin | `{shellId,cols,rows}` | `{shellId,accepted:true}` |
| `node.shell.close` | admin | `{shellId}` | `{shellId,accepted:true}` |

Provider management is an owner-authorized, write-only credential surface. Product
callers must establish workspace ownership and actual machine ownership before
using its admin RPCs; ordinary machine access is not ownership. A node credential
cannot call these methods, and generic `node.invoke` cannot bypass their scope.
List first and bind every write to the returned exact `target.id`. The controller
has a durable target identity; destination targets bind the authenticated durable
node ID. A mismatch fails before the provider service mutates anything.

All operations return `{target:{id,nodeId,hostname},default:{providerId,modelId},
providers:[...]}`. Provider rows contain only capability/configuration/readiness
metadata: `id`, `displayName`, `methods`, `configured`, `status`,
`lastValidation`, `environmentOverrides`, and `configurationOverrides`. No API
key, OAuth material, credential prefix, or upstream error is returned. Provider
IDs use canonical base IDs, including `openai_codex`. Requests reject unknown
fields and require bounded nonempty strings (256 bytes for target/provider/model
IDs, 251 bytes for node IDs, 16 KiB for API-key values). Target and node IDs use
only ASCII letters, digits, `_`, `.`, `:`, and `-`. Listing is static resolver
inspection, not a provider call.
Writes return the same listing shape; environment, project configuration, and
credential-pool precedence remain visible rather than being silently overwritten.

The optional CLI provider setup service is loaded at runtime without a control
plane dependency on the CLI app. Named-node operations use authenticated NodeIO
transport and invoke that service on the destination, never an arbitrary command
or a controller-side credential store. Unavailable/uncertain mutation responses
are not automatically retryable: inspect the destination listing before another
write. Secret-bearing request data and exception text are excluded from transport
diagnostics.

Invites default to purpose `lemon_bot`, labels `{}`, expiry 15 minutes (bounded
to 1 ms–24 hours). Labels are a record with at most 32 nonempty keys (64 UTF-8
bytes) and string values (256 UTF-8 bytes). The command uses a provisioned
destination source checkout or installs an explicitly pinned operator-supported
build through the existing installer, then verifies actual worker compatibility
before enrollment. It never defaults to the currently published release or PATH.
The exact-name-bound credential embeds no operator token. Optional `nodeId`
creates a repair invitation bound to that durable
identity, recovery hash and current generation; it never creates a replacement
identity. Revocation invalidates only a pending unused invite.
Set `LEMON_CONTROL_PLANE_PUBLIC_WS_URL` to the reachable `wss://.../ws` endpoint.
`nodes.list {name?,nodeId?}` filters exact matches before caps; rows include
`purpose`, label records and `enrollmentInviteId` (null for legacy nodes), and
`summary.truncated` distinguishes capped inventory. Invite connections have
enrollment-only authority and receive no general events.

Runtime selection uses `LEMON_NODE_SOURCE_CHECKOUT` (absolute destination path),
or **both** `LEMON_NODE_INSTALL_VERSION` and `LEMON_NODE_INSTALL_BASE_URL`
(HTTPS operator-supported artifacts). Equivalent Elixir settings are
`:node_source_checkout`, `:node_install_version`, and `:node_install_base_url`.
Loopback development can use the controller's actual compiled source checkout.
Configured version pins must match `lemon version` exactly. Generated commands
run `lemon node capabilities --json --require-bot` before consuming any invite;
direct invite joins perform the same fail-closed check.

`node.runtime.features` reports protocol 1, declared methods and ten boolean
feature flags: `hostIO`, `filesystemCAS`, `deletePreviews`, `encryptedSecrets`,
`ptyShell`, `mcpDiscovery`, `profileSync`, `liveStreaming`, `repairInvites`,
`nativeExecutionPolicy`. `missingFeatures` is sorted; `botReady` is true only when
all are present, including required Python/assets, the large native tool-policy
JSON envelope and native privacy-context protocol version 1. Native policy readiness
requires the actual worker's nested `coding_agent.run.nativePrivacyContext` descriptor,
not just a shared JSON helper. This is installed software compatibility, **not** provider login,
per-bot policy or an OS permission grant. Reconcile the live enrolled exact node
and require its `botReady:true` before declaring a machine ready; an online socket
or a matching version string alone is insufficient.

Paths resolve on the worker, under the node user's home by default. Repeat
destination CLI `--allowed-root PATH` to allow additional existing directories.
Descriptor-relative file operations pin worker policy roots and use `O_NOFOLLOW`;
caller path traversal and symlink escapes are rejected. All worker file calls
serialize through one supervised owner. Existing-file writes require matching
`expectedModifiedAtMs`; zero means require missing. Moves require the source
revision and default to native atomic no-overwrite (`overwrite:true` is explicit).
Delete previews bind revisions and exact candidate sets to a one-use, five-minute
worker token. Execution requires that token and `confirm` equal to the exact
caller path. Nonrecursive deletion is the default; recursion requires an explicit
recursive preview. Stale proofs fail closed; local external writers are not
sandboxed, and raced recursive deletion can leave a partial outcome.
Read/write/input chunks decode to at most 1 MiB. Writes default to offset zero
and truncation at the end of the chunk; use `truncate:false` for intermediate
chunks and carry the returned `mtimeMs` into the next CAS. Directory and secret
listings cap at 500. See [files and secrets](../../docs/user-guide/node-files-and-secrets.md).

Supported macOS/Linux host snapshots contain real measured memory, disk, CPU,
uptime and version data. Failed or unsupported measurement returns `UNAVAILABLE`,
not nulls or invented zeroes. Secret values enter only the destination encrypted
store; missing master keys fail closed.

For durable install reconciliation, fix a unique `operationId` (1–128 ASCII
letters/digits/`_:-`) before `node.secrets.set`. The destination atomically stores
encrypted value and a private intent/current-revision receipt in one vault row.
An identical still-current operation returns its original proof without another
set; conflicting or superseded intent fails with `CONFLICT`. Query
`node.secrets.receipt` after a lost response rather than replaying the mutation.
Status is `"applied"` or `"not_found"`; `name` is null for not found, and
`currentBindingMatches` is false when not found or when replacement, deletion,
expiry or key rotation invalidated the original encrypted binding. The query
does not decrypt, change secret usage, set a value or replay an operation.
Historical proof survives ordinary mutations and never exposes values, private
fingerprints or digests. History is bounded to 128 operations per owner/name;
capacity fails closed without evicting proof. `secret_store_failed`, timeouts and
transport loss can be ambiguous and must be reconciled. Vault/lease diagnostics
are content-free, including failure logs.

Reserved private invocation proof names `lemon_bot/invocations/<runId>` require
`operationId` exactly equal to that run ID. The controller queries the owning
`NativeLineage.pending_destination(runId,nodeId)` before provisioning: a pending
follow-up must retain its sealed exact node/PID/generation; only strict owning
Store absence permits a new pre-admission root and fresh live-ID inspection.
Existing nonpending/terminal/malformed rows, target/profile/session mismatch and
query failure never fall back to root provisioning. Both paths require privacy
protocol v1 and pin PID/generation atomically in dispatch before sending the proof
value. Names are inspected after the same trim normalization used by the vault,
so decorated names cannot bypass this guard. No caller-supplied flag grants this
authority; raw `node.invoke` remains forbidden for secret methods. Ordinary
secret operations and read-only reconciliation retain their original behavior.

After a successful awaited vault reply, the wrapper rechecks the owning lineage
and the **same pre-provision PID/generation** plus current privacy capability
before acknowledging success. Current pending target configuration/policy changes
or ownership loss cannot become a positive proof acknowledgement. Pending lookup
disappearance never becomes a fresh-root fallback; an initial root must remain
strictly absent from admission. Failure returns `UNAVAILABLE` with
`reason:private_proof_acknowledgement_changed`, `preDispatch:false`,
`retrySafe:false`, and `mutationMayHaveApplied:true`: the value may already be
durable, so do not replay. This acknowledgement is not model authority; actual
root admission still validates placement, configuration and policy.

Capability items contain `{id,name,category,supported,configuredLevel,osGrant,
tools,reason,measuredAtMs,stale}`. Categories are `files|shell|browser|connector|os_app`,
levels `off|read_only|read_interact`, and OS grant states
`granted|denied|not_required|unknown`. Probes read the destination's actual tool
catalog/root permissions, executable availability and browser backend status.
macOS Peekaboo grants and Linux X11 connection status are passive, bounded
checks; unavailable inspection stays unknown, never fabricated denial or grant.
Full Disk Access has no supported nonprompting macOS query and remains unknown.
Connector authorization is session-scoped, not invented from method names.
These measurements are not per-bot grants or an OS sandbox.
The shell tool inventory includes `lsp_diagnostics` only when that exact native
tool is in the actual registry and destination shell machinery is supported.
It resolves destination workspace files and can execute local language checkers;
it is not baseline/read-only access. Product diagnostics require effective files
**and** shell `read_interact` ceilings and normal tool approvals. Installed language
checker availability remains the diagnostic tool's actual result, not an OS grant.

### Native automated processes

`node.process.*` is the non-PTY destination-native execution path for automated
HostDriver actions and probes. All three methods require operator `admin` and
dispatch asynchronously; `run` awaits the bounded final receipt, while `get`
only reads a fixed-ID receipt and never starts or replays work. Interactive
`node.shell.*` terminals remain unchanged. There is no shell-string, PTY, SSH,
or named-node fallback for native process requests.

Every run field is required; no environment, shell, TTY, or client admission
options are accepted. `processId` is 1–128 ASCII letters/digits/`_`/`:`/`-`.
`argv` is 1–128 literal UTF-8 strings without NUL; each and their total are at
most 131,072 bytes, with a nonempty executable in `argv[0]`. Later empty
arguments are valid. `cwd` is a nonempty UTF-8 path of at most 4096 bytes without
NUL or traversal, admitted and descriptor-pinned under the destination's home
and explicit `--allowed-root` roots. `stdinBase64` is standard base64 decoding
to at most 1 MiB (empty is allowed); stdin closes at EOF. `maxOutputBytes` is
1–1,048,576 **combined** stdout/stderr bytes. `timeoutMs` is 1000–1,800,000
(30 minutes). Run's broker deadline is `timeoutMs + 5000`; the local await
allows another 1000 ms. Get/cancel use the normal 30-second broker budget.

The method resolves the actual durable `nodeId` and internally pins its PID
and generation. Registry admission requires `required_process_execution: 1`
and actual version-1 descriptors for all three process methods before delivery;
caller-supplied options and generic `node.invoke` cannot bypass this boundary.
The broker supplies authenticated `nodeGeneration`, never a caller generation.

The frozen seven-field receipt has state `running|completed|cancelled|outcome_unknown`
(get additionally `not_found`). `exitCode` is an integer only for an observed
OS exit, otherwise null. A `completed` receipt requires that observed integer
exit, even when captured output is unavailable; null exit is not completion
evidence. Output strings represent captured bytes; `""` means actually measured
zero bytes, not absent output. Unavailable outputs are
null/null with `outputTruncated:true`; running, unknown and not-found receipts
also have null exit. Restarted receipts retain known state/exit but do not
persist raw output. Missing receipt fields fail closed rather than being filled
with fabricated empty output. A transport failure stays an error, not an
execution receipt or proof of absence.

Choose the fixed ID before first intent and retain it across controller timeouts.
Never redispatch uncertain execution: reconcile with `get` on the original
node/ID. Only a successful strict destination Store absence read can return
`not_found`; offline/error is not absence. Cancel of an absent ID durably writes
a tombstone before acknowledgment so a racing later run cannot start. Active
cancellation is bound to the original authenticated owning node/generation;
a replacement worker cannot cancel its predecessor's job, although get can
read its receipt. Timeout/overflow/cancellation clean up the process group and
descendants where supported, without inventing an exit code.

The narrow worker owner admits at most 16 active processes and retains at most
1,000 durable fixed-ID fences across its destination service. Spent IDs and cancel
tombstones do **not** expire: exhaustion returns `process_receipt_limit` before
new execution, never deletes a fence to make an old ID runnable. Automated
inspection/probe intents consume this capacity too; operators must provision a
destination with available admission capacity rather than clear/reuse spent IDs.
Captured output is volatile, limited to 16 completed receipts and a 24-hour cache
lifetime; cache loss never erases original status/exit or allows redispatch.

Argv, stdin and captured output are private to the authenticated request/response
transport and never enter general events, model context, logs, or durable process
receipt content. Keep credential-bearing inputs and outputs in a trusted backend
over `wss://` or a trusted encrypted overlay. See the exact request examples and
reconciliation workflow in [node files, secrets and native processes](../../docs/user-guide/node-files-and-secrets.md#native-processes).

### Interactive terminals

Terminals use a real worker PTY (`python3` required), with the destination login
shell and worker default cwd unless specified. Cwd is opened through the same
descriptor-root resolver and applied with `fchdir`, not a raced path-based chdir.
The helper reads exactly one length-prefixed worker policy packet before forking;
later input packets remain in the terminal protocol. Its shared filesystem
resolver is import-safe: the filesystem packet server runs only when that helper
is executed directly, never while the PTY imports its descriptor policy.
Dimensions are 1–500 columns/rows.
`node.shell.output {shellId,dataBase64,seq}` (one-based per-shell sequence) and
`node.shell.exit {shellId,code}` are delivered **only to the opening connection**;
foreign connections cannot operate a shell. The node-only `node.shell.event
{invokeId,payload}` transport validates the receiving connection, credential
generation and active opening invocation. No terminal data reaches the Bus.
PTY output has 16 KiB chunks, acknowledgement backpressure, a 32 MiB total cap
and one-hour lifetime. Disconnect, close, timeout, node replacement and slow
consumers terminate the terminal and clean up its process group. Limits are
64 terminals globally and eight per opening connection.

See [attaching a bot machine](../../docs/user-guide/attaching-a-bot-machine.md).


## Other HTTP surfaces

- `/healthz`: local service health; it does not prove a provider-backed turn.
- `/v1/*`: [OpenAI-compatible preview](../../docs/tools/openai-compatible-api.md),
  including model metadata, chat/responses, retrieval and cancellation. Configure
  `LEMON_OPENAI_COMPAT_API_TOKEN` (or `LEMON_OPENAI_COMPAT_TOKEN`) for bearer/
  `x-api-key` auth. Generation reuses the router; queued/wait/SSE modes and safe
  image input limits are described in the linked guide.
- `/acp`: [ACP editor adapter](../../docs/tools/acp.md); configure
  `LEMON_ACP_API_TOKEN` for HTTP bearer/`x-api-key` auth. The guide also describes
  the line-oriented stdio bridge and client filesystem/permission callbacks.
- Optional [A2A](../../docs/user-guide/a2a-peers.md) uses a separate listener
  (default 9901) enabled by `[gateway] enable_a2a = true`. Peers are independent
  principals. Task access is peer-scoped and message IDs durably replay the
  original task. Unknown submissions reconcile; cancellation is first-writer-wins.

`:lemon_control_plane, :port` controls the listener; test default `0` chooses a
free port. `:git_commit` may supply server version metadata. Runtime configuration
and source/release commands are covered in the [CLI guide](../../docs/user-guide/cli.md).

## Development

Read [AGENTS.md](AGENTS.md) for authorization, lifecycle and privacy invariants.
`Methods.Registry` and `Protocol.Schemas` are the authoritative method/schema
catalog. From the umbrella root, run `mix test apps/lemon_control_plane/test`.
