defmodule LemonCore.Store.JsonlBackend do
  @moduledoc """
  Persistent JSONL-based storage backend with dynamic table support.

  Stores all operations as append-only JSONL (JSON Lines) files.
  Each logical table is stored in a separate file within the configured directory.

  ## Options

    * `:path` - Required. Directory path where JSONL files will be stored.

  ## File Format

  Each line is a JSON object with the structure:
  ```json
  {"op": "put"|"delete", "key": <key>, "value": <value>, "ts": <unix_ms>}
  ```

  On init, all existing `*.jsonl` files in the store directory are loaded.
  Discovery or replay failures stop initialization; unknown data is never empty.
  Lazy load failures leave the table unloaded, so access after repair can recover.
  New tables are created on first write. Errors contain bounded classifications,
  not journal contents, keys, file paths or exception messages.
  """

  @behaviour LemonCore.Store.Backend

  # Core tables that are always loaded at startup
  @core_tables [:chat, :progress, :runs, :run_history]

  # Additional parity tables that will be loaded if they exist
  @parity_tables [
    :idempotency,
    :agents,
    :agent_files,
    :sessions_index,
    :skills_status_cache,
    :skills_config,
    :cron_jobs,
    :cron_runs,
    :exec_approvals_policy,
    :exec_approvals_policy_agent,
    :exec_approvals_policy_node,
    :exec_approvals_pending,
    :nodes_pairing,
    :nodes_registry,
    :voicewake_config,
    :tts_config
  ]

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    skip_tables = Keyword.get(opts, :skip_tables, [])

    case File.mkdir_p(path) do
      :ok ->
        state = %{
          path: path,
          data: %{},
          loaded_tables: MapSet.new()
        }

        load_all_tables(state, skip_tables)

      {:error, _reason} ->
        {:error, {:jsonl_unavailable, :mkdir_failed}}
    end
  end

  @impl true
  def put(state, table, key, value) do
    with {:ok, state} <- ensure_table_loaded(state, table),
         {:ok, entry} <- encode_entry("put", key, value),
         :ok <- append_entry(state, table, entry) do
      data = put_in(state.data, [Access.key(table, %{}), key], value)
      {:ok, %{state | data: data}}
    end
  end

  @impl true
  def put_new(state, table, key, value) do
    with {:ok, state} <- ensure_table_loaded(state, table) do
      if Map.has_key?(Map.get(state.data, table, %{}), key) do
        {:exists, state}
      else
        put(state, table, key, value)
      end
    end
  end

  @impl true
  def get(state, table, key) do
    with {:ok, state} <- ensure_table_loaded(state, table) do
      {:ok, get_in(state.data, [table, key]), state}
    end
  end

  @impl true
  def delete(state, table, key) do
    with {:ok, state} <- ensure_table_loaded(state, table),
         {:ok, entry} <- encode_entry("delete", key, nil),
         :ok <- append_entry(state, table, entry) do
      data = update_in(state.data, [Access.key(table, %{})], &Map.delete(&1, key))
      {:ok, %{state | data: data}}
    end
  end

  # Appends are unsynced; flush every table file, then its directory so newly
  # created table files are durable too. Durable owns the actual host barrier,
  # including Darwin F_FULLFSYNC; unsupported/refused barriers fail closed.
  @impl true
  def sync(state) do
    state.path
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn file, :ok ->
      case LemonCore.Durable.sync_file(file) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:jsonl_unavailable, :sync_failed}}}
      end
    end)
    |> case do
      :ok ->
        case LemonCore.Durable.sync_directory(state.path) do
          :ok -> {:ok, state}
          {:error, _reason} -> {:error, {:jsonl_unavailable, :sync_failed}}
        end

      error ->
        error
    end
  end

  @impl true
  def compare_and_delete_many(state, entries) do
    loaded =
      Enum.reduce_while(entries, {:ok, state}, fn {table, _key, _expected}, {:ok, acc} ->
        case ensure_table_loaded(acc, table) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case loaded do
      {:ok, state} ->
        if Enum.all?(entries, fn {table, key, expected} ->
             Map.fetch(Map.get(state.data, table, %{}), key) == {:ok, expected}
           end) do
          Enum.reduce_while(entries, {:ok, state}, fn {table, key, _expected}, {:ok, acc} ->
            case delete(acc, table, key) do
              {:ok, next_state} -> {:cont, {:ok, next_state}}
              {:error, reason} -> {:halt, {:error, reason, acc}}
            end
          end)
        else
          {:error, :mismatch, state}
        end

      error ->
        error
    end
  end

  @impl true
  def list(state, table) do
    with {:ok, state} <- ensure_table_loaded(state, table) do
      {:ok, state.data |> Map.get(table, %{}) |> Enum.to_list(), state}
    end
  end

  @doc """
  List all loaded tables.
  """
  @spec list_tables(map()) :: [atom()]
  def list_tables(state) do
    MapSet.to_list(state.loaded_tables)
  end

  @doc """
  Ensure a table is loaded into memory.

  If the table file exists but hasn't been loaded, it will be loaded.
  Only confirmed absence marks a table as loaded (empty). A failed load returns
  an error without publishing partial data or preventing access after repair.
  """
  @spec ensure_table_loaded(map(), atom()) :: {:ok, map()} | {:error, term()}
  def ensure_table_loaded(state, table) do
    if MapSet.member?(state.loaded_tables, table) do
      {:ok, state}
    else
      with {:ok, new_state} <- load_table(state, table) do
        {:ok, %{new_state | loaded_tables: MapSet.put(new_state.loaded_tables, table)}}
      end
    end
  end

  # Private functions

  defp load_all_tables(state, skip_tables) do
    with {:ok, discovered_tables} <- discover_tables(state.path) do
      (@core_tables ++ @parity_tables ++ discovered_tables)
      |> Enum.reject(&(&1 in skip_tables))
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, state}, fn table, {:ok, acc} ->
        case ensure_table_loaded(acc, table) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp discover_tables(path) do
    case File.ls(path) do
      {:ok, files} ->
        tables =
          files
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(fn filename ->
            filename |> String.replace_suffix(".jsonl", "") |> String.to_atom()
          end)

        {:ok, tables}

      {:error, _reason} ->
        {:error, {:jsonl_unavailable, :discovery_failed}}
    end
  end

  defp load_table(state, table) do
    file_path = table_path(state.path, table)

    case File.read(file_path) do
      {:ok, content} ->
        replay_file(state, table, content)

      {:error, :enoent} ->
        # A dangling link or missing store directory is not a new table.
        with {:error, :enoent} <- File.lstat(file_path),
             {:ok, %File.Stat{type: :directory}} <- File.stat(state.path) do
          {:ok, state}
        else
          _ -> {:error, {:jsonl_unavailable, :read_failed}}
        end

      {:error, _reason} ->
        {:error, {:jsonl_unavailable, :read_failed}}
    end
  end

  defp replay_file(state, table, content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case replay_entry(line, acc) do
        {:ok, data} -> {:cont, {:ok, data}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, data} ->
        # Keep absent tables out of data, as for a fresh store.
        data =
          if data == %{},
            do: Map.delete(state.data, table),
            else: Map.put(state.data, table, data)

        {:ok, %{state | data: data}}

      error ->
        error
    end
  end

  defp replay_entry(line, data) do
    case Jason.decode(line) do
      {:ok, %{"op" => "put", "key" => key, "value" => value}} ->
        {:ok, Map.put(data, decode_key(key), decode_value(value))}

      {:ok, %{"op" => "delete", "key" => key}} ->
        {:ok, Map.delete(data, decode_key(key))}

      _ ->
        {:error, {:jsonl_unavailable, :corrupt_table}}
    end
  rescue
    _error -> {:error, {:jsonl_unavailable, :corrupt_table}}
  end

  defp encode_entry(op, key, value) do
    entry = %{
      "op" => op,
      "key" => encode_key(key),
      "ts" => System.system_time(:millisecond)
    }

    entry = if op == "put", do: Map.put(entry, "value", encode_value(value)), else: entry

    case Jason.encode(entry) do
      {:ok, line} -> {:ok, [line, "\n"]}
      {:error, _reason} -> {:error, {:jsonl_unavailable, :encode_failed}}
    end
  rescue
    _error -> {:error, {:jsonl_unavailable, :encode_failed}}
  end

  defp append_entry(state, table, entry) do
    case File.write(table_path(state.path, table), entry, [:append, :binary]) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:jsonl_unavailable, :write_failed}}
    end
  end

  defp table_path(base_path, table) do
    Path.join(base_path, "#{table}.jsonl")
  end

  # Key encoding for JSON compatibility
  # Tuples, structs, and other Elixir terms need special handling

  defp encode_value(value), do: encode_key(value)

  defp decode_value(value), do: decode_key(value)

  defp encode_key(key) when is_struct(key) do
    # Convert struct to map with module name marker
    struct_name = key.__struct__ |> Module.split() |> Enum.join(".")
    fields = Map.from_struct(key) |> encode_key()
    %{"__struct__" => struct_name, "fields" => fields}
  end

  defp encode_key(key) when is_tuple(key) do
    %{"__tuple__" => Tuple.to_list(key) |> Enum.map(&encode_key/1)}
  end

  defp encode_key(key) when is_atom(key) do
    %{"__atom__" => Atom.to_string(key)}
  end

  defp encode_key(key) when is_reference(key) do
    %{"__ref__" => inspect(key)}
  end

  defp encode_key(key) when is_pid(key) do
    %{"__pid__" => inspect(key)}
  end

  defp encode_key(key) when is_map(key) do
    Map.new(key, fn {k, v} -> {encode_key_string(k), encode_key(v)} end)
  end

  defp encode_key(key) when is_list(key) do
    Enum.map(key, &encode_key/1)
  end

  defp encode_key(key), do: key

  defp encode_key_string(key) when is_atom(key), do: "__atom__:#{key}"
  defp encode_key_string(key) when is_binary(key), do: key
  defp encode_key_string(key), do: inspect(key)

  defp decode_key(%{"__struct__" => struct_name, "fields" => fields}) do
    # Reconstruct struct from module name and fields
    module = String.split(struct_name, ".") |> Module.concat()
    decoded_fields = decode_key(fields)
    struct(module, decoded_fields)
  end

  defp decode_key(%{"__tuple__" => list}) when is_list(list) do
    list |> Enum.map(&decode_key/1) |> List.to_tuple()
  end

  defp decode_key(%{"__atom__" => str}) when is_binary(str) do
    String.to_atom(str)
  end

  defp decode_key(%{"__ref__" => _str}) do
    # References can't be reconstructed, use a placeholder
    :persisted_ref
  end

  defp decode_key(%{"__pid__" => _str}) do
    # PIDs can't be reconstructed, use a placeholder
    :persisted_pid
  end

  defp decode_key(key) when is_map(key) do
    Map.new(key, fn {k, v} -> {decode_key_string(k), decode_key(v)} end)
  end

  defp decode_key(key) when is_list(key) do
    Enum.map(key, &decode_key/1)
  end

  defp decode_key(key), do: key

  defp decode_key_string("__atom__:" <> rest), do: String.to_atom(rest)
  defp decode_key_string(key), do: key
end
