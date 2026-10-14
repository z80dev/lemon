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
fixed identities and never cause a launch retry. Todo and process projections
require the corresponding domain-owner read APIs; their absence is explicit
`unavailable`.

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
