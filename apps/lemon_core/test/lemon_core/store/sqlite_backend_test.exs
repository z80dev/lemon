defmodule LemonCore.Store.SqliteBackendTest do
  @moduledoc """
  Tests for the SqliteBackend storage module.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Exqlite.Sqlite3
  alias LemonCore.Store.SqliteBackend

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("sqlite_test_#{:rand.uniform(10_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "init/1" do
    test "creates SQLite database file with directory path", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert File.exists?(Path.join(tmp_dir, "store.sqlite3"))
      assert state.path == Path.join(tmp_dir, "store.sqlite3")
      assert is_reference(state.conn)
      assert is_map(state.statements)
      assert %MapSet{} = state.ephemeral_tables
      assert :runs in state.ephemeral_tables
      :ok = SqliteBackend.close(state)
    end

    test "preserves a trailing slash on a database-named directory", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "store.sqlite3")
      assert {:ok, state} = SqliteBackend.init(path: directory <> "/")
      assert state.path == Path.join(directory, "store.sqlite3")
      assert File.dir?(directory)
      :ok = SqliteBackend.close(state)
    end

    test "creates SQLite database file with explicit file path", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "custom.db")
      assert {:ok, state} = SqliteBackend.init(path: db_path)
      assert File.exists?(db_path)
      assert state.path == db_path
      :ok = SqliteBackend.close(state)
    end

    test "creates SQLite database file with .sqlite3 extension", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "mydata.sqlite3")
      assert {:ok, state} = SqliteBackend.init(path: db_path)
      assert File.exists?(db_path)
      assert state.path == db_path
      :ok = SqliteBackend.close(state)
    end

    test "creates SQLite database file with .sqlite extension", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "mydata.sqlite")
      assert {:ok, state} = SqliteBackend.init(path: db_path)
      assert File.exists?(db_path)
      assert state.path == db_path
      :ok = SqliteBackend.close(state)
    end

    test "creates parent directories if they don't exist", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join([tmp_dir, "level1", "level2", "level3"])
      refute File.exists?(nested_dir)

      assert {:ok, state} = SqliteBackend.init(path: nested_dir)
      assert File.exists?(nested_dir)
      assert File.exists?(Path.join(nested_dir, "store.sqlite3"))
      :ok = SqliteBackend.close(state)
    end

    test "uses custom ephemeral_tables option", %{tmp_dir: tmp_dir} do
      assert {:ok, state} =
               SqliteBackend.init(path: tmp_dir, ephemeral_tables: [:temp_table, :cache])

      assert :temp_table in state.ephemeral_tables
      assert :cache in state.ephemeral_tables
      refute :runs in state.ephemeral_tables
      :ok = SqliteBackend.close(state)
    end

    test "returns error for invalid path", %{tmp_dir: tmp_dir} do
      # Create a file where we try to create a directory
      file_path = Path.join(tmp_dir, "a_file")
      File.write!(file_path, "content")

      # Try to create a directory inside the file (should fail)
      invalid_path = Path.join(file_path, "subdir")

      # Path gets normalized to include store.sqlite3
      normalized_invalid_path = Path.join(invalid_path, "store.sqlite3")

      assert {:error, {:sqlite_init_failed, ^normalized_invalid_path, _}} =
               SqliteBackend.init(path: invalid_path)
    end

    test "closes an opened connection when database initialization fails", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid.sqlite3")
      File.write!(path, "not a SQLite database")

      {result, calls} =
        trace_sqlite_calls(fn -> SqliteBackend.init(path: path) end, open: 1, close: 1)

      assert {:error, {:sqlite_init_failed, ^path, _}} = result
      assert [{:ok, conn}] = returned_calls(calls, :open)
      assert [{Sqlite3, :close, [^conn]}] = called_functions(calls, :close)
      assert [:ok] = returned_calls(calls, :close)
    end

    test "ping checks the connection without writing a probe row", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, ^state} = SqliteBackend.ping(state)
      assert {:ok, [], ^state} = SqliteBackend.list(state, :health_probe)
      :ok = SqliteBackend.close(state)
    end
  end

  describe "put/4 and get/3 roundtrip - persistent tables" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "stores and retrieves string values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, "value1", _} = SqliteBackend.get(state, :mytable, "key1")
    end

    test "stores and retrieves integer keys and values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, 123, 456)
      assert {:ok, 456, _} = SqliteBackend.get(state, :mytable, 123)
    end

    test "stores and retrieves atom keys and values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, :atom_key, :atom_value)
      assert {:ok, :atom_value, _} = SqliteBackend.get(state, :mytable, :atom_key)
    end

    test "stores and retrieves tuple keys and values", %{state: state} do
      tuple_key = {:user, 123}
      tuple_value = {:ok, "success"}

      assert {:ok, state} = SqliteBackend.put(state, :mytable, tuple_key, tuple_value)
      assert {:ok, ^tuple_value, _} = SqliteBackend.get(state, :mytable, tuple_key)
    end

    test "stores and retrieves map values", %{state: state} do
      map_value = %{name: "Test", count: 42, active: true}

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", map_value)
      assert {:ok, ^map_value, _} = SqliteBackend.get(state, :mytable, "key")
    end

    test "stores and retrieves nested structures", %{state: state} do
      nested = %{
        users: [:alice, :bob, :charlie],
        config: %{port: 8080, host: "localhost"},
        tuple: {:ok, "success"},
        nested: %{deep: %{deeper: %{value: :atom}}}
      }

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "complex", nested)
      assert {:ok, ^nested, _} = SqliteBackend.get(state, :mytable, "complex")
    end

    test "stores and retrieves list values", %{state: state} do
      list_value = [1, 2, 3, :atom, %{key: "value"}]

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "list_key", list_value)
      assert {:ok, ^list_value, _} = SqliteBackend.get(state, :mytable, "list_key")
    end

    test "overwrites existing values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", "original")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", "updated")
      assert {:ok, "updated", _} = SqliteBackend.get(state, :mytable, "key")
    end

    test "put_new does not overwrite an existing persistent value", %{state: state} do
      assert {:ok, state} = SqliteBackend.put_new(state, :mytable, "claim", "first")
      assert {:exists, state} = SqliteBackend.put_new(state, :mytable, "claim", "second")
      assert {:ok, "first", _} = SqliteBackend.get(state, :mytable, "claim")
    end

    test "returns nil for missing keys", %{state: state} do
      assert {:ok, nil, _} = SqliteBackend.get(state, :mytable, "nonexistent")
    end

    test "stores and retrieves nil values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "nil_key", nil)
      assert {:ok, nil, _} = SqliteBackend.get(state, :mytable, "nil_key")
    end

    test "stores and retrieves boolean values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "true_key", true)
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "false_key", false)

      assert {:ok, true, _} = SqliteBackend.get(state, :mytable, "true_key")
      assert {:ok, false, _} = SqliteBackend.get(state, :mytable, "false_key")
    end

    test "stores and retrieves empty string", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "empty", "")
      assert {:ok, "", _} = SqliteBackend.get(state, :mytable, "empty")
    end

    test "stores and retrieves unicode strings", %{state: state} do
      unicode = "Hello 🌍 世界 Привет"
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "unicode", unicode)
      assert {:ok, ^unicode, _} = SqliteBackend.get(state, :mytable, "unicode")
    end

    test "table isolation - same key in different tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :table_a, "shared_key", "value_a")
      assert {:ok, state} = SqliteBackend.put(state, :table_b, "shared_key", "value_b")

      assert {:ok, "value_a", _} = SqliteBackend.get(state, :table_a, "shared_key")
      assert {:ok, "value_b", _} = SqliteBackend.get(state, :table_b, "shared_key")
    end

    test "handles deeply nested structures", %{state: state} do
      deep = %{
        level1: %{
          level2: %{
            level3: %{
              level4: %{
                level5: [:deep, :data]
              }
            }
          }
        }
      }

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "deep", deep)
      assert {:ok, ^deep, _} = SqliteBackend.get(state, :mytable, "deep")
    end

    test "handles lists of tuples", %{state: state} do
      value = [{:ok, 1}, {:error, 2}, {:ok, 3}]

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "tuple_list", value)
      assert {:ok, ^value, _} = SqliteBackend.get(state, :mytable, "tuple_list")
    end

    test "handles maps with string keys", %{state: state} do
      value = %{"string_key" => "value", "number" => 42}

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "string_map", value)
      assert {:ok, ^value, _} = SqliteBackend.get(state, :mytable, "string_map")
    end
  end

  describe "put/4 and get/3 roundtrip - ephemeral tables" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "stores and retrieves values in ephemeral table (:runs)", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", %{status: :active})
      assert {:ok, %{status: :active}, _} = SqliteBackend.get(state, :runs, "run1")
    end

    test "ephemeral table data is not in SQLite", %{state: state, tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run_key", "ephemeral_value")
      assert {:ok, "ephemeral_value", _} = SqliteBackend.get(state, :runs, "run_key")

      # Close and reopen - ephemeral data should be gone
      :ok = SqliteBackend.close(state)
      {:ok, new_state} = SqliteBackend.init(path: tmp_dir)

      # Ephemeral data should not persist
      assert {:ok, nil, _} = SqliteBackend.get(new_state, :runs, "run_key")
      :ok = SqliteBackend.close(new_state)
    end

    test "ephemeral table uses ETS storage", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "key", "value")
      # The ephemeral_ets map should contain the :runs table
      assert map_size(state.ephemeral_ets) >= 1
      assert is_reference(state.ephemeral_ets[:runs])
    end

    test "multiple ephemeral tables can be configured", %{tmp_dir: tmp_dir} do
      {:ok, state} =
        SqliteBackend.init(path: tmp_dir, ephemeral_tables: [:cache, :temp, :session])

      on_exit(fn -> SqliteBackend.close(state) end)

      assert {:ok, state} = SqliteBackend.put(state, :cache, "key1", "cached")
      assert {:ok, state} = SqliteBackend.put(state, :temp, "key2", "temporary")
      assert {:ok, state} = SqliteBackend.put(state, :session, "key3", "session_data")

      assert {:ok, "cached", _} = SqliteBackend.get(state, :cache, "key1")
      assert {:ok, "temporary", _} = SqliteBackend.get(state, :temp, "key2")
      assert {:ok, "session_data", _} = SqliteBackend.get(state, :session, "key3")
    end
  end

  describe "persistence across reopen" do
    test "preserves nested atom keys in persisted maps", %{tmp_dir: tmp_dir} do
      world = %{
        status: :in_progress,
        board: %{center: :empty, corners: [:x, :o]},
        meta: %{current_player: :x, turn: 3}
      }

      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, state} = SqliteBackend.put(state, :sim_states, "sim-1", %{world: world})
      :ok = SqliteBackend.close(state)

      {:ok, reopened} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, %{world: ^world}, _} = SqliteBackend.get(reopened, :sim_states, "sim-1")
      :ok = SqliteBackend.close(reopened)
    end
  end

  describe "delete/3" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "removes values from persistent tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", "value")
      assert {:ok, "value", _} = SqliteBackend.get(state, :mytable, "key")

      assert {:ok, state} = SqliteBackend.delete(state, :mytable, "key")
      assert {:ok, nil, _} = SqliteBackend.get(state, :mytable, "key")
    end

    test "removes values from ephemeral tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run_key", "run_data")
      assert {:ok, "run_data", _} = SqliteBackend.get(state, :runs, "run_key")

      assert {:ok, state} = SqliteBackend.delete(state, :runs, "run_key")
      assert {:ok, nil, _} = SqliteBackend.get(state, :runs, "run_key")
    end

    test "succeeds when deleting non-existent key from persistent table", %{state: state} do
      assert {:ok, _} = SqliteBackend.delete(state, :mytable, "nonexistent")
    end

    test "succeeds when deleting non-existent key from ephemeral table", %{state: state} do
      assert {:ok, _} = SqliteBackend.delete(state, :runs, "nonexistent")
    end

    test "only deletes from specified table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :table_a, "shared_key", "value_a")
      assert {:ok, state} = SqliteBackend.put(state, :table_b, "shared_key", "value_b")

      assert {:ok, state} = SqliteBackend.delete(state, :table_a, "shared_key")

      assert {:ok, nil, _} = SqliteBackend.get(state, :table_a, "shared_key")
      assert {:ok, "value_b", _} = SqliteBackend.get(state, :table_b, "shared_key")
    end
  end

  describe "sweep/3" do
    test "persistent and ephemeral predicates preserve timestamp precedence", %{tmp_dir: tmp_dir} do
      cases = [
        {:chat, :expires_at, 1,
         [
           {:old, %{expires_at: 9}},
           {:boundary, %{expires_at: 10}},
           {:string, %{"expires_at" => 1}},
           {:float, %{expires_at: 1.0}},
           {:missing, nil}
         ]},
        {:idempotency, :inserted_at_ms, 1,
         [
           {:old, %{"inserted_at_ms" => 9}},
           {:boundary, %{"inserted_at_ms" => 10}},
           {:atom, %{inserted_at_ms: 1}},
           {:invalid, %{"inserted_at_ms" => "1"}}
         ]},
        {:cron_runs, :started_at_ms, 3,
         [
           {:atom, %{started_at_ms: 9}},
           {:string, %{"started_at_ms" => 9}},
           {:fallback, %{"started_at_ms" => 9, :started_at_ms => :invalid}},
           {:boundary, %{"started_at_ms" => 1, :started_at_ms => 10}},
           {:future, %{"started_at_ms" => 1, :started_at_ms => 11}},
           {:float, %{started_at_ms: 1.0}}
         ]},
        {:introspection_log, :introspection_timestamp, 6,
         [
           {{9, :old}, nil},
           {:atom, %{ts_ms: 9}},
           {:string, %{"ts_ms" => 9}},
           {:nil_fallback, %{"ts_ms" => 9, :ts_ms => nil}},
           {:false_fallback, %{"ts_ms" => 9, :ts_ms => false}},
           {{:not_integer, :fallback}, %{ts_ms: 9}},
           {{10, :boundary}, %{ts_ms: 1}},
           {{11, :future}, %{"ts_ms" => 1}},
           {:atom_boundary, %{"ts_ms" => 1, :ts_ms => 10}},
           {:invalid_atom, %{"ts_ms" => 1, :ts_ms => :invalid}},
           {:invalid_float, %{"ts_ms" => 1, :ts_ms => 1.0}},
           {:missing, nil}
         ]}
      ]

      for mode <- [:persistent, :ephemeral] do
        ephemeral = if mode == :ephemeral, do: Enum.map(cases, &elem(&1, 0)), else: []
        path = Path.join(tmp_dir, "#{mode}.sqlite3")
        {:ok, state} = SqliteBackend.init(path: path, ephemeral_tables: ephemeral)

        state =
          Enum.reduce(cases, state, fn {table, field, count, entries}, state ->
            state = put_entries(state, table, entries)
            assert {:ok, ^count, state} = SqliteBackend.sweep(state, table, {field, 10})
            assert {:ok, remaining, state} = SqliteBackend.list(state, table)
            assert Map.new(remaining) == Map.new(Enum.drop(entries, count))
            assert {:ok, 0, state} = SqliteBackend.sweep(state, table, {field, 10})
            state
          end)

        assert {:ok, 0, _} = SqliteBackend.sweep(state, :unknown, {:expires_at, 10})
        :ok = SqliteBackend.close(state)
      end
    end

    test "a persistent sweep executes one delete without reading rows", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      state = put_entries(state, :chat, for(key <- 1..25, do: {key, %{expires_at: 1}}))
      {:ok, state} = SqliteBackend.put(state, :progress, :old, %{expires_at: 1})
      statement = state.statements[{:sweep, :expires_at}]
      conn = state.conn

      {result, calls} =
        trace_sqlite_calls(
          fn -> SqliteBackend.sweep(state, :chat, {:expires_at, 10}) end,
          step: 2,
          fetch_all: 2,
          execute: 2,
          prepare: 2
        )

      assert {:ok, 25, ^state} = result
      assert [{Sqlite3, :step, [^conn, ^statement]}] = called_functions(calls, :step)
      assert [] == called_functions(calls, :fetch_all)
      assert [] == called_functions(calls, :execute)
      assert [] == called_functions(calls, :prepare)
      assert {:ok, %{expires_at: 1}, _} = SqliteBackend.get(state, :progress, :old)
      :ok = SqliteBackend.close(state)
    end

    test "overwrites, put_new and compare-and-swap keep retention metadata current", %{
      tmp_dir: tmp_dir
    } do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      {:ok, state} = SqliteBackend.put(state, :chat, :refresh, %{expires_at: 1})
      {:ok, state} = SqliteBackend.put(state, :chat, :refresh, %{expires_at: 20})
      {:ok, state} = SqliteBackend.put(state, :chat, :clear, %{expires_at: 1})
      {:ok, state} = SqliteBackend.put(state, :chat, :clear, %{})
      {:ok, state} = SqliteBackend.put_new(state, :chat, :claim, %{expires_at: 20})
      {:exists, state} = SqliteBackend.put_new(state, :chat, :claim, %{expires_at: 1})
      {:ok, state} = SqliteBackend.put_new(state, :chat, :expired_claim, %{expires_at: 1})
      {:ok, state} = SqliteBackend.put(state, :chat, :swap, %{expires_at: 20})

      assert {:ok, state} =
               SqliteBackend.with_durability(state, fn ->
                 SqliteBackend.compare_and_swap(
                   state,
                   :chat,
                   :swap,
                   %{expires_at: 20},
                   %{expires_at: 1}
                 )
               end)

      assert {:ok, 2, state} = SqliteBackend.sweep(state, :chat, {:expires_at, 10})
      assert {:ok, state} = SqliteBackend.sync(state)
      :ok = SqliteBackend.close(state)

      {:ok, reopened} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, rows, _} = SqliteBackend.list(reopened, :chat)

      assert Map.new(rows) == %{
               refresh: %{expires_at: 20},
               clear: %{},
               claim: %{expires_at: 20}
             }

      :ok = SqliteBackend.close(reopened)
    end

    test "large Erlang timestamps round-trip without narrowing retention comparisons", %{
      tmp_dir: tmp_dir
    } do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      beyond = 9_223_372_036_854_775_809
      {:ok, state} = SqliteBackend.put(state, :chat, :past, %{expires_at: -beyond})
      {:ok, state} = SqliteBackend.put(state, :chat, :future, %{expires_at: beyond})
      assert {:ok, %{expires_at: ^beyond}, _} = SqliteBackend.get(state, :chat, :future)

      assert {:ok, 1, state} =
               SqliteBackend.sweep(state, :chat, {:expires_at, -9_223_372_036_854_775_808})

      assert {:ok, 0, state} =
               SqliteBackend.sweep(state, :chat, {:expires_at, 9_223_372_036_854_775_807})

      :ok = SqliteBackend.close(state)
    end
  end

  describe "retention metadata migration" do
    test "backfills existing term rows without changing blobs or concealing corruption", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "legacy.sqlite3")
      conn = legacy_database!(path)

      for {table, key, value} <- [
            {:chat, {:old, :atom_key}, %{expires_at: 9, nested: %{atom: :value}}},
            {:chat, :live, %{expires_at: 10}},
            {:idempotency, :old, %{"inserted_at_ms" => 9}},
            {:cron_runs, :old, %{"started_at_ms" => 9}},
            {:introspection_log, {9, :old}, %{ts_ms: 100}}
          ] do
        insert_corrupt_row!(%{conn: conn}, table, key, :erlang.term_to_binary(value))
      end

      insert_corrupt_row!(%{conn: conn}, :chat, :corrupt, <<0>>)

      assert :ok =
               Sqlite3.execute(conn, """
               INSERT INTO lemon_store_kv (table_name, key_blob, value_blob, updated_at_ms)
               VALUES ('broken_keys', X'00', X'00', 0)
               """)

      original = query_rows!(conn, "SELECT * FROM lemon_store_kv ORDER BY rowid")
      :ok = Sqlite3.close(conn)
      assert {:ok, state} = SqliteBackend.init(path: path)

      assert original ==
               query_rows!(
                 state.conn,
                 "SELECT table_name, key_blob, value_blob, updated_at_ms FROM lemon_store_kv ORDER BY rowid"
               )

      for {table, field} <- [
            chat: :expires_at,
            idempotency: :inserted_at_ms,
            cron_runs: :started_at_ms,
            introspection_log: :introspection_timestamp
          ] do
        assert {:ok, 1, _} = SqliteBackend.sweep(state, table, {field, 10})
      end

      assert {:ok, %{expires_at: 10}, _} = SqliteBackend.get(state, :chat, :live)

      assert {:error, {:sqlite_corrupt_data, _, _}} =
               SqliteBackend.get(state, :chat, :corrupt)

      assert {:error, {:sqlite_corrupt_data, _, _}} = SqliteBackend.list(state, :broken_keys)
      assert {:ok, 0, _} = SqliteBackend.sweep(state, :broken_keys, {:expires_at, 10})
      assert {:ok, state} = SqliteBackend.sync(state)
      :ok = SqliteBackend.close(state)

      assert {:ok, reopened} = SqliteBackend.init(path: path)
      assert {:ok, 0, _} = SqliteBackend.sweep(reopened, :chat, {:expires_at, 10})
      assert {:ok, %{expires_at: 10}, _} = SqliteBackend.get(reopened, :chat, :live)

      assert {:error, {:sqlite_corrupt_data, _, _}} =
               SqliteBackend.get(reopened, :chat, :corrupt)

      :ok = SqliteBackend.close(reopened)
    end

    test "failed backfills roll back schema changes and close their connection", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "legacy.sqlite3")
      conn = legacy_database!(path)
      insert_corrupt_row!(%{conn: conn}, :chat, :old, :erlang.term_to_binary(%{expires_at: 9}))

      assert :ok =
               Sqlite3.execute(conn, """
               CREATE TRIGGER reject_backfill BEFORE UPDATE ON lemon_store_kv
               BEGIN SELECT RAISE(ABORT, 'backfill rejected'); END
               """)

      :ok = Sqlite3.close(conn)

      {result, calls} =
        trace_sqlite_calls(
          fn -> SqliteBackend.init(path: path) end,
          open: 1,
          close: 1,
          prepare: 2,
          release: 2
        )

      assert {:error, {:sqlite_init_failed, ^path, _}} = result
      assert [{:ok, failed_conn}] = returned_calls(calls, :open)
      assert [{Sqlite3, :close, [^failed_conn]}] = called_functions(calls, :close)
      assert [:ok] = returned_calls(calls, :close)
      prepared = for {:ok, statement} <- returned_calls(calls, :prepare), do: statement

      released =
        for {Sqlite3, :release, [_, statement]} <- called_functions(calls, :release),
            do: statement

      assert Enum.sort(prepared) == Enum.sort(released)

      {:ok, conn} = Sqlite3.open(path)
      columns = query_rows!(conn, "PRAGMA table_info(lemon_store_kv)")

      assert Enum.map(columns, &Enum.at(&1, 1)) == [
               "table_name",
               "key_blob",
               "value_blob",
               "updated_at_ms"
             ]

      assert [[1]] = query_rows!(conn, "SELECT COUNT(*) FROM lemon_store_kv")
      assert :ok = Sqlite3.execute(conn, "DROP TRIGGER reject_backfill")
      :ok = Sqlite3.close(conn)
      assert {:ok, state} = SqliteBackend.init(path: path)
      assert {:ok, 1, _} = SqliteBackend.sweep(state, :chat, {:expires_at, 10})
      :ok = SqliteBackend.close(state)
    end
  end

  describe "compare_and_delete_many/2" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "rolls every persistent delete back when a later delete fails", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :atomic_first, "key", "first")
      assert {:ok, state} = SqliteBackend.put(state, :atomic_second, "key", "second")

      assert :ok =
               Sqlite3.execute(state.conn, """
               CREATE TRIGGER fail_atomic_second
               BEFORE DELETE ON lemon_store_kv
               WHEN OLD.table_name = 'atomic_second'
               BEGIN
                 SELECT RAISE(ABORT, 'injected second delete failure');
               END;
               """)

      assert {:error, _reason, ^state} =
               SqliteBackend.compare_and_delete_many(state, [
                 {:atomic_first, "key", "first"},
                 {:atomic_second, "key", "second"}
               ])

      assert {:ok, "first", _} = SqliteBackend.get(state, :atomic_first, "key")
      assert {:ok, "second", _} = SqliteBackend.get(state, :atomic_second, "key")

      assert :ok = Sqlite3.execute(state.conn, "DROP TRIGGER fail_atomic_second")

      assert {:ok, ^state} =
               SqliteBackend.compare_and_delete_many(state, [
                 {:atomic_first, "key", "first"},
                 {:atomic_second, "key", "second"}
               ])

      assert {:ok, nil, _} = SqliteBackend.get(state, :atomic_first, "key")
      assert {:ok, nil, _} = SqliteBackend.get(state, :atomic_second, "key")
    end

    test "validates mixed ephemeral and persistent snapshots before ordered deletion", %{
      state: state
    } do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "ephemeral", "run")
      assert {:ok, state} = SqliteBackend.put(state, :durable_fences, "persistent", "fence")

      assert {:error, :mismatch, state} =
               SqliteBackend.compare_and_delete_many(state, [
                 {:runs, "ephemeral", "wrong"},
                 {:durable_fences, "persistent", "fence"}
               ])

      assert {:ok, "run", state} = SqliteBackend.get(state, :runs, "ephemeral")

      assert {:ok, "fence", state} =
               SqliteBackend.get(state, :durable_fences, "persistent")

      assert {:ok, state} =
               SqliteBackend.compare_and_delete_many(state, [
                 {:runs, "ephemeral", "run"},
                 {:durable_fences, "persistent", "fence"}
               ])

      assert {:ok, nil, state} = SqliteBackend.get(state, :runs, "ephemeral")
      assert {:ok, nil, _state} = SqliteBackend.get(state, :durable_fences, "persistent")
    end
  end

  describe "list/2" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "returns empty list for empty persistent table", %{state: state} do
      assert {:ok, [], _} = SqliteBackend.list(state, :empty_table)
    end

    test "returns empty list for empty ephemeral table", %{state: state} do
      assert {:ok, [], _} = SqliteBackend.list(state, :runs)
    end

    test "returns all key-value pairs from persistent table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key3", "value3")

      assert {:ok, items, _} = SqliteBackend.list(state, :mytable)

      items_map = Map.new(items)
      assert items_map["key1"] == "value1"
      assert items_map["key2"] == "value2"
      assert items_map["key3"] == "value3"
      assert map_size(items_map) == 3
    end

    test "returns all key-value pairs from ephemeral table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data1")
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run2", "data2")

      assert {:ok, items, _} = SqliteBackend.list(state, :runs)

      items_map = Map.new(items)
      assert items_map["run1"] == "data1"
      assert items_map["run2"] == "data2"
      assert map_size(items_map) == 2
    end

    test "does not include deleted items in persistent table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, state} = SqliteBackend.delete(state, :mytable, "key1")

      assert {:ok, items, _} = SqliteBackend.list(state, :mytable)

      items_map = Map.new(items)
      refute Map.has_key?(items_map, "key1")
      assert items_map["key2"] == "value2"
      assert map_size(items_map) == 1
    end

    test "does not include deleted items in ephemeral table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data1")
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run2", "data2")
      assert {:ok, state} = SqliteBackend.delete(state, :runs, "run1")

      assert {:ok, items, _} = SqliteBackend.list(state, :runs)

      items_map = Map.new(items)
      refute Map.has_key?(items_map, "run1")
      assert items_map["run2"] == "data2"
      assert map_size(items_map) == 1
    end

    test "table isolation in list", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :table_a, "key", "value_a")
      assert {:ok, state} = SqliteBackend.put(state, :table_b, "key", "value_b")

      assert {:ok, items_a, _} = SqliteBackend.list(state, :table_a)
      assert {:ok, items_b, _} = SqliteBackend.list(state, :table_b)

      assert [{"key", "value_a"}] = items_a
      assert [{"key", "value_b"}] = items_b
    end

    test "list returns complex data types correctly", %{state: state} do
      complex_value = %{nested: %{deep: :value}, list: [1, 2, 3]}
      assert {:ok, state} = SqliteBackend.put(state, :mytable, :complex_key, complex_value)

      assert {:ok, items, _} = SqliteBackend.list(state, :mytable)
      assert [{:complex_key, ^complex_value}] = items
    end
  end

  describe "list_tables/1" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "returns empty list for fresh database", %{state: state} do
      # Initially no persistent tables, ephemeral tables are lazily created
      tables = SqliteBackend.list_tables(state)
      assert is_list(tables)
    end

    test "returns persistent tables with data", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :users, "u1", "Alice")
      assert {:ok, state} = SqliteBackend.put(state, :products, "p1", "Widget")

      tables = SqliteBackend.list_tables(state)
      assert :users in tables
      assert :products in tables
    end

    test "returns ephemeral tables when accessed", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data")

      tables = SqliteBackend.list_tables(state)
      assert :runs in tables
    end

    test "returns both persistent and ephemeral tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :users, "u1", "Alice")
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data")

      tables = SqliteBackend.list_tables(state)
      assert :users in tables
      assert :runs in tables
    end

    test "no duplicates when same table name in both", %{state: state} do
      # This shouldn't happen in practice, but test for safety
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data")

      tables = SqliteBackend.list_tables(state)
      # Should have unique values
      assert length(tables) == length(Enum.uniq(tables))
    end
  end

  describe "persistence across re-initialization" do
    test "persistent data survives close and reopen", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key1", "value1")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key2", %{nested: "data"})
      {:ok, state1} = SqliteBackend.put(state1, :other_table, "key", "other_value")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, "value1", _} = SqliteBackend.get(state2, :mytable, "key1")
      assert {:ok, %{nested: "data"}, _} = SqliteBackend.get(state2, :mytable, "key2")
      assert {:ok, "other_value", _} = SqliteBackend.get(state2, :other_table, "key")
      :ok = SqliteBackend.close(state2)
    end

    test "deletes persist across re-initialization", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key1", "value1")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key2", "value2")
      {:ok, state1} = SqliteBackend.delete(state1, :mytable, "key1")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, nil, _} = SqliteBackend.get(state2, :mytable, "key1")
      assert {:ok, "value2", _} = SqliteBackend.get(state2, :mytable, "key2")
      :ok = SqliteBackend.close(state2)
    end

    test "overwrites persist correctly across re-initialization", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key", "original")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key", "updated")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key", "final")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, "final", _} = SqliteBackend.get(state2, :mytable, "key")
      :ok = SqliteBackend.close(state2)
    end

    test "complex data types persist correctly", %{tmp_dir: tmp_dir} do
      complex_data = %{
        users: [:alice, :bob, :charlie],
        config: %{port: 8080, host: "localhost"},
        tuple: {:ok, "success"},
        nested: %{deep: %{deeper: %{value: :atom}}}
      }

      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "complex", complex_data)
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, ^complex_data, _} = SqliteBackend.get(state2, :mytable, "complex")
      :ok = SqliteBackend.close(state2)
    end

    test "ephemeral data does not persist across re-initialization", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :runs, "run1", %{status: :active})
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, nil, _} = SqliteBackend.get(state2, :runs, "run1")
      :ok = SqliteBackend.close(state2)
    end

    test "mixed persistent and ephemeral data", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :persistent_table, "key", "persistent_value")
      {:ok, state1} = SqliteBackend.put(state1, :runs, "run_key", "ephemeral_value")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, "persistent_value", _} = SqliteBackend.get(state2, :persistent_table, "key")
      assert {:ok, nil, _} = SqliteBackend.get(state2, :runs, "run_key")
      :ok = SqliteBackend.close(state2)
    end
  end

  describe "close/1" do
    test "closes connection and releases statements", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert :ok = SqliteBackend.close(state)
    end

    test "can close multiple times without error", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert :ok = SqliteBackend.close(state)
      assert :ok = SqliteBackend.close(state)
    end

    test "closes with invalid state gracefully" do
      assert :ok = SqliteBackend.close(%{})
      assert :ok = SqliteBackend.close(nil)
    end

    test "database file remains after close", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "store.sqlite3")
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      :ok = SqliteBackend.close(state)

      assert File.exists?(db_path)
    end
  end

  describe "multiple tables operations" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "can work with many tables simultaneously", %{state: state} do
      tables = [:users, :products, :orders, :inventory, :categories]

      state =
        Enum.reduce(tables, state, fn table, acc_state ->
          {:ok, new_state} = SqliteBackend.put(acc_state, table, "key", "value_#{table}")
          new_state
        end)

      # Verify all tables have data
      for table <- tables do
        expected_value = "value_#{table}"
        assert {:ok, ^expected_value, _} = SqliteBackend.get(state, table, "key")
      end
    end

    test "complex operations across multiple tables", %{state: state} do
      # Insert into multiple tables
      {:ok, state} = SqliteBackend.put(state, :users, "user1", %{name: "Alice", age: 30})
      {:ok, state} = SqliteBackend.put(state, :users, "user2", %{name: "Bob", age: 25})
      {:ok, state} = SqliteBackend.put(state, :products, "prod1", %{name: "Widget", price: 10.99})

      {:ok, state} =
        SqliteBackend.put(state, :orders, "order1", %{user: "user1", items: ["prod1"]})

      # List all tables
      {:ok, users, _} = SqliteBackend.list(state, :users)
      {:ok, products, _} = SqliteBackend.list(state, :products)
      {:ok, orders, _} = SqliteBackend.list(state, :orders)

      assert length(users) == 2
      assert length(products) == 1
      assert length(orders) == 1

      # Delete from one table
      {:ok, state} = SqliteBackend.delete(state, :users, "user1")
      {:ok, users, _} = SqliteBackend.list(state, :users)
      assert length(users) == 1

      # Verify other tables unaffected
      {:ok, products, _} = SqliteBackend.list(state, :products)
      assert length(products) == 1
    end
  end

  describe "state management" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "put returns updated state", %{state: state} do
      assert {:ok, new_state} = SqliteBackend.put(state, :mytable, "key", "value")
      assert {:ok, "value", _} = SqliteBackend.get(new_state, :mytable, "key")
    end

    test "get returns state", %{state: state} do
      assert {:ok, nil, ^state} = SqliteBackend.get(state, :mytable, "key")
    end

    test "delete returns updated state", %{state: state} do
      {:ok, state} = SqliteBackend.put(state, :mytable, "key", "value")
      assert {:ok, new_state} = SqliteBackend.delete(state, :mytable, "key")
      assert {:ok, nil, _} = SqliteBackend.get(new_state, :mytable, "key")
    end

    test "list returns state", %{state: state} do
      assert {:ok, [], ^state} = SqliteBackend.list(state, :mytable)
    end
  end

  describe "backend behavior compliance" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "all callbacks return expected formats", %{state: state} do
      # put returns {:ok, state}
      assert {:ok, state_after_put} = SqliteBackend.put(state, :mytable, "k", "v")
      assert is_map(state_after_put)

      # get returns {:ok, value, state}
      assert {:ok, "v", state_after_get} = SqliteBackend.get(state_after_put, :mytable, "k")
      assert is_map(state_after_get)

      # delete returns {:ok, state}
      assert {:ok, state_after_delete} = SqliteBackend.delete(state_after_get, :mytable, "k")
      assert is_map(state_after_delete)

      # list returns {:ok, items, state}
      assert {:ok, [], state_after_list} = SqliteBackend.list(state_after_delete, :mytable)
      assert is_map(state_after_list)
    end
  end

  describe "list_recent/3" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "list_recent returns limited results ordered by recency", %{state: state} do
      # Put 5 entries with sequential puts so updated_at_ms increases naturally
      {:ok, state} = SqliteBackend.put(state, :recent_table, "a", %{order: 1})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "b", %{order: 2})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "c", %{order: 3})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "d", %{order: 4})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "e", %{order: 5})

      assert {:ok, items, _state} = SqliteBackend.list_recent(state, :recent_table, 2)
      assert length(items) == 2

      # The two most recent entries should be returned (e and d), newest first
      keys = Enum.map(items, fn {key, _val} -> key end)
      assert keys == ["e", "d"]
    end

    test "list_recent with limit larger than entries returns all", %{state: state} do
      {:ok, state} = SqliteBackend.put(state, :small_table, "x", %{val: 1})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :small_table, "y", %{val: 2})

      assert {:ok, items, _state} = SqliteBackend.list_recent(state, :small_table, 100)
      assert length(items) == 2
    end

    test "list_recent with ephemeral table falls back to take", %{state: state} do
      # :runs is ephemeral by default
      {:ok, state} = SqliteBackend.put(state, :runs, "run_1", %{status: :done})
      {:ok, state} = SqliteBackend.put(state, :runs, "run_2", %{status: :active})
      {:ok, state} = SqliteBackend.put(state, :runs, "run_3", %{status: :pending})

      assert {:ok, items, _state} = SqliteBackend.list_recent(state, :runs, 2)
      # Ephemeral tables fall back to Enum.take, so we just verify the count
      assert length(items) == 2
    end
  end

  describe "corrupt SQLite payloads" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "get returns an error for corrupted values", %{state: state} do
      insert_corrupt_row!(state, :mytable, "bad-key", <<0>>)

      assert {:error, {:sqlite_corrupt_data, context, _message}} =
               SqliteBackend.get(state, :mytable, "bad-key")

      assert context.table == :mytable
      assert context.field == :value
      assert context.key == "bad-key"
    end

    test "list returns an error for corrupted rows", %{state: state} do
      insert_corrupt_row!(state, :mytable, "bad-key", <<0>>)

      assert {:error, {:sqlite_corrupt_data, context, _message}} =
               SqliteBackend.list(state, :mytable)

      assert context.table == :mytable
    end

    test "decode returns structured failure without directly logging decoded sensitive keys", %{
      state: state
    } do
      secret = "sqlite-idempotency-secret"
      raw_key = {"integration", secret}
      insert_corrupt_row!(state, :webhook_idempotency, raw_key, <<0>>)

      log =
        capture_log(fn ->
          assert {:error, {:sqlite_corrupt_data, context, _message}} =
                   SqliteBackend.list(state, :webhook_idempotency)

          assert context.key == raw_key
        end)

      refute log =~ secret
    end

    test "list_recent returns an error for corrupted rows", %{state: state} do
      insert_corrupt_row!(state, :mytable, "bad-key", <<0>>)

      assert {:error, {:sqlite_corrupt_data, context, _message}} =
               SqliteBackend.list_recent(state, :mytable, 5)

      assert context.table == :mytable
    end
  end

  describe "compare_and_swap/5 and sync/1" do
    test "a read on one connection does not block its writes after another connection commits",
         %{tmp_dir: tmp_dir} do
      {:ok, a} = SqliteBackend.init(path: tmp_dir)
      {:ok, b} = SqliteBackend.init(path: tmp_dir)
      {:ok, a} = SqliteBackend.put(a, :secrets_lock, :secrets, %{owner: "a"})

      # B sees A's lease, A releases it, then B tries to take it.
      assert {:ok, %{owner: "a"}, b} = SqliteBackend.get(b, :secrets_lock, :secrets)
      {:ok, a} = SqliteBackend.delete(a, :secrets_lock, :secrets)
      assert {:ok, b} = SqliteBackend.put_new(b, :secrets_lock, :secrets, %{owner: "b"})

      # Same for compare-and-swap after a fresh read on B and a write on A.
      assert {:ok, %{owner: "b"}, b} = SqliteBackend.get(b, :secrets_lock, :secrets)
      {:ok, a} = SqliteBackend.put(a, :secrets_lock, :secrets, %{owner: "a2"})

      assert {:ok, b} =
               SqliteBackend.compare_and_swap(b, :secrets_lock, :secrets, %{owner: "a2"}, %{
                 owner: "b2"
               })

      # And a checkpoint on B is not blocked by an outstanding read on A.
      assert {:ok, %{owner: "b2"}, a} = SqliteBackend.get(a, :secrets_lock, :secrets)
      assert {:ok, b} = SqliteBackend.sync(b)

      :ok = SqliteBackend.close(a)
      :ok = SqliteBackend.close(b)
    end

    test "compare-and-swap compares against the shared file, not one connection",
         %{tmp_dir: tmp_dir} do
      {:ok, first} = SqliteBackend.init(path: tmp_dir)
      {:ok, second} = SqliteBackend.init(path: tmp_dir)
      {:ok, first} = SqliteBackend.put(first, :secrets_v1, {"default", "A"}, %{v: 0})

      assert {:ok, _} =
               SqliteBackend.compare_and_swap(first, :secrets_v1, {"default", "A"}, %{v: 0}, %{
                 v: 1
               })

      # The second connection (another OS process sharing the store) still
      # holds the old snapshot; its swap must be refused, not overwrite.
      assert {:error, :mismatch, _} =
               SqliteBackend.compare_and_swap(second, :secrets_v1, {"default", "A"}, %{v: 0}, %{
                 v: 2
               })

      assert {:ok, %{v: 1}, _} = SqliteBackend.get(second, :secrets_v1, {"default", "A"})
      :ok = SqliteBackend.close(first)
      :ok = SqliteBackend.close(second)
    end

    test "sync checkpoints committed writes out of the WAL", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      {:ok, state} = SqliteBackend.put(state, :secrets_v1, {"default", "A"}, %{v: 1})
      wal = Path.join(tmp_dir, "store.sqlite3-wal")
      assert File.stat!(wal).size > 0

      # A read leaves its cached statement on the row, as the store's reads do.
      {:ok, %{v: 1}, state} = SqliteBackend.get(state, :secrets_v1, {"default", "A"})
      {:ok, [_ | _], state} = SqliteBackend.list(state, :secrets_v1)

      assert {:ok, state} = SqliteBackend.sync(state)
      assert File.stat!(wal).size == 0

      {:ok, reader} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, %{v: 1}, _} = SqliteBackend.get(reader, :secrets_v1, {"default", "A"})
      :ok = SqliteBackend.close(reader)
      :ok = SqliteBackend.close(state)
    end
  end

  defp put_entries(state, table, entries) do
    Enum.reduce(entries, state, fn {key, value}, state ->
      {:ok, state} = SqliteBackend.put(state, table, key, value)
      state
    end)
  end

  defp legacy_database!(path) do
    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE lemon_store_kv (
        table_name TEXT NOT NULL,
        key_blob BLOB NOT NULL,
        value_blob BLOB NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY (table_name, key_blob)
      )
      """)

    conn
  end

  defp query_rows!(conn, sql) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      :ok = Sqlite3.release(conn, statement)
    end
  end

  defp trace_sqlite_calls(operation, functions) do
    caller = self()

    worker =
      spawn_link(fn ->
        receive do
          :run ->
            send(caller, {:trace_result, self(), operation.()})

            receive do
              :stop -> :ok
            end
        end
      end)

    for {name, arity} <- functions do
      :erlang.trace_pattern({Sqlite3, name, arity}, [{:_, [], [{:return_trace}]}], [])
    end

    :erlang.trace(worker, true, [:call])

    try do
      send(worker, :run)
      assert_receive {:trace_result, ^worker, result}, 5_000
      barrier = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^barrier}
      {result, collect_trace_calls(worker, [])}
    after
      :erlang.trace(worker, false, [:call])

      for {name, arity} <- functions do
        :erlang.trace_pattern({Sqlite3, name, arity}, false, [])
      end

      send(worker, :stop)
    end
  end

  defp collect_trace_calls(worker, acc) do
    receive do
      {:trace, ^worker, :call, call} ->
        collect_trace_calls(worker, [{:call, call} | acc])

      {:trace, ^worker, :return_from, mfa, result} ->
        collect_trace_calls(worker, [{:return, mfa, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp called_functions(calls, name) do
    for {:call, {Sqlite3, ^name, _args} = call} <- calls, do: call
  end

  defp returned_calls(calls, name) do
    for {:return, {Sqlite3, ^name, _arity}, result} <- calls, do: result
  end

  defp insert_corrupt_row!(state, table, key, corrupt_value_blob) do
    table_name = Atom.to_string(table)
    key_blob = :erlang.term_to_binary(key) |> Base.encode16(case: :upper)
    value_blob = Base.encode16(corrupt_value_blob, case: :upper)

    sql = """
    INSERT INTO lemon_store_kv (table_name, key_blob, value_blob, updated_at_ms)
    VALUES ('#{table_name}', X'#{key_blob}', X'#{value_blob}', 0)
    """

    assert :ok = Sqlite3.execute(state.conn, sql)
  end
end
