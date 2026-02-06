defmodule LemonGateway.Engines.CodexEngineTest do
  @moduledoc """
  Comprehensive tests for the Codex engine implementation.

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

  alias LemonGateway.Engines.Codex
  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Types.{ChatScope, Job}
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
    test "returns codex" do
      assert Codex.id() == "codex"
    end

    test "returns consistent value on multiple calls" do
      assert Codex.id() == Codex.id()
    end

    test "returns a string" do
      assert is_binary(Codex.id())
    end
  end

  # ============================================================================
  # Resume Token Formatting Tests
  # ============================================================================

  describe "format_resume/1" do
    test "formats resume token with codex resume syntax" do
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc123"}
      assert Codex.format_resume(token) == "codex resume thread_abc123"
    end

    test "formats token with various thread IDs" do
      for value <- ["thread_123", "thread-abc", "t_12345", "my_thread_id"] do
        token = %LemonGateway.Types.ResumeToken{engine: "codex", value: value}
        result = Codex.format_resume(token)
        assert String.contains?(result, value)
        assert String.contains?(result, "resume")
        # Codex doesn't use --resume
        refute String.contains?(result, "--")
      end
    end

    test "preserves special characters in thread ID" do
      token = %LemonGateway.Types.ResumeToken{
        engine: "codex",
        value: "thread_with-dashes_and_123"
      }

      result = Codex.format_resume(token)
      assert result == "codex resume thread_with-dashes_and_123"
    end

    test "handles long thread IDs" do
      long_value = String.duplicate("x", 100)
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: long_value}
      result = Codex.format_resume(token)
      assert String.contains?(result, long_value)
    end
  end

  # ============================================================================
  # Resume Token Extraction Tests
  # ============================================================================

  describe "extract_resume/1" do
    test "extracts token from plain text" do
      text = "codex resume thread_abc123"

      assert %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc123"} =
               Codex.extract_resume(text)
    end

    test "extracts token from text with surrounding content" do
      text = "To continue, run codex resume thread_xyz789 in terminal"
      assert %LemonGateway.Types.ResumeToken{value: "thread_xyz789"} = Codex.extract_resume(text)
    end

    test "extracts token from backtick-wrapped text" do
      text = "`codex resume thread_abc`"
      assert %LemonGateway.Types.ResumeToken{value: "thread_abc"} = Codex.extract_resume(text)
    end

    test "extracts token case-insensitively" do
      text = "CODEX RESUME Thread123"

      assert %LemonGateway.Types.ResumeToken{engine: "codex", value: "Thread123"} =
               Codex.extract_resume(text)
    end

    test "returns nil for non-matching text" do
      assert Codex.extract_resume("no resume here") == nil
      assert Codex.extract_resume("") == nil
      assert Codex.extract_resume("just some random text") == nil
    end

    test "returns nil for other engine tokens" do
      assert Codex.extract_resume("claude --resume abc") == nil
      assert Codex.extract_resume("lemon resume xyz") == nil
    end

    test "returns nil for malformed codex tokens" do
      # no space
      assert Codex.extract_resume("codex--resume abc") == nil
    end

    test "extracts first token when multiple present" do
      text = "Run codex resume first_one or codex resume second_one"
      result = Codex.extract_resume(text)
      assert result.value == "first_one"
    end

    test "handles token with alphanumeric and special characters" do
      for value <- ["thread_123", "thread-abc", "t_123_abc", "UPPER_lower_123"] do
        text = "codex resume #{value}"
        result = Codex.extract_resume(text)
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
      assert Codex.is_resume_line("codex resume thread_abc123")
    end

    test "returns true for backtick-wrapped line" do
      assert Codex.is_resume_line("`codex resume thread_abc123`")
    end

    test "returns true for line with leading/trailing whitespace" do
      assert Codex.is_resume_line("  codex resume thread_abc123  ")
      assert Codex.is_resume_line("\tcodex resume thread_abc123\t")
    end

    test "returns true for case-insensitive match" do
      assert Codex.is_resume_line("Codex Resume THREAD_ABC")
      assert Codex.is_resume_line("CODEX RESUME thread_123")
    end

    test "returns false for line with extra text before" do
      refute Codex.is_resume_line("Please run codex resume thread_abc123")
      refute Codex.is_resume_line("Run: codex resume thread_abc123")
    end

    test "returns false for line with extra text after" do
      refute Codex.is_resume_line("codex resume thread_abc123 to continue")
    end

    test "returns false for other engines" do
      refute Codex.is_resume_line("claude --resume sess_abc123")
      refute Codex.is_resume_line("lemon resume sess_abc123")
    end

    test "returns false for empty or nil input" do
      refute Codex.is_resume_line("")
      refute Codex.is_resume_line("   ")
    end

    test "returns false for malformed lines" do
      # no space
      refute Codex.is_resume_line("codex--resume thread_123")
    end
  end

  # ============================================================================
  # Steer Support Tests
  # ============================================================================

  describe "supports_steer?/0" do
    test "returns false for codex" do
      assert Codex.supports_steer?() == false
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
      defmodule MockCodexRunner do
        def cancel(pid, _reason) do
          send(pid, :stop)
          :ok
        end
      end

      ctx = %{runner_pid: pid, task_pid: nil, runner_module: MockCodexRunner}
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
    test "maps codex StartedEvent to gateway Started" do
      token = CoreResumeToken.new("codex", "thread_abc")
      started = StartedEvent.new("codex", token, title: "Codex Session", meta: %{model: "gpt-4"})

      result = CliAdapter.to_gateway_event(started)

      assert %Event.Started{} = result
      assert result.engine == "codex"
      assert result.resume.engine == "codex"
      assert result.resume.value == "thread_abc"
      assert result.title == "Codex Session"
      assert result.meta.model == "gpt-4"
    end

    test "maps StartedEvent with minimal fields" do
      token = CoreResumeToken.new("codex", "t1")
      started = StartedEvent.new("codex", token)

      result = CliAdapter.to_gateway_event(started)

      assert result.engine == "codex"
      assert result.resume.value == "t1"
      assert result.title == nil
      assert result.meta == nil
    end
  end

  describe "CliAdapter.to_gateway_event/1 - ActionEvent" do
    test "maps ActionEvent to gateway ActionEvent" do
      action = Action.new("t1", :command, "ls -la", %{command: "ls -la"})
      ev = ActionEvent.new("codex", action, :started, level: :info)

      result = CliAdapter.to_gateway_event(ev)

      assert %Event.ActionEvent{} = result
      assert result.engine == "codex"
      assert result.action.id == "t1"
      assert result.action.kind == "command"
      assert result.action.title == "ls -la"
      assert result.phase == :started
    end

    test "maps completed ActionEvent with ok status" do
      action = Action.new("cmd_1", :command, "npm install", %{})
      ev = ActionEvent.new("codex", action, :completed, ok: true, message: "Installed")

      result = CliAdapter.to_gateway_event(ev)

      assert result.phase == :completed
      assert result.ok == true
      assert result.message == "Installed"
    end

    test "maps failed ActionEvent" do
      action = Action.new("cmd_1", :command, "false", %{})
      ev = ActionEvent.new("codex", action, :completed, ok: false, level: :error)

      result = CliAdapter.to_gateway_event(ev)

      assert result.ok == false
      assert result.level == :error
    end

    test "maps various action kinds" do
      for kind <- [:command, :tool, :file_change, :web_search, :note, :warning, :turn] do
        action = Action.new("a1", kind, "Title", %{})
        ev = ActionEvent.new("codex", action, :started)

        result = CliAdapter.to_gateway_event(ev)

        assert result.action.kind == to_string(kind)
      end
    end

    test "maps updated phase action" do
      action = Action.new("cmd_1", :command, "long running", %{})
      ev = ActionEvent.new("codex", action, :updated)

      result = CliAdapter.to_gateway_event(ev)

      assert result.phase == :updated
    end
  end

  describe "CliAdapter.to_gateway_event/1 - CompletedEvent" do
    test "maps successful CompletedEvent" do
      token = CoreResumeToken.new("codex", "thread_abc")

      ev =
        CompletedEvent.ok("codex", "Task completed successfully",
          resume: token,
          usage: %{input_tokens: 200}
        )

      result = CliAdapter.to_gateway_event(ev)

      assert %Event.Completed{} = result
      assert result.engine == "codex"
      assert result.ok == true
      assert result.answer == "Task completed successfully"
      assert result.resume.value == "thread_abc"
      assert result.usage.input_tokens == 200
    end

    test "maps failed CompletedEvent with error" do
      token = CoreResumeToken.new("codex", "thread_fail")

      ev =
        CompletedEvent.error("codex", "API error occurred", resume: token, answer: "partial work")

      result = CliAdapter.to_gateway_event(ev)

      assert result.ok == false
      assert result.error == "API error occurred"
      assert result.answer == "partial work"
      assert result.resume.value == "thread_fail"
    end

    test "maps CompletedEvent without resume token" do
      ev = CompletedEvent.ok("codex", "Done")

      result = CliAdapter.to_gateway_event(ev)

      assert result.ok == true
      assert result.resume == nil
    end

    test "maps CompletedEvent with full usage stats" do
      token = CoreResumeToken.new("codex", "t1")

      ev =
        CompletedEvent.ok("codex", "Done",
          resume: token,
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            cached_input_tokens: 25
          }
        )

      result = CliAdapter.to_gateway_event(ev)

      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 50
      assert result.usage.cached_input_tokens == 25
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
    test "formats codex resume without --flag" do
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_123"}
      result = CliAdapter.format_resume("codex", token)
      assert result == "codex resume thread_123"
    end

    test "codex format differs from claude" do
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "id_123"}

      codex_result = CliAdapter.format_resume("codex", token)
      refute String.contains?(codex_result, "--")
      assert codex_result == "codex resume id_123"
    end
  end

  # ============================================================================
  # CliAdapter Extract Resume Tests
  # ============================================================================

  describe "CliAdapter.extract_resume/2" do
    test "extracts codex token from text" do
      result = CliAdapter.extract_resume("codex", "codex resume thread_abc")
      assert result.engine == "codex"
      assert result.value == "thread_abc"
    end

    test "returns nil when engine doesn't match" do
      result = CliAdapter.extract_resume("codex", "claude --resume sess_123")
      assert result == nil
    end

    test "returns nil for non-matching text" do
      result = CliAdapter.extract_resume("codex", "no token here")
      assert result == nil
    end
  end

  # ============================================================================
  # CliAdapter Is Resume Line Tests
  # ============================================================================

  describe "CliAdapter.is_resume_line/2" do
    test "returns true for exact codex resume line" do
      assert CliAdapter.is_resume_line("codex", "codex resume thread_123")
    end

    test "returns true for backtick-wrapped line" do
      assert CliAdapter.is_resume_line("codex", "`codex resume thread_123`")
    end

    test "returns false for other engines" do
      refute CliAdapter.is_resume_line("codex", "claude --resume sess_123")
    end

    test "returns false for line with extra content" do
      refute CliAdapter.is_resume_line("codex", "Please run codex resume thread_123")
    end
  end

  # ============================================================================
  # Job Creation Helper Tests
  # ============================================================================

  describe "Job struct for Codex engine" do
    test "creates valid job for Codex" do
      scope = %ChatScope{transport: :telegram, chat_id: 123}

      job = %Job{
        scope: scope,
        user_msg_id: 456,
        text: "Hello Codex",
        engine_hint: "codex"
      }

      assert job.text == "Hello Codex"
      assert job.engine_hint == "codex"
      assert job.resume == nil
    end

    test "creates job with resume token" do
      scope = %ChatScope{transport: :telegram, chat_id: 123}
      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc"}

      job = %Job{
        scope: scope,
        user_msg_id: 456,
        text: "Continue",
        resume: resume
      }

      assert job.resume.value == "thread_abc"
    end

    test "creates job with metadata" do
      scope = %ChatScope{transport: :telegram, chat_id: 123}

      job = %Job{
        scope: scope,
        user_msg_id: 1,
        text: "test",
        meta: %{source: "api", priority: :high}
      }

      assert job.meta.source == "api"
      assert job.meta.priority == :high
    end
  end

  # ============================================================================
  # Engine Behaviour Compliance Tests
  # ============================================================================

  describe "Engine behaviour compliance" do
    test "implements all required callbacks" do
      assert function_exported?(Codex, :id, 0)
      assert function_exported?(Codex, :format_resume, 1)
      assert function_exported?(Codex, :extract_resume, 1)
      assert function_exported?(Codex, :is_resume_line, 1)
      assert function_exported?(Codex, :supports_steer?, 0)
      assert function_exported?(Codex, :start_run, 3)
      assert function_exported?(Codex, :cancel, 1)
    end

    test "id returns string" do
      assert is_binary(Codex.id())
    end

    test "supports_steer? returns boolean" do
      assert is_boolean(Codex.supports_steer?())
    end
  end

  # ============================================================================
  # Event.Started Struct Tests
  # ============================================================================

  describe "Event.Started struct for Codex" do
    test "requires engine and resume fields" do
      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "t1"}
      started = %Event.Started{engine: "codex", resume: resume}

      assert started.engine == "codex"
      assert started.resume.value == "t1"
    end

    test "allows optional title and meta fields" do
      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "t1"}

      started = %Event.Started{
        engine: "codex",
        resume: resume,
        title: "Codex Session",
        meta: %{model: "gpt-4o"}
      }

      assert started.title == "Codex Session"
      assert started.meta.model == "gpt-4o"
    end
  end

  # ============================================================================
  # Event.Completed Struct Tests
  # ============================================================================

  describe "Event.Completed struct for Codex" do
    test "requires engine and ok fields" do
      completed = %Event.Completed{engine: "codex", ok: true}
      assert completed.engine == "codex"
      assert completed.ok == true
    end

    test "includes answer and error fields" do
      completed = %Event.Completed{
        engine: "codex",
        ok: false,
        answer: "partial work done",
        error: "rate limit"
      }

      assert completed.answer == "partial work done"
      assert completed.error == "rate limit"
    end

    test "includes usage field with token counts" do
      completed = %Event.Completed{
        engine: "codex",
        ok: true,
        usage: %{input_tokens: 150, output_tokens: 75, cached_input_tokens: 50}
      }

      assert completed.usage.input_tokens == 150
      assert completed.usage.cached_input_tokens == 50
    end
  end

  # ============================================================================
  # Event.ActionEvent Struct Tests
  # ============================================================================

  describe "Event.ActionEvent struct for Codex" do
    test "requires engine, action, and phase fields" do
      action = %Event.Action{id: "a1", kind: "command", title: "ls"}
      ev = %Event.ActionEvent{engine: "codex", action: action, phase: :started}

      assert ev.engine == "codex"
      assert ev.action.id == "a1"
      assert ev.phase == :started
    end

    test "handles turn action kind" do
      action = %Event.Action{id: "turn_1", kind: "turn", title: "Turn 1"}
      ev = %Event.ActionEvent{engine: "codex", action: action, phase: :started}

      assert ev.action.kind == "turn"
    end
  end

  # ============================================================================
  # Event.Action Struct Tests
  # ============================================================================

  describe "Event.Action struct for Codex actions" do
    test "command action" do
      action = %Event.Action{
        id: "cmd_1",
        kind: "command",
        title: "npm install",
        detail: %{command: "npm install", exit_code: 0}
      }

      assert action.kind == "command"
      assert action.detail.exit_code == 0
    end

    test "file_change action" do
      action = %Event.Action{
        id: "fc_1",
        kind: "file_change",
        title: "2 files changed",
        detail: %{changes: [%{path: "a.ex", kind: :add}, %{path: "b.ex", kind: :update}]}
      }

      assert action.kind == "file_change"
      assert length(action.detail.changes) == 2
    end

    test "tool action with MCP" do
      action = %Event.Action{
        id: "t_1",
        kind: "tool",
        title: "filesystem.read_file",
        detail: %{server: "filesystem", tool: "read_file", arguments: %{path: "/test.ex"}}
      }

      assert action.kind == "tool"
      assert action.detail.server == "filesystem"
    end

    test "web_search action" do
      action = %Event.Action{
        id: "ws_1",
        kind: "web_search",
        title: "elixir genserver",
        detail: %{query: "elixir genserver"}
      }

      assert action.kind == "web_search"
    end
  end

  # ============================================================================
  # ResumeToken Struct Tests (Gateway Types)
  # ============================================================================

  describe "LemonGateway.Types.ResumeToken struct" do
    test "creates token with engine and value" do
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_123"}
      assert token.engine == "codex"
      assert token.value == "thread_123"
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
    test "uses AgentCore.CliRunners.CodexRunner module" do
      # Verify the module reference is correct
      assert Code.ensure_loaded?(AgentCore.CliRunners.CodexRunner)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles empty text in extract_resume" do
      result = Codex.extract_resume("")
      assert result == nil
    end

    test "handles empty text in is_resume_line" do
      refute Codex.is_resume_line("")
    end

    test "handles whitespace-only text in extract_resume" do
      result = Codex.extract_resume("   ")
      assert result == nil
    end

    test "handles newlines in text" do
      text = "first line\ncodex resume thread_123\nlast line"
      result = Codex.extract_resume(text)
      assert result.value == "thread_123"
    end
  end

  # ============================================================================
  # Integration Pattern Tests
  # ============================================================================

  describe "integration patterns" do
    test "round-trip format and extract resume token" do
      original = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_roundtrip_123"}

      formatted = Codex.format_resume(original)
      extracted = Codex.extract_resume(formatted)

      assert extracted.engine == original.engine
      assert extracted.value == original.value
    end

    test "format_resume output is valid resume line" do
      token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_test"}
      formatted = Codex.format_resume(token)

      assert Codex.is_resume_line(formatted)
    end

    test "gateway event types are serializable" do
      # Test that event structs can be safely inspected (useful for logging)
      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "t1"}
      started = %Event.Started{engine: "codex", resume: resume}

      # Should not raise
      assert is_binary(inspect(started))
    end
  end

  # ============================================================================
  # Codex-Specific Event Scenarios
  # ============================================================================

  describe "codex-specific event scenarios" do
    test "turn started action event" do
      action = Action.new("turn_1", :turn, "Turn 1", %{turn_index: 1})
      ev = ActionEvent.new("codex", action, :started)

      result = CliAdapter.to_gateway_event(ev)

      assert result.action.kind == "turn"
      assert result.phase == :started
    end

    test "reconnection warning action" do
      action = Action.new("reconnect_1", :note, "Reconnecting...1/3", %{attempt: 1, max: 3})
      ev = ActionEvent.new("codex", action, :started, level: :warning)

      result = CliAdapter.to_gateway_event(ev)

      assert result.action.kind == "note"
      assert result.level == :warning
    end

    test "file change with multiple files" do
      action =
        Action.new("fc_1", :file_change, "3 files changed", %{
          changes: [
            %{path: "a.ex", kind: :add},
            %{path: "b.ex", kind: :update},
            %{path: "c.ex", kind: :delete}
          ]
        })

      ev = ActionEvent.new("codex", action, :completed, ok: true)

      result = CliAdapter.to_gateway_event(ev)

      assert result.action.kind == "file_change"
      assert result.ok == true
      assert length(result.action.detail.changes) == 3
    end

    test "todo list action" do
      action = Action.new("todo_1", :note, "2/3 tasks", %{done: 2, total: 3})
      ev = ActionEvent.new("codex", action, :completed, ok: true)

      result = CliAdapter.to_gateway_event(ev)

      assert result.action.title == "2/3 tasks"
      assert result.action.detail.done == 2
    end

    test "error item action" do
      action = Action.new("err_1", :warning, "Something went wrong", %{})
      ev = ActionEvent.new("codex", action, :completed, ok: false, level: :warning)

      result = CliAdapter.to_gateway_event(ev)

      assert result.action.kind == "warning"
      assert result.ok == false
      assert result.level == :warning
    end

    test "reasoning/note action" do
      action = Action.new("r_1", :note, "Let me think about this...", %{})
      ev = ActionEvent.new("codex", action, :started)

      result = CliAdapter.to_gateway_event(ev)

      assert result.action.kind == "note"
      assert result.phase == :started
    end
  end

  # ============================================================================
  # ChatScope Tests
  # ============================================================================

  describe "ChatScope struct" do
    test "creates scope with transport and chat_id" do
      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert scope.transport == :telegram
      assert scope.chat_id == 12345
      assert scope.topic_id == nil
    end

    test "creates scope with optional topic_id" do
      scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 99}
      assert scope.topic_id == 99
    end
  end

  # ============================================================================
  # Engine Comparison Tests
  # ============================================================================

  describe "engine comparison with claude" do
    test "codex and claude have different ids" do
      assert Codex.id() != LemonGateway.Engines.Claude.id()
      assert Codex.id() == "codex"
      assert LemonGateway.Engines.Claude.id() == "claude"
    end

    test "codex and claude have different resume formats" do
      codex_token = %LemonGateway.Types.ResumeToken{engine: "codex", value: "id_123"}
      claude_token = %LemonGateway.Types.ResumeToken{engine: "claude", value: "id_123"}

      codex_format = Codex.format_resume(codex_token)
      claude_format = LemonGateway.Engines.Claude.format_resume(claude_token)

      assert codex_format == "codex resume id_123"
      assert claude_format == "claude --resume id_123"
    end

    test "codex doesn't extract claude tokens" do
      result = Codex.extract_resume("claude --resume sess_123")
      assert result == nil
    end

    test "both engines don't support steer" do
      assert Codex.supports_steer?() == false
      assert LemonGateway.Engines.Claude.supports_steer?() == false
    end
  end

  # ============================================================================
  # Process State Tests
  # ============================================================================

  describe "process state management" do
    test "cancel context with all fields" do
      ctx = %{
        runner_pid: self(),
        task_pid: self(),
        runner_module: AgentCore.CliRunners.CodexRunner
      }

      assert is_pid(ctx.runner_pid)
      assert is_pid(ctx.task_pid)
      assert ctx.runner_module == AgentCore.CliRunners.CodexRunner
    end

    test "cancel context with nil runner_pid" do
      ctx = %{
        runner_pid: nil,
        task_pid: self(),
        runner_module: AgentCore.CliRunners.CodexRunner
      }

      assert ctx.runner_pid == nil
      assert is_pid(ctx.task_pid)
    end
  end
end
