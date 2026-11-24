# Platform Microbenchmarks

Numbers for the primitives every agent run goes through: the store, the event
bus, the streaming coalescers, and the per-conversation process lifecycle.

These measure **infrastructure, not intelligence**. For model behaviour and the
simulation arenas' artifact and verification guarantees, see
[LemonSim](https://github.com/z80dev/lemon-sim). Nothing here
calls a model or touches a network.

For offline end-to-end native request/token/queue timings, session-start stage
breakdowns and nightly regression artifacts, see the
[latency budget and harness](latency-sla.md). Those protocol-path measurements
are separate from the primitive throughput suites on this page.

Everything below is reproducible with `mix lemon.bench`. The suites live in
[`bench/`](https://github.com/z80dev/lemon/tree/main/bench) and are about 700 lines total, so if a number looks
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
([`init_db/1`](../../apps/lemon_core/lib/lemon_core/store/sqlite_backend.ex) in `LemonCore.Store.SqliteBackend`).
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
| 10 | 2.29 ms | 229.5 µs | 1 | 1 per 10 |
| 100 | 0.24 ms | 2.45 µs | 10 | 1 per 10 |
| 1,000 | 1.23 ms | 1.23 µs | 100 | 1 per 10 |
| 10,000 | 38.6 ms | 3.86 µs | 1,000 | 1 per 10 |

The first row is cold start: spawning the coalescer under its DynamicSupervisor
dominates ten deltas. The steady state is a few microseconds per delta and a
**10:1 reduction in outbound API calls**, which is the number that keeps a bot
off a rate limit.

### The 100,000-character cliff, and the fix

The 10,000-delta row above used to read **5,004 ms** — 500 µs per delta — and
its coalescing ratio degraded to 1 dispatch per 13 deltas. This benchmark is
what found it.

`StreamCoalescer` capped its accumulated answer at 100,000 bytes via `cap_full_text/1`
([`LemonRouter.StreamCoalescer`](../../apps/lemon_router/lib/lemon_router/stream_coalescer.ex));
since #685 the cap is the coalescer's 65,536-byte ingress message budget.
It used to trim like this:

```elixir
String.slice(text, String.length(text) - keep, keep)
```

`String.length/1` and `String.slice/3` both walk the binary grapheme by
grapheme, so once an answer crossed the cap, **every subsequent delta re-walked
100,000 characters, twice**. The stalls also pushed flushes off the size
threshold and onto the `max_latency_ms` timer, which is why the dispatch ratio
degraded at the same time.

There was a second, quieter bug in the same line. The guard is
`byte_size(text) > 100_000`, but the arithmetic was in graphemes — so for
multi-byte text `String.length(text) - keep` went **negative**, and
`String.slice/3` reads a negative start as an offset from the end. It returned
the whole string. **The cap did not apply at all to any answer in a non-Latin
script or with heavy emoji**, which made it an unbounded memory path per run,
not merely a slow one. Feeding it 120,000 bytes of `€` returned all 120,000
bytes unchanged.

The trim is now byte-based — `binary_part/3` plus a UTF-8 continuation-byte
re-sync, since a byte-aligned cut can land inside a codepoint and produce a
binary that fails JSON encoding on the way to a channel.

| Accumulated answer | Grapheme trim (was) | Byte trim (now) |
| --- | ---: | ---: |
| 50k characters (below cap, no trim) | 0.40 µs | 0.40 µs |
| 100k characters (at cap) | **1.00 ms** | **0.79 µs** |
| 200k characters (above cap) | **3.45 ms** | **2.17 µs** |

About **1,600x** at 200k characters, and the end-to-end burst went from 5,004 ms
to 38.6 ms — a 130x improvement on the whole path, with the dispatch ratio back
to a clean 1 per 10.

Both algorithms stay in `bench/coalescer.exs` side by side, so if the numbers
ever converge the walk is back. Regression tests are in
[`stream_coalescer_test.exs`](../../apps/lemon_router/test/lemon_router/stream_coalescer_test.exs);
the multi-byte bound test is the load-bearing one, and it fails against the old
implementation.

### Per-operation cost

| Operation | Median |
| --- | ---: |
| `ingest_delta` (caller: registry lookup + cast) | 0.91 µs |
| `current_text` (call round-trip only) | 1.14 µs |
| `ingest_delta` + drain (caller + coalescer work) | 3.65 µs |

`ingest_delta` is a cast, so a producer can enqueue about twice as fast as the
coalescer drains. The buffer between them is an unbounded mailbox — worth
knowing before pointing a very fast local engine at one.

### Concurrent conversations

| Load | Wall clock | Throughput |
| --- | ---: | ---: |
| 100 sessions x 50 deltas | 2.8 ms | 1.76 M deltas/s |
| 1,000 sessions x 50 deltas | 25.1 ms | 1.99 M deltas/s |

A thousand simultaneous conversations, each with its own coalescer process,
buffer and timer, absorb fifty thousand deltas in about 25 ms. Throughput holds
up as sessions multiply because the work spreads across schedulers instead of
queueing behind one mailbox — the same effect that makes eight stores beat one.

### Tool status coalescer

`ToolStatusCoalescer` collapses tool lifecycle events into one editable
message. Its flushes are purely timer-driven (`idle_ms: 400`,
`max_latency_ms: 1200`) rather than size-driven, so absorbing a burst and
emitting one are measured separately.

| Tools | Lifecycle events | Absorb | Per event |
| ---: | ---: | ---: | ---: |
| 10 | 20 | 0.07 ms | 3.65 µs |
| 100 | 200 | 0.40 ms | 1.99 µs |
| 1,000 | 2,000 | 2.27 ms | 1.14 µs |

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
streaming run carries its accumulated text on its own heap, up to the
65,536-byte answer cap above, until it finalizes. Since #685 finalizing drops
that text and idle coalescers retire, so this population tracks live runs.

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

Suites: [`bench/store.exs`](https://github.com/z80dev/lemon/blob/main/bench/store.exs),
[`bench/bus.exs`](https://github.com/z80dev/lemon/blob/main/bench/bus.exs),
[`bench/coalescer.exs`](https://github.com/z80dev/lemon/blob/main/bench/coalescer.exs),
[`bench/process.exs`](https://github.com/z80dev/lemon/blob/main/bench/process.exs), with shared helpers in
[`bench/support.exs`](https://github.com/z80dev/lemon/blob/main/bench/support.exs).

Numbers on this page are from a single full run on 2026-08-10, except the
coalescer section, which was re-measured on the same machine later that day
after the answer-trim fix described above. If you re-run them and the ratios
hold but the absolutes differ, that is the expected outcome, and the ratios
were the point.

## Epic #543 local measurements (2026-11-16)

Candidate `abc566dcdb83f35d311fb9c2c66b889e3b6fcc9d`; pre-epic
`4d94b3c8e` checked out with `git worktree add /tmp/lemon-pre 4d94b3c8e`.
MacBook Pro Mac15,9, Apple M3 Max, 128 GB RAM, macOS 15.6, OTP 29
(ERTS 17.1.1), Elixir 1.20.5. These runs use the default 16 schedulers;
CPU benchmarks were serialized. Other host load was uncontrolled. These are
separate from the older Linux figures above.

### Mixed Store workload

Command on the candidate:
`MIX_ENV=test mix run --no-start apps/lemon_core/bench/store_workload.exs`.
The script does not exist at the pre-epic revision, but is explicitly
cross-revision compatible. Run the unchanged candidate script by absolute path
from the baseline checkout with
`MIX_ENV=test mix run --no-start "$CANDIDATE/apps/lemon_core/bench/store_workload.exs"`.
`CANDIDATE` denotes the candidate checkout, not a second copy of its BEAMs:
Mix compiled each checkout's test sources before its run.
Both runs use 16 workers, 500 iterations, 10,000 initial rows per table;
8,000 observations per operation, 24,000 Store-call observations.

| Metric | Pre-epic | Candidate |
| --- | ---: | ---: |
| Workload elapsed (ms) | 2176.126 | 1042.372 |
| Peak Store mailbox length | 27 | 24 |
| Store calls p50 / p99 (us) | 167 / 17271 | 241 / 18085 |
| Read p50 / p99 (us) | 200 / 18452 | 245 / 6691 |
| Write p50 / p99 (us) | 186 / 18481 | 252 / 18819 |
| History p50 / p99 (us) | 243 / 575 | 18 / 43 |
| Secret p50 / p99 (us) | 546 / 1105 | 253 / 18387 |
| Sweep/ping p50 / p99 (us) | 103 / 320 | 224 / 13585 |

The workload finished faster, but not every operation improved: Store-call
p50 and p99 and secret/sweep tails worsened. A single sequential run per
revision is not a statistically controlled effect estimate.

### Durable tool-intent overhead

Command: `mix run --no-start bench/tool_intent.exs`; 1,000 calls per class,
APFS temporary directory, synthetic 1,024-byte parameters, no actual tool effect.

| Class | Mean (us) | p50 / p95 / p99 (us) |
| --- | ---: | ---: |
| No effect / no intent | 0.06 | 0 / 0 / 0 |
| External effect / append + datasync | 193.34 | 142 / 357 / 621 |

Added mean: **193.28 us**. Zero integer-microsecond samples mean below the
clock resolution, not free execution. The pre-epic revision has neither this
benchmark nor the durable intent API, so it cannot run the same workload.

### EventStream transport and delta-byte model (#571 / #570)

Command:
`LEMON_EVENT_STREAM_BENCH=1 LEMON_BENCH_REVISION=$(git rev-parse HEAD) MIX_ENV=test mix run --no-start apps/lemon_ai/bench/event_stream.exs`.
Twenty measured batches after two warmups; 10,000 ordered 128-byte deltas.
Startup/teardown and payload creation are excluded.

| Transport | Batch p50 / p95 (us) | p50 per event (us) |
| --- | ---: | ---: |
| Raw mailbox | 1410 / 1661 | 0.141 |
| One EventStream | 20964 / 22888 | 2.096 |
| Two EventStreams with relay | 44546 / 58746 | 4.455 |

Ratios to raw mailbox p50: **14.87x / 31.59x**. The raw path does not
preserve EventStream backpressure, timeout, cancellation or subscription semantics.

The script is absent pre-epic but applies unchanged there. Baseline command
from that checkout:
`LEMON_EVENT_STREAM_BENCH=1 LEMON_BENCH_REVISION=$(git rev-parse HEAD) MIX_ENV=test mix run --no-start "$CANDIDATE/apps/lemon_ai/bench/event_stream.exs"`.
Baseline batch p50/p95 us: raw **1373/1559**, one stream **20150/24090**,
two streams **48185/58798**; ratios **14.68x/35.09x**. Candidate versus baseline
median changes were +814 us for one stream and −3639 us for two streams.
These small differences are not a demonstrated architectural speedup. The
delta-byte test is absent pre-epic; its old/new arithmetic arms are a model,
not a historical runtime benchmark.

Command:
`scripts/test path apps/lemon_ai/test/lemon_ai/stream_delta_benchmark_test.exs --include benchmark`
passed **1 test**. This is an arithmetic byte model, not allocator measurement:

| Argument bytes | Old materialized / sent bytes | New materialized / sent bytes |
| ---: | ---: | ---: |
| 51200 | 1305600 / 1356800 | 51200 / 51200 |
| 102400 | 5171200 / 5273600 | 102400 / 102400 |
| 204800 | 20582400 / 20787200 | 204800 / 204800 |

### Task worktree CoW warm build (#601)

Same-revision control/treatment at the candidate revision above, using the
production `CodingAgent.Tools.Task.Worktree.prepare/3` in `"none"` mode.
An isolated local clone kept the task worktrees and branches separate from
the main repository. Its ignored `_build` (164 MiB) and `deps` (43 MiB) were
seeded using APFS `cp -c -R`; only these two cache directories were allowlisted.
The mechanism probes CoW, checks Git-ignored eligibility and traverses the cache
against its entry/size/time guards; it is not just a direct `cp` stopwatch.

| Backend | Prepare (ms) | `mix deps.get --check-locked && mix compile` (ms) | Combined (ms) |
| --- | ---: | ---: | ---: |
| `:git_worktree` | 803.140 | 66053.169 | 66856.309 |
| `:auto` → observed `:cow` | 2450.438 | 18821.822 | 21272.260 |

Both builds exited zero. The cold child initially had neither cache; the CoW
child had both. Warming added 1647.298 ms preparation and reduced the subsequent
dependency/build command by 47231.347 ms (combined reduction 45584.049 ms).
One cold-then-warm sample is not a distribution; dependency download/network,
OS caches and incremental recompilation are included, and ordering favors the
warm arm. It was not a zero-work incremental build. The source fixture used
the supplied prepared development artifacts without an independent build
provenance attestation.

Command was `mix run --no-start bench/measure_cow_tmp.exs`; the temporary helper
set `Application.put_env(:coding_agent, :task_clone_directories, ["_build", "deps"])`,
selected `:task_workspace_backend` as `:git_worktree` then `:auto`, timed
`Worktree.prepare(fixture, generated_id, "none")` with `:timer.tc/1`,
then timed `System.cmd("sh", ["-c", "mix deps.get --check-locked && mix compile"],
cd: prepared.cwd)`. It checked cache presence/backend/build exit, removed
its own task worktrees/branches, and was discarded with the fixture.
Pre-epic has no CoW backend or this helper, so the feature-off candidate is the
comparison control; no historical warm-build improvement is claimed.
