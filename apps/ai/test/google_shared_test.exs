defmodule Ai.Providers.GoogleSharedTest do
  use ExUnit.Case

  alias Ai.Providers.GoogleShared
  alias Ai.Types.{Context, Model, ModelCost, TextContent, ToolResultMessage}

  describe "normalize_sse_message/1" do
    test "handles unwrapped data" do
      assert {:data, "chunk"} == GoogleShared.normalize_sse_message({:data, "chunk"})
    end

    test "handles wrapped data" do
      ref = make_ref()
      assert {:data, "chunk"} == GoogleShared.normalize_sse_message({ref, {:data, "chunk"}})
    end

    test "handles done messages" do
      assert :done == GoogleShared.normalize_sse_message({:done, :ok})

      ref = make_ref()
      assert :done == GoogleShared.normalize_sse_message({ref, :done})
      assert :done == GoogleShared.normalize_sse_message({ref, {:done, :ok}})
    end

    test "handles down messages" do
      assert :down == GoogleShared.normalize_sse_message({:DOWN, make_ref(), :process, self(), :normal})
    end

    test "ignores unknown messages" do
      assert :ignore == GoogleShared.normalize_sse_message(:unknown)
    end
  end

  describe "thinking helpers" do
    test "thinking_part?/1 detects thought marker" do
      assert GoogleShared.thinking_part?(%{"thought" => true}) == true
      assert GoogleShared.thinking_part?(%{"thought" => false}) == false
      assert GoogleShared.thinking_part?(%{}) == false
    end

    test "retain_thought_signature keeps last non-empty signature" do
      assert GoogleShared.retain_thought_signature(nil, "sig") == "sig"
      assert GoogleShared.retain_thought_signature("old", "") == "old"
      assert GoogleShared.retain_thought_signature("old", nil) == "old"
    end

    test "valid_thought_signature? validates base64" do
      assert GoogleShared.valid_thought_signature?("TWFu") == true
      assert GoogleShared.valid_thought_signature?("abc") == false
      assert GoogleShared.valid_thought_signature?("**") == false
    end

    test "resolve_thought_signature only keeps valid signatures for same provider" do
      assert GoogleShared.resolve_thought_signature(true, "TWFu") == "TWFu"
      assert GoogleShared.resolve_thought_signature(true, "abc") == nil
      assert GoogleShared.resolve_thought_signature(false, "TWFu") == nil
    end
  end

  describe "tool call helpers" do
    test "requires_tool_call_id? for claude and gpt-oss" do
      assert GoogleShared.requires_tool_call_id?("claude-3-5-sonnet-20240620") == true
      assert GoogleShared.requires_tool_call_id?("gpt-oss-20b") == true
      assert GoogleShared.requires_tool_call_id?("gemini-2.5-pro") == false
    end

    test "merge_function_responses combines consecutive tool results" do
      model = %Model{
        id: "gemini-2.0-flash",
        name: "Gemini 2.0 Flash",
        api: :google_generative_ai,
        provider: :google,
        base_url: "https://generativelanguage.googleapis.com/v1beta",
        input: [:text],
        cost: %ModelCost{}
      }

      tool_a = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_a",
        tool_name: "tool_a",
        content: [%TextContent{text: "ok-a"}],
        timestamp: System.system_time(:millisecond)
      }

      tool_b = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_b",
        tool_name: "tool_b",
        content: [%TextContent{text: "ok-b"}],
        timestamp: System.system_time(:millisecond)
      }

      context = Context.new(messages: [tool_a, tool_b])

      [content] = GoogleShared.convert_messages(model, context)
      assert content["role"] == "user"
      assert length(content["parts"]) == 2
    end

    test "map_tool_choice maps known values" do
      assert GoogleShared.map_tool_choice(:auto) == "AUTO"
      assert GoogleShared.map_tool_choice(:none) == "NONE"
      assert GoogleShared.map_tool_choice(:any) == "ANY"
      assert GoogleShared.map_tool_choice(:unknown) == "AUTO"
    end

    test "convert_messages skips images when model does not support them" do
      model = %Model{
        id: "gemini-2.0-flash",
        name: "Gemini 2.0 Flash",
        api: :google_generative_ai,
        provider: :google,
        base_url: "https://generativelanguage.googleapis.com/v1beta",
        input: [:text],
        cost: %ModelCost{}
      }

      tool = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_a",
        tool_name: "tool_a",
        content: [
          %Ai.Types.ImageContent{data: "AA==", mime_type: "image/png"}
        ],
        timestamp: System.system_time(:millisecond)
      }

      context = Context.new(messages: [tool])

      [content] = GoogleShared.convert_messages(model, context)
      [part] = content["parts"]
      assert Map.has_key?(part, "functionResponse")
      refute Map.has_key?(part, "inlineData")
    end
  end

  describe "thinking budgets" do
    test "clamp_reasoning handles :xhigh and invalid values" do
      assert GoogleShared.clamp_reasoning(:xhigh) == :high
      assert GoogleShared.clamp_reasoning(:medium) == :medium
      assert GoogleShared.clamp_reasoning(:invalid) == nil
    end

    test "get_thinking_budget uses defaults and overrides" do
      model = %Model{id: "gemini-2.5-pro"}
      assert GoogleShared.get_thinking_budget(model, :minimal, %{}) == 128
      assert GoogleShared.get_thinking_budget(model, :minimal, %{minimal: 999}) == 999

      other = %Model{id: "other-model"}
      assert GoogleShared.get_thinking_budget(other, :minimal, %{}) == -1
    end

    test "get_gemini_3_thinking_level varies by model" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-pro") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-pro") == "HIGH"
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-flash") == "MINIMAL"
    end
  end

  describe "stop reason mapping" do
    test "maps STOP and MAX_TOKENS" do
      assert GoogleShared.map_stop_reason("STOP") == :stop
      assert GoogleShared.map_stop_reason("MAX_TOKENS") == :length
      assert GoogleShared.map_stop_reason("OTHER") == :error
    end
  end
end
