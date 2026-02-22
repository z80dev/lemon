defmodule LemonCore.Store.SqliteBackend do
  @moduledoc """
  SQLite-backed storage backend with optional ephemeral tables.

  Most tables are persisted in a single SQLite database. High-churn tables
  (like `:runs`) can be configured as ephemeral to avoid disk write amplification.
  Ephemeral tables are stored in ETS only.

  ## Options

    * `:path` - Required. Path to SQLite file, or a directory (then `store.sqlite3` is used)
    * `:ephemeral_tables` - Optional list of table atoms to keep in ETS (default: `[:runs]`)
  """

  @behaviour LemonCore.Store.Backend

  alias Exqlite.Sqlite3
  alias Exqlite.Error, as: ExqliteError

  @default_ephemeral_tables [:runs]
  @default_filename "store.sqlite3"

  @schema_sql """
  CREATE TABLE IF NOT EXISTS lemon_store_kv (
    table_name TEXT NOT NULL,
    key_blob BLOB NOT NULL,
    value_blob BLOB NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (table_name, key_blob)
  );
  """

  @put_sql """
  INSERT INTO lemon_store_kv (table_name, key_blob, value_blob, updated_at_ms)
  VALUES (?1, ?2, ?3, ?4)
  ON CONFLICT(table_name, key_blob) DO UPDATE SET
    value_blob = excluded.value_blob,
    updated_at_ms = excluded.updated_at_ms
  """

  @get_sql """
  SELECT value_blob
  FROM lemon_store_kv
  WHERE table_name = ?1 AND key_blob = ?2
  LIMIT 1
  """

  @delete_sql """
  DELETE FROM lemon_store_kv
  WHERE table_name = ?1 AND key_blob = ?2
  """

  @list_sql """
  SELECT key_blob, value_blob
  FROM lemon_store_kv
  WHERE table_name = ?1
  """

  @list_tables_sql "SELECT DISTINCT table_name FROM lemon_store_kv"

  @impl true
  def init(opts) do
    raw_path = Keyword.fetch!(opts, :path)
    path = normalize_path(raw_path)
    ephemeral_tables = Keyword.get(opts, :ephemeral_tables, @default_ephemeral_tables)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- init_db(conn),
         {:ok, statements} <- prepare_statements(conn) do
      {:ok,
       %{
         path: path,
         conn: conn,
         statements: statements,
         ephemeral_tables: MapSet.new(ephemeral_tables),
         ephemeral_ets: %{}
       }}
    else
      {:error, reason} ->
        {:error, {:sqlite_init_failed, path, reason}}
    end
  end

  @impl true
  def put(state, table, key, value) do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)
      :ets.insert(table_ets, {key, value})
      {:ok, state}
    else
      table_name = normalize_table_name(table)
      encoded_key = encode(key)
      encoded_value = encode(value)
      now_ms = System.system_time(:millisecond)

      with :ok <-
             bind_statement(state.statements.put, [
               table_name,
               {:blob, encoded_key},
               {:blob, encoded_value},
               now_ms
             ]),
           :done <- Sqlite3.step(state.conn, state.statements.put) do
        {:ok, state}
      else
        :busy -> {:error, :sqlite_busy}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_put_failed, other}}
      end
    end
  end

  @impl true
  def get(state, table, key) do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)

      value =
        case :ets.lookup(table_ets, key) do
          [{^key, found}] -> found
          _ -> nil
        end

      {:ok, value, state}
    else
      table_name = normalize_table_name(table)
      encoded_key = encode(key)

      with :ok <- bind_statement(state.statements.get, [table_name, {:blob, encoded_key}]) do
        case Sqlite3.step(state.conn, state.statements.get) do
          {:row, [value_blob]} ->
            case decode(value_blob) do
              nil -> {:ok, nil, state}
              value -> {:ok, value, state}
            end

          :done ->
            {:ok, nil, state}

          :busy ->
            {:error, :sqlite_busy}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:sqlite_get_failed, other}}
        end
      end
    end
  end

  @impl true
  def delete(state, table, key) do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)
      :ets.delete(table_ets, key)
      {:ok, state}
    else
      table_name = normalize_table_name(table)
      encoded_key = encode(key)

      with :ok <- bind_statement(state.statements.delete, [table_name, {:blob, encoded_key}]),
           :done <- Sqlite3.step(state.conn, state.statements.delete) do
        {:ok, state}
      else
        :busy -> {:error, :sqlite_busy}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_delete_failed, other}}
      end
    end
  end

  @impl true
  def list(state, table) do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)
      items = :ets.tab2list(table_ets)
      {:ok, items, state}
    else
      table_name = normalize_table_name(table)

      with :ok <- bind_statement(state.statements.list, [table_name]),
           {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.statements.list) do
        items =
          Enum.flat_map(rows, fn [key_blob, value_blob] ->
            key = decode(key_blob)
            value = decode(value_blob)
            # Filter out corrupted entries
            if key != nil and value != nil do
              [{key, value}]
            else
              []
            end
          end)

        {:ok, items, state}
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_list_failed, other}}
      end
    end
  end

  @doc """
  Returns all table names currently present.
  """
  @spec list_tables(map()) :: [atom()]
  def list_tables(state) do
    persistent_tables =
      with :ok <- bind_statement(state.statements.list_tables, []),
           {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.statements.list_tables) do
        rows
        |> Enum.map(fn [table_name] -> table_name end)
        |> Enum.map(&String.to_atom/1)
      else
        _ -> []
      end

    (persistent_tables ++ Map.keys(state.ephemeral_ets))
    |> Enum.uniq()
  end

  @doc """
  Closes prepared statements and SQLite connection.
  """
  @spec close(map()) :: :ok
  def close(%{conn: conn, statements: statements}) do
    Enum.each(Map.values(statements), fn stmt ->
      _ = Sqlite3.release(conn, stmt)
    end)

    _ = Sqlite3.close(conn)
    :ok
  end

  def close(_), do: :ok

  defp init_db(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(conn, @schema_sql) do
      :ok
    end
  end

  defp prepare_statements(conn) do
    with {:ok, put_stmt} <- Sqlite3.prepare(conn, @put_sql),
         {:ok, get_stmt} <- Sqlite3.prepare(conn, @get_sql),
         {:ok, delete_stmt} <- Sqlite3.prepare(conn, @delete_sql),
         {:ok, list_stmt} <- Sqlite3.prepare(conn, @list_sql),
         {:ok, list_tables_stmt} <- Sqlite3.prepare(conn, @list_tables_sql) do
      {:ok,
       %{
         put: put_stmt,
         get: get_stmt,
         delete: delete_stmt,
         list: list_stmt,
         list_tables: list_tables_stmt
       }}
    else
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp normalize_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    ext = String.downcase(Path.extname(expanded))

    cond do
      File.dir?(expanded) ->
        Path.join(expanded, @default_filename)

      String.ends_with?(expanded, "/") ->
        Path.join(expanded, @default_filename)

      ext in [".db", ".sqlite", ".sqlite3"] ->
        expanded

      true ->
        # Preserve backward compatibility with prior directory-style config
        # (`LEMON_STORE_PATH=/var/lib/lemon/store`).
        Path.join(expanded, @default_filename)
    end
  end

  defp normalize_path(path), do: path |> to_string() |> normalize_path()

  defp normalize_table_name(table) when is_atom(table), do: Atom.to_string(table)
  defp normalize_table_name(table), do: to_string(table)

  defp ephemeral_table?(%{ephemeral_tables: %MapSet{} = set}, table) when is_atom(table) do
    MapSet.member?(set, table)
  end

  defp ephemeral_table?(_state, _table), do: false

  defp ensure_ephemeral_table(state, table) do
    case state.ephemeral_ets do
      %{^table => tid} ->
        {tid, state}

      _ ->
        tid = :ets.new(:lemon_core_store_sqlite_ephemeral, [:set, :protected])
        {tid, %{state | ephemeral_ets: Map.put(state.ephemeral_ets, table, tid)}}
    end
  end

  defp bind_statement(statement, params) do
    try do
      with :ok <- Sqlite3.reset(statement),
           :ok <- Sqlite3.bind(statement, params) do
        :ok
      end
    rescue
      e in ExqliteError ->
        {:error, classify_bind_error(e)}

      e ->
        {:error, {:sqlite_bind_failed, Exception.message(e)}}
    end
  end

  defp classify_bind_error(%ExqliteError{} = error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "too big") do
      {:sqlite_bind_failed, :blob_too_big}
    else
      {:sqlite_bind_failed, message}
    end
  end

  defp encode(term), do: :erlang.term_to_binary(term)
  
  defp decode(binary) do
    :erlang.binary_to_term(binary)
  rescue
    ArgumentError -> 
      # Corrupted or invalid binary data
      nil
  end
end
