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
missing and non-directory paths are rejected before submission. Canonical
profile sessions reject caller workspace overrides; use `profile.chat`, whose
workspace remains server-owned.

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
