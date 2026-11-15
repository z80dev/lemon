# Run from the umbrella root: MIX_ENV=test mix run --no-start apps/lemon_core/bench/sqlite_sync.exs
# Reports microseconds (p50/p95), without thresholds or claims about other hosts.
alias Exqlite.Sqlite3
alias LemonCore.Store.SqliteBackend

path = Path.join(System.tmp_dir!(), "lemon_sync_bench_#{System.unique_integer([:positive])}.db")
{:ok, initial} = SqliteBackend.init(path: path, ephemeral_tables: [])

checkpoint = fn state ->
  {:ok, statement} = Sqlite3.prepare(state.conn, "PRAGMA wal_checkpoint(TRUNCATE)")

  try do
    {:row, [0, _, _]} = Sqlite3.step(state.conn, statement)
  after
    Sqlite3.release(state.conn, statement)
  end
end

report = fn label, samples ->
  sorted = Enum.sort(samples)
  n = length(sorted)

  IO.puts(
    "#{label}: p50=#{Enum.at(sorted, div(n, 2))}us p95=#{Enum.at(sorted, ceil(n * 0.95) - 1)}us n=#{n}"
  )
end

try do
  :ok = Sqlite3.execute(initial.conn, "PRAGMA wal_autocheckpoint=0")
  {:ok, state} = SqliteBackend.sync(initial)

  payload = %{
    state: :accepted,
    session_key: "agent:bench:main",
    prompt: String.duplicate("receipt ", 256)
  }

  for mode <- [:checkpoint, :sync] do
    samples =
      for iteration <- 1..30 do
        # 1,000 individually committed, roughly 2 KiB receipt rows; no auto-checkpoint.
        for key <- 1..1_000 do
          {:ok, _} =
            SqliteBackend.put(state, :run_receipts, key, Map.put(payload, :iteration, iteration))
        end

        wal_bytes = File.stat!(path <> "-wal").size

        {us, _} =
          :timer.tc(fn ->
            case mode do
              :checkpoint -> checkpoint.(state)
              :sync -> {:ok, _} = SqliteBackend.sync(state)
            end
          end)

        if iteration == 1, do: IO.puts("#{mode} realistic WAL bytes=#{wal_bytes}")
        us
      end

    report.("nonempty #{mode}", samples)
  end

  report.(
    "empty checkpoint",
    for _ <- 1..1_000 do
      {us, _} = :timer.tc(fn -> checkpoint.(state) end)
      us
    end
  )

  # Compare complete admission transactions, not just their final barrier.
  # Seed once outside timing so all three arms update an existing receipt row.
  receipt = %{
    run_id: "run_bench_receipt",
    session_key: "agent:bench:main",
    state: :accepted,
    effective_mode: :collect,
    target_run_id: "run_bench_receipt",
    accepted_at_ms: 1_800_000_000_000
  }

  for {label, synchronous, barrier?} <- [
        {"receipt NORMAL commit + TRUNCATE", "NORMAL", true},
        {"receipt FULL commit only", "FULL", false},
        {"receipt NORMAL commit only", "NORMAL", false}
      ] do
    :ok = Sqlite3.execute(state.conn, "PRAGMA synchronous=#{synchronous}")
    fullfsync = if synchronous == "FULL" and match?({:unix, :darwin}, :os.type()), do: 1, else: 0
    :ok = Sqlite3.execute(state.conn, "PRAGMA fullfsync=#{fullfsync}")
    {:ok, _} = SqliteBackend.put(state, :run_receipts, receipt.run_id, receipt)
    {:ok, _} = SqliteBackend.sync(state)

    {:ok, statement} = Sqlite3.prepare(state.conn, "PRAGMA fullfsync")

    try do
      {:row, [fullfsync]} = Sqlite3.step(state.conn, statement)
      IO.puts("#{label}: fullfsync=#{fullfsync} (1=on, 0=off), wal_autocheckpoint=0")
    after
      Sqlite3.release(state.conn, statement)
    end

    samples =
      for iteration <- 1..100 do
        value = %{receipt | accepted_at_ms: receipt.accepted_at_ms + iteration}

        {us, :ok} =
          :timer.tc(fn ->
            {:ok, _} = SqliteBackend.put(state, :run_receipts, receipt.run_id, value)

            if barrier? do
              {:ok, _} = SqliteBackend.sync(state)
            end

            :ok
          end)

        us
      end

    report.(label, samples)
    # Seal each arm outside timing; commit-only arms accumulate WAL frames.
    {:ok, _} = SqliteBackend.sync(state)
  end
after
  SqliteBackend.close(initial)
  Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
end
