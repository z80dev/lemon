defmodule CodingAgent.Tools.WebCacheTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.WebCache

  @table_one :coding_agent_web_cache_test_one
  @table_two :coding_agent_web_cache_test_two
  @table_three :coding_agent_web_cache_test_three

  setup do
    start_supervised!(
      {CodingAgent.RuntimeTables,
       name: __MODULE__.Owner,
       tables: [@table_one, @table_two, @table_three],
       cache_table: :coding_agent_web_cache_test_values}
    )

    original_cache_path = System.get_env("LEMON_WEB_CACHE_PATH")

    cache_dir =
      Path.join(System.tmp_dir!(), "web_cache_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)
    System.put_env("LEMON_WEB_CACHE_PATH", cache_dir)

    opts = %{
      "persistent" => true,
      "path" => cache_dir,
      "max_entries" => 10
    }

    WebCache.clear_cache(@table_one, opts)
    WebCache.clear_cache(@table_two, opts)
    WebCache.clear_cache(@table_three, opts)

    on_exit(fn ->
      for table <- [@table_one, @table_two, @table_three] do
        :ets.match_delete(:coding_agent_web_cache_state, {{:loaded, table, :_}, :_})
        :ets.delete(:coding_agent_web_cache_state, {:active_dir, table})
      end

      if original_cache_path,
        do: System.put_env("LEMON_WEB_CACHE_PATH", original_cache_path),
        else: System.delete_env("LEMON_WEB_CACHE_PATH")

      File.rm_rf!(cache_dir)
    end)

    %{cache_dir: cache_dir}
  end

  test "persists cache entries across ETS table recreation", %{cache_dir: cache_dir} do
    opts = %{"persistent" => true, "path" => cache_dir, "max_entries" => 10}
    WebCache.write_cache(@table_one, "lemon:key", %{"value" => "persisted"}, 60_000, 10, opts)

    assert {:hit, %{"value" => "persisted"}} = WebCache.read_cache(@table_one, "lemon:key", opts)

    restart_owner()

    assert {:hit, %{"value" => "persisted"}} = WebCache.read_cache(@table_one, "lemon:key", opts)
  end

  test "expires persisted entries when ttl elapses", %{cache_dir: cache_dir} do
    opts = %{"persistent" => true, "path" => cache_dir, "max_entries" => 10}
    WebCache.write_cache(@table_two, "expire:key", "stale", 60_000, 10, opts)

    path = Path.join(cache_dir, "#{@table_two}.json")
    payload = path |> File.read!() |> Jason.decode!()
    payload = put_in(payload, ["entries", Access.at(0), "expires_at"], 0)
    File.write!(path, Jason.encode!(payload))
    restart_owner()

    assert :miss = WebCache.read_cache(@table_two, "expire:key", opts)
  end

  test "evicts oldest entries with max size and persists bounded state", %{cache_dir: cache_dir} do
    opts = %{"persistent" => true, "path" => cache_dir, "max_entries" => 1}

    WebCache.write_cache(@table_three, "first", 1, 60_000, 1, opts)
    WebCache.write_cache(@table_three, "second", 2, 60_000, 1, opts)

    assert :miss = WebCache.read_cache(@table_three, "first", opts)
    assert {:hit, 2} = WebCache.read_cache(@table_three, "second", opts)

    restart_owner()

    assert :miss = WebCache.read_cache(@table_three, "first", opts)
    assert {:hit, 2} = WebCache.read_cache(@table_three, "second", opts)
  end

  test "LEMON_WEB_CACHE_MAX_ENTRIES overrides passed max_entries", %{cache_dir: cache_dir} do
    original_max_entries = System.get_env("LEMON_WEB_CACHE_MAX_ENTRIES")
    System.put_env("LEMON_WEB_CACHE_MAX_ENTRIES", "1")

    on_exit(fn ->
      if original_max_entries,
        do: System.put_env("LEMON_WEB_CACHE_MAX_ENTRIES", original_max_entries),
        else: System.delete_env("LEMON_WEB_CACHE_MAX_ENTRIES")
    end)

    opts = %{"persistent" => true, "path" => cache_dir}

    WebCache.write_cache(@table_one, "first", 1, 60_000, 10, opts)
    WebCache.write_cache(@table_one, "second", 2, 60_000, 10, opts)

    assert :miss = WebCache.read_cache(@table_one, "first", opts)
    assert {:hit, 2} = WebCache.read_cache(@table_one, "second", opts)
  end

  defp restart_owner do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    owner = Process.whereis(__MODULE__.Owner)
    ref = Process.monitor(owner)
    :ok = Supervisor.terminate_child(supervisor, CodingAgent.RuntimeTables)
    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}
    {:ok, restarted} = Supervisor.restart_child(supervisor, CodingAgent.RuntimeTables)
    assert :ets.info(@table_one, :owner) == restarted
  end
end
