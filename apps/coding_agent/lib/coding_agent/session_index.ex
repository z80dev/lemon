defmodule CodingAgent.SessionIndex do
  @moduledoc """
  Rebuildable SQLite metadata cache for native JSONL journals.

  Each session directory owns an `.index.sqlite3`. Listing stats directory
  entries but opens only new or changed journals, not every journal. Atomic
  replacements, appends and deletions are reconciled by size, inode, mtime and
  ctime. Header fields, the latest session-info title and last activity are
  cached; JSONL remains authoritative. Deleting the cache rebuilds it on demand.

  Cache writes deliberately do not fsync: journal checkpoints own durability.
  Cache failure must never turn a successful journal mutation into a retryable
  failure. Directory admission serializes local writers and reconciliation;
  callers holding native-file admission acquire it before directory admission.
  """

  alias Exqlite.Sqlite3

  @filename ".index.sqlite3"
  @version 1
  @columns "path, fingerprint, id, timestamp, cwd, title, updated_at, version, parent_session"
  @schema """
  CREATE TABLE IF NOT EXISTS journals (
    path TEXT PRIMARY KEY NOT NULL,
    fingerprint TEXT NOT NULL,
    id TEXT,
    timestamp INTEGER,
    cwd TEXT,
    title TEXT,
    updated_at INTEGER,
    version INTEGER,
    parent_session TEXT
  );
  """

  @doc "The derived index path for a native session directory."
  def path(directory), do: Path.join(directory, @filename)

  @doc "Serialize local directory reconciliation and journal/index mutations."
  def with_directory_lock(directory, fun) when is_function(fun, 0) do
    key = {__MODULE__, node(), Path.expand(directory)}
    held_key = {__MODULE__, :held, key}

    if Process.get(held_key, false) do
      fun.()
    else
      :global.trans(
        {key, self()},
        fn ->
          Process.put(held_key, true)

          try do
            fun.()
          after
            Process.delete(held_key)
          end
        end,
        [node()]
      )
    end
  end

  @doc "List indexed metadata, reconciling only changed or missing journals."
  def list(directory) do
    with_directory_lock(directory, fn ->
      case File.ls(directory) do
        {:ok, names} ->
          with_connection(directory, fn conn ->
            with {:ok, cached} <- rows(conn),
                 :ok <- reconcile(conn, directory, names, cached),
                 {:ok, current} <- rows(conn) do
              {:ok,
               current
               |> Map.values()
               |> Enum.reject(&is_nil(&1.id))
               |> Enum.map(&Map.delete(&1, :fingerprint))
               |> Enum.sort_by(&{&1.updated_at, &1.timestamp, &1.id}, :desc)}
            end
          end)

        {:error, :enoent} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc "Drop a moved or removed journal from its derived index."
  def remove(journal_path) do
    directory = Path.dirname(journal_path)

    with_directory_lock(directory, fn ->
      with_connection(directory, fn conn ->
        execute(conn, "DELETE FROM journals WHERE path = ?1", [Path.expand(journal_path)])
      end)
    end)
  end

  @doc false
  # The writer runs exactly once, regardless of cache availability. `update` is
  # {:snapshot, header, entries_rev}, {:append, entry}, or :checkpoint.
  def mutate(journal_path, update, writer) when is_function(writer, 0) do
    journal_path = Path.expand(journal_path)
    directory = Path.dirname(journal_path)

    with_directory_lock(directory, fn ->
      case cache_only(fn -> open(directory) end, {:error, :index_unavailable}) do
        {:ok, conn} ->
          try do
            previous = cache_only(fn -> matching_row(conn, journal_path) end, nil)
            result = writer.()

            if result == :ok do
              _ = cache_only(fn -> cache_mutation(conn, journal_path, previous, update) end, :ok)
            end

            result
          after
            Sqlite3.close(conn)
          end

        {:error, _reason} ->
          result = writer.()

          if result == :ok do
            _ =
              cache_only(
                fn ->
                  with_connection(directory, &cache_mutation(&1, journal_path, nil, update))
                end,
                :ok
              )
          end

          result
      end
    end)
  end

  defp cache_only(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  end

  defp cache_mutation(conn, journal_path, previous, update) do
    with {:ok, stat} <- journal_stat(journal_path) do
      metadata =
        case {update, previous} do
          {{:snapshot, header, entries_rev}, _} -> snapshot(header, entries_rev)
          {{:append, entry}, %{} = row} -> append_metadata(row, entry)
          {:checkpoint, %{} = row} -> row
          _ -> read_metadata(journal_path)
        end

      put(conn, journal_path, stat, metadata)
    end
  end

  defp matching_row(conn, journal_path) do
    with {:ok, stat} <- journal_stat(journal_path),
         {:ok, [row]} <-
           query(conn, "SELECT #{@columns} FROM journals WHERE path = ?1", [journal_path]),
         %{fingerprint: fingerprint} = metadata <- decode_row(row),
         true <- fingerprint == fingerprint(stat) do
      metadata
    else
      _ -> nil
    end
  end

  defp reconcile(conn, directory, names, cached) do
    paths =
      names
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> MapSet.new(&Path.expand(Path.join(directory, &1)))

    with :ok <- execute(conn, "BEGIN IMMEDIATE", []) do
      result =
        Enum.reduce_while(paths, :ok, fn journal_path, :ok ->
          result =
            case journal_stat(journal_path) do
              {:ok, stat} ->
                current_fingerprint = fingerprint(stat)

                case Map.get(cached, journal_path) do
                  %{fingerprint: ^current_fingerprint} -> :ok
                  _ -> put(conn, journal_path, stat, read_metadata(journal_path))
                end

              {:error, :enoent} ->
                execute(conn, "DELETE FROM journals WHERE path = ?1", [journal_path])

              {:error, :not_regular} ->
                execute(conn, "DELETE FROM journals WHERE path = ?1", [journal_path])

              {:error, reason} ->
                {:error, reason}
            end

          if result == :ok, do: {:cont, :ok}, else: {:halt, result}
        end)

      result =
        if result == :ok do
          cached
          |> Map.keys()
          |> Enum.reject(&MapSet.member?(paths, &1))
          |> Enum.reduce_while(:ok, fn journal_path, :ok ->
            case execute(conn, "DELETE FROM journals WHERE path = ?1", [journal_path]) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        else
          result
        end

      if result == :ok do
        execute(conn, "COMMIT", [])
      else
        _ = execute(conn, "ROLLBACK", [])
        result
      end
    end
  end

  defp journal_stat(journal_path) do
    case File.lstat(journal_path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, _} -> {:error, :not_regular}
      error -> error
    end
  end

  defp fingerprint(stat) do
    Enum.join([stat.size, stat.inode, stat.mtime, stat.ctime], ":")
  end

  defp snapshot(header, entries_rev) do
    title = Enum.find(entries_rev, &(&1.type == :session_info))

    %{
      id: header.id,
      timestamp: header.timestamp,
      cwd: header.cwd,
      title: if(title, do: text(title.name)),
      updated_at:
        Enum.reduce(entries_rev, timestamp(header.timestamp), &max(timestamp(&1.timestamp), &2)),
      version: header.version,
      parent_session: text(header.parent_session)
    }
  end

  defp append_metadata(row, entry) do
    row
    |> Map.put(:updated_at, max(row.updated_at || 0, timestamp(entry.timestamp)))
    |> then(fn row ->
      if entry.type == :session_info, do: Map.put(row, :title, text(entry.name)), else: row
    end)
  end

  defp read_metadata(journal_path) do
    journal_path
    |> File.stream!()
    |> Enum.reduce_while(nil, fn line, metadata ->
      case Jason.decode(line, strings: :copy) do
        {:ok, %{"type" => "session", "id" => id, "cwd" => cwd, "timestamp" => time} = header}
        when is_nil(metadata) and is_binary(id) and is_binary(cwd) and
               (is_integer(time) or is_binary(time)) ->
          {:cont,
           %{
             id: id,
             timestamp: time,
             cwd: cwd,
             title: nil,
             updated_at: timestamp(time),
             version: if(is_integer(header["version"]), do: header["version"], else: 1),
             parent_session: text(header["parentSession"])
           }}

        {:ok, entry} when is_map(entry) and is_map(metadata) ->
          metadata = Map.update!(metadata, :updated_at, &max(&1, timestamp(entry["timestamp"])))

          metadata =
            if entry["type"] == "sessionInfo",
              do: Map.put(metadata, :title, text(entry["name"])),
              else: metadata

          {:cont, metadata}

        _ when is_nil(metadata) ->
          if String.trim(line) == "", do: {:cont, nil}, else: {:halt, nil}

        _ ->
          {:cont, metadata}
      end
    end)
  rescue
    _error in File.Error -> nil
  end

  defp timestamp(value) when is_integer(value), do: value

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> 0
    end
  end

  defp timestamp(_), do: 0

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp put(conn, journal_path, stat, metadata) do
    metadata =
      metadata ||
        %{
          id: nil,
          timestamp: nil,
          cwd: nil,
          title: nil,
          updated_at: 0,
          version: nil,
          parent_session: nil
        }

    execute(
      conn,
      "INSERT OR REPLACE INTO journals (#{@columns}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
      [
        journal_path,
        fingerprint(stat),
        metadata.id,
        metadata.timestamp,
        metadata.cwd,
        metadata.title,
        max(metadata.updated_at || 0, stat.mtime * 1000),
        metadata.version,
        metadata.parent_session
      ]
    )
  end

  defp rows(conn) do
    with {:ok, rows} <- query(conn, "SELECT #{@columns} FROM journals", []) do
      {:ok,
       Map.new(rows, fn row ->
         metadata = decode_row(row)
         {metadata.path, metadata}
       end)}
    end
  end

  defp decode_row([
         path,
         fingerprint,
         id,
         timestamp,
         cwd,
         title,
         updated_at,
         version,
         parent_session
       ]) do
    %{
      path: path,
      fingerprint: fingerprint,
      id: id,
      timestamp: timestamp,
      cwd: cwd,
      title: title,
      updated_at: updated_at,
      version: version,
      parent_session: parent_session
    }
  end

  defp with_connection(directory, fun) do
    with {:ok, conn} <- open(directory) do
      try do
        fun.(conn)
      after
        Sqlite3.close(conn)
      end
    end
  end

  defp open(directory, rebuild? \\ true) do
    index_path = path(directory)

    with :ok <- safe_index(index_path),
         {:ok, conn} <- Sqlite3.open(index_path) do
      case initialize(conn) do
        :ok ->
          {:ok, conn}

        {:error, reason} = error ->
          Sqlite3.close(conn)

          if rebuild? and corrupt_database?(reason) do
            with :ok <- File.rm(index_path), do: open(directory, false)
          else
            error
          end
      end
    end
  end

  defp corrupt_database?(message) when is_binary(message),
    do: String.contains?(message, ["file is not a database", "database disk image is malformed"])

  defp corrupt_database?(_reason), do: false

  defp safe_index(index_path) do
    case File.lstat(index_path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :unsafe_index}
      error -> error
    end
  end

  defp initialize(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=OFF"),
         {:ok, [[version]]} <- query(conn, "PRAGMA user_version", []) do
      valid_schema? =
        version == @version and
          query(conn, "SELECT #{@columns} FROM journals LIMIT 0", []) == {:ok, []}

      if valid_schema? do
        :ok
      else
        with :ok <- Sqlite3.execute(conn, "DROP TABLE IF EXISTS journals"),
             :ok <- Sqlite3.execute(conn, @schema),
             :ok <- Sqlite3.execute(conn, "PRAGMA user_version=#{@version}") do
          :ok
        end
      end
    end
  end

  defp execute(conn, sql, params) do
    case statement(conn, sql, params, &Sqlite3.step(conn, &1)) do
      :done -> :ok
      :busy -> {:error, :index_busy}
      {:error, _} = error -> error
    end
  end

  defp query(conn, sql, params), do: statement(conn, sql, params, &Sqlite3.fetch_all(conn, &1))

  defp statement(conn, sql, params, fun) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params), do: fun.(statement)
      after
        Sqlite3.release(conn, statement)
      end
    end
  end
end
