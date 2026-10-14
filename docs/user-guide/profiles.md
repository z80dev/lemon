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
instructions (`AGENTS.md`, `IDENTITY.md`, `README.md`, `SOUL.md`, `USER.md`) as
JSON-safe text. These instructions overlay that run's destination-local
assistant workspace; no profile files need to be pre-installed on the worker.

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

`cron.add` accepts `profileId` for agent jobs. `cron.list` includes the stored
`profileId`; each run fetches the current profile, so moving or editing a bot
changes its future scheduled runs without recreating its routines. Shell jobs
remain scheduler-local and do not accept profile placement.

### Update and attach MCP tools

`profiles.update` accepts `id` and any of `name`, `description`, `avatar`,
`model`, `systemPrompt`, `node`, or `mcpServers`. Omitted fields stay unchanged;
an empty optional text field clears it. Use `node: "local"` to return a profile
to the controller, and `mcpServers: []` to remove its session connectors.

```json
{
  "id": "research",
  "node": "worker-1",
  "systemPrompt": "Research carefully and cite your sources.",
  "mcpServers": [{
    "name": "lemon-bot",
    "url": "https://bot.example/mcp",
    "headers": {"Authorization": "${LEMON_SECRET:lemon-bot/research/authorization}"}
  }]
}
```

The same `mcpServers` field is accepted by `profiles.create` and cloned with the
profile. Servers use Streamable HTTP; names must be unique, URLs HTTP(S), and
headers a JSON object of string name/value pairs. Definitions are bounded to
32 servers and 64 KiB total. Connections are owner-bound and released when the
run ends. Connection failures fail the run rather than silently dropping tools.

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


## Current boundaries

This vertical covers durable profiles, isolated assistant workspaces, lifecycle,
canonical and placement-aware extra sessions, profile-bound cron agent runs,
per-profile MCP tools, node routing, and a roster. Group-room orchestration,
import/restore, free-form prompt editing in browser/TUI surfaces, browser export,
and merged multi-controller rosters remain separate product work. The TUI and
Web lifecycle journeys remain unchanged.
