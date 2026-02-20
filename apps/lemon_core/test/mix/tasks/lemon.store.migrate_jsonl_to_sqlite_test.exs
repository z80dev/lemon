defmodule Mix.Tasks.Lemon.Store.MigrateJsonlToSqliteTest do
  @moduledoc """
  Tests for the mix lemon.store.migrate_jsonl_to_sqlite task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Store.MigrateJsonlToSqlite

  setup do
    Mix.Task.run("loadpaths")
    :ok
  end

  describe "module attributes" do
    test "has correct shortdoc" do
      assert Mix.Task.shortdoc(MigrateJsonlToSqlite) == "Migrate Lemon store data from JSONL files to SQLite"
    end

    test "module exists and exports run/1" do
      assert Code.ensure_loaded?(MigrateJsonlToSqlite)
      assert function_exported?(MigrateJsonlToSqlite, :run, 1)
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(MigrateJsonlToSqlite)
      assert doc =~ "One-time migration tool"
    end
  end

  describe "error handling" do
    test "raises error when JSONL path doesn't exist" do
      assert_raise Mix.Error, ~r/JSONL store directory not found/, fn ->
        MigrateJsonlToSqlite.run(["--jsonl-path", "/nonexistent/path"])
      end
    end

    test "raises error when default path doesn't exist" do
      # Force default resolution through LEMON_STORE_PATH and point it at a missing directory
      tmp_home = Path.join(System.tmp_dir!(), "lemon_test_home_#{:erlang.unique_integer([:positive])}")
      missing_path = Path.join(tmp_home, "does-not-exist")
      File.mkdir_p!(tmp_home)
      
      original_home = System.get_env("HOME")
      original_store_path = System.get_env("LEMON_STORE_PATH")
      
      System.put_env("HOME", tmp_home)
      System.put_env("LEMON_STORE_PATH", missing_path)
      
      try do
        assert_raise Mix.Error, ~r/JSONL store directory not found/, fn ->
          MigrateJsonlToSqlite.run([])
        end
      after
        if original_home, do: System.put_env("HOME", original_home)
        if original_store_path, do: System.put_env("LEMON_STORE_PATH", original_store_path)
        File.rm_rf!(tmp_home)
      end
    end
  end

  describe "with valid JSONL directory" do
    setup do
      # Create a temporary directory structure
      tmp_dir = Path.join(System.tmp_dir!(), "lemon_test_#{:erlang.unique_integer([:positive])}")
      jsonl_path = Path.join(tmp_dir, "store")
      File.mkdir_p!(jsonl_path)
      
      # Create some test JSONL files
      File.write!(Path.join(jsonl_path, "users.jsonl"), Jason.encode!(%{key: "user1", value: %{name: "Alice"}}) <> "\n")
      File.write!(Path.join(jsonl_path, "users.jsonl"), Jason.encode!(%{key: "user2", value: %{name: "Bob"}}) <> "\n", [:append])
      
      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)
      
      {:ok, tmp_dir: tmp_dir, jsonl_path: jsonl_path}
    end

    test "dry-run mode shows table counts", %{jsonl_path: jsonl_path} do
      output = capture_io(fn ->
        MigrateJsonlToSqlite.run(["--jsonl-path", jsonl_path, "--dry-run"])
      end)
      
      assert output =~ "JSONL path:"
      assert output =~ "SQLite path:"
      assert output =~ "Mode: dry-run"
      assert output =~ "Dry run complete"
    end

    test "shows appropriate message when no tables exist", %{jsonl_path: jsonl_path} do
      # Create empty directory
      empty_path = Path.join(jsonl_path, "../empty")
      File.mkdir_p!(empty_path)
      
      output = capture_io(fn ->
        MigrateJsonlToSqlite.run(["--jsonl-path", empty_path, "--dry-run"])
      end)
      
      assert output =~ "Tables to migrate:"
      assert output =~ "Dry run complete. Total rows: 0"
    end

    test "custom SQLite path can be specified", %{jsonl_path: jsonl_path, tmp_dir: tmp_dir} do
      sqlite_path = Path.join(tmp_dir, "custom.db")
      
      output = capture_io(fn ->
        MigrateJsonlToSqlite.run([
          "--jsonl-path", jsonl_path,
          "--sqlite-path", sqlite_path,
          "--dry-run"
        ])
      end)
      
      assert output =~ "SQLite path: #{sqlite_path}"
    end
  end

  describe "environment variables" do
    test "uses LEMON_STORE_PATH when set" do
      tmp_dir = Path.join(System.tmp_dir!(), "lemon_env_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      
      original = System.get_env("LEMON_STORE_PATH")
      System.put_env("LEMON_STORE_PATH", tmp_dir)
      
      on_exit(fn ->
        if original do
          System.put_env("LEMON_STORE_PATH", original)
        else
          System.delete_env("LEMON_STORE_PATH")
        end
        File.rm_rf!(tmp_dir)
      end)
      
      output = capture_io(fn ->
        MigrateJsonlToSqlite.run(["--dry-run"])
      end)
      
      assert output =~ "JSONL path: #{tmp_dir}"
    end

    test "CLI --jsonl-path overrides environment variable" do
      tmp_dir = Path.join(System.tmp_dir!(), "lemon_override_test_#{:erlang.unique_integer([:positive])}")
      jsonl_path = Path.join(tmp_dir, "cli_store")
      env_path = Path.join(tmp_dir, "env_store")
      
      File.mkdir_p!(jsonl_path)
      File.mkdir_p!(env_path)
      
      original = System.get_env("LEMON_STORE_PATH")
      System.put_env("LEMON_STORE_PATH", env_path)
      
      on_exit(fn ->
        if original do
          System.put_env("LEMON_STORE_PATH", original)
        else
          System.delete_env("LEMON_STORE_PATH")
        end
        File.rm_rf!(tmp_dir)
      end)
      
      output = capture_io(fn ->
        MigrateJsonlToSqlite.run(["--jsonl-path", jsonl_path, "--dry-run"])
      end)
      
      assert output =~ "JSONL path: #{jsonl_path}"
      refute output =~ "env_store"
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved" do
      task = Mix.Task.get("lemon.store.migrate_jsonl_to_sqlite")
      assert task == MigrateJsonlToSqlite
    end

    test "task is registered with correct name" do
      assert Mix.Task.task?(MigrateJsonlToSqlite)
    end
  end
end
