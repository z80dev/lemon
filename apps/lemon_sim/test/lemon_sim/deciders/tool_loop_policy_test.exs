defmodule LemonSim.Deciders.ToolLoopPolicyTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.ToolCall
  alias LemonSim.Deciders.ToolPolicies.SingleTerminal

  test "accepts support tools followed by one terminal decision tool" do
    resolved_calls = [
      %{tool_call: tool_call("tc-1", "memory_read_file"), tool: tool("memory_read_file")},
      %{tool_call: tool_call("tc-2", "attack"), tool: tool("attack")}
    ]

    assert :ok =
             SingleTerminal.validate_tool_calls(
               resolved_calls,
               support_tool_matcher: &support_tool?/1
             )
  end

  test "rejects batches with multiple decision tools" do
    resolved_calls = [
      %{tool_call: tool_call("tc-1", "attack"), tool: tool("attack")},
      %{tool_call: tool_call("tc-2", "defend"), tool: tool("defend")}
    ]

    assert {:error, {:multiple_decision_tools, ["attack", "defend"]}} =
             SingleTerminal.validate_tool_calls(resolved_calls, [])
  end

  test "rejects batches where the decision tool is not last" do
    resolved_calls = [
      %{tool_call: tool_call("tc-1", "attack"), tool: tool("attack")},
      %{tool_call: tool_call("tc-2", "memory_write_file"), tool: tool("memory_write_file")}
    ]

    assert {:error, {:decision_tool_must_be_last, "attack"}} =
             SingleTerminal.validate_tool_calls(
               resolved_calls,
               support_tool_matcher: &support_tool?/1
             )
  end

  test "returns nil for support tools and a decision map for terminal tools" do
    result =
      %AgentToolResult{
        content: [AgentCore.text_content("attack committed")],
        details: %{ok: true},
        trust: :trusted
      }

    assert nil ==
             SingleTerminal.decision_from_call(
               tool_call("tc-1", "memory_read_file"),
               tool("memory_read_file"),
               result,
               support_tool_matcher: &support_tool?/1
             )

    assert %{"tool_name" => "attack"} =
             SingleTerminal.decision_from_call(
               tool_call("tc-2", "attack"),
               tool("attack"),
               result,
               support_tool_matcher: &support_tool?/1
             )
  end

  defp tool(name) do
    %AgentTool{
      name: name,
      description: "#{name} tool",
      parameters: %{"type" => "object", "properties" => %{}},
      label: name,
      execute: fn _id, _params, _signal, _on_update -> %AgentToolResult{} end
    }
  end

  defp tool_call(id, name) do
    %ToolCall{type: :tool_call, id: id, name: name, arguments: %{}}
  end

  defp support_tool?(tool), do: String.starts_with?(tool.name, "memory_")
end
