defmodule CodingAgent.Tools.WriteSqlite do
  @moduledoc false

  alias CodingAgent.{FileReadTracker, MutationLock}
  alias CodingAgent.Tools.{CheckpointGuard, FileValidation, ReadSqlite, Sqlite}
  alias Exqlite.Sqlite3
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  def target(path) do
    case ReadSqlite.split_path(path, false) do
      {_, "", ""} -> nil
      target -> if File.exists?(path), do: nil, else: target
    end
  end

  def write({path, sub_path, query}, content, signal, cwd, opts) do
    path = Path.expand(path)

    MutationLock.with_lock(MutationLock.path_key(path), fn ->
      with :ok <-
             FileValidation.check_mutation_target(path, Keyword.put(opts, :mutation_root, cwd)),
           true <- ReadSqlite.sqlite_file?(path),
           {:ok, table, key} <- selector(sub_path, query),
           {:ok, payload} <- payload(content, key) do
        Sqlite.with_connection(path, :readwrite, fn conn ->
          with {:ok, columns} <- Sqlite.table_info(conn, table),
               {:ok, sql, args, action} <- statement(conn, table, key, payload, columns),
               {:ok, checkpoint} <-
                 CheckpointGuard.before_mutation(
                   [path, path <> "-wal", path <> "-shm"],
                   cwd,
                   opts,
                   %{tool: "write", action: action, path: path}
                 ),
               false <- AbortSignal.aborted?(signal),
               {:ok, _, _, _} <- Sqlite.query(conn, sql, args),
               {:ok, changes} <- Sqlite3.changes(conn) do
            FileReadTracker.refresh(opts, [path])

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
      else
        false -> {:error, "SQLite writes require an existing SQLite database"}
        error -> error
      end
    end)
  rescue
    _ -> {:error, "SQLite write failed"}
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
