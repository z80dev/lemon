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
It returns `{"receipt": {...}}` with the same receipt fields. An ambiguous
admission fence returns `state: "outcome_unknown"` with nullable `sessionKey`,
`effectiveMode` and `targetRunId`. Missing IDs return `NOT_FOUND`; query failures
remain `UNAVAILABLE`, not missing or idle. Use `agent.wait` for final answer,
success/error and explicit `cancelled` proof, following `targetRunId` for merged
or steered work. `SUBMISSION_OUTCOME_UNKNOWN` errors retain the original `runId`
and `sessionKey` with `retrySafe: false`; reconcile that ID, never fabricate
another send. Receipts retain only IDs, private semantic hashes and dispositions,
never prompt content; semantic hashes do not cross the wire.

For `interrupt`, await completion under the submitted `runId`, not the old
cancellation target. Re-read pending steering receipts before choosing a
completion target: a rejected instruction can become its own queued run.

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
Ordinary configured profile placement remains name-first.

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
