defmodule LemonCore.Quality.DocsCatalog do
  @moduledoc """
  Loads docs catalog metadata used by quality checks.

  Catalogs may use the compact `%{defaults: map(), entries: list()}` format or
  the legacy bare entry list. In both cases callers receive a normalized list
  with conservative lifecycle metadata filled in.
  """

  @catalog_path "docs/catalog.exs"
  @entry_defaults %{kind: :reference, status: :current, public: false}

  @type entry :: %{
          required(:path) => String.t(),
          required(:owner) => String.t(),
          required(:last_reviewed) => Date.t(),
          required(:max_age_days) => pos_integer(),
          required(:kind) => atom(),
          required(:status) => atom(),
          required(:public) => boolean(),
          optional(atom()) => any()
        }

  @spec load(keyword()) :: {:ok, [entry()]} | {:error, String.t()}
  def load(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    catalog_file = Path.join(root, @catalog_path)

    with :ok <- ensure_catalog_exists(catalog_file),
         {:ok, entries} <- parse_catalog(catalog_file) do
      {:ok, entries}
    end
  end

  @spec catalog_file(String.t()) :: String.t()
  def catalog_file(root) do
    Path.join(root, @catalog_path)
  end

  defp ensure_catalog_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, "Missing catalog file: #{path}"}
    end
  end

  defp parse_catalog(path) do
    case File.read(path) do
      {:ok, source} -> parse_catalog_source(path, source)
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, "Failed to read #{path}: #{Exception.message(exception)}"}
  end

  defp parse_catalog_source(path, source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, catalog} <- decode_ast(ast),
         {:ok, entries} <- normalize_catalog(catalog) do
      {:ok, entries}
    else
      {:error, {:invalid_catalog, message}} ->
        {:error, "Invalid catalog #{path}: #{message}"}

      {:error, reason} ->
        {:error, "Failed to parse #{path}: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, "Failed to parse #{path}: #{Exception.message(exception)}"}
  end

  defp normalize_catalog(entries) when is_list(entries) do
    normalize_entries(entries, @entry_defaults)
  end

  defp normalize_catalog(%{} = catalog) do
    unknown_keys = Map.keys(catalog) -- [:defaults, :entries]

    with :ok <- ensure_known_keys(unknown_keys),
         {:ok, defaults} <- fetch_defaults(catalog),
         {:ok, entries} <- fetch_entries(catalog) do
      normalize_entries(entries, Map.merge(@entry_defaults, defaults))
    end
  end

  defp normalize_catalog(other) do
    invalid_catalog(
      "expected a list or %{defaults: map(), entries: list()}, got: #{inspect(other)}"
    )
  end

  defp fetch_defaults(catalog) do
    case Map.get(catalog, :defaults, %{}) do
      defaults when is_map(defaults) -> {:ok, defaults}
      other -> invalid_catalog("expected :defaults to be a map, got: #{inspect(other)}")
    end
  end

  defp ensure_known_keys([]), do: :ok

  defp ensure_known_keys(keys) do
    invalid_catalog("unknown top-level keys: #{inspect(keys)}")
  end

  defp fetch_entries(catalog) do
    case Map.fetch(catalog, :entries) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      {:ok, other} -> invalid_catalog("expected :entries to be a list, got: #{inspect(other)}")
      :error -> invalid_catalog("missing required :entries list")
    end
  end

  defp normalize_entries(entries, defaults) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      entry, {:ok, acc} when is_map(entry) ->
        {:cont, {:ok, [Map.merge(defaults, entry) | acc]}}

      entry, _acc ->
        {:halt, invalid_catalog("expected every entry to be a map, got: #{inspect(entry)}")}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp invalid_catalog(message), do: {:error, {:invalid_catalog, message}}

  defp decode_ast({:%{}, _meta, pairs}) do
    pairs
    |> Enum.reduce_while({:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      with {:ok, key} <- decode_ast(key_ast),
           {:ok, value} <- decode_ast(value_ast) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_ast(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case decode_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_ast({:sigil_D, _meta, [{:<<>>, _string_meta, [date]}, []]})
       when is_binary(date) do
    Date.from_iso8601(date)
  end

  defp decode_ast(
         {{:., _meta, [{:__aliases__, _aliases_meta, [:Date]}, :from_iso8601!]}, _call_meta,
          [
            date
          ]}
       )
       when is_binary(date) do
    Date.from_iso8601(date)
  end

  defp decode_ast(
         {:|>, _meta,
          [
            date,
            {{:., _call_meta, [{:__aliases__, _aliases_meta, [:Date]}, :from_iso8601!]},
             _from_meta, []}
          ]}
       )
       when is_binary(date) do
    Date.from_iso8601(date)
  end

  defp decode_ast({:-, _meta, [value]}) when is_integer(value) or is_float(value),
    do: {:ok, -value}

  defp decode_ast(
         {:|>, _meta,
          [
            {{:., _to_meta, [{:__aliases__, _aliases_meta, [:Date]}, :to_iso8601]}, _to_call_meta,
             [
               {{:., _today_meta, [{:__aliases__, _today_aliases_meta, [:Date]}, :utc_today]},
                _today_call_meta, []}
             ]},
            {{:., _from_meta, [{:__aliases__, _from_aliases_meta, [:Date]}, :from_iso8601!]},
             _from_call_meta, []}
          ]}
       ) do
    {:ok, Date.utc_today()}
  end

  defp decode_ast(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_atom(value),
       do: {:ok, value}

  defp decode_ast(ast), do: {:error, {:unsupported_catalog_ast, Macro.to_string(ast)}}
end
