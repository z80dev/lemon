# LemonMemory

Durable memory for agents: what an agent did, written down and searchable later.

`lemon_memory` is one of the packages that make up the [Lemon](https://github.com/z80dev/lemon)
agent platform. It is usable on its own — its only Lemon dependency is
`lemon_core`.

## What is in it

| Module | Purpose |
|---|---|
| `LemonMemory.Document` | The record every provider reads and writes: content, scope, metadata, timestamps |
| `LemonMemory.Store` | SQLite-backed store with full-text search; the built-in durable backend |
| `LemonMemory.Provider` | Behaviour for a searchable memory backend |
| `LemonMemory.Providers` | Fan-out registry — queries every registered provider, isolates failures and timeouts |
| `LemonMemory.Providers.Local` | The built-in provider over `LemonMemory.Store` |
| `LemonMemory.Ingest` | Writes finished runs into memory, invoked from the store's finalize-run hook |
| `LemonMemory.Safety` | Redaction and size limits applied before anything is persisted |
| `LemonMemory.SessionSearch` | Scoped search across sessions, agents and workspaces |
| `LemonMemory.TaskFingerprint` | Stable fingerprints for recognising repeated work |

Explicit review/confirm workflows can use `LemonMemory.Store.put_sync/1` when
they must not report success before SQLite accepts a document, or
`put_new_sync/1` for an atomic create-if-absent boundary that never overwrites
an exact document ID. `get_document/1` and `delete_document/1` inspect and
remove one exact record; deletion removes its FTS row in the same SQLite
transaction. Ordinary run ingest remains asynchronous.
`LemonMemory.Safety.redact/1` removes common secret-shaped values before a
caller builds the bounded document summary.

`mix lemon.memory` inspects and searches the store from the command line.

## Installation

```elixir
def deps do
  [{:lemon_memory, "~> 0.1"}]
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
