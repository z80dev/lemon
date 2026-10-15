# LemonMemory

Durable memory for agents: what an agent did, written down and searchable later.

`lemon_memory` is one of the packages that make up the [Lemon](https://github.com/z80dev/lemon)
agent platform. It is usable on its own — its only Lemon dependency is
`lemon_core`.

## What is in it

| Module | Purpose |
|---|---|
| `LemonMemory.Document` | The record every provider reads and writes: content, scope, metadata, timestamps |
| `LemonMemory.Store` | SQLite-backed store with OR/BM25 lexical search; the built-in durable backend |
| `LemonMemory.Query` | Builds sanitized OR-joined FTS5 search terms |
| `LemonMemory.Recall` | Bounded local lexical search used for automatic conversation recall |
| `LemonMemory.Project` | Bounded repository/assistant-home/agent-scoped coding learnings in the same durable store |
| `LemonMemory.ContextScope` | Admitted native ownership proof and explicit private/shared management selectors |
| `LemonMemory.Preferences` | Full-byte private or intentionally shared user/memory notes in the existing Store |
| `LemonMemory.Providers` | Fan-out registry — queries every registered provider, isolates failures and timeouts |
| `LemonMemory.Providers.Local` | The built-in provider over `LemonMemory.Store` |
| `LemonMemory.Ingest` | Writes finished runs into memory, invoked from the store's finalize-run hook |
| `LemonMemory.Safety` | Redaction and size limits applied before anything is persisted |
| `LemonMemory.Lifecycle` | Bounded/redacted browse, provenance inspection, and exact revision-bound delete for operator clients |
| `LemonMemory.SessionSearch` | Session-scoped conversation search API used by `recall` |
| `LemonMemory.TaskFingerprint` | Stable fingerprints for recognising repeated work |
| `LemonMemory.Doctor.Checks.Memory` | `lemon doctor` check of `session_search` against store health; registered via `config :lemon_core, :doctor_checks` |

Explicit review/confirm workflows can use `LemonMemory.Store.put_sync/1` when
they must not report success before SQLite accepts a document, or
`put_new_sync/1` for an atomic create-if-absent boundary that never overwrites
an exact document ID. `get_document/1` and `delete_document/1` inspect and
remove one exact record; deletion removes its FTS row in the same SQLite
transaction. Ordinary run ingest remains asynchronous.
`LemonMemory.Safety.redact/1` removes common secret-shaped values before a
caller builds the bounded document summary.

Authenticated operator surfaces use `LemonMemory.Lifecycle`, not raw Store
rows. It lists or searches at most 50 results from a bounded recent window,
filters by scope, safe agent label, one-way workspace digest, and memory kind,
and displays only Safety-redacted summaries plus digest-only learned-source
provenance. Deletion is non-mutating until previewed and re-confirmed with the
exact fresh digest. `Store.delete_document_if_unchanged/3` performs the final
constant-time revision comparison and removes both the SQLite row and FTS row
inside one transaction.

### Profile-scoped operator memory

`Lifecycle.profile_list(context, query \\ "", opts \\ [])`,
`profile_search(context, query, opts \\ [])`, `profile_get(context, id, opts \\ [])`,
`profile_preview_delete(context, id, opts \\ [])`, and
`profile_delete(context, id, confirmation_digest, opts \\ [])` provide the
profile-specific lifecycle. The context must have `session_scope: :main`,
`agent_id`, `workspace_dir` (the assistant home), and `cwd`. Every record must
match **both** the agent ID and the exact expanded assistant-home digest.
`:memory_scope` selects `{:private, key}`, `:shared`, or `:operator` (the default
unrestricted trusted-operator view). Private selectors include only verified
records with that exact key; shared selectors include only explicitly verified
shared records, never unknown legacy rows. Selection is enforced on list,
search, get, preview, and delete, even with a valid foreign wire ID.
`:server` selects an isolated Store instance.

Browse reads at most 200 recent eligible records. For explicit private/shared
selectors, `profile_search/3` queries the full owned lexical index before its
200-candidate limit, plus a bounded complete preference scan to match text beyond
the index preview. It includes project facts, never foreign/shared/legacy rows
in a private selection. The operator search retains its existing recent-window
behavior. Private/shared ownership is applied in SQLite **before** limits.
Results are `{:ok, %{items: items, revision: revision}}`.
Each item contains only string keys `id`, `kind`, `text`, `source`,
`createdAtMs`, and `updatedAtMs`. Source is `"durable"`; kinds are `"run"`,
`"learned_source"`, `"project_learning"`, `"user"`, or `"memory"`.
Text is operator-redacted, valid UTF-8, and at most 2048 bytes. Failed-run details
are withheld. The browse revision is internal pagination state, not display
data.

Managed queries accept at most 512 Unicode codepoints and 2048 UTF-8 bytes, with
no NUL or invalid UTF-8. `Lifecycle.valid_profile_query?/1` is the shared pure
validator; empty queries remain valid for browsing. Generic `Lifecycle.list/2`
keeps its 256-byte query limit. Validation does not rewrite accepted queries.

IDs are opaque and bind the record revision, agent, and assistant home.
`profile_get/3` returns `{:ok, item}`. A changed record returns `{:error, :stale}`;
another profile's record returns `{:error, :not_found}`. Raw document IDs are
not accepted by these APIs. Preview returns an internal `confirmation_digest`;
confirmed deletion rechecks ownership and revision before Store atomically
removes the record and its FTS row. Success is
`{:ok, %{"deleted" => true, "id" => id}}`; forged confirmations fail with
`:confirmation_mismatch`. Store failures return `:memory_unavailable`, never an
empty successful browse.

`LemonSkills.ProfileMemory.execute/4` composes these APIs with its owning
`WorkspacePreferences` service for `USER.md`/`MEMORY.md`. It derives
destination-local paths through `ProfileStore.paths/2` without requiring a
destination configuration record, returns bounded snapshot-bound pages, and
requires the exact revision-bound item ID as delete confirmation. Workspace
adds and the existing `remember` tool share preference screening and capacity
rules rather than writing a second memory store.
Workspace queries match the bounded raw preference entries before redaction
and preview truncation, so keywords beyond the displayed excerpt remain searchable.

Full profile copying uses `LemonSkills.ProfileMemoryTransfer`, not redacted
lifecycle projections. Store's typed `transfer_snapshot/4`, `transfer_get/2`,
`transfer_put_new/3`, and `transfer_import/8` (or `/9` with local boundary/rollback
options) own its private durable journal and SQLite transaction. The Store process
owns the filesystem boundary lock across publication, commit and known rollback.
Import rechecks exact selected row revisions, rejects foreign identity collisions,
replaces only the chosen agent/home scope, and commits the receipt together with
the rows and FTS updates. A durable pending
intent is never a successful import and must not be automatically replayed.
Transfer scans reject more than 2000 agent rows or 500 selected documents rather
than silently copying a recent window. See the
[owning transfer API](../lemon_skills/README.md#profile-memory-transfer).

### Native private memory and explicit sharing

Native ownership requires valid atom `:memory_context_key` and
`:invocation_context_key` fields plus `:memory_context_verified == true`, stamped
by the admitted request owner. String fields, nested provider metadata, and
caller booleans cannot establish that proof. The stable memory key owns durable
memory across policy epochs; the invocation key proves the current admission.
Incomplete context claims fail closed. No-key legacy personal sessions retain
their existing behavior, but never read private or unproven documents.

`Document.from_run/4` removes claimed ownership fields and stamps canonical
private/unproven/legacy metadata from the native proof. Run records are never
shared, even when a shared-write grant exists. Nullable SQLite ownership columns
index new owning writes without rewriting or attesting retained legacy rows.
New run projections also discard runtime MCP/server/header/token configuration
and ephemeral invocation proof/grant artifacts; the full run receipt remains
owned by `lemon_core`. Provider/completion metadata cannot supply memory proof or
reclassify a run as a protected preference.

Every Store read includes a `Document.index` tuple of the persisted ownership
columns, included in the record revision. `Store.document_ownership(doc)` derives
authority from that tuple plus canonical metadata agreement. An old NULL-index
row cannot attest private/shared ownership merely by containing future-looking
raw flags; scoped exact-ID reads use `Store.get_owned_document/5` as well.

`Preferences.remember(context, kind, text, replaces \\ nil, opts \\ [])` saves
`user`/`memory` notes in Store, not `USER.md` or `MEMORY.md`. Replacement
or removal affects only the selected write owner. Exact entries take priority;
otherwise a unique substring selects an entry. Deletion removes that entry,
while patching replaces only the unique span; ambiguous entries or repeated
spans return `:ambiguous_match` without writing. Project selectors normalize
whitespace like project facts. Patched results pass normal safety and capacity
checks. Backdoor and credential-exfiltration instructions are screened as prompt
injection on new writes and patched results, not retroactively on retained
facts or replacement selectors. Existing secret/control/injection read checks
remain in force. Accepted text bytes are preserved in bounded `preference_facts`
metadata, independently of Document's
2000-byte index summary. Secret, invisible-control, and injection screening is
shared through `Safety.validate_note/2`; input is capped at 4096 bytes, total
notes at 200 per owner, and per-kind text at 1375/2200 characters. Mutations
serialize under the same preference-owner lock. Notes use context-namespaced
session identities and are not expired by ordinary history retention/pruning.
New project learnings are also retained until explicitly changed or deleted.

`Preferences.add(context, kind, text, store: server, memory_scope: selector)`
is the trusted management mutation for explicit private or shared selectors;
it needs no fabricated invocation key and returns exactly the Lifecycle
revision-bound six-field projection. Native `remember` never accepts that
operator override: only a valid admitted `:shared_memory_grant == true` changes
its write target to shared. Automatic Project capture remains private even
with that grant, and mutations never load combined private/shared reads.

`Preferences.read/2` returns full private plus explicitly shared facts.
`read_shared/2` returns only verified shared facts.
`shared_bootstrap/2` returns `{:ok, %{"USER.md" => markdown, "MEMORY.md" => markdown}}`
generated only from canonical shared preference documents (empty strings when
absent). All three require proven native private context; Store failures are
errors, never a legacy-file fallback. Unknown retained workspace-file facts
are not automatically shared with context-owned runs.

`Preferences.usage(context, kind, opts)` reports safe scoped entries, used characters
and the per-kind cap. `Project.usage(context, opts)` reports fact count, byte usage,
and both caps. These reads preserve the same ownership checks as ordinary reads.

`Project.read/2` combines only the exact private project and explicitly shared
curated project namespace, within its existing fact/byte budget.
`Project.search_history(context, query, requested_scope, opts)` searches local
history with profile, private key, history kind, and optional repository filters
before its limit; the existing `session_search` feature policy still applies.
`:agent`, `:workspace`, and `:project` are supported; `:store` and `:limit` select
the server and bounded result count. Recall uses that same owning API, full
preference metadata before bounded rendering, and canonical shared bootstrap
facts rather than unproven raw files. No provider/network/model fallback exists.

`SessionSearch.session(context, session_key, opts)` reads chronological owned
run summaries around `:around` (document/run ID), or the latest `:window`
(default 5, maximum 20). `recent_sessions(context, opts)` returns first-prompt
representatives and run counts. Both apply indexed ownership/profile filters
before window selection, require a proven private context just like history
search, refuse subagents, and respect the session-search flag. Legacy or partial
ownership contexts return `{:error, :unproven_context}` rather than browsing.
Scroll prompt/answer summaries are capped at 1024/2048 bytes respectively.

Authorized profile copies first inspect `Store.document_ownership/1` on the
unchanged source snapshot and canonicalize portable ownership from that result,
never from raw flags alone. `Project.transfer_document_id(destination, metadata)`
then returns `{:ok, id}` in the correct private/shared/plain-legacy destination
namespace without inventing native invocation proof. Unproven copies retain
their unproven state rather than becoming a canonical project document.
Transfers preserve full `preference_facts` and call `Document.with_index/1` after
rehoming a trusted new write. `Store.transfer_snapshot/4` keeps its one-argument
callback and revision tuple protocol; those revisions now bind indexed authority.
Exact opaque `sha256:<64hex>` workspace identities are preserved, never resolved
against a worker cwd or mapped into its current repository.


`mix lemon.memory` inspects and searches the store from the command line.

## Installation

```elixir
def deps do
  [{:lemon_memory, "~> 0.2"}]
end
```

SQLite (`exqlite`) is a hard dependency here, unlike in `lemon_core` where it is
optional: a durable store is this package's reason to exist.

## Adding a provider

Implement `LemonMemory.Provider` and register it at boot:

```elixir
LemonMemory.Providers.register_provider(%{
  id: "vector",
  module: MyApp.VectorMemory,
  label: "Vector store",
  timeout_ms: 2_000
})
```

Searches then fan out to it alongside the local store. Read the behaviour's
moduledoc first — it documents the contract in prose, including the rules that
are easy to get wrong (`search/2` returns a bare list, must not raise on user
input, and must ignore options it does not recognise).

Verify your provider against the platform's compliance suite:

```elixir
defmodule MyApp.VectorMemoryTest do
  use LemonPlatformTest.ProviderCase, provider: MyApp.VectorMemory
end
```

## Configuration

```elixir
# `:path` is a directory; memory.sqlite3 is created inside it.
config :lemon_memory, LemonMemory.Store, path: "/var/lib/my_app/store"

# Ingest options; `start_link/1` opts take precedence over these.
config :lemon_memory, LemonMemory.Ingest, config_ttl_ms: 30_000
```

`LemonMemory.Application` starts `Providers` always, and `Store` plus `Ingest`
when SQLite is available, both registered under their module names.

## Running more than one instance

`Store` and `Ingest` both take `:name`, and every public function on them takes
the server as an optional first argument, so an embedding application can run
isolated pipelines side by side in one node:

```elixir
children = [
  Supervisor.child_spec(
    {LemonMemory.Store, name: :tenant_a_store, path: "/var/lib/my_app/tenant_a"},
    id: :tenant_a_store
  ),
  Supervisor.child_spec(
    {LemonMemory.Ingest, name: :tenant_a_ingest, memory_store: :tenant_a_store},
    id: :tenant_a_ingest
  )
]
```

A non-default ingest worker binds its name into the finalize-run hook:
`{LemonMemory.Ingest, :handle_finalize_run, [:tenant_a_ingest]}`.
