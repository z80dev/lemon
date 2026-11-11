defmodule CodingAgent.Tools.Task.StructuredOutput do
  @moduledoc """
  Strict JSON decoding and a bounded, reference-free JSON Schema subset for tasks.

  Schemas use string keys and may be objects or boolean schemas. Unsupported
  keywords (including references and formats) are rejected, not ignored. Schema
  JSON is limited to 65,536 encoded bytes and 32 container levels, including
  annotations. Patterns use Unicode regular expressions supported by `Regex`.
  String lengths count Unicode code points, not graphemes. Integer schemas accept
  mathematically integral JSON numbers, including `1.0`; values are never coerced.

  Errors identify a JSON path and constraint without including response values.
  Unknown response property names are redacted from paths. `nil` disables the
  contract. Callers should validate before adding `instruction/1` to a prompt.
  Match-budget exhaustion rejects the complete response, including under `not`
  and branching schemas; it is not an ordinary non-match that can be inverted.
  """

  @max_bytes 65_536
  @max_depth 32
  @types ~w(string object array integer number boolean null)
  @annotations ~w(title description $schema default examples)
  @counts ~w(minLength maxLength minItems maxItems minProperties maxProperties)
  @bounds ~w(minimum maximum exclusiveMinimum exclusiveMaximum multipleOf)
  @combinators ~w(anyOf oneOf allOf)

  @spec validate_schema(term()) :: :ok | {:error, String.t()}
  def validate_schema(nil), do: :ok

  def validate_schema(schema) do
    case prepare(schema) do
      {:ok, _schema} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec instruction(term()) :: String.t()
  def instruction(nil), do: ""

  def instruction(schema) do
    "Your final response must be ONLY valid JSON matching the following JSON schema. " <>
      "Do not include Markdown fences, explanations, or any other prose.\n" <>
      Jason.encode!(schema)
  end

  @spec decode(term(), term()) :: {:ok, term()} | {:error, String.t()}
  def decode(_text, nil), do: {:ok, nil}

  def decode(text, schema) do
    with {:ok, prepared} <- prepare(schema),
         {:ok, value} <- decode_json(text),
         :ok <- validate(value, prepared, "$") do
      {:ok, value}
    end
  rescue
    SystemLimitError -> error("$", "string pattern exceeded its match budget")
  end

  defp decode_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> error("$", "response is not valid JSON")
    end
  end

  defp decode_json(_), do: error("$", "response must be JSON text")

  defp prepare(schema) do
    with {:ok, _remaining} <- json_budget(schema, "$", 0, @max_bytes) do
      prepare_schema(schema, "$")
    end
  end

  # Check the JSON representation before encoding a whole schema or recursing
  # through its semantics. Accounting includes separators and escaped strings.
  defp json_budget(_value, path, depth, _remaining) when depth > @max_depth,
    do: error(path, "schema exceeds maximum nesting of #{@max_depth}")

  defp json_budget(_value, path, _depth, remaining) when remaining < 0,
    do: error(path, "schema exceeds maximum encoded size of #{@max_bytes} bytes")

  defp json_budget(value, path, depth, remaining) when is_map(value) and not is_struct(value) do
    remaining = remaining - 2 - max(map_size(value) - 1, 0)

    Enum.reduce_while(value, budget_result(remaining, path), fn
      {key, child}, {:ok, budget} when is_binary(key) ->
        result =
          with {:ok, budget} <- json_budget(key, path, depth + 1, budget - 1) do
            json_budget(child, child_path(path, key), depth + 1, budget)
          end

        continue(result)

      _, {:ok, _} ->
        {:halt, error(path, "schema object keys must be strings")}

      _, {:error, _} = error ->
        {:halt, error}
    end)
  end

  defp json_budget(value, path, depth, remaining) when is_list(value) do
    remaining = remaining - 2 - max(length(value) - 1, 0)

    value
    |> Enum.with_index()
    |> Enum.reduce_while(budget_result(remaining, path), fn
      {child, index}, {:ok, budget} ->
        continue(json_budget(child, index_path(path, index), depth + 1, budget))

      _, {:error, _} = error ->
        {:halt, error}
    end)
  end

  defp json_budget(value, path, _depth, remaining)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    cond do
      is_binary(value) and byte_size(value) > remaining ->
        budget_result(-1, path)

      is_binary(value) and not String.valid?(value) ->
        error(path, "schema strings must be valid UTF-8")

      true ->
        case Jason.encode(value) do
          {:ok, encoded} -> budget_result(remaining - byte_size(encoded), path)
          {:error, _} -> error(path, "schema must contain only JSON values")
        end
    end
  end

  defp json_budget(_, path, _depth, _remaining),
    do: error(path, "schema must contain only JSON values")

  defp budget_result(remaining, path) when remaining < 0,
    do: error(path, "schema exceeds maximum encoded size of #{@max_bytes} bytes")

  defp budget_result(remaining, _path), do: {:ok, remaining}

  defp prepare_schema(schema, _path) when is_boolean(schema), do: {:ok, schema}

  defp prepare_schema(schema, path) when is_map(schema) do
    Enum.reduce_while(schema, {:ok, schema}, fn {keyword, value}, {:ok, prepared} ->
      case prepare_keyword(keyword, value, child_path(path, keyword)) do
        {:ok, value} -> {:cont, {:ok, Map.put(prepared, keyword, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_schema(_, path), do: error(path, "schema must be an object or boolean")

  defp prepare_keyword("type", value, path) do
    types = if is_list(value), do: value, else: [value]

    if types != [] and Enum.all?(types, &(&1 in @types)) and
         length(Enum.uniq(types)) == length(types) do
      {:ok, value}
    else
      error(path, "type must name supported JSON types without duplicates")
    end
  end

  defp prepare_keyword("properties", value, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, schema}, {:ok, prepared} ->
      case prepare_schema(schema, child_path(path, key)) do
        {:ok, schema} -> {:cont, {:ok, Map.put(prepared, key, schema)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_keyword("required", value, path) do
    if is_list(value) and Enum.all?(value, &is_binary/1) and
         length(Enum.uniq(value)) == length(value) do
      {:ok, value}
    else
      error(path, "required must be an array of unique property names")
    end
  end

  defp prepare_keyword(keyword, value, path)
       when keyword in ["additionalProperties", "items", "not"],
       do: prepare_schema(value, path)

  defp prepare_keyword(keyword, value, path) when keyword in @combinators do
    if is_list(value) and value != [] do
      value
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {schema, index}, {:ok, prepared} ->
        case prepare_schema(schema, index_path(path, index)) do
          {:ok, schema} -> {:cont, {:ok, [schema | prepared]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
        {:error, _} = error -> error
      end
    else
      error(path, "#{keyword} must be a non-empty array of schemas")
    end
  end

  defp prepare_keyword("enum", value, path) do
    if is_list(value) and value != [] and unique?(value) do
      {:ok, value}
    else
      error(path, "enum must be a non-empty array of distinct JSON values")
    end
  end

  defp prepare_keyword("const", value, _path), do: {:ok, value}

  defp prepare_keyword(keyword, value, path) when keyword in @counts do
    if type?(value, "integer") and value >= 0,
      do: {:ok, value},
      else: error(path, "#{keyword} must be a non-negative integer")
  end

  defp prepare_keyword(keyword, value, path) when keyword in @bounds do
    if is_number(value) and (keyword != "multipleOf" or value > 0) do
      {:ok, value}
    else
      suffix = if keyword == "multipleOf", do: " greater than zero", else: ""
      error(path, "#{keyword} must be a number#{suffix}")
    end
  end

  defp prepare_keyword("pattern", value, path) when is_binary(value) do
    case Regex.compile(value, "u") do
      {:ok, pattern} -> {:ok, pattern}
      {:error, _} -> error(path, "pattern must be a valid Unicode regular expression")
    end
  end

  defp prepare_keyword("uniqueItems", value, _path) when is_boolean(value), do: {:ok, value}

  defp prepare_keyword(keyword, value, path) when keyword in @annotations do
    cond do
      keyword == "default" -> {:ok, value}
      keyword == "examples" and is_list(value) -> {:ok, value}
      keyword in ["title", "description", "$schema"] and is_binary(value) -> {:ok, value}
      true -> error(path, "invalid annotation value")
    end
  end

  defp prepare_keyword(keyword, _value, path)
       when keyword in ["properties", "pattern", "uniqueItems"],
       do: error(path, "invalid #{keyword} constraint")

  defp prepare_keyword(_keyword, _value, path), do: error(path, "unsupported schema keyword")

  defp validate(_value, true, _path), do: :ok
  defp validate(_value, false, path), do: error(path, "boolean schema forbids this value")

  defp validate(value, schema, path) do
    Enum.reduce_while(schema, :ok, fn {keyword, constraint}, :ok ->
      continue(validate_keyword(keyword, constraint, value, schema, path))
    end)
  end

  defp validate_keyword("type", types, value, _schema, path) do
    check(Enum.any?(List.wrap(types), &type?(value, &1)), path, "type mismatch")
  end

  defp validate_keyword("enum", choices, value, _schema, path),
    do: check(Enum.any?(choices, &equal?(&1, value)), path, "value does not match enum")

  defp validate_keyword("const", expected, value, _schema, path),
    do: check(equal?(expected, value), path, "value does not match const")

  defp validate_keyword("allOf", schemas, value, _schema, path) do
    Enum.reduce_while(schemas, :ok, fn schema, :ok ->
      continue(validate(value, schema, path))
    end)
  end

  defp validate_keyword("anyOf", schemas, value, _schema, path),
    do:
      check(
        Enum.any?(schemas, &(validate(value, &1, path) == :ok)),
        path,
        "no anyOf branch matched"
      )

  defp validate_keyword("oneOf", schemas, value, _schema, path),
    do:
      check(
        Enum.count(schemas, &(validate(value, &1, path) == :ok)) == 1,
        path,
        "exactly one oneOf branch must match"
      )

  defp validate_keyword("not", schema, value, _parent, path),
    do: check(validate(value, schema, path) != :ok, path, "value matches forbidden not schema")

  defp validate_keyword("required", names, value, _schema, path) when is_map(value) do
    case Enum.find(names, &(not Map.has_key?(value, &1))) do
      nil -> :ok
      name -> error(child_path(path, name), "required property is missing")
    end
  end

  defp validate_keyword("properties", properties, value, _schema, path) when is_map(value) do
    Enum.reduce_while(properties, :ok, fn {name, schema}, :ok ->
      case Map.fetch(value, name) do
        {:ok, child} -> continue(validate(child, schema, child_path(path, name)))
        :error -> {:cont, :ok}
      end
    end)
  end

  defp validate_keyword("additionalProperties", additional, value, schema, path)
       when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    Enum.reduce_while(value, :ok, fn {name, child}, :ok ->
      cond do
        Map.has_key?(properties, name) or additional == true -> {:cont, :ok}
        additional == false -> {:halt, error(path, "additional properties are forbidden")}
        true -> continue(validate(child, additional, path <> "[additional property]"))
      end
    end)
  end

  defp validate_keyword("items", schema, value, _parent, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
      continue(validate(child, schema, index_path(path, index)))
    end)
  end

  defp validate_keyword("uniqueItems", true, value, _schema, path) when is_list(value),
    do: check(unique?(value), path, "array items must be unique")

  defp validate_keyword("pattern", pattern, value, _schema, path) when is_binary(value),
    do: check(Regex.match?(pattern, value), path, "string does not match pattern")

  defp validate_keyword(keyword, bound, value, _schema, path)
       when keyword in @counts do
    size =
      cond do
        keyword in ["minLength", "maxLength"] and is_binary(value) ->
          codepoint_length(value, 0)

        keyword in ["minItems", "maxItems"] and is_list(value) ->
          length(value)

        keyword in ["minProperties", "maxProperties"] and is_map(value) ->
          map_size(value)

        true ->
          nil
      end

    cond do
      is_nil(size) ->
        :ok

      keyword in ["minLength", "minItems", "minProperties"] ->
        check(size >= bound, path, "#{keyword} constraint failed")

      true ->
        check(size <= bound, path, "#{keyword} constraint failed")
    end
  end

  defp validate_keyword(keyword, bound, value, _schema, path)
       when keyword in @bounds and is_number(value) do
    valid =
      case keyword do
        "minimum" -> value >= bound
        "maximum" -> value <= bound
        "exclusiveMinimum" -> value > bound
        "exclusiveMaximum" -> value < bound
        "multipleOf" -> multiple?(value, bound)
      end

    check(valid, path, "#{keyword} constraint failed")
  end

  # Schema preparation rejects unknown keywords. Type-specific constraints do
  # not apply to other JSON types, as required by JSON Schema semantics.
  defp validate_keyword(_keyword, _constraint, _value, _schema, _path), do: :ok

  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "array"), do: is_list(value)

  defp type?(value, "integer"),
    do: is_integer(value) or (is_float(value) and trunc(value) == value)

  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "null"), do: is_nil(value)

  defp codepoint_length(<<_::utf8, rest::binary>>, count), do: codepoint_length(rest, count + 1)
  defp codepoint_length(<<>>, count), do: count

  # JSON numeric equality treats 1 and 1.0 alike, including nested enum/const
  # values and uniqueItems. Erlang map equality alone does not do this for values.
  defp equal?(left, right) when is_map(left) and is_map(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        case Map.fetch(right, key) do
          {:ok, other} -> equal?(value, other)
          :error -> false
        end
      end)
  end

  defp equal?([left | left_rest], [right | right_rest]),
    do: equal?(left, right) and equal?(left_rest, right_rest)

  defp equal?(left, right), do: left == right

  defp unique?(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      key = equality_key(value)

      if MapSet.member?(seen, key),
        do: {:halt, false},
        else: {:cont, MapSet.put(seen, key)}
    end) != false
  end

  defp equality_key(value) when is_float(value) do
    integer = trunc(value)
    if integer == value, do: integer, else: value
  end

  defp equality_key(value) when is_list(value), do: Enum.map(value, &equality_key/1)

  defp equality_key(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, equality_key(child)} end)

  defp equality_key(value), do: value

  # Decimal rational arithmetic avoids accepting near-multiples via a floating
  # point tolerance or rejecting ordinary values such as 0.3 / 0.1.
  defp multiple?(value, bound) do
    {value_numerator, value_denominator} = rational(value)
    {bound_numerator, bound_denominator} = rational(bound)
    rem(value_numerator * bound_denominator, value_denominator * bound_numerator) == 0
  end

  defp rational(value) when is_integer(value), do: {value, 1}

  defp rational(value) do
    [mantissa | exponent] = String.split(:erlang.float_to_binary(value, [:short]), "e")
    exponent = if exponent == [], do: 0, else: String.to_integer(hd(exponent))
    [whole, fraction] = String.split(mantissa, ".")
    numerator = String.to_integer(whole <> fraction)
    scale = byte_size(fraction) - exponent

    if scale >= 0,
      do: {numerator, Integer.pow(10, scale)},
      else: {numerator * Integer.pow(10, -scale), 1}
  end

  defp child_path(path, name), do: path <> "[" <> Jason.encode!(name) <> "]"
  defp index_path(path, index), do: path <> "[#{index}]"
  defp check(true, _path, _message), do: :ok
  defp check(false, path, message), do: error(path, message)
  defp error(path, message), do: {:error, "#{path}: #{message}"}
  defp continue({:error, _} = error), do: {:halt, error}
  defp continue(result), do: {:cont, result}
end
