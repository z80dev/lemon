# Memory User Guide

Lemon has two memory concepts:

- **Remember** compact personal preferences and repository-specific learnings with
  `remember`. Context-owned Bot sessions keep these in the existing durable store.
- **Recall** relevant past conversations and longer notes using `recall`. Lemon can also add a
  bounded **Relevant memory** block to each user message automatically.

In legacy unscoped operator/CLI sessions, `USER.md` and `MEMORY.md` remain bootstrap
files and `recall` can search `memory/`. Context-owned Bot sessions instead use
verified private actor partitions plus explicitly authorized shared facts. They
never infer sharing authority from old files or unproven run metadata.


### Browse and scroll conversations

Call `recall` with no query to browse recent sessions (first prompt, timestamp,
and run count). Search hits include session key, document ID, and run ID. Pass
`session` back to `recall` to read its latest run summaries, or add `around`
with a document/run ID to center the window there. `window` defaults to 5 and
is capped at 20. Runs are returned chronologically; an unknown anchor returns
no runs. These are finalized-run summaries, not full transcripts.

Browse and scroll use the same owner, agent, and assistant-profile boundary as
search, refuse subagents, and require `[features] session_search`. Session keys
identify only visible sessions and do not grant access to another owner's data.
Each returned prompt/answer is byte-bounded; recalled content remains untrusted
data, never instructions.
---

## Remember compact facts

Personal targets never write into the active project. Legacy unscoped sessions
update assistant-home files; verified context-owned sessions use canonical facts
in the existing durable memory database, without modifying those files:

| Target | Owning location | Limit | Purpose |
|---|---|---:|---|
| `user` | Canonical scoped preferences; legacy `USER.md` only when unscoped | 1,375 chars | Stable human preferences |
| `memory` (default) | Canonical scoped preferences; legacy `MEMORY.md` only when unscoped | 2,200 chars | Curated quick facts and links |
| `project` | Existing local memory database, repository + assistant home + agent + verified actor partition | 24 facts / 2,000 bytes total; 512 bytes per fact | Build/test commands, conventions and confirmed decisions |

The tool accepts `text`, `target` (`user`, `memory`, or `project`; default `memory`), and `replaces`.
Providing `text` adds a bullet; an existing duplicate is not added again. Providing both `text`
and `replaces` patches an exact entry or a unique substring (exact whole entries win).
Providing only `replaces` deletes the whole matched entry. Ambiguous matches require
longer unique text. Capacity errors show usage, attempted size, required space, and
current entries: remove or shorten entries before retrying. Content is screened for
common secrets, prompt injection, NUL bytes, and invisible/bidirectional controls;
refusals name the reason without repeating rejected content.

When adding a new fact, omit `replaces` or set it to JSON `null`—never use an
empty string or a placeholder. For deletion, omit `text` or set it to `null`.
Before correcting or deleting a project fact, use `recall` with `scope: "project"`
and relevant query keywords, then copy the exact saved fact into `replaces`.
A missing replacement target leaves memory unchanged; it never falls back to adding.

Only provenance-proven canonical **shared** preferences enter context-owned static
bootstrap as virtual `USER.md`/`MEMORY.md`. Private preferences and authorized
conversation/project facts are selected for bounded volatile recall instead.
Raw legacy files stay unchanged and require explicit owner review/import to become
shared; appending one shared fact never promotes the rest of a file. Legacy
unscoped sessions keep their previous file bootstrap behavior.
Save reusable procedures as skills rather than memory facts.

Prompt memory blocks report full store usage, for example
`USER PROFILE [62% — 860/1,375 chars]`, `MEMORY [67% — 1,474/2,200 chars]`,
and `PROJECT MEMORY [5/24 facts, 340/2,000 bytes]`. Above 80% of either
applicable limit, a line reminds the agent to consolidate before adding.
Scoped character counts exclude generated headings/bullets; legacy file counts
include the saved file's formatting. Excerpts remain bounded even when the
header reports the full store. Labels do not change stored notes or enter
subagent prompts.

### Repository learnings

Use `remember` with `{"target":"project","text":"Run targeted checks with scripts/test path."}`
for facts that must not follow you into other repositories. `replaces` updates or removes one
exact project fact. Explicit saves reject capacity overflow rather than silently evicting facts.

Completed native coding turns and compactions also extract durable project learnings in bounded
background jobs. This capture can use a model; it does not delay the main session, survive a
runtime kill by itself, or guarantee that every useful fact is retained. Use explicit `remember`
when saving a fact matters. Automatic capture deduplicates and retains the newest facts within
the same hard storage limit. It omits secrets, raw transcripts and transient TODOs.

Context-owned capture always stays in the actor's private partition, even when
the current maintainer has explicitly authorized a separate shared save. Only
an admitted trusted runtime grant can authorize `remember` to write shared facts;
model/tool arguments such as `sharedMemoryGrant` cannot grant that authority.
Changing invocation/policy epochs does not change the durable actor identity.
Private Bot+user preferences may span owned DMs/tasks/routines, while a shared
room uses a distinct actor+conversation+audience partition.

Sessions in subdirectories of the same repository share the nearest `.git` root. Outside a
repository, only the same working directory shares project facts. Different assistant profiles
or agent identities remain isolated even when they work in the same repository. Subagents
cannot read or write personal or project memory through these tools.

---

## Recall conversations and notes

The read-only `recall` tool searches these sources:

1. Conversation summaries with the exact profile/home and verified actor key.
2. With `scope: "project"`, authorized compact project learnings and that repository's history.
3. With `scope: "agent"`, canonical private and proven shared preferences.

Context-owned recall excludes other actors' valid IDs, unproven/legacy summaries,
and raw `USER.md`, `MEMORY.md`, or `memory/` files. A legacy unscoped session retains
its previous note-folder search, with personal bootstrap files already in its
system prompt. Call `recall` with a non-empty `query`; `scope` defaults to `agent`
or can be `project`, and `limit` is 1–10 (default 5). Project scope searches only
the current repository. For prior work, for example “What did I use to deploy
that app last week?”, use `recall` when the answer is not already in context.

Conversation search uses OR/BM25 lexical matching: results may match any query term, and are
ranked for relevance. Paraphrases that share a keyword can therefore match even when they do not
share the full query wording. This is lexical search, not semantic search.

The old `session_search` scroll/browse interface for inspecting a session's message history has
been removed and has no replacement. The `[features] session_search` setting remains the durable
memory ingest/search kill switch; setting it to `"off"` disables those features.

### Automatic recall

Automatic recall is enabled by default. Before a meaningful turn, Lemon searches local
conversation history scoped to the session's agent/profile and attaches a **Relevant memory**
block to the user message after the cache breakpoint, never inside the static system prefix.
It prioritizes compact project learnings, followed by the top three matching conversations
(up to five for embedders) and authorized preference facts. In context-owned
sessions these are canonical private/shared facts, never an unproven raw-file
excerpt. Project learnings need not repeat the opening query's keywords.
The combined block, including its title, is at most 2,048 bytes. Short queries, subagents, and
sessions without a complete agent/assistant-home scope are skipped. Missing profile files never
fall back to another profile's workspace. Historical documents without a verified assistant-home
identity are excluded rather than guessed into a profile.
Historical outcomes must match at least two meaningful query terms and at least half of
the query's meaningful terms, in the same repository. Generic output instructions do not
count as relevance. Old user prompts are never injected: matching assistant outcomes are
clearly marked as background, not instructions to follow or echo. Use explicit `recall`
when a broader search across the same agent/profile is intentional.

Disable automatic recall in configuration:

```toml
[memory]
auto_recall = false
```

Automatic recall is also disabled when `[features] session_search = "off"`, which additionally
disables automatic project capture. `[memory] auto_recall = false` disables injection only.
Automatic recall performs no LLM pass or network request: it uses local database reads and
lexical search. Background fact extraction is separate from this latency-sensitive recall path.
It uses the same resolved summary model as compaction, including a configured `@smol`
role, with that provider's credentials; it does not switch the active session model.

---

## Which persistence surface should agents use?

| Need | Use | Why |
|---|---|---|
| Save a stable profile fact or compact context | `remember` | Updates bounded assistant-home `USER.md` or `MEMORY.md` |
| Save repository build commands, conventions or gotchas | `remember` target `project` | Isolated compact facts, automatically available in later sessions in the same repository/profile |
| Find relevant previous conversations and longer workspace notes | `recall` | Searches past conversation summaries and `memory/` Markdown notes |
| Capture a repeatable procedure, command sequence, integration, or checklist | `skill_manage` | Creates or updates an audited reusable skill |
| Track the current run's work queue | `todo` | Keeps progress in this session's history only; it follows rewind, branch switches, resume and forks, and never leaves the session |
| Inspect user-editable notes directly | `read` / `grep` | Opens files when direct inspection or editing is needed |

Use `remember` for concise facts, `recall` for finding prior work, `skill_manage` for repeatable
procedures, and `todo` for active work only.

Bare `USER.md`, `MEMORY.md`, and `memory/...` paths resolve to assistant home for file tools when
a session has `workspace_dir`; prefix with `./` to access a repo-local file with the same name.

---

## Memory management

### Profile-scoped operator API

External applications can use the authenticated control-plane `memory.list`,
`memory.search`, `memory.get`, `memory.add` and `memory.delete` methods. Supply a
managed `profileId`, not a filesystem path. A profile placed on a named machine
reads and changes memory on that destination; an offline machine never falls
back to the controller's memory.

Reads require `operator.read`, while add/delete require `operator.admin`.
Product backends must always select `{memoryScope: "private", memoryContextKey}`
using their verified stable Bot+actor key, or `{memoryScope: "shared"}` for proven
shared facts. Every scoped success echoes the exact selector (shared key is null);
the backend checks that echo and strips internal keys before returning UI/model
results. Exact IDs and confirmations do not bypass private ownership checks.
Only trusted non-product operator requests may omit both selectors to inspect
legacy retained files and all profile-owned records. Partial selectors fail.
Results expose only id, kind, redacted text preview (at most 2 KiB), source and
creation/update timestamps, plus the internal top-level scope echo.

For example, after connecting an operator client:

```json
{"type":"req","id":"remember-1","method":"memory.add","params":{"profileId":"researcher","memoryScope":"private","memoryContextKey":"private_bot_v1.actor","text":"Prefers concise summaries","kind":"user"}}
{"type":"req","id":"memory-1","method":"memory.list","params":{"profileId":"researcher","memoryScope":"private","memoryContextKey":"private_bot_v1.actor","limit":25}}
```

Adding uses the same owning safety/compactness rules as `remember`; scoped writes
create canonical facts, not shared files. The default is `kind: "memory"`; `"user"`
is a human preference. To delete, send `{profileId, id, confirm: id}` **with the same
scope selectors** after reviewing the returned item.
Confirmation must repeat the exact id, not `true`. Changed or foreign items do
not authorize deletion. A remote mutation whose acknowledgement is lost returns
`retrySafe: false`; inspect current memory before retrying.

List pagination is bounded and snapshot-bound: use `nextCursor` as `cursor` in
`memory.list` with the same profile/query/scope, and restart if memory changed.
Managed queries accept at most 512 Unicode codepoints / 2,048 UTF-8 bytes.
Scoped querying uses the owning index and full accepted preference facts, not
only the newest summaries or clipped previews. A legitimate match may not contain
the query in its redacted preview; clients must preserve that native match.
See the [control-plane method contract](../../apps/lemon_control_plane/README.md#profile-memory)
for exact parameters, result shapes, limits, and node invocation behavior.

### Moving memory to another attached machine

The admin-only `memory.transfer` control-plane method copies full scoped memory
before a profile's machine placement changes. Supply the managed `profileId`,
the destination's durable `nodeId`, and a fresh `mutationId` for that move.
The source remains untouched and placement is **not** switched by the transfer.

The default apply is create-only. If the destination already has selected
profile memory, request `action: "preview"`. The result shows source/destination
document and preference-file counts, snapshot digests, and an opaque confirmation
token—not sensitive text. Explain exactly which destination memory will be
replaced and collect explicit approval. Apply the same mutation with its exact
`snapshotDigest`, `destinationDigest`, and `confirmationToken`; changed source
or destination memory invalidates that plan.

This transfers profile-owned run/project records, canonical private/shared preference
facts with actor ownership intact, and retained `USER.md`/`MEMORY.md` bytes.
Unknown legacy files or pre-index proof claims remain unproven after copying:
transfer does not authorize sharing. No transcripts, secrets, cookies, daily notes
or arbitrary files are copied, and no truncated UI preview is used.
Oversized or unsafe source data is rejected rather than partially copied. Other source repository
groups keep opaque identities: their facts remain available as profile memory,
but a new destination repository cannot be inferred from the old filesystem.

All transfer worker operations require fresh provenance-aware capability
advertisements and exact checked connection binding. An old/downgraded worker
is unavailable rather than silently turning private ownership into legacy data.

Wait for the destination's durable `copied: true` receipt before changing the
profile's machine. Preserve the mutation ID if the outcome is unknown and query
the read-only `memory.transfer.status` method with `{profileId, nodeId, mutationId}`.
It never starts or replays a copy, including when the controller has no intent.
Only `status: "completed"` with the exact durable receipt acknowledges the copy;
`pending`, `unknown`, or an unavailable query must retain the old placement.
See [the transfer contract](../../apps/lemon_control_plane/README.md#copying-scoped-memory-before-moving-a-profile)
for exact preview/confirmation fields and bounds.

### Retention and pruning

Indexed run/conversation history is pruned using the configured retention window
(default **30 days**) and history scope cap (default **500**). Canonical user/memory
preferences and project facts are protected from ordinary history age/per-session
pruning; explicit scoped lifecycle deletion still applies. Existing data is not
rewritten or purged merely by migrating ownership columns.

```elixir
config :lemon_memory, LemonMemory.Store,
  path: "~/.lemon/store",
  retention_ms: 30 * 24 * 60 * 60 * 1000,
  max_per_scope: 500
```

Manual maintenance commands:

```bash
mix lemon.memory stats
mix lemon.memory prune
mix lemon.memory erase --scope <session|agent|workspace> --key <value>
```

### Storage locations

| Scope | Database location |
|---|---|
| Default local provider | `~/.lemon/store/memory.sqlite3` |
| Custom store directory | `<LEMON_STORE_PATH>/memory.sqlite3` |
| Explicit primary SQLite file | `memory.sqlite3` beside the file named by `LEMON_STORE_PATH` |

### Privacy and secrets

Before a run is stored as a memory document, `LemonMemory.Safety` scans summaries for credential
key-value pairs, API key patterns, AWS access keys, PEM private-key headers, and JWT-like tokens.
The policy is **drop, not redact**: if a pattern matches, the entire run is not recorded.
New summary indexes also omit runtime MCP/server/header/token configurations and
ephemeral invocation-proof artifacts. Run admission and dedicated credential
services remain authoritative; memory is a bounded summary projection, not a
second credential store.

Automatic native skill synthesis never turns private/unproven memory into
profile-wide or global draft files, even if a run could explicitly save a shared
preference. Legacy non-product synthesis and provenance-proven shared sources
retain their previous eligibility. Product-private Experiences use their existing
owning approval/persistence path rather than a new private skill store.

Support bundles include `memory_diagnostics.json`. It reports provider count,
enabled provider count, provider ids, sources, scopes, timeout shape, and module
load state. It does not include memory document contents, raw provider config,
secret values, prompts, tool output, or provider error payloads.

### Feature flag

```toml
[features]
session_search = "default-on"
```

The `session_search` feature flag gates durable memory ingest and search, including automatic
recall. Set it to `"off"` or use `LEMON_FEATURE_SESSION_SEARCH=off` to disable them.

---

## Routing feedback and skill synthesis

Each completed run can also record routing feedback used by adaptive routing. When
`skill_synthesis_drafts` is enabled, Lemon can mine successful runs and generate draft skills.
See [`docs/user-guide/adaptive.md`](adaptive.md) and
[`docs/user-guide/skills.md`](skills.md#skill-drafts-synthesized-skills).
