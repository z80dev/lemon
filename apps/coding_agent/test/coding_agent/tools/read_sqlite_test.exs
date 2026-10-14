defmodule CodingAgent.Tools.ReadSqliteTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Read
  alias Exqlite.Sqlite3
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    db = Path.join(tmp_dir, "app.db")
    {:ok, conn} = Sqlite3.open(db)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, avatar BLOB);
      CREATE TABLE tags (label TEXT);
      CREATE VIEW adults AS SELECT name FROM users WHERE age >= 18;
      """)

    for i <- 1..30 do
      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO users (name, age, avatar) VALUES ('user#{i}', #{i}, x'00ff')"
        )
    end

    :ok = Sqlite3.execute(conn, "INSERT INTO tags VALUES ('a'), ('b')")
    :ok = Sqlite3.close(conn)
    %{db: db}
  end

  defp read(tmp_dir, path, extra \\ %{}) do
    Read.execute("call", Map.put(extra, "path", path), nil, nil, tmp_dir, [])
  end

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  test "lists tables and views with row counts", %{tmp_dir: tmp_dir} do
    result = read(tmp_dir, "app.db")
    assert %AgentToolResult{details: %{format: :sqlite, selector: :list}} = result
    assert text(result) =~ "users (table, 30 rows)"
    assert text(result) =~ "tags (table, 2 rows)"
    assert text(result) =~ "adults (view, 13 rows)"
  end

  test "table selector shows schema and sample rows", %{tmp_dir: tmp_dir} do
    output = text(read(tmp_dir, "app.db:users"))
    assert output =~ "CREATE TABLE users"
    assert output =~ "user5"
    refute output =~ "user6 "
    assert output =~ "<blob 2 bytes>"
    assert output =~ "[25 more rows; use :users?limit=20&offset=5 to continue]"
  end

  test "paging with where and order", %{tmp_dir: tmp_dir} do
    output = text(read(tmp_dir, "app.db:users?where=age%3E20&order=age%20DESC&limit=3"))
    assert output =~ "Rows 1-3 of 10"
    assert output =~ ~r/user30.*\n.*user29.*\n.*user28/
    assert output =~ "[Use offset=3 for the next page]"

    last = text(read(tmp_dir, "app.db:users?where=age>20&order=age&limit=5&offset=8"))
    assert last =~ "Rows 9-10 of 10"
    refute last =~ "next page"
  end

  test "row selector uses the primary key or rowid", %{tmp_dir: tmp_dir} do
    assert text(read(tmp_dir, "app.db:users:7")) =~ "2: name: user7\n3: age: 7"
    assert text(read(tmp_dir, "app.db:tags:2")) =~ "label: b"
    assert text(read(tmp_dir, "app.db:users:999")) =~ "No row found in table 'users'"
  end

  test "raw read queries", %{tmp_dir: tmp_dir} do
    output = text(read(tmp_dir, "app.db?q=SELECT count(*) AS n FROM users WHERE age < 10"))
    assert output =~ "1 row(s)"
    assert output =~ "2: n\n3: -\n4: 9"
  end

  test "rejects writes and statement smuggling", %{tmp_dir: tmp_dir, db: db} do
    assert {:error, "SQLite q may not use DELETE" <> _} =
             read(tmp_dir, "app.db?q=DELETE FROM users")

    assert {:error, "SQLite where must be a single statement" <> _} =
             read(tmp_dir, "app.db:users?where=1;DROP TABLE users")

    assert {:error, "SQLite q may not use ATTACH" <> _} =
             read(tmp_dir, "app.db?q=ATTACH 'x.db' AS x")

    # Even a write disguised past the keyword guard fails on the read-only handle.
    assert {:error, message} = read(tmp_dir, "app.db?q=WITH x AS (SELECT 1) SELECT * FROM nope")
    assert message =~ "no such table"

    {:ok, conn} = Sqlite3.open(db)
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT count(*) FROM users")
    assert {:row, [30]} = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    Sqlite3.close(conn)
  end

  test "non-SQLite .db files fall back to the ordinary reader", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "plain.db"), "just text\n")
    assert text(read(tmp_dir, "plain.db")) =~ "1: just text"
  end
end
