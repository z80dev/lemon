defmodule AgentCore.CliRunners.ClaudeRunnerTest do
  use ExUnit.Case, async: false

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

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  setup do
    # Clean up config between tests
    System.delete_env("LEMON_CLAUDE_YOLO")

    on_exit(fn ->
      System.delete_env("LEMON_CLAUDE_YOLO")
    end)

    :ok
  end

  # ============================================================================
  # engine/0 Tests
  # ============================================================================

  describe "engine/0" do
    test "returns claude" do
      assert ClaudeRunner.engine() == "claude"
    end
  end

  # ============================================================================
  # build_command/3 Tests
  # ============================================================================

  describe "build_command/3" do
    test "builds command for new session" do
      state = RunnerState.new()
      {cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert cmd == "claude"
      assert "-p" in args
      assert "--output-format" in args
      assert "stream-json" in args
      assert "--verbose" in args
      refute "--dangerously-skip-permissions" in args
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

    test "adds skip-permissions flag when yolo enabled via config" do
      state = RunnerState.new(%{yolo: true})
      {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert "--dangerously-skip-permissions" in args
    end

    test "adds skip-permissions flag when dangerously_skip_permissions enabled" do
      state = RunnerState.new(%{dangerously_skip_permissions: true})
      {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert "--dangerously-skip-permissions" in args
    end

    test "adds skip-permissions flag when LEMON_CLAUDE_YOLO env set" do
      System.put_env("LEMON_CLAUDE_YOLO", "1")

      state = RunnerState.new()
      {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert "--dangerously-skip-permissions" in args
    end

    test "LEMON_CLAUDE_YOLO accepts various truthy values" do
      for val <- ["1", "true", "TRUE", "yes", "YES"] do
        System.put_env("LEMON_CLAUDE_YOLO", val)

        state = RunnerState.new()
        {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

        assert "--dangerously-skip-permissions" in args, "Expected truthy for LEMON_CLAUDE_YOLO=#{val}"
      end
    end

    test "adds allowed tools when configured as list" do
      state = RunnerState.new(%{allowed_tools: ["Bash", "Read", "Write"]})
      {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert "--allowedTools" in args
      assert "Bash" in args
      assert "Read" in args
      assert "Write" in args
    end

    test "adds allowed tools when configured as comma-separated string" do
      state = RunnerState.new(%{allowed_tools: "Bash,Read,Write"})
      {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      assert "--allowedTools" in args
      assert "Bash" in args
    end

    test "handles empty allowed_tools list" do
      state = RunnerState.new(%{allowed_tools: []})
      {_cmd, args} = ClaudeRunner.build_command("Hello", nil, state)

      refute "--allowedTools" in args
    end
  end

  # ============================================================================
  # stdin_payload/3 Tests
  # ============================================================================

  describe "stdin_payload/3" do
    test "returns nil (Claude uses CLI args for prompt)" do
      state = RunnerState.new()
      assert ClaudeRunner.stdin_payload("Hello", nil, state) == nil
    end

    test "returns nil even with resume token" do
      state = RunnerState.new()
      token = ResumeToken.new("claude", "sess_123")
      assert ClaudeRunner.stdin_payload("Continue", token, state) == nil
    end
  end

  # ============================================================================
  # init_state/2 Tests
  # ============================================================================

  describe "init_state/2" do
    test "creates fresh RunnerState" do
      state = ClaudeRunner.init_state("prompt", nil)

      assert %RunnerState{} = state
      assert state.found_session == nil
      assert state.last_assistant_text == nil
      assert state.pending_actions == %{}
      assert state.thinking_seq == 0
    end

    test "creates fresh state regardless of resume token" do
      token = ResumeToken.new("claude", "sess_123")
      state = ClaudeRunner.init_state("prompt", token)

      assert %RunnerState{} = state
      assert state.found_session == nil
    end
  end

  # ============================================================================
  # translate_event/2 - System Messages
  # ============================================================================

  describe "translate_event/2 - system messages" do
    test "translates system init to StartedEvent" do
      state = RunnerState.new()
      event = %StreamSystemMessage{
        subtype: "init",
        session_id: "sess_abc123",
        model: "claude-opus-4",
        cwd: "/home/user",
        tools: ["Bash", "Read"],
        permission_mode: "default"
      }

      {events, new_state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%StartedEvent{} = started] = events
      assert started.engine == "claude"
      assert started.resume.value == "sess_abc123"
      assert started.meta.model == "claude-opus-4"
      assert started.meta.cwd == "/home/user"
      assert started.meta.tools == ["Bash", "Read"]
      assert started.meta.permission_mode == "default"
      assert new_state.found_session.value == "sess_abc123"
      assert opts[:found_session].value == "sess_abc123"
    end

    test "ignores system message without session_id" do
      state = RunnerState.new()
      event = %StreamSystemMessage{subtype: "init", session_id: nil}

      {events, new_state, opts} = ClaudeRunner.translate_event(event, state)

      assert events == []
      assert new_state.found_session == nil
      assert opts == []
    end

    test "ignores non-init system messages" do
      state = RunnerState.new()
      event = %StreamSystemMessage{subtype: "other", session_id: "sess_123"}

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)
      assert events == []
    end

    test "ignores :ignored decoded events" do
      state = RunnerState.new()

      {events, new_state, opts} = ClaudeRunner.translate_event(:ignored, state)

      assert events == []
      assert new_state == state
      assert opts == []
    end
  end

  # ============================================================================
  # translate_event/2 - Assistant Messages
  # ============================================================================

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

    test "accumulates text across multiple assistant messages" do
      state = RunnerState.new()

      event1 = %StreamAssistantMessage{
        message: %AssistantMessageContent{content: [%TextBlock{text: "First part. "}]}
      }
      {_, state, _} = ClaudeRunner.translate_event(event1, state)

      event2 = %StreamAssistantMessage{
        message: %AssistantMessageContent{content: [%TextBlock{text: "Second part."}]}
      }
      {_, state, _} = ClaudeRunner.translate_event(event2, state)

      assert state.last_assistant_text == "First part. Second part."
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
      assert action.action.detail.signature == "sig123"
      assert new_state.thinking_seq == 1
    end

    test "thinking blocks have sequential IDs" do
      state = RunnerState.new()

      event1 = %StreamAssistantMessage{
        message: %AssistantMessageContent{content: [%ThinkingBlock{thinking: "First thought"}]}
      }
      {[action1], state, _} = ClaudeRunner.translate_event(event1, state)

      event2 = %StreamAssistantMessage{
        message: %AssistantMessageContent{content: [%ThinkingBlock{thinking: "Second thought"}]}
      }
      {[action2], state, _} = ClaudeRunner.translate_event(event2, state)

      assert action1.action.id == "claude.thinking.0"
      assert action2.action.id == "claude.thinking.1"
      assert state.thinking_seq == 2
    end

    test "truncates long thinking text in title" do
      state = RunnerState.new()
      long_thinking = String.duplicate("x", 200)
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ThinkingBlock{thinking: long_thinking}]
        }
      }

      {[action], _state, _} = ClaudeRunner.translate_event(event, state)

      assert String.length(action.action.title) == 100
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
      assert action.action.detail.name == "Bash"
      assert action.action.detail.input == %{"command" => "ls -la"}
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
      assert action.title == "Write: new.ex"
    end

    test "translates Edit tool to file_change kind" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Edit", input: %{"file_path" => "/path/to/edit.ex"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :file_change
      assert action.title == "Edit: edit.ex"
    end

    test "translates Glob tool correctly" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Glob", input: %{"pattern" => "**/*.ex"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :tool
      assert action.title == "Glob: **/*.ex"
    end

    test "translates Grep tool correctly" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Grep", input: %{"pattern" => "defmodule"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :tool
      assert action.title == "Grep: defmodule"
    end

    test "translates WebSearch tool correctly" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "WebSearch", input: %{"query" => "elixir genserver"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :web_search
      assert action.title == "elixir genserver"
    end

    test "translates WebFetch tool correctly" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "WebFetch", input: %{"url" => "https://example.com"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :tool
      assert action.title == "Fetch: https://example.com"
    end

    test "translates Task tool as subagent" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Task", input: %{"prompt" => "Implement the feature with tests"}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :subagent
      assert action.title == "Task: Implement the feature with tests"
    end

    test "truncates long Task prompts in title" do
      state = RunnerState.new()
      long_prompt = String.duplicate("x", 100)
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Task", input: %{"prompt" => long_prompt}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      # "Task: " (6 chars) + 40 chars = 46 chars max
      assert String.length(action.title) == 46
    end

    test "handles unknown tool types" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "CustomTool", input: %{}}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{action: action}] = events
      assert action.kind == :tool
      assert action.title == "CustomTool"
    end

    test "emits warning when permission denied message is present" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          error: "Permission denied: Read tool not allowed",
          content: []
        }
      }

      {events, _new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert Enum.any?(events, fn
               %ActionEvent{action: %{kind: :warning}} -> true
               _ -> false
             end)
    end

    test "handles multiple content blocks in single message" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [
            %TextBlock{text: "Here's what I'll do:"},
            %ToolUseBlock{id: "t1", name: "Bash", input: %{"command" => "ls"}}
          ]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert length(events) == 1
      assert [%ActionEvent{action: %{kind: :command}}] = events
      assert new_state.last_assistant_text == "Here's what I'll do:"
      assert Map.has_key?(new_state.pending_actions, "t1")
    end

    test "handles empty content gracefully" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{message: %AssistantMessageContent{content: []}}

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert events == []
      assert new_state == state
    end

    test "handles nil content gracefully" do
      state = RunnerState.new()
      event = %StreamAssistantMessage{message: %AssistantMessageContent{content: nil}}

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert events == []
      assert new_state == state
    end
  end

  # ============================================================================
  # translate_event/2 - User Messages (Tool Results)
  # ============================================================================

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
      assert action.action.kind == :command
      assert action.ok == true
      assert action.action.detail.result_preview == "file listing"
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

    test "emits warning when tool result indicates permission denial" do
      state = RunnerState.new()

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "t1", content: "Permission denied", is_error: true}]
        }
      }

      {events, _state, _opts} = ClaudeRunner.translate_event(event, state)

      # Should have both the warning and the fallback action
      assert length(events) >= 1
      assert Enum.any?(events, fn
               %ActionEvent{action: %{kind: :warning}} -> true
               _ -> false
             end)
    end

    test "handles list content in tool result" do
      state = %{RunnerState.new() | pending_actions: %{
        "t1" => %{id: "t1", kind: :tool, title: "test", detail: %{}}
      }}

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{
            tool_use_id: "t1",
            content: [%{"text" => "line 1"}, %{"text" => "line 2"}],
            is_error: false
          }]
        }
      }

      {[action], _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert action.action.detail.result_preview == "line 1\nline 2"
    end

    test "truncates long tool result previews" do
      state = %{RunnerState.new() | pending_actions: %{
        "t1" => %{id: "t1", kind: :tool, title: "test", detail: %{}}
      }}

      long_content = String.duplicate("x", 500)
      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "t1", content: long_content, is_error: false}]
        }
      }

      {[action], _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert String.length(action.action.detail.result_preview) == 200
    end

    test "handles multiple tool results in single message" do
      state = %{RunnerState.new() | pending_actions: %{
        "t1" => %{id: "t1", kind: :command, title: "cmd1", detail: %{}},
        "t2" => %{id: "t2", kind: :tool, title: "cmd2", detail: %{}}
      }}

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [
            %ToolResultBlock{tool_use_id: "t1", content: "ok1", is_error: false},
            %ToolResultBlock{tool_use_id: "t2", content: "ok2", is_error: false}
          ]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert length(events) == 2
      assert new_state.pending_actions == %{}
    end

    test "handles empty content gracefully" do
      state = RunnerState.new()
      event = %StreamUserMessage{message: %UserMessageContent{content: []}}

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert events == []
      assert new_state == state
    end
  end

  # ============================================================================
  # env/1 Tests
  # ============================================================================

  describe "env/1" do
    setup do
      original = System.get_env()

      on_exit(fn ->
        System.delete_env("LEMON_TEST_SECRET")
        System.delete_env("LEMON_TEST_PATH")
        System.delete_env("LEMON_CLAUDE_YOLO")

        # Restore original env vars we care about
        for key <- ["HOME", "PATH", "USER", "SHELL", "TERM"] do
          case Map.get(original, key) do
            nil -> System.delete_env(key)
            val -> System.put_env(key, val)
          end
        end
      end)

      :ok
    end

    test "scrubs environment by default when permissions not skipped" do
      System.put_env("LEMON_TEST_SECRET", "shh")
      System.put_env("LEMON_TEST_PATH", "/usr/bin")

      env = ClaudeRunner.env(RunnerState.new())

      assert is_list(env)
      refute Enum.any?(env, fn {key, _} -> key == "LEMON_TEST_SECRET" end)

      # Should include allowlisted vars
      assert Enum.any?(env, fn {key, _} -> key == "HOME" end) or System.get_env("HOME") == nil
    end

    test "does not scrub when yolo mode enabled" do
      System.put_env("LEMON_TEST_SECRET", "shh")

      env = ClaudeRunner.env(RunnerState.new(%{yolo: true}))

      # With yolo mode, scrub_env is auto-disabled
      assert env == nil or Enum.any?(env, fn {key, _} -> key == "LEMON_TEST_SECRET" end)
    end

    test "disables scrubbing when explicitly configured" do
      System.put_env("LEMON_TEST_SECRET", "shh")

      env = ClaudeRunner.env(RunnerState.new(%{scrub_env: false}))

      assert env == nil
    end

    test "allows environment overrides when scrubbing" do
      env = ClaudeRunner.env(RunnerState.new(%{scrub_env: true, env_overrides: %{"LEMON_TEST_SECRET" => "shh"}}))

      assert Enum.any?(env, fn {key, value} -> key == "LEMON_TEST_SECRET" and value == "shh" end)
    end

    test "allows environment overrides as keyword list" do
      env = ClaudeRunner.env(RunnerState.new(%{scrub_env: true, env_overrides: [{"CUSTOM_VAR", "value"}]}))

      assert Enum.any?(env, fn {key, value} -> key == "CUSTOM_VAR" and value == "value" end)
    end

    test "includes env_allowlist variables" do
      System.put_env("CUSTOM_ALLOWED", "yes")

      env = ClaudeRunner.env(RunnerState.new(%{scrub_env: true, env_allowlist: ["CUSTOM_ALLOWED"]}))

      assert Enum.any?(env, fn {key, _} -> key == "CUSTOM_ALLOWED" end)
    end

    test "includes variables matching env_allow_prefixes" do
      System.put_env("MY_PREFIX_VAR", "value")

      env = ClaudeRunner.env(RunnerState.new(%{scrub_env: true, env_allow_prefixes: ["MY_PREFIX_"]}))

      assert Enum.any?(env, fn {key, _} -> key == "MY_PREFIX_VAR" end)
    end
  end

  # ============================================================================
  # translate_event/2 - Result Messages
  # ============================================================================

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
        duration_api_ms: 4000,
        num_turns: 3,
        total_cost_usd: 0.05,
        usage: %Usage{input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 10, cache_read_input_tokens: 20}
      }

      {events, _state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == "Final answer text"
      assert completed.resume.value == "sess_123"
      assert completed.usage.duration_ms == 5000
      assert completed.usage.duration_api_ms == 4000
      assert completed.usage.num_turns == 3
      assert completed.usage.total_cost_usd == 0.05
      assert completed.usage.usage.input_tokens == 100
      assert completed.usage.usage.output_tokens == 50
      assert opts[:done] == true
    end

    test "uses result text when available" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "sess_123"),
        last_assistant_text: "Assistant text"
      }

      event = %StreamResultMessage{
        subtype: "success",
        session_id: "sess_123",
        is_error: false,
        result: "Result text"  # Should use this over last_assistant_text
      }

      {[completed], _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert completed.answer == "Result text"
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
      assert completed.resume.value == "sess_123"
      assert opts[:done] == true
    end

    test "error result without explicit message gets default error" do
      state = RunnerState.new()

      event = %StreamResultMessage{
        subtype: "error",
        session_id: "sess_123",
        is_error: true,
        result: nil
      }

      {[completed], _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert completed.ok == false
      assert completed.error == "Claude session failed"
    end

    test "uses session_id from event over found_session" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "old_session")
      }

      event = %StreamResultMessage{
        subtype: "success",
        session_id: "new_session",
        is_error: false,
        result: "Done"
      }

      {[completed], _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert completed.resume.value == "new_session"
    end

    test "falls back to found_session when event has no session_id" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "found_sess")
      }

      event = %StreamResultMessage{
        subtype: "success",
        session_id: nil,
        is_error: false,
        result: "Done"
      }

      {[completed], _state, _opts} = ClaudeRunner.translate_event(event, state)

      assert completed.resume.value == "found_sess"
    end
  end

  # ============================================================================
  # handle_exit_error/2 Tests
  # ============================================================================

  describe "handle_exit_error/2" do
    test "returns note and completed error events" do
      state = %{RunnerState.new() |
        last_assistant_text: "partial",
        found_session: ResumeToken.new("claude", "s1")
      }

      {events, _state} = ClaudeRunner.handle_exit_error(1, state)

      assert [%ActionEvent{} = note, %CompletedEvent{} = completed] = events
      assert note.action.kind == :warning
      assert note.action.title =~ "rc=1"
      assert completed.ok == false
      assert completed.error =~ "rc=1"
      assert completed.answer == "partial"
      assert completed.resume.value == "s1"
    end

    test "handles missing last_assistant_text" do
      state = RunnerState.new()

      {[_note, completed], _state} = ClaudeRunner.handle_exit_error(127, state)

      assert completed.answer == ""
      assert completed.error =~ "rc=127"
    end

    test "handles various exit codes" do
      state = RunnerState.new()

      for exit_code <- [1, 2, 127, 137, 255] do
        {[note, completed], _} = ClaudeRunner.handle_exit_error(exit_code, state)

        assert note.action.title =~ "rc=#{exit_code}"
        assert completed.error =~ "rc=#{exit_code}"
      end
    end
  end

  # ============================================================================
  # handle_stream_end/1 Tests
  # ============================================================================

  describe "handle_stream_end/1" do
    test "returns error when no session found" do
      state = RunnerState.new()

      {events, _state} = ClaudeRunner.handle_stream_end(state)

      assert [%CompletedEvent{ok: false} = completed] = events
      assert completed.error =~ "no session_id"
      assert completed.resume == nil
    end

    test "returns error when session found but no result event" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "s1"),
        last_assistant_text: "Done"
      }

      {events, _state} = ClaudeRunner.handle_stream_end(state)

      assert [%CompletedEvent{ok: false, answer: "Done"} = completed] = events
      assert completed.error =~ "without a result event"
      assert completed.resume.value == "s1"
    end

    test "includes partial text in error case" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "s1"),
        last_assistant_text: "Partial response"
      }

      {[completed], _state} = ClaudeRunner.handle_stream_end(state)

      assert completed.answer == "Partial response"
    end
  end

  # ============================================================================
  # decode_line/1 Tests
  # ============================================================================

  describe "decode_line/1" do
    test "decodes valid system init JSON" do
      json = Jason.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "session_id" => "sess_123",
        "model" => "claude-opus-4"
      })

      {:ok, event} = ClaudeRunner.decode_line(json)

      assert %StreamSystemMessage{} = event
      assert event.session_id == "sess_123"
      assert event.model == "claude-opus-4"
    end

    test "decodes valid assistant message JSON" do
      json = Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "Hello"}]
        }
      })

      {:ok, event} = ClaudeRunner.decode_line(json)

      assert %StreamAssistantMessage{} = event
      assert [%TextBlock{text: "Hello"}] = event.message.content
    end

    test "decodes valid user message JSON" do
      json = Jason.encode!(%{
        "type" => "user",
        "message" => %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok"}]
        }
      })

      {:ok, event} = ClaudeRunner.decode_line(json)

      assert %StreamUserMessage{} = event
      assert [%ToolResultBlock{tool_use_id: "t1"}] = event.message.content
    end

    test "decodes valid result message JSON" do
      json = Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "Done"
      })

      {:ok, event} = ClaudeRunner.decode_line(json)

      assert %StreamResultMessage{} = event
      assert event.result == "Done"
      assert event.is_error == false
    end

    test "returns :ignored for unknown event types" do
      json = Jason.encode!(%{"type" => "stream_event", "data" => %{}})

      {:ok, event} = ClaudeRunner.decode_line(json)

      assert event == :ignored
    end

    test "returns error for invalid JSON" do
      {:error, _reason} = ClaudeRunner.decode_line("not json")
    end

    test "returns error for JSON without type" do
      json = Jason.encode!(%{"data" => "something"})

      {:error, :missing_type} = ClaudeRunner.decode_line(json)
    end
  end

  # ============================================================================
  # GenServer Lifecycle Integration Tests
  # ============================================================================

  describe "GenServer lifecycle - start_link" do
    test "start_link requires prompt option" do
      # This test verifies that the runner requires a prompt
      # The start_link call will fail in init when trying to fetch the prompt
      # Use spawn_link to isolate the crash
      Process.flag(:trap_exit, true)

      spawn_link(fn ->
        ClaudeRunner.start_link(cwd: File.cwd!())
      end)

      # We should receive an EXIT message due to the KeyError
      # The error format is {%KeyError{}, stacktrace}
      assert_receive {:EXIT, _, {%KeyError{key: :prompt}, _}}, 1000
    after
      Process.flag(:trap_exit, false)
    end
  end

  # ============================================================================
  # Process Management Tests (using DummyRunner pattern)
  # ============================================================================

  describe "process management with mock" do
    # These tests use a simplified approach that doesn't require mocking the CLI
    # The JsonlRunner cancel test already validates the cancel behavior

    test "cancel/2 API is available" do
      # Verify the API exists and can be called
      # We don't actually start a process since that would call the real CLI
      assert function_exported?(ClaudeRunner, :cancel, 2)
    end

    test "stream/1 API is available" do
      assert function_exported?(ClaudeRunner, :stream, 1)
    end

    test "run/1 API is available" do
      assert function_exported?(ClaudeRunner, :run, 1)
    end
  end

  # ============================================================================
  # Event Stream Parsing Unit Tests
  # ============================================================================

  describe "event stream parsing - unit tests" do
    # Test the parsing logic directly without spawning processes

    test "parses system init and emits StartedEvent" do
      state = RunnerState.new()

      event = %StreamSystemMessage{
        subtype: "init",
        session_id: "sess_test123",
        model: "claude-opus-4"
      }

      {events, new_state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%StartedEvent{} = started] = events
      assert started.resume.value == "sess_test123"
      assert new_state.found_session.value == "sess_test123"
      assert opts[:found_session].value == "sess_test123"
    end

    test "parses assistant message and accumulates text" do
      state = RunnerState.new()

      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%TextBlock{text: "Hello world"}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert events == []
      assert new_state.last_assistant_text == "Hello world"
    end

    test "parses tool use and emits ActionEvent started" do
      state = RunnerState.new()

      event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "t1", name: "Bash", input: %{"command" => "ls"}}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{phase: :started}] = events
      assert Map.has_key?(new_state.pending_actions, "t1")
    end

    test "parses tool result and emits ActionEvent completed" do
      state = %{RunnerState.new() | pending_actions: %{
        "t1" => %{id: "t1", kind: :command, title: "ls", detail: %{}}
      }}

      event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "t1", content: "file1\nfile2", is_error: false}]
        }
      }

      {events, new_state, _opts} = ClaudeRunner.translate_event(event, state)

      assert [%ActionEvent{phase: :completed, ok: true}] = events
      assert new_state.pending_actions == %{}
    end

    test "parses error result and emits CompletedEvent with error" do
      state = RunnerState.new()

      event = %StreamResultMessage{
        subtype: "error",
        session_id: "s1",
        is_error: true,
        result: "API rate limit exceeded"
      }

      {events, _state, opts} = ClaudeRunner.translate_event(event, state)

      assert [%CompletedEvent{ok: false} = completed] = events
      assert completed.error == "API rate limit exceeded"
      assert opts[:done] == true
    end
  end

  # ============================================================================
  # Error Conditions Unit Tests
  # ============================================================================

  describe "error conditions - unit tests" do
    test "handle_exit_error creates error events for non-zero exit" do
      state = RunnerState.new()

      {events, _state} = ClaudeRunner.handle_exit_error(1, state)

      assert [%ActionEvent{} = note, %CompletedEvent{ok: false} = completed] = events
      assert note.action.kind == :warning
      assert completed.error =~ "rc=1"
    end

    test "handle_stream_end creates error when no result received" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "s1"),
        last_assistant_text: "partial"
      }

      {events, _state} = ClaudeRunner.handle_stream_end(state)

      assert [%CompletedEvent{ok: false} = completed] = events
      assert completed.answer == "partial"
      assert completed.error =~ "without a result event"
    end

    test "handle_stream_end handles missing session" do
      state = RunnerState.new()

      {events, _state} = ClaudeRunner.handle_stream_end(state)

      assert [%CompletedEvent{ok: false} = completed] = events
      assert completed.error =~ "no session_id"
    end
  end

  # ============================================================================
  # Resume Token Extraction Tests
  # ============================================================================

  describe "resume token extraction" do
    test "session_id from result overrides found_session in state" do
      state = %{RunnerState.new() |
        found_session: ResumeToken.new("claude", "init_session")
      }

      event = %StreamResultMessage{
        subtype: "success",
        session_id: "result_session",
        is_error: false,
        result: "done"
      }

      {[completed], _state, _opts} = ClaudeRunner.translate_event(event, state)

      # Result session_id takes precedence
      assert completed.resume.value == "result_session"
    end

    test "ResumeToken.format creates correct claude resume command" do
      token = ResumeToken.new("claude", "sess_123")
      assert ResumeToken.format(token) == "`claude --resume sess_123`"
    end

    test "ResumeToken.extract_resume finds claude tokens" do
      text = "To continue, run `claude --resume sess_abc123`"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "claude"
      assert token.value == "sess_abc123"
    end

    test "ResumeToken.is_resume_line recognizes claude resume lines" do
      assert ResumeToken.is_resume_line("claude --resume sess_123") == true
      assert ResumeToken.is_resume_line("`claude --resume sess_123`") == true
      assert ResumeToken.is_resume_line("Please run claude --resume sess_123") == false
    end

    test "extracts session_id from system init event" do
      state = RunnerState.new()

      event = %StreamSystemMessage{
        subtype: "init",
        session_id: "sess_abc123"
      }

      {[started], new_state, opts} = ClaudeRunner.translate_event(event, state)

      assert started.resume.engine == "claude"
      assert started.resume.value == "sess_abc123"
      assert new_state.found_session.value == "sess_abc123"
      assert opts[:found_session].value == "sess_abc123"
    end
  end

  # ============================================================================
  # Session Locking Unit Tests
  # ============================================================================

  describe "session locking" do
    test "session lock prevents duplicate resumes at init level" do
      # Session locking is tested at the JsonlRunner level
      # Here we verify the ClaudeRunner properly passes resume tokens

      state = RunnerState.new()
      token = ResumeToken.new("claude", "sess_123")
      {cmd, args} = ClaudeRunner.build_command("Continue", token, state)

      assert cmd == "claude"
      assert "--resume" in args
      assert "sess_123" in args
    end
  end

  # ============================================================================
  # RunnerState Tests
  # ============================================================================

  describe "RunnerState" do
    test "new/0 creates initialized state" do
      state = RunnerState.new()

      assert %RunnerState{} = state
      assert state.factory != nil
      assert state.found_session == nil
      assert state.last_assistant_text == nil
      assert state.pending_actions == %{}
      assert state.thinking_seq == 0
    end
  end

  # ============================================================================
  # Full Event Flow Tests
  # ============================================================================

  describe "full event flow simulation" do
    test "simulates complete session with all event types" do
      state = RunnerState.new()

      # 1. System init
      init_event = %StreamSystemMessage{
        subtype: "init",
        session_id: "sess_flow_test",
        model: "claude-opus-4",
        cwd: "/test",
        tools: ["Bash", "Read"]
      }
      {[started], state, _} = ClaudeRunner.translate_event(init_event, state)

      assert %StartedEvent{} = started
      assert started.resume.value == "sess_flow_test"
      assert state.found_session.value == "sess_flow_test"

      # 2. Assistant thinking
      thinking_event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ThinkingBlock{thinking: "Let me analyze the request..."}]
        }
      }
      {[thinking_action], state, _} = ClaudeRunner.translate_event(thinking_event, state)

      assert thinking_action.action.kind == :note
      assert state.thinking_seq == 1

      # 3. Assistant text
      text_event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%TextBlock{text: "I'll run a command. "}]
        }
      }
      {[], state, _} = ClaudeRunner.translate_event(text_event, state)
      assert state.last_assistant_text == "I'll run a command. "

      # 4. Tool use
      tool_use_event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%ToolUseBlock{id: "tool_1", name: "Bash", input: %{"command" => "ls -la"}}]
        }
      }
      {[tool_started], state, _} = ClaudeRunner.translate_event(tool_use_event, state)

      assert tool_started.phase == :started
      assert tool_started.action.kind == :command
      assert Map.has_key?(state.pending_actions, "tool_1")

      # 5. Tool result
      tool_result_event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{tool_use_id: "tool_1", content: "total 42\n...", is_error: false}]
        }
      }
      {[tool_completed], state, _} = ClaudeRunner.translate_event(tool_result_event, state)

      assert tool_completed.phase == :completed
      assert tool_completed.ok == true
      assert state.pending_actions == %{}

      # 6. More assistant text
      more_text_event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%TextBlock{text: "The directory contains 42 items."}]
        }
      }
      {[], state, _} = ClaudeRunner.translate_event(more_text_event, state)
      assert state.last_assistant_text == "I'll run a command. The directory contains 42 items."

      # 7. Result
      result_event = %StreamResultMessage{
        subtype: "success",
        session_id: "sess_flow_test",
        is_error: false,
        result: "Final answer",
        duration_ms: 5000,
        num_turns: 2,
        usage: %Usage{input_tokens: 100, output_tokens: 50}
      }
      {[completed], _final_state, opts} = ClaudeRunner.translate_event(result_event, state)

      assert %CompletedEvent{} = completed
      assert completed.ok == true
      assert completed.answer == "Final answer"
      assert completed.resume.value == "sess_flow_test"
      assert completed.usage.duration_ms == 5000
      assert opts[:done] == true
    end

    test "simulates error session flow" do
      state = RunnerState.new()

      # 1. System init
      init_event = %StreamSystemMessage{
        subtype: "init",
        session_id: "sess_error_test"
      }
      {[_started], state, _} = ClaudeRunner.translate_event(init_event, state)

      # 2. Some text before error
      text_event = %StreamAssistantMessage{
        message: %AssistantMessageContent{
          content: [%TextBlock{text: "Starting to process..."}]
        }
      }
      {[], state, _} = ClaudeRunner.translate_event(text_event, state)

      # 3. Error result
      # Note: When is_error is true, the result field contains the error message
      # and the answer comes from last_assistant_text (or result if not error text)
      result_event = %StreamResultMessage{
        subtype: "error",
        session_id: "sess_error_test",
        is_error: true,
        result: "Rate limit exceeded"
      }
      {[completed], _state, opts} = ClaudeRunner.translate_event(result_event, state)

      assert completed.ok == false
      assert completed.error == "Rate limit exceeded"
      # The error result uses the result field for the error message,
      # and answer includes any accumulated text or the result text
      assert completed.answer == "Rate limit exceeded"
      assert opts[:done] == true
    end

    test "simulates tool error flow" do
      state = RunnerState.new()

      # Setup with pending action
      state = %{state | pending_actions: %{
        "tool_err" => %{id: "tool_err", kind: :command, title: "bad command", detail: %{}}
      }}

      # Tool result with error
      tool_result_event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{
            tool_use_id: "tool_err",
            content: "command not found: badcmd",
            is_error: true
          }]
        }
      }
      {[tool_completed], state, _} = ClaudeRunner.translate_event(tool_result_event, state)

      assert tool_completed.ok == false
      assert tool_completed.action.detail.is_error == true
      assert state.pending_actions == %{}
    end

    test "handles permission warning in tool result" do
      state = RunnerState.new()

      # Tool result with permission error
      tool_result_event = %StreamUserMessage{
        message: %UserMessageContent{
          content: [%ToolResultBlock{
            tool_use_id: "perm_tool",
            content: "Permission denied: cannot access /root",
            is_error: true
          }]
        }
      }
      {events, _state, _} = ClaudeRunner.translate_event(tool_result_event, state)

      # Should have both a warning and the tool result
      warning = Enum.find(events, fn
        %ActionEvent{action: %{kind: :warning}} -> true
        _ -> false
      end)

      assert warning != nil
      assert warning.action.title =~ "Permission denied"
    end
  end

  # ============================================================================
  # Callback Compliance Tests
  # ============================================================================

  describe "JsonlRunner callback compliance" do
    test "implements all required callbacks" do
      # Verify all required callbacks are implemented
      assert function_exported?(ClaudeRunner, :engine, 0)
      assert function_exported?(ClaudeRunner, :build_command, 3)
      assert function_exported?(ClaudeRunner, :init_state, 2)
      assert function_exported?(ClaudeRunner, :stdin_payload, 3)
      assert function_exported?(ClaudeRunner, :decode_line, 1)
      assert function_exported?(ClaudeRunner, :translate_event, 2)
      assert function_exported?(ClaudeRunner, :handle_exit_error, 2)
      assert function_exported?(ClaudeRunner, :handle_stream_end, 1)
      assert function_exported?(ClaudeRunner, :env, 1)
    end

    test "engine returns string" do
      assert is_binary(ClaudeRunner.engine())
    end

    test "build_command returns {binary, list}" do
      state = RunnerState.new()
      {cmd, args} = ClaudeRunner.build_command("test", nil, state)

      assert is_binary(cmd)
      assert is_list(args)
      assert Enum.all?(args, &is_binary/1)
    end

    test "init_state returns RunnerState" do
      state = ClaudeRunner.init_state("test", nil)
      assert %RunnerState{} = state
    end

    test "stdin_payload returns nil for claude" do
      state = RunnerState.new()
      assert ClaudeRunner.stdin_payload("test", nil, state) == nil
    end

    test "decode_line handles valid and invalid input" do
      # Valid
      {:ok, _} = ClaudeRunner.decode_line(~s|{"type":"system"}|)

      # Invalid JSON
      {:error, _} = ClaudeRunner.decode_line("not json")

      # Missing type
      {:error, :missing_type} = ClaudeRunner.decode_line(~s|{"foo":"bar"}|)
    end

    test "translate_event returns correct tuple structure" do
      state = RunnerState.new()

      # All translate_event calls should return {events, state, opts}
      {events, new_state, opts} = ClaudeRunner.translate_event(:ignored, state)

      assert is_list(events)
      assert %RunnerState{} = new_state
      assert is_list(opts)
    end

    test "handle_exit_error returns correct tuple structure" do
      state = RunnerState.new()

      {events, new_state} = ClaudeRunner.handle_exit_error(1, state)

      assert is_list(events)
      assert length(events) == 2  # note + completed
      assert %RunnerState{} = new_state
    end

    test "handle_stream_end returns correct tuple structure" do
      state = RunnerState.new()

      {events, new_state} = ClaudeRunner.handle_stream_end(state)

      assert is_list(events)
      assert length(events) == 1  # completed
      assert %RunnerState{} = new_state
    end

    test "env returns nil or list of tuples" do
      state = RunnerState.new()
      env = ClaudeRunner.env(state)

      assert env == nil or is_list(env)
      if is_list(env) do
        assert Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end)
      end
    end
  end
end
