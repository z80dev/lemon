defmodule LemonCore.RunStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{RunStore, Store}
  alias LemonCore.Store.EtsBackend

  defmodule FailFirstSessionIndexPutBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    defdelegate init(opts), to: EtsBackend

    @impl true
    def put(state, :sessions_index, key, value) do
      failure_key = {__MODULE__, :failed_session_index_put}

      if Process.get(failure_key, false) do
        EtsBackend.put(state, :sessions_index, key, value)
      else
        Process.put(failure_key, true)
        {:error, :injected_session_index_failure}
      end
    end

    def put(state, table, key, value), do: EtsBackend.put(state, table, key, value)

    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend

    @impl true
    defdelegate get(state, table, key), to: EtsBackend

    @impl true
    defdelegate delete(state, table, key), to: EtsBackend

    @impl true
    defdelegate list(state, table), to: EtsBackend
  end

  defp start_store(name, opts) do
    spec = Supervisor.child_spec({Store, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  test "appends, fetches, finalizes, and lists run history through the typed wrapper" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    run_id = "run_#{System.unique_integer([:positive])}"

    assert :ok =
             RunStore.append_event(run_id, %{
               type: :prompt,
               text: "hello",
               session_key: session_key
             })

    assert is_map(RunStore.get(run_id))

    assert :ok =
             RunStore.finalize(run_id, %{
               completed: %{ok: true, answer: "world"},
               prompt: "hello",
               session_key: session_key
             })

    assert eventually(fn ->
             Enum.any?(RunStore.history(session_key, limit: 10), fn {stored_run_id, _} ->
               stored_run_id == run_id
             end)
           end)
  end

  test "execution-only MCP credentials never persist in final summaries or event metadata" do
    run_id = "run_mcp_#{System.unique_integer([:positive])}"
    session_key = "agent:mcp:main"

    secret_meta = %{
      profile_id: "mcp",
      mcp_servers: [%{"name" => "bot", "headers" => %{"Authorization" => "Bearer runtime-only"}}]
    }

    assert :ok = RunStore.append_event(run_id, %{type: :started, meta: secret_meta})

    assert :ok =
             RunStore.finalize(run_id, %{
               session_key: session_key,
               meta: secret_meta,
               completed: %{ok: true, meta: %{"mcp_servers" => secret_meta.mcp_servers}}
             })

    record = RunStore.get(run_id)
    refute inspect(record) =~ "runtime-only"
    assert record.summary.meta == %{profile_id: "mcp"}
    assert record.summary.completed.meta == %{}
    refute inspect(record) =~ "mcp_servers"
  end

  test "a retry repairs a failed session index without double-counting the run" do
    store =
      start_store(:run_store_partial_finalize,
        backend: FailFirstSessionIndexPutBackend,
        cached_tables: [:sessions_index]
      )

    parent = self()
    hook = fn event -> send(parent, {:finalized, event.run_id}) end
    :ok = Store.register_finalize_run_hook(store, hook)
    on_exit(fn -> Store.unregister_finalize_run_hook(store, hook) end)

    run_id = "run-partial"
    session_key = "agent:partial:main"
    summary = %{session_key: session_key, completed: %{ok: true}}

    assert {:error, :injected_session_index_failure} =
             RunStore.finalize(store, run_id, summary)

    assert %{summary: ^summary} = Store.get(store, :runs, run_id)
    assert Store.get(store, :sessions_index, session_key) == nil
    refute_receive {:finalized, ^run_id}

    assert :ok = RunStore.finalize(store, run_id, summary)
    assert %{run_count: 1} = Store.get(store, :sessions_index, session_key)
    assert_receive {:finalized, ^run_id}

    # Record and index writes are idempotent. Hooks deliberately use
    # at-least-once delivery, so an explicit retry invokes them again.
    assert :ok = RunStore.finalize(store, run_id, summary)
    assert %{run_count: 1} = Store.get(store, :sessions_index, session_key)
    assert_receive {:finalized, ^run_id}

    assert [{^session_key, public_entry}] = RunStore.list_sessions(store)
    refute Map.has_key?(public_entry, :__recent_run_ids__)
  end

  test "the session index stays bounded across many runs while retries stay idempotent" do
    store = start_store(:run_store_bounded_index, backend: EtsBackend)
    session_key = "agent:bounded:main"
    runs = 10_000

    for i <- 1..runs do
      :ok = RunStore.finalize(store, "run-#{i}", %{session_key: session_key, n: i})
    end

    entry = Store.get(store, :sessions_index, session_key)
    assert %{run_count: ^runs} = entry

    # The idempotency marker must not grow with the session's lifetime: before
    # it was bounded, every run id ever finalized stayed in the entry, and the
    # entry was copied on every finalization and every cached read.
    assert length(entry.__recent_run_ids__) <= 32
    assert :erts_debug.flat_size(entry) < 1_000

    # A retry of a recent run is still a no-op for the index.
    assert :ok = RunStore.finalize(store, "run-#{runs}", %{session_key: session_key, n: runs})
    assert %{run_count: ^runs} = Store.get(store, :sessions_index, session_key)

    assert [{^session_key, %{run_count: ^runs} = public_entry}] = RunStore.list_sessions(store)
    refute Map.has_key?(public_entry, :__recent_run_ids__)
  end

  test "an entry carrying the old unbounded marker is migrated on the session's next run" do
    store = start_store(:run_store_legacy_index, backend: EtsBackend)
    session_key = "agent:legacy:main"

    :ok =
      Store.put(store, :sessions_index, session_key, %{
        session_key: session_key,
        agent_id: "legacy",
        origin: :unknown,
        created_at_ms: 1,
        updated_at_ms: 1,
        run_count: 3,
        __indexed_run_ids__: MapSet.new(["old-1", "old-2", "old-3"]),
        __legacy_run_count__: 0
      })

    assert [{^session_key, listed}] = RunStore.list_sessions(store)
    refute Map.has_key?(listed, :__indexed_run_ids__)
    refute Map.has_key?(listed, :__legacy_run_count__)

    assert :ok = RunStore.finalize(store, "new-1", %{session_key: session_key})

    entry = Store.get(store, :sessions_index, session_key)
    assert %{run_count: 4, __recent_run_ids__: ["new-1"]} = entry
    refute Map.has_key?(entry, :__indexed_run_ids__)
    refute Map.has_key?(entry, :__legacy_run_count__)
  end

  test "finalizing a run with a different summary fails without leaking the first summary" do
    store = start_store(:run_store_summary_conflict, backend: EtsBackend)

    original = %{session_key: "agent:one:main", prompt: "private original prompt"}
    conflicting = %{session_key: "agent:two:main", prompt: "replacement prompt"}

    assert :ok = RunStore.finalize(store, "run-conflict", original)

    assert {:error, {:already_finalized, "run-conflict"}} =
             RunStore.finalize(store, "run-conflict", conflicting)

    assert %{summary: ^original} = Store.get(store, :runs, "run-conflict")
  end

  defp eventually(fun, attempts \\ 500)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
