defmodule LemonCore.StoreRunsRetentionTest do
  @moduledoc """
  `:runs` is bounded and full-table reads leave the store process (#682).
  """

  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonCore.Store.{EtsBackend, Hooks, ReadCache, SqliteBackend}

  @moduletag :tmp_dir

  defmodule GatedReaderBackend do
    @moduledoc """
    ETS backend whose concurrent `read_list/2` waits for `:release` from the
    process named in the `:gate` persistent term before reading.
    """
    @behaviour LemonCore.Store.Backend

    @impl true
    defdelegate init(opts), to: EtsBackend
    @impl true
    defdelegate put(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate get(state, table, key), to: EtsBackend
    @impl true
    defdelegate delete(state, table, key), to: EtsBackend
    @impl true
    defdelegate list(state, table), to: EtsBackend
    @impl true
    defdelegate reader(state), to: EtsBackend

    @impl true
    def read_list(reader, table) do
      send(:persistent_term.get({__MODULE__, :gate}), {:reading, self()})

      receive do
        :release -> EtsBackend.read_list(reader, table)
      end
    end
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_store(opts) do
    name = Keyword.get_lazy(opts, :name, fn -> unique(:runs_retention) end)

    spec =
      Supervisor.child_spec(
        {Store,
         Keyword.merge([backend: EtsBackend, finalize_run_hooks: [], cached_tables: []], opts)
         |> Keyword.put(:name, name)},
        id: name
      )

    start_supervised!(spec)
    name
  end

  defp sweep(store) do
    send(Process.whereis(store), :sweep_expired)
    :ok = Store.ping(store)
  end

  describe "per-run event buffer" do
    test "appends keep the stored record and the buffer bounded" do
      store = start_store([])

      for i <- 1..2_500, do: Store.append_run_event(store, "run-big", %{seq: i})
      :ok = Store.ping(store)

      # The record is written once and never grows with its events.
      cached = ReadCache.get(store, :runs, "run-big")
      assert %{summary: nil} = cached
      refute Map.has_key?(cached, :events)
      assert :erlang.external_size(cached) < 200

      buffer = Hooks.published(store, :run_events, nil)
      # 2,000 events plus the run's counter.
      assert :ets.info(buffer, :size) == 2_001

      run = Store.get_run_with_events(store, "run-big")
      assert length(run.events) == 2_000
      assert run.events_dropped == 500
      # Newest first; the first 200 events survive next to the latest 1,800.
      assert hd(run.events) == %{seq: 2_500}
      assert List.last(run.events) == %{seq: 1}
      assert Enum.at(run.events, 1_799) == %{seq: 701}
      assert Enum.at(run.events, 1_800) == %{seq: 200}

      assert {:ok, summary} = Store.fetch_run(store, "run-big")
      refute Map.has_key?(summary, :events)

      assert %{events: [%{seq: 2_500} | _]} =
               Store.get_run_with_events(Process.whereis(store), "run-big")
    end

    test "finalization freezes events without copying them into the backend or cache" do
      store = start_store([])

      for i <- 1..3, do: Store.append_run_event(store, "run-1", %{seq: i})
      :ok = Store.finalize_run(store, "run-1", %{completed: %{ok: true}})

      assert %{events: [%{seq: 3}, %{seq: 2}, %{seq: 1}], summary: %{completed: %{ok: true}}} =
               Store.get_run_with_events(store, "run-1")

      refute Map.has_key?(Store.get_run(store, "run-1"), :events)
      assert {:ok, backend_record} = Store.fetch(store, :runs, "run-1")
      refute Map.has_key?(backend_record, :events)
      refute Map.has_key?(ReadCache.get(store, :runs, "run-1"), :events)
      assert :ets.info(Hooks.published(store, :run_events, nil), :size) == 4

      # Late events neither reopen nor grow a finalized run.
      Store.append_run_event(store, "run-1", %{seq: 4})
      :ok = Store.ping(store)
      assert length(Store.get_run_with_events(store, "run-1").events) == 3
      assert :ets.info(Hooks.published(store, :run_events, nil), :size) == 4
    end

    test "durable session history still has events after the buffer is swept", %{tmp_dir: path} do
      history = unique(:retained_history)
      start_supervised!({LemonCore.RunHistoryStore, name: history, path: path})

      store =
        start_store(
          runs_retention_ms: 1,
          finalize_run_hooks: [{LemonCore.RunHistoryStore, :handle_finalize_run, [history]}]
        )

      Store.append_run_event(store, "run-1", %{seq: 1})
      :ok = Store.finalize_run(store, "run-1", %{session_key: "agent:test:main"})
      Process.sleep(5)
      sweep(store)

      assert Store.get_run_with_events(store, "run-1") == nil

      assert [{"run-1", %{events: [%{seq: 1}]}}] =
               LemonCore.RunHistoryStore.get(history, "agent:test:main", [])
    end
  end

  describe "retention" do
    test "the sweep evicts finalized runs past retention and keeps live ones" do
      store = start_store(runs_retention_ms: 1)

      for i <- 1..50 do
        Store.append_run_event(store, "done-#{i}", %{seq: 1})
        :ok = Store.finalize_run(store, "done-#{i}", %{completed: %{ok: true}})
      end

      Store.append_run_event(store, "live", %{seq: 1})
      :ok = Store.ping(store)
      Process.sleep(5)
      sweep(store)

      assert :ets.info(ReadCache.tables(store).runs, :size) == 1
      assert :ets.info(Hooks.published(store, :run_events, nil), :size) == 2
      assert %{summary: nil, events: [%{seq: 1}]} = Store.get_run_with_events(store, "live")

      assert {:error, :evicted} = Store.fetch_run(store, "done-1")
      assert Store.get_run(store, "done-1") == nil
      assert {:ok, nil} = Store.fetch_run(store, "never-ran")

      # An evicted run stays finalized. An identical retry is safe but
      # publishes no new decision and cannot recreate the live record.
      Store.append_run_event(store, "done-1", %{seq: 2})
      :ok = Store.ping(store)
      assert {:error, :evicted} = Store.fetch_run(store, "done-1")

      assert :ok = Store.finalize_run(store, "done-1", %{completed: %{ok: true}})
      assert {:error, :evicted} = Store.fetch_run(store, "done-1")
    end

    test "runs inside retention are kept" do
      store = start_store([])
      :ok = Store.finalize_run(store, "recent", %{completed: %{ok: true}})
      sweep(store)
      assert {:ok, %{summary: %{completed: %{ok: true}}}} = Store.fetch_run(store, "recent")
    end

    test "finalization preserves a richer decision in the shared terminal table" do
      store = start_store([])
      Store.append_run_event(store, "run", %{seq: 1})
      :ok = Store.ping(store)
      :ok = Store.finalize_run(store, "run", %{completed: %{ok: true}})

      assert {:ok, %{digest: _, status: :completed} = decision} =
               Store.fetch(store, :run_terminals, "run")

      assert {:error, {:already_finalized, "run"}} =
               Store.finalize_run(store, "run", %{completed: %{ok: false}})

      assert {:ok, ^decision} = Store.fetch(store, :run_terminals, "run")
    end

    test "subsequent sweeps preserve the terminal fence" do
      store = start_store(runs_retention_ms: 1)
      :ok = Store.finalize_run(store, "gone", %{completed: %{ok: true}})
      Process.sleep(5)
      sweep(store)
      sweep(store)
      assert {:error, :evicted} = Store.fetch_run(store, "gone")
    end

    test "a restart that drops ephemeral :runs still reports a finalized run as evicted",
         %{tmp_dir: tmp_dir} do
      name = unique(:runs_restart)

      opts = [
        name: name,
        backend: SqliteBackend,
        backend_opts: [path: Path.join(tmp_dir, "store.sqlite3"), ephemeral_tables: [:runs]]
      ]

      start_store(opts)
      :ok = Store.finalize_run(name, "finished", %{completed: %{ok: true}})
      Store.append_run_event(name, "unfinished", %{seq: 1})
      :ok = Store.ping(name)

      stop_supervised!(name)
      start_store(opts)

      assert {:error, :evicted} = Store.fetch_run(name, "finished")
      assert {:ok, nil} = Store.fetch_run(name, "unfinished")
    end

    test "retention settings must be positive milliseconds" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _stack}} =
               Store.start_link(name: unique(:bad_retention), runs_retention_ms: 0)
    end
  end

  describe "reads outside the store process" do
    test ":runs cannot be read whole" do
      store = start_store([])

      for read <- [&Store.fetch_all/2, &Store.list/2, &Store.fetch_keys/2] do
        assert_raise ArgumentError, fn -> read.(store, :runs) end
      end

      assert_raise ArgumentError, fn -> Store.fetch_range(store, :runs, 0, 1) end
    end

    test "a full-table read in progress does not hold up other store callers" do
      store = start_store(backend: GatedReaderBackend)
      :ok = Store.put(store, :big_table, "k", "v")
      :ok = Store.put(store, :session_policies, "p", %{allow: true})
      :persistent_term.put({GatedReaderBackend, :gate}, self())
      on_exit(fn -> :persistent_term.erase({GatedReaderBackend, :gate}) end)

      scan = Task.async(fn -> Store.fetch_all(store, :big_table) end)
      assert_receive {:reading, reader}, 1_000

      # The scan is parked in the caller; the store still answers.
      assert Store.get(store, :session_policies, "p") == %{allow: true}
      :ok = Store.put(store, :big_table, "k2", "v2")

      send(reader, :release)
      assert {:ok, rows} = Task.await(scan)
      assert {"k", "v"} in rows
    end

    test "fetch_keys and fetch_range read the requested slice", %{tmp_dir: tmp_dir} do
      for backend_opts <- [
            [backend: EtsBackend],
            [backend: SqliteBackend, backend_opts: [path: Path.join(tmp_dir, "range.sqlite3")]]
          ] do
        store = start_store(backend_opts)

        :ok = Store.put(store, :usage_occurrences, "a", %{at_ms: 999})
        :ok = Store.put(store, :usage_occurrences, "b", %{at_ms: 1_000})
        :ok = Store.put(store, :usage_occurrences, "c", %{at_ms: 1_999})
        :ok = Store.put(store, :usage_occurrences, "d", %{at_ms: 2_000})
        :ok = Store.put(store, :usage_occurrences, "e", %{at_ms: nil})

        assert {:ok, rows} = Store.fetch_range(store, :usage_occurrences, 1_000, 2_000)
        assert rows |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["b", "c"]

        assert {:ok, rows} =
                 Store.fetch_range(store, :usage_occurrences, 1_000, 2_000, include_untimed: true)

        assert rows |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["b", "c", "e"]

        assert {:ok, keys} = Store.fetch_keys(store, :usage_occurrences)
        assert Enum.sort(keys) == ["a", "b", "c", "d", "e"]

        :ok = Store.put(store, :usage_records, "1970-01-01", %{})
        :ok = Store.put(store, :usage_records, "1970-01-02", %{})
        :ok = Store.put(store, :usage_records, "1970-01-03", %{})

        assert {:ok, [{"1970-01-02", %{}}]} =
                 Store.fetch_range(store, :usage_records, 86_400_000, 172_800_000)
      end
    end

    test "fetch_keys of a mirrored table answers from the read cache" do
      store = start_store(cached_tables: [:sessions_index])
      :ok = Store.put(store, :sessions_index, "agent:a:main", %{session_key: "agent:a:main"})
      :sys.suspend(store)

      try do
        assert {:ok, ["agent:a:main"]} = Store.fetch_keys(store, :sessions_index)
      after
        :sys.resume(store)
      end
    end

    test "an unavailable store is an error, not an empty table" do
      assert {:error, :store_unavailable} = Store.fetch_all(:runs_retention_missing, :anything)
      assert {:error, :store_unavailable} = Store.fetch_keys(:runs_retention_missing, :anything)

      assert {:error, :store_unavailable} =
               Store.fetch_range(:runs_retention_missing, :anything, 0, 1)
    end
  end
end
