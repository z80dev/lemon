# Platform Microbenchmarks

Numbers for the primitives every agent run goes through: the store, the event
bus, the streaming coalescers, and the per-conversation process lifecycle.

These measure **infrastructure, not intelligence**. For model behaviour see
[the simulation arenas](quickstart.md); for the artifact and verification
guarantees those arenas provide, see [platform.md](platform.md). Nothing here
calls a model or touches a network.

Everything below is reproducible with `mix lemon.bench`. The suites live in
[`bench/`](../../bench) and are about 700 lines total, so if a number looks
wrong the code that produced it is short enough to check.

## Read this first

**These are dev-workstation numbers.** They were taken on one machine, on
Linux, with a desktop CPU and no other load to speak of — not on the hardware
anyone would deploy to, and not averaged across machines. Treat them as
*ratios and orders of magnitude*, which transfer, rather than as absolutes,
which do not.

| | |
| --- | --- |
| CPU | AMD Ryzen 7 9700X, 8 cores / 16 threads |
| Memory | 60.4 GB |
| OS | Linux (Arch, kernel 7.1) |
| Elixir / OTP | 1.19.5 / 28.5, JIT enabled |
| Date | 2026-08-10 |
| Schedulers | 16 online |

**Variance is high and we are not hiding it.** Several scenarios show Benchee
deviations in the hundreds of percent. That is normal for operations measured
in hundreds of nanoseconds — a GC pause or a scheduler hop is larger than the
thing being measured — but it means **the median is the number to read, not
the average**. Where a distribution is genuinely wide, the 99th percentile is
given too. Run-to-run drift of 10-20% on the throughput figures is routine;
two runs of this suite an hour apart produced single-store write throughput of
720k/s and 1.20M/s. Any comparison finer than "about twice as fast" is noise.

**Each suite runs in a fresh VM under `mix run --no-start`.** Nothing in the
umbrella starts unless a suite starts it deliberately, so no cron job, channel
adapter or agent runtime is running in the background. This is a deliberate
choice for signal, and it is also a limitation: it measures components in
isolation, not a loaded production node.

## Running them

```bash
mix lemon.bench                # all four suites
mix lemon.bench store          # one
mix lemon.bench bus process    # several
```

## Store

`LemonCore.Store` is a GenServer in front of a pluggable backend. Writes
serialise through that one process; reads either serialise with them or bypass
the mailbox entirely through an ETS read cache. The numbers exist mostly to
show the size of that difference.

### Single operation, median latency

| Operation | Backend | Median | Ops/sec |
| --- | --- | ---: | ---: |
| `get` on a cached table | ETS read cache | **0.17 µs** | 4.9 M |
| `put_new` | ETS | 0.94 µs | 982 K |
| `put` | ETS | 0.99 µs | 955 K |
| `get` on an uncached table | ETS | 1.08 µs | 853 K |
| `put` | SQLite | 3.79 µs | 257 K |
| `put_new` | SQLite | 4.38 µs | 215 K |
| `get` | SQLite | 4.38 µs | 215 K |

The read cache is roughly **6x faster than the same read through the
GenServer**, because it is an ETS lookup in the calling process and never
touches the store's mailbox. That is the entire argument for `:cached_tables`.
It is also why the default cached set is small: every cached table is memory
held twice and a consistency obligation on write.

SQLite costs about 4x ETS per operation. That is the price of durability, and
it is low enough that it is rarely the reason an agent feels slow.

### About those SQLite write numbers

A 3.79 µs durable write should look suspicious, and the explanation belongs
next to the number: `SqliteBackend` opens with `journal_mode=WAL` and
**`synchronous=NORMAL`**
([`sqlite_backend.ex:340`](../../apps/lemon_core/lib/lemon_core/store/sqlite_backend.ex)).
Under WAL with `NORMAL`, a commit does not `fsync` — it appends to the WAL and
syncs at checkpoints. So this is "the write reached the OS", not "the write
survived a power cut". A crash of the BEAM keeps the data; a sudden loss of
power can lose recent commits. `synchronous=FULL` would be materially slower
and is the setting to reach for if that trade is wrong for your deployment.

### `list/2` by table size

`list/2` returns every pair in a table, and it is the operation most likely to
surprise someone.

| Rows | ETS | SQLite |
| ---: | ---: | ---: |
| 100 | 0.012 ms | 0.113 ms |
| 1,000 | 0.135 ms | 1.03 ms |
| 10,000 | 1.31 ms | 15.5 ms |

Both are linear, both are fine at a hundred rows, and neither is fine on a hot
path at ten thousand. A 15 ms SQLite `list` inside a request is a stall a user
can feel. Backends that support it can push ORDER BY + LIMIT down via
`list_recent/3`; that is what it is for.

### Concurrent throughput

Benchee measures one operation at a time. This measures eight processes
writing at once, which is the question that matters for a serialising
GenServer.

| Scenario | Throughput |
| --- | ---: |
| 1 store, 1 writer (reference) | 634 K ops/s |
| 1 store, 8 writers | 1.20 M ops/s |
| 8 stores, 8 writers | 2.66 M ops/s |
| Cached `get`, 8 readers | **21.1 M ops/s** |
| Uncached `get`, 8 readers | 1.36 M ops/s |
| 1 SQLite store, 8 writers | 111 K ops/s |

Three things worth naming, two of them unflattering:

1. **Eight writers do not get eight times the throughput of one.** They get
   about double. A single store is a single mailbox: with one writer the store
   idles while the caller round-trips, so more writers mainly keep it busy
   rather than making it faster. Somewhere near 1.2 M puts/sec is the ceiling
   for one store on this machine, and no amount of caller concurrency moves it.
2. **Eight stores get about 2.2x one store, not 8x.** Sharding the keyspace
   across instances is the supported way to buy write concurrency, and it works
   — but it stops paying well before the core count, because the cost moves to
   scheduling and message copying. Do not plan capacity assuming linear scaling.
3. **The cached read path is the one that genuinely scales.** 21 M reads/sec
   across 8 readers, because it takes no lock and touches no mailbox. Reads that
   matter should be on cached tables.

## Bus

`LemonCore.Bus` uses `Phoenix.PubSub` when phoenix_pubsub is available and a
duplicate-key `Registry` otherwise. Two numbers per configuration: how long
`broadcast/2` blocks the caller, and how long until the last subscriber has
*processed* the message.

Microseconds, median (p99), 2,000 iterations each.

| Backend | Subscribers | Publish p50 | Publish p99 | Fanout p50 | Fanout p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| registry | 1 | 0.42 | 2.12 | 0.76 | 2.50 |
| registry | 10 | 2.85 | 13.04 | 3.23 | 9.77 |
| registry | 100 | 29.49 | 48.28 | 28.10 | 50.99 |
| registry | 1,000 | 287.48 | 380.85 | 282.35 | 361.13 |
| pubsub | 1 | 1.83 | 5.85 | 1.79 | 85.01 |
| pubsub | 10 | 3.99 | 11.19 | 4.39 | 8.24 |
| pubsub | 100 | 30.64 | 51.37 | 29.58 | 52.61 |
| pubsub | 1,000 | 302.18 | 435.48 | 303.73 | 400.85 |

**The Registry fallback is not a downgrade on a single node.** It matches
Phoenix.PubSub within noise at every subscriber count, and beats it slightly at
low counts where PubSub's extra indirection shows. The documented reason to
depend on phoenix_pubsub is distribution — broadcasts crossing node boundaries
— not local speed. That claim now has a number behind it.

**Publish cost and fanout cost are the same number, and that is the finding.**
`broadcast/2` dispatches to local subscribers synchronously in the calling
process, so a publisher fanning out to 1,000 subscribers is blocked for ~290 µs
doing it. Fanout is linear in subscriber count at roughly **0.29 µs per
subscriber**. A run process broadcasting per-token deltas to a topic with a
large audience is paying that on every delta, on its own scheduler time. If
that ever becomes a problem the fix is a relay process, not a faster bus.

### Typed events are effectively free

| Call | Median |
| --- | ---: |
| `broadcast/2` with a raw map | 2.60 µs |
| `broadcast_event/4`, unregistered type | 2.89 µs |
| `broadcast_event/4`, registered type (payload checked) | 2.73 µs |
| `broadcast/2` with a struct | 2.82 µs |

The registry lookup and struct check in `broadcast_event/4` cost less than the
run-to-run spread of the measurement itself — across two runs the "overhead"
came out at 0.49 µs and then at −0.09 µs, which is another way of saying it is
unmeasurable at this scale. **Performance is not a reason to avoid typed
events.**

## Coalescers

A model streams tokens far faster than any chat API accepts edits.
`StreamCoalescer` absorbs that burst and emits a much smaller number of
delivery intents, bounded by `min_chars: 200`, `idle_ms: 800` and
`max_latency_ms: 3000`. The headline is the compression ratio, not the latency.

Deltas are 20 characters each; downstream dispatch is stubbed.

| Deltas | Total | Per delta | Dispatches | Ratio |
| ---: | ---: | ---: | ---: | --- |
| 10 | 1.97 ms | 196.9 µs | 1 | 1 per 10 |
| 100 | 0.26 ms | 2.60 µs | 10 | 1 per 10 |
| 1,000 | 1.78 ms | 1.78 µs | 100 | 1 per 10 |
| 10,000 | **5,004 ms** | **500.5 µs** | 735 | 1 per 13 |

The first row is cold start: spawning the coalescer under its DynamicSupervisor
dominates ten deltas. The steady state is ~1.8 µs per delta and a **10:1
reduction in outbound API calls**, which is the number that keeps a bot off a
rate limit.

The last row is not a typo.

### The 100,000-character cliff

`StreamCoalescer` caps its accumulated answer at 100,000 characters via
`cap_full_text/1`
([`stream_coalescer.ex:637`](../../apps/lemon_router/lib/lemon_router/stream_coalescer.ex)):

```elixir
String.slice(text, String.length(text) - keep, keep)
```

Both `String.length/1` and `String.slice/3` walk the binary grapheme by
grapheme. Once an answer crosses the cap, **every subsequent delta re-walks
100,000 characters, twice**.

| Accumulated answer | Cost per delta |
| --- | ---: |
| 50k characters (below cap) | 0.44 µs |
| 99k characters (below cap) | 0.75 µs |
| 100k characters (at cap) | **1.00 ms** |
| 200k characters (above cap) | **3.79 ms** |
| the same trim via `binary_part/3` | 2.21 µs |

That is a **2,200x step change** at the cap, and a byte-based `binary_part/3`
does the same job about 450x faster than the grapheme-based version at 200k.
In practice a run whose answer exceeds 100k characters spends multiple seconds
of CPU inside the coalescer — the 10,000-delta row above is five seconds of
wall clock, essentially all of it here.

This is a real defect, not a benchmark artifact, and it is filed as such. It
only bites runs with very long single answers, which is why it has gone
unnoticed.

### Per-operation cost

| Operation | Median |
| --- | ---: |
| `ingest_delta` (caller: registry lookup + cast) | 0.64 µs |
| `current_text` (call round-trip only) | 1.12 µs |
| `ingest_delta` + drain (caller + coalescer work) | 2.71 µs |

`ingest_delta` is a cast, so a producer can enqueue about twice as fast as the
coalescer drains. The buffer between them is an unbounded mailbox — worth
knowing before pointing a very fast local engine at one.

### Concurrent conversations

| Load | Wall clock | Throughput |
| --- | ---: | ---: |
| 100 sessions x 50 deltas | 4.6 ms | 1.09 M deltas/s |
| 1,000 sessions x 50 deltas | 19.0 ms | 2.63 M deltas/s |

A thousand simultaneous conversations, each with its own coalescer process,
buffer and timer, absorb fifty thousand deltas in 19 ms. Throughput *improves*
with more sessions because the work spreads across schedulers instead of
queueing behind one mailbox — the same effect that makes eight stores beat one.

### Tool status coalescer

`ToolStatusCoalescer` collapses tool lifecycle events into one editable
message. Its flushes are purely timer-driven (`idle_ms: 400`,
`max_latency_ms: 1200`) rather than size-driven, so absorbing a burst and
emitting one are measured separately.

| Tools | Lifecycle events | Absorb | Per event |
| ---: | ---: | ---: | ---: |
| 10 | 20 | 0.05 ms | 2.70 µs |
| 100 | 200 | 0.28 ms | 1.39 µs |
| 1,000 | 2,000 | 1.75 ms | 0.88 µs |

Dispatch counts for this suite vary substantially between runs (a burst that
completes in under 2 ms may produce one flush or several, depending on where
the 400 ms idle timer lands relative to it). Absorb cost is stable; the flush
count is not, and should not be read as a ratio.

## Process lifecycle

Every run gets a supervised, registry-named process. Whether that is
affordable at scale is a fair question with a numeric answer.

**What this does not measure:** a real `LemonRouter.RunProcess` resolves a
conversation, subscribes to the Bus, submits an `ExecutionCommand` to an engine
and starts a watchdog — dominated by a network call to a model provider. These
numbers use a GenServer whose `init/1` does nothing. Read them as "the process
machinery costs about this much", not "a run starts in this long".

| Operation | Median |
| --- | ---: |
| Registry lookup (hit) | 241 ns |
| Registry lookup (miss) | 270 ns |
| `GenServer.call` via a registry name | 1,694 ns |

### Bulk spawn

| Processes | Total | Each | Rate |
| ---: | ---: | ---: | ---: |
| 1,000 | 5.5 ms | 5.50 µs | 182 K/s |
| 10,000 | 52.2 ms | 5.22 µs | 192 K/s |
| 50,000 | 278.4 ms | 5.57 µs | 180 K/s |

Spawning, registering and supervising a conversation process costs about
**5.5 µs and stays flat to 50,000 processes** — the per-process cost does not
degrade as the population grows, which is the property that makes
process-per-conversation viable.

### Concurrent spawn does not scale

| Concurrent starters | Throughput |
| ---: | ---: |
| 1 | 179 K ops/s |
| 8 | 190 K ops/s |
| 32 | 175 K ops/s |

`DynamicSupervisor.start_child/2` is a call into a single supervisor process,
so **adding concurrent starters buys nothing** — 32 of them are marginally
worse than one. About 180 K starts/sec is the ceiling for a single supervisor,
which is far above any plausible arrival rate for conversations but is a real
limit worth knowing before designing something that starts processes in a hot
loop. The fix, if it ever matters, is more supervisors, not more callers.

### Memory

50,000 idle registered GenServers occupy **157.9 MB — about 3.3 KB each**,
including the Registry entry and the supervisor's child record.

At that rate 10,000 concurrent conversations cost roughly 33 MB of process
memory. This is measured on processes that have never received a message; a
run that has streamed a long conversation carries its accumulated text on its
own heap, and the coalescer cap above is a reminder that "its own heap" can be
100,000 characters.

## Why these are not in CI

They are not wired into any CI lane, deliberately.

GitHub Actions runners are shared, noisy and variable — the throughput figures
here move 10-20% between runs on a *quiet dedicated machine*, and CI runners are
neither. A performance gate built on that either fails constantly on noise,
which trains everyone to ignore it, or is set loose enough to catch nothing.
Either way it costs minutes of CI time per push to produce a number nobody can
act on.

The honest way to use these is to run them locally, on the same machine, before
and after a change you expect to matter, and to compare the medians. If we ever
want continuous performance tracking it needs dedicated hardware and a
regression model that understands variance — which is a real project, not a
workflow file.

## Reproducing

```bash
mix lemon.bench
```

Suites: [`bench/store.exs`](../../bench/store.exs),
[`bench/bus.exs`](../../bench/bus.exs),
[`bench/coalescer.exs`](../../bench/coalescer.exs),
[`bench/process.exs`](../../bench/process.exs), with shared helpers in
[`bench/support.exs`](../../bench/support.exs).

Numbers on this page are from a single full run on 2026-08-10. If you re-run
them and the ratios hold but the absolutes differ, that is the expected
outcome, and the ratios were the point.
