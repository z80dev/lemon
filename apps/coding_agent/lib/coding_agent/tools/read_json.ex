defmodule CodingAgent.Tools.ReadJson do
  @moduledoc """
  Deterministic, dependency-free jq subset for JSON `read` queries.
  Supports identity, field/index traversal, iteration, pipes, keys, length and
  select comparisons against JSON scalars. No executable or shell is invoked.
  """

  alias CodingAgent.Tools.{ReadFormats, ReadFormatText}
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def split_path(path) do
    case String.split(path, "?q=", parts: 2) do
      [file, query] -> if String.downcase(Path.extname(file)) == ".json", do: {file, query}
      _ -> nil
    end
  end

  def read(path, query, source, params, signal, opts) do
    with :ok <- ReadFormats.check_input(path, opts),
         :ok <- check_abort(signal),
         {:ok, bytes} <- File.read(path),
         {:ok, value} <- decode_json(bytes),
         {:ok, stages} <- parse(URI.decode_www_form(query)),
         {:ok, values} <- evaluate([value], stages),
         :ok <- check_abort(signal) do
      text =
        if values == [],
          do: "(no results)",
          else: Enum.map_join(values, "\n", &Jason.encode!(&1, pretty: true))

      ReadFormatText.result(text, source, params, signal, opts, %{
        format: :json_query,
        immutable: true
      })
    end
  rescue
    _ -> {:error, "Cannot read JSON query"}
  end

  defp decode_json(bytes) do
    case Jason.decode(bytes) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, "JSON source is not valid JSON"}
    end
  end

  defp parse(filter) do
    with {:ok, stages} <- split_pipes(String.to_charlist(filter), false, false, [], []) do
      Enum.reduce_while(stages, {:ok, []}, fn stage, {:ok, acc} ->
        case parse_stage(String.trim(stage)) do
          {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, operations} -> {:ok, Enum.reverse(operations)}
        error -> error
      end
    end
  end

  defp split_pipes([], false, _escape, current, acc),
    do: {:ok, Enum.reverse([current |> Enum.reverse() |> List.to_string() | acc])}

  defp split_pipes([], true, _escape, _current, _acc),
    do: {:error, "Unterminated JSON query string"}

  defp split_pipes([char | rest], quoted, escaped, current, acc) do
    cond do
      escaped ->
        split_pipes(rest, quoted, false, [char | current], acc)

      char == ?\\ and quoted ->
        split_pipes(rest, quoted, true, [char | current], acc)

      char == ?" ->
        split_pipes(rest, not quoted, false, [char | current], acc)

      char == ?| and not quoted ->
        split_pipes(rest, false, false, [], [current |> Enum.reverse() |> List.to_string() | acc])

      true ->
        split_pipes(rest, quoted, false, [char | current], acc)
    end
  end

  defp parse_stage("keys"), do: {:ok, :keys}
  defp parse_stage("length"), do: {:ok, :length}

  defp parse_stage("select(" <> _ = stage) do
    case Regex.run(
           ~r/\Aselect\(\s*(\.[A-Za-z_][A-Za-z_0-9.]*)\s*(==|!=|<|>)\s*(.*?)\s*\)\z/s,
           stage,
           capture: :all_but_first
         ) do
      [path, operator, literal] ->
        with {:ok, ops} <- path_ops(path),
             {:ok, value} <- decode_json(literal),
             true <- scalar?(value) do
          {:ok, {:select, ops, operator, value}}
        else
          _ -> {:error, "select requires a field path and a JSON scalar comparison"}
        end

      _ ->
        {:error, "Unsupported select expression; use select(.field == value)"}
    end
  end

  defp parse_stage("." <> _ = path) do
    with {:ok, ops} <- path_ops(path), do: {:ok, {:path, ops}}
  end

  defp parse_stage(_),
    do: {:error, "Unsupported JSON query; use paths, iteration, keys, length or select"}

  defp path_ops("."), do: {:ok, []}
  defp path_ops(".[" <> rest), do: path_ops("[" <> rest)
  defp path_ops(""), do: {:ok, []}

  defp path_ops(path) do
    case Regex.run(~r/\A(?:\.([A-Za-z_][A-Za-z_0-9]*)|\[(-?\d+)\]|(\[\]))(.*)\z/s, path,
           capture: :all_but_first
         ) do
      [field, index, each, rest] ->
        op =
          cond do
            each != "" -> :each
            index != "" -> {:index, String.to_integer(index)}
            true -> {:field, field}
          end

        with {:ok, tail} <- path_ops(rest), do: {:ok, [op | tail]}

      _ ->
        {:error, "Unsupported JSON field/index path"}
    end
  end

  defp evaluate(values, []), do: {:ok, values}

  defp evaluate(values, [stage | rest]) do
    with {:ok, next} <- flat_apply(values, &apply_stage(&1, stage)), do: evaluate(next, rest)
  end

  defp flat_apply(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, results} -> {:cont, {:ok, [results | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp apply_stage(value, {:path, ops}), do: evaluate([value], Enum.map(ops, &{:step, &1}))

  defp apply_stage(value, {:step, {:field, key}}) when is_map(value),
    do: {:ok, [Map.get(value, key)]}

  defp apply_stage(nil, {:step, {:field, _key}}), do: {:ok, [nil]}

  defp apply_stage(value, {:step, {:index, index}}) when is_list(value),
    do: {:ok, [Enum.at(value, index)]}

  defp apply_stage(nil, {:step, {:index, _index}}), do: {:ok, [nil]}

  defp apply_stage(value, {:step, :each}) when is_list(value), do: {:ok, value}

  defp apply_stage(value, {:step, :each}) when is_map(value),
    do: {:ok, value |> Enum.sort() |> Enum.map(&elem(&1, 1))}

  defp apply_stage(value, :keys) when is_map(value),
    do: {:ok, [value |> Map.keys() |> Enum.sort()]}

  defp apply_stage(value, :keys) when is_list(value),
    do: {:ok, [Enum.to_list(0..(length(value) - 1)//1)]}

  defp apply_stage(value, :length) when is_map(value), do: {:ok, [map_size(value)]}
  defp apply_stage(value, :length) when is_list(value), do: {:ok, [length(value)]}

  defp apply_stage(value, :length) when is_binary(value),
    do: {:ok, [value |> String.to_charlist() |> length()]}

  defp apply_stage(value, :length) when is_number(value), do: {:ok, [abs(value)]}
  defp apply_stage(nil, :length), do: {:ok, [0]}

  defp apply_stage(value, {:select, ops, operator, expected}) do
    with {:ok, [actual]} <- apply_stage(value, {:path, ops}),
         true <- scalar?(actual) do
      {:ok, if(compare(actual, expected, operator), do: [value], else: [])}
    else
      _ -> {:error, "select comparisons require scalar field values"}
    end
  end

  defp apply_stage(_value, _stage),
    do: {:error, "JSON query operation does not apply to this value type"}

  defp scalar?(value), do: not is_map(value) and not is_list(value)
  defp compare(a, b, "=="), do: a == b
  defp compare(a, b, "!="), do: a != b
  defp compare(a, b, "<"), do: {scalar_rank(a), a} < {scalar_rank(b), b}
  defp compare(a, b, ">"), do: {scalar_rank(a), a} > {scalar_rank(b), b}
  defp scalar_rank(nil), do: 0
  defp scalar_rank(false), do: 1
  defp scalar_rank(true), do: 2
  defp scalar_rank(value) when is_number(value), do: 3
  defp scalar_rank(_value), do: 4
end
