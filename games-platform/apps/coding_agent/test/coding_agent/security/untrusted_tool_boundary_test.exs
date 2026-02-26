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

  test "wraps untrusted string trust value" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_str",
      tool_name: "webfetch",
      trust: "untrusted",
      content: [%TextContent{type: :text, text: "string trust payload"}],
      is_error: false,
      timestamp: 10
    }

    assert {:ok, [wrapped]} = UntrustedToolBoundary.transform([message], nil)

    [content] = wrapped.content
    assert content.text =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert content.text =~ "string trust payload"
  end

  test "handles empty content list" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_empty",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [],
      is_error: false,
      timestamp: 20
    }

    assert {:ok, [result]} = UntrustedToolBoundary.transform([message], nil)
    assert result.content == []
  end

  test "handles nil content" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_nil",
      tool_name: "webfetch",
      trust: :untrusted,
      content: nil,
      is_error: false,
      timestamp: 30
    }

    assert {:ok, [result]} = UntrustedToolBoundary.transform([message], nil)
    assert result.content == []
  end

  test "handles map-style text content blocks with string keys" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_map_str",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [%{"type" => "text", "text" => "string-key payload"}],
      is_error: false,
      timestamp: 40
    }

    assert {:ok, [wrapped]} = UntrustedToolBoundary.transform([message], nil)

    [content] = wrapped.content
    assert content["text"] =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert content["text"] =~ "string-key payload"
  end

  test "handles atom-style text content blocks (plain map)" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_map_atom",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [%{type: :text, text: "atom-key payload"}],
      is_error: false,
      timestamp: 50
    }

    assert {:ok, [wrapped]} = UntrustedToolBoundary.transform([message], nil)

    [content] = wrapped.content
    assert content.text =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert content.text =~ "atom-key payload"
  end

  test "skips non-text content blocks" do
    image_block = %{type: :image, data: "base64data"}
    text_block = %TextContent{type: :text, text: "some text"}

    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_mixed_types",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [image_block, text_block],
      is_error: false,
      timestamp: 60
    }

    assert {:ok, [wrapped]} = UntrustedToolBoundary.transform([message], nil)

    [image_result, text_result] = wrapped.content
    # image block passes through unchanged
    assert image_result == image_block
    # text block gets wrapped
    assert text_result.text =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert text_result.text =~ "some text"
  end

  test "handles mixed message list: only untrusted messages are wrapped" do
    untrusted = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_untrusted",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [%TextContent{type: :text, text: "untrusted data"}],
      is_error: false,
      timestamp: 70
    }

    trusted = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_trusted",
      tool_name: "local_tool",
      trust: :trusted,
      content: [%TextContent{type: :text, text: "trusted data"}],
      is_error: false,
      timestamp: 71
    }

    user = %UserMessage{role: :user, content: "hello", timestamp: 72}

    assert {:ok, [untrusted_after, trusted_after, user_after]} =
             UntrustedToolBoundary.transform([untrusted, trusted, user], nil)

    # untrusted message is wrapped
    [untrusted_content] = untrusted_after.content
    assert untrusted_content.text =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert untrusted_content.text =~ "untrusted data"

    # trusted message is unchanged
    assert trusted_after == trusted

    # user message is unchanged
    assert user_after == user
  end

  test "transform with empty list returns {:ok, []}" do
    assert {:ok, []} = UntrustedToolBoundary.transform([], nil)
  end

  test "wraps multiple content blocks in a single message" do
    message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_multi",
      tool_name: "webfetch",
      trust: :untrusted,
      content: [
        %TextContent{type: :text, text: "first block"},
        %TextContent{type: :text, text: "second block"},
        %TextContent{type: :text, text: "third block"}
      ],
      is_error: false,
      timestamp: 80
    }

    assert {:ok, [wrapped]} = UntrustedToolBoundary.transform([message], nil)

    assert length(wrapped.content) == 3

    Enum.each(wrapped.content, fn content ->
      assert content.text =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    end)

    [first, second, third] = wrapped.content
    assert first.text =~ "first block"
    assert second.text =~ "second block"
    assert third.text =~ "third block"
  end
end
