# Owned Storage

How persistent state is split between the modules that own it and the store
that keeps it. This is the deliverable of Phase 3 of the
[September 2026 architecture review](../architecture/review-2026-09.md),
revised in its section 7: domain behaviour leaves `LemonCore.Store` first,
into small modules that own meaning, and table registration is trialled on
a few different domains before it is asked of everyone.

The rule, in one line: **a domain module owns what a table means; the store
owns how it is kept.** Meaning is validation, defaults, retention policy and
compatibility with older values. Keeping is backend access, atomic
operations and cache coherence.

## The two layers

| Layer | Module | Owns |
| --- | --- | --- |
| Domain | `LemonCore.ChatStateStore`, `LemonCore.RunStore`, `LemonCore.ProgressStore`, `LemonCore.PolicyStore`, `LemonCore.IntrospectionStore`, `LemonCore.IdempotencyStore`, `LemonAutomation.CronStore`, `LemonChannels.Telegram.KnownTargetStore`, ... | The table's name and key shape, the value's fields, validation before a write, defaults on a read, the retention policy, the hooks other modules attach to |
| Storage | `LemonCore.Store` with `LemonCore.Store.Backend` implementations, `LemonCore.Store.ReadCache`, `LemonCore.Store.Table` | Backend reads and writes, `put_new`, `compare_and_swap`, `update`, `take`, the read-cache mirror and its coherence, the periodic sweep that applies declared retention |

`LemonCore.Store` no longer implements chat state, run records, progress
mappings, policies or introspection events. It does not know those tables
exist until their owners register them.

## Declaring and registering a table

A domain module declares the tables it owns once:

```elixir
defmodule LemonAutomation.CronStore do
  use LemonCore.Store.Table,
    tables: [
      cron_jobs: [],
      cron_runs: [retention: [max_age_ms: 48 * 60 * 60 * 1000, timestamp: :started_at_ms]],
      cron_audit_events: [],
      cron_monitor_state: [],
      cron_preflight_notice_state: []
    ]
end
```

and its application registers them with the store when it starts:

```elixir
LemonCore.Store.Table.register(LemonAutomation.CronStore)
```

Registration is what gives a table a read-cache mirror (`cached: true`),
an expiry policy (`retention:`) and a persistence hint
(`persistence: :ephemeral`). It is also the record of ownership: a table
registered by one module cannot be registered by another, and the
application that tries fails to boot with the conflict in the error.
Registrations are per store instance and survive a store restart;
`lemon_core`'s own table modules are registered by every instance at boot
(`:table_modules`), so a second store behaves like the first for the
domains core ships with.

A declaration generates no accessors. The owning module writes the storage
calls it needs, which keeps each module readable on its own and keeps the
macro small. What the declaration buys is that the store can enumerate
the tables that exist, apply their policies without naming them, and tell
who owns what.

## The questions the trial had to answer

Section 7 of the review asked for explicit answers before table
registration is adopted more widely. These are the answers the trial
settled on, each backed by a test in `apps/lemon_core/test/lemon_core/store/table_test.exs`
or `apps/lemon_core/test/lemon_core/store_test.exs`.

**Schema versioning.** A declaration carries a `version:` for the owner's
own records. The store does not migrate values: the owner reads the shapes
it has written before (`LemonCore.IdempotencyStore` reads
`"inserted_at_ms"` under its string key; `LemonCore.RunStore` accepts the
record shape it has always written). Automatic migration on read was left
out deliberately, because no table needed it and unused machinery is
exactly what this phase removes.

**Missing versus failed reads.** `LemonCore.Store.fetch/3` answers
`{:ok, value}`, `:error` for an absent key and `{:error, reason}` when the
backend failed or the store is unavailable. `get/3` collapses the last two
into `nil` for callers that do not care, and says so. Neither can tell a
stored `nil` from an absent key.

**Atomic updates.** `LemonCore.Store.update/5` runs a function over the
current value (or a default when the key is absent) inside the store
process, so concurrent updates of one key all apply; `compare_and_swap/5`
and `put_new/4` remain for the cases that need a precondition. A function
that raises is a bug in the owner: it is logged with its stacktrace,
answered as `{:error, {:update_failed, exception}}`, and nothing is
written.

**Retention.** Declared per table, in one of two forms: an absolute
expiry stored in the value (`retention: [expires_at: :expires_at]`, chat
state) or an age measured from a timestamp (`retention: [max_age_ms: ms,
timestamp: field | {module, function}]`, idempotency entries, cron runs,
introspection events). The store's periodic sweep applies every declared
policy, evicts what it deletes from the read cache, keeps entries it cannot
date, and isolates a timestamp function that raises. `LemonCore.Store.sweep/1`
runs it on demand. The per-domain sweeps that used to live in the store
are gone.

**Backend routing.** A declaration may hint `persistence: :ephemeral`. A
backend that can honour it does through the optional
`register_table/2` callback: the SQLite backend keeps such a table in
memory, which is what `:runs` has always needed. Other backends ignore the
hint. Per-table backends were not needed by any domain and were not built.

**Cache coherence and write semantics.** Unchanged, and now stated once in
`LemonCore.Store`: the store process is the read cache's only writer and
writes it only after the backend confirms; `put`, `put_new`,
`compare_and_swap`, `update`, `delete` and `take` are synchronous;
`put_async` and `update_async` are casts for writers that produce far more
than anything reads back, with `ping/1` as the barrier. `LemonCore.RunStore.append_event/3`
uses `update_async`; `LemonCore.RunStore.finalize/3` is now synchronous, so
when it returns the record is written, the session is indexed and every
finalize hook has run in the caller's process.

## What moved

| Behaviour | Was in `LemonCore.Store` | Now in |
| --- | --- | --- |
| Chat state TTL stamp, lazy expiry, sweep | `put_chat_state/3`, `get_chat_state/2`, `delete_chat_state/2`, `sweep_expired_chat_states` | `LemonCore.ChatStateStore` (`ttl_ms/0` from `config :lemon_core, LemonCore.ChatStateStore`), retention declared |
| Run records and the session index | `append_run_event/3`, `finalize_run/3`, `get_run/2`, `update_sessions_index/5`, `parse_agent_id/1` | `LemonCore.RunStore` |
| Finalize hooks | `:finalize_run_hooks` option, `register_finalize_run_hook/2` | `config :lemon_core, LemonCore.RunStore, finalize_hooks:` and `LemonCore.RunStore.register_finalize_hook/2` |
| Run history reads | `:run_history_provider` option, `get_run_history/3` | `LemonCore.RunStore.history/2`, which reads `LemonCore.RunHistoryStore` directly |
| Progress message mapping | `put_progress_mapping/4`, `get_run_by_progress/3`, `delete_progress_mapping/3` | `LemonCore.ProgressStore` |
| Policies | sixteen `*_policy` functions | `LemonCore.PolicyStore` |
| Introspection events: validation, filtering, retention | `append_introspection_event/2`, `list_introspection_events/2`, `sweep_expired_introspection_events` | `LemonCore.IntrospectionStore` |
| Idempotency and cron-run retention | `sweep_expired_idempotency`, `sweep_expired_cron_runs` | Declared by `LemonCore.IdempotencyStore` and `LemonAutomation.CronStore` |
| Cached-domain list | `ReadCache` intrinsic domains `:chat`, `:runs`, `:progress`; `@default_cached_tables [:sessions_index]` | Declared `cached: true` by their owners |
| Telegram known targets mirror | `register_cached_table/2` call from channels | `LemonChannels.Telegram.KnownTargetStore` declaration, registered by `LemonChannels.Application` |

The store keeps `register_cached_table/2` for a table that needs nothing
but the mirror.

## What the trial found

Three domains of different shape adopted declarations: a single table with
an age-based retention (`LemonCore.IdempotencyStore`), a five-table domain
in another application with retention on one of them
(`LemonAutomation.CronStore`), and a cached hot table with an absolute
expiry and a synchronous write contract (`LemonCore.ChatStateStore`). The
other core owners (`RunStore`, `ProgressStore`, `PolicyStore`,
`IntrospectionStore`) and the Telegram known-target index followed because
their behaviour was being moved anyway.

What worked: every per-domain sweep and every hardcoded table list in the
store disappeared behind one sweep over declarations, and ownership
conflicts fail at boot instead of being discovered by a lint rule. What
did not need building: accessor generation, automatic migration and
per-table backends.

What remains, and is not this phase's job:

- Most of the other `*_store.ex` modules still name their tables in
  generic calls without a declaration. They work; they simply get no
  retention, mirror or ownership record from the store. Adopt the
  declaration when a module is next touched. The measure is the
  `generic_store_tables` ratchet, not the number of wrapper modules.
- The cron diagnostics used to read the cron tables from `lemon_core`, below
  the application that owns them; they now live in
  `LemonAutomation.Doctor.CronDiagnostics` and read through `CronStore`, and
  the doctor reaches them through `config :lemon_core, :doctor_runtime`.
- `LemonCore.Store.JsonlBackend` still lists domain tables to preload; it
  also discovers tables from disk, so the list is a legacy it can lose.

## How this is kept true

- `LemonCore.Store.Table.register/2` raises on a table another module owns,
  and the applications that own tables register them at boot.
- `mix lemon.quality` ratchets `generic_store_tables`, the distinct tables
  named in generic store calls outside modules that `use LemonCore.Store.Table`,
  so the count can only fall.
- The rules in `LemonCore.Quality.ArchitectureRulesCheck` that banned
  bypasses of the store's domain functions are gone with the functions;
  calling them is a compile error now.
