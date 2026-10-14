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
`profile_get(context, id, opts \\ [])`, `profile_preview_delete(context, id, opts \\ [])`,
and `profile_delete(context, id, confirmation_digest, opts \\ [])` provide the
profile-specific lifecycle. The context must have `session_scope: :main`,
`agent_id`, `workspace_dir` (the assistant home), and `cwd`. Every record must
match **both** the agent ID and the exact expanded assistant-home digest.
Legacy unscoped records are excluded; project learnings from all repositories
within that profile are included. `:server` selects an isolated Store instance.

Browse/search reads at most 200 recent records for that agent, returning
`{:ok, %{items: items, revision: revision}}`. Each item contains only string
keys `id`, `kind`, `text`, `source`, `createdAtMs`, and `updatedAtMs`. Source is
`"durable"`; kinds are `"run"`, `"learned_source"`, or `"project_learning"`.
Text is operator-redacted, valid UTF-8, and at most 2048 bytes. Failed-run details
are withheld. The browse revision is internal pagination state, not display
data.

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
