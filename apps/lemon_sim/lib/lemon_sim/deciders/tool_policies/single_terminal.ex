defmodule LemonSim.Deciders.ToolPolicies.SingleTerminal do
  @moduledoc """
  Default tool-loop policy.

  The policy allows any number of support tools but enforces that at most one
  decision tool appears in an assistant response, and that if present it must be
  the last tool call in the batch.
  """

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
      decision = %{
        "type" => "tool_call",
        "tool_name" => tool_call.name,
        "tool_call_id" => tool_call.id,
        "arguments" => tool_call.arguments || %{},
        "result_text" => AgentCore.get_text(result),
        "result_details" => result.details
      }

      case decision_events(result.details) do
        nil -> decision
        events -> Map.put(decision, "events", events)
      end
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

  defp decision_events(details) when is_map(details) do
    cond do
      is_list(fetch(details, :events, "events", nil)) ->
        fetch(details, :events, "events", [])

      not is_nil(fetch(details, :event, "event", nil)) ->
        [fetch(details, :event, "event", nil)]

      true ->
        nil
    end
  end

  defp decision_events(_details), do: nil

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end
end
