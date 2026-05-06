defmodule AgentCore.Loop.TranscriptValidatorTest do
  use ExUnit.Case, async: true

  alias AgentCore.Loop.TranscriptValidator
  alias Ai.Types.{AssistantMessage, TextContent, ToolCall, ToolResultMessage, UserMessage}

  defp assistant_tool_call(id) do
    %AssistantMessage{
      role: :assistant,
      content: [%ToolCall{id: id, name: "read", arguments: %{"path" => "README.md"}}]
    }
  end

  defp assistant_text(text) do
    %AssistantMessage{role: :assistant, content: [%TextContent{text: text}]}
  end

  defp tool_result(id) do
    %ToolResultMessage{tool_call_id: id, tool_name: "read", content: [%TextContent{text: "ok"}]}
  end

  defp user(text) do
    %UserMessage{role: :user, content: text}
  end

  test "accepts assistant tool calls followed by exactly matching tool results" do
    messages = [
      user("read the file"),
      assistant_tool_call("call_1"),
      tool_result("call_1"),
      assistant_text("done")
    ]

    assert TranscriptValidator.validate(messages) == :ok
  end

  test "rejects missing tool results before the next provider turn" do
    messages = [
      user("read the file"),
      assistant_tool_call("call_1"),
      user("also check tests")
    ]

    assert {:error, {:invalid_tool_transcript, [violation]}} =
             TranscriptValidator.validate(messages)

    assert violation.type == :missing_tool_result
    assert violation.tool_call_ids == ["call_1"]
  end

  test "rejects duplicate tool results for one tool call" do
    messages = [
      assistant_tool_call("call_1"),
      tool_result("call_1"),
      tool_result("call_1")
    ]

    assert {:error, {:invalid_tool_transcript, violations}} =
             TranscriptValidator.validate(messages)

    assert Enum.any?(violations, &(&1.type == :duplicate_tool_result))
  end

  test "rejects unexpected tool results" do
    messages = [
      assistant_tool_call("call_1"),
      tool_result("call_other")
    ]

    assert {:error, {:invalid_tool_transcript, violations}} =
             TranscriptValidator.validate(messages)

    assert Enum.any?(violations, &(&1.type == :unexpected_tool_result))
  end

  test "rejects orphan tool results" do
    assert {:error, {:invalid_tool_transcript, [violation]}} =
             TranscriptValidator.validate([tool_result("call_1")])

    assert violation.type == :orphan_tool_result
  end
end
