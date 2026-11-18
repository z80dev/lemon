defmodule LemonCore.Store.DurableWriteTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias LemonCore.Store
  alias LemonCore.Store.SqliteBackend

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "durable_write_#{System.unique_integer([:positive, :monotonic])}.db"
      )

    store =
      start_supervised!(
        {Store,
         name: __MODULE__,
         backend: SqliteBackend,
         cached_tables: [],
         backend_opts: [path: path, ephemeral_tables: []]}
      )

    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:lemon, :store, :sqlite, :durable_write], [:lemon, :store, :sqlite, :checkpoint]],
        fn event, _, metadata, _ ->
          if self() == store do
            case event do
              [:lemon, :store, :sqlite, :durable_write] ->
                send(
                  owner,
                  {:durable_mode, pragma(metadata.conn, "synchronous"),
                   pragma(metadata.conn, "fullfsync")}
                )

              _ ->
                send(owner, :checkpoint)
            end
          end
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    %{store: store}
  end

  test "only durable writes use FULL; ordinary writes remain NORMAL", %{store: store} do
    assert :ok = Store.put(store, :run_receipts, "receipt", true, durable: true)
    assert_received {:durable_mode, 2, fullfsync}
    assert fullfsync == if(match?({:unix, :darwin}, :os.type()), do: 1, else: 0)
    refute_received :checkpoint
    assert :ok = Store.put(store, :chat, "ordinary", true)
    conn = :sys.get_state(store).backend_state.conn
    assert pragma(conn, "synchronous") == 1
    assert pragma(conn, "fullfsync") == 0
    refute_received {:durable_mode, _, _}
    assert {:ok, true} = Store.fetch(store, :run_receipts, "receipt")
    refute_received :checkpoint
  end

  test "drain sync still checkpoints while durable writes do not", %{store: store} do
    assert :ok = Store.put(store, :run_receipts, "receipt", true, durable: true)
    refute_received :checkpoint
    conn = :sys.get_state(store).backend_state.conn
    assert pragma(conn, "synchronous") == 1
    assert :ok = Store.sync(store)
    assert_received :checkpoint
    path = :sys.get_state(store).backend_state.path
    assert File.stat!(path <> "-wal").size == 0
  end

  @tag capture_log: true
  test "failed durable transaction is outcome unknown and restores NORMAL", %{store: store} do
    conn = :sys.get_state(store).backend_state.conn
    assert :ok = Store.put(store, :run_receipts, "failed", true)

    :ok =
      Sqlite3.execute(conn, """
      PRAGMA foreign_keys=ON;
      CREATE TABLE parent (id INTEGER PRIMARY KEY);
      CREATE TABLE child (parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER fail_at_commit AFTER UPDATE ON lemon_store_kv
      BEGIN INSERT INTO child VALUES (999); END;
      """)

    # The deferred foreign key is checked at COMMIT, not at UPDATE.
    assert {:error, :outcome_unknown} =
             Store.compare_and_swap(store, :run_receipts, "failed", true, false, durable: true)

    assert pragma(conn, "synchronous") == 1
    assert pragma(conn, "fullfsync") == 0
    refute_received :checkpoint
  end

  test "durable take consumes under FULL and returns the value once", %{store: store} do
    assert :ok = Store.put(store, :confirmations, "token", %{scope: 1})
    assert %{scope: 1} = Store.take(store, :confirmations, "token", durable: true)
    assert_received {:durable_mode, 2, _fullfsync}
    assert {:ok, nil} = Store.fetch(store, :confirmations, "token")
    assert Store.take(store, :confirmations, "token", durable: true) == nil
    conn = :sys.get_state(store).backend_state.conn
    assert pragma(conn, "synchronous") == 1
  end

  @tag capture_log: true
  test "a failed durable take is outcome unknown and keeps the entry", %{store: store} do
    conn = :sys.get_state(store).backend_state.conn
    assert :ok = Store.put(store, :confirmations, "token", %{scope: 1})

    :ok =
      Sqlite3.execute(conn, """
      PRAGMA foreign_keys=ON;
      CREATE TABLE parent (id INTEGER PRIMARY KEY);
      CREATE TABLE child (parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER fail_take_at_commit AFTER DELETE ON lemon_store_kv
      BEGIN INSERT INTO child VALUES (999); END;
      """)

    assert {:error, :outcome_unknown} =
             Store.take(store, :confirmations, "token", durable: true)

    assert {:ok, %{scope: 1}} = Store.fetch(store, :confirmations, "token")
    assert pragma(conn, "synchronous") == 1
  end

  defp pragma(conn, name) do
    {:ok, statement} = Sqlite3.prepare(conn, "PRAGMA " <> name)

    try do
      {:row, [value]} = Sqlite3.step(conn, statement)
      value
    after
      Sqlite3.release(conn, statement)
    end
  end
end
