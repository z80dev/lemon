# Tenant activity lookup

The activity API reads `event_lookup.sql` as one parameterized SELECT and binds
`:tenant_id`, `:start_at`, `:end_at`, and `:limit`. `schema.sql` and `sample.sql`
provide a local dataset. Fix the SELECT and `indexes.sql`; keep schema and API
column names unchanged. SQLite 3.40 and Python's standard library suffice.

## Query contract

Return `(event_id, occurred_at, kind, payload)` for just the requested tenant,
with `deleted_at IS NULL`, and `start_at <= occurred_at < end_at`. Sort by
`occurred_at DESC, event_id DESC`, then apply `:limit`. The limit is an integer
>= 0 (zero returns no rows). The start/end may be equal or reversed; then the
result is empty. A tenant with no matches returns no rows. Preserve payload and
kind exactly, including Unicode and NULL payloads; do not deduplicate events.

Timestamps are canonical UTC strings of the form `YYYY-MM-DDTHH:MM:SSZ`, with
four-digit years, zero-padded fields, and no fractional seconds. Lexical order
is chronological order. Bounds use this same format. Do not truncate timestamps
to calendar dates. Deletion is indicated by any non-NULL deleted_at value.
Tenant IDs are integers; there are no other implicit kind or payload filters.

## Query-plan contract

`indexes.sql` must install an index named `events_live_lookup`, and be safely
reapplicable to the same database without losing event data or unrelated indexes.
The supplied incorrect definition under that name may already exist; reapplying
your installer must replace/fix it as needed. Only this index installer and the
lookup query need changing; the API executes no additional statements.

For nonempty canonical ranges, with ordinary positive limits, SQLite
`EXPLAIN QUERY PLAN` of the parameterized query must show a range SEARCH of
`events` using `events_live_lookup` (tenant equality and occurred_at bounds),
not merely a full index scan or tenant-only search. It must not need a temporary
B-tree for ORDER BY. The tests check results and this structural plan property,
not elapsed time. Partial indexes are allowed; INDEXED BY is not required.
Do not change SQLite PRAGMAs or depend on ANALYZE for correctness.

## Local workflow

```
sqlite3 activity.db < schema.sql
sqlite3 activity.db < sample.sql
sqlite3 activity.db < indexes.sql
python3 -m unittest discover -s tests -v
```
The visible tests invoke the CLI to install indexes, then use sqlite3 parameter
binding to execute the query and inspect its plan.
