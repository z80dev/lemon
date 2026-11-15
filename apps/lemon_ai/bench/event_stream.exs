# Opt-in only; this file is outside ExUnit's test paths. Run from the umbrella root:
# LEMON_EVENT_STREAM_BENCH=1 MIX_ENV=test mix run --no-start apps/lemon_ai/bench/event_stream.exs
# Optionally set LEMON_BENCH_REVISION to the revision/worktree identifier being measured.
# No provider, application startup, external dependency or phase-2 implementation is used.

defmodule LemonAi.EventStreamBench do
  alias LemonAi.EventStream
  alias LemonAi.Types.AssistantMessage

  @events 10_000
  @samples 20
  @warmups 2
  @modes [:direct_send, :one_stream, :two_streams]

  def run do
    message = %AssistantMessage{stop_reason: :stop}
    delta = String.duplicate("x", 128)
    events = Enum.map(1..@events, &{:text_delta, &1, delta, message})

    IO.puts("""
    EventStream transport comparison (issue #570 / phase-2 measurement input)
    revision: #{System.get_env("LEMON_BENCH_REVISION", "not supplied")}
    recorded_at: #{DateTime.to_iso8601(DateTime.utc_now())}
    elixir: #{System.version()}  otp: #{System.otp_release()}
    architecture: #{:erlang.system_info(:system_architecture)}
    schedulers: #{System.schedulers_online()} online / #{System.schedulers()} total
    events/batch: #{@events}  delta bytes: 128  samples: #{@samples}  warmups: #{@warmups}

    direct_send: producer -> raw consumer mailbox
    one_stream: producer -> EventStream -> consumer
    two_streams: producer -> EventStream -> relay -> EventStream -> consumer

    All paths consume the same ordered events and terminal; delivery is checked.
    Timed: pushing/sending a batch through final consumption and relay completion.
    Excluded: payload construction, process startup and process teardown.
    EventStream queues fit the whole batch; idle/hard timers are disabled.
    Raw send is an unbounded lower-level baseline, NOT a replacement preserving
    backpressure, owner cancellation, result subscriptions or timeout semantics.
    These are local transport numbers, not model latency or a phase-2 decision.
    """)

    for _ <- 1..@warmups, mode <- @modes do
      measure(mode, events, message)
    end

    samples =
      Enum.reduce(1..@samples, Map.new(@modes, &{&1, []}), fn round, samples ->
        # Rotate execution order so each transport is measured first in some rounds.
        offset = rem(round - 1, length(@modes))
        modes = Enum.drop(@modes, offset) ++ Enum.take(@modes, offset)

        Enum.reduce(modes, samples, fn mode, samples ->
          elapsed = measure(mode, events, message)
          Map.update!(samples, mode, &[elapsed | &1])
        end)
      end)

    medians =
      Map.new(@modes, fn mode ->
        sorted = Enum.sort(Map.fetch!(samples, mode))
        p50 = Enum.at(sorted, ceil(@samples * 0.50) - 1)
        p95 = Enum.at(sorted, ceil(@samples * 0.95) - 1)

        IO.puts(
          "#{mode}: batch p50=#{p50}us p95=#{p95}us " <>
            "p50/event=#{Float.round(p50 / @events, 3)}us " <>
            "p95/event=#{Float.round(p95 / @events, 3)}us " <>
            "events/sec=#{round(@events * 1_000_000 / p50)}"
        )

        {mode, p50}
      end)

    for mode <- [:one_stream, :two_streams] do
      ratio = Map.fetch!(medians, mode) / Map.fetch!(medians, :direct_send)
      IO.puts("#{mode}/direct_send median batch ratio: #{Float.round(ratio, 2)}x")
    end
  end

  defp measure(:direct_send, events, message) do
    consumer = ready_task(fn -> receive_events(1, message) end)

    try do
      {elapsed, count} =
        :timer.tc(fn ->
          Enum.each(events, &send(consumer.pid, &1))
          send(consumer.pid, {:done, :stop, message})
          Task.await(consumer, 60_000)
        end)

      @events = count
      elapsed
    after
      stop_task(consumer)
    end
  end

  defp measure(mode, events, message) do
    source = start_stream()
    sink = if mode == :two_streams, do: start_stream(), else: source
    consumer = ready_task(fn -> consume_events(sink, message) end)

    relay =
      if mode == :two_streams do
        ready_task(fn ->
          source
          |> EventStream.events()
          |> Enum.each(fn
            {:done, :stop, ^message} -> :ok = EventStream.complete(sink, message)
            event -> :ok = EventStream.push(sink, event)
          end)
        end)
      end

    try do
      {elapsed, count} =
        :timer.tc(fn ->
          Enum.each(events, fn event -> :ok = EventStream.push(source, event) end)
          :ok = EventStream.complete(source, message)
          count = Task.await(consumer, 60_000)
          if relay, do: :ok = Task.await(relay, 60_000)
          count
        end)

      @events = count
      {:ok, ^message} = EventStream.result(source, 1_000)
      {:ok, ^message} = EventStream.result(sink, 1_000)
      elapsed
    after
      stop_task(consumer)
      if relay, do: stop_task(relay)
      GenServer.stop(source)
      if sink != source, do: GenServer.stop(sink)
    end
  end

  defp start_stream do
    {:ok, stream} =
      EventStream.start_link(
        owner: self(),
        max_queue: @events + 1,
        drop_strategy: :error,
        timeout: :infinity,
        idle_timeout: :infinity
      )

    stream
  end

  defp ready_task(fun) do
    parent = self()
    ready = make_ref()

    task =
      Task.async(fn ->
        send(parent, {ready, self()})
        fun.()
      end)

    receive do
      {^ready, pid} when pid == task.pid -> task
    after
      5_000 -> raise "benchmark task failed to start"
    end
  end

  defp receive_events(expected, message) do
    receive do
      {:text_delta, ^expected, _delta, ^message} -> receive_events(expected + 1, message)
      {:done, :stop, ^message} -> expected - 1
      other -> raise "unexpected direct-send event: #{inspect(other)}"
    after
      60_000 -> raise "direct-send consumer did not receive the terminal"
    end
  end

  defp consume_events(stream, message) do
    stream
    |> EventStream.events()
    |> Enum.reduce(1, fn
      {:text_delta, index, _delta, ^message}, expected when index == expected -> expected + 1
      {:done, :stop, ^message}, expected -> expected
      other, _expected -> raise "unexpected EventStream event: #{inspect(other)}"
    end)
    |> Kernel.-(1)
  end

  defp stop_task(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
  end
end

if System.get_env("LEMON_EVENT_STREAM_BENCH") == "1" do
  LemonAi.EventStreamBench.run()
else
  IO.puts("Set LEMON_EVENT_STREAM_BENCH=1 to run this opt-in transport benchmark.")
end
