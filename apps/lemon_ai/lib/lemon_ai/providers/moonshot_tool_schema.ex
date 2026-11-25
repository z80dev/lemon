defmodule LemonAi.Providers.MoonshotToolSchema do
  @moduledoc """
  Moonshot Flavored JSON Schema (MFJS) for tool parameters.

  Moonshot/Kimi native OpenAI-compatible hosts (`api.moonshot.ai`,
  `api.moonshot.cn`, `api.kimi.com`, `api.kimi.ai`) validate
  `tools[].function.parameters` against a stricter JSON Schema subset and
  answer HTTP 400 `... is not a valid moonshot flavored json schema` otherwise.
  `normalize/1` mirrors omp's `normalizeSchemaForMoonshot`:

    * `const`, and `anyOf`/`oneOf` whose every branch is a `const`, become an
      `enum` with an inferred scalar `type`;
    * residual `oneOf` folds into `anyOf` (the only MFJS combinator);
    * `type` arrays reduce to one scalar (the `null` branch is dropped);
      `nullable` is removed;
    * an `enum` without a `type` gets the type its values share; an `enum`
      with values other than strings and numbers is dropped;
    * validation and decorative keywords (`format`, `pattern`, `minItems`,
      `title`, ...) and `prefixItems` are removed; human-meaningful ones are
      appended to the node's `description` as `{key: json, ...}`;
    * boolean subschemas become the permissive `{}`.

  Local references (`#/$defs/Name`, `#/definitions/Name`) are inlined first,
  as omp's `dereferenceJsonSchema` does: keywords beside a `$ref` override the
  definition's, the `$defs`/`definitions` blocks are removed, a reference back
  into a definition being inlined becomes `{}`, and other references (remote
  URLs, other pointers, unknown names) stay as they are; nothing is fetched.
  Inlining is bounded: after 1,000 inlined references, further references
  become `{}` instead of growing the schema.

  `default`, `description`, `additionalProperties` and `type: "null"` are kept.
  `allOf` and other keywords pass through unchanged.

  Lemon's Kimi providers use the Anthropic Messages wire, which does not
  apply MFJS; this normalizer covers OpenAI Chat Completions models pointed at
  a Moonshot-native host (`native_host?/1`).
  """

  @native_hosts ["api.moonshot.ai", "api.moonshot.cn", "api.kimi.com", "api.kimi.ai"]

  @stripped ~w(format pattern minLength maxLength minimum maximum exclusiveMinimum
    exclusiveMaximum minItems maxItems uniqueItems multipleOf $schema examples title
    $comment if then else not unevaluatedProperties unevaluatedItems patternProperties
    propertyNames contains minContains maxContains dependentRequired dependentSchemas
    contentEncoding contentMediaType contentSchema deprecated readOnly writeOnly
    minProperties maxProperties $dynamicRef $dynamicAnchor prefixItems)

  @spilled ~w(pattern format minLength maxLength minimum maximum exclusiveMinimum
    exclusiveMaximum multipleOf minItems maxItems uniqueItems minProperties maxProperties
    examples)

  @schema_map_keys ~w(properties $defs definitions)
  @schema_value_keys ~w(items additionalItems)
  @schema_list_keys ~w(anyOf oneOf allOf)
  @ref_budget 1_000

  @doc "Whether `base_url` is a Moonshot-native host that validates MFJS."
  @spec native_host?(String.t() | nil) :: boolean()
  def native_host?(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host) in @native_hosts
      _ -> false
    end
  end

  def native_host?(_), do: false

  @doc "Normalize a tool parameter schema to MFJS."
  @spec normalize(term()) :: term()
  def normalize(schema), do: schema |> dereference() |> schema_node()

  # Inline local `$ref`s (omp `dereferenceJsonSchema`), only when the root
  # carries a definitions block. `budget` bounds the number of inlined refs.
  defp dereference(%{} = root)
       when is_map_key(root, "$defs") or is_map_key(root, "definitions") do
    {schema, _budget} = deref_node(root, root, %{}, @ref_budget)
    schema
  end

  defp dereference(schema), do: schema

  defp deref_node(list, root, visiting, budget) when is_list(list) do
    Enum.map_reduce(list, budget, &deref_node(&1, root, visiting, &2))
  end

  defp deref_node(%{"$ref" => ref} = node, root, visiting, budget) when is_binary(ref) do
    if is_map_key(visiting, ref) do
      {%{}, budget}
    else
      case local_ref(ref, root) do
        nil ->
          {node, budget}

        _definition when budget <= 0 ->
          {%{}, 0}

        definition ->
          {inlined, budget} =
            deref_node(definition, root, Map.put(visiting, ref, true), budget - 1)

          # Keywords beside `$ref` (description, default, ...) win, unprocessed.
          case Map.delete(node, "$ref") do
            siblings when siblings == %{} -> {inlined, budget}
            siblings -> {Map.merge(inlined, siblings), budget}
          end
      end
    end
  end

  defp deref_node(%{} = node, root, visiting, budget) do
    node
    |> Map.drop(["$defs", "definitions"])
    |> Enum.map_reduce(budget, fn {key, value}, budget ->
      {value, budget} = deref_node(value, root, visiting, budget)
      {{key, value}, budget}
    end)
    |> then(fn {pairs, budget} -> {Map.new(pairs), budget} end)
  end

  defp deref_node(value, _root, _visiting, budget), do: {value, budget}

  defp local_ref("#/$defs/" <> name, root), do: definition(root["$defs"], name)
  defp local_ref("#/definitions/" <> name, root), do: definition(root["definitions"], name)
  defp local_ref(_ref, _root), do: nil

  defp definition(%{} = defs, name) when name != "" do
    case defs[name] do
      %{} = schema -> schema
      _ -> nil
    end
  end

  defp definition(_defs, _name), do: nil

  defp schema_node(value) when is_boolean(value), do: %{}
  defp schema_node(value) when is_map(value), do: object_node(value)
  defp schema_node(value), do: value

  defp object_node(node) do
    case const_union(node) do
      {combiner, variants} ->
        node
        |> Map.delete(combiner)
        |> Map.delete("const")
        |> walk()
        |> Map.merge(const_union_enum(variants))
        |> finish()

      nil ->
        node
        |> walk()
        |> collapse_type_array()
        |> merge_const(node)
        |> infer_enum_type()
        |> finish()
    end
  end

  # Keywords are walked once: stripped keys are spilled, subschemas recursed.
  defp walk(node) do
    {result, spill} =
      Enum.reduce(node, {%{}, []}, fn {key, value}, {acc, spill} ->
        cond do
          key in @stripped ->
            {acc, if(key in @spilled, do: [{key, value} | spill], else: spill)}

          key in ["nullable", "const"] ->
            {acc, spill}

          key in @schema_map_keys and is_map(value) ->
            {Map.put(acc, key, Map.new(value, fn {name, sub} -> {name, schema_node(sub)} end)),
             spill}

          key in @schema_list_keys and is_list(value) ->
            {Map.put(acc, key, Enum.map(value, &schema_node/1)), spill}

          key in @schema_value_keys or (key == "additionalProperties" and is_map(value)) ->
            {Map.put(acc, key, schema_node(value)), spill}

          true ->
            {Map.put(acc, key, value), spill}
        end
      end)

    spill_description(result, Enum.reverse(spill))
  end

  defp const_union(node) do
    Enum.find_value(["anyOf", "oneOf"], fn combiner ->
      case Map.get(node, combiner) do
        [_ | _] = variants ->
          if Enum.all?(variants, &(is_map(&1) and Map.has_key?(&1, "const"))),
            do: {combiner, variants}

        _ ->
          nil
      end
    end)
  end

  defp const_union_enum(variants) do
    values = variants |> Enum.map(& &1["const"]) |> Enum.uniq()
    explicit = Enum.map(variants, & &1["type"])

    type =
      case Enum.uniq(explicit) do
        [type] when is_binary(type) -> type
        _ -> shared_type(values, true)
      end

    if type, do: %{"enum" => values, "type" => type}, else: %{"enum" => values}
  end

  defp collapse_type_array(%{"type" => types} = node) when is_list(types) do
    case Enum.filter(types, &is_binary/1) do
      [] -> Map.delete(node, "type")
      [first | _] = names -> Map.put(node, "type", Enum.find(names, first, &(&1 != "null")))
    end
  end

  defp collapse_type_array(node), do: node

  defp merge_const(node, %{"const" => value}) do
    enum = Enum.uniq(List.wrap(Map.get(node, "enum")) ++ [value])
    node = Map.put(node, "enum", enum)
    if Map.has_key?(node, "type"), do: node, else: put_type(node, json_type(value))
  end

  defp merge_const(node, _source), do: node

  defp infer_enum_type(%{"enum" => [_ | _] = values} = node)
       when not is_map_key(node, "type") and not is_map_key(node, "anyOf") and
              not is_map_key(node, "oneOf"),
       do: put_type(node, shared_type(values, false))

  defp infer_enum_type(node), do: node

  # The single JSON type of `values`; `allow_null?` lets `null` join one other type.
  defp shared_type(values, allow_null?) do
    types = values |> Enum.map(&json_type/1) |> Enum.uniq()

    case types do
      [type] -> type
      _ when allow_null? -> types |> List.delete("null") |> then(&if(length(&1) == 1, do: hd(&1)))
      _ -> nil
    end
  end

  defp put_type(node, nil), do: node
  defp put_type(node, type), do: Map.put(node, "type", type)

  defp finish(node), do: node |> fold_one_of() |> drop_non_scalar_enum()

  defp fold_one_of(%{"oneOf" => one_of} = node) when is_list(one_of) do
    node
    |> Map.delete("oneOf")
    |> Map.update("anyOf", one_of, &(List.wrap(&1) ++ one_of))
  end

  defp fold_one_of(node), do: node

  defp drop_non_scalar_enum(%{"enum" => values} = node) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) or is_number(&1))),
      do: node,
      else: Map.delete(node, "enum")
  end

  defp drop_non_scalar_enum(node), do: node

  defp spill_description(node, []), do: node

  defp spill_description(node, entries) do
    spilled =
      "{" <>
        Enum.map_join(entries, ", ", fn {key, value} -> "#{key}: #{Jason.encode!(value)}" end) <>
        "}"

    case Map.get(node, "description") do
      existing when is_binary(existing) and existing != "" ->
        Map.put(node, "description", existing <> "\n\n" <> spilled)

      _ ->
        Map.put(node, "description", spilled)
    end
  end

  defp json_type(nil), do: "null"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(value) when is_number(value), do: "number"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_map(value), do: "object"
  defp json_type(_), do: nil
end
