defmodule LemonGateway.Store.JsonlBackend do
  @moduledoc """
  Persistent JSONL-based storage backend.

  Stores all operations as append-only JSONL (JSON Lines) files.
  Each logical table is stored in a separate file within the configured directory.

  ## Options

    * `:path` - Required. Directory path where JSONL files will be stored.

  ## File Format

  Each line is a JSON object with the structure:
  ```json
  {"op": "put"|"delete", "key": <key>, "value": <value>, "ts": <unix_ms>}
  ```

  On init, files are replayed to reconstruct state. Only the latest value
  for each key is kept in memory.
  """

  @behaviour LemonGateway.Store.Backend

  @tables [:chat, :progress, :runs, :run_history]

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    case File.mkdir_p(path) do
      :ok ->
        state = %{
          path: path,
          data: %{},
          file_handles: %{}
        }

        load_all_tables(state)

      {:error, reason} ->
        {:error, {:mkdir_failed, path, reason}}
    end
  end

  @impl true
  def put(state, table, key, value) do
    entry = %{
      "op" => "put",
      "key" => encode_key(key),
      "value" => value,
      "ts" => System.system_time(:millisecond)
    }

    state = append_entry(state, table, entry)
    data = put_in(state.data, [Access.key(table, %{}), key], value)
    {:ok, %{state | data: data}}
  end

  @impl true
  def get(state, table, key) do
    value = get_in(state.data, [table, key])
    {:ok, value, state}
  end

  @impl true
  def delete(state, table, key) do
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
    items =
      state.data
      |> Map.get(table, %{})
      |> Enum.to_list()

    {:ok, items, state}
  end

  # Private functions

  defp load_all_tables(state) do
    result =
      Enum.reduce_while(@tables, state, fn table, acc ->
        case load_table(acc, table) do
          {:ok, new_state} -> {:cont, new_state}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      %{} = final_state -> {:ok, final_state}
      {:error, _} = err -> err
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
                Map.put(acc, decode_key(key), value)

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
