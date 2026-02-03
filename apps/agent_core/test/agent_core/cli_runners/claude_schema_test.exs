defmodule AgentCore.CliRunners.ClaudeSchemaTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.ClaudeSchema
  alias AgentCore.CliRunners.ClaudeSchema.{
    StreamAssistantMessage,
    StreamResultMessage,
    StreamSystemMessage,
    StreamUserMessage,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock,
    Usage
  }

  describe "decode_event/1 - system messages" do
    test "decodes system init message" do
      json = ~s|{"type":"system","subtype":"init","session_id":"sess_123","model":"claude-opus-4","cwd":"/home/user","tools":["Bash","Read"]}|
      assert {:ok, %StreamSystemMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert msg.subtype == "init"
      assert msg.session_id == "sess_123"
      assert msg.model == "claude-opus-4"
      assert msg.cwd == "/home/user"
      assert msg.tools == ["Bash", "Read"]
    end

    test "decodes system message with minimal fields" do
      json = ~s|{"type":"system","subtype":"init"}|
      assert {:ok, %StreamSystemMessage{subtype: "init"}} = ClaudeSchema.decode_event(json)
    end
  end

  describe "decode_event/1 - assistant messages" do
    test "decodes assistant message with text content" do
      json = ~s|{"type":"assistant","session_id":"sess_123","message":{"role":"assistant","content":[{"type":"text","text":"Hello world"}]}}|
      assert {:ok, %StreamAssistantMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert msg.session_id == "sess_123"
      assert [%TextBlock{text: "Hello world"}] = msg.message.content
    end

    test "decodes assistant message with thinking block" do
      json = ~s|{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me analyze...","signature":"abc123"}]}}|
      assert {:ok, %StreamAssistantMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert [%ThinkingBlock{thinking: "Let me analyze...", signature: "abc123"}] = msg.message.content
    end

    test "decodes assistant message with tool_use block" do
      json = ~s|{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_123","name":"Bash","input":{"command":"ls -la"}}]}}|
      assert {:ok, %StreamAssistantMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert [%ToolUseBlock{id: "toolu_123", name: "Bash", input: %{"command" => "ls -la"}}] = msg.message.content
    end

    test "decodes assistant message with mixed content" do
      json = ~s|{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll run a command"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo hi"}}]}}|
      assert {:ok, %StreamAssistantMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert [%TextBlock{}, %ToolUseBlock{}] = msg.message.content
    end
  end

  describe "decode_event/1 - user messages" do
    test "decodes user message with tool_result" do
      json = ~s|{"type":"user","session_id":"sess_123","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"output text","is_error":false}]}}|
      assert {:ok, %StreamUserMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert msg.session_id == "sess_123"
      assert [%ToolResultBlock{tool_use_id: "toolu_123", content: "output text", is_error: false}] = msg.message.content
    end

    test "decodes user message with error result" do
      json = ~s|{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"error message","is_error":true}]}}|
      assert {:ok, %StreamUserMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert [%ToolResultBlock{is_error: true}] = msg.message.content
    end

    test "decodes user message with string content" do
      json = ~s|{"type":"user","message":{"role":"user","content":"plain text input"}}|
      assert {:ok, %StreamUserMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert msg.message.content == "plain text input"
    end
  end

  describe "decode_event/1 - result messages" do
    test "decodes success result message" do
      json = ~s|{"type":"result","subtype":"success","session_id":"sess_123","duration_ms":5000,"num_turns":3,"is_error":false,"result":"Final answer","usage":{"input_tokens":100,"output_tokens":50}}|
      assert {:ok, %StreamResultMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert msg.subtype == "success"
      assert msg.session_id == "sess_123"
      assert msg.duration_ms == 5000
      assert msg.num_turns == 3
      assert msg.is_error == false
      assert msg.result == "Final answer"
      assert %Usage{input_tokens: 100, output_tokens: 50} = msg.usage
    end

    test "decodes error result message" do
      json = ~s|{"type":"result","subtype":"error","is_error":true,"result":"Something went wrong"}|
      assert {:ok, %StreamResultMessage{} = msg} = ClaudeSchema.decode_event(json)
      assert msg.subtype == "error"
      assert msg.is_error == true
      assert msg.result == "Something went wrong"
    end

    test "decodes result with cost" do
      json = ~s|{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.015}|
      assert {:ok, %StreamResultMessage{total_cost_usd: 0.015}} = ClaudeSchema.decode_event(json)
    end
  end

  describe "decode_event/1 - ignored types" do
    test "ignores stream_event type" do
      json = ~s|{"type":"stream_event","event":{}}|
      assert {:ok, :ignored} = ClaudeSchema.decode_event(json)
    end

    test "ignores control_request type" do
      json = ~s|{"type":"control_request"}|
      assert {:ok, :ignored} = ClaudeSchema.decode_event(json)
    end
  end

  describe "decode_event/1 - error handling" do
    test "returns error for invalid JSON" do
      assert {:error, _} = ClaudeSchema.decode_event("{invalid}")
    end

    test "returns error for missing type" do
      assert {:error, :missing_type} = ClaudeSchema.decode_event(~s|{"foo":"bar"}|)
    end
  end

  describe "Usage struct" do
    test "decodes full usage" do
      json = ~s|{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}|
      assert {:ok, %StreamResultMessage{usage: usage}} = ClaudeSchema.decode_event(json)
      assert %Usage{
        input_tokens: 1000,
        output_tokens: 500,
        cache_creation_input_tokens: 100,
        cache_read_input_tokens: 200
      } = usage
    end
  end
end
