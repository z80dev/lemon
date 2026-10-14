defmodule LemonSkills.McpDiscovery do
  @moduledoc """
  Destination-local, temporary discovery of a profile HTTP MCP server.

  Uses the profile definition validator and owner-bound MCP session services.
  Header secret references resolve only on this host through the encrypted store.
  The invoking process owns the random session; all clients are released on
  completion, failure or owner death. Results contain no connection definitions.
  `name` is the exact raw remote selector; `executionName` is the stable native
  policy/runtime alias for this public server endpoint and raw name. Aliases
  include URL path/query identity but never headers, credentials or DNS pins.
  `readOnly` is advisory metadata, true only for explicit boolean `readOnlyHint:
  true`; it cannot grant execution or weaken native tool-policy requirements.

  Inventories are limited to 256 tools, 128-byte names, 4096-byte descriptions,
  32-KiB complete input schemas, and a 1-MiB encoded response. Schemas have at
  most 24 JSON nesting levels; aggregate JSON items are bounded to 131,072 with
  room reserved for transport envelopes. Invalid or oversized schemas/tools are
  skipped with `truncated: true`, never truncated or modified. Credential-bearing
  raw names/schemas are skipped; credential-bearing server labels fail closed.
  Descriptions are scrubbed before truncation or projection.
  """

  alias LemonCore.{JSONPayload, ProfileStore, Redact}
  alias LemonSkills.{McpSession, McpSource}

  @max_tools 256
  @max_schema 32_768
  @max_result 1_048_576
  @max_items 131_072
  @max_schema_depth 24

  @spec discover(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def discover(server, cwd) do
    with {:ok, [server]} <- ProfileStore.normalize_mcp_servers([server]) do
      id = "mcp-discovery-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      try do
        # Discovery reads the raw inventory but never installs executable tools.
        with :ok <- McpSession.open_http(id, cwd, [Map.put(server, "enabledTools", [])], self()),
             {:ok, tools} <- McpSession.remote_tools(id) do
          {:ok, project(server, tools)}
        end
      after
        McpSession.close(id)
      end
    else
      _ -> {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :discovery_failed}
  catch
    _, _ -> {:error, :discovery_failed}
  end

  defp project(server, inventory) do
    base = %{
      "connected" => true,
      "server" => %{"name" => Redact.text(server["name"], drop_keys: true), "status" => "connected"},
      "tools" => [],
      "count" => 0,
      "truncated" => false
    }

    # Reserve conservative envelope/count overhead. Descriptor statistics include
    # executionName, schema contents and every other field sent over the wire.
    {:ok, base_stats} = JSONPayload.validate(base, max_bytes: @max_result, max_items: @max_items)
    budget = @max_result - base_stats.bytes - 32
    item_budget = @max_items - base_stats.item_count - 32

    {tools, _bytes, _items, _names, truncated} =
      Enum.reduce(inventory, {[], 0, 0, MapSet.new(), false},
        fn raw, {tools, bytes, items, names, truncated} = acc ->
          case project_tool(raw) do
            {:ok, tool, shortened} ->
              tool = Map.put(tool, "executionName",
                McpSource.execution_name(server["name"], server["url"], tool["name"]))

              case JSONPayload.validate(tool, max_bytes: budget, max_items: item_budget,
                     max_depth: @max_schema_depth + 1) do
                {:ok, stats} ->
                  size = stats.bytes + 1

                  if length(tools) < @max_tools and bytes + size <= budget and
                       items + stats.item_count <= item_budget and
                       not MapSet.member?(names, tool["name"]) do
                    {[tool | tools], bytes + size, items + stats.item_count,
                     MapSet.put(names, tool["name"]), truncated or shortened}
                  else
                    put_elem(acc, 4, true)
                  end

                {:error, _} ->
                  put_elem(acc, 4, true)
              end

            :skip ->
              put_elem(acc, 4, true)
          end
        end)

    tools = Enum.reverse(tools)
    %{base | "tools" => tools, "count" => length(tools), "truncated" => truncated}
  end

  defp project_tool(%{"name" => name, "description" => description, "inputSchema" => schema} = tool) do
    with true <- McpSource.valid_remote_name?(name),
         true <- valid_text?(description),
         true <- valid_schema?(schema),
         {:ok, json} <- Jason.encode(schema),
         true <- byte_size(json) <= @max_schema do
      shortened = byte_size(description) > 4096
      description = bounded_text(description, 4096)

      {:ok,
       %{
         "name" => name,
         "description" => description,
         "inputSchema" => schema,
         "readOnly" => get_in(tool, ["annotations", "readOnlyHint"]) === true
       }, shortened}
    else
      _ -> :skip
    end
  end

  defp project_tool(_), do: :skip

  defp valid_text?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  # MCP requires an object input schema; validate its JSON shape without inventing
  # a partial schema repair or evaluating untrusted external schema references.
  defp valid_schema?(%{"type" => "object"} = schema),
    do: json_value?(schema, 0) and schema_shape?(schema)

  defp valid_schema?(_), do: false

  defp schema_shape?(value) when is_boolean(value), do: true

  defp schema_shape?(value) when is_map(value) do
    Enum.all?(value, fn
      {"type", type} when is_binary(type) ->
        type in ["null", "boolean", "object", "array", "number", "integer", "string"]

      {"type", types} when is_list(types) ->
        types != [] and Enum.uniq(types) == types and
          Enum.all?(types, &(is_binary(&1) and schema_shape?(%{"type" => &1})))

      {"type", _} ->
        false

      {key, schemas} when key in ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"] ->
        is_map(schemas) and Enum.all?(schemas, fn {_name, schema} -> schema_shape?(schema) end)

      {key, schemas} when key in ["allOf", "anyOf", "oneOf", "prefixItems"] ->
        is_list(schemas) and schemas != [] and Enum.all?(schemas, &schema_shape?/1)

      {key, schema} when key in ["additionalProperties", "unevaluatedProperties", "propertyNames",
                                "contains", "additionalItems", "unevaluatedItems", "not", "if", "then", "else"] ->
        schema_shape?(schema)

      {"items", schemas} when is_list(schemas) ->
        Enum.all?(schemas, &schema_shape?/1)

      {"items", schema} ->
        schema_shape?(schema)

      {"required", names} ->
        is_list(names) and Enum.all?(names, &valid_text?/1) and Enum.uniq(names) == names

      {"enum", values} ->
        is_list(values) and values != [] and Enum.uniq(values) == values

      {key, number} when key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] ->
        is_number(number)

      {"multipleOf", number} ->
        is_number(number) and number > 0

      {key, count} when key in ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties", "minContains", "maxContains"] ->
        is_integer(count) and count >= 0

      {"uniqueItems", value} ->
        is_boolean(value)

      {key, text} when key in ["$ref", "$id", "$schema", "$anchor", "$dynamicRef", "$dynamicAnchor", "pattern", "format", "title", "description"] ->
        valid_text?(text)

      _ ->
        true
    end)
  end

  defp schema_shape?(_), do: false

  defp json_value?(_value, depth) when depth > @max_schema_depth, do: false
  defp json_value?(value, _depth) when is_binary(value), do: valid_text?(value)
  defp json_value?(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json_value?(value, depth) when is_list(value), do: Enum.all?(value, &json_value?(&1, depth + 1))

  defp json_value?(value, depth) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> valid_text?(key) and json_value?(nested, depth + 1) end)

  defp json_value?(_, _), do: false

  defp bounded_text(value, max) when byte_size(value) <= max, do: value

  defp bounded_text(value, max) do
    prefix = binary_part(value, 0, max)
    if String.valid?(prefix), do: prefix, else: bounded_text(prefix, max - 1)
  end
end
