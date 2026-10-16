defmodule LemonCore.StoreHooksTest do
  @moduledoc """
  The store is a storage primitive: collaborators attach through hooks and
  registered cached tables rather than being named in the store's hot path.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache

  defmodule FakeHistory do
    @moduledoc false
    def get(server, session_key, opts), do: [{:fake, server, session_key, opts}]
  end

  defmodule ExplodingHistory do
    @moduledoc false
    def get(_server, _session_key, _opts), do: raise("history provider is down")
  end

  defp start_store(name, opts) do
    spec = Supervisor.child_spec({Store, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  defp finalize(store, run_id, summary) do
    :ok = Store.finalize_run(store, run_id, summary)
  end

  describe "finalize_run hooks" do
    test "configured hooks receive the finalized run" do
      parent = self()
      hook = fn event -> send(parent, {:hook_fired, event}) end

      store =
        start_store(:store_hooks_configured, backend: EtsBackend, finalize_run_hooks: [hook])

      :ok = Store.append_run_event(store, "run_cfg", %{type: :started})
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

      on_exit(fn -> Store.unregister_finalize_run_hook(:store_hooks_runtime, hook) end)

      :ok = Store.register_finalize_run_hook(store, hook)
      finalize(store, "run_1", %{session_key: "agent:runtime:main"})
      assert_receive {:runtime_hook, "run_1"}

      :ok = Store.unregister_finalize_run_hook(store, hook)
      finalize(store, "run_2", %{session_key: "agent:runtime:main"})
      refute_receive {:runtime_hook, "run_2"}
    end

    test "hooks run in order and a failing hook does not stop the others" do
      parent = self()
      first = fn _event -> send(parent, {:order, :first}) end
      boom = fn _event -> raise "hook exploded" end
      last = fn _event -> send(parent, {:order, :last}) end

      store =
        start_store(:store_hooks_isolation,
          backend: EtsBackend,
          finalize_run_hooks: [first, boom, last]
        )

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

    test "runs without an indexable session key still fire hooks exactly once per finalization" do
      parent = self()
      hook = fn event -> send(parent, {:hook_fired, event}) end

      store =
        start_store(:store_hooks_no_session, backend: EtsBackend, finalize_run_hooks: [hook])

      for {run_id, summary} <- [
            {"run_orphan", %{agent_id: "nobody"}},
            {"run_blank", %{session_key: ""}},
            {"run_invalid", %{session_key: :invalid}}
          ] do
        finalize(store, run_id, summary)
        assert_receive {:hook_fired, %{run_id: ^run_id, summary: ^summary} = event}
        assert event.session_key == Map.get(summary, :session_key)
        refute_receive {:hook_fired, _}
      end

      assert Store.list(store, :sessions_index) == []
    end

    test "history hook ignores runs without an indexable session key" do
      for session_key <- [nil, "", :invalid] do
        assert :ok =
                 LemonCore.RunHistoryStore.handle_finalize_run(:no_history_server, %{
                   run_id: "sessionless",
                   session_key: session_key,
                   started_at: 1,
                   record: %{events: []},
                   summary: %{}
                 })
      end
    end
  end

  describe "run history provider" do
    test "reads forward to the configured provider" do
      store =
        start_store(:store_history_provider,
          backend: EtsBackend,
          run_history_provider: {FakeHistory, :fake_server}
        )

      assert Store.get_run_history(store, "agent:x:main", limit: 3) == [
               {:fake, :fake_server, "agent:x:main", [limit: 3]}
             ]
    end

    test "a store with no provider reports no history instead of failing" do
      store = start_store(:store_history_none, backend: EtsBackend)

      assert Store.get_run_history(store, "agent:x:main", []) == []
    end

    test "a provider that raises is isolated from the store" do
      store =
        start_store(:store_history_exploding,
          backend: EtsBackend,
          run_history_provider: ExplodingHistory
        )

      log =
        capture_log(fn ->
          assert Store.get_run_history(store, "agent:x:main", []) == []
        end)

      assert log =~ "history provider is down"
      assert Store.ping(store) == :ok
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

      # Not in this instance's set: readable, but not mirrored.
      :ok = Store.put(store, :sessions_index, "s", %{run_count: 1})
      assert ReadCache.get(store, :sessions_index, "s") == nil
      assert Store.get(store, :sessions_index, "s") == %{run_count: 1}
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

  describe "chat state is an ordinary mirrored table" do
    test "a generic delete evicts what the typed owner wrote" do
      store = start_store(:store_chat_generic, backend: EtsBackend)
      scope = {:generic, :chat}

      :ok = LemonCore.ChatStateStore.put(store, scope, %{phase: :active})
      assert %{phase: :active} = ReadCache.get(store, :chat, scope)
      assert %{phase: :active} = Store.get(store, :chat, scope)

      assert :ok = Store.delete(store, :chat, scope)
      assert ReadCache.get(store, :chat, scope) == nil
      assert LemonCore.ChatStateStore.get(store, scope) == nil
    end
  end

  describe "hook sources are deduplicated" do
    test "a hook wired through config AND registered at runtime fires once" do
      parent = self()
      hook = {__MODULE__, :send_to, [parent]}

      store = start_store(:hook_dedup_store, finalize_run_hooks: [hook])
      # A collaborator that also self-registers at boot — the two mechanisms are
      # documented as interchangeable, so wiring both must not double-ingest.
      :ok = Store.register_finalize_run_hook(store, hook)
      on_exit(fn -> Store.unregister_finalize_run_hook(store, hook) end)

      finalize(store, "run_dedup", %{session_key: "agent:dedup:main"})

      assert_receive {:hook_fired, %{run_id: "run_dedup"}}
      refute_receive {:hook_fired, %{run_id: "run_dedup"}}, 100
    end
  end

  @doc false
  def send_to(pid, event), do: send(pid, {:hook_fired, event})
end
