defmodule Ai.TypesTest do
  @moduledoc """
  Tests for Ai.Types – struct creation and Context functions.
  """
  use ExUnit.Case, async: true

  alias Ai.Types.{
    TextContent,
    ThinkingContent,
    ImageContent,
    ToolCall,
    UserMessage,
    AssistantMessage,
    ToolResultMessage,
    Cost,
    Usage,
    Tool,
    Context,
    ModelCost,
    Model,
    StreamOptions
  }

  # ============================================================================
  # Content Structs
  # ============================================================================

  describe "TextContent" do
    test "has expected defaults" do
      tc = %TextContent{}
      assert tc.type == :text
      assert tc.text == ""
      assert tc.text_signature == nil
    end

    test "can be created with values" do
      tc = %TextContent{text: "hello", text_signature: "sig123"}
      assert tc.text == "hello"
      assert tc.text_signature == "sig123"
    end
  end

  describe "ThinkingContent" do
    test "has expected defaults" do
      tc = %ThinkingContent{}
      assert tc.type == :thinking
      assert tc.thinking == ""
      assert tc.thinking_signature == nil
    end
  end

  describe "ImageContent" do
    test "has expected defaults" do
      ic = %ImageContent{}
      assert ic.type == :image
      assert ic.data == ""
      assert ic.mime_type == "image/png"
    end

    test "accepts custom mime_type" do
      ic = %ImageContent{data: "base64data", mime_type: "image/jpeg"}
      assert ic.mime_type == "image/jpeg"
    end
  end

  describe "ToolCall" do
    test "has expected defaults" do
      tc = %ToolCall{}
      assert tc.type == :tool_call
      assert tc.id == ""
      assert tc.name == ""
      assert tc.arguments == %{}
      assert tc.thought_signature == nil
    end

    test "can hold tool arguments" do
      tc = %ToolCall{
        id: "tc_1",
        name: "read",
        arguments: %{"path" => "/foo/bar.ex"}
      }

      assert tc.name == "read"
      assert tc.arguments["path"] == "/foo/bar.ex"
    end
  end

  # ============================================================================
  # Message Structs
  # ============================================================================

  describe "UserMessage" do
    test "has expected defaults" do
      msg = %UserMessage{}
      assert msg.role == :user
      assert msg.content == ""
      assert msg.timestamp == 0
    end

    test "content can be string or list" do
      msg_str = %UserMessage{content: "hello"}
      assert msg_str.content == "hello"

      msg_list = %UserMessage{
        content: [%TextContent{text: "hello"}]
      }

      assert [%TextContent{text: "hello"}] = msg_list.content
    end
  end

  describe "AssistantMessage" do
    test "has expected defaults" do
      msg = %AssistantMessage{}
      assert msg.role == :assistant
      assert msg.content == []
      assert msg.api == nil
      assert msg.provider == nil
      assert msg.model == ""
      assert msg.usage == nil
      assert msg.stop_reason == nil
      assert msg.error_message == nil
      assert msg.timestamp == 0
    end

    test "can hold content blocks" do
      msg = %AssistantMessage{
        content: [
          %TextContent{text: "I'll help you."},
          %ToolCall{id: "tc1", name: "read", arguments: %{"path" => "/foo"}}
        ],
        model: "claude-3.5-sonnet",
        stop_reason: :tool_use
      }

      assert length(msg.content) == 2
      assert msg.model == "claude-3.5-sonnet"
      assert msg.stop_reason == :tool_use
    end
  end

  describe "ToolResultMessage" do
    test "has expected defaults" do
      msg = %ToolResultMessage{}
      assert msg.role == :tool_result
      assert msg.tool_call_id == ""
      assert msg.tool_name == ""
      assert msg.content == []
      assert msg.details == nil
      assert msg.trust == :trusted
      assert msg.is_error == false
      assert msg.timestamp == 0
    end

    test "can represent an error result" do
      msg = %ToolResultMessage{
        tool_call_id: "tc1",
        tool_name: "bash",
        is_error: true,
        trust: :untrusted,
        content: [%TextContent{text: "command failed"}]
      }

      assert msg.is_error == true
      assert msg.trust == :untrusted
    end
  end

  # ============================================================================
  # Usage & Cost
  # ============================================================================

  describe "Cost" do
    test "has zero defaults" do
      cost = %Cost{}
      assert cost.input == 0.0
      assert cost.output == 0.0
      assert cost.cache_read == 0.0
      assert cost.cache_write == 0.0
      assert cost.total == 0.0
    end
  end

  describe "Usage" do
    test "has zero defaults" do
      usage = %Usage{}
      assert usage.input == 0
      assert usage.output == 0
      assert usage.cache_read == 0
      assert usage.cache_write == 0
      assert usage.total_tokens == 0
      assert usage.cost == %Cost{}
    end
  end

  # ============================================================================
  # Tool
  # ============================================================================

  describe "Tool" do
    test "has expected defaults" do
      tool = %Tool{}
      assert tool.name == ""
      assert tool.description == ""
      assert tool.parameters == %{}
    end

    test "can define a tool" do
      tool = %Tool{
        name: "read",
        description: "Read a file",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"}
          }
        }
      }

      assert tool.name == "read"
    end
  end

  # ============================================================================
  # Context
  # ============================================================================

  describe "Context.new/1" do
    test "creates empty context" do
      ctx = Context.new()
      assert ctx.system_prompt == nil
      assert ctx.messages == []
      assert ctx.tools == []
    end

    test "accepts system_prompt option" do
      ctx = Context.new(system_prompt: "You are helpful.")
      assert ctx.system_prompt == "You are helpful."
    end

    test "accepts messages option" do
      msg = %UserMessage{content: "hi"}
      ctx = Context.new(messages: [msg])
      assert length(ctx.messages) == 1
    end

    test "accepts tools option" do
      tool = %Tool{name: "bash", description: "Run command"}
      ctx = Context.new(tools: [tool])
      assert length(ctx.tools) == 1
    end
  end

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

      messages = Context.get_messages_chronological(ctx)
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
      assistant = %AssistantMessage{content: [%TextContent{text: "I can help"}]}

      ctx = Context.new() |> Context.add_assistant_message(assistant)
      assert length(ctx.messages) == 1
      assert %AssistantMessage{} = hd(ctx.messages)
    end
  end

  describe "Context.add_tool_result/2" do
    test "appends tool result to context" do
      result = %ToolResultMessage{
        tool_call_id: "tc1",
        tool_name: "read",
        content: [%TextContent{text: "file contents"}]
      }

      ctx = Context.new() |> Context.add_tool_result(result)
      assert length(ctx.messages) == 1
      assert %ToolResultMessage{tool_call_id: "tc1"} = hd(ctx.messages)
    end
  end

  # ============================================================================
  # Model & ModelCost
  # ============================================================================

  describe "ModelCost" do
    test "has zero defaults" do
      mc = %ModelCost{}
      assert mc.input == 0.0
      assert mc.output == 0.0
      assert mc.cache_read == 0.0
      assert mc.cache_write == 0.0
    end
  end

  describe "Model" do
    test "has expected defaults" do
      model = %Model{}
      assert model.id == ""
      assert model.name == ""
      assert model.api == nil
      assert model.provider == nil
      assert model.base_url == ""
      assert model.reasoning == false
      assert model.input == [:text]
      assert model.cost == %ModelCost{}
      assert model.context_window == 0
      assert model.max_tokens == 0
      assert model.headers == %{}
      assert model.compat == nil
    end

    test "can create a configured model" do
      model = %Model{
        id: "claude-3.5-sonnet",
        name: "Claude 3.5 Sonnet",
        api: :anthropic,
        provider: :anthropic,
        context_window: 200_000,
        max_tokens: 8192,
        reasoning: true
      }

      assert model.context_window == 200_000
      assert model.reasoning == true
    end
  end

  # ============================================================================
  # StreamOptions
  # ============================================================================

  describe "StreamOptions" do
    test "has expected defaults" do
      opts = %StreamOptions{}
      assert opts.temperature == nil
      assert opts.max_tokens == nil
      assert opts.api_key == nil
      assert opts.session_id == nil
      assert opts.headers == %{}
      assert opts.reasoning == nil
      assert opts.thinking_budgets == %{}
      assert opts.stream_timeout == 300_000
      assert opts.tool_choice == nil
      assert opts.project == nil
      assert opts.location == nil
      assert opts.access_token == nil
    end
  end
end
