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
```

`LemonMemory.Application` starts `Providers` always, and `Store` plus `Ingest`
when SQLite is available.
