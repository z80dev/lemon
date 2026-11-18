defmodule CodingAgent.Tools.WriteSqlite do
  @moduledoc false

  # Row writes never hand SQLite a workspace path. The database is pinned and
  # read (bounded) through the descriptor-bound FileValidation helpers below
  # the validated mutation boundary, mutated as a private in-memory image
  # (`Sqlite.with_image/2`: no journal, WAL or temp file), and committed with
  # an atomic, mode-preserving replace of the pinned file. Symlinks are always
  # refused, even with `allow_symlinks: true`.
  #
  # A database with a `-journal`, `-wal` or `-shm` companion (open, in WAL use
  # or interrupted) is refused, checked in the database's directory handle
  # before the read and again before the commit. The identity check before the
  # replace is best-effort conflict detection, not compare-and-swap: another
  # SQLite writer that commits between the read and the replace is
  # overwritten, and a process holding the database open keeps the old inode.

  alias CodingAgent.{FileReadTracker, MutationLock}
  alias CodingAgent.Tools.{CheckpointGuard, FileValidation, ReadSqlite, Sqlite}
  alias Exqlite.Sqlite3
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonCore.ConfinedFS

  @magic "SQLite format 3" <> <<0>>
  @companions ["-journal", "-wal", "-shm"]
  @max_bytes 128 * 1024 * 1024
  @not_database "SQLite writes require an existing SQLite database"

  def target(path) do
    case ReadSqlite.split_path(path, false) do
      {_, "", ""} -> nil
      target -> if File.exists?(path), do: nil, else: target
    end
  end

  def write({path, sub_path, query}, content, signal, cwd, opts) do
    path = Path.expand(path)
    mutation_opts = Keyword.put(opts, :mutation_root, cwd)
    io_opts = Keyword.put(mutation_opts, :allow_symlinks, false)

    MutationLock.with_lock(MutationLock.path_key(path), fn ->
      with :ok <- FileValidation.check_mutation_target(path, mutation_opts),
           {:ok, table, key} <- selector(sub_path, query),
           {:ok, payload} <- payload(content, key),
           {:ok, identity, original} <- load(path, io_opts),
           {:ok, {action, changes}, updated} <-
             Sqlite.with_image(original, &mutate(&1, table, key, payload)),
           {:ok, checkpoint} <-
             CheckpointGuard.before_mutation(
               [path, path <> "-wal", path <> "-shm"],
               cwd,
               opts,
               %{tool: "write", action: action, path: path}
             ),
           false <- AbortSignal.aborted?(signal),
           :ok <- commit(path, identity, original, updated, io_opts) do
        FileReadTracker.record(opts, path, updated)

        %AgentToolResult{
          content: [%TextContent{text: "SQLite #{action}: #{changes} row(s) affected"}],
          details:
            CheckpointGuard.put_details(
              %{path: path, format: :sqlite, action: action, rows_affected: changes},
              checkpoint
            )
        }
      else
        true -> {:error, :aborted}
        error -> error
      end
    end)
  rescue
    _ -> {:error, "SQLite write failed"}
  end

  defp load(path, opts) do
    max_bytes = Keyword.get(opts, :format_max_input_bytes, @max_bytes)

    with {:ok, identity} <- FileValidation.regular_file_identity(path, opts),
         :ok <- no_companions(path, opts),
         {:ok, bytes} <- FileValidation.read_regular_file(path, identity, max_bytes: max_bytes) do
      if String.starts_with?(bytes, @magic),
        do: {:ok, identity, bytes},
        else: {:error, @not_database}
    else
      {:error, :enoent} -> {:error, @not_database}
      {:error, reason} -> {:error, sqlite_error(reason, path)}
    end
  end

  defp commit(_path, _identity, original, original, _opts), do: :ok

  defp commit(path, identity, _original, updated, opts) do
    with :ok <- no_companions(path, opts),
         :ok <- FileValidation.replace_regular_file(path, identity, updated, opts) do
      :ok
    else
      {:error, reason} -> {:error, sqlite_error(reason, path)}
    end
  end

  defp no_companions(path, opts) do
    with {:ok, root, parts} <- FileValidation.mutation_location(path, opts) do
      ConfinedFS.with_root(root, fn fs ->
        with {:ok, dir, name} <- ConfinedFS.open_parent(fs, :root, parts) do
          Enum.find_value(@companions, :ok, fn suffix ->
            case ConfinedFS.stat(fs, dir, name <> suffix) do
              {:error, :enoent} -> nil
              {:ok, _stat} -> {:error, companion_error(path, suffix)}
              {:error, _reason} = error -> error
            end
          end)
        end
      end)
      |> case do
        {:error, reason} when is_atom(reason) -> FileValidation.confined_error(reason, path)
        result -> result
      end
    end
  end

  defp companion_error(path, suffix) do
    "SQLite database has a #{suffix} file (open, in WAL use or interrupted); " <>
      "row writes need a closed database without journal files: #{path}"
  end

  defp sqlite_error(reason, _path) when is_binary(reason), do: reason
  defp sqlite_error(reason, path), do: FileValidation.format_file_error(reason, path, "database")

  defp mutate(conn, table, key, payload) do
    with {:ok, columns} <- Sqlite.table_info(conn, table),
         {:ok, sql, args, action} <- statement(conn, table, key, payload, columns),
         {:ok, _, _, _} <- Sqlite.query(conn, sql, args),
         {:ok, changes} <- Sqlite3.changes(conn) do
      {:ok, {action, changes}}
    end
  end

  defp selector(_sub_path, query) when query != "",
    do: {:error, "SQLite writes do not support query parameters"}

  defp selector(sub_path, _query) do
    case String.split(sub_path, ":", parts: 2) do
      [table] when table != "" -> {:ok, table, nil}
      [table, key] when table != "" and key != "" -> {:ok, table, key}
      _ -> {:error, "SQLite write path must be db:table or db:table:key"}
    end
  end

  defp payload(content, key) do
    if key != nil and String.trim(content) == "" do
      {:ok, :delete}
    else
      case Jason.decode(content) do
        {:ok, value} when is_map(value) -> {:ok, value}
        _ -> {:error, "SQLite content must be a JSON object with scalar values"}
      end
    end
  end

  defp statement(conn, table, key, :delete, _columns) do
    with {:ok, lookup} <- Sqlite.row_lookup(conn, table) do
      {:ok, "DELETE FROM #{Sqlite.ident(table)} WHERE #{lookup} = ?", [key], :delete}
    end
  end

  defp statement(conn, table, key, payload, columns) do
    names = Enum.map(columns, fn [name, _] -> name end)

    cond do
      Enum.any?(Map.keys(payload), &(&1 not in names)) ->
        {:error, "SQLite content contains an unknown column"}

      Enum.any?(Map.values(payload), &(is_map(&1) or is_list(&1))) ->
        {:error, "SQLite values must be scalars (string, number, boolean, or null)"}

      key != nil and map_size(payload) == 0 ->
        {:error, "SQLite update object must not be empty"}

      true ->
        fields = Enum.sort(Map.keys(payload))
        args = Enum.map(fields, &scalar(Map.fetch!(payload, &1)))
        build_statement(conn, table, key, fields, args)
    end
  end

  defp build_statement(_conn, table, nil, [], []),
    do: {:ok, "INSERT INTO #{Sqlite.ident(table)} DEFAULT VALUES", [], :insert}

  defp build_statement(_conn, table, nil, fields, args) do
    names = Enum.map_join(fields, ", ", &Sqlite.ident/1)
    placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)
    {:ok, "INSERT INTO #{Sqlite.ident(table)} (#{names}) VALUES (#{placeholders})", args, :insert}
  end

  defp build_statement(conn, table, key, fields, args) do
    with {:ok, lookup} <- Sqlite.row_lookup(conn, table) do
      assignments = Enum.map_join(fields, ", ", &(Sqlite.ident(&1) <> " = ?"))

      {:ok, "UPDATE #{Sqlite.ident(table)} SET #{assignments} WHERE #{lookup} = ?", args ++ [key],
       :update}
    end
  end

  defp scalar(true), do: 1
  defp scalar(false), do: 0
  defp scalar(value), do: value
end
