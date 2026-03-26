defmodule LemonSim.Examples.Poker.ToolPolicy do
  @moduledoc false

  @behaviour LemonSim.Deciders.ToolLoopPolicy

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.ToolCall

  @impl true
  def validate_tool_calls(resolved_tool_calls, opts)
      when is_list(resolved_tool_calls) and is_list(opts) do
    decision_calls =
      Enum.filter(resolved_tool_calls, fn %{tool: tool} ->
        not support_tool?(tool, opts)
      end)

    case decision_calls do
      [] ->
        :ok

      [decision_call] ->
        if last_tool_call?(resolved_tool_calls, decision_call) do
          :ok
        else
          {:error, {:decision_tool_must_be_last, decision_call.tool.name}}
        end

      _ ->
        {:error,
         {:multiple_decision_tools, Enum.map(decision_calls, fn %{tool: tool} -> tool.name end)}}
    end
  end

  @impl true
  def decision_from_call(
        %ToolCall{} = tool_call,
        %AgentTool{} = tool,
        %AgentToolResult{} = result,
        opts
      ) do
    if support_tool?(tool, opts) do
      nil
    else
      %{
        "type" => "tool_call",
        "tool_name" => tool_call.name,
        "tool_call_id" => tool_call.id,
        "arguments" => tool_call.arguments || %{},
        "result_text" => AgentCore.get_text(result),
        "result_details" => result.details
      }
    end
  end

  defp last_tool_call?(resolved_tool_calls, %{tool_call: %ToolCall{id: id}}) do
    case List.last(resolved_tool_calls) do
      %{tool_call: %ToolCall{id: ^id}} -> true
      _ -> false
    end
  end

  defp support_tool?(%AgentTool{} = tool, opts) do
    case Keyword.get(opts, :support_tool_matcher) do
      matcher when is_function(matcher, 1) -> matcher.(tool)
      _ -> false
    end
  end
end
