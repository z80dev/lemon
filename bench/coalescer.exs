Code.require_file("support.exs", __DIR__)

# Stream and tool-status coalescers under burst.
#
# A model streams tokens far faster than any chat API will accept edits. The
# coalescers exist to absorb that: they take a burst of deltas and emit a much
# smaller number of `DeliveryIntent`s, bounded by `min_chars`, `idle_ms` and
# `max_latency_ms`. So the headline number here is not latency — it is the
# compression ratio, because that is what keeps the process off a rate limit.
#
# Everything downstream of the coalescer is stubbed. A benchmark that measured
# `LemonChannels.Dispatcher` talking to Telegram would be measuring Telegram.

alias LemonRouter.StreamCoalescer
alias LemonRouter.ToolStatusCoalescer

LemonBench.banner("LemonRouter coalescers")

defmodule BenchDispatcher do
  @moduledoc false

  # Counts dispatches so the suite can report a coalescing ratio, and returns
  # `:ok` immediately so the number reflects coalescer work only.

  def start do
    :ets.new(:bench_dispatch_counter, [:named_table, :public, :set])
    :ets.insert(:bench_dispatch_counter, {:count, 0})
    :ok
  end

  def reset, do: :ets.insert(:bench_dispatch_counter, {:count, 0})

  def count do
    [{:count, n}] = :ets.lookup(:bench_dispatch_counter, :count)
    n
  end

  def dispatch(_intent) do
    :ets.update_counter(:bench_dispatch_counter, :count, 1)
    :ok
  end
end

BenchDispatcher.start()
Application.put_env(:lemon_router, :dispatcher, BenchDispatcher)

# The coalescers broadcast a `:coalesced_output` event on every flush when the
# Bus is up. Leaving it up keeps the flush cost honest.
Application.put_env(:lemon_core, :bus_backend, :registry)
{:ok, _} = Registry.start_link(keys: :duplicate, name: LemonCore.Bus.Registry)

{:ok, _} = Registry.start_link(keys: :unique, name: LemonRouter.CoalescerRegistry)
{:ok, _} = Registry.start_link(keys: :unique, name: LemonRouter.ToolStatusRegistry)

{:ok, _} =
  DynamicSupervisor.start_link(strategy: :one_for_one, name: LemonRouter.CoalescerSupervisor)

{:ok, _} =
  DynamicSupervisor.start_link(strategy: :one_for_one, name: LemonRouter.ToolStatusSupervisor)

channel_id = "telegram"

session_key = fn n ->
  "agent:bench:#{channel_id}:default:dm:#{n}"
end

# A delta the size of a typical streamed token chunk.
delta_text = "the quick brown fox "

# `ingest_delta` is a cast, so sending returns before the coalescer has done
# anything. A `call` afterwards lands behind every queued cast in the same
# mailbox, so it returns only once the burst has been fully processed — that is
# what makes this an end-to-end burst measurement rather than an enqueue timer.
drain = fn sk, run_id ->
  StreamCoalescer.current_text(sk, channel_id, run_id)
end

burst = fn sk, run_id, count ->
  for seq <- 1..count do
    StreamCoalescer.ingest_delta(sk, channel_id, run_id, seq, delta_text)
  end

  drain.(sk, run_id)
end

IO.puts("""
--- stream coalescer: burst absorption ---------------------------------

Each delta is #{String.length(delta_text)} characters. Defaults are
min_chars=200, idle_ms=800, max_latency_ms=3000, so a flush is expected
roughly every #{div(200, String.length(delta_text))} deltas.

deltas    total ms    per delta    dispatches    chars in    chars out
""")

for count <- [10, 100, 1_000, 10_000] do
  sk = session_key.("burst_#{count}")
  run_id = "run_#{count}_#{System.unique_integer([:positive])}"
  BenchDispatcher.reset()

  {us, _} = :timer.tc(fn -> burst.(sk, run_id, count) end)

  dispatches = BenchDispatcher.count()
  chars_in = count * String.length(delta_text)

  IO.puts(
    String.pad_leading(to_string(count), 6) <>
      String.pad_leading(LemonBench.num(us / 1000, 2), 12) <>
      String.pad_leading(LemonBench.num(us / count, 2) <> " us", 13) <>
      String.pad_leading(to_string(dispatches), 14) <>
      String.pad_leading(to_string(chars_in), 12) <>
      String.pad_leading(
        if(dispatches > 0, do: "1 per #{div(count, dispatches)} deltas", else: "-"),
        22
      )
  )
end

IO.puts("""

A dispatch carries the full text so far, not the increment, so "chars out"
is deliberately not reported as a byte saving — the win is in the number of
API calls, which is the column that matters.

The 10,000-delta row used to read 5,004 ms at 1 dispatch per 13 deltas: past
100k characters the answer trim walked the whole buffer per delta, and the
resulting stalls pushed flushes onto the max_latency timer. See below.
""")

# ---------------------------------------------------------------------------
# Why the answer trim is byte-based
# ---------------------------------------------------------------------------
#
# `StreamCoalescer.cap_full_text/1` trims the accumulated answer to
# `@max_full_text` (100,000). It used to do that with
# `String.slice(text, String.length(text) - keep, keep)`; both `String.length/1`
# and `String.slice/3` walk the binary grapheme by grapheme, so once an answer
# crossed the cap every delta re-walked 100k characters twice. It now trims with
# `binary_part/3` plus a UTF-8 continuation-byte re-sync.
#
# Both algorithms are measured side by side. The grapheme version is kept here
# as a guard: if the numbers ever converge, the walk is back.

IO.puts("--- answer trim: grapheme (removed) vs byte (current) ------------------\n")

grapheme_trim = fn chars ->
  base = String.duplicate("x", chars)
  keep = 100_000

  fn ->
    text = base <> delta_text

    if byte_size(text) > keep do
      String.slice(text, String.length(text) - keep, keep)
    else
      text
    end
  end
end

# Fixtures are built outside the measured function: `String.duplicate/2` at
# 200k characters costs far more than the operation under test, and including
# it would understate the gap.
byte_trim = fn chars ->
  base = String.duplicate("x", chars)
  keep = 100_000

  drop_partial = fn
    <<byte, rest::binary>> = bin, drop_partial ->
      if byte in 0x80..0xBF, do: drop_partial.(rest, drop_partial), else: bin

    bin, _drop_partial ->
      bin
  end

  fn ->
    text = base <> delta_text

    if byte_size(text) > keep do
      text
      |> binary_part(byte_size(text) - keep, keep)
      |> drop_partial.(drop_partial)
    else
      text
    end
  end
end

Benchee.run(
  %{
    "grapheme trim  answer 100k chars (at cap)" => grapheme_trim.(100_000),
    "grapheme trim  answer 200k chars (above cap)" => grapheme_trim.(200_000),
    "byte trim      answer 100k chars (at cap)" => byte_trim.(100_000),
    "byte trim      answer 200k chars (above cap)" => byte_trim.(200_000),
    "either         answer 50k chars (below cap, no trim)" => byte_trim.(50_000)
  },
  time: 2,
  warmup: 1,
  print: [fast_warning: false]
)

IO.puts("""

The grapheme trim also failed to bound multi-byte text at all: its
`String.length(text) - keep` went negative, which `String.slice/3` reads as an
offset from the end, so it returned the whole string and the answer grew
without limit. The byte trim caps bytes, which is what the guard already
measured. Regression tests live in
apps/lemon_router/test/lemon_router/stream_coalescer_test.exs.
""")

# ---------------------------------------------------------------------------
# Per-delta cost, split into its two halves
# ---------------------------------------------------------------------------

# Each scenario gets its own coalescer. Sharing one is a trap: `ingest_delta`
# is a cast, so the cast-only scenario enqueues faster than the coalescer
# drains and leaves millions of messages in the mailbox. A later scenario's
# first `call` then lands behind that backlog and reports seconds — which
# measures the queue left by the previous scenario, not the operation.
cast_sk = session_key.("percall_cast")
drain_sk = session_key.("percall_drain")
call_sk = session_key.("percall_call")
seq = :counters.new(1, [])

# Benchee runs these millions of times against one coalescer. Left alone, the
# accumulated answer would sail past the 100k character cap measured below and
# every later iteration would pay the cliff, so the reported "cost per delta"
# would really be "cost of running one absurdly long answer". Rotating the
# run_id every 500 deltas keeps the buffer at a realistic answer length; the
# cliff is measured deliberately and separately.
warm_run = fn n -> "run_warm_#{div(n, 500)}" end

next_delta = fn ->
  :counters.add(seq, 1, 1)
  n = :counters.get(seq, 1)
  {warm_run.(n), rem(n, 500) + 1}
end

for sk <- [cast_sk, drain_sk, call_sk] do
  StreamCoalescer.ingest_delta(sk, channel_id, warm_run.(0), 1, delta_text)
  drain.(sk, warm_run.(0))
end

IO.puts("--- per-operation cost -------------------------------------------------\n")

Benchee.run(
  %{
    "ingest_delta   (caller side: registry lookup + cast)" => fn ->
      {run, n} = next_delta.()
      StreamCoalescer.ingest_delta(cast_sk, channel_id, run, n, delta_text)
    end,
    "ingest_delta + drain  (caller + coalescer work)" => fn ->
      {run, n} = next_delta.()
      StreamCoalescer.ingest_delta(drain_sk, channel_id, run, n, delta_text)
      drain.(drain_sk, run)
    end,
    "current_text   (call round-trip only)" => fn ->
      drain.(call_sk, warm_run.(0))
    end
  },
  time: 3,
  warmup: 1,
  print: [fast_warning: false]
)

IO.puts("""
The gap between the first two rows is the coalescer's own work per delta.
`ingest_delta` is a cast, so a producer can enqueue faster than the coalescer
drains — the buffer between them is an unbounded mailbox, which is worth
knowing before pointing a very fast engine at one.
""")

# ---------------------------------------------------------------------------
# Many concurrent conversations
# ---------------------------------------------------------------------------
#
# One coalescer per session/channel pair means a thousand simultaneous
# conversations are a thousand processes, each with its own buffer and timer.
# This is the shape the BEAM is supposed to be good at, so it is worth a number.

IO.puts("\n--- concurrent conversations -------------------------------------------\n")

for sessions <- [100, 1_000] do
  BenchDispatcher.reset()
  deltas_each = 50

  {us, _} =
    :timer.tc(fn ->
      tasks =
        for s <- 1..sessions do
          Task.async(fn ->
            sk = session_key.("concurrent_#{sessions}_#{s}")
            run_id = "run_c_#{s}"
            burst.(sk, run_id, deltas_each)
          end)
        end

      Task.await_many(tasks, 120_000)
    end)

  total = sessions * deltas_each

  IO.puts(
    String.pad_trailing("#{sessions} sessions x #{deltas_each} deltas", 40) <>
      String.pad_leading(LemonBench.num(us / 1000, 1) <> " ms", 12) <>
      String.pad_leading(LemonBench.fmt_ops(total * 1_000_000 / us) <> " deltas/s", 24) <>
      String.pad_leading("#{BenchDispatcher.count()} dispatches", 20)
  )
end

# ---------------------------------------------------------------------------
# Tool status coalescer
# ---------------------------------------------------------------------------
#
# Same idea, different shape: tool lifecycle events collapse into one editable
# "Tool calls" message rather than a text buffer.

IO.puts("\n--- tool status coalescer ----------------------------------------------\n")

action_event = fn id, status ->
  %{
    action: %{
      kind: :tool,
      id: "tool_#{id}",
      title: "Read",
      status: status,
      detail: %{path: "lib/lemon_core/store.ex"}
    }
  }
end

IO.puts("""
Its flushes are purely timer-driven (idle_ms=400, max_latency_ms=1200) rather
than size-driven, so absorbing a burst and emitting one are measured
separately: "absorb" is the time to take all the events in, "to flush" is the
extra wall-clock wait before the first dispatch appears.

                                          absorb     per event      to flush   dispatches
""")

await_dispatch = fn timeout_ms ->
  deadline = System.monotonic_time(:millisecond) + timeout_ms

  wait = fn wait ->
    cond do
      BenchDispatcher.count() > 0 -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> wait.(wait)
    end
  end

  wait.(wait)
end

for count <- [10, 100, 1_000] do
  sk = session_key.("tools_#{count}")
  run_id = "run_tools_#{count}"
  BenchDispatcher.reset()

  {us, _} =
    :timer.tc(fn ->
      for i <- 1..count do
        ToolStatusCoalescer.ingest_action(sk, channel_id, run_id, action_event.(i, :running))
        ToolStatusCoalescer.ingest_action(sk, channel_id, run_id, action_event.(i, :completed))
      end

      # `ingest_action` casts; a call on the same mailbox lands behind the
      # whole burst, so this returns only once every event has been absorbed.
      case Registry.lookup(LemonRouter.ToolStatusRegistry, {sk, channel_id, :status}) do
        [{pid, _}] -> :sys.get_state(pid)
        _ -> :ok
      end
    end)

  {flush_us, _} = :timer.tc(fn -> await_dispatch.(3_000) end)

  events = count * 2

  IO.puts(
    String.pad_trailing("#{count} tools (#{events} lifecycle events)", 40) <>
      String.pad_leading(LemonBench.num(us / 1000, 2) <> " ms", 12) <>
      String.pad_leading(LemonBench.num(us / events, 2) <> " us", 14) <>
      String.pad_leading(LemonBench.num(flush_us / 1000, 0) <> " ms", 14) <>
      String.pad_leading(to_string(BenchDispatcher.count()), 12)
  )
end

IO.puts("")
