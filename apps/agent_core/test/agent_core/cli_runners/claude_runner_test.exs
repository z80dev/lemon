defmodule AgentCore.CliRunners.ClaudeRunnerTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.ClaudeRunner
  alias AgentCore.CliRunners.ClaudeRunner.RunnerState
  alias AgentCore.CliRunners.ClaudeSchema.{
    StreamAssistantMessage,
    StreamResultMessage,
    StreamSystemMessage,
    StreamUserMessage,
    AssistantMessageContent,
    UserMessageContent,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock,
    Usage
  }
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  describe "engine/0" do
    test "returns claude" do
      assert ClaudeRunner.engine() == "claude"
    end
  end

  describe "build_command/3" do
    test "builds command for new session" do
      state = RunnerState.new()
      {cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert cmd == "claude"
      assert "-p" in args
      assert "--output-format" in args
      assert "stream-json" in args
      assert "--verbose" in args
      assert "--" in args
      assert "Hello" in args
      refute "--resume" in args
    end

    test "builds command for resumed session" do
      state = RunnerState.new()
      token = ResumeToken.new("claude", "sess_123")
      {cmd, args} = ClaudeRunner.build_command("Continue", token, state)

      assert cmd == "claude"
      assert "--resume" in args
      assert "sess_123" in args
    end
  end

  describe "stdin_payload/3" do
    test "returns nil (Claude uses CLI args for prompt)" do
      state = RunnerState.new()
      assert ClaudeRunner.stdin_payload("Hello", nil, state) == nil
    end
  end

  describe "translate_event/2 - system messages" do
    test "translates system init to StartedEvent" do
      state = RunnerState.new()
      event = %StreamSystemMessage{
        subtype: "init",
        session_id: "sess_abc123",
        model: "claude-opus-4",
        cwd: "/home/user",
        tools: ["Bash", "Read"]
      }

      {events, new_state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%StartedEvent{} = started] = events
      assert started.engine == "claude"
      assert started.resume.value == "sess_abc123"
      assert started.meta.model == "claude-opus-4"
      assert new_state.found_session.value == "sess_abc123"
      assert opts[:found_session].value == "sess_abc123"
    end

    test "ignores system message without session_id" do
      state = RunnerState.new()
      event = %StreamSystemMessage{subtype: "init", session_id: nil}

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)
      assert events == []
    end
  end

  describe "translate_event/2 - assistant messages" do
    test "accumulates text content for final result" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%TextBlock{text: "Here is "}, %TextBlock{text: "my answer"}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert events == []
      assert new_state.last_assistant_text == "Here is my answer"
    end

    test "translates thinking block to action completed" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ThinkingBlock{thinking: "Let me analyze this...", signature: "sig123"}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :completed
      assert action.action.kind == :note
      assert action.action.id == "claude.thinking.0"
      assert action.ok == true
      assert new_state.thinking_seq == 1
    end

    test "translates tool_use to action started" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "toolu_123", name: "Bash", input: %{"command" => "ls -la"}}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :started
      assert action.action.kind == :command
      assert action.action.id == "toolu_123"
      assert action.action.title == "ls -la"
      assert Map.has_key?(new_state.pending_actions, "toolu_123")
    end

    test "translates Read tool to tool kind" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Read", input: %{"file_path" => "/path/to/file.ex"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :tool
      assert action.title == "Read: file.ex"
    end

    test "translates Write tool to file_change kind" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Write", input: %{"file_path" => "/path/to/new.ex"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :file_change
    end
  end

  describe "translate_event/2 - user messages (tool results)" do
    test "translates tool_result to action completed" do
      # First, create a pending action
      state = RunnerState.new()
      state = %{state | pending_actions: %{
        "toolu_123" => %{id: "toolu_123", kind: :command, title: "ls -la", detail: %{}}
      }}

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "toolu_123", content: "file listing", is_error: false}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :completed
      assert action.action.id == "toolu_123"
      assert action.ok == true
      assert new_state.pending_actions == %{}
    end

    test "translates error tool_result correctly" do
      state = %{RunnerState.new() | pending_actions: %{
        "t1" => %{id: "t1", kind: :command, title: "bad command", detail: %{}}
      }}

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "t1", content: "error output", is_error: true}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{ok: false}] = events
    end

    test "emits fallback action when tool_result has no pending action" do
      state = RunnerState.new()

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "t-missing", content: "ok", is_error: false}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :completed
      assert action.action.id == "t-missing"
      assert action.action.kind == :tool
      assert action.action.title == "tool result"
      assert action.ok == true
    end
  end

  describe "translate_event/2 - result messages" do
    test "translates success result to CompletedEvent" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "sess_123"),
        last_assistant_text: "Final answer text"
      }

      event = %StreamResultMessage{
        subtype: "success",
        session_id: "sess_123",
        is_error: false,
        result: nil,  # Uses last_assistant_text
        duration_ms: 5000,
        num_turns: 3,
        usage: %Usage{input_tokens: 100, output_tokens: 50}
      }

      {events, _state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == "Final answer text"
      assert completed.resume.value == "sess_123"
      assert completed.usage.duration_ms == 5000
      assert opts[:done] == true
    end

    test "translates error result to CompletedEvent" do
      state = RunnerState.new()

      event = %StreamResultMessage{
        subtype: "error",
        session_id: "sess_123",
        is_error: true,
        result: "Something went wrong"
      }

      {events, _state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == false
      assert completed.error == "Something went wrong"
      assert opts[:done] == true
    end
  end

  describe "handle_exit_error/2" do
    test "returns note and completed error events" do
      state = %{RunnerState.new() |
        last_assistant_text: "partial",
        found_session: ResumeToken.new("claude", "s1")
      }

      {events, _state} = ClaudeRunner.handle_exit_error(1, state)

      assert [%ActionEvent{} = note, %CompletedEvent{} = completed] = events
      assert note.action.kind == :warning
      assert completed.ok == false
      assert completed.error =~ "rc=1"
    end
  end

  describe "handle_stream_end/1" do
    test "returns error when no session found" do
      state = RunnerState.new()

      {events, _state} = ClaudeRunner.handle_stream_end(state)

      assert [%CompletedEvent{ok: false}] = events
    end

    test "returns error when session found but no result event" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "s1"),
        last_assistant_text: "Done"
      }

      {events, _state} = ClaudeRunner.handle_stream_end(state)

      assert [%CompletedEvent{ok: false, answer: "Done"}] = events
    end
  end
end
