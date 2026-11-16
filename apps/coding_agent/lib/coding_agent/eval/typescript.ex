defmodule CodingAgent.Eval.TypeScript do
  @moduledoc """
  Deterministic TypeScript declarations for a frozen, wrapped AgentTool catalog.

  `render/1` accepts a list of tools or a name-to-tool map and returns a binary.
  Tool and property names are sorted and JSON-quoted, never interpolated as code.
  Unsupported schemas and references render as `unknown`; declarations do not
  replace runtime argument validation. Bash streams may be combined by a backend;
  in that case both streams are null (unavailable, not empty), `output` is the
  combined capture and `output_combined` is true.
  """

  alias LemonAgent.Types.AgentTool

  @spec render([AgentTool.t()] | map()) :: binary()
  def render(tools) do
    tools = if is_map(tools), do: Map.values(tools), else: tools

    declarations =
      tools
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", fn tool ->
        result_type = if tool.name == "bash", do: "BashResult", else: "ToolResult"

        "  #{quote_name(tool.name)}: (args: #{schema(tool.parameters)}) => Promise<#{result_type}>;"
      end)

    """
    interface ToolResult {
      ok: boolean;
      text: string;
      details: unknown;
      images: Array<{ mimeType: string; data: string }>;
      stdout?: string | null;
      stderr?: string | null;
      exit_code?: number | null;
      output_combined?: boolean;
    }
    interface BashResult extends ToolResult {
      stdout?: string | null;
      stderr?: string | null;
      output?: string;
      exit_code?: number | null;
      output_combined?: boolean;
    }
    declare const tools: {
    #{declarations}
    };
    """
  end

  defp schema(true), do: "unknown"
  defp schema(false), do: "never"
  defp schema(s) when not is_map(s), do: "unknown"

  defp schema(s) do
    cond do
      Map.has_key?(s, "$ref") -> "unknown"
      Map.has_key?(s, "const") -> literal(s["const"])
      is_list(s["enum"]) -> join(Enum.map(s["enum"], &literal/1), " | ", "never")
      is_list(s["anyOf"]) -> variants(s["anyOf"], " | ", "never")
      is_list(s["oneOf"]) -> variants(s["oneOf"], " | ", "never")
      is_list(s["allOf"]) -> variants(s["allOf"], " & ", "unknown")
      is_list(s["type"]) -> variants(Enum.map(s["type"], &Map.put(s, "type", &1)), " | ", "never")
      true -> typed(s["type"], s)
    end
  end

  defp typed("string", _), do: "string"
  defp typed(type, _) when type in ["integer", "number"], do: "number"
  defp typed("boolean", _), do: "boolean"
  defp typed("null", _), do: "null"
  defp typed("array", s), do: "Array<#{schema(s["items"])}>"

  defp typed(type, s) when type == "object" or is_map_key(s, "properties") do
    properties = if is_map(s["properties"]), do: s["properties"], else: %{}
    required = if is_list(s["required"]), do: s["required"], else: []

    fields =
      properties
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join(" ", fn {name, value} ->
        optional = if name in required, do: "", else: "?"
        "#{quote_name(name)}#{optional}: #{schema(value)};"
      end)

    object = "{ #{fields} }"

    case s["additionalProperties"] do
      false -> object
      extra when is_map(extra) and map_size(properties) == 0 -> "Record<string, #{schema(extra)}>"
      _ when map_size(properties) == 0 -> "Record<string, unknown>"
      _ -> object
    end
  end

  defp typed(_, _), do: "unknown"

  defp variants(values, separator, empty),
    do: "(" <> join(Enum.map(values, &schema/1), separator, empty) <> ")"

  defp join(values, separator, empty) do
    case Enum.sort(Enum.uniq(values)) do
      [] -> empty
      values -> Enum.join(values, separator)
    end
  end

  defp literal(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: Jason.encode!(value)

  defp literal(_), do: "unknown"
  defp quote_name(name), do: Jason.encode!(name)
end
