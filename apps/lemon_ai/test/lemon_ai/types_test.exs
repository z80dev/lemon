defmodule LemonAi.TypesTest do
  @moduledoc """
  Tests for context message accumulation and ordering.
  """
  use ExUnit.Case, async: true

  alias LemonAi.Types.{AssistantMessage, Context, TextContent, ToolResultMessage, UserMessage}

  describe "Context.add_user_message/2" do
    test "appends user message to context" do
      ctx = Context.new() |> Context.add_user_message("Hello")
      assert length(ctx.messages) == 1
      assert %UserMessage{content: "Hello"} = hd(ctx.messages)
    end

    test "preserves existing messages (in chronological order)" do
      ctx =
        Context.new()
        |> Context.add_user_message("First")
        |> Context.add_user_message("Second")

      messages = ctx.messages
      assert length(messages) == 2
      assert %UserMessage{content: "First"} = Enum.at(messages, 0)
      assert %UserMessage{content: "Second"} = Enum.at(messages, 1)
    end

    test "sets timestamp" do
      ctx = Context.new() |> Context.add_user_message("Hello")
      msg = hd(ctx.messages)
      assert msg.timestamp > 0
    end
  end

  describe "Context.add_assistant_message/2" do
    test "appends assistant message to context" do
      user = %UserMessage{content: "First"}
      assistant = %AssistantMessage{content: [%TextContent{text: "I can help"}]}

      ctx = Context.new(messages: [user]) |> Context.add_assistant_message(assistant)
      assert ctx.messages == [user, assistant]
    end
  end

  describe "Context.add_tool_result/2" do
    test "appends tool result to context" do
      result = %ToolResultMessage{
        tool_call_id: "tc1",
        tool_name: "read",
        content: [%TextContent{text: "file contents"}]
      }

      user = %UserMessage{content: "First"}
      assistant = %AssistantMessage{content: [%TextContent{text: "Checking"}]}

      ctx = Context.new(messages: [user, assistant]) |> Context.add_tool_result(result)
      assert ctx.messages == [user, assistant, result]
    end
  end
end
