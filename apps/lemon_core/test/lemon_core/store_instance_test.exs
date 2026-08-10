defmodule LemonCore.StoreInstanceTest do
  @moduledoc """
  Two `LemonCore.Store` instances must be able to run side by side in one node
  with fully isolated data — backend *and* read cache.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache

  defmodule TaggingBackend do
    @moduledoc false
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(opts), do: {:ok, %{tag: Keyword.fetch!(opts, :tag), data: %{}}}

    @impl true
    def put(state, table, key, value),
      do: {:ok, %{state | data: Map.put(state.data, {table, key}, value)}}

    @impl true
    def put_new(state, table, key, value) do
      if Map.has_key?(state.data, {table, key}) do
        {:exists, state}
      else
        put(state, table, key, value)
      end
    end

    @impl true
    def get(state, :tag, :tag), do: {:ok, state.tag, state}
    def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(state, table, key), do: {:ok, update_in(state.data, &Map.delete(&1, {table, key}))}

    @impl true
    def list(state, table) do
      entries =
        for {{^table, key}, value} <- state.data, do: {key, value}

      {:ok, entries, state}
    end
  end

  defp start_store(name, opts) do
    spec = Supervisor.child_spec({Store, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  describe "two named stores in one node" do
    setup do
      alpha = start_store(:store_instance_alpha, backend: EtsBackend, backend_opts: [])
      beta = start_store(:store_instance_beta, backend: EtsBackend, backend_opts: [])
      %{alpha: alpha, beta: beta}
    end

    test "generic tables are isolated", %{alpha: alpha, beta: beta} do
      assert :ok = Store.put(alpha, :notes, "k", "alpha value")
      assert :ok = Store.put(beta, :notes, "k", "beta value")

      assert Store.get(alpha, :notes, "k") == "alpha value"
      assert Store.get(beta, :notes, "k") == "beta value"

      assert Store.list(alpha, :notes) == [{"k", "alpha value"}]

      assert :ok = Store.delete(alpha, :notes, "k")
      assert Store.get(alpha, :notes, "k") == nil
      assert Store.get(beta, :notes, "k") == "beta value"
    end

    test "read-cached generic tables are isolated", %{alpha: alpha, beta: beta} do
      assert :ok = Store.put(alpha, :sessions_index, "agent:a:main", %{agent_id: "a"})
      assert :ok = Store.put(beta, :sessions_index, "agent:b:main", %{agent_id: "b"})

      # Served straight from each instance's ETS cache, not the GenServer.
      assert ReadCache.get(alpha, :sessions_index, "agent:a:main") == %{agent_id: "a"}
      assert ReadCache.get(beta, :sessions_index, "agent:a:main") == nil

      assert Store.list(alpha, :sessions_index) == [{"agent:a:main", %{agent_id: "a"}}]
      assert Store.list(beta, :sessions_index) == [{"agent:b:main", %{agent_id: "b"}}]
    end

    test "chat state and its read cache are isolated", %{alpha: alpha, beta: beta} do
      scope = {:store_instance_test, :chat}

      assert :ok = Store.put_chat_state(alpha, scope, %{msg: "alpha"})

      assert %{msg: "alpha"} = Store.get_chat_state(alpha, scope)
      assert Store.get_chat_state(beta, scope) == nil

      assert :ok = Store.delete_chat_state(alpha, scope)
      assert Store.get_chat_state(alpha, scope) == nil
    end

    test "progress mappings and runs are isolated", %{alpha: alpha, beta: beta} do
      scope = {:store_instance_test, :progress}

      assert :ok = Store.put_progress_mapping(alpha, scope, 42, "run_alpha")
      assert Store.get_run_by_progress(alpha, scope, 42) == "run_alpha"
      assert Store.get_run_by_progress(beta, scope, 42) == nil

      assert :ok = Store.append_run_event(alpha, "run_alpha", %{type: :started})
      # Casts are async; wait for the write to land in the backend.
      assert :ok = Store.ping(alpha)

      assert %{events: [%{type: :started}]} = Store.get_run(alpha, "run_alpha")
      assert Store.get_run(beta, "run_alpha") == nil
    end

    test "each instance owns its own read-cache tables", %{alpha: alpha, beta: beta} do
      # Per-instance domains: another store's cached-table set is irrelevant here.
      for domain <- ReadCache.cached_domains(alpha) do
        alpha_table = ReadCache.table_for(alpha, domain)
        beta_table = ReadCache.table_for(beta, domain)

        assert alpha_table != beta_table
        assert :ets.whereis(alpha_table) != :undefined
        assert :ets.whereis(beta_table) != :undefined
        assert :ets.info(:ets.whereis(alpha_table), :owner) == Process.whereis(alpha)
        assert :ets.info(:ets.whereis(beta_table), :owner) == Process.whereis(beta)
      end
    end

    test "the default store keeps its historical table names" do
      assert ReadCache.table_for(:chat) == :lemon_store_cache_chat
      assert ReadCache.table_for(:runs) == :lemon_store_cache_runs
      assert ReadCache.table_for(:progress) == :lemon_store_cache_progress
      assert ReadCache.table_for(:sessions_index) == :lemon_store_cache_sessions_index

      assert ReadCache.table_for(:telegram_known_targets) ==
               :lemon_store_cache_telegram_known_targets

      assert ReadCache.table_for(LemonCore.Store, :chat) == :lemon_store_cache_chat

      assert ReadCache.table_for(:store_instance_alpha, :chat) ==
               :lemon_store_cache_store_instance_alpha_chat
    end
  end

  describe "backend configuration" do
    test "comes from start_link opts" do
      store =
        start_store(:store_instance_opts, backend: TaggingBackend, backend_opts: [tag: :opts])

      assert Store.get(store, :tag, :tag) == :opts
    end

    test "falls back to the app env keyed by the store name" do
      name = :store_instance_env

      Application.put_env(:lemon_core, name,
        backend: TaggingBackend,
        backend_opts: [tag: :app_env]
      )

      on_exit(fn -> Application.delete_env(:lemon_core, name) end)

      store = start_store(name, [])

      assert Store.get(store, :tag, :tag) == :app_env
    end

    test "opts win over the app env" do
      name = :store_instance_precedence

      Application.put_env(:lemon_core, name,
        backend: TaggingBackend,
        backend_opts: [tag: :app_env]
      )

      on_exit(fn -> Application.delete_env(:lemon_core, name) end)

      store = start_store(name, backend_opts: [tag: :opts])

      assert Store.get(store, :tag, :tag) == :opts
    end

    test "the default store still reads config :lemon_core, LemonCore.Store" do
      # The running application store is configured through the historical key;
      # its cache tables and app-env key must not have moved.
      assert is_pid(Process.whereis(LemonCore.Store))
      assert Store.ping() == :ok
    end
  end

  describe "RunHistoryStore instances" do
    @tag :tmp_dir
    test "keep their own database and stay isolated from the default store", %{tmp_dir: tmp_dir} do
      name = :run_history_instance_test

      start_supervised!(
        Supervisor.child_spec({LemonCore.RunHistoryStore, name: name, path: tmp_dir}, id: name)
      )

      session_key = "agent:run_history_instance_test:main"

      :ok = LemonCore.RunHistoryStore.put(name, session_key, 1_000, "run_1", %{summary: %{}})

      assert [{"run_1", %{summary: %{}}}] =
               LemonCore.RunHistoryStore.get(name, session_key, limit: 10)

      assert LemonCore.RunHistoryStore.get(session_key, limit: 10) == []

      assert File.exists?(Path.join(tmp_dir, "run_history_run_history_instance_test.sqlite3"))
    end
  end

  describe "ConfigCache instances" do
    test "get their own ETS table and answer independently" do
      name = :config_cache_instance_test

      start_supervised!(Supervisor.child_spec({LemonCore.ConfigCache, name: name}, id: name))

      assert LemonCore.ConfigCache.table_for(name) ==
               :lemon_core_config_cache_config_cache_instance_test

      assert LemonCore.ConfigCache.table_for(LemonCore.ConfigCache) == :lemon_core_config_cache

      assert LemonCore.ConfigCache.available?(name)
      assert %LemonCore.Config{} = LemonCore.ConfigCache.get(name, nil, [])

      assert :ok = LemonCore.ConfigCache.invalidate(name, nil)
      assert %LemonCore.Config{} = LemonCore.ConfigCache.get(name, nil, [])
    end
  end

  describe "read cache collisions" do
    test "reusing another owner's table raises instead of silently sharing" do
      name = :store_instance_collision
      parent = self()

      owner =
        spawn(fn ->
          ReadCache.init(name)
          send(parent, :ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :ready

      log =
        capture_log(fn ->
          assert_raise ReadCache.CollisionError, fn -> ReadCache.init(name) end
        end)

      assert log =~ "already exists and is owned by"

      send(owner, :stop)
    end

    test "re-attaching to the tables of the registered store instance is allowed" do
      name = :store_instance_reattach
      parent = self()

      owner =
        spawn(fn ->
          Process.register(self(), name)
          tables = ReadCache.init(name)
          send(parent, {:ready, tables})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:ready, tables}

      # Same tables, no collision: the owner is the process registered as `name`.
      assert ReadCache.init(name) == tables

      send(owner, :stop)
    end
  end
end
