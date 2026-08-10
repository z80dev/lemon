Code.require_file("support.exs", __DIR__)

# LemonCore.Store throughput.
#
# The store is a GenServer in front of a pluggable backend. That shape is the
# whole point of the benchmark: writes serialise through one process, reads
# either serialise with them or bypass the mailbox entirely via the ETS read
# cache. The numbers below are meant to show where each path lands, and what it
# costs to buy write concurrency by running more than one store.

alias LemonCore.Store

LemonBench.banner("LemonCore.Store")

sqlite_available? = Code.ensure_loaded?(Exqlite.Sqlite3)

unless sqlite_available? do
  IO.puts("""
  exqlite is not loadable — the SQLite scenarios will be skipped.
  Run from the umbrella root so the optional dependency is on the code path.
  """)
end

scratch = LemonBench.scratch_dir("store")

start_store! = fn name, backend, backend_opts ->
  {:ok, pid} =
    Store.start_link(
      name: name,
      backend: backend,
      backend_opts: backend_opts,
      # `:sessions_index` is the default cached table; naming it explicitly keeps
      # the benchmark honest if that default ever changes.
      cached_tables: [:sessions_index]
    )

  pid
end

ets_store = :bench_store_ets
_ = start_store!.(ets_store, Store.EtsBackend, [])

sqlite_store = :bench_store_sqlite

if sqlite_available? do
  _ = start_store!.(sqlite_store, Store.SqliteBackend, path: Path.join(scratch, "bench.sqlite3"))
end

# A payload shaped like what actually gets stored: a small map with a few string
# fields, not a bare integer. Serialisation cost is part of the answer.
value = fn i ->
  %{
    id: "run_#{i}",
    session_key: "telegram:acct:dm:#{i}",
    status: :running,
    updated_at: System.system_time(:millisecond),
    meta: %{model: "claude-fable-5", tokens: i}
  }
end

# Pre-seed keys so `get` measures a hit rather than a miss.
for i <- 1..1_000 do
  Store.put(ets_store, :bench_kv, "key_#{i}", value.(i))
  Store.put(ets_store, :sessions_index, "key_#{i}", value.(i))
  if sqlite_available?, do: Store.put(sqlite_store, :bench_kv, "key_#{i}", value.(i))
end

# ---------------------------------------------------------------------------
# Per-operation latency
# ---------------------------------------------------------------------------

single_op_jobs = %{
  "ets   put            (GenServer call)" => fn ->
    Store.put(:bench_store_ets, :bench_kv, "hot_key", %{n: 1})
  end,
  "ets   get            (GenServer call)" => fn ->
    Store.get(:bench_store_ets, :bench_kv, "key_500")
  end,
  "ets   get   cached   (ETS read cache)" => fn ->
    Store.get(:bench_store_ets, :sessions_index, "key_500")
  end,
  "ets   put_new        (GenServer call)" => fn ->
    Store.put_new(:bench_store_ets, :bench_kv, "key_500", %{n: 1})
  end
}

sqlite_jobs =
  if sqlite_available? do
    %{
      "sqlite put           (GenServer call)" => fn ->
        Store.put(:bench_store_sqlite, :bench_kv, "hot_key", %{n: 1})
      end,
      "sqlite get           (GenServer call)" => fn ->
        Store.get(:bench_store_sqlite, :bench_kv, "key_500")
      end,
      "sqlite put_new       (GenServer call)" => fn ->
        Store.put_new(:bench_store_sqlite, :bench_kv, "key_500", %{n: 1})
      end
    }
  else
    %{}
  end

IO.puts("\n--- single-operation latency ------------------------------------------\n")

Benchee.run(Map.merge(single_op_jobs, sqlite_jobs),
  time: 3,
  warmup: 1,
  print: [fast_warning: false]
)

# ---------------------------------------------------------------------------
# list/2 as a function of table size
# ---------------------------------------------------------------------------
#
# `list` returns every pair in a table. It is the operation most likely to
# surprise someone: it is cheap at a hundred rows and not cheap at ten thousand,
# on either backend.

for size <- [100, 1_000, 10_000] do
  table = :"bench_list_#{size}"

  for i <- 1..size do
    Store.put(ets_store, table, "key_#{i}", value.(i))
    if sqlite_available?, do: Store.put(sqlite_store, table, "key_#{i}", value.(i))
  end
end

IO.puts("\n--- list/2 by table size ----------------------------------------------\n")

list_jobs =
  for size <- [100, 1_000, 10_000], into: %{} do
    {"ets   list #{String.pad_leading(to_string(size), 6)} rows",
     fn ->
       Store.list(:bench_store_ets, :"bench_list_#{size}")
     end}
  end

list_jobs =
  if sqlite_available? do
    Enum.into(
      for size <- [100, 1_000, 10_000] do
        {"sqlite list #{String.pad_leading(to_string(size), 6)} rows",
         fn ->
           Store.list(:bench_store_sqlite, :"bench_list_#{size}")
         end}
      end,
      list_jobs
    )
  else
    list_jobs
  end

Benchee.run(list_jobs, time: 3, warmup: 1, print: [fast_warning: false])

# ---------------------------------------------------------------------------
# Concurrent write throughput: one store vs several
# ---------------------------------------------------------------------------
#
# Benchee above measures one operation at a time. This measures what happens
# when N processes write at once. A single store is a single mailbox, so adding
# writers cannot add write throughput — it can only add queueing. Running
# several store instances is how the design scales that, and the cost is that
# each instance owns a disjoint slice of the keyspace.

IO.puts("\n--- concurrent write throughput ----------------------------------------\n")

writers = 8
per_writer = 5_000
total = writers * per_writer

{ops, us} =
  LemonBench.throughput(writers, per_writer, fn w, i ->
    Store.put(:bench_store_ets, :bench_concurrent, {w, i}, %{n: i})
  end)

LemonBench.report("ets  1 store  / #{writers} writers", ops, us, total)

# Same load, spread across 8 stores — one per writer.
instances =
  for n <- 1..writers do
    name = :"bench_store_shard_#{n}"
    _ = start_store!.(name, Store.EtsBackend, [])
    name
  end

instance_tuple = List.to_tuple(instances)

{ops, us} =
  LemonBench.throughput(writers, per_writer, fn w, i ->
    Store.put(elem(instance_tuple, w - 1), :bench_concurrent, {w, i}, %{n: i})
  end)

LemonBench.report("ets  #{writers} stores / #{writers} writers", ops, us, total)

# Single writer for reference: no contention at all.
{ops, us} =
  LemonBench.throughput(1, per_writer, fn w, i ->
    Store.put(:bench_store_ets, :bench_concurrent, {:solo, w, i}, %{n: i})
  end)

LemonBench.report("ets  1 store  / 1 writer  (reference)", ops, us, per_writer)

# The cached read path takes no lock and touches no mailbox, so it is the one
# read that genuinely scales with cores.
{ops, us} =
  LemonBench.throughput(writers, per_writer, fn _w, _i ->
    Store.get(:bench_store_ets, :sessions_index, "key_500")
  end)

LemonBench.report("ets  cached get / #{writers} readers", ops, us, total)

{ops, us} =
  LemonBench.throughput(writers, per_writer, fn _w, _i ->
    Store.get(:bench_store_ets, :bench_kv, "key_500")
  end)

LemonBench.report("ets  uncached get / #{writers} readers", ops, us, total)

if sqlite_available? do
  {ops, us} =
    LemonBench.throughput(writers, 500, fn w, i ->
      Store.put(:bench_store_sqlite, :bench_concurrent, {w, i}, %{n: i})
    end)

  LemonBench.report("sqlite 1 store / #{writers} writers", ops, us, writers * 500)
end

File.rm_rf(scratch)
IO.puts("")
