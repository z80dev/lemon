defmodule LemonCore.StoreHooksTest do
  @moduledoc """
  The store is a storage primitive: collaborators attach through hooks and
  registered cached tables rather than being named in the store's hot path.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonCore.{ChatStateStore, RunStore}
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache

  defp start_store(name, opts) do
    spec = Supervisor.child_spec({Store, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  # `finalize/3` is synchronous: when it returns, the record is written and
  # every hook has run in this process.
  defp finalize(store, run_id, summary) do
    :ok = RunStore.finalize(store, run_id, summary)
  end

  defp register_hook(store, hook) do
    :ok = RunStore.register_finalize_hook(store, hook)
    on_exit(fn -> RunStore.unregister_finalize_hook(store, hook) end)
  end

  describe "finalize hooks" do
    test "registered hooks receive the finalized run" do
      parent = self()
      hook = fn event -> send(parent, {:hook_fired, event}) end

      store = start_store(:store_hooks_configured, backend: EtsBackend)
      register_hook(store, hook)

      :ok = RunStore.append_event(store, "run_cfg", %{type: :started})
      finalize(store, "run_cfg", %{session_key: "agent:hooks:main", agent_id: "hooks"})

      assert_receive {:hook_fired, event}
      assert event.store == store
      assert event.run_id == "run_cfg"
      assert event.session_key == "agent:hooks:main"
      assert event.summary.agent_id == "hooks"
      assert %{events: [%{type: :started}]} = event.record
      assert is_integer(event.started_at)
    end

    test "hooks registered at runtime fire, and stop firing once removed" do
      parent = self()
      hook = fn event -> send(parent, {:runtime_hook, event.run_id}) end
      store = start_store(:store_hooks_runtime, backend: EtsBackend)

      on_exit(fn -> RunStore.unregister_finalize_hook(:store_hooks_runtime, hook) end)

      :ok = RunStore.register_finalize_hook(store, hook)
      finalize(store, "run_1", %{session_key: "agent:runtime:main"})
      assert_receive {:runtime_hook, "run_1"}

      :ok = RunStore.unregister_finalize_hook(store, hook)
      finalize(store, "run_2", %{session_key: "agent:runtime:main"})
      refute_receive {:runtime_hook, "run_2"}
    end

    test "hooks run in order and a failing hook does not stop the others" do
      parent = self()
      first = fn _event -> send(parent, {:order, :first}) end
      boom = fn _event -> raise "hook exploded" end
      last = fn _event -> send(parent, {:order, :last}) end

      store = start_store(:store_hooks_isolation, backend: EtsBackend)
      Enum.each([first, boom, last], &register_hook(store, &1))

      log =
        capture_log(fn ->
          finalize(store, "run_boom", %{session_key: "agent:isolation:main"})
        end)

      assert_receive {:order, :first}
      assert_receive {:order, :last}
      assert log =~ "hook exploded"
      # The store survived the failing hook.
      assert Store.ping(store) == :ok
    end

    test "runs without a session key do not fire hooks" do
      parent = self()
      hook = fn event -> send(parent, {:hook_fired, event}) end

      store = start_store(:store_hooks_no_session, backend: EtsBackend)
      register_hook(store, hook)

      finalize(store, "run_orphan", %{agent_id: "nobody"})
      refute_receive {:hook_fired, _}

      finalize(store, "run_blank", %{session_key: ""})
      refute_receive {:hook_fired, _}
    end

    test "the store's hot path names no run-history or memory module" do
      source = File.read!("lib/lemon_core/store.ex")

      refute source =~ "RunHistoryStore"
      refute source =~ "MemoryIngest"
      refute source =~ "known_targets"
    end
  end

  describe "sessions_index coherence" do
    test "a cached read reflects later finalizations" do
      store = start_store(:store_sessions_index, backend: EtsBackend)
      session_key = "agent:sessions_index:main"

      finalize(store, "run_1", %{session_key: session_key})
      # Populates the read cache from the backend.
      assert %{run_count: 1, session_key: ^session_key} =
               Store.get(store, :sessions_index, session_key)

      finalize(store, "run_2", %{session_key: session_key})

      # Before the write-through fix this still reported run_count: 1, because
      # update_sessions_index wrote the backend without touching the cache.
      assert %{run_count: 2} = Store.get(store, :sessions_index, session_key)
      assert [{^session_key, %{run_count: 2}}] = Store.list(store, :sessions_index)
    end
  end

  describe "cached tables" do
    test "are configurable per instance" do
      store =
        start_store(:store_cached_custom, backend: EtsBackend, cached_tables: [:my_index])

      :ok = Store.put(store, :my_index, "k", "v")
      assert ReadCache.get(store, :my_index, "k") == "v"
      assert :ets.whereis(ReadCache.table_for(store, :my_index)) != :undefined

      # Neither configured nor declared by a registered table module: readable,
      # but not mirrored.
      :ok = Store.put(store, :plain_index, "s", %{run_count: 1})
      assert ReadCache.get(store, :plain_index, "s") == nil
      assert Store.get(store, :plain_index, "s") == %{run_count: 1}
    end

    test "channel target tables are not a core default" do
      store = start_store(:store_cached_defaults, backend: EtsBackend)

      assert ReadCache.cached?(store, :sessions_index)
      refute ReadCache.cached?(store, :demo_targets)
    end

    test "register_cached_table starts mirroring and warms from the backend" do
      store = start_store(:store_cached_register, backend: EtsBackend, cached_tables: [])
      on_exit(fn -> Store.unregister_cached_table(:store_cached_register, :late_index) end)

      # Written before the table was cached.
      :ok = Store.put(store, :late_index, "k", "v")
      assert ReadCache.get(store, :late_index, "k") == nil

      :ok = Store.register_cached_table(store, :late_index)

      assert ReadCache.get(store, :late_index, "k") == "v"
      assert Store.get(store, :late_index, "k") == "v"
      assert Store.list(store, :late_index) == [{"k", "v"}]
    end

    test "registration survives a store restart" do
      name = :store_cached_restart
      on_exit(fn -> Store.unregister_cached_table(name, :sticky_index) end)

      pid =
        start_supervised!(
          Supervisor.child_spec({Store, name: name, backend: EtsBackend}, id: name)
        )

      :ok = Store.register_cached_table(name, :sticky_index)
      assert ReadCache.cached?(name, :sticky_index)

      stop_supervised!(name)
      refute Process.alive?(pid)

      start_supervised!(Supervisor.child_spec({Store, name: name, backend: EtsBackend}, id: name))
      assert ReadCache.cached?(name, :sticky_index)
    end
  end

  describe "the generic API sees the rows the typed API writes" do
    test "a chat state written through the typed API is a plain row" do
      store = start_store(:store_intrinsic_bypass, backend: EtsBackend)
      scope = {:intrinsic, :chat}

      :ok = ChatStateStore.put(store, scope, %{phase: :active})
      assert %{phase: :active} = ChatStateStore.get(store, scope)

      assert %{phase: :active} = Store.get(store, :chat, scope)
      assert :ok = Store.delete(store, :chat, scope)
      assert Store.get(store, :chat, scope) == nil
    end
  end

  describe "hook sources are deduplicated" do
    test "a hook wired through config AND registered at runtime fires once" do
      parent = self()
      hook = {__MODULE__, :send_to, [parent]}

      # Configured hooks belong to the default store, so this test runs on it,
      # standing in for the runtime's own wiring for the duration.
      previous = Application.get_env(:lemon_core, LemonCore.RunStore)
      Application.put_env(:lemon_core, LemonCore.RunStore, finalize_hooks: [hook])

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:lemon_core, LemonCore.RunStore),
          else: Application.put_env(:lemon_core, LemonCore.RunStore, previous)
      end)

      # A collaborator that also self-registers at boot — the two mechanisms are
      # documented as interchangeable, so wiring both must not double-ingest.
      register_hook(Store, hook)

      finalize(Store, "run_dedup_#{System.unique_integer([:positive])}", %{
        session_key: "agent:dedup:main"
      })

      assert_receive {:hook_fired, %{session_key: "agent:dedup:main"}}
      refute_receive {:hook_fired, %{session_key: "agent:dedup:main"}}, 100
    end
  end

  @doc false
  def send_to(pid, event), do: send(pid, {:hook_fired, event})
end
