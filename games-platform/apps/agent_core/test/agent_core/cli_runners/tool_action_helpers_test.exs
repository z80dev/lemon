defmodule AgentCore.CliRunners.ToolActionHelpersTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.ToolActionHelpers

  test "normalize_tool_result extracts text from AgentToolResult" do
    result = %AgentCore.Types.AgentToolResult{
      content: [%Ai.Types.TextContent{type: :text, text: "hello"}],
      details: nil
    }

    assert ToolActionHelpers.normalize_tool_result(result) == "hello"
  end

  test "normalize_tool_result extracts text from list of TextContent and strings" do
    content = [
      %Ai.Types.TextContent{type: :text, text: "a"},
      "b",
      %{"text" => "c"}
    ]

    assert ToolActionHelpers.normalize_tool_result(content) == "a\nb\nc"
  end

  test "normalize_tool_result extracts nested content from maps" do
    payload = %{
      content: [
        %Ai.Types.TextContent{type: :text, text: "nested"}
      ]
    }

    assert ToolActionHelpers.normalize_tool_result(payload) == "nested"
  end
end
