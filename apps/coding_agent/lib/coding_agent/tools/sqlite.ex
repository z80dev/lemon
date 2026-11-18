defmodule CodingAgent.Tools.Sqlite do
  @moduledoc false

  alias Exqlite.Sqlite3

  def ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # Read views open an existing database file read-only (`SQLITE_OPEN_READONLY`
  # never creates one) with `PRAGMA query_only`.
  def with_connection(path, :readonly, fun) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, conn} ->
        try do
          with :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout = 3000"),
               :ok <- Sqlite3.execute(conn, "PRAGMA query_only = 1") do
            fun.(conn)
          end
        after
          Sqlite3.close(conn)
        end

      {:error, _} ->
        {:error, "Cannot open SQLite database"}
    end
  end

  @doc """
  Run `fun` on a private in-memory copy of the database image `bytes`.

  SQLite never gets a filesystem path: it creates no journal, WAL or temp
  file (`temp_store = MEMORY`) and follows no symlink. When `fun` returns
  `{:ok, result}` this returns `{:ok, result, image}` with the database image
  after `fun`. An image in WAL format (file format bytes 18-19 = 2) is opened
  in rollback format, since no WAL file belongs to it, and the returned image
  is put back in WAL format.
  """
  def with_image(bytes, fun) when is_binary(bytes) do
    {wal?, image} = rollback_format(bytes)

    case Sqlite3.open(":memory:") do
      {:ok, conn} ->
        try do
          with :ok <- deserialize(conn, image),
               :ok <- Sqlite3.execute(conn, "PRAGMA temp_store = MEMORY"),
               {:ok, result} <- fun.(conn),
               {:ok, image} <- Sqlite3.serialize(conn, "main") do
            {:ok, result, if(wal?, do: wal_format(image), else: image)}
          end
        after
          Sqlite3.close(conn)
        end

      {:error, _} ->
        {:error, "Cannot open SQLite database"}
    end
  end

  defp deserialize(conn, image) do
    case Sqlite3.deserialize(conn, "main", image) do
      :ok -> :ok
      {:error, _} -> {:error, "Cannot open SQLite database"}
    end
  end

  defp rollback_format(<<head::binary-size(18), 2, 2, rest::binary>>),
    do: {true, <<head::binary, 1, 1, rest::binary>>}

  defp rollback_format(bytes), do: {false, bytes}

  defp wal_format(<<head::binary-size(18), _write, _read, rest::binary>>),
    do: <<head::binary, 2, 2, rest::binary>>

  def query(conn, sql, args \\ [], max_rows \\ :infinity) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, args),
             {:ok, columns} <- Sqlite3.columns(conn, stmt),
             {:ok, rows, truncated?} <- collect(conn, stmt, max_rows, []) do
          {:ok, columns, rows, truncated?}
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
    |> case do
      {:error, _} ->
        {:error, "SQLite statement failed (invalid query, constraint, or unavailable database)"}

      ok ->
        ok
    end
  end

  defp collect(_conn, _stmt, max, acc) when is_integer(max) and length(acc) >= max,
    do: {:ok, Enum.reverse(acc), true}

  defp collect(conn, stmt, max, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect(conn, stmt, max, [row | acc])
      :done -> {:ok, Enum.reverse(acc), false}
      :busy -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  def table_sql(conn, table) do
    case query(
           conn,
           "SELECT sql FROM sqlite_schema WHERE name = ? AND type IN ('table','view')",
           [table]
         ) do
      {:ok, _, [[sql]], _} -> {:ok, sql || "(no schema SQL)"}
      {:ok, _, [], _} -> {:error, "SQLite table or view not found"}
      {:error, _} = error -> error
    end
  end

  def table_info(conn, table) do
    case query(conn, "SELECT name, pk FROM pragma_table_info(?) ORDER BY cid", [table]) do
      {:ok, _, [], _} -> {:error, "SQLite table not found"}
      {:ok, _, rows, _} -> {:ok, rows}
      {:error, _} = error -> error
    end
  end

  def row_lookup(conn, table) do
    with {:ok, rows} <- table_info(conn, table) do
      case Enum.filter(rows, fn [_, pk] -> pk > 0 end) do
        [[column, _]] -> {:ok, ident(column)}
        [] -> rowid_lookup(conn, table, rows)
        _ -> {:error, "SQLite row selectors do not support composite primary keys"}
      end
    end
  end

  defp rowid_lookup(conn, table, rows) do
    names = Enum.map(rows, fn [name, _] -> String.downcase(name) end)

    case Enum.find(["rowid", "_rowid_", "oid"], &(&1 not in names)) do
      nil ->
        {:error, "SQLite rowid is unavailable"}

      name ->
        case query(conn, "SELECT #{ident(name)} FROM #{ident(table)} LIMIT 0") do
          {:ok, _, _, _} -> {:ok, ident(name)}
          _ -> {:error, "SQLite rowid is unavailable"}
        end
    end
  end
end
