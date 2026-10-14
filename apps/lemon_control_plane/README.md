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
otherwise the current named placement must resolve uniquely. Local profiles
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
use durable ID-only dispatch, never name fallback even offline; ordinary
profile placement remains name-first. Placement changes only in a separate
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
