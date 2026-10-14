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
Private native requests also require `required_native_privacy_context: 1`, which
checks the actual resolved connection's nested
`capabilities["coding_agent.run"]["nativePrivacyContext"] == {"version":1}`
inside the registry owner before invocation allocation or delivery. An absent/
unsupported marker returns `{:native_privacy_context_unsupported,nodeId}`.
These are internal admission options, not remotely supplied PID values or a
post-response privacy check.

| Method | Scope | Request | Success payload |
| --- | --- | --- | --- |
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
| `node.shell.open` | admin | `{nodeId,cwd?,cols?,rows?}` | `{shellId}` |
| `node.shell.input` | admin | `{shellId,dataBase64}` | `{shellId,accepted:true}` |
| `node.shell.resize` | admin | `{shellId,cols,rows}` | `{shellId,accepted:true}` |
| `node.shell.close` | admin | `{shellId}` | `{shellId,accepted:true}` |

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
