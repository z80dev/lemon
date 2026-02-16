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
  New tables are created on first write.
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
          file_handles: %{},
          loaded_tables: MapSet.new()
        }

        load_all_tables(state, skip_tables)

      {:error, reason} ->
        {:error, {:mkdir_failed, path, reason}}
    end
  end

  @impl true
  def put(state, table, key, value) do
    # Ensure table is loaded (for dynamic tables)
    state = ensure_table_loaded(state, table)

    entry = %{
      "op" => "put",
      "key" => encode_key(key),
      "value" => encode_value(value),
      "ts" => System.system_time(:millisecond)
    }

    state = append_entry(state, table, entry)
    data = put_in(state.data, [Access.key(table, %{}), key], value)
    {:ok, %{state | data: data}}
  end

  @impl true
  def get(state, table, key) do
    # Ensure table is loaded (for dynamic tables)
    state = ensure_table_loaded(state, table)
    value = get_in(state.data, [table, key])
    {:ok, value, state}
  end

  @impl true
  def delete(state, table, key) do
    # Ensure table is loaded (for dynamic tables)
    state = ensure_table_loaded(state, table)

    entry = %{
      "op" => "delete",
      "key" => encode_key(key),
      "ts" => System.system_time(:millisecond)
    }

    state = append_entry(state, table, entry)
    data = update_in(state.data, [Access.key(table, %{})], &Map.delete(&1, key))
    {:ok, %{state | data: data}}
  end

  @impl true
  def list(state, table) do
    # Ensure table is loaded (for dynamic tables)
    state = ensure_table_loaded(state, table)

    items =
      state.data
      |> Map.get(table, %{})
      |> Enum.to_list()

    {:ok, items, state}
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
  If the table doesn't exist, it will be marked as loaded (empty).
  """
  @spec ensure_table_loaded(map(), atom()) :: map()
  def ensure_table_loaded(state, table) do
    if MapSet.member?(state.loaded_tables, table) do
      state
    else
      case load_table(state, table) do
        {:ok, new_state} ->
          %{new_state | loaded_tables: MapSet.put(new_state.loaded_tables, table)}

        {:error, _reason} ->
          # If loading fails, still mark as loaded to avoid repeated attempts
          %{state | loaded_tables: MapSet.put(state.loaded_tables, table)}
      end
    end
  end

  # Private functions

  defp load_all_tables(state, skip_tables) do
    # First, discover all existing .jsonl files in the directory
    discovered_tables = discover_tables(state.path)

    # Combine core tables, parity tables, and discovered tables
    all_tables =
      (@core_tables ++ @parity_tables ++ discovered_tables)
      |> Enum.reject(&(&1 in skip_tables))
      |> Enum.uniq()

    result =
      Enum.reduce_while(all_tables, state, fn table, acc ->
        case load_table(acc, table) do
          {:ok, new_state} ->
            new_state = %{new_state | loaded_tables: MapSet.put(new_state.loaded_tables, table)}
            {:cont, new_state}

          {:error, reason} ->
            # Log but continue - don't fail init for optional tables
            require Logger
            Logger.warning("Failed to load table #{table}: #{inspect(reason)}")
            {:cont, acc}
        end
      end)

    {:ok, result}
  end

  defp discover_tables(path) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn filename ->
          filename
          |> String.replace_suffix(".jsonl", "")
          |> String.to_atom()
        end)

      {:error, _} ->
        []
    end
  end

  defp load_table(state, table) do
    file_path = table_path(state.path, table)

    case File.exists?(file_path) do
      true -> replay_file(state, table, file_path)
      false -> {:ok, state}
    end
  end

  defp replay_file(state, table, file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        data =
          content
          |> String.split("\n", trim: true)
          |> Enum.reduce(Map.get(state.data, table, %{}), fn line, acc ->
            case Jason.decode(line) do
              {:ok, %{"op" => "put", "key" => key, "value" => value}} ->
                Map.put(acc, decode_key(key), decode_value(value))

              {:ok, %{"op" => "delete", "key" => key}} ->
                Map.delete(acc, decode_key(key))

              _ ->
                acc
            end
          end)

        {:ok, put_in(state, [:data, Access.key(table, %{})], data)}

      {:error, reason} ->
        {:error, {:read_failed, file_path, reason}}
    end
  end

  defp append_entry(state, table, entry) do
    file_path = table_path(state.path, table)
    line = Jason.encode!(entry) <> "\n"

    # Append to file (create if doesn't exist)
    File.write!(file_path, line, [:append, :utf8])

    state
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
