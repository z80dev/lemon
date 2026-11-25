defmodule LemonCore.StoreCacheCoherenceTest do
  @moduledoc """
  The read cache must never claim something the backend does not have.

  `LemonCore.Store.ReadCache` is public ETS that reads consult without going
  through the store, so anything it holds is effectively the store's answer.
  These tests pin the invariant that makes that safe: the store process is the
  cache's only writer, and it writes only after the backend confirms.

  Each test here corresponds to a way that invariant was previously broken.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{ChatStateStore, Store}
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache

  defmodule RefusingBackend do
    @moduledoc """
    Accepts reads, refuses every write. Stands in for a full disk or a
    backend that has started returning errors.
    """
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(_state, _table, _key, _value), do: {:error, :backend_refused}

    @impl true
    def put_new(_state, _table, _key, _value), do: {:error, :backend_refused}

    @impl true
    def get(state, _table, _key), do: {:ok, nil, state}

    @impl true
    def delete(state, _table, _key), do: {:ok, state}

    @impl true
    def list(state, _table), do: {:ok, [], state}
  end

  defp start_store(name, opts) do
    spec = Supervisor.child_spec({Store, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  describe "a refused backend write leaves nothing behind in the cache" do
    setup do
      %{store: start_store(unique(:coherence_refusing), backend: RefusingBackend)}
    end

    test "chat state is not readable after the backend refuses it", %{store: store} do
      scope = {:coherence, :chat}

      assert {:error, :backend_refused} =
               ChatStateStore.put(store, scope, %{last_engine: "ghost"})

      assert ChatStateStore.get(store, scope) == nil
      assert ReadCache.get(store, :chat, scope) == nil
    end

    test "a registered cached table is not readable after the backend refuses it" do
      store = unique(:coherence_registered)
      # Registered before boot, the way an owning app registers its hot index.
      :ok = Store.register_cached_table(store, :hot_index)
      on_exit(fn -> Store.unregister_cached_table(store, :hot_index) end)
      start_store(store, backend: RefusingBackend)

      assert ReadCache.cached?(store, :hot_index)
      assert {:error, :backend_refused} = Store.put(store, :hot_index, {:scope, 42}, "run_ghost")

      assert Store.get(store, :hot_index, {:scope, 42}) == nil
      assert ReadCache.get(store, :hot_index, {:scope, 42}) == nil
    end

    test "a generic put into a mirrored table is not readable after refusal" do
      store = start_store(unique(:coherence_generic), backend: RefusingBackend)

      assert {:error, :backend_refused} = Store.put(store, :sessions_index, "k", %{v: 1})
      assert Store.get(store, :sessions_index, "k") == nil
      assert Store.list(store, :sessions_index) == []
    end
  end

  describe "sweeps evict what they delete" do
    test "a registered cached table does not keep serving swept rows" do
      store = unique(:coherence_sweep)
      # Registered before boot so the store mirrors it from init.
      :ok = Store.register_cached_table(store, :idempotency)
      on_exit(fn -> Store.unregister_cached_table(store, :idempotency) end)
      start_store(store, backend: EtsBackend)

      ancient = System.system_time(:millisecond) - 72 * 60 * 60 * 1000
      :ok = Store.put(store, :idempotency, "key1", %{"inserted_at_ms" => ancient})
      assert %{"inserted_at_ms" => ^ancient} = Store.get(store, :idempotency, "key1")

      send(Process.whereis(store), :sweep_expired)
      # The sweep runs in the store process; a call afterwards is the barrier.
      :ok = Store.ping(store)

      assert Store.get(store, :idempotency, "key1") == nil,
             "the sweeper deleted the backend row but the cache kept serving it"

      assert Store.list(store, :idempotency) == []
      assert ReadCache.get(store, :idempotency, "key1") == nil
    end

    test "the sweep never deletes cron runs; CronStore owns their retention" do
      store = start_store(unique(:coherence_cron_runs), backend: EtsBackend)
      ancient = System.system_time(:millisecond) - 72 * 60 * 60 * 1000
      running = %{status: :running, started_at_ms: ancient}
      unknown = %{status: :running, started_at_ms: ancient, meta: %{outcome_unknown: true}}
      :ok = Store.put(store, :cron_runs, "running", running)
      :ok = Store.put(store, :cron_runs, "unknown", unknown)

      send(Process.whereis(store), :sweep_expired)
      :ok = Store.ping(store)

      assert Store.get(store, :cron_runs, "running") == running
      assert Store.get(store, :cron_runs, "unknown") == unknown
    end

    test "expired chat state is evicted from the cache, not just the backend" do
      store = start_store(unique(:coherence_chat_sweep), backend: EtsBackend)
      scope = {:coherence, :expiring}

      # Already expired when the sweeper sees it, and mirrored by the write.
      expired = %{last_engine: "codex", expires_at: System.system_time(:millisecond) - 1_000}
      :ok = Store.put(store, :chat, scope, expired)
      assert ReadCache.get(store, :chat, scope) == expired

      send(Process.whereis(store), :sweep_expired)
      :ok = Store.ping(store)

      assert ReadCache.get(store, :chat, scope) == nil,
             "expired chat state stayed in the ETS mirror, which grows without bound"
    end
  end

  describe "read-after-write" do
    test "a chat-state write is visible to the next read", %{} do
      store = start_store(unique(:coherence_raw), backend: EtsBackend)
      scope = {:coherence, :raw}

      :ok = ChatStateStore.put(store, scope, %{last_engine: "one"})
      :ok = ChatStateStore.put(store, scope, %{last_engine: "two"})

      # No barrier: the write is synchronous, so the newest value is readable
      # immediately and an older one can never be applied on top of it.
      assert %{last_engine: "two"} = ChatStateStore.get(store, scope)
    end

    test "a rapid write sequence ends on the newest value", %{} do
      store = start_store(unique(:coherence_rapid), backend: EtsBackend)
      scope = {:coherence, :rapid}

      for i <- 1..50 do
        :ok = ChatStateStore.put(store, scope, %{seq: i})
        # No barrier anywhere in this loop: each write is applied before it
        # returns, so the mirror is never behind the caller.
        assert %{seq: ^i} = ChatStateStore.get(store, scope)
      end

      assert %{seq: 50} = ChatStateStore.get(store, scope)
    end

    test "a deleted chat state stays deleted", %{} do
      store = start_store(unique(:coherence_del), backend: EtsBackend)
      scope = {:coherence, :del}

      :ok = ChatStateStore.put(store, scope, %{last_engine: "one"})
      :ok = ChatStateStore.delete(store, scope)

      assert ChatStateStore.get(store, scope) == nil
    end
  end

  describe "mirrored tables are advertised only once they hold data" do
    test "a table registered at runtime is warm before reads trust it" do
      store = start_store(unique(:coherence_warm), backend: EtsBackend)

      # Written before the table is mirrored, so it exists only in the backend.
      :ok = Store.put(store, :late_index, "k", %{v: 1})
      assert Store.list(store, :late_index) == [{"k", %{v: 1}}]

      :ok = Store.register_cached_table(store, :late_index)
      on_exit(fn -> Store.unregister_cached_table(store, :late_index) end)

      # Now served from the mirror. If :cached_tables were published before the
      # warm, this would be [] — the table would look authoritative while empty.
      assert Store.list(store, :late_index) == [{"k", %{v: 1}}]
      assert Store.get(store, :late_index, "k") == %{v: 1}
    end
  end
end
