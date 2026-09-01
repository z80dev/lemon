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

  alias LemonCore.Store
  alias LemonCore.{ChatStateStore, ProgressStore}
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache
  alias LemonCore.Store.Table

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

    test "a progress mapping is not readable after the backend refuses it", %{store: store} do
      scope = {:coherence, :progress}

      assert {:error, :backend_refused} =
               ProgressStore.put(store, scope, 42, "run_ghost")

      assert ProgressStore.get_run(store, scope, 42) == nil
      assert ReadCache.get(store, :progress, {scope, 42}) == nil
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
      # Registered before boot so the store mirrors it from init: a cached
      # table whose rows expire 48 hours after `started_at_ms`.
      :ok =
        Store.register_table(store, %Table{
          name: :sweep_runs,
          owner: __MODULE__,
          cached: true,
          retention: [max_age_ms: 48 * 60 * 60 * 1000, timestamp: :started_at_ms]
        })

      on_exit(fn -> Table.clear(store) end)
      start_store(store, backend: EtsBackend)

      ancient = System.system_time(:millisecond) - 72 * 60 * 60 * 1000
      :ok = Store.put(store, :sweep_runs, "job1", %{started_at_ms: ancient})
      assert %{started_at_ms: ^ancient} = Store.get(store, :sweep_runs, "job1")

      :ok = Store.sweep(store)

      assert Store.get(store, :sweep_runs, "job1") == nil,
             "the sweeper deleted the backend row but the cache kept serving it"

      assert Store.list(store, :sweep_runs) == []
      assert ReadCache.get(store, :sweep_runs, "job1") == nil
    end

    test "expired chat state is evicted from the cache, not just the backend" do
      store = start_store(unique(:coherence_chat_sweep), backend: EtsBackend)
      scope = {:coherence, :expiring}

      # A TTL in the past: the row is already expired when the sweeper sees it.
      :ok = ChatStateStore.put(store, scope, %{last_engine: "codex"})

      :sys.replace_state(Process.whereis(store), fn state ->
        expired = %{last_engine: "codex", expires_at: System.system_time(:millisecond) - 1_000}
        {:ok, backend_state} = state.backend.put(state.backend_state, :chat, scope, expired)
        ReadCache.put(state.read_cache, :chat, scope, expired)
        %{state | backend_state: backend_state}
      end)

      :ok = Store.sweep(store)

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

  describe "the store process is the cache's only writer" do
    # The behavioural tests above cover what a caller can observe. This one
    # pins the *reason* they hold, because the failure it guards against is
    # only visible to a second process reading during a drain window — two
    # rapid writes used to interleave as eager-1, eager-2, then the first
    # cast landing last and restoring the older value. Catching that
    # behaviourally needs a racing observer, and a racing observer that loses
    # the race passes vacuously or fails spuriously depending on machine load.
    # The invariant that makes the window impossible is structural, so assert
    # it structurally: no cache mutation outside the GenServer callbacks.
    test "no client-side code path mutates the read cache" do
      source = File.read!("lib/lemon_core/store.ex")

      {client_side, _server_side} =
        case String.split(source, "# GenServer Implementation", parts: 2) do
          [client, server] -> {client, server}
          [only] -> {only, ""}
        end

      mutations =
        Regex.scan(~r/ReadCache\.(put|delete)\(/, client_side)
        |> Enum.map(fn [_match, fun] -> fun end)

      assert mutations == [],
             "client-side ReadCache.#{Enum.join(Enum.uniq(mutations), "/")} call(s) found in " <>
               "the public API section of store.ex. A caller writing the mirror is what let a " <>
               "failed backend write serve a phantom and two rapid writes land out of order. " <>
               "Mutate the cache from the GenServer callbacks, after the backend confirms."
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
