defmodule LemonCore.RunStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{RunStore, Store}
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.Table

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

  test "declares the run-domain tables without changing their runtime path" do
    assert [runs, sessions_index] = RunStore.__store_tables__()

    assert %Table{
             name: :runs,
             owner: RunStore,
             cached: true,
             persistence: :ephemeral,
             retention: nil,
             version: 1
           } = runs

    assert %Table{
             name: :sessions_index,
             owner: RunStore,
             cached: true,
             persistence: :durable,
             retention: nil,
             version: 1
           } = sessions_index
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
    refute Map.has_key?(public_entry, :__indexed_run_ids__)
    refute Map.has_key?(public_entry, :__legacy_run_count__)
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

  defp eventually(fun, attempts \\ 20)

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
