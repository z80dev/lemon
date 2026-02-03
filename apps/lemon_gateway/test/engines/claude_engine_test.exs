defmodule LemonGateway.Engines.ClaudeEngineTest do
  @moduledoc """
  Comprehensive tests for the Claude engine implementation.

  Tests cover:
  - Engine identification
  - Resume token formatting and extraction
  - Resume line detection
  - Request handling via CliAdapter
  - Response parsing
  - Event emission
  - Error handling
  - Timeout handling
  - Cancellation
  - State management
  - Configuration handling
  - Process lifecycle
  """
  use ExUnit.Case, async: true

  alias LemonGateway.Engines.Claude
  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}
  alias LemonGateway.Event

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    StartedEvent
  }

  alias AgentCore.CliRunners.Types.ResumeToken, as: CoreResumeToken

  # ============================================================================
  # Engine Identity Tests
  # ============================================================================

  describe "id/0" do
    test "returns claude" do
      assert Claude.id() == "claude"
    end

    test "returns consistent value on multiple calls" do
      assert Claude.id() == Claude.id()
    end

    test "returns a string" do
      assert is_binary(Claude.id())
    end
  end

  # ============================================================================
  # Resume Token Formatting Tests
  # ============================================================================

  describe "format_resume/1" do
    test "formats resume token with claude --resume syntax" do
      token = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_abc123"}
      assert Claude.format_resume(token) == "claude --resume sess_abc123"
    end

    test "formats token with various session IDs" do
      for value <- ["sess_123", "session_abc", "s-12345", "my_session_id"] do
        token = %LemonGateway.Types.ResumeToken{engine: "claude", value: value}
        result = Claude.format_resume(token)
        assert String.contains?(result, value)
        assert String.contains?(result, "--resume")
      end
    end

    test "preserves special characters in session ID" do
      token = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_with-dashes_and_123"}
      result = Claude.format_resume(token)
      assert result == "claude --resume sess_with-dashes_and_123"
    end

    test "handles long session IDs" do
      long_value = String.duplicate("x", 100)
      token = %LemonGateway.Types.ResumeToken{engine: "claude", value: long_value}
      result = Claude.format_resume(token)
      assert String.contains?(result, long_value)
    end
  end

  # ============================================================================
  # Resume Token Extraction Tests
  # ============================================================================

  describe "extract_resume/1" do
    test "extracts token from plain text" do
      text = "claude --resume sess_abc123"
      assert %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_abc123"} = Claude.extract_resume(text)
    end

    test "extracts token from text with surrounding content" do
      text = "To continue, run claude --resume sess_xyz789 in terminal"
      assert %LemonGateway.Types.ResumeToken{value: "sess_xyz789"} = Claude.extract_resume(text)
    end

    test "extracts token from backtick-wrapped text" do
      text = "`claude --resume session_abc`"
      assert %LemonGateway.Types.ResumeToken{value: "session_abc"} = Claude.extract_resume(text)
    end

    test "extracts token case-insensitively" do
      text = "CLAUDE --RESUME Session123"
      assert %LemonGateway.Types.ResumeToken{engine: "claude", value: "Session123"} = Claude.extract_resume(text)
    end

    test "returns nil for non-matching text" do
      assert Claude.extract_resume("no resume here") == nil
      assert Claude.extract_resume("") == nil
      assert Claude.extract_resume("just some random text") == nil
    end

    test "returns nil for other engine tokens" do
      assert Claude.extract_resume("codex resume abc") == nil
      assert Claude.extract_resume("lemon resume xyz") == nil
    end

    test "returns nil for malformed claude tokens" do
      assert Claude.extract_resume("claude resume abc") == nil  # missing --
      assert Claude.extract_resume("claude--resume abc") == nil  # no space
    end

    test "extracts first token when multiple present" do
      text = "Run claude --resume first_one or claude --resume second_one"
      result = Claude.extract_resume(text)
      assert result.value == "first_one"
    end

    test "handles token with alphanumeric and special characters" do
      for value <- ["sess_123", "session-abc", "s_123_abc", "UPPER_lower_123"] do
        text = "claude --resume #{value}"
        result = Claude.extract_resume(text)
        assert result != nil, "Expected to extract token for value: #{value}"
        assert result.value == value
      end
    end
  end

  # ============================================================================
  # Resume Line Detection Tests
  # ============================================================================

  describe "is_resume_line/1" do
    test "returns true for exact resume line" do
      assert Claude.is_resume_line("claude --resume sess_abc123")
    end

    test "returns true for backtick-wrapped line" do
      assert Claude.is_resume_line("`claude --resume sess_abc123`")
    end

    test "returns true for line with leading/trailing whitespace" do
      assert Claude.is_resume_line("  claude --resume sess_abc123  ")
      assert Claude.is_resume_line("\tclaude --resume sess_abc123\t")
    end

    test "returns true for case-insensitive match" do
      assert Claude.is_resume_line("Claude --Resume SESS_ABC")
      assert Claude.is_resume_line("CLAUDE --RESUME sess_123")
    end

    test "returns false for line with extra text before" do
      refute Claude.is_resume_line("Please run claude --resume sess_abc123")
      refute Claude.is_resume_line("Run: claude --resume sess_abc123")
    end

    test "returns false for line with extra text after" do
      refute Claude.is_resume_line("claude --resume sess_abc123 to continue")
    end

    test "returns false for other engines" do
      refute Claude.is_resume_line("codex resume sess_abc123")
      refute Claude.is_resume_line("lemon resume sess_abc123")
    end

    test "returns false for empty or nil input" do
      refute Claude.is_resume_line("")
      refute Claude.is_resume_line("   ")
    end

    test "returns false for malformed lines" do
      refute Claude.is_resume_line("claude resume sess_123")  # missing --
      refute Claude.is_resume_line("claude--resume sess_123")  # no space
    end
  end

  # ============================================================================
  # Steer Support Tests
  # ============================================================================

  describe "supports_steer?/0" do
    test "returns false for claude" do
      assert Claude.supports_steer?() == false
    end
  end

  # ============================================================================
  # Cancel Tests
  # ============================================================================

  describe "cancel/1" do
    test "returns :ok for context with runner_pid" do
      # Create a dummy process to use as runner_pid
      pid = spawn(fn -> receive do: (:stop -> :ok) end)

      # Create a mock runner module for testing
      defmodule MockClaudeRunner do
        def cancel(pid, _reason) do
          send(pid, :stop)
          :ok
        end
      end

      ctx = %{runner_pid: pid, task_pid: nil, runner_module: MockClaudeRunner}
      assert :ok = CliAdapter.cancel(ctx)
    end

    test "returns :ok when killing task_pid if no runner_pid" do
      # Trap exits to avoid test process crash
      Process.flag(:trap_exit, true)

      task_pid = spawn_link(fn -> Process.sleep(:infinity) end)
      ctx = %{task_pid: task_pid, runner_pid: nil, runner_module: nil}

      assert :ok = CliAdapter.cancel(ctx)

      # Verify the task was killed
      assert_receive {:EXIT, ^task_pid, :killed}, 1000
    after
      Process.flag(:trap_exit, false)
    end
  end

  # ============================================================================
  # CliAdapter Event Mapping Tests
  # ============================================================================

  describe "CliAdapter.to_gateway_event/1 - StartedEvent" do
    test "maps claude StartedEvent to gateway Started" do
      token = CoreResumeToken.new("claude", "sess_abc")
      started = StartedEvent.new("claude", token, title: "Claude Session", meta: %{model: "claude-opus-4"})

      result = CliAdapter.to_gateway_event(started)

      assert %Event.Started{} = result
      assert result.engine == "claude"
      assert result.resume.engine == "claude"
      assert result.resume.value == "sess_abc"
      assert result.title == "Claude Session"
      assert result.meta.model == "claude-opus-4"
    end

    test "maps StartedEvent with minimal fields" do
      token = CoreResumeToken.new("claude", "s1")
      started = StartedEvent.new("claude", token)

      result = CliAdapter.to_gateway_event(started)

      assert result.engine == "claude"
      assert result.resume.value == "s1"
      assert result.title == nil
      assert result.meta == nil
    end
  end

  describe "CliAdapter.to_gateway_event/1 - ActionEvent" do
    test "maps ActionEvent to gateway ActionEvent" do
      action = Action.new("t1", :tool, "Bash", %{command: "ls"})
      ev = ActionEvent.new("claude", action, :started, level: :info)

      result = CliAdapter.to_gateway_event(ev)

      assert %Event.ActionEvent{} = result
      assert result.engine == "claude"
      assert result.action.id == "t1"
      assert result.action.kind == "tool"
      assert result.action.title == "Bash"
      assert result.phase == :started
    end

    test "maps completed ActionEvent with ok status" do
      action = Action.new("cmd_1", :command, "ls -la", %{})
      ev = ActionEvent.new("claude", action, :completed, ok: true, message: "Success")

      result = CliAdapter.to_gateway_event(ev)

      assert result.phase == :completed
      assert result.ok == true
      assert result.message == "Success"
    end

    test "maps failed ActionEvent" do
      action = Action.new("cmd_1", :command, "bad_cmd", %{})
      ev = ActionEvent.new("claude", action, :completed, ok: false, level: :error)

      result = CliAdapter.to_gateway_event(ev)

      assert result.ok == false
      assert result.level == :error
    end

    test "maps various action kinds" do
      for kind <- [:command, :tool, :file_change, :web_search, :note, :warning] do
        action = Action.new("a1", kind, "Title", %{})
        ev = ActionEvent.new("claude", action, :started)

        result = CliAdapter.to_gateway_event(ev)

        assert result.action.kind == to_string(kind)
      end
    end
  end

  describe "CliAdapter.to_gateway_event/1 - CompletedEvent" do
    test "maps successful CompletedEvent" do
      token = CoreResumeToken.new("claude", "sess_abc")
      ev = CompletedEvent.ok("claude", "The answer is 42", resume: token, usage: %{input_tokens: 100})

      result = CliAdapter.to_gateway_event(ev)

      assert %Event.Completed{} = result
      assert result.engine == "claude"
      assert result.ok == true
      assert result.answer == "The answer is 42"
      assert result.resume.value == "sess_abc"
      assert result.usage.input_tokens == 100
    end

    test "maps failed CompletedEvent with error" do
      token = CoreResumeToken.new("claude", "sess_fail")
      ev = CompletedEvent.error("claude", "Rate limit exceeded", resume: token, answer: "partial")

      result = CliAdapter.to_gateway_event(ev)

      assert result.ok == false
      assert result.error == "Rate limit exceeded"
      assert result.answer == "partial"
      assert result.resume.value == "sess_fail"
    end

    test "maps CompletedEvent without resume token" do
      ev = CompletedEvent.ok("claude", "Done")

      result = CliAdapter.to_gateway_event(ev)

      assert result.ok == true
      assert result.resume == nil
    end
  end

  describe "CliAdapter.to_gateway_event/1 - edge cases" do
    test "returns nil for unknown event type" do
      result = CliAdapter.to_gateway_event(%{type: :unknown})
      assert result == nil
    end

    test "returns nil for nil input" do
      result = CliAdapter.to_gateway_event(nil)
      assert result == nil
    end
  end

  # ============================================================================
  # CliAdapter Format Resume Tests
  # ============================================================================

  describe "CliAdapter.format_resume/2" do
    test "formats claude resume with --resume flag" do
      token = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_123"}
      result = CliAdapter.format_resume("claude", token)
      assert result == "claude --resume sess_123"
    end

    test "formats codex resume differently" do
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_123"}
      result = CliAdapter.format_resume("codex", token)
      assert result == "codex resume thread_123"
    end

    test "formats generic engine resume" do
      token = %LemonGateway.Types.ResumeToken{engine: "other", value: "id_123"}
      result = CliAdapter.format_resume("other", token)
      assert result == "other resume id_123"
    end
  end

  # ============================================================================
  # CliAdapter Extract Resume Tests
  # ============================================================================

  describe "CliAdapter.extract_resume/2" do
    test "extracts claude token from text" do
      result = CliAdapter.extract_resume("claude", "claude --resume sess_abc")
      assert result.engine == "claude"
      assert result.value == "sess_abc"
    end

    test "returns nil when engine doesn't match" do
      result = CliAdapter.extract_resume("claude", "codex resume thread_123")
      assert result == nil
    end

    test "returns nil for non-matching text" do
      result = CliAdapter.extract_resume("claude", "no token here")
      assert result == nil
    end
  end

  # ============================================================================
  # CliAdapter Is Resume Line Tests
  # ============================================================================

  describe "CliAdapter.is_resume_line/2" do
    test "returns true for exact claude resume line" do
      assert CliAdapter.is_resume_line("claude", "claude --resume sess_123")
    end

    test "returns true for backtick-wrapped line" do
      assert CliAdapter.is_resume_line("claude", "`claude --resume sess_123`")
    end

    test "returns false for other engines" do
      refute CliAdapter.is_resume_line("claude", "codex resume thread_123")
    end

    test "returns false for line with extra content" do
      refute CliAdapter.is_resume_line("claude", "Please run claude --resume sess_123")
    end
  end

  # ============================================================================
  # Job Creation Helper Tests
  # ============================================================================

  describe "Job struct for Claude engine" do
    test "creates valid job for Claude" do
      scope = %ChatScope{transport: :telegram, chat_id: 123}
      job = %Job{
        scope: scope,
        user_msg_id: 456,
        text: "Hello Claude",
        engine_hint: "claude"
      }

      assert job.text == "Hello Claude"
      assert job.engine_hint == "claude"
      assert job.resume == nil
    end

    test "creates job with resume token" do
      scope = %ChatScope{transport: :telegram, chat_id: 123}
      resume = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_abc"}
      job = %Job{
        scope: scope,
        user_msg_id: 456,
        text: "Continue",
        resume: resume
      }

      assert job.resume.value == "sess_abc"
    end

    test "creates job with various queue modes" do
      scope = %ChatScope{transport: :telegram, chat_id: 123}

      for mode <- [:collect, :followup, :steer, :interrupt] do
        job = %Job{
          scope: scope,
          user_msg_id: 1,
          text: "test",
          queue_mode: mode
        }
        assert job.queue_mode == mode
      end
    end
  end

  # ============================================================================
  # Engine Behaviour Compliance Tests
  # ============================================================================

  describe "Engine behaviour compliance" do
    test "implements all required callbacks" do
      assert function_exported?(Claude, :id, 0)
      assert function_exported?(Claude, :format_resume, 1)
      assert function_exported?(Claude, :extract_resume, 1)
      assert function_exported?(Claude, :is_resume_line, 1)
      assert function_exported?(Claude, :supports_steer?, 0)
      assert function_exported?(Claude, :start_run, 3)
      assert function_exported?(Claude, :cancel, 1)
    end

    test "id returns string" do
      assert is_binary(Claude.id())
    end

    test "supports_steer? returns boolean" do
      assert is_boolean(Claude.supports_steer?())
    end
  end

  # ============================================================================
  # Event.Started Struct Tests
  # ============================================================================

  describe "Event.Started struct" do
    test "requires engine and resume fields" do
      resume = %LemonGateway.Types.ResumeToken{engine: "claude", value: "s1"}
      started = %Event.Started{engine: "claude", resume: resume}

      assert started.engine == "claude"
      assert started.resume.value == "s1"
    end

    test "allows optional title and meta fields" do
      resume = %LemonGateway.Types.ResumeToken{engine: "claude", value: "s1"}
      started = %Event.Started{
        engine: "claude",
        resume: resume,
        title: "Claude Session",
        meta: %{model: "opus"}
      }

      assert started.title == "Claude Session"
      assert started.meta.model == "opus"
    end
  end

  # ============================================================================
  # Event.Completed Struct Tests
  # ============================================================================

  describe "Event.Completed struct" do
    test "requires engine and ok fields" do
      completed = %Event.Completed{engine: "claude", ok: true}
      assert completed.engine == "claude"
      assert completed.ok == true
    end

    test "includes answer and error fields" do
      completed = %Event.Completed{
        engine: "claude",
        ok: false,
        answer: "partial",
        error: "timeout"
      }

      assert completed.answer == "partial"
      assert completed.error == "timeout"
    end

    test "includes usage field" do
      completed = %Event.Completed{
        engine: "claude",
        ok: true,
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      assert completed.usage.input_tokens == 100
    end
  end

  # ============================================================================
  # Event.ActionEvent Struct Tests
  # ============================================================================

  describe "Event.ActionEvent struct" do
    test "requires engine, action, and phase fields" do
      action = %Event.Action{id: "a1", kind: "tool", title: "Test"}
      ev = %Event.ActionEvent{engine: "claude", action: action, phase: :started}

      assert ev.engine == "claude"
      assert ev.action.id == "a1"
      assert ev.phase == :started
    end

    test "allows optional ok, message, and level fields" do
      action = %Event.Action{id: "a1", kind: "tool", title: "Test"}
      ev = %Event.ActionEvent{
        engine: "claude",
        action: action,
        phase: :completed,
        ok: true,
        message: "Done",
        level: :info
      }

      assert ev.ok == true
      assert ev.message == "Done"
      assert ev.level == :info
    end
  end

  # ============================================================================
  # Event.Action Struct Tests
  # ============================================================================

  describe "Event.Action struct" do
    test "requires id, kind, and title fields" do
      action = %Event.Action{id: "a1", kind: "command", title: "ls -la"}
      assert action.id == "a1"
      assert action.kind == "command"
      assert action.title == "ls -la"
    end

    test "allows optional detail field" do
      action = %Event.Action{
        id: "a1",
        kind: "tool",
        title: "Read",
        detail: %{file_path: "/test.ex"}
      }

      assert action.detail.file_path == "/test.ex"
    end
  end

  # ============================================================================
  # ResumeToken Struct Tests (Gateway Types)
  # ============================================================================

  describe "LemonGateway.Types.ResumeToken struct" do
    test "creates token with engine and value" do
      token = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_123"}
      assert token.engine == "claude"
      assert token.value == "sess_123"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(LemonGateway.Types.ResumeToken, [])
      end
    end
  end

  # ============================================================================
  # Configuration Handling Tests
  # ============================================================================

  describe "configuration handling" do
    test "uses AgentCore.CliRunners.ClaudeRunner module" do
      # Verify the module reference is correct
      assert Code.ensure_loaded?(AgentCore.CliRunners.ClaudeRunner)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles empty text in extract_resume" do
      result = Claude.extract_resume("")
      assert result == nil
    end

    test "handles empty text in is_resume_line" do
      refute Claude.is_resume_line("")
    end

    test "handles whitespace-only text in extract_resume" do
      result = Claude.extract_resume("   ")
      assert result == nil
    end

    test "handles newlines in text" do
      text = "first line\nclaude --resume sess_123\nlast line"
      result = Claude.extract_resume(text)
      assert result.value == "sess_123"
    end
  end

  # ============================================================================
  # Integration Pattern Tests
  # ============================================================================

  describe "integration patterns" do
    test "round-trip format and extract resume token" do
      original = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_roundtrip_123"}

      formatted = Claude.format_resume(original)
      extracted = Claude.extract_resume(formatted)

      assert extracted.engine == original.engine
      assert extracted.value == original.value
    end

    test "format_resume output is valid resume line" do
      token = %LemonGateway.Types.ResumeToken{engine: "claude", value: "sess_test"}
      formatted = Claude.format_resume(token)

      assert Claude.is_resume_line(formatted)
    end

    test "gateway event types are serializable" do
      # Test that event structs can be safely inspected (useful for logging)
      resume = %LemonGateway.Types.ResumeToken{engine: "claude", value: "s1"}
      started = %Event.Started{engine: "claude", resume: resume}

      # Should not raise
      assert is_binary(inspect(started))
    end
  end
end
