Code.require_file("support.exs", __DIR__)

# LemonCore.Bus fanout.
#
# The Bus has two backends: `Phoenix.PubSub` when phoenix_pubsub is on the code
# path, and a duplicate-key `Registry` when it is not. They are supposed to
# behave identically on the local node, so the interesting question is what the
# fallback costs — and how either one degrades as a topic collects subscribers,
# which is what happens when a run fans out to a web UI, a channel adapter and
# a set of telemetry listeners at once.
#
# Two different numbers are reported per configuration:
#
#   * publisher cost — how long `broadcast/2` blocks the calling process.
#   * fanout latency — how long until the last subscriber has *processed* the
#     message. This is the number that matters for "did the UI update", and it
#     is always the larger of the two.

alias LemonCore.Bus

LemonBench.banner("LemonCore.Bus")

pubsub_available? = Code.ensure_loaded?(Phoenix.PubSub)

if pubsub_available? do
  # The PG2 adapter joins a `:pg` scope owned by the phoenix_pubsub
  # application, which `--no-start` leaves down.
  {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
  {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: LemonCore.PubSub)
else
  IO.puts("phoenix_pubsub is not loadable — only the Registry fallback will be measured.\n")
end

{:ok, _} = Registry.start_link(keys: :duplicate, name: LemonCore.Bus.Registry)

event = %LemonCore.Events.RunStarted{
  run_id: "run_bench_0001",
  session_key: "telegram:acct:dm:42",
  engine: "claude_code"
}

# Spawns `n` processes subscribed to `topic`. Each bumps an atomic counter when
# a message lands, which lets the publisher detect completion without adding a
# mailbox of its own to the measurement.
spawn_subscribers = fn topic, n, counter ->
  parent = self()

  pids =
    for _ <- 1..n do
      spawn_link(fn ->
        Bus.subscribe(topic)
        send(parent, {:subscribed, self()})

        recv = fn recv ->
          receive do
            :stop ->
              :ok

            _msg ->
              :atomics.add(counter, 1, 1)
              recv.(recv)
          end
        end

        recv.(recv)
      end)
    end

  for pid <- pids do
    receive do
      {:subscribed, ^pid} -> :ok
    after
      5_000 -> raise "subscriber failed to subscribe"
    end
  end

  pids
end

await_count = fn counter, target ->
  wait = fn wait ->
    if :atomics.get(counter, 1) >= target do
      :ok
    else
      :erlang.yield()
      wait.(wait)
    end
  end

  wait.(wait)
end

percentile = fn sorted, p ->
  idx = max(0, min(length(sorted) - 1, round(p / 100 * length(sorted)) - 1))
  Enum.at(sorted, idx)
end

# Sampled in nanoseconds: a single broadcast to one subscriber is faster than
# microsecond resolution can express, and rounding it to "0 μs" would be a
# flattering way of saying "we did not measure it".
measure_fanout = fn topic, subs, counter, iterations ->
  samples =
    for _ <- 1..iterations do
      :atomics.put(counter, 1, 0)

      {ns, :ok} =
        :timer.tc(
          fn ->
            Bus.broadcast(topic, event)
            await_count.(counter, subs)
            :ok
          end,
          :nanosecond
        )

      ns
    end

  sorted = Enum.sort(samples)
  {percentile.(sorted, 50), percentile.(sorted, 99)}
end

measure_publish = fn topic, iterations ->
  samples =
    for _ <- 1..iterations do
      {ns, :ok} = :timer.tc(fn -> Bus.broadcast(topic, event) end, :nanosecond)
      ns
    end

  sorted = Enum.sort(samples)
  {percentile.(sorted, 50), percentile.(sorted, 99)}
end

backends =
  [:registry] ++ if(pubsub_available?, do: [:pubsub], else: [])

subscriber_counts = [1, 10, 100, 1_000]

IO.puts("""
--- broadcast cost by subscriber count ---------------------------------

publish = time for broadcast/2 to return to the caller
fanout  = time until the last of N subscribers has processed the message
values are microseconds, median (p99), 2000 iterations each
""")

IO.puts(
  String.pad_trailing("backend", 12) <>
    String.pad_leading("subs", 6) <>
    String.pad_leading("publish p50", 14) <>
    String.pad_leading("publish p99", 14) <>
    String.pad_leading("fanout p50", 14) <>
    String.pad_leading("fanout p99", 14)
)

IO.puts(String.duplicate("-", 74))

for backend <- backends, subs <- subscriber_counts do
  Application.put_env(:lemon_core, :bus_backend, backend)
  ^backend = Bus.backend()

  topic = "bench:#{backend}:#{subs}:#{System.unique_integer([:positive])}"
  counter = :atomics.new(1, [])
  pids = spawn_subscribers.(topic, subs, counter)

  # Warm the path before sampling.
  :atomics.put(counter, 1, 0)
  Bus.broadcast(topic, event)
  await_count.(counter, subs)

  {pub_p50, pub_p99} = measure_publish.(topic, 2_000)
  {fan_p50, fan_p99} = measure_fanout.(topic, subs, counter, 2_000)

  us = fn ns -> LemonBench.num(ns / 1000, 2) end

  IO.puts(
    String.pad_trailing(to_string(backend), 12) <>
      String.pad_leading(to_string(subs), 6) <>
      String.pad_leading(us.(pub_p50), 14) <>
      String.pad_leading(us.(pub_p99), 14) <>
      String.pad_leading(us.(fan_p50), 14) <>
      String.pad_leading(us.(fan_p99), 14)
  )

  for pid <- pids, do: send(pid, :stop)
end

# ---------------------------------------------------------------------------
# Typed events vs raw terms
# ---------------------------------------------------------------------------
#
# `broadcast_event/4` looks the payload's type up in `LemonCore.Events` and
# raises on a mismatch in dev and test. That check is not free, and it is worth
# knowing what it costs before deciding to route everything through it.

IO.puts("\n--- typed event overhead (10 subscribers) ------------------------------\n")

Application.put_env(:lemon_core, :bus_backend, :registry)
typed_topic = "bench:typed:#{System.unique_integer([:positive])}"
typed_counter = :atomics.new(1, [])
typed_pids = spawn_subscribers.(typed_topic, 10, typed_counter)

Benchee.run(
  %{
    "broadcast/2         raw map" => fn ->
      Bus.broadcast(typed_topic, %{type: :run_started, run_id: "r"})
    end,
    "broadcast/2         struct" => fn ->
      Bus.broadcast(typed_topic, event)
    end,
    "broadcast_event/4   registered type (checked)" => fn ->
      Bus.broadcast_event(typed_topic, :run_started, event)
    end,
    "broadcast_event/4   unregistered type" => fn ->
      Bus.broadcast_event(typed_topic, :bench_unregistered, %{n: 1})
    end
  },
  time: 3,
  warmup: 1,
  print: [fast_warning: false]
)

for pid <- typed_pids, do: send(pid, :stop)
IO.puts("")
