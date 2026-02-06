defmodule AgentCore.TypesTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.{
    AgentToolResult,
    AgentTool,
    AgentContext,
    AgentState,
    AgentLoopConfig
  }

  alias Ai.Types.{TextContent, ImageContent, StreamOptions}

  # ============================================================================
  # AgentToolResult Tests
  # ============================================================================

  describe "AgentToolResult" do
    test "creates with default values" do
      result = %AgentToolResult{}

      assert result.content == []
      assert result.details == nil
    end

    test "creates with text content" do
      content = [%TextContent{type: :text, text: "Hello, world!"}]
      result = %AgentToolResult{content: content, details: %{foo: "bar"}}

      assert result.content == content
      assert result.details == %{foo: "bar"}
    end

    test "creates with mixed content types" do
      content = [
        %TextContent{type: :text, text: "Some text"},
        %ImageContent{type: :image, data: "base64data", mime_type: "image/png"}
      ]

      result = %AgentToolResult{content: content}

      assert length(result.content) == 2
      assert Enum.at(result.content, 0).type == :text
      assert Enum.at(result.content, 1).type == :image
    end
  end

  # ============================================================================
  # AgentTool Tests
  # ============================================================================

  describe "AgentTool" do
    test "creates with default values" do
      tool = %AgentTool{}

      assert tool.name == ""
      assert tool.description == ""
      assert tool.parameters == %{}
      assert tool.label == ""
      assert tool.execute == nil
    end

    test "creates with all fields" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      tool = %AgentTool{
        name: "test_tool",
        description: "A test tool",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string"}
          }
        },
        label: "Test Tool",
        execute: execute_fn
      }

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert tool.label == "Test Tool"
      assert is_function(tool.execute, 4)
    end

    test "execute function can be called" do
      execute_fn = fn _id, %{"text" => text}, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "Result: #{text}"}]
        }
      end

      tool = %AgentTool{
        name: "echo",
        execute: execute_fn
      }

      result = tool.execute.("call_123", %{"text" => "hello"}, nil, nil)

      assert %AgentToolResult{} = result
      assert [%TextContent{text: "Result: hello"}] = result.content
    end

    test "execute function can return {:ok, result}" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        {:ok, %AgentToolResult{content: [%TextContent{type: :text, text: "success"}]}}
      end

      tool = %AgentTool{execute: execute_fn}
      {:ok, result} = tool.execute.("call_123", %{}, nil, nil)

      assert %AgentToolResult{} = result
    end

    test "execute function can return {:error, reason}" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        {:error, "Something went wrong"}
      end

      tool = %AgentTool{execute: execute_fn}
      {:error, reason} = tool.execute.("call_123", %{}, nil, nil)

      assert reason == "Something went wrong"
    end
  end

  # ============================================================================
  # AgentContext Tests
  # ============================================================================

  describe "AgentContext" do
    test "new/0 creates empty context" do
      context = AgentContext.new()

      assert context.system_prompt == nil
      assert context.messages == []
      assert context.tools == []
    end

    test "new/1 with system_prompt option" do
      context = AgentContext.new(system_prompt: "You are a helpful assistant")

      assert context.system_prompt == "You are a helpful assistant"
      assert context.messages == []
      assert context.tools == []
    end

    test "new/1 with messages option" do
      messages = [
        %{role: :user, content: "Hello", timestamp: 123},
        %{role: :assistant, content: "Hi!", timestamp: 124}
      ]

      context = AgentContext.new(messages: messages)

      assert context.messages == messages
    end

    test "new/1 with tools option" do
      tools = [
        %AgentTool{name: "tool1"},
        %AgentTool{name: "tool2"}
      ]

      context = AgentContext.new(tools: tools)

      assert length(context.tools) == 2
      assert Enum.map(context.tools, & &1.name) == ["tool1", "tool2"]
    end

    test "new/1 with all options" do
      tools = [%AgentTool{name: "echo"}]
      messages = [%{role: :user, content: "Test", timestamp: 100}]

      context =
        AgentContext.new(
          system_prompt: "Test system prompt",
          messages: messages,
          tools: tools
        )

      assert context.system_prompt == "Test system prompt"
      assert context.messages == messages
      assert context.tools == tools
    end

    test "struct can be updated" do
      context = AgentContext.new(system_prompt: "Initial")

      updated = %{context | system_prompt: "Updated"}

      assert updated.system_prompt == "Updated"
    end

    test "messages can be appended" do
      context = AgentContext.new()

      new_message = %{role: :user, content: "New message", timestamp: 100}
      updated = %{context | messages: context.messages ++ [new_message]}

      assert length(updated.messages) == 1
      assert hd(updated.messages).content == "New message"
    end
  end

  # ============================================================================
  # AgentState Tests
  # ============================================================================

  describe "AgentState" do
    test "creates with default values" do
      state = %AgentState{}

      assert state.system_prompt == ""
      assert state.model == nil
      assert state.thinking_level == :off
      assert state.tools == []
      assert state.messages == []
      assert state.is_streaming == false
      assert state.stream_message == nil
      assert state.pending_tool_calls == MapSet.new()
      assert state.error == nil
    end

    test "thinking_level accepts valid values" do
      for level <- [:off, :minimal, :low, :medium, :high, :xhigh] do
        state = %AgentState{thinking_level: level}
        assert state.thinking_level == level
      end
    end

    test "pending_tool_calls can be modified with MapSet operations" do
      state = %AgentState{}

      # Add a tool call ID
      updated = %{state | pending_tool_calls: MapSet.put(state.pending_tool_calls, "call_1")}
      assert MapSet.member?(updated.pending_tool_calls, "call_1")

      # Add another
      updated2 = %{updated | pending_tool_calls: MapSet.put(updated.pending_tool_calls, "call_2")}
      assert MapSet.size(updated2.pending_tool_calls) == 2

      # Remove one
      updated3 = %{
        updated2
        | pending_tool_calls: MapSet.delete(updated2.pending_tool_calls, "call_1")
      }

      assert MapSet.size(updated3.pending_tool_calls) == 1
      assert MapSet.member?(updated3.pending_tool_calls, "call_2")
    end

    test "is_streaming tracks streaming state" do
      state = %AgentState{is_streaming: true}
      assert state.is_streaming == true

      state2 = %{state | is_streaming: false}
      assert state2.is_streaming == false
    end

    test "error can store error messages" do
      state = %AgentState{error: "Connection timeout"}
      assert state.error == "Connection timeout"
    end
  end

  # ============================================================================
  # AgentLoopConfig Tests
  # ============================================================================

  describe "AgentLoopConfig" do
    test "creates with default values" do
      config = %AgentLoopConfig{}

      assert config.model == nil
      assert config.convert_to_llm == nil
      assert config.transform_context == nil
      assert config.get_api_key == nil
      assert config.get_steering_messages == nil
      assert config.get_follow_up_messages == nil
      assert config.stream_options == %StreamOptions{}
      assert config.stream_fn == nil
    end

    test "requires model for meaningful use" do
      # model is required for the loop to work
      config = %AgentLoopConfig{model: nil}
      assert config.model == nil
    end

    test "convert_to_llm can be set to a function" do
      convert_fn = fn messages ->
        Enum.filter(messages, fn msg -> Map.get(msg, :role) in [:user, :assistant] end)
      end

      config = %AgentLoopConfig{convert_to_llm: convert_fn}

      assert is_function(config.convert_to_llm, 1)

      # Test the function works
      messages = [
        %{role: :user, content: "hi"},
        %{role: :system, content: "you are helpful"},
        %{role: :assistant, content: "hello"}
      ]

      result = config.convert_to_llm.(messages)
      assert length(result) == 2
    end

    test "transform_context can be set to a function" do
      transform_fn = fn messages, _signal ->
        # Simulate context window management
        Enum.take(messages, -10)
      end

      config = %AgentLoopConfig{transform_context: transform_fn}

      messages = for i <- 1..20, do: %{role: :user, content: "message #{i}"}
      result = config.transform_context.(messages, nil)

      assert length(result) == 10
    end

    test "get_api_key can dynamically resolve keys" do
      get_key_fn = fn provider ->
        case provider do
          "anthropic" -> "sk-anthropic-key"
          "openai" -> "sk-openai-key"
          _ -> nil
        end
      end

      config = %AgentLoopConfig{get_api_key: get_key_fn}

      assert config.get_api_key.("anthropic") == "sk-anthropic-key"
      assert config.get_api_key.("openai") == "sk-openai-key"
      assert config.get_api_key.("unknown") == nil
    end

    test "get_steering_messages returns messages for mid-run injection" do
      steering_queue = [:queue.new()]

      get_steering = fn ->
        case :queue.out(hd(steering_queue)) do
          {{:value, msg}, _} -> [msg]
          {:empty, _} -> []
        end
      end

      config = %AgentLoopConfig{get_steering_messages: get_steering}

      assert config.get_steering_messages.() == []
    end

    test "get_follow_up_messages returns messages after agent would stop" do
      follow_up_queue = [:queue.new()]

      get_follow_up = fn ->
        case :queue.out(hd(follow_up_queue)) do
          {{:value, msg}, _} -> [msg]
          {:empty, _} -> []
        end
      end

      config = %AgentLoopConfig{get_follow_up_messages: get_follow_up}

      assert config.get_follow_up_messages.() == []
    end

    test "stream_options can be customized" do
      options = %StreamOptions{
        temperature: 0.7,
        max_tokens: 2000,
        api_key: "test-key",
        session_id: "session-123"
      }

      config = %AgentLoopConfig{stream_options: options}

      assert config.stream_options.temperature == 0.7
      assert config.stream_options.max_tokens == 2000
      assert config.stream_options.api_key == "test-key"
      assert config.stream_options.session_id == "session-123"
    end

    test "stream_fn can be set to custom function" do
      custom_stream_fn = fn model, context, options ->
        # Custom implementation
        {:ok, %{model: model, context: context, options: options}}
      end

      config = %AgentLoopConfig{stream_fn: custom_stream_fn}

      assert is_function(config.stream_fn, 3)
    end
  end

  # ============================================================================
  # Agent Event Types Tests
  # ============================================================================

  describe "agent_event types" do
    test "agent lifecycle events" do
      # These are tuples, testing the documented structure
      agent_start = {:agent_start}
      assert agent_start == {:agent_start}

      agent_end = {:agent_end, []}
      assert elem(agent_end, 0) == :agent_end
      assert elem(agent_end, 1) == []
    end

    test "turn lifecycle events" do
      turn_start = {:turn_start}
      assert turn_start == {:turn_start}

      message = %{role: :assistant, content: "test"}
      tool_results = []
      turn_end = {:turn_end, message, tool_results}

      assert elem(turn_end, 0) == :turn_end
      assert elem(turn_end, 1) == message
      assert elem(turn_end, 2) == tool_results
    end

    test "message lifecycle events" do
      message = %{role: :user, content: "hello"}

      message_start = {:message_start, message}
      assert elem(message_start, 0) == :message_start
      assert elem(message_start, 1) == message

      message_end = {:message_end, message}
      assert elem(message_end, 0) == :message_end
      assert elem(message_end, 1) == message

      assistant_event = {:text_delta, 0, "chunk"}
      message_update = {:message_update, message, assistant_event}
      assert elem(message_update, 0) == :message_update
      assert elem(message_update, 2) == assistant_event
    end

    test "tool execution lifecycle events" do
      id = "call_123"
      name = "echo"
      args = %{"text" => "hello"}
      result = %AgentToolResult{content: [%TextContent{type: :text, text: "Echo: hello"}]}

      tool_start = {:tool_execution_start, id, name, args}
      assert elem(tool_start, 0) == :tool_execution_start
      assert elem(tool_start, 1) == id
      assert elem(tool_start, 2) == name
      assert elem(tool_start, 3) == args

      tool_update = {:tool_execution_update, id, name, args, result}
      assert elem(tool_update, 0) == :tool_execution_update
      assert elem(tool_update, 4) == result

      tool_end = {:tool_execution_end, id, name, result, false}
      assert elem(tool_end, 0) == :tool_execution_end
      assert elem(tool_end, 4) == false

      tool_end_error = {:tool_execution_end, id, name, result, true}
      assert elem(tool_end_error, 4) == true
    end

    test "error events include reason and partial_state" do
      error_event = {:error, :timeout, %{messages: []}}

      assert elem(error_event, 0) == :error
      assert elem(error_event, 1) == :timeout
      assert elem(error_event, 2) == %{messages: []}
    end
  end
end
