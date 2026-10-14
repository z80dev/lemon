# User-managed profiles

Profiles let one Lemon runtime host durable specialist agents without adding a
second execution engine. A profile is the canonical `[profiles.<id>]` router
record plus an isolated home derived from its validated ID:

```text
~/.lemon/profiles/research/
├── config.toml
├── profile.json
├── sessions/
└── workspace/
    ├── memory/
    └── .lemon/skill/
```

The profile ID is stable. Its main conversation is always
`agent:<id>:main`; renaming the display name does not fork or lose that chat.
The native `coding_agent -> lemon_agent -> lemon_ai` path remains unchanged.

## Create and chat

```bash
lemon profile create research \
  --name "Research" \
  --description "Evidence-first research specialist" \
  --model openai:gpt-5

lemon profile show research
lemon profile chat research "Map the unresolved questions"
lemon profile roster
```

The terminal UI exposes the same server-owned records. Run `/profiles` for a
filterable node-aware roster; selecting an entry opens its stable
`agent:<id>:main` conversation. `/profile current`, `/profile show <id>`, and
`/profile open <id>` inspect or select a profile. After selection, ordinary
prompt submissions use `profile.chat` rather than generic `chat.send`, so the
daemon still derives the profile workspace and named-node route:

```text
/profiles
/profile create research --name "Research" --model openai:gpt-5 --node newphy
/profile chat research Map the unresolved questions
```

The TUI also supports `clone`, `rename`, credential-safe `export`, and guarded
`delete` subcommands. Use `/profile help` for exact syntax. Delete requires the
same profile ID again through `--confirm`; the TUI never accepts a profile home
or workspace path. Export's destination is the sole lifecycle output path.

The token-required browser management shell exposes the same core lifecycle at
`/manage/profiles`. It provides a bounded filterable roster, local/named-node
availability, profile detail, create, clone, rename, recoverable delete, and a
direct link to the stable canonical chat. Every write is preview-first. Clone,
rename, and delete previews bind an opaque hash of the current profile and fail
closed if it changes; delete also requires the exact profile ID. The page never
loads derived paths or system prompts into LiveView state. Credential-safe
export remains available through the CLI, TUI, and control-plane API.

Both launchers start the runtime through the launcher when it is not already
healthy. The one-shot `profile chat` process then submits to that runtime
rather than starting a second router whose work would disappear when the CLI
exits.

Use `--node <name>` at creation time to route canonical chat through an
authenticated named execution node. The roster reports `local`, `online`, or
`offline`. Named runs omit controller working directories and use the worker's
destination-local default cwd. Provider credentials remain destination-local.
The execution request carries the profile system prompt and known bootstrap
instructions (`AGENTS.md`, `IDENTITY.md`, `README.md`, `SOUL.md`) as
JSON-safe text. These instructions overlay that run's destination-local
assistant workspace; no profile files need to be pre-installed on the worker.
`USER.md` is mutable destination-owned preference memory, not a persona
snapshot. Its additions/deletions remain effective on subsequent sessions.

Selected skills remain under that destination profile's
`workspace/.lemon/skill/<key>/SKILL.md`. The native available-skills prompt
loads metadata there even when the worker's project cwd differs; `read_skill`
loads the full selected body lazily through the existing skill registry.
Skill Markdown is not concatenated into `systemPrompt` or truncated to fit it.

All lifecycle reads support `--json`. Chat also accepts `--model` and
`--queue-mode collect|followup|steer|interrupt` overrides. Its working boundary
remains the derived profile workspace; generic chat/delegation APIs own any
explicit project-directory selection. Omitting overrides uses the profile and
normal runtime defaults.

## Clone, rename, and delete

```bash
lemon profile clone research research-copy --name "Research Copy"
lemon profile rename research "Research Prime"
lemon profile delete research-copy --confirm research-copy
```

Clone copies regular profile-home files but rejects symlinks and special files.
Rename updates only presentation metadata. Delete refuses the reserved
`default` profile, requires an exact matching confirmation value, and moves the
managed home to `~/.lemon/trash/profiles/` before removing its TOML table. A
failed config commit restores the home.

Lifecycle config edits are serialized and atomically replace the global config
file. Targeted TOML patching preserves unrelated tables, unknown keys, and
comments instead of decoding and rewriting the entire user file.
Accepted newlines, control characters, and literal backslashes in managed text
survive updates and cloning exactly. MCP definitions and tool policies likewise
round-trip without dropping configured entries.

## Credential-safe export

```bash
lemon profile export research ./research-profile.json
```

The default export is deliberately selected-file, not a backup of the entire
home. It includes portable profile metadata, profile-local config, known
bootstrap markdown, and text files under the profile skill tree. Before
encoding it redacts sensitive assignments and recognizable inline credential
patterns.

It does not include:

- sessions or message history;
- memory content or artifacts;
- binary files or special files;
- secret-like paths such as `.env`, token, password, credential, or private-key
  files.

The JSON `exportPolicy` and command result report selected file, omission, and
redaction counts. There is intentionally no packaged CLI option to include
secrets. Review any export before sharing it.

## Control-plane API

Clients can use the equivalent JSON-RPC methods:

- `profiles.list`, `profiles.get`, and `profiles.roster` (`read` scope);
- `profiles.create`, `profiles.update`, `profiles.clone`, `profiles.rename`,
  `profiles.export`, and `profiles.delete` (`admin` scope);
- `profile.chat` (`write` scope).

`profile.chat` returns the run ID and stable session key without echoing the
prompt. It does not accept a caller-supplied working directory or node: both
come from the validated profile record. Lifecycle and export summaries are
credential-free by construction.

### Fixed admission IDs and reconciliation

`chat.send` (including its `profileId` path) and `profile.chat` accept optional
`runId`. Generate and persist this ID **before** sending: 1–128 ASCII letters,
digits, underscores, dots, colons or hyphens, beginning with a letter or digit.
If omitted, the runtime generates it. A fixed ID durably binds the complete
normalized execution intent. An identical submission returns its receipt without
dispatching again; changed content, placement, images or queue mode conflicts
with `CONFLICT` and details `code: "RUN_ID_CONFLICT"`. Profile edits can change
the resolved intent, so do not use a resubmission as a substitute for receipt reads.

The configured Store must support a successful durability barrier. The router
flushes its submitting fence before dispatch, uncertainty fences before merge
effects, and receipts before acknowledging them. A failed barrier preserves the
fixed ID as `outcome_unknown`; work never dispatches across an unproven fence.
Receipt replay/readback also requires a successful barrier, so an earlier failed
flush cannot turn a merely visible row into a durable acceptance.

Trusted operator producers can also supply `chat.send.invocationContextKey`,
an opaque keyed digest derived from the **authenticated** initiating principal,
effective policy, connector/grant epochs and exact MCP configuration. It uses
the same bounded ASCII identifier alphabet as `runId` and is private execution
metadata, not an authorization grant or a caller-claimed user identity.

An optional `memoryContextKey` supplies a stable private memory identity. The
trusted backend derives it from the authenticated principal, workspace, bot and
authorized conversation/surface audience, distinguishing private DM/task memory
from shared-room memory. Unlike the invocation key, it excludes policy/grant
epochs. It has the same scalar validation and requires `invocationContextKey`.
The control plane installs the private verification marker only after validating
both keys; caller/provider/tool proof flags are never accepted.

Trusted control-plane producers use
`LemonControlPlane.ChatSubmission.attach_execution_context/3` with the actual
authenticated operator context and the already-built fixed-ID profile request.
It authorizes grants/proofs, then delegates to the shared pure factory
`LemonCore.InvocationProof.attach_execution_context/2`. Scheduled admission calls
that same pure factory only after its owning authenticated, admin-configured
callback validates the bound projection, with `sharedMemoryGrant: false`; it
must not synthesize an operator context. The pure factory grants no authority
itself. The request must already contain the explicit per-principal MCP
replacement and effective restrictive policy. The projection's `runId` must
match that request's actual fixed ID.

`sharedMemoryGrant` defaults to `false`. Enabling it requires both validated keys
and an authenticated operator connection with `admin` authorization; the backend
must derive it solely from explicit workspace-maintainer/admin shared-write
intent, never a product client field. Only the control-plane factory stamps the
private grant. Native children inherit it only within the unchanged authorized
context. It permits explicit shared `remember` writes, not shared automatic run
capture: automatic capture remains private regardless of this flag.

Trusted admin `chat.send` producers may add `invocationProof` only with both
verified context keys and an explicitly submitted fixed `runId`. The descriptor
has exactly these fields:

```json
{
  "runId": "fixed-run-id",
  "serverName": "lemon-bot",
  "serverUrl": "https://bot.example/mcp",
  "headerName": "X-Lemon-Bot-Invocation",
  "secretName": "lemon_bot/invocations/fixed-run-id"
}
```

The actual admitted MCP server must match the name and URL and contain the exact
header value `${LEMON_SECRET:lemon_bot/invocations/fixed-run-id}`. The factory
stamps the private proof marker; booleans or model-provided attestations cannot
replace this binding. Context comparisons may mask only that exact attested
header **value**. They retain the server, URL, header name and every other
configuration field. The actual transport header is never removed: an active
same-context steer keeps its original proof, while each fresh native execution
attaches its own freshly provisioned proof and clients.

Queue merging and active-run controls require the same invocation/memory context,
effective tool policy and exact MCP configuration. Explicit and missing context keys
differ; an absent MCP override is distinct from explicit `[]`. Cross-context
followup, steer, redirect, backlog-steer and interrupt requests become their own
ordinary queued run, with its own `targetRunId`, never text or cancellation
injected into another principal's execution. Matching legacy missing keys retain
the previous behavior when capabilities also match.

Native resume tokens and pending compaction history are bound to the effective
execution context. A mismatch, or an unproven keyed token, starts a separate
native journal without deleting the old one. The backend supplies only the
currently authorized transcript summary; another principal's old private journal
is not automatically replayed. Same-context history can resume, while each new
execution rebuilds its policy, clients and credential resolver.

Session and agent standing approvals are scoped by the invocation key, never
another principal's shared-session grant. Explicit workspace-admin global/node
grants remain separate administrative policy. Native memory recall/indexing uses
the verified memory identity and cannot fall back to unscoped private notes.
Changing either context key conflicts with an existing fixed `runId`.

Success includes `runId`, `sessionKey`, `state: "accepted"`, `effectiveMode`,
`targetRunId`, and `retrySafe: false`. Requested `queueMode` in the redacted
summary is not evidence of the effective action:

| Effective mode | Meaning and target |
| --- | --- |
| `new_run` | A new run was started; target is this run ID. |
| `queued` | Admitted behind other work; target is this run ID. |
| `merged` | A debounced followup joined another queued intent; target is the surviving run ID (the newest followup). Earlier receipts track subsequent merges. |
| `steer_pending`, `steer_backlog_pending`, `redirect_pending` | Dispatch to the actual active target was accepted by the router, not yet by its executor. |
| `steer`, `steer_backlog`, `redirect` | The actual target acknowledged the instruction. |
| `interrupt` | The replacement was queued and cancellation dispatched to the recorded active target; this is not proof that cancellation completed. |

Idle steering/redirect and idle interrupt start a `new_run`; image-bearing
steering falls back to its own queued/new run because steering is text-only.
Rejected steering updates the receipt to its actual queued/new/merged fallback.
An admission receipt is not a run completion result.

After a lost response, read `runs.receipt.get` (`read` scope) with `{"runId": ID}`.
It returns `{"receipt": {...}}` with the same receipt fields. It also accepts
typed `includeAnswer: false` for uniform status-only clients; receipts never
include an answer, even when the boolean is true, and invalid flag types fail
before the receipt query. It does not read private run history. An ambiguous
admission fence returns `state: "outcome_unknown"` with nullable `sessionKey`,
`effectiveMode` and `targetRunId`. Missing IDs return `NOT_FOUND`; query failures
remain `UNAVAILABLE`, not missing or idle. Use `agent.wait` for final answer,
success/error and explicit `cancelled` proof, following `targetRunId` for merged
or steered work. `includeAnswer: false` provides status-only completion: `answer`
is null, answer-derived byte counts are zero, and usage/budget are omitted.
The original initiator can keep the default full-answer projection; a credential
revocation manager need not fetch another principal's answer to inspect terminal
status. Malformed nonboolean flags are rejected rather than returning an answer.
`SUBMISSION_OUTCOME_UNKNOWN` errors retain the original `runId` and `sessionKey`
with `retrySafe: false`; reconcile that ID, never fabricate another send.
A known start rejection remains a known error when matching terminal evidence
has already been durably recorded. That fixed-ID fence is retained; replaying
the same intent cannot start a second run.
Receipt management views contain only IDs, status and dispositions. Owner rows
also retain private content-free scope/fingerprint and terminal evidence, never
prompt content or plaintext lineage handles.

For `interrupt`, await completion under the submitted `runId`, not the old
cancellation target. Re-read pending steering receipts before choosing a
completion target: a rejected instruction can become its own queued run.

### Native follow-up proof renewal

In-process native children inside the still-active original invocation may
inherit its exact authority and clients. A fresh routed task or delegated-agent
follow-up is a distinct fixed-ID execution, never a way to replay
the completed root's proof or attach ambient profile credentials.
The native caller allocates that ID before submitting to admission or invoking
the proof issuer. Admission compaction retains the sealed current target,
destination and policy binding, so acceptance cannot drop the startup or queued
activation fences.

Provision the backend-owned issuer using admin `profile.followup.admission.set`
with exactly `profileId`, `url` and `token`. Success is
`{"profileId": "...", "configured": true}`. The encrypted token and private URL
are not returned by profile get/list/roster or history. Configure exact permitted
origins through `LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS`, or
`:lemon_router, :native_followup_allowed_origins`. HTTPS is required except
explicitly allowlisted HTTP on literal loopback IPs; userinfo, query strings,
fragments, redirects and automatic retries are not allowed.

The existing **current target profile's `mcpServers`** is the operator-authored
identity/origin/tool ceiling. For managed contexts, register credential-free
templates with `headers: {}`: current Core/connector name and URL, allowed origins,
explicit private-origin approvals and optional enabled-tool limits. Never put
an owner's account credentials in these templates. They are not execution
defaults: every managed initial run, task, SideQuery and fresh follow-up must
supply the exact complete per-principal MCP replacement, including `[]` when no
connections are authorized. Missing replacement must not inherit the templates,
ambient profile headers or cached OAuth clients.

The native owner records actual root/parent provenance before dispatch and
hands its factory a private, run-bound continuing-lineage handle. Only its hash
is durable; raw handles do not enter management/history/provider projections.
Remote renewal requests must come from the actual authenticated source node and
current session generation, not a body claiming an actor or ancestor.

Only the actual executing-root factory receipts its immutable native policy
floor before MCP clients, bootstrap, session/model or tools start. In-process
children cannot reseal that root with a narrower child/persona floor. Fresh
renewal refuses an unverified source floor; destination-local configuration is
not approximated from a controller or model-supplied policy.
An explicitly empty proofless managed root has no continuing-lineage handle:
its startup floor receipt is bound to its actual sealed root ID and authenticated
destination, and cannot create later follow-up authority.

The node-only conduits are `node.native.lineage.floor`
(`sourceRunId`, `toolPolicy`, optional `lineageHandle`) and `node.native.followup`
(`sourceRunId`, `lineageHandle`, `request`). A request contains fixed `runId`,
`prompt` and optional `agentId`, `sessionKey`, `images`, `model`, `cwd`,
`toolPolicy`, `meta`; there is no queue/resume, actor/audience or body-provided
node/generation selector. Private metadata is discarded and owner-derived.
The floor acknowledgement is `{}`; admitted follow-up acknowledgement is
`{"runId": "F"}`. Neither response returns the private handle. Their native
payload bound is 16 MiB with strict JSON validation; ordinary RPC bounds remain
unchanged.

Before contacting the issuer, the owner reserves and flushes fixed follow-up
`F`, its verified source lineage and the exact current destination. The callback
sends only `{"runId": "F"}` with the private per-profile bearer. The backend must
read admin `runs.followup.lineage.get` with exactly that ID. During the pending
callback it returns the retained `sourceRootRunId`, `parentRunId`, `sourceProfileId`,
`sourceSessionKey`, `sourceInvocationContextKey`, `sourceMemoryContextKey`,
`sourceRestrictiveToolPolicy`, and the actual `targetProfileId`, `targetAgentId`,
`targetSessionKey`, `targetNodeId`, plus `runId`. There is no parent selector,
answer, prompt, token, MCP header or process identifier in this projection.

The issuer derives the actual root actor/private audience from retained owned
records, checks current membership and source/target policy/connector fences,
and provisions a new destination proof bound to `F`. An approving HTTP 200
response is exactly:

```json
{
  "allow": true,
  "invocation": {
    "invocationContextKey": "current-principal-policy-connectors-digest",
    "memoryContextKey": "authorized-stable-private-audience-digest",
    "invocationToolPolicy": {"allow": ["read"]},
    "invocationMcpServers": [{
      "name": "lemon-bot",
      "url": "https://bot.example/mcp",
      "allowedOrigins": ["https://bot.example"],
      "approvedPrivateOrigins": [],
      "headers": {
        "X-Lemon-Bot-Invocation": "${LEMON_SECRET:lemon_bot/invocations/F}"
      }
    }],
    "invocationProof": {
      "runId": "F",
      "serverName": "lemon-bot",
      "serverUrl": "https://bot.example/mcp",
      "headerName": "X-Lemon-Bot-Invocation",
      "secretName": "lemon_bot/invocations/F"
    },
    "sharedMemoryGrant": false
  }
}
```

Refusal is exactly `{"allow": false}`. Response authority flags and principal
claims are not accepted. The owner validates the fixed proof, intersects actual
source/request/current target and issuer policy, and validates the currently
authorized target BaseCore/connector MCP transport against the **current target's
current operator-authored `mcpServers`**, using canonical origin and destination-secret
rules. Response servers must match canonical template name/URL and may only
narrow origin, private-origin and enabled-tool sets. Their own allowlists do not
create operator consent. New keys/transports may legitimately change with target
or current epochs; original keys authenticate retained lineage, not stale
credentials. Configuration changes fence prepared and queued executions before
private dispatch. Arbitrary callback transports, permission widening and
owner/default credentials are not accepted. It rechecks exact destination identity,
connection and privacy capability before dispatch. Fresh `F` uses independent
collect admission, with truthful `new_run`/`queued` receipt targeting `F`.
Known rejection retains fixed-ID terminal evidence; unavailable or ambiguous
outcomes never manufacture a new ID, retry the callback or redispatch.

Context-owned remote execution requires the **current authenticated worker's**
`capabilities["coding_agent.run"]["nativePrivacyContext"] = {"version": 1}`.
Generic coding-agent version 1 and stale durable capability rows are not proof.
Private execution and proof provisioning bind the inspected durable node ID,
current connection PID and session generation atomically; unsupported, stale or
unavailable destinations fail before enqueueing the private payload.

### Complete profile-idle proof

`runs.active.list` accepts `profileId`, `agentId`, `sessionKey` and display
`limit`. Its existing `runs` array remains active entries; `presence` contains
`active`, `queued`, `unknown`, `idle`, and `complete: true`. Counts are computed
**before** the display limit. Idle means all three counts are zero with every
read successful, not merely an empty active array.

Presence combines live native owners, coordinator queues/pending controls,
durable admission/receipt uncertainty and retained terminal evidence. It uses
actual executed profile/agent identity and verified source-profile dependencies;
it never invents a profile from an arbitrary session-key string. Unattributed
legacy or timed-out metadata candidates remain fixed-ID unknown work, not idle.
Completed rows remain terminal through history pruning. Controller/registry/store
failure or a racing durable snapshot returns `UNAVAILABLE`; a valid available
empty registry returns genuine idle proof.
A source-profile query can therefore return a run whose actual `profileId` is
another dependent execution profile; the authoritative `presence` counts, not
that display array, determine whether the source resource is idle.

### Placement-aware sessions and routines

`chat.send` accepts `profileId` alongside `sessionKey` and `prompt`. This uses
the profile's persona, model, workspace and node for a non-canonical session,
such as `agent:research:task-123`, `agent:research:dm-alice`, or
`agent:research:group-team`. The profile owns placement; the session key owns
conversation history. Omit `profileId` to retain ordinary chat routing.

For per-invocation principal isolation, `chat.send` also accepts
`invocationMcpServers` with `profileId`. Omission inherits the profile's
connectors, `[]` attaches none, and a supplied list completely replaces them
for that run. Neither headers nor owner connector definitions are merged.

`cron.add` accepts `profileId` for agent jobs. `cron.list` includes the stored
`profileId`; each run fetches the current profile, so moving or editing a bot
changes its future scheduled runs without recreating its routines. Shell jobs
remain scheduler-local and do not accept profile placement.

### Update and attach MCP tools

`profiles.update` accepts `id` and any of `name`, `description`, `avatar`,
`model`, `systemPrompt`, `node`, `mcpServers`, or `toolPolicy`. Omitted fields stay unchanged;
an empty optional text field clears it. Use `node: "local"` to return a profile
to the controller, and `mcpServers: []` to remove its session connectors.
Names support 120 Unicode scalar values (512-byte defensive UTF-8 ceiling).
System prompts preserve exact UTF-8, including surrounding whitespace, through
128 KiB. Chat prompts and each persona instruction file have independent
64 KiB limits. Oversize/invalid UTF-8/NUL input is rejected, not truncated.

`toolPolicy` uses the native policy shape: optional preset `profile`, `allow`
(`"all"` or exact registry-name array), `deny`, `blocked_tools`,
`require_approval`, `approvals` (tool name to `"always"`/`"never"`), and
`no_reply`. Each list/map supports up to 16,384 tool names of at most 256 bytes.
`allow: []` denies all; `{}` clears the persisted profile floor. Fresh
canonical, task, DM, group and cron runs inherit this floor and intersect it
with session/destination policy. Allow sets intersect, denies and required
approvals union, `"always"` dominates `"never"` and `no_reply` ORs.
`chat.send.invocationToolPolicy` requires `profileId` and can only restrict
this floor; omission or `{}` adds no restriction. Denied tools stay denied
even if an invocation declares `"all"` or `"never"` approval. Active sessions
retain startup policy, so grant-revoking applications must fence admission and
settle active cancellation before reporting a restrictive change as applied.

```json
{
  "id": "research",
  "node": "worker-1",
  "systemPrompt": "Research carefully and cite your sources.",
  "mcpServers": [{
    "name": "lemon-bot",
    "url": "https://bot.example/mcp",
    "headers": {"Authorization": "${LEMON_SECRET:lemon-bot/research/authorization}"},
    "enabledTools": ["send_message", "create_draft"],
    "allowedOrigins": ["https://bot.example"],
    "approvedPrivateOrigins": []
  }]
}
```

The same `mcpServers` field is accepted by `profiles.create` and cloned with the
profile. Servers use Streamable HTTP; names must be unique, URLs HTTP(S), and
headers a JSON object of string name/value pairs. Definitions are bounded to
32 servers and 64 KiB total. Connections are owner-bound and released when the
run ends. Connection failures fail the run rather than silently dropping tools.
Profile executions never inherit ambient machine-global MCP connections,
including an explicit empty per-call list. Generic non-profile/ACP behavior
is unchanged.

`enabledTools` is an exact allowlist of raw remote tool names, with at most
256 unique names of 128 bytes each. There is no wildcard expansion. Omission
allows all tools; `[]` disables all tools. An explicit allowlist does not grant
resource/prompt utility tools. Restrictions apply to both model exposure and
actual MCP invocation, including after registry refresh.

Product connectors must set `allowedOrigins` to the exact approved HTTP(S)
origin and set `approvedPrivateOrigins` only for explicit private-network
consent. The worker validates all A/AAAA answers and pins the real HTTP/TLS
connection before reading header secrets; redirects are rejected and the
original origin remains the Host/TLS verification identity. Policy omission
retains existing operator-trusted networking, not a product security guarantee.

Header values may contain the explicit reference `${LEMON_SECRET:NAME}`.
Write the complete header value into the encrypted secret store on the bot's
machine (for example, using `node.secrets.set`), then configure that reference.
Literal prefixes/suffixes are supported, such as `Bearer ${LEMON_SECRET:api-token}`.
Only the executing host resolves references, immediately before attaching MCP
clients; the controller forwards reference text unchanged. There is no
environment or external-source fallback, and `${ENV_VAR}` is not expanded.
Missing secrets, decryption failures, malformed references and invalid resolved
headers fail attachment before any client starts. The reported failure is the
static `secret_resolution_failed` classification, never a secret value or name.

MCP headers are secrets: all management reads and lifecycle responses omit the
`headers` field entirely. Authenticated operators set or replace headers with
the full server definition; returned rows are not a credential backup. Headers
are stored in the private profile configuration and travel to a named worker
only in that profile's execution request, not in run history or public events.
Do not share private config files. Credential-safe exports omit these headers.
Management rows include `mcpConfigFingerprint`, a credential-free SHA-256
binding of ordered complete private server definitions. This permits
lost-update reconciliation without returning headers; optional-field omission
differs from an explicit empty list. The exact compact-JSON algorithm is in
the [control-plane method documentation](../../apps/lemon_control_plane/README.md).

### Discover on the bot's machine

Before a profile exists, use the pure operator-read method
`mcp.execution_names {server:{name,url},toolNames:[rawName]}` to build its
closed tool allowlist. It returns
`{server:{name},tools:[{name,executionName}],count}` using the same native alias
owner as actual execution. Only public identity is accepted: no credentials,
profile/node lookup, DNS or HTTP initialization. At most 256 names are accepted.
This computes identity only, not tool existence, availability or permission;
use destination discovery for the live inventory.

`node.mcp.discover {nodeId,server}` (`admin`, asynchronous) accepts the same
server shape. It connects only on the selected execution node, using temporary
owner-bound MCP clients with no executable tools installed. Discovery returns
the full raw inventory regardless of `enabledTools`, so applications can offer
new tools without granting them.

The result is `{connected:true,server:{name,status:"connected"},tools,count,truncated}`.
Each tool has `{name,executionName,description,inputSchema,readOnly}`. Tool names, descriptions
and complete schemas are bounded; oversized or credential-bearing schemas are
omitted rather than modified. `readOnly` is only an advisory server annotation
and defaults false. Failure responses never return header values or resolver
secret names. Connections close after discovery or when its owner disconnects.
`executionName` is the actual native tool-policy alias. Profile HTTP aliases
derive from public server name/canonical URL/raw tool name, not credentials or
resolved addresses, and remain stable across secret rotation and DNS pinning.
Use the returned value, not a guessed prefix. These clients obey native policy
denial and required approvals without an extra unconditional MCP approval
prompt. Read-only hints are not permission grants. Legacy global/ACP aliases
and approval behavior stay unchanged.

### Provision before moving

`profiles.sync {id,[nodeId,mutationId]}` (`admin`, asynchronous) provisions
controller-owned persona files on a destination without changing controller
placement. Supply the durable target `nodeId` before a move; otherwise the
current remote placement is used. Local profiles require an explicit target.

The destination creates safe profile boundaries, preserves local config,
credentials, USER.md, memory and skills, and commits/rereads the persona
revision before returning `{profileId,nodeId,mutationId,acknowledged:true,revisionDigest}`.
Only `AGENTS.md`, `IDENTITY.md`, `README.md`, and `SOUL.md` are synchronized.
MCP credentials are never provisioned by sync.

An optional mutation ID binds its revision and is durably reserved before
persona writes. The destination retains only the latest non-null mutation/digest
pair, not an unlimited mutation history. Reuse with changed content conflicts;
missing IDs return null and preserve the retained binding.
`profiles.sync.status {id,nodeId,mutationId}` (`read`, asynchronous) queries the
actual destination without resending persona or writing storage. It returns
`{profileId,nodeId,mutationId,status,acknowledged,revisionDigest}`:
`"acknowledged"` verifies the exact retained binding and files, `"pending"`
matches a reserved unfinished write, and `"unknown"` has a null digest for
absent, superseded or source-revision-mismatched bindings. Unavailable
transport/corrupt storage is an RPC error, not unknown. Explicit `nodeId`
uses durable ID-only dispatch even offline, never a same-named node.
Implicit sync first selects an exact stored durable ID, including an offline
record, so another node named that ID cannot receive its private persona.
Only when no ID record exists does it resolve the configured legacy name.

Coordinate destination memory/skill transfer through their owning services,
then switch `profiles.update.node` only after the required acknowledgements.
For selected profile skills, use
`node.profile.paths {nodeId,profileId}` (`read`, asynchronous) to obtain the
destination-owned `{profileId,nodeId,workspacePath,skillsPath}`. It never
creates a profile or guesses from controller paths/default cwd. Provision
`skillsPath/<key>/SKILL.md` through owning filesystem stat/CAS operations.
The lookup does not grant filesystem roots; non-home custom state requires
the machine operator's explicit `--allowed-root` admission.



## Current boundaries

This vertical covers durable profiles, isolated assistant workspaces, lifecycle,
canonical and placement-aware extra sessions, profile-bound cron agent runs,
per-profile MCP tools, node routing, and a roster. Group-room orchestration,
import/restore, free-form prompt editing in browser/TUI surfaces, browser export,
and merged multi-controller rosters remain separate product work. The TUI and
Web lifecycle journeys remain unchanged.
