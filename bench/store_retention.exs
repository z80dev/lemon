# Run from the umbrella root: MIX_ENV=test mix run --no-start bench/store_retention.exs
alias LemonCore.Store
alias LemonCore.Store.ReadCache

{:ok, store} = Store.start_link(name: :bench_retention, cached_tables: [])

{legacy_bytes, _} =
  Enum.reduce(1..10_000, {0, []}, fn i, {sum, events} ->
    events = [%{seq: i} | events]
    {sum + :erlang.external_size(%{events: events, summary: nil}), events}
  end)

{append_us, :ok} =
  :timer.tc(fn ->
    for i <- 1..10_000, do: Store.append_run_event(:bench_retention, "stream", %{seq: i})
    Store.ping(:bench_retention)
  end)

record = ReadCache.get(:bench_retention, :runs, "stream")
%{events: []} = record
%{events: events} = Store.get_run(:bench_retention, "stream")
IO.puts("10k events: #{append_us} µs; #{length(events)} events retained")

IO.puts(
  "Stored record ETF bytes: #{:erlang.external_size(record)} once vs #{legacy_bytes} cumulative rewrites (legacy model)"
)

for i <- 1..100_000 do
  :ok = Store.put(:bench_retention, :runs, "run-#{i}", %{events: [], summary: %{completed: %{}}})
end

:ok = Store.put(:bench_retention, :session_policies, "p", %{allow: true})
{:reader, backend, reader} = GenServer.call(store, :reader)

# The public API now refuses full runs scans. Compare the same backend read on
# either side of the Store boundary, including the old reply's mailbox copy.
scans = [
  legacy: fn -> GenServer.call(store, {:generic_fetch_all, :runs}) end,
  caller: fn -> backend.read_list(reader, :runs) end
]

for {label, read} <- scans do
  task =
    Task.async(fn ->
      for _ <- 1..32 do
        {:ok, rows} = read.()
        100_001 = length(rows)
      end
    end)

  Process.sleep(5)

  times =
    Enum.sort(
      for _ <- 1..1_000 do
        {us, %{allow: true}} =
          :timer.tc(fn -> Store.get(:bench_retention, :session_policies, "p") end)

        us
      end
    )

  Task.await(task, 30_000)

  IO.puts(
    "#{label} 100k-row scans: policy get p99 #{Enum.at(times, 989)} µs, max #{List.last(times)} µs"
  )
end

GenServer.stop(store)
