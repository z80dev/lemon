defmodule CodingAgent.Wasm.ToolFactory do
  @moduledoc """
  Builds `AgentTool` wrappers for discovered WASM tools.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.Wasm.SidecarSession

  @type tool_source :: {:wasm, map()}
  @type inventory_entry :: {String.t(), AgentTool.t(), tool_source()}

  @spec build_inventory(pid(), [map()], keyword()) :: [inventory_entry()]
  def build_inventory(sidecar_pid, discovered_tools, opts \\ []) when is_pid(sidecar_pid) do
    cwd = Keyword.get(opts, :cwd, ".")
    session_id = Keyword.get(opts, :session_id, "")

    Enum.map(discovered_tools, fn tool ->
      name = tool.name
      description = tool.description
      schema = decode_schema(tool.schema_json)

      metadata = %{
        path: tool.path,
        warnings: tool.warnings,
        capabilities: tool.capabilities,
        source: :wasm
      }

      execute =
        build_execute_fun(sidecar_pid, name,
          context_json: Jason.encode!(%{cwd: cwd, session_id: session_id}),
          metadata: metadata
        )

      agent_tool = %AgentTool{
        name: name,
        description: description,
        parameters: schema,
        label: "WASM: #{name}",
        execute: execute
      }

      {name, agent_tool, {:wasm, metadata}}
    end)
  end

  defp build_execute_fun(sidecar_pid, name, opts) do
    context_json = Keyword.fetch!(opts, :context_json)
    metadata = Keyword.fetch!(opts, :metadata)

    fn _tool_call_id, params, _signal, _on_update ->
      params_json = Jason.encode!(params || %{})

      case SidecarSession.invoke(sidecar_pid, name, params_json, context_json) do
        {:ok, invoke_result} ->
          build_success_result(name, invoke_result, metadata)

        {:error, reason} ->
          %AgentToolResult{
            content: [
              %TextContent{
                text: "WASM tool '#{name}' failed: #{inspect(reason)}"
              }
            ],
            details: %{reason: reason, wasm: metadata},
            trust: :untrusted
          }
      end
    end
  end

  defp build_success_result(name, invoke_result, metadata) do
    text =
      cond do
        is_binary(invoke_result.error) and invoke_result.error != "" ->
          "WASM tool '#{name}' returned an error: #{invoke_result.error}"

        is_binary(invoke_result.output_json) ->
          output_json_to_text(invoke_result.output_json)

        true ->
          "null"
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        wasm: metadata,
        invoke: invoke_result
      },
      trust: :untrusted
    }
  end

  defp decode_schema(schema_json) when is_binary(schema_json) do
    case Jason.decode(schema_json) do
      {:ok, schema} when is_map(schema) -> schema
      _ -> %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end

  defp decode_schema(_), do: %{"type" => "object", "properties" => %{}, "required" => []}

  defp output_json_to_text(raw_json) do
    case Jason.decode(raw_json) do
      {:ok, value} when is_binary(value) -> value
      {:ok, value} -> Jason.encode!(value)
      {:error, _} -> raw_json
    end
  end
end
