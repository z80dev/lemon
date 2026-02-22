defmodule AgentCore.TypesPropertyTest do
  @moduledoc """
  Property-based tests for AgentCore.Types module.

  Tests invariants for:
  - Message type validation
  - Content block type validation
  - Tool call validation
  - Usage struct properties
  - Serialization/deserialization roundtrips
  - Type coercion
  - Edge cases with random input
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias AgentCore.Types.{
    AgentContext,
    AgentLoopConfig,
    AgentState,
    AgentTool,
    AgentToolResult
  }

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    ImageContent,
    Model,
    ModelCost,
    StreamOptions,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  # ============================================================================
  # Generators
  # ============================================================================

  # Basic string generators
  defp non_empty_string do
    string(:printable, min_length: 1, max_length: 100)
  end

  defp maybe_string do
    one_of([
      constant(nil),
      string(:printable, max_length: 100)
    ])
  end

  defp unicode_string do
    one_of([
      string(:ascii, max_length: 100),
      string(:printable, max_length: 100),
      map(list_of(utf8_char(), min_length: 1, max_length: 50), &Enum.join/1)
    ])
  end

  defp utf8_char do
    one_of([
      integer(?a..?z),
      integer(0x4E00..0x4FFF),
      integer(0x0400..0x04FF),
      member_of([0x1F600, 0x1F601, 0x1F602, 0x2764])
    ])
    |> map(fn codepoint -> <<codepoint::utf8>> end)
  end

  # Thinking level generator
  defp thinking_level do
    member_of([:off, :minimal, :low, :medium, :high, :xhigh])
  end

  # Stop reason generator
  defp stop_reason do
    member_of([:stop, :length, :tool_use, :error, :aborted])
  end

  # Role generator
  defp role do
    member_of([:user, :assistant, :tool_result])
  end

  # ============================================================================
  # Content Block Generators
  # ============================================================================

  defp text_content_gen do
    map(string(:printable, max_length: 200), fn text ->
      %TextContent{type: :text, text: text}
    end)
  end

  defp thinking_content_gen do
    map(string(:printable, max_length: 200), fn thinking ->
      %ThinkingContent{type: :thinking, thinking: thinking}
    end)
  end

  defp image_content_gen do
    map({string(:alphanumeric, min_length: 10, max_length: 100), mime_type_gen()}, fn {data, mime} ->
      %ImageContent{type: :image, data: data, mime_type: mime}
    end)
  end

  defp mime_type_gen do
    member_of(["image/png", "image/jpeg", "image/gif", "image/webp"])
  end

  defp tool_call_gen do
    map(
      {string(:alphanumeric, min_length: 5, max_length: 20),
       string(:alphanumeric, min_length: 1, max_length: 30), arguments_gen()},
      fn {id, name, args} ->
        %ToolCall{type: :tool_call, id: id, name: name, arguments: args}
      end
    )
  end

  defp arguments_gen do
    one_of([
      constant(%{}),
      map(
        {string(:alphanumeric, min_length: 1, max_length: 10),
         string(:printable, max_length: 50)},
        fn {k, v} -> %{k => v} end
      ),
      map(
        list_of(
          {string(:alphanumeric, min_length: 1, max_length: 10), simple_value()},
          min_length: 1,
          max_length: 5
        ),
        fn pairs -> Map.new(pairs) end
      )
    ])
  end

  defp simple_value do
    one_of([
      string(:printable, max_length: 50),
      integer(-1000..1000),
      boolean(),
      float(min: -1000.0, max: 1000.0)
    ])
  end

  defp content_block_gen do
    one_of([
      text_content_gen(),
      thinking_content_gen(),
      tool_call_gen()
    ])
  end

  # ============================================================================
  # Message Generators
  # ============================================================================

  defp user_message_gen do
    map({user_content_gen(), timestamp_gen()}, fn {content, ts} ->
      %UserMessage{role: :user, content: content, timestamp: ts}
    end)
  end

  defp user_content_gen do
    one_of([
      string(:printable, max_length: 500),
      list_of(one_of([text_content_gen(), image_content_gen()]), min_length: 1, max_length: 3)
    ])
  end

  defp assistant_message_gen do
    map(
      {list_of(content_block_gen(), max_length: 5), stop_reason(), timestamp_gen(), usage_gen()},
      fn {content, stop, ts, usage} ->
        %AssistantMessage{
          role: :assistant,
          content: content,
          api: :mock,
          provider: :mock_provider,
          model: "mock-model",
          usage: usage,
          stop_reason: stop,
          timestamp: ts
        }
      end
    )
  end

  defp tool_result_message_gen do
    map(
      {string(:alphanumeric, min_length: 5, max_length: 20),
       string(:alphanumeric, min_length: 1, max_length: 30),
       list_of(text_content_gen(), max_length: 3), boolean(), timestamp_gen()},
      fn {call_id, name, content, is_error, ts} ->
        %ToolResultMessage{
          role: :tool_result,
          tool_call_id: call_id,
          tool_name: name,
          content: content,
          is_error: is_error,
          timestamp: ts
        }
      end
    )
  end

  defp message_gen do
    one_of([
      user_message_gen(),
      assistant_message_gen(),
      tool_result_message_gen()
    ])
  end

  defp timestamp_gen do
    integer(0..9_999_999_999_999)
  end

  # ============================================================================
  # Usage and Cost Generators
  # ============================================================================

  defp cost_gen do
    map(
      {non_neg_float(), non_neg_float(), non_neg_float(), non_neg_float()},
      fn {input, output, cache_read, cache_write} ->
        total = input + output + cache_read + cache_write

        %Cost{
          input: input,
          output: output,
          cache_read: cache_read,
          cache_write: cache_write,
          total: total
        }
      end
    )
  end

  defp usage_gen do
    map(
      {non_negative_integer(), non_negative_integer(), non_negative_integer(),
       non_negative_integer(), cost_gen()},
      fn {input, output, cache_read, cache_write, cost} ->
        %Usage{
          input: input,
          output: output,
          cache_read: cache_read,
          cache_write: cache_write,
          total_tokens: input + output,
          cost: cost
        }
      end
    )
  end

  defp non_neg_float do
    float(min: 0.0, max: 100.0)
  end

  # ============================================================================
  # Model Generators
  # ============================================================================

  defp model_cost_gen do
    map(
      {non_neg_float(), non_neg_float(), non_neg_float(), non_neg_float()},
      fn {input, output, cache_read, cache_write} ->
        %ModelCost{
          input: input,
          output: output,
          cache_read: cache_read,
          cache_write: cache_write
        }
      end
    )
  end

  defp model_gen do
    map(
      {non_empty_string(), non_empty_string(), atom(:alphanumeric), atom(:alphanumeric),
       string(:printable, max_length: 100), boolean(), model_cost_gen(), non_negative_integer(),
       non_negative_integer()},
      fn {id, name, api, provider, base_url, reasoning, cost, context_window, max_tokens} ->
        %Model{
          id: id,
          name: name,
          api: api,
          provider: provider,
          base_url: base_url,
          reasoning: reasoning,
          input: [:text],
          cost: cost,
          context_window: context_window,
          max_tokens: max_tokens
        }
      end
    )
  end

  # ============================================================================
  # Tool Generators
  # ============================================================================

  defp tool_gen do
    map(
      {non_empty_string(), string(:printable, max_length: 200), json_schema_gen()},
      fn {name, desc, params} ->
        %Tool{name: name, description: desc, parameters: params}
      end
    )
  end

  defp agent_tool_gen do
    map(
      {non_empty_string(), string(:printable, max_length: 200), json_schema_gen(),
       non_empty_string()},
      fn {name, desc, params, label} ->
        %AgentTool{
          name: name,
          description: desc,
          parameters: params,
          label: label,
          execute: fn _id, _params, _signal, _on_update ->
            %AgentToolResult{content: [], details: nil}
          end
        }
      end
    )
  end

  defp json_schema_gen do
    one_of([
      constant(%{}),
      constant(%{"type" => "object", "properties" => %{}}),
      map(string(:alphanumeric, min_length: 1, max_length: 20), fn prop_name ->
        %{
          "type" => "object",
          "properties" => %{prop_name => %{"type" => "string"}},
          "required" => [prop_name]
        }
      end)
    ])
  end

  # ============================================================================
  # Context and State Generators
  # ============================================================================

  defp agent_context_gen do
    map(
      {maybe_string(), list_of(message_gen(), max_length: 10),
       list_of(agent_tool_gen(), max_length: 3)},
      fn {prompt, messages, tools} ->
        %AgentContext{system_prompt: prompt, messages: messages, tools: tools}
      end
    )
  end

  defp agent_state_gen do
    map(
      {string(:printable, max_length: 200), model_gen(), thinking_level(),
       list_of(message_gen(), max_length: 10), boolean()},
      fn {prompt, model, thinking, messages, is_streaming} ->
        %AgentState{
          system_prompt: prompt,
          model: model,
          thinking_level: thinking,
          tools: [],
          messages: messages,
          is_streaming: is_streaming,
          pending_tool_calls: MapSet.new()
        }
      end
    )
  end

  defp stream_options_gen do
    map(
      {one_of([constant(nil), float(min: 0.0, max: 2.0)]),
       one_of([constant(nil), integer(1..8192)]), one_of([constant(nil), thinking_level()])},
      fn {temp, max_tokens, reasoning} ->
        %StreamOptions{
          temperature: temp,
          max_tokens: max_tokens,
          reasoning: reasoning
        }
      end
    )
  end

  # ============================================================================
  # Message Type Validation Properties
  # ============================================================================

  describe "UserMessage validation properties" do
    property "UserMessage always has role :user" do
      check all(msg <- user_message_gen()) do
        assert msg.role == :user
      end
    end

    property "UserMessage content is string or list of content blocks" do
      check all(msg <- user_message_gen()) do
        assert is_binary(msg.content) or is_list(msg.content)
      end
    end

    property "UserMessage timestamp is non-negative integer" do
      check all(msg <- user_message_gen()) do
        assert is_integer(msg.timestamp)
        assert msg.timestamp >= 0
      end
    end

    property "UserMessage struct keys are preserved" do
      check all(msg <- user_message_gen()) do
        assert Map.has_key?(msg, :role)
        assert Map.has_key?(msg, :content)
        assert Map.has_key?(msg, :timestamp)
        assert %UserMessage{} = msg
      end
    end
  end

  describe "AssistantMessage validation properties" do
    property "AssistantMessage always has role :assistant" do
      check all(msg <- assistant_message_gen()) do
        assert msg.role == :assistant
      end
    end

    property "AssistantMessage content is always a list" do
      check all(msg <- assistant_message_gen()) do
        assert is_list(msg.content)
      end
    end

    property "AssistantMessage stop_reason is valid atom" do
      check all(msg <- assistant_message_gen()) do
        assert msg.stop_reason in [:stop, :length, :tool_use, :error, :aborted]
      end
    end

    property "AssistantMessage usage is Usage struct or nil" do
      check all(msg <- assistant_message_gen()) do
        assert is_nil(msg.usage) or match?(%Usage{}, msg.usage)
      end
    end

    property "AssistantMessage content blocks have valid types" do
      check all(msg <- assistant_message_gen()) do
        Enum.each(msg.content, fn block ->
          assert block.type in [:text, :thinking, :tool_call]
        end)
      end
    end
  end

  describe "ToolResultMessage validation properties" do
    property "ToolResultMessage always has role :tool_result" do
      check all(msg <- tool_result_message_gen()) do
        assert msg.role == :tool_result
      end
    end

    property "ToolResultMessage has required identifiers" do
      check all(msg <- tool_result_message_gen()) do
        assert is_binary(msg.tool_call_id)
        assert is_binary(msg.tool_name)
        assert String.length(msg.tool_call_id) > 0
        assert String.length(msg.tool_name) > 0
      end
    end

    property "ToolResultMessage is_error is boolean" do
      check all(msg <- tool_result_message_gen()) do
        assert is_boolean(msg.is_error)
      end
    end

    property "ToolResultMessage content is list of content blocks" do
      check all(msg <- tool_result_message_gen()) do
        assert is_list(msg.content)

        Enum.each(msg.content, fn block ->
          assert match?(%TextContent{}, block) or match?(%ImageContent{}, block)
        end)
      end
    end
  end

  # ============================================================================
  # Content Block Type Validation Properties
  # ============================================================================

  describe "TextContent validation properties" do
    property "TextContent has type :text" do
      check all(content <- text_content_gen()) do
        assert content.type == :text
      end
    end

    property "TextContent text is always a string" do
      check all(content <- text_content_gen()) do
        assert is_binary(content.text)
      end
    end

    property "TextContent signature is nil or string" do
      check all(content <- text_content_gen()) do
        assert is_nil(content.text_signature) or is_binary(content.text_signature)
      end
    end
  end

  describe "ThinkingContent validation properties" do
    property "ThinkingContent has type :thinking" do
      check all(content <- thinking_content_gen()) do
        assert content.type == :thinking
      end
    end

    property "ThinkingContent thinking is always a string" do
      check all(content <- thinking_content_gen()) do
        assert is_binary(content.thinking)
      end
    end
  end

  describe "ImageContent validation properties" do
    property "ImageContent has type :image" do
      check all(content <- image_content_gen()) do
        assert content.type == :image
      end
    end

    property "ImageContent data is always a string" do
      check all(content <- image_content_gen()) do
        assert is_binary(content.data)
      end
    end

    property "ImageContent mime_type is valid" do
      check all(content <- image_content_gen()) do
        assert content.mime_type in ["image/png", "image/jpeg", "image/gif", "image/webp"]
      end
    end
  end

  # ============================================================================
  # Tool Call Validation Properties
  # ============================================================================

  describe "ToolCall validation properties" do
    property "ToolCall has type :tool_call" do
      check all(tc <- tool_call_gen()) do
        assert tc.type == :tool_call
      end
    end

    property "ToolCall has non-empty id and name" do
      check all(tc <- tool_call_gen()) do
        assert is_binary(tc.id)
        assert is_binary(tc.name)
        assert String.length(tc.id) > 0
        assert String.length(tc.name) > 0
      end
    end

    property "ToolCall arguments is a map" do
      check all(tc <- tool_call_gen()) do
        assert is_map(tc.arguments)
      end
    end

    property "ToolCall arguments keys are strings" do
      check all(tc <- tool_call_gen()) do
        Enum.each(Map.keys(tc.arguments), fn key ->
          assert is_binary(key)
        end)
      end
    end
  end

  # ============================================================================
  # Usage Struct Properties
  # ============================================================================

  describe "Usage struct properties" do
    property "Usage token counts are non-negative integers" do
      check all(usage <- usage_gen()) do
        assert is_integer(usage.input) and usage.input >= 0
        assert is_integer(usage.output) and usage.output >= 0
        assert is_integer(usage.cache_read) and usage.cache_read >= 0
        assert is_integer(usage.cache_write) and usage.cache_write >= 0
        assert is_integer(usage.total_tokens) and usage.total_tokens >= 0
      end
    end

    property "Usage total_tokens equals input + output" do
      check all(usage <- usage_gen()) do
        assert usage.total_tokens == usage.input + usage.output
      end
    end

    property "Usage cost is a Cost struct" do
      check all(usage <- usage_gen()) do
        assert %Cost{} = usage.cost
      end
    end

    property "Usage cost values are non-negative floats" do
      check all(usage <- usage_gen()) do
        assert is_float(usage.cost.input) and usage.cost.input >= 0
        assert is_float(usage.cost.output) and usage.cost.output >= 0
        assert is_float(usage.cost.cache_read) and usage.cost.cache_read >= 0
        assert is_float(usage.cost.cache_write) and usage.cost.cache_write >= 0
        assert is_float(usage.cost.total) and usage.cost.total >= 0
      end
    end

    property "Usage cost total equals sum of components" do
      check all(usage <- usage_gen()) do
        expected =
          usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write

        assert_in_delta usage.cost.total, expected, 0.0001
      end
    end
  end

  describe "Cost struct properties" do
    property "Cost all fields are non-negative floats" do
      check all(cost <- cost_gen()) do
        assert is_float(cost.input) and cost.input >= 0
        assert is_float(cost.output) and cost.output >= 0
        assert is_float(cost.cache_read) and cost.cache_read >= 0
        assert is_float(cost.cache_write) and cost.cache_write >= 0
        assert is_float(cost.total) and cost.total >= 0
      end
    end

    property "Cost total is consistent with component sum" do
      check all(cost <- cost_gen()) do
        expected = cost.input + cost.output + cost.cache_read + cost.cache_write
        assert_in_delta cost.total, expected, 0.0001
      end
    end
  end

  # ============================================================================
  # Serialization/Deserialization Roundtrip Properties
  # ============================================================================

  describe "serialization roundtrip properties" do
    property "TextContent survives map conversion roundtrip" do
      check all(content <- text_content_gen()) do
        map = Map.from_struct(content)
        reconstructed = struct(TextContent, map)
        assert content == reconstructed
      end
    end

    property "ThinkingContent survives map conversion roundtrip" do
      check all(content <- thinking_content_gen()) do
        map = Map.from_struct(content)
        reconstructed = struct(ThinkingContent, map)
        assert content == reconstructed
      end
    end

    property "ToolCall survives map conversion roundtrip" do
      check all(tc <- tool_call_gen()) do
        map = Map.from_struct(tc)
        reconstructed = struct(ToolCall, map)
        assert tc == reconstructed
      end
    end

    property "UserMessage survives map conversion roundtrip" do
      check all(
              msg <-
                map(
                  {string(:printable, max_length: 100), timestamp_gen()},
                  fn {content, ts} ->
                    %UserMessage{role: :user, content: content, timestamp: ts}
                  end
                )
            ) do
        map = Map.from_struct(msg)
        reconstructed = struct(UserMessage, map)
        assert msg == reconstructed
      end
    end

    property "Usage survives map conversion roundtrip" do
      check all(usage <- usage_gen()) do
        map = Map.from_struct(usage)
        cost_map = Map.from_struct(usage.cost)
        map = %{map | cost: struct(Cost, cost_map)}
        reconstructed = struct(Usage, map)
        assert usage == reconstructed
      end
    end

    property "Tool survives map conversion roundtrip" do
      check all(tool <- tool_gen()) do
        map = Map.from_struct(tool)
        reconstructed = struct(Tool, map)
        assert tool == reconstructed
      end
    end

    property "Model survives map conversion roundtrip" do
      check all(model <- model_gen()) do
        map = Map.from_struct(model)
        cost_map = Map.from_struct(model.cost)
        map = %{map | cost: struct(ModelCost, cost_map)}
        reconstructed = struct(Model, map)
        assert model == reconstructed
      end
    end
  end

  describe "JSON encoding properties" do
    property "TextContent JSON encodes without error" do
      check all(content <- text_content_gen()) do
        map = Map.from_struct(content)
        assert {:ok, _json} = Jason.encode(map)
      end
    end

    property "ToolCall arguments JSON encode without error" do
      check all(tc <- tool_call_gen()) do
        assert {:ok, _json} = Jason.encode(tc.arguments)
      end
    end

    property "Usage JSON encodes without error" do
      check all(usage <- usage_gen()) do
        map = Map.from_struct(usage)
        cost_map = Map.from_struct(usage.cost)
        map = %{map | cost: cost_map}
        assert {:ok, _json} = Jason.encode(map)
      end
    end

    property "Tool parameters JSON encode without error" do
      check all(tool <- tool_gen()) do
        assert {:ok, _json} = Jason.encode(tool.parameters)
      end
    end
  end

  # ============================================================================
  # Type Coercion Properties
  # ============================================================================

  describe "type coercion properties" do
    property "thinking_level atom values are valid" do
      check all(level <- thinking_level()) do
        assert level in [:off, :minimal, :low, :medium, :high, :xhigh]
      end
    end

    property "stop_reason atom values are valid" do
      check all(reason <- stop_reason()) do
        assert reason in [:stop, :length, :tool_use, :error, :aborted]
      end
    end

    property "role atom values are valid for messages" do
      check all(r <- role()) do
        assert r in [:user, :assistant, :tool_result]
      end
    end

    property "content block type atoms are valid" do
      check all(block <- content_block_gen()) do
        assert block.type in [:text, :thinking, :tool_call]
      end
    end

    property "MapSet for pending_tool_calls handles string additions" do
      check all(
              ids <- list_of(string(:alphanumeric, min_length: 5, max_length: 20), max_length: 10)
            ) do
        set =
          Enum.reduce(ids, MapSet.new(), fn id, acc ->
            MapSet.put(acc, id)
          end)

        unique_ids = Enum.uniq(ids)
        assert MapSet.size(set) == length(unique_ids)
      end
    end
  end

  # ============================================================================
  # Edge Cases with Random Input Properties
  # ============================================================================

  describe "edge cases properties" do
    property "empty content is handled" do
      # Empty text content
      content = %TextContent{type: :text, text: ""}
      assert content.text == ""

      # Empty thinking content
      thinking = %ThinkingContent{type: :thinking, thinking: ""}
      assert thinking.thinking == ""

      # Empty arguments
      tc = %ToolCall{type: :tool_call, id: "id", name: "name", arguments: %{}}
      assert tc.arguments == %{}
    end

    property "unicode strings in text content work correctly" do
      check all(text <- unicode_string()) do
        content = %TextContent{type: :text, text: text}
        assert content.text == text
        assert String.valid?(content.text)
      end
    end

    property "unicode strings in messages work correctly" do
      check all(text <- unicode_string()) do
        msg = %UserMessage{role: :user, content: text, timestamp: 0}
        assert msg.content == text
        assert String.valid?(msg.content)
      end
    end

    property "very long strings are handled" do
      check all(len <- integer(1000..5000)) do
        long_text = String.duplicate("x", len)
        content = %TextContent{type: :text, text: long_text}
        assert String.length(content.text) == len
      end
    end

    property "timestamps at boundary values work" do
      boundary_timestamps = [0, 1, 999_999_999_999, 9_999_999_999_999]

      for ts <- boundary_timestamps do
        msg = %UserMessage{role: :user, content: "test", timestamp: ts}
        assert msg.timestamp == ts
      end
    end

    property "nil values in optional fields work" do
      # AssistantMessage with nil usage
      msg = %AssistantMessage{role: :assistant, content: [], usage: nil}
      assert is_nil(msg.usage)

      # AssistantMessage with nil error_message
      msg2 = %AssistantMessage{role: :assistant, content: [], error_message: nil}
      assert is_nil(msg2.error_message)

      # ToolResultMessage with nil details
      result = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "id",
        tool_name: "name",
        content: [],
        details: nil
      }

      assert is_nil(result.details)
    end

    property "special characters in tool names are handled" do
      special_names = ["tool-name", "tool_name", "tool.name", "tool:name", "TOOL", "123tool"]

      for name <- special_names do
        tc = %ToolCall{type: :tool_call, id: "id", name: name, arguments: %{}}
        assert tc.name == name
      end
    end

    property "deeply nested arguments work" do
      check all(key <- string(:alphanumeric, min_length: 1, max_length: 10)) do
        nested = %{key => %{"nested" => %{"deep" => "value"}}}
        tc = %ToolCall{type: :tool_call, id: "id", name: "name", arguments: nested}
        assert tc.arguments == nested
      end
    end
  end

  # ============================================================================
  # AgentContext Properties
  # ============================================================================

  describe "AgentContext properties" do
    property "AgentContext.new creates valid struct" do
      check all(prompt <- maybe_string()) do
        ctx = AgentContext.new(system_prompt: prompt)
        assert %AgentContext{} = ctx
        assert ctx.system_prompt == prompt
        assert ctx.messages == []
        assert ctx.tools == []
      end
    end

    property "AgentContext fields are properly typed" do
      check all(ctx <- agent_context_gen()) do
        assert is_nil(ctx.system_prompt) or is_binary(ctx.system_prompt)
        assert is_list(ctx.messages)
        assert is_list(ctx.tools)
      end
    end

    property "AgentContext tools are AgentTool structs" do
      check all(ctx <- agent_context_gen()) do
        Enum.each(ctx.tools, fn tool ->
          assert %AgentTool{} = tool
        end)
      end
    end
  end

  # ============================================================================
  # AgentState Properties
  # ============================================================================

  describe "AgentState properties" do
    property "AgentState default values are valid" do
      state = %AgentState{}
      assert state.system_prompt == ""
      assert is_nil(state.model)
      assert state.thinking_level == :off
      assert state.tools == []
      assert state.messages == []
      assert state.is_streaming == false
      assert is_nil(state.stream_message)
      assert MapSet.size(state.pending_tool_calls) == 0
      assert is_nil(state.error)
    end

    property "AgentState thinking_level is valid" do
      check all(state <- agent_state_gen()) do
        assert state.thinking_level in [:off, :minimal, :low, :medium, :high, :xhigh]
      end
    end

    property "AgentState is_streaming is boolean" do
      check all(state <- agent_state_gen()) do
        assert is_boolean(state.is_streaming)
      end
    end

    property "AgentState pending_tool_calls is MapSet" do
      check all(state <- agent_state_gen()) do
        assert %MapSet{} = state.pending_tool_calls
      end
    end
  end

  # ============================================================================
  # AgentLoopConfig Properties
  # ============================================================================

  describe "AgentLoopConfig properties" do
    property "AgentLoopConfig default stream_options is StreamOptions struct" do
      config = %AgentLoopConfig{}
      assert %StreamOptions{} = config.stream_options
    end

    property "AgentLoopConfig model can be nil or Model struct" do
      # Default is nil
      config = %AgentLoopConfig{}
      assert is_nil(config.model)

      # Can be set to a model
      check all(model <- model_gen()) do
        config = %AgentLoopConfig{model: model}
        assert %Model{} = config.model
      end
    end

    property "AgentLoopConfig optional callbacks can be nil" do
      config = %AgentLoopConfig{}
      assert is_nil(config.transform_context)
      assert is_nil(config.get_api_key)
      assert is_nil(config.get_steering_messages)
      assert is_nil(config.get_follow_up_messages)
      assert is_nil(config.max_tool_concurrency)
      assert is_nil(config.stream_fn)
    end
  end

  # ============================================================================
  # AgentToolResult Properties
  # ============================================================================

  describe "AgentToolResult properties" do
    property "AgentToolResult default values are valid" do
      result = %AgentToolResult{}
      assert result.content == []
      assert is_nil(result.details)
      assert result.trust == :trusted
    end

    property "AgentToolResult content is list of content blocks" do
      check all(
              content_list <-
                list_of(one_of([text_content_gen(), image_content_gen()]), max_length: 5)
            ) do
        result = %AgentToolResult{content: content_list}
        assert is_list(result.content)

        Enum.each(result.content, fn block ->
          assert block.type in [:text, :image]
        end)
      end
    end

    property "AgentToolResult details can be any term" do
      details_examples = [nil, "string", 123, %{key: "value"}, [1, 2, 3], {:tuple, "value"}]

      for details <- details_examples do
        result = %AgentToolResult{content: [], details: details}
        assert result.details == details
      end
    end
  end

  # ============================================================================
  # AgentTool Properties
  # ============================================================================

  describe "AgentTool properties" do
    property "AgentTool has required string fields" do
      check all(tool <- agent_tool_gen()) do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_binary(tool.label)
      end
    end

    property "AgentTool parameters is a map" do
      check all(tool <- agent_tool_gen()) do
        assert is_map(tool.parameters)
      end
    end

    property "AgentTool execute is a function" do
      check all(tool <- agent_tool_gen()) do
        assert is_function(tool.execute)
      end
    end

    property "AgentTool execute returns AgentToolResult" do
      check all(tool <- agent_tool_gen()) do
        result = tool.execute.("id", %{}, nil, nil)
        assert %AgentToolResult{} = result
      end
    end
  end

  # ============================================================================
  # StreamOptions Properties
  # ============================================================================

  describe "StreamOptions properties" do
    property "StreamOptions default values are valid" do
      opts = %StreamOptions{}
      assert is_nil(opts.temperature)
      assert is_nil(opts.max_tokens)
      assert is_nil(opts.api_key)
      assert is_nil(opts.session_id)
      assert opts.headers == %{}
      assert is_nil(opts.reasoning)
      assert opts.thinking_budgets == %{}
      assert opts.stream_timeout == 300_000
      assert is_nil(opts.tool_choice)
    end

    property "StreamOptions temperature is nil or valid float" do
      check all(opts <- stream_options_gen()) do
        assert is_nil(opts.temperature) or (is_float(opts.temperature) and opts.temperature >= 0)
      end
    end

    property "StreamOptions max_tokens is nil or positive integer" do
      check all(opts <- stream_options_gen()) do
        assert is_nil(opts.max_tokens) or (is_integer(opts.max_tokens) and opts.max_tokens > 0)
      end
    end

    property "StreamOptions reasoning is nil or valid thinking_level" do
      check all(opts <- stream_options_gen()) do
        assert is_nil(opts.reasoning) or
                 opts.reasoning in [:off, :minimal, :low, :medium, :high, :xhigh]
      end
    end
  end

  # ============================================================================
  # Model Properties
  # ============================================================================

  describe "Model properties" do
    property "Model has required fields" do
      check all(model <- model_gen()) do
        assert is_binary(model.id)
        assert is_binary(model.name)
        assert not is_nil(model.api)
        assert not is_nil(model.provider)
      end
    end

    property "Model cost is ModelCost struct" do
      check all(model <- model_gen()) do
        assert %ModelCost{} = model.cost
      end
    end

    property "Model context_window and max_tokens are non-negative integers" do
      check all(model <- model_gen()) do
        assert is_integer(model.context_window) and model.context_window >= 0
        assert is_integer(model.max_tokens) and model.max_tokens >= 0
      end
    end

    property "Model input is list of input types" do
      check all(model <- model_gen()) do
        assert is_list(model.input)

        Enum.each(model.input, fn input_type ->
          assert input_type in [:text, :image]
        end)
      end
    end

    property "Model reasoning is boolean" do
      check all(model <- model_gen()) do
        assert is_boolean(model.reasoning)
      end
    end
  end

  # ============================================================================
  # Context Properties
  # ============================================================================

  describe "Context properties" do
    property "Context.new creates valid struct" do
      check all(prompt <- maybe_string()) do
        ctx = Context.new(system_prompt: prompt)
        assert %Context{} = ctx
        assert ctx.system_prompt == prompt
        assert ctx.messages == []
        assert ctx.tools == []
      end
    end

    property "Context.add_user_message prepends message (O(1) performance)" do
      check all(
              initial_count <- integer(0..5),
              content <- non_empty_string()
            ) do
        initial_messages =
          Enum.map(1..initial_count//1, fn i ->
            %UserMessage{role: :user, content: "msg#{i}", timestamp: i}
          end)

        ctx = %Context{messages: initial_messages}
        updated = Context.add_user_message(ctx, content)

        assert length(updated.messages) == initial_count + 1
        # Messages are prepended for O(1) performance, so new message is at head
        first_msg = hd(updated.messages)
        assert %UserMessage{} = first_msg
        assert first_msg.content == content

        # Chronological order can be obtained with get_messages_chronological/1
        chronological = Context.get_messages_chronological(updated)
        last_msg = List.last(chronological)
        assert last_msg.content == content
      end
    end

    property "Context messages preserve order" do
      check all(messages <- list_of(message_gen(), min_length: 2, max_length: 10)) do
        ctx = %Context{messages: messages}

        Enum.with_index(messages)
        |> Enum.each(fn {msg, idx} ->
          assert Enum.at(ctx.messages, idx) == msg
        end)
      end
    end
  end
end
