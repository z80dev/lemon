defmodule LemonCore.Quality.DocsCatalog do
  @moduledoc """
  Loads and validates docs catalog metadata used by quality checks.
  """

  @catalog_path "docs/catalog.exs"

  @type entry :: %{
          required(:path) => String.t(),
          required(:owner) => String.t(),
          required(:last_reviewed) => Date.t(),
          required(:max_age_days) => pos_integer(),
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
      {:error, reason} -> {:error, "Failed to evaluate #{path}: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, "Failed to evaluate #{path}: #{Exception.message(exception)}"}
  end

  defp parse_catalog_source(path, source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, entries} <- decode_ast(ast) do
      case entries do
        entries when is_list(entries) ->
          {:ok, entries}

        other ->
          {:error, "Expected #{path} to evaluate to a list, got: #{inspect(other)}"}
      end
    else
      {:error, reason} ->
        {:error, "Failed to evaluate #{path}: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, "Failed to evaluate #{path}: #{Exception.message(exception)}"}
  end

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
