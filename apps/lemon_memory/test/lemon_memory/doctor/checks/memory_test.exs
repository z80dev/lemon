defmodule LemonMemory.Doctor.Checks.MemoryTest do
  use ExUnit.Case, async: false

  alias LemonCore.Config.Features
  alias LemonMemory.Doctor.Checks.Memory

  defmodule StubMemoryStore do
    def stats do
      %{total: 3, oldest_ms: 1, newest_ms: System.system_time(:millisecond) - 120_000}
    end
  end

  test "reports inactive memory when session_search is off" do
    checks = Memory.run(features: %Features{session_search: :off})
    check = Enum.find(checks, &(&1.name == "memory.session_search"))

    assert check.status == :pass
    assert check.message =~ "session_search is off"
    assert check.message =~ "inactive"
  end

  test "reports inactive memory when session_search is opt-in" do
    checks = Memory.run(features: %Features{session_search: :"opt-in"})
    check = Enum.find(checks, &(&1.name == "memory.session_search"))

    assert check.status == :pass
    assert check.message =~ "session_search is opt-in"
  end

  test "warns with the kill switch when default-on but exqlite is unavailable" do
    checks =
      Memory.run(
        features: %Features{session_search: :"default-on"},
        exqlite_loaded: false
      )

    check = Enum.find(checks, &(&1.name == "memory.session_search"))

    assert check.status == :warn
    assert check.message =~ "exqlite SQLite NIF is not loaded"
    assert check.remediation =~ "LEMON_FEATURE_SESSION_SEARCH=off"
  end

  test "warns when default-on but the store process is not running" do
    checks =
      Memory.run(
        features: %Features{session_search: :"default-on"},
        exqlite_loaded: true,
        store_module: StubMemoryStore
      )

    check = Enum.find(checks, &(&1.name == "memory.session_search"))

    assert check.status == :warn
    assert check.message =~ "store process is not running"
    assert check.remediation =~ "LEMON_FEATURE_SESSION_SEARCH=off"
  end

  for runtime <- [:external, :absent] do
    test "does not infer runtime memory failure from an absent CLI-local process (#{runtime})" do
      [check] =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          exqlite_loaded: true,
          store_module: StubMemoryStore,
          runtime: unquote(runtime)
        )

      assert check.status == :skip
      assert check.remediation == nil
    end

    test "#{runtime} runtime scope does not conceal a missing exqlite NIF" do
      [check] =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          runtime: unquote(runtime),
          exqlite_loaded: false
        )

      assert check.status == :warn
    end
  end

  test "passes with document count, db size, and ingest recency when the store is up" do
    {:ok, agent} = Agent.start_link(fn -> :ok end, name: StubMemoryStore)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    dir = Path.join(System.tmp_dir!(), "memory_check_db_#{System.unique_integer([:positive])}")
    db_path = Path.join(dir, "memory.sqlite3")
    File.mkdir_p!(dir)
    File.write!(db_path, String.duplicate("x", 2048))
    on_exit(fn -> File.rm_rf!(dir) end)

    checks =
      Memory.run(
        features: %Features{session_search: :"default-on"},
        exqlite_loaded: true,
        store_module: StubMemoryStore,
        store_path: db_path
      )

    check = Enum.find(checks, &(&1.name == "memory.session_search"))

    assert check.status == :pass
    assert check.message =~ "session_search is default-on"
    assert check.message =~ "3 document(s)"
    assert check.message =~ "db 2.0 KB"
    assert check.message =~ "last ingest 2m ago"
  end

  test "reports the size of the database the configured store opens" do
    dir = Path.join(System.tmp_dir!(), "memory_check_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "memory.sqlite3"), String.duplicate("x", 3072))
    on_exit(fn -> File.rm_rf!(dir) end)

    original = Application.get_env(:lemon_memory, LemonMemory.Store)
    Application.put_env(:lemon_memory, LemonMemory.Store, path: dir)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:lemon_memory, LemonMemory.Store),
        else: Application.put_env(:lemon_memory, LemonMemory.Store, original)
    end)

    assert LemonMemory.Store.database_path() == Path.join(dir, "memory.sqlite3")

    {:ok, agent} = Agent.start_link(fn -> :ok end, name: StubMemoryStore)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    [check] =
      Memory.run(
        features: %Features{session_search: :"default-on"},
        exqlite_loaded: true,
        store_module: StubMemoryStore
      )

    assert check.message =~ "db 3.0 KB"
  end
end
