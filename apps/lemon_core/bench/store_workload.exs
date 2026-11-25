# Run unchanged on the base and candidate revisions:
# MIX_ENV=test mix run --no-start apps/lemon_core/bench/store_workload.exs
# Optional: STORE_WORKERS=16 STORE_ITERATIONS=500 STORE_ROWS=10000
# All databases and credentials are synthetic and confined to a fresh temp dir.
defmodule LemonCore.Bench.StoreWorkload do
  alias LemonCore.{RunHistoryStore, Secrets, Store}

  def run do
    for app <- [:crypto, :exqlite, :phoenix_pubsub], do: Application.ensure_all_started(app)

    root =
      Path.join(System.tmp_dir!(), "lemon-store-workload-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    env = "LEMON_STORE_BENCH_KEY"
    old_env = System.get_env(env)
    old_config = Application.get_env(:lemon_core, :secrets)
    System.put_env(env, Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, :secrets, key_providers: [:env], env_var: env)
    store = :store_workload
    history = :store_workload_history
    usage = Module.concat(Secrets, Usage)

    children = [
      LemonCore.Bus.child_spec_for_backend(),
      {Store,
       name: store,
       backend: LemonCore.Store.SqliteBackend,
       backend_opts: [path: Path.join(root, "store.sqlite3"), ephemeral_tables: []],
       run_history_provider: {RunHistoryStore, history}},
      {RunHistoryStore, name: history, path: Path.join(root, "history.sqlite3")}
    ]

    children = if Code.ensure_loaded?(usage), do: children ++ [usage], else: children
    runtime_cache = Module.concat(LemonCore, RuntimeCache)

    children =
      if Code.ensure_loaded?(runtime_cache), do: [runtime_cache | children], else: children

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    try do
      rows = integer_env("STORE_ROWS", 10_000)
      workers = integer_env("STORE_WORKERS", 16)
      iterations = integer_env("STORE_ITERATIONS", 500)
      now = System.system_time(:millisecond)

      for n <- 1..rows do
        :ok = Store.put(store, :chat, n, %{expires_at: now - 1})
        :ok = Store.put(store, :idempotency, n, %{"inserted_at_ms" => 0})
      end

      {:ok, _} = Secrets.set("bench", "synthetic-value", store: store)
      :ok = RunHistoryStore.put(history, "bench", now, "run", %{summary: %{}, events: []})
      # Owner mailbox barrier; do not use a direct ETS read as synchronization.
      :sys.get_state(history)
      {:ok, "synthetic-value"} = Secrets.get("bench", store: store)
      owner = Process.whereis(store)
      sampler = Task.async(fn -> sample(owner, 0) end)
      started = System.monotonic_time(:microsecond)

      samples =
        1..workers
        |> Task.async_stream(
          fn worker ->
            for n <- 1..iterations, op <- [:write, :read, :secret, :history, :sweep] do
              {elapsed, _} =
                :timer.tc(fn ->
                  case op do
                    :write ->
                      :ok = Store.put(store, :bench, {worker, n}, n)

                    :read ->
                      Store.get(store, :bench, {worker, n})

                    :secret ->
                      {:ok, "synthetic-value"} = Secrets.get("bench", store: store)

                    :history ->
                      history_read(store, history)

                    :sweep ->
                      if rem(n, 50) == 0, do: send(owner, :sweep_expired)
                      :ok = Store.ping(store)
                  end
                end)

              {op, elapsed}
            end
          end,
          max_concurrency: workers,
          timeout: :infinity,
          ordered: false
        )
        |> Enum.flat_map(fn {:ok, result} -> result end)

      duration = System.monotonic_time(:microsecond) - started
      send(sampler.pid, :stop)
      peak = Task.await(sampler)
      calls = for {op, us} <- samples, op in [:write, :read, :sweep], do: us

      IO.inspect(
        %{
          workers: workers,
          iterations: iterations,
          initial_rows_per_table: rows,
          elapsed_ms: duration / 1000,
          peak_store_message_queue_len: peak,
          store_calls_us: percentiles(calls),
          operations_us:
            Map.new(
              Enum.group_by(samples, &elem(&1, 0), &elem(&1, 1)),
              fn {op, values} -> {op, percentiles(values)} end
            )
        },
        label: "store_workload"
      )
    after
      Supervisor.stop(supervisor)
      File.rm_rf!(root)
      if old_env, do: System.put_env(env, old_env), else: System.delete_env(env)

      if old_config,
        do: Application.put_env(:lemon_core, :secrets, old_config),
        else: Application.delete_env(:lemon_core, :secrets)
    end
  end

  defp history_read(store, history) do
    # Select each revision's public path without compile-time obsolete-API calls.
    if function_exported?(Store, :get_run_history, 3),
      do: apply(Store, :get_run_history, [store, "bench", [limit: 10]]),
      else: RunHistoryStore.get(history, "bench", limit: 10)
  end

  defp sample(owner, peak) do
    {:message_queue_len, depth} = Process.info(owner, :message_queue_len)
    peak = max(peak, depth)

    receive do
      :stop -> peak
    after
      1 -> sample(owner, peak)
    end
  end

  defp percentiles(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      p50: Enum.at(sorted, div((count - 1) * 50, 100)),
      p99: Enum.at(sorted, div((count - 1) * 99, 100))
    }
  end

  defp integer_env(name, default) do
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value > 0 -> value
      _ -> raise ArgumentError, "#{name} must be a positive integer"
    end
  end
end

LemonCore.Bench.StoreWorkload.run()
