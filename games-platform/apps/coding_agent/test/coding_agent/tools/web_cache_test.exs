defmodule CodingAgent.Tools.WebCacheTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.WebCache

  @table_one :coding_agent_web_cache_test_one
  @table_two :coding_agent_web_cache_test_two
  @table_three :coding_agent_web_cache_test_three

  setup do
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
      WebCache.clear_cache(@table_one, opts)
      WebCache.clear_cache(@table_two, opts)
      WebCache.clear_cache(@table_three, opts)

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

    :ets.delete(@table_one)

    assert {:hit, %{"value" => "persisted"}} = WebCache.read_cache(@table_one, "lemon:key", opts)
  end

  test "expires persisted entries when ttl elapses", %{cache_dir: cache_dir} do
    opts = %{"persistent" => true, "path" => cache_dir, "max_entries" => 10}
    WebCache.write_cache(@table_two, "expire:key", "stale", 5, 10, opts)

    Process.sleep(20)
    :ets.delete(@table_two)

    assert :miss = WebCache.read_cache(@table_two, "expire:key", opts)
  end

  test "evicts oldest entries with max size and persists bounded state", %{cache_dir: cache_dir} do
    opts = %{"persistent" => true, "path" => cache_dir, "max_entries" => 1}

    WebCache.write_cache(@table_three, "first", 1, 60_000, 1, opts)
    Process.sleep(2)
    WebCache.write_cache(@table_three, "second", 2, 60_000, 1, opts)

    assert :miss = WebCache.read_cache(@table_three, "first", opts)
    assert {:hit, 2} = WebCache.read_cache(@table_three, "second", opts)

    :ets.delete(@table_three)

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
    Process.sleep(2)
    WebCache.write_cache(@table_one, "second", 2, 60_000, 10, opts)

    assert :miss = WebCache.read_cache(@table_one, "first", opts)
    assert {:hit, 2} = WebCache.read_cache(@table_one, "second", opts)
  end
end
