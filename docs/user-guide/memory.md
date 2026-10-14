# Memory User Guide

Lemon has two memory concepts:

- **Remember** compact personal facts in assistant-home `USER.md` or `MEMORY.md`,
  or repository-specific coding learnings with `remember` target `project`.
- **Recall** relevant past conversations and longer notes using `recall`. Lemon can also add a
  bounded **Relevant memory** block to each user message automatically.

These surfaces complement each other: `USER.md` and `MEMORY.md` are bootstrap context,
while project learnings and relevant conversation summaries are bounded volatile context.
`recall` also searches longer notes under the workspace's `memory/` folder.

---

## Remember compact facts

The `remember` tool never writes into the active project. Personal targets update assistant-home
files; project learnings use the existing durable memory database:

| Target | File | Limit | Purpose |
|---|---|---:|---|
| `user` | `~/.lemon/agent/workspace/USER.md` | 1,375 chars | Stable facts and preferences about the human |
| `memory` (default) | `~/.lemon/agent/workspace/MEMORY.md` | 2,200 chars | Curated quick facts and links |
| `project` | Local memory database, isolated by repository + assistant home + agent | 24 facts / 2,000 bytes total; 512 bytes per fact | Build/test commands, conventions, gotchas, confirmed project decisions |

The tool accepts `text`, `target` (`user`, `memory`, or `project`; default `memory`), and `replaces`.
Providing `text` adds a bullet; an existing duplicate is not added again. Providing both `text`
and `replaces` replaces the unique exact passage. Providing only `replaces` removes that exact
passage. Writes that exceed the file limit, ambiguous or missing replacement text, and invalid
targets are rejected. Content is screened for common secrets, prompt-injection phrases, NUL bytes,
and invisible or bidirectional control characters.

When adding a new fact, omit `replaces` or set it to JSON `null`—never use an
empty string or a placeholder. For deletion, omit `text` or set it to `null`.
Before correcting or deleting a project fact, use `recall` with `scope: "project"`
and relevant query keywords, then copy the exact saved fact into `replaces`.
A missing replacement target leaves memory unchanged; it never falls back to adding.

These files are included in the main-session workspace bootstrap context. `USER.md` is for
stable human profile facts; `MEMORY.md` is for concise curated context. Save reusable procedures
as skills instead of memory facts.

### Repository learnings

Use `remember` with `{"target":"project","text":"Run targeted checks with scripts/test path."}`
for facts that must not follow you into other repositories. `replaces` updates or removes one
exact project fact. Explicit saves reject capacity overflow rather than silently evicting facts.

Completed native coding turns and compactions also extract durable project learnings in bounded
background jobs. This capture can use a model; it does not delay the main session, survive a
runtime kill by itself, or guarantee that every useful fact is retained. Use explicit `remember`
when saving a fact matters. Automatic capture deduplicates and retains the newest facts within
the same hard storage limit. It omits secrets, raw transcripts and transient TODOs.

Sessions in subdirectories of the same repository share the nearest `.git` root. Outside a
repository, only the same working directory shares project facts. Different assistant profiles
or agent identities remain isolated even when they work in the same repository. Subagents
cannot read or write personal or project memory through these tools.

---

## Recall conversations and notes

The read-only `recall` tool searches these sources:

1. Past conversation summaries belonging to the same agent and assistant profile.
2. With `scope: "project"`, compact project learnings and that repository's conversation history.
3. With `scope: "agent"`, Markdown notes under `<workspace_dir>/memory/` (except `TEMPLATE.md`).

`USER.md` and `MEMORY.md` are not searched because they are already in the system prompt. Call
`recall` with a non-empty `query`; `scope` is `agent` by default or `project`, and `limit` ranges
from 1 to 10 (default 5). Agent scope searches that agent/profile's conversation history;
project scope searches the current repository only. For questions about prior work, for example “What did I
use to deploy that app last week?”, use `recall` when the answer is not already in the supplied
context.

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
(up to five for embedders) and a bounded USER.md excerpt. Project learnings do not require the
opening question to repeat their keywords: a build command can help with a new feature request.
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
| Track the current run's work queue | `todo` | Keeps transient progress for this session only |
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
Lists and searches combine the profile's bounded durable memory window with its
assistant `USER.md`/`MEMORY.md` preferences. Both agent identity and assistant-home
identity must match for durable documents, so unrelated profiles and unscoped
legacy history are excluded. Results expose only item id, kind, redacted text
preview (at most 2 KiB), source label, and creation/update timestamps.

For example, after connecting an operator client:

```json
{"type":"req","id":"remember-1","method":"memory.add","params":{"profileId":"researcher","text":"Prefers concise summaries","kind":"user"}}
{"type":"req","id":"memory-1","method":"memory.list","params":{"profileId":"researcher","limit":25}}
```

Adding uses the same compact-file safety rules as `remember` and defaults to
`kind: "memory"`; `kind: "user"` saves a human preference. To remove a returned
item, call `memory.delete` with `{profileId, id, confirm: id}` after reviewing it.
Confirmation must repeat the exact id, not `true`. Changed or foreign items do
not authorize deletion. A remote mutation whose acknowledgement is lost returns
`retrySafe: false`; inspect current memory before retrying.

List pagination is bounded and snapshot-bound: use `nextCursor` as `cursor` in
`memory.list` with the same profile/query, and restart listing if memory changed.
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

This transfers profile-owned summary/project records and assistant `USER.md`/
`MEMORY.md`, not session transcripts, secrets, cookies, daily notes, or arbitrary
files. It does not rely on truncated/redacted UI previews. Oversized or unsafe
source data is rejected rather than partially copied. Other source repository
groups keep opaque identities: their facts remain available as profile memory,
but a new destination repository cannot be inferred from the old filesystem.

Wait for the destination's durable `copied: true` receipt before changing the
profile's machine. Preserve the mutation ID if the outcome is unknown and query
the read-only `memory.transfer.status` method with `{profileId, nodeId, mutationId}`.
It never starts or replays a copy, including when the controller has no intent.
Only `status: "completed"` with the exact durable receipt acknowledges the copy;
`pending`, `unknown`, or an unavailable query must retain the old placement.
See [the transfer contract](../../apps/lemon_control_plane/README.md#copying-scoped-memory-before-moving-a-profile)
for exact preview/confirmation fields and bounds.

### Retention and pruning

Memory documents older than the retention window are pruned automatically. Default retention is
**30 days**, with at most **500 documents per scope** (configurable through the
`LemonMemory.Store` application environment).

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
