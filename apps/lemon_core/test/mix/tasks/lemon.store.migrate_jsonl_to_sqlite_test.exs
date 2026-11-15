defmodule Mix.Tasks.Lemon.Store.MigrateJsonlToSqliteTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Store.SqliteBackend
  alias Mix.Tasks.Lemon.Store.MigrateJsonlToSqlite

  setup do
    root = Path.join(System.tmp_dir!(), "jsonl-migration-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    target = Path.join(root, "chosen.sqlite3")
    File.mkdir_p!(source)

    File.write!(Path.join(source, "users.jsonl"), """
    {"op":"put","key":"user1","value":{"__atom__:name":"Old"}}
    {"op":"put","key":"deleted","value":1}
    {"op":"delete","key":"deleted"}
    {"op":"put","key":"user1","value":{"__atom__:name":"Alice"}}
    {"op":"put","key":"user2","value":{"__atom__:name":"Bob"}}
    {"op":"put","key":{"__tuple__":[{"__atom__":"owner"},"id"]},"value":{"__tuple__":[{"__atom__":"ok"},[1,2]]}}
    """)

    File.write!(Path.join(source, "runs.jsonl"), """
    {"op":"put","key":"run1","value":{"__atom__:answer":"private run"}}
    """)

    previous = Map.new(~w(LEMON_STORE_PATH LEMON_STORE_DB_PATH), &{&1, System.get_env(&1)})
    Enum.each(Map.keys(previous), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, root: root, source: source, target: target}
  end

  test "empty legacy directory remains empty and creates no database", %{
    root: root,
    target: target
  } do
    source = Path.join(root, "empty")
    File.mkdir_p!(source)

    capture_io(fn ->
      MigrateJsonlToSqlite.run(["--jsonl-path", source, "--sqlite-path", target])
    end)

    assert File.ls!(source) == []
    refute File.exists?(target)
  end

  test "dry run leaves the chosen database and source journal unchanged", %{
    source: source,
    target: target
  } do
    before = File.read!(Path.join(source, "users.jsonl"))

    capture_io(fn ->
      MigrateJsonlToSqlite.run(["--jsonl-path", source, "--sqlite-path", target, "--dry-run"])
    end)

    refute File.exists?(target)
    assert File.read!(Path.join(source, "users.jsonl")) == before
  end

  test "migration preserves native keys and values at the selected target, excluding runs by default",
       %{source: source, target: target} do
    capture_io(fn ->
      MigrateJsonlToSqlite.run(["--jsonl-path", source, "--sqlite-path", target])
    end)

    {:ok, state} = SqliteBackend.init(path: target, ephemeral_tables: [])

    try do
      assert {:ok, %{name: "Alice"}, _} = SqliteBackend.get(state, :users, "user1")
      assert {:ok, %{name: "Bob"}, _} = SqliteBackend.get(state, :users, "user2")
      assert {:ok, nil, _} = SqliteBackend.get(state, :runs, "run1")
      assert {:ok, nil, _} = SqliteBackend.get(state, :users, "deleted")
      assert {:ok, {:ok, [1, 2]}, _} = SqliteBackend.get(state, :users, {:owner, "id"})
    after
      SqliteBackend.close(state)
    end
  end

  test "explicit run migration preserves run data", %{source: source, target: target} do
    capture_io(fn ->
      MigrateJsonlToSqlite.run([
        "--jsonl-path",
        source,
        "--sqlite-path",
        target,
        "--include-runs"
      ])
    end)

    {:ok, state} = SqliteBackend.init(path: target, ephemeral_tables: [])

    try do
      assert {:ok, %{answer: "private run"}, _} = SqliteBackend.get(state, :runs, "run1")
    after
      SqliteBackend.close(state)
    end
  end

  test "corrupt input refuses migration without publishing a database", %{
    source: source,
    target: target
  } do
    File.write!(Path.join(source, "users.jsonl"), "invalid journal\n", [:append])

    capture_io(fn ->
      assert_raise Mix.Error, fn ->
        MigrateJsonlToSqlite.run(["--jsonl-path", source, "--sqlite-path", target])
      end
    end)

    refute File.exists?(target)
  end

  test "explicit source and target override environment without migrating the wrong store", %{
    root: root,
    source: source,
    target: target
  } do
    wrong_source = Path.join(root, "wrong-source")
    wrong_target = Path.join(root, "wrong.sqlite3")
    File.mkdir_p!(wrong_source)

    File.write!(Path.join(wrong_source, "users.jsonl"), """
    {"op":"put","key":"user1","value":{"__atom__:name":"Wrong"}}
    """)

    System.put_env("LEMON_STORE_PATH", wrong_source)
    System.put_env("LEMON_STORE_DB_PATH", wrong_target)

    capture_io(fn ->
      MigrateJsonlToSqlite.run(["--jsonl-path", source, "--sqlite-path", target])
    end)

    refute File.exists?(wrong_target)
    {:ok, state} = SqliteBackend.init(path: target, ephemeral_tables: [])

    try do
      assert {:ok, %{name: "Alice"}, _} = SqliteBackend.get(state, :users, "user1")
    after
      SqliteBackend.close(state)
    end
  end
end
