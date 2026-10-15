defmodule CodingAgent.Tools.WriteSqliteTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.{Sqlite, Write}
  alias Exqlite.Sqlite3
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    db = Path.join(dir, "app.db")
    {:ok, conn} = Sqlite3.open(db)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT DEFAULT 'default', active INTEGER);
      CREATE TABLE tags (label TEXT);
      CREATE TABLE codes (code TEXT PRIMARY KEY, name TEXT) WITHOUT ROWID;
      CREATE TABLE pairs (a TEXT, b TEXT, PRIMARY KEY(a,b));
      CREATE TABLE "odd table" ("odd column" TEXT);
      INSERT INTO users VALUES (1, 'old', 0);
      INSERT INTO tags VALUES ('old');
      INSERT INTO codes VALUES ('007', 'old');
      """)

    :ok = Sqlite3.close(conn)
    %{db: db}
  end

  defp write(dir, path, content, opts \\ []) do
    Write.execute("write", %{"path" => path, "content" => content}, nil, nil, dir, opts)
  end

  defp rows(db, sql) do
    Sqlite.with_connection(db, :readonly, fn conn ->
      {:ok, _, rows, _} = Sqlite.query(conn, sql)
      rows
    end)
  end

  test "inserts scalar JSON and default rows, with parameterized values", %{tmp_dir: dir, db: db} do
    assert %AgentToolResult{details: %{action: :insert, rows_affected: 1}} =
             write(
               dir,
               "app.db:users",
               Jason.encode!(%{name: "'); DROP TABLE users; --", active: true})
             )

    assert %AgentToolResult{} = write(dir, "app.db:users", "{}")

    assert [["old", 0], ["'); DROP TABLE users; --", 1], ["default", nil]] =
             rows(db, "SELECT name, active FROM users ORDER BY id")

    assert %AgentToolResult{} = write(dir, "app.db:odd table", ~s({"odd column":"ok"}))
    assert [["ok"]] = rows(db, ~s(SELECT * FROM "odd table"))
  end

  test "updates and deletes by PK including text keys, or rowid", %{tmp_dir: dir, db: db} do
    for path <- ["app.db:users:1", "app.db:tags:1", "app.db:codes:007"] do
      field = if String.contains?(path, ":tags:"), do: "label", else: "name"

      assert %AgentToolResult{details: %{rows_affected: 1}} =
               write(dir, path, Jason.encode!(%{field => "new"}))

      assert %AgentToolResult{details: %{action: :delete, rows_affected: 1}} =
               write(dir, path, " \n")
    end

    assert [[0]] = rows(db, "SELECT count(*) FROM users")

    assert %AgentToolResult{details: %{rows_affected: 0}} =
             write(dir, "app.db:users:999", ~s({"name":"absent"}))

    assert %AgentToolResult{details: %{rows_affected: 0}} =
             write(dir, "app.db:users:1' OR 1=1 --", "")
  end

  test "rejects invalid payloads, columns, selectors and composite keys safely", %{
    tmp_dir: dir,
    db: db
  } do
    for {path, body} <- [
          {"app.db:users", "[]"},
          {"app.db:users", "not JSON secret"},
          {"app.db:users", ~s({"name": {"secret": 1}})},
          {"app.db:users", ~s({"missing secret": 1})},
          {"app.db:users:1", "{}"},
          {"app.db:users:", "{}"},
          {"app.db:users?q=x", "{}"},
          {"app.db:users;DROP TABLE users", "{}"},
          {"app.db:pairs:a", ""}
        ] do
      assert {:error, message} = write(dir, path, body)
      refute message =~ "secret"
    end

    assert [[1]] = rows(db, "SELECT count(*) FROM users")
  end

  test "never creates missing databases and rejects symlinks and directories", %{
    tmp_dir: dir,
    db: db
  } do
    assert {:error, _} = write(dir, "missing.db:users", "{}")
    refute File.exists?(Path.join(dir, "missing.db"))
    refute File.exists?(Path.join(dir, "missing.db:users"))
    File.ln_s!(db, Path.join(dir, "link.db"))
    assert {:error, _} = write(dir, "link.db:users", "{}")
    File.mkdir!(Path.join(dir, "dir.db"))
    assert {:error, _} = write(dir, "dir.db:users", "{}")
  end

  test "checkpoints the physical database and honors abort", %{tmp_dir: dir, db: db} do
    session = "sqlite-write-#{System.unique_integer([:positive])}"
    on_exit(fn -> CodingAgent.Checkpoint.delete_all(session) end)

    assert %AgentToolResult{details: %{checkpoint_id: id}} =
             write(dir, "app.db:users:1", ~s({"name":"changed"}), session_id: session)

    assert [["changed"]] = rows(db, "SELECT name FROM users")
    assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(id)
    assert [["old"]] = rows(db, "SELECT name FROM users")

    signal = LemonAgent.AbortSignal.new()
    LemonAgent.AbortSignal.abort(signal)
    on_exit(fn -> LemonAgent.AbortSignal.clear(signal) end)

    assert {:error, :aborted} =
             Write.execute(
               "abort",
               %{"path" => "app.db:users:1", "content" => ""},
               signal,
               nil,
               dir,
               []
             )

    assert [["old"]] = rows(db, "SELECT name FROM users")
  end

  test "shared readwrite connection does not create a database", %{tmp_dir: dir} do
    path = Path.join(dir, "absent.db")
    assert {:error, _} = Sqlite.with_connection(path, :readwrite, fn _ -> flunk("opened") end)
    refute File.exists?(path)
  end

  test "database writes use the physical path lock and busy timeout", %{tmp_dir: dir, db: db} do
    parent = self()

    task =
      CodingAgent.MutationLock.with_lock(CodingAgent.MutationLock.path_key(db), fn ->
        task =
          Task.async(fn ->
            send(parent, :starting_sqlite_write)
            write(dir, "app.db:users:1", ~s({"name":"locked"}))
          end)

        assert_receive :starting_sqlite_write
        assert Task.yield(task, 20) == nil
        assert [["old"]] = rows(db, "SELECT name FROM users")
        task
      end)

    assert %AgentToolResult{} = Task.await(task)
    assert [["locked"]] = rows(db, "SELECT name FROM users")

    assert {:ok, _, [[3000]], _} =
             Sqlite.with_connection(db, :readwrite, &Sqlite.query(&1, "PRAGMA busy_timeout"))
  end

  test "literal selector-shaped files retain normal write behavior", %{tmp_dir: dir} do
    path = Path.join(dir, "app.db:literal")
    File.write!(path, "before")
    assert %AgentToolResult{} = write(dir, "app.db:literal", "after")
    assert File.read!(path) == "after"
  end
end
