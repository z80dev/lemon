defmodule LemonCore.Store.SqliteBackend do
  @moduledoc """
  SQLite-backed storage backend with optional ephemeral tables.

  Most tables are persisted in a single SQLite database. High-churn tables
  (like `:runs`) can be configured as ephemeral to avoid disk write amplification.
  Ephemeral tables are stored in ETS only.

  Retention timestamps, and a value's `:at_ms` event time, are indexed
  alongside the term-encoded payloads. Existing databases are backfilled
  transactionally on first open; undecodable rows are retained without that
  metadata and still produce explicit read errors.

  ## Concurrent reads

  `reader/1` hands the Store a handle for full-table and time-range reads that
  run in the calling process: each such read opens its own read-only
  connection (WAL readers never block the writer, and a private connection
  cannot share another caller's older read snapshot), and ephemeral tables are
  read from their protected ETS tables through a directory table.

  ## Options

    * `:path` - Required. Path to SQLite file, or a directory (then `store.sqlite3` is used)
    * `:ephemeral_tables` - Optional list of table atoms to keep in ETS (default: `[:runs]`)
  """

  @behaviour LemonCore.Store.Backend

  require Logger

  alias Exqlite.Sqlite3
  alias Exqlite.Error, as: ExqliteError

  @compile {:no_warn_undefined, [Exqlite.Sqlite3, Exqlite.Error]}

  @default_ephemeral_tables [:runs]
  @default_filename "store.sqlite3"
  @min_timestamp -9_223_372_036_854_775_808
  @max_timestamp 9_223_372_036_854_775_807
  @sweep_columns [
    expires_at: "expires_at_ms",
    introspection_timestamp: "introspection_ts_ms",
    inserted_at_ms: "inserted_at_ms",
    started_at_ms: "started_at_ms"
  ]
  # Every derived column, in `retention_metadata/2` order. `at_ms` (a value's
  # event time) is not a sweep field; it serves `read_range/5`.
  @metadata_columns @sweep_columns ++ [at_ms: "at_ms"]

  @schema_sql """
  CREATE TABLE IF NOT EXISTS lemon_store_kv (
    table_name TEXT NOT NULL,
    key_blob BLOB NOT NULL,
    value_blob BLOB NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    expires_at_ms INTEGER,
    introspection_ts_ms INTEGER,
    inserted_at_ms INTEGER,
    started_at_ms INTEGER,
    at_ms INTEGER,
    PRIMARY KEY (table_name, key_blob)
  );
  """

  @put_sql """
  INSERT INTO lemon_store_kv (
    table_name, key_blob, value_blob, updated_at_ms,
    expires_at_ms, introspection_ts_ms, inserted_at_ms, started_at_ms, at_ms
  )
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
  ON CONFLICT(table_name, key_blob) DO UPDATE SET
    value_blob = excluded.value_blob,
    updated_at_ms = excluded.updated_at_ms,
    expires_at_ms = excluded.expires_at_ms,
    introspection_ts_ms = excluded.introspection_ts_ms,
    inserted_at_ms = excluded.inserted_at_ms,
    started_at_ms = excluded.started_at_ms,
    at_ms = excluded.at_ms
  """

  @put_new_sql """
  INSERT INTO lemon_store_kv (
    table_name, key_blob, value_blob, updated_at_ms,
    expires_at_ms, introspection_ts_ms, inserted_at_ms, started_at_ms, at_ms
  )
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
  ON CONFLICT(table_name, key_blob) DO NOTHING
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

  @list_recent_sql """
  SELECT key_blob, value_blob
  FROM lemon_store_kv
  WHERE table_name = ?1
  ORDER BY updated_at_ms DESC
  LIMIT ?2
  """

  @range_sql """
  SELECT key_blob, value_blob
  FROM lemon_store_kv
  WHERE table_name = ?1 AND at_ms >= ?2 AND at_ms < ?3
  """

  @range_with_untimed_sql @range_sql <>
                            """
                            UNION ALL
                            SELECT key_blob, value_blob
                            FROM lemon_store_kv
                            WHERE table_name = ?1 AND at_ms IS NULL
                            """

  @list_tables_sql "SELECT DISTINCT table_name FROM lemon_store_kv"

  # Durable once the optional :exqlite NIF is available; without it `init/1`
  # refuses to start.
  @impl true
  def durable?, do: Code.ensure_loaded?(Sqlite3)

  @impl true
  def init(opts) do
    ensure_exqlite!()

    raw_path = Keyword.fetch!(opts, :path)
    path = normalize_path(raw_path)

    ephemeral_tables =
      opts
      |> Keyword.get(:ephemeral_tables, @default_ephemeral_tables)
      |> MapSet.new()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path) do
      case initialize_connection(conn) do
        {:ok, statements} ->
          {:ok,
           %{
             path: path,
             conn: conn,
             statements: statements,
             ephemeral_tables: ephemeral_tables,
             ephemeral_ets: %{},
             # table => ETS table, readable by `read_list/2` callers.
             ephemeral_directory: :ets.new(:lemon_core_store_sqlite_directory, [:set])
           }}

        {:error, reason} ->
          {:error, {:sqlite_init_failed, path, reason}}
      end
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
               now_ms | retention_metadata(table, key, value)
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
  def ping(state) do
    case Sqlite3.execute(state.conn, "SELECT 1") do
      :ok -> {:ok, state}
      :busy -> {:error, :sqlite_busy}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:sqlite_ping_failed, other}}
    end
  end

  @impl true
  def put_new(state, table, key, value) do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)

      if :ets.insert_new(table_ets, {key, value}) do
        {:ok, state}
      else
        {:exists, state}
      end
    else
      table_name = normalize_table_name(table)
      encoded_key = encode(key)
      encoded_value = encode(value)
      now_ms = System.system_time(:millisecond)

      with :ok <-
             bind_statement(state.statements.put_new, [
               table_name,
               {:blob, encoded_key},
               {:blob, encoded_value},
               now_ms | retention_metadata(table, key, value)
             ]),
           :done <- Sqlite3.step(state.conn, state.statements.put_new),
           {:ok, changes} <- Sqlite3.changes(state.conn) do
        if changes == 1 do
          {:ok, state}
        else
          {:exists, state}
        end
      else
        :busy -> {:error, :sqlite_busy}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_put_new_failed, other}}
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
        result =
          case Sqlite3.step(state.conn, state.statements.get) do
            {:row, [value_blob]} ->
              case decode(value_blob, table: table, field: :value, key: key) do
                {:ok, value} -> {:ok, value, state}
                {:error, reason} -> {:error, reason}
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

        # A single-row SELECT left on SQLITE_ROW keeps its read snapshot open;
        # a later write or checkpoint on this connection would then see a stale
        # WAL snapshot and fail with SQLITE_BUSY. Finish it on every path.
        _ = Sqlite3.reset(state.statements.get)
        result
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
  def sweep(state, table, {field, cutoff})
      when is_integer(cutoff) and cutoff >= @min_timestamp and cutoff <= @max_timestamp do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)
      match_spec = LemonCore.Store.EtsBackend.sweep_match_spec(field, cutoff)
      {:ok, :ets.select_delete(table_ets, match_spec), state}
    else
      statement = Map.fetch!(state.statements, {:sweep, field})

      with :ok <- bind_statement(statement, [normalize_table_name(table), cutoff]),
           :done <- Sqlite3.step(state.conn, statement),
           {:ok, count} <- Sqlite3.changes(state.conn) do
        {:ok, count, state}
      else
        :busy -> {:error, :sqlite_busy}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_sweep_failed, other}}
      end
    end
  end

  # BEGIN IMMEDIATE takes the database write lock before the read, so another
  # process sharing the file cannot change the row between compare and write.
  @impl true
  def compare_and_swap(state, table, key, expected, replacement) do
    if ephemeral_table?(state, table) do
      {table_ets, state} = ensure_ephemeral_table(state, table)

      current =
        case :ets.lookup(table_ets, key) do
          [{^key, found}] -> found
          _ -> nil
        end

      if current === expected do
        :ets.insert(table_ets, {key, replacement})
        {:ok, state}
      else
        {:error, :mismatch, state}
      end
    else
      compare_and_swap_persistent(state, table, key, expected, replacement)
    end
  end

  @impl true
  def confirm_durable(state) do
    reset_statements(state)
    {:ok, state}
  end

  @doc false
  @impl true
  def with_durability(state, operation) do
    reset_statements(state)
    :ok = Sqlite3.execute(state.conn, "PRAGMA synchronous=FULL")

    try do
      if match?({:unix, :darwin}, :os.type()) do
        :ok = Sqlite3.execute(state.conn, "PRAGMA fullfsync=ON")
      end

      :telemetry.execute([:lemon, :store, :sqlite, :durable_write], %{count: 1}, %{
        conn: state.conn
      })

      operation.()
    after
      reset_statements(state)
      # The Store serializes the whole scope. Never leak FULL to ordinary writes,
      # even when a transaction fails; a restore failure crashes the owner.
      :ok = Sqlite3.execute(state.conn, "PRAGMA synchronous=NORMAL")
      :ok = Sqlite3.execute(state.conn, "PRAGMA fullfsync=OFF")
    end
  end

  @doc """
  Checkpoints the write-ahead log into the database file with `TRUNCATE`.

  The store runs with `synchronous=NORMAL`, so a committed transaction may
  still sit unsynced in the WAL. A complete checkpoint syncs the WAL, copies
  it into the database, and syncs the database file (with `F_FULLFSYNC` on
  macOS, via `checkpoint_fullfsync`); a checkpoint blocked by
  another connection is reported as `{:error, :sqlite_checkpoint_busy}`
  rather than claiming durability. Cached statements are reset first: a read
  statement left on its last row holds a read transaction on this connection
  that would block the checkpoint.
  """
  @impl true
  def sync(state) do
    :telemetry.execute([:lemon, :store, :sqlite, :checkpoint], %{count: 1}, %{})
    reset_statements(state)

    with {:ok, statement} <- Sqlite3.prepare(state.conn, "PRAGMA wal_checkpoint(TRUNCATE)") do
      result =
        case Sqlite3.step(state.conn, statement) do
          {:row, [0, _log_frames, _checkpointed]} -> {:ok, state}
          {:row, [_busy | _rest]} -> {:error, :sqlite_checkpoint_busy}
          :busy -> {:error, :sqlite_checkpoint_busy}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:sqlite_checkpoint_failed, other}}
        end

      _ = Sqlite3.release(state.conn, statement)
      result
    end
  end

  @impl true
  def compare_and_delete_many(state, entries) do
    case entries
         |> Enum.map(fn {table, _key, _expected} -> ephemeral_table?(state, table) end)
         |> Enum.uniq() do
      [] ->
        {:ok, state}

      [true] ->
        compare_and_delete_ephemeral(state, entries)

      [false] ->
        compare_and_delete_persistent(state, entries)

      _mixed ->
        compare_and_delete_mixed(state, entries)
    end
  end

  # SQLite cannot transact across its durable rows and the ETS tables used for
  # ephemeral data. Preserve the backend contract by validating the complete
  # snapshot first, then deleting in caller order. Callers place the durable
  # execution fence last, so a partial failure remains fail-closed.
  defp compare_and_delete_mixed(state, entries) do
    with {:ok, state} <- validate_mixed_snapshots(state, entries) do
      delete_mixed_snapshots(state, entries)
    end
  end

  defp validate_mixed_snapshots(state, entries) do
    Enum.reduce_while(entries, {:ok, state}, fn {table, key, expected}, {:ok, current_state} ->
      case get(current_state, table, key) do
        {:ok, ^expected, next_state} -> {:cont, {:ok, next_state}}
        {:ok, _other, next_state} -> {:halt, {:error, :mismatch, next_state}}
        {:error, reason} -> {:halt, {:error, reason, current_state}}
      end
    end)
  end

  defp delete_mixed_snapshots(state, entries) do
    Enum.reduce_while(entries, {:ok, state}, fn {table, key, _expected}, {:ok, current_state} ->
      case delete(current_state, table, key) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason, current_state}}
      end
    end)
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
        with {:ok, items} <- decode_rows(rows, table) do
          {:ok, items, state}
        end
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_list_failed, other}}
      end
    end
  end

  @doc """
  Lists the most recent `limit` entries from `table`, ordered by `updated_at_ms DESC`.

  This pushes the ORDER BY + LIMIT into SQLite so the GenServer does not need to
  load every row into memory. Ephemeral (ETS-backed) tables fall back to loading
  all rows and sorting in Elixir.

  Returns `{:ok, [{key, value}], state}`.
  """
  @impl true
  @spec list_recent(map(), atom(), pos_integer()) ::
          {:ok, [{term(), term()}], map()} | {:error, term()}
  def list_recent(state, table, limit) when is_integer(limit) and limit > 0 do
    if ephemeral_table?(state, table) do
      # Ephemeral tables are in ETS — no SQL available, fall back to full scan + sort + take
      {table_ets, state} = ensure_ephemeral_table(state, table)
      items = :ets.tab2list(table_ets)
      # We cannot sort by updated_at_ms for ETS, just take the first `limit` entries
      {:ok, Enum.take(items, limit), state}
    else
      table_name = normalize_table_name(table)

      with :ok <- bind_statement(state.statements.list_recent, [table_name, limit]),
           {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.statements.list_recent) do
        with {:ok, items} <- decode_rows(rows, table) do
          {:ok, items, state}
        end
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, {:sqlite_list_recent_failed, other}}
      end
    end
  end

  @doc """
  Handle for `read_list/2`, `read_range/5` and `read_recent/3`, which any
  process may call while the Store keeps writing (see "Concurrent reads").
  """
  @impl true
  def reader(state) do
    %{
      path: state.path,
      ephemeral_tables: state.ephemeral_tables,
      ephemeral_directory: state.ephemeral_directory
    }
  end

  @impl true
  def read_list(reader, table) do
    if ephemeral_table?(reader, table) do
      {:ok, ephemeral_rows(reader, table)}
    else
      read_rows(reader, table, @list_sql, [normalize_table_name(table)])
    end
  end

  @impl true
  def read_keys(reader, table) do
    if ephemeral_table?(reader, table) do
      LemonCore.Store.EtsBackend.read_keys(reader.ephemeral_directory, table)
    else
      sql = "SELECT key_blob FROM lemon_store_kv WHERE table_name = ?1"
      read_rows(reader, table, sql, [normalize_table_name(table)], &decode_keys/2)
    end
  end

  @impl true
  def read_range(reader, table, from_ms, to_ms, include_untimed)
      when is_integer(from_ms) and is_integer(to_ms) do
    if ephemeral_table?(reader, table) do
      LemonCore.Store.EtsBackend.read_range(
        reader.ephemeral_directory,
        table,
        from_ms,
        to_ms,
        include_untimed
      )
    else
      sql = if include_untimed, do: @range_with_untimed_sql, else: @range_sql

      read_rows(reader, table, sql, [
        normalize_table_name(table),
        sql_timestamp(from_ms),
        sql_timestamp(to_ms)
      ])
    end
  end

  @impl true
  def read_recent(reader, table, limit) when is_integer(limit) and limit > 0 do
    if ephemeral_table?(reader, table) do
      {:ok, reader |> ephemeral_rows(table) |> Enum.take(limit)}
    else
      read_rows(reader, table, @list_recent_sql, [normalize_table_name(table), limit])
    end
  end

  defp ephemeral_rows(reader, table) do
    case :ets.lookup(reader.ephemeral_directory, table) do
      [{^table, tid}] -> :ets.tab2list(tid)
      [] -> []
    end
  end

  # One private read-only connection per read: it sees every transaction
  # committed before it opened and never blocks the Store's writer.
  defp read_rows(reader, table, sql, params, decoder \\ &decode_rows/2) do
    case Sqlite3.open(reader.path, mode: :readonly) do
      {:ok, conn} ->
        try do
          conn |> query_rows(table, sql, params, decoder) |> normalize_read_result()
        after
          _ = Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, {:sqlite_read_open_failed, reason}}
    end
  end

  defp query_rows(conn, table, sql, params, decoder) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- bind_statement(statement, params),
             {:ok, rows} <- Sqlite3.fetch_all(conn, statement) do
          decoder.(rows, table)
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp normalize_read_result({:ok, _items} = ok), do: ok
  defp normalize_read_result({:error, _reason} = error), do: error
  defp normalize_read_result(:busy), do: {:error, :sqlite_busy}
  defp normalize_read_result(other), do: {:error, {:sqlite_read_failed, other}}

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
  @impl true
  def close(%{conn: conn, statements: statements}) do
    Enum.each(Map.values(statements), fn stmt ->
      case Sqlite3.release(conn, stmt) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("SQLite statement release failed: #{inspect(reason)}")
      end
    end)

    case Sqlite3.close(conn) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("SQLite connection close failed: #{inspect(reason)}")
    end

    :ok
  end

  def close(_), do: :ok

  defp initialize_connection(conn) do
    result =
      with :ok <- init_db(conn),
           {:ok, statements} <- prepare_statements(conn) do
        {:ok, statements}
      end

    case result do
      {:ok, _statements} ->
        result

      error ->
        _ = Sqlite3.close(conn)
        error
    end
  rescue
    error ->
      _ = Sqlite3.close(conn)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      _ = Sqlite3.close(conn)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp init_db(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL"),
         # Checkpoints are the `sync/1` durability barrier; on macOS a plain
         # fsync does not reach stable storage, so they use F_FULLFSYNC there
         # (a no-op elsewhere). Ordinary commits are unaffected.
         :ok <- Sqlite3.execute(conn, "PRAGMA checkpoint_fullfsync=ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(conn, @schema_sql),
         :ok <- migrate_retention_metadata(conn) do
      :ok
    end
  end

  defp migrate_retention_metadata(conn) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      result =
        with {:ok, columns} <-
               with_statement(conn, "PRAGMA table_info(lemon_store_kv)", fn statement ->
                 Sqlite3.fetch_all(conn, statement)
               end),
             existing = MapSet.new(columns, fn [_id, name | _rest] -> name end),
             missing = Enum.reject(@metadata_columns, fn {_field, name} -> name in existing end),
             :ok <- add_retention_columns(conn, missing),
             :ok <- backfill_retention_metadata(conn, missing),
             :ok <- create_retention_indexes(conn),
             :ok <- Sqlite3.execute(conn, "COMMIT") do
          :ok
        end

      case result do
        :ok ->
          :ok

        error ->
          _ = Sqlite3.execute(conn, "ROLLBACK")
          {:error, normalize_transaction_error(error)}
      end
    end
  end

  defp add_retention_columns(conn, columns) do
    Enum.reduce_while(columns, :ok, fn {_field, column}, :ok ->
      case Sqlite3.execute(conn, "ALTER TABLE lemon_store_kv ADD COLUMN #{column} INTEGER") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_retention_indexes(conn) do
    sweep_indexes =
      Enum.map(@sweep_columns, fn {_field, column} ->
        """
        CREATE INDEX IF NOT EXISTS lemon_store_kv_#{column}
        ON lemon_store_kv (table_name, #{column}) WHERE #{column} IS NOT NULL
        """
      end)

    # Not partial: time-range reads also select the rows without a time.
    range_index =
      "CREATE INDEX IF NOT EXISTS lemon_store_kv_at_ms ON lemon_store_kv (table_name, at_ms)"

    Enum.reduce_while(sweep_indexes ++ [range_index], :ok, fn sql, :ok ->
      case Sqlite3.execute(conn, sql) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp backfill_retention_metadata(_conn, []), do: :ok

  defp backfill_retention_metadata(conn, _missing) do
    select_sql =
      "SELECT rowid, table_name, key_blob, value_blob FROM lemon_store_kv ORDER BY rowid"

    update_sql = """
    UPDATE lemon_store_kv
    SET expires_at_ms = ?1, introspection_ts_ms = ?2, inserted_at_ms = ?3, started_at_ms = ?4,
      at_ms = ?5
    WHERE rowid = ?6
    """

    with_statement(conn, select_sql, fn select ->
      with_statement(conn, update_sql, fn update ->
        backfill_retention_rows(conn, select, update)
      end)
    end)
  end

  defp backfill_retention_rows(conn, select, update) do
    case Sqlite3.step(conn, select) do
      {:row, [rowid, table, key_blob, value_blob]} ->
        metadata =
          with {:ok, key} <- decode(key_blob, table: table, field: :key),
               {:ok, value} <- decode(value_blob, table: table, field: :value, key: key) do
            retention_metadata(table, key, value)
          else
            # Preserve the original blobs and their explicit read errors. A
            # migration must never turn corruption into an expired/missing row.
            {:error, _reason} -> Enum.map(@metadata_columns, fn _column -> nil end)
          end

        with :ok <- bind_statement(update, metadata ++ [rowid]),
             :done <- Sqlite3.step(conn, update) do
          backfill_retention_rows(conn, select, update)
        end

      :done ->
        :ok

      error ->
        {:error, normalize_transaction_error(error)}
    end
  end

  defp with_statement(conn, sql, operation) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        operation.(statement)
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp retention_metadata(table, key, value) do
    expires_at =
      case value do
        %{expires_at: timestamp} -> timestamp
        _ -> nil
      end

    introspection_timestamp =
      case key do
        {timestamp, _event_id} when is_integer(timestamp) -> timestamp
        _ -> LemonCore.MapHelpers.get_key(value, :ts_ms)
      end

    inserted_at =
      case value do
        %{"inserted_at_ms" => timestamp} -> timestamp
        _ -> nil
      end

    started_at =
      case value do
        %{started_at_ms: timestamp} when is_integer(timestamp) -> timestamp
        %{"started_at_ms" => timestamp} -> timestamp
        _ -> nil
      end

    at_ms = LemonCore.Store.Backend.range_timestamp(table, key, value)

    Enum.map(
      [expires_at, introspection_timestamp, inserted_at, started_at, at_ms],
      &sql_timestamp/1
    )
  end

  # Out-of-range Erlang integers must still round-trip in the payload. Numeric
  # sentinels beyond the cutoff range preserve comparisons without SQLite's
  # signed-64-bit parameter binding truncating those values.
  defp sql_timestamp(timestamp) when is_integer(timestamp) and timestamp < @min_timestamp,
    do: -1.0e100

  defp sql_timestamp(timestamp) when is_integer(timestamp) and timestamp > @max_timestamp,
    do: 1.0e100

  defp sql_timestamp(timestamp) when is_integer(timestamp), do: timestamp
  defp sql_timestamp(_timestamp), do: nil

  defp prepare_statements(conn) do
    statements = [
      put: @put_sql,
      put_new: @put_new_sql,
      get: @get_sql,
      delete: @delete_sql,
      list: @list_sql,
      list_recent: @list_recent_sql,
      list_tables: @list_tables_sql
    ]

    sweeps =
      Enum.map(@sweep_columns, fn {field, column} ->
        {{:sweep, field}, "DELETE FROM lemon_store_kv WHERE table_name = ?1 AND #{column} < ?2"}
      end)

    Enum.reduce_while(statements ++ sweeps, {:ok, %{}}, fn {name, sql}, {:ok, prepared} ->
      case Sqlite3.prepare(conn, sql) do
        {:ok, statement} ->
          {:cont, {:ok, Map.put(prepared, name, statement)}}

        {:error, reason} ->
          Enum.each(Map.values(prepared), &Sqlite3.release(conn, &1))
          {:halt, {:error, {:prepare_failed, reason}}}
      end
    end)
  end

  defp normalize_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    ext = String.downcase(Path.extname(expanded))

    cond do
      File.dir?(expanded) ->
        Path.join(expanded, @default_filename)

      String.ends_with?(path, "/") ->
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
        true = :ets.insert(state.ephemeral_directory, {table, tid})
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
      e -> {:error, classify_bind_error(e)}
    end
  end

  defp ensure_exqlite! do
    unless Code.ensure_loaded?(Sqlite3) do
      raise """
      #{inspect(__MODULE__)} requires the optional :exqlite dependency.

      Add it to your deps:

          {:exqlite, "~> 0.34"}

      Or configure the ETS backend instead:

          config :lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend
      """
    end

    :ok
  end

  defp compare_and_delete_ephemeral(state, entries) do
    {resolved, state} =
      Enum.map_reduce(entries, state, fn {table, key, expected}, acc ->
        {table_ets, acc} = ensure_ephemeral_table(acc, table)
        {{table_ets, key, expected}, acc}
      end)

    if Enum.all?(resolved, fn {table_ets, key, expected} ->
         :ets.lookup(table_ets, key) == [{key, expected}]
       end) do
      Enum.each(resolved, fn {table_ets, key, _expected} -> :ets.delete(table_ets, key) end)
      {:ok, state}
    else
      {:error, :mismatch, state}
    end
  end

  # Every cached statement is finished first: one left mid-result would pin an
  # old read snapshot and turn BEGIN IMMEDIATE into SQLITE_BUSY.
  defp reset_statements(state), do: Enum.each(Map.values(state.statements), &Sqlite3.reset/1)

  defp compare_and_swap_persistent(state, table, key, expected, replacement) do
    reset_statements(state)

    case Sqlite3.execute(state.conn, "BEGIN IMMEDIATE") do
      :ok ->
        result =
          with :ok <- validate_persistent_snapshots(state, [{table, key, expected}]),
               {:ok, _state} <- put(state, table, key, replacement),
               :ok <- Sqlite3.execute(state.conn, "COMMIT") do
            :ok
          end

        case result do
          :ok ->
            {:ok, state}

          {:error, :mismatch} ->
            _ = Sqlite3.execute(state.conn, "ROLLBACK")
            {:error, :mismatch, state}

          error ->
            _ = Sqlite3.execute(state.conn, "ROLLBACK")
            {:error, normalize_transaction_error(error), state}
        end

      error ->
        {:error, normalize_transaction_error(error), state}
    end
  rescue
    error ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:sqlite_transaction_failed, Exception.message(error)}, state}
  catch
    kind, reason ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:sqlite_transaction_failed, kind, reason}, state}
  end

  defp compare_and_delete_persistent(state, entries) do
    reset_statements(state)

    case Sqlite3.execute(state.conn, "BEGIN IMMEDIATE") do
      :ok ->
        result =
          with :ok <- validate_persistent_snapshots(state, entries),
               :ok <- delete_persistent_snapshots(state, entries),
               :ok <- Sqlite3.execute(state.conn, "COMMIT") do
            :ok
          end

        case result do
          :ok ->
            {:ok, state}

          error ->
            _ = Sqlite3.execute(state.conn, "ROLLBACK")
            {:error, normalize_transaction_error(error), state}
        end

      error ->
        {:error, normalize_transaction_error(error), state}
    end
  rescue
    error ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:sqlite_transaction_failed, Exception.message(error)}, state}
  catch
    kind, reason ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:sqlite_transaction_failed, kind, reason}, state}
  end

  defp validate_persistent_snapshots(state, entries) do
    Enum.reduce_while(entries, :ok, fn {table, key, expected}, :ok ->
      case get(state, table, key) do
        {:ok, current, _state} when current === expected -> {:cont, :ok}
        {:ok, _current, _state} -> {:halt, {:error, :mismatch}}
        {:error, reason} -> {:halt, {:error, reason}}
        other -> {:halt, {:error, {:sqlite_get_failed, other}}}
      end
    end)
  end

  defp delete_persistent_snapshots(state, entries) do
    Enum.reduce_while(entries, :ok, fn {table, key, _expected}, :ok ->
      case delete(state, table, key) do
        {:ok, _state} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_transaction_error({:error, reason}), do: reason
  defp normalize_transaction_error(:busy), do: :sqlite_busy
  defp normalize_transaction_error(other), do: {:sqlite_transaction_failed, other}

  # Guarded with `is_struct/2` rather than rescued `in ExqliteError` or matched
  # on `%ExqliteError{}`: both need the struct at compile time, which warns in
  # any consumer that doesn't pull in the optional :exqlite.
  defp classify_bind_error(error) when is_struct(error, ExqliteError) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "too big") do
      {:sqlite_bind_failed, :blob_too_big}
    else
      {:sqlite_bind_failed, message}
    end
  end

  defp classify_bind_error(error), do: {:sqlite_bind_failed, Exception.message(error)}

  defp encode(term), do: :erlang.term_to_binary(term)

  defp decode(binary, context) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    error in ArgumentError ->
      reason = {:sqlite_corrupt_data, Enum.into(context, %{}), Exception.message(error)}
      {:error, reason}
  end

  defp decode_keys(rows, table) do
    Enum.reduce_while(rows, {:ok, []}, fn [blob], {:ok, keys} ->
      case decode(blob, table: table, field: :key) do
        {:ok, key} -> {:cont, {:ok, [key | keys]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Every row is decoded: an undecodable row is skipped rather than ending the
  # scan, and the result is still one explicit corruption error, never a
  # silently shortened table. The error names the first bad row and counts all
  # of them (`:corrupt_rows`), so an operator sees the extent of the damage.
  defp decode_rows(rows, table) do
    {items, corrupt, first_error} =
      Enum.reduce(rows, {[], 0, nil}, fn [key_blob, value_blob], {acc, corrupt, first} ->
        with {:ok, key} <- decode(key_blob, table: table, field: :key),
             {:ok, value} <- decode(value_blob, table: table, field: :value, key: key) do
          {[{key, value} | acc], corrupt, first}
        else
          {:error, reason} -> {acc, corrupt + 1, first || reason}
        end
      end)

    case first_error do
      nil ->
        {:ok, Enum.reverse(items)}

      {:sqlite_corrupt_data, context, message} ->
        {:error, {:sqlite_corrupt_data, Map.put(context, :corrupt_rows, corrupt), message}}
    end
  end
end
