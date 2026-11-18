defmodule CodingAgent.RuntimeTablesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RuntimeTables
  alias CodingAgent.Security.SecretObfuscator.Placeholder
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools.Grep
  alias CodingAgent.Tools.WebCache

  @moduletag :tmp_dir
  @cache_table :coding_agent_runtime_cache
  @extension_table :coding_agent_tool_registry_extension_cache

  test "application startup owns the caches before any requesting process" do
    owner = Process.whereis(RuntimeTables)
    assert is_pid(owner)

    assert {RuntimeTables, owner, :worker, [RuntimeTables]} in Supervisor.which_children(
             CodingAgent.Supervisor
           )

    for table <- [
          @cache_table,
          @extension_table,
          :coding_agent_extension_source_paths,
          :coding_agent_extension_load_errors,
          :coding_agent_web_cache_state,
          :coding_agent_websearch_cache,
          :coding_agent_webfetch_cache,
          :coding_agent_websearch_rate_limit
        ] do
      assert :ets.info(table, :owner) == owner
    end

    assert :ets.info(@cache_table, :protection) == :protected
  end

  test "extension inventory survives the task that primes it", %{tmp_dir: tmp_dir} do
    on_exit(fn -> ToolRegistry.invalidate_extension_cache(tmp_dir) end)

    {caller, ref} =
      spawn_monitor(fn -> ToolRegistry.prime_extension_cache(tmp_dir, [], [__MODULE__]) end)

    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    key = {Path.expand(tmp_dir), []}

    assert [{^key, %{extensions: [__MODULE__]}}] =
             :ets.lookup(@extension_table, key)

    assert :ets.info(@extension_table, :owner) == Process.whereis(RuntimeTables)

    assert :ok = ToolRegistry.invalidate_extension_cache(tmp_dir)
    assert :ets.lookup(@extension_table, key) == []
  end

  test "concurrent first web-cache callers never own the table", %{tmp_dir: tmp_dir} do
    table = :coding_agent_runtime_tables_web_test
    opts = %{persistent: false, path: tmp_dir}
    on_exit(fn -> WebCache.clear_cache(table, opts) end)

    clients =
      for index <- 1..8 do
        spawn_monitor(fn ->
          WebCache.write_cache(table, Integer.to_string(index), index, 60_000, 20, opts)
        end)
      end

    for {caller, ref} <- clients do
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    end

    assert :ets.info(table, :owner) == Process.whereis(RuntimeTables)

    for index <- 1..8 do
      assert {:hit, ^index} = WebCache.read_cache(table, Integer.to_string(index), opts)
    end
  end

  test "concurrent cache misses publish one value without running probes in the owner" do
    key = {__MODULE__, make_ref()}
    parent = self()
    on_exit(fn -> RuntimeTables.delete(key) end)

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          RuntimeTables.fetch(key, fn ->
            send(parent, {:probing, self()})

            receive do
              :publish -> self()
            end
          end)
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:probing, ^pid}, 1_000
    end

    # All callers reached their probe before any value was published.
    Enum.each(tasks, &send(&1.pid, :publish))
    values = Enum.map(tasks, &Task.await/1)
    assert [published] = Enum.uniq(values)
    assert published in Enum.map(tasks, & &1.pid)
    assert RuntimeTables.fetch(key, fn -> flunk("cache hit must not probe") end) == published
    assert :ok = RuntimeTables.delete(key)
    assert RuntimeTables.fetch(key, fn -> :refreshed end) == :refreshed
  end

  test "grep uses supervised PCRE2 results without writing persistent terms", %{tmp_dir: tmp_dir} do
    key = {Grep, :pcre2, System.find_executable("rg")}
    RuntimeTables.delete(key)
    on_exit(fn -> RuntimeTables.delete(key) end)

    {caller, ref} = spawn_monitor(fn -> RuntimeTables.fetch(key, fn -> false end) end)
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}

    assert {:error, message} =
             Grep.execute("pcre", %{"pattern" => "needle(?=!)"}, nil, nil, tmp_dir,
               ripgrep_available?: true,
               rg_cmd_fun: fn _, _, _ -> flunk("unsupported patterns must not run") end
             )

    assert message =~ "without PCRE2 support"
    RuntimeTables.delete(key)
    RuntimeTables.fetch(key, fn -> true end)

    assert %LemonAgent.Types.AgentToolResult{} =
             Grep.execute("pcre", %{"pattern" => "needle(?=!)"}, nil, nil, tmp_dir,
               ripgrep_available?: true,
               rg_cmd_fun: fn "rg", args, _ ->
                 assert "--pcre2" in args
                 {"", 1}
               end
             )

    assert :persistent_term.get(key, :missing) == :missing
  end

  @tag capture_log: true
  test "unwritable placeholder keys share one supervised ephemeral key", %{tmp_dir: tmp_dir} do
    key = {Placeholder, :ephemeral_key}
    RuntimeTables.delete(key)
    on_exit(fn -> RuntimeTables.delete(key) end)
    blocker = Path.join(tmp_dir, "not-a-directory")
    File.write!(blocker, "file")
    key_path = Path.join(blocker, "key")

    keys =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Placeholder.load_or_create_key(key_path) end) end)
      |> Enum.map(&Task.await/1)

    assert [published] = Enum.uniq(keys)
    assert published =~ ~r/^[A-Za-z0-9_-]{43}$/
    assert Placeholder.load_or_create_key(key_path) == published
    assert :persistent_term.get(key, :missing) == :missing
  end

  test "a scoped supervised owner recreates empty tables on restart" do
    table = :coding_agent_runtime_tables_restart_test
    cache_table = :coding_agent_runtime_tables_restart_cache

    owner =
      start_supervised!(
        {RuntimeTables, name: __MODULE__.Owner, tables: [table], cache_table: cache_table}
      )

    :ets.insert(table, {:entry, :volatile})
    assert :value = GenServer.call(owner, {:put_new, :probe, :value})
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    ref = Process.monitor(owner)

    assert :ok = Supervisor.terminate_child(supervisor, RuntimeTables)
    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}
    assert :ets.whereis(table) == :undefined
    assert :ets.whereis(cache_table) == :undefined
    assert {:ok, restarted} = Supervisor.restart_child(supervisor, RuntimeTables)
    assert :ets.info(table, :owner) == restarted
    assert :ets.info(cache_table, :owner) == restarted
    assert :ets.tab2list(table) == []
    assert :ets.tab2list(cache_table) == []
  end
end
