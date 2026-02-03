defmodule AgentCore.CliRunners.CodexSchemaTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.CodexSchema
  alias AgentCore.CliRunners.CodexSchema.{
    AgentMessageItem,
    CommandExecutionItem,
    ErrorItem,
    FileChangeItem,
    FileUpdateChange,
    ItemCompleted,
    ItemStarted,
    ItemUpdated,
    McpToolCallItem,
    ReasoningItem,
    StreamError,
    ThreadStarted,
    TodoItem,
    TodoListItem,
    TurnCompleted,
    TurnFailed,
    TurnStarted,
    Usage,
    WebSearchItem
  }

  describe "decode_event/1 - session lifecycle" do
    test "decodes thread.started" do
      json = ~s|{"type":"thread.started","thread_id":"abc123"}|
      assert {:ok, %ThreadStarted{thread_id: "abc123"}} = CodexSchema.decode_event(json)
    end

    test "decodes turn.started" do
      json = ~s|{"type":"turn.started"}|
      assert {:ok, %TurnStarted{}} = CodexSchema.decode_event(json)
    end

    test "decodes turn.completed with usage" do
      json = ~s|{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":200}}|
      assert {:ok, %TurnCompleted{usage: usage}} = CodexSchema.decode_event(json)
      assert %Usage{input_tokens: 100, cached_input_tokens: 50, output_tokens: 200} = usage
    end

    test "decodes turn.failed" do
      json = ~s|{"type":"turn.failed","error":{"message":"Something went wrong"}}|
      assert {:ok, %TurnFailed{error: error}} = CodexSchema.decode_event(json)
      assert error.message == "Something went wrong"
    end

    test "decodes stream error" do
      json = ~s|{"type":"error","message":"Connection lost"}|
      assert {:ok, %StreamError{message: "Connection lost"}} = CodexSchema.decode_event(json)
    end
  end

  describe "decode_event/1 - item events" do
    test "decodes item.started with agent_message" do
      json = ~s|{"type":"item.started","item":{"type":"agent_message","id":"msg_1","text":"Hello"}}|
      assert {:ok, %ItemStarted{item: item}} = CodexSchema.decode_event(json)
      assert %AgentMessageItem{id: "msg_1", text: "Hello"} = item
    end

    test "decodes item.updated with command_execution" do
      json = ~s|{"type":"item.updated","item":{"type":"command_execution","id":"cmd_1","command":"ls -la","status":"in_progress"}}|
      assert {:ok, %ItemUpdated{item: item}} = CodexSchema.decode_event(json)
      assert %CommandExecutionItem{id: "cmd_1", command: "ls -la", status: :in_progress} = item
    end

    test "decodes item.completed with command_execution" do
      json = ~s|{"type":"item.completed","item":{"type":"command_execution","id":"cmd_1","command":"ls","exit_code":0,"status":"completed"}}|
      assert {:ok, %ItemCompleted{item: item}} = CodexSchema.decode_event(json)
      assert %CommandExecutionItem{exit_code: 0, status: :completed} = item
    end

    test "decodes reasoning item" do
      json = ~s|{"type":"item.started","item":{"type":"reasoning","id":"r_1","text":"Let me think..."}}|
      assert {:ok, %ItemStarted{item: item}} = CodexSchema.decode_event(json)
      assert %ReasoningItem{id: "r_1", text: "Let me think..."} = item
    end

    test "decodes file_change item" do
      json = ~s|{"type":"item.completed","item":{"type":"file_change","id":"fc_1","changes":[{"path":"foo.ex","kind":"add"},{"path":"bar.ex","kind":"update"}],"status":"completed"}}|
      assert {:ok, %ItemCompleted{item: item}} = CodexSchema.decode_event(json)
      assert %FileChangeItem{id: "fc_1", status: :completed, changes: changes} = item
      assert [%FileUpdateChange{path: "foo.ex", kind: :add}, %FileUpdateChange{path: "bar.ex", kind: :update}] = changes
    end

    test "decodes mcp_tool_call item" do
      json = ~s|{"type":"item.started","item":{"type":"mcp_tool_call","id":"t_1","server":"my_server","tool":"read_file","arguments":{"path":"foo.ex"},"status":"in_progress"}}|
      assert {:ok, %ItemStarted{item: item}} = CodexSchema.decode_event(json)
      assert %McpToolCallItem{
        id: "t_1",
        server: "my_server",
        tool: "read_file",
        arguments: %{"path" => "foo.ex"},
        status: :in_progress
      } = item
    end

    test "decodes web_search item" do
      json = ~s|{"type":"item.started","item":{"type":"web_search","id":"ws_1","query":"elixir genserver"}}|
      assert {:ok, %ItemStarted{item: item}} = CodexSchema.decode_event(json)
      assert %WebSearchItem{id: "ws_1", query: "elixir genserver"} = item
    end

    test "decodes todo_list item" do
      json = ~s|{"type":"item.completed","item":{"type":"todo_list","id":"todo_1","items":[{"text":"Task 1","completed":true},{"text":"Task 2","completed":false}]}}|
      assert {:ok, %ItemCompleted{item: item}} = CodexSchema.decode_event(json)
      assert %TodoListItem{id: "todo_1", items: items} = item
      assert [%TodoItem{text: "Task 1", completed: true}, %TodoItem{text: "Task 2", completed: false}] = items
    end

    test "decodes error item" do
      json = ~s|{"type":"item.completed","item":{"type":"error","id":"err_1","message":"Something failed"}}|
      assert {:ok, %ItemCompleted{item: item}} = CodexSchema.decode_event(json)
      assert %ErrorItem{id: "err_1", message: "Something failed"} = item
    end
  end

  describe "decode_event/1 - error handling" do
    test "returns error for invalid JSON" do
      assert {:error, _} = CodexSchema.decode_event("{invalid}")
    end

    test "returns error for missing type" do
      assert {:error, :missing_type} = CodexSchema.decode_event(~s|{"foo":"bar"}|)
    end

    test "returns error for unknown event type" do
      assert {:error, {:unknown_event_type, "unknown"}} = CodexSchema.decode_event(~s|{"type":"unknown"}|)
    end

    test "returns error for unknown item type" do
      json = ~s|{"type":"item.started","item":{"type":"unknown_item","id":"x"}}|
      assert {:error, {:unknown_item_type, "unknown_item"}} = CodexSchema.decode_event(json)
    end
  end

  describe "decode_event/1 - status parsing" do
    test "parses all valid statuses for command_execution" do
      for {status_str, expected} <- [
        {"in_progress", :in_progress},
        {"completed", :completed},
        {"failed", :failed},
        {"declined", :declined}
      ] do
        json = ~s|{"type":"item.started","item":{"type":"command_execution","id":"1","command":"ls","status":"#{status_str}"}}|
        assert {:ok, %ItemStarted{item: %CommandExecutionItem{status: ^expected}}} = CodexSchema.decode_event(json)
      end
    end

    test "defaults to in_progress for unknown status" do
      json = ~s|{"type":"item.started","item":{"type":"command_execution","id":"1","command":"ls","status":"unknown_status"}}|
      assert {:ok, %ItemStarted{item: %CommandExecutionItem{status: :in_progress}}} = CodexSchema.decode_event(json)
    end
  end
end
