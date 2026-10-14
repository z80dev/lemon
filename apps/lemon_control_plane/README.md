# LemonControlPlane

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
| `profiles.create` | admin | `{id,[name,description,avatar,model,systemPrompt,node,mcpServers]}` | `{profile,summary}` |
| `profiles.update` | admin | `{id,[name,description,avatar,model,systemPrompt,node,mcpServers]}` | `{profile,summary}` |
| `profiles.clone` | admin | `{sourceId,id,[name,description,avatar,model,systemPrompt,node,mcpServers]}` | `{profile,summary}` |
| `profile.chat` | write | `{id,prompt,[model,queueMode,images]}` | `{runId,profileId,sessionKey,node,summary}` |

`profiles.update` preserves omitted fields, clears optional text with `""`, and
uses `"local"` to clear node placement. `mcpServers` is a list of
`{name,url,headers}` Streamable HTTP server definitions, with string-to-string
header objects. Names must be unique; limits are 32 servers and 64 KiB total.
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

`chat.send {sessionKey,prompt,[profileId,agentId,cwd,images,queueMode]}` can use a
profile's persona, model and node on arbitrary task/DM/group session keys.
Named profile requests carry JSON-safe system prompt/bootstrap instructions
and MCP servers to the worker and omit controller-default cwd. Provider
credentials and assistant workspace paths are resolved destination-locally.
MCP tools attach through the existing owner-bound session client lifecycle.

`cron.add {name,schedule,[profileId,agentId,sessionKey,prompt,...]}` persists
`profileId` for agent jobs; `cron.list` job rows expose `profileId` (null when
unset). Each agent run resolves current profile placement/persona rather than
snapshotting the node at job creation. Shell jobs remain scheduler-local.
Profile placement is rejected for shell jobs. Explicit routine `cwd` and model
pins remain supported; an explicit remote cwd is interpreted on the worker.
See [profiles](../../docs/user-guide/profiles.md) for configuration and boundaries.


## Durable session inspection

`sessions.get` (`operator.read`) accepts `{sessionKey}` and returns `{session}`
from the daemon's canonical lifecycle index, including title, pin/archive state
and run counts. `sessions.history` accepts `{sessionKey, limit}` (1–200, default
50) and returns `{session, history}` with redacted structured **run history**.
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
`isActive`, `isLeaf`, and `rewindable`. Text is a redacted native preview, not
thoughts or tool-result bodies. Branch summaries contain `leafId` and `active`.

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

`sessions.fork` requires `operator.write` and accepts only the source
`sessionKey` and `cwd`. The server generates an independent canonical child key,
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
a workspace path or an arbitrary memory scope. Reads require `operator.read`;
add and delete require `operator.admin`. All run asynchronously so a named-node
request does not block the connection's events or heartbeat.

| Method | Parameters | Successful payload |
|---|---|---|
| `memory.list` | `{profileId, query?, limit?, cursor?}` | `{items, nextCursor}` |
| `memory.search` | `{profileId, query, limit?}` | `{items, nextCursor}` |
| `memory.get` | `{profileId, id}` | `{item}` |
| `memory.add` | `{profileId, text, kind?}` | `{item}` |
| `memory.delete` | `{profileId, id, confirm}` | `{deleted: true, id}` |

`limit` is 1–50 (default 25); `query` is bounded to 256 UTF-8 bytes.
`nextCursor` is null at the end of the bounded recent window. Pass a returned
cursor to `memory.list` with the same profile/query; a stale or mismatched cursor
is rejected rather than silently skipping changed memory. This is not an
unbounded archive export.

Each item is exactly `{id, kind, text, source, createdAtMs, updatedAtMs}`.
`text` is an operator-redacted preview of at most 2 KiB, not a full raw memory
record. `source` is `workspace` or `durable`; raw paths, credentials, provenance
contents and arbitrary provider errors are excluded. Workspace preferences use
`kind: "user"` or `"memory"`; durable records retain their supported memory kind.

Adding defaults to `kind: "memory"` (assistant `MEMORY.md`); `"user"` writes
assistant `USER.md`. It uses the same secret/prompt-injection screening and file
size limits as `remember`, not a second store. `text` is bounded to 4,096 bytes.
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
home identity; foreign and unscoped legacy memory is not exposed. There is no
local fallback for an unavailable destination. A lost remote mutation receipt
returns `UNAVAILABLE` with
`{code: "MEMORY_OUTCOME_UNKNOWN", profileId, invokeId, retrySafe: false}`.
Re-read memory before deciding whether to repeat the mutation.

No memory-content event is broadcast. Remote terminal replies use
`node.invoke.result` with `result: {ok: true, payload: <payload above>}` or
`result: {ok: false, error: "<bounded service classification>"}`; the existing
authenticated node/session/invocation ownership checks still apply.

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

| Method | Scope | Request | Success payload |
| --- | --- | --- | --- |
| `node.pair.invite` | pairing | `{nodeName,purpose?,labels?,expiresInMs?}` | `{inviteId,inviteCode,joinCommand,expiresAtMs,summary}` |
| `node.host.info` | read | `{nodeId}` | `{hostname,os,osVersion,arch,cpuCount,memTotalBytes,memFreeBytes,diskTotalBytes,diskFreeBytes,uptimeSec,lemonVersion,defaultCwd,user}` |
| `node.fs.list` | admin | `{nodeId,path,showHidden?}` | `{path,entries,limit,truncated}` |
| `node.fs.stat` | admin | `{nodeId,path}` | `{path,type,size,mtimeMs,mode,mime}` |
| `node.fs.read` | admin | `{nodeId,path,offset?,length?}` | `{path,dataBase64,offset,length,size,mime,eof}` |
| `node.fs.write` | admin | `{nodeId,path,dataBase64,offset?,truncate?,mkdirs?}` | `{path,offset,bytesWritten,size}` |
| `node.fs.mkdir` | admin | `{nodeId,path}` | `{path,created:true}` |
| `node.fs.move` | admin | `{nodeId,path,destination}` | `{path,destination,moved:true}` |
| `node.fs.delete` | admin | `{nodeId,path,confirm}` | `{path,deleted:true}` |
| `node.secrets.set` | admin | `{nodeId,name,value}` | `{name,set:true}` |
| `node.secrets.list` | admin | `{nodeId}` | `{names,limit,truncated}` |
| `node.secrets.delete` | admin | `{nodeId,name}` | `{name,deleted:true}` |
| `node.shell.open` | admin | `{nodeId,cwd?,cols?,rows?}` | `{shellId}` |
| `node.shell.input` | admin | `{shellId,dataBase64}` | `{shellId,accepted:true}` |
| `node.shell.resize` | admin | `{shellId,cols,rows}` | `{shellId,accepted:true}` |
| `node.shell.close` | admin | `{shellId}` | `{shellId,accepted:true}` |

Invites default to purpose `lemon_bot`, labels `[]`, expiry 15 minutes (bounded
to 1 ms–24 hours). The command installs Lemon if missing, then enrolls with the
one-time, exact-name-bound invite credential. No operator token is embedded.
Set `LEMON_CONTROL_PLANE_PUBLIC_WS_URL` to the reachable `wss://.../ws` endpoint
before creating remote invitations. `nodes.list` includes `purpose` and `labels`.
Invite connections have enrollment-only authority and receive no general events.

Paths resolve on the worker, under the node user's home by default. Repeat
destination CLI `--allowed-root PATH` to allow additional existing directories.
Traversal and symlink escapes are rejected; delete requires `confirm` equal to
the exact supplied `path`, and never recursively deletes a nonempty directory.
Read/write/input chunks decode to at most 1 MiB; read defaults to that limit.
Offsets are bytes; writes default to offset zero and truncation at the end of the
written chunk. Use `truncate:false` while uploading intermediate chunks.
Directory and secret listings cap at 500 entries and report truncation.
Unavailable host metrics are `null`, not invented zeroes. Secret values enter
only the destination encrypted store; missing master keys fail closed.
See [files and secrets](../../docs/user-guide/node-files-and-secrets.md).

Terminals use a real worker PTY (`python3` required), with the destination login
shell and worker default cwd unless specified. Dimensions are 1–500 columns/rows.
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
