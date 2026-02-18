defmodule CodingAgent.Security.UntrustedToolBoundaryTest do
  use ExUnit.Case, async: true

  alias Ai.Types.{TextContent, ToolResultMessage, UserMessage}
  alias CodingAgent.Security.UntrustedToolBoundary

  test "wraps untrusted tool result text blocks once" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_1",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [%TextContent{type: :text, text: "raw untrusted payload"}],
      is_error: false,
      timestamp: 1
    }

    assert {:ok, [wrapped]} = UntrustedToolBoundary.transform([message], nil)

    [content] = wrapped.content
    assert content.text =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"

    assert {:ok, [wrapped_again]} = UntrustedToolBoundary.transform([wrapped], nil)

    [content_again] = wrapped_again.content

    assert content_again.text == content.text
  end

  test "does not change trusted tool results or other messages" do
    trusted = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_2",
      tool_name: "local_tool",
      trust: :trusted,
      content: [%TextContent{type: :text, text: "trusted output"}],
      is_error: false,
      timestamp: 2
    }

    user = %UserMessage{role: :user, content: "hello", timestamp: 3}

    assert {:ok, [trusted_after, user_after]} =
             UntrustedToolBoundary.transform([trusted, user], nil)

    assert trusted_after == trusted
    assert user_after == user
  end
end
