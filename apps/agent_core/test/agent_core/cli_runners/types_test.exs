defmodule AgentCore.CliRunners.TypesTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    EventFactory,
    ResumeToken,
    StartedEvent
  }

  describe "ResumeToken" do
    test "creates a new token" do
      token = ResumeToken.new("codex", "thread_123")
      assert token.engine == "codex"
      assert token.value == "thread_123"
    end

    test "implements Jason.Encoder" do
      token = ResumeToken.new("codex", "thread_123")

      assert Jason.encode!(token) |> Jason.decode!() == %{
               "engine" => "codex",
               "value" => "thread_123"
             }
    end

    test "formats codex token correctly" do
      token = ResumeToken.new("codex", "thread_123")
      assert ResumeToken.format(token) == "`codex resume thread_123`"
    end

    test "formats claude token correctly" do
      token = ResumeToken.new("claude", "session_456")
      assert ResumeToken.format(token) == "`claude --resume session_456`"
    end

    test "formats unknown engine token" do
      token = ResumeToken.new("custom", "abc")
      assert ResumeToken.format(token) == "`custom resume abc`"
    end

    test "formats lemon token correctly" do
      token = ResumeToken.new("lemon", "abc12345")
      assert ResumeToken.format(token) == "`lemon resume abc12345`"
    end

    test "formats opencode token correctly" do
      token = ResumeToken.new("opencode", "ses_abc123")
      assert ResumeToken.format(token) == "`opencode --session ses_abc123`"
    end

    test "formats pi token correctly" do
      token = ResumeToken.new("pi", "session_1")
      assert ResumeToken.format(token) == "`pi --session session_1`"
    end
  end

  describe "ResumeToken.extract_resume/1" do
    test "extracts codex token from plain text" do
      token = ResumeToken.extract_resume("codex resume thread_abc123")
      assert token == %ResumeToken{engine: "codex", value: "thread_abc123"}
    end

    test "extracts codex token with backticks" do
      token = ResumeToken.extract_resume("Please run `codex resume thread_abc123`")
      assert token == %ResumeToken{engine: "codex", value: "thread_abc123"}
    end

    test "extracts claude token from plain text" do
      token = ResumeToken.extract_resume("claude --resume session_xyz")
      assert token == %ResumeToken{engine: "claude", value: "session_xyz"}
    end

    test "extracts claude token with backticks" do
      token = ResumeToken.extract_resume("Run `claude --resume session_xyz` to continue")
      assert token == %ResumeToken{engine: "claude", value: "session_xyz"}
    end

    test "extracts lemon token from plain text" do
      token = ResumeToken.extract_resume("lemon resume abc12345")
      assert token == %ResumeToken{engine: "lemon", value: "abc12345"}
    end

    test "extracts lemon token with backticks" do
      token = ResumeToken.extract_resume("Continue with `lemon resume abc12345`")
      assert token == %ResumeToken{engine: "lemon", value: "abc12345"}
    end

    test "extracts opencode token" do
      token = ResumeToken.extract_resume("opencode --session ses_494719016ffe85dkDMj0FPRbHK")
      assert %ResumeToken{engine: "opencode", value: value} = token
      assert String.starts_with?(value, "ses_")
    end

    test "extracts pi token (including quoted tokens)" do
      token = ResumeToken.extract_resume("pi --session s1")
      assert token == %ResumeToken{engine: "pi", value: "s1"}

      token = ResumeToken.extract_resume("pi --session \"~/pi sessions/s1.jsonl\"")
      assert token == %ResumeToken{engine: "pi", value: "~/pi sessions/s1.jsonl"}
    end

    test "returns nil when no token found" do
      assert ResumeToken.extract_resume("No token here") == nil
      assert ResumeToken.extract_resume("") == nil
    end

    test "handles case insensitivity" do
      assert ResumeToken.extract_resume("CODEX resume ABC") != nil
      assert ResumeToken.extract_resume("Claude --Resume XYZ") != nil
      assert ResumeToken.extract_resume("LEMON RESUME abc") != nil
      assert ResumeToken.extract_resume("OPENCODE --SESSION ses_abc") != nil
      assert ResumeToken.extract_resume("PI --SESSION s1") != nil
    end

    test "extracts first token when multiple present" do
      # Codex comes first in pattern list
      token = ResumeToken.extract_resume("codex resume abc123 and claude --resume xyz")
      assert token.engine == "codex"
      assert token.value == "abc123"
    end

    test "handles tokens with various ID formats" do
      # Underscores
      assert ResumeToken.extract_resume("codex resume thread_abc_123").value == "thread_abc_123"
      # Hyphens
      assert ResumeToken.extract_resume("claude --resume session-xyz-456").value ==
               "session-xyz-456"

      # Mixed
      assert ResumeToken.extract_resume("lemon resume abc-123_xyz").value == "abc-123_xyz"
    end
  end

  describe "ResumeToken.extract_resume/2" do
    test "extracts only matching engine" do
      text = "codex resume abc123 and claude --resume xyz"

      assert ResumeToken.extract_resume(text, "codex").value == "abc123"
      assert ResumeToken.extract_resume(text, "claude").value == "xyz"
      assert ResumeToken.extract_resume(text, "lemon") == nil
    end
  end

  describe "ResumeToken.is_resume_line/1" do
    test "returns true for plain codex resume line" do
      assert ResumeToken.is_resume_line("codex resume thread_abc123") == true
    end

    test "returns true for backticked codex resume line" do
      assert ResumeToken.is_resume_line("`codex resume thread_abc123`") == true
    end

    test "returns true for plain claude resume line" do
      assert ResumeToken.is_resume_line("claude --resume session_xyz") == true
    end

    test "returns true for backticked claude resume line" do
      assert ResumeToken.is_resume_line("`claude --resume session_xyz`") == true
    end

    test "returns true for plain lemon resume line" do
      assert ResumeToken.is_resume_line("lemon resume abc12345") == true
    end

    test "returns true for backticked lemon resume line" do
      assert ResumeToken.is_resume_line("`lemon resume abc12345`") == true
    end

    test "returns false for line with extra text before" do
      assert ResumeToken.is_resume_line("Please run codex resume abc") == false
    end

    test "returns false for line with extra text after" do
      assert ResumeToken.is_resume_line("codex resume abc to continue") == false
    end

    test "returns false for non-resume lines" do
      assert ResumeToken.is_resume_line("Some other text") == false
      assert ResumeToken.is_resume_line("") == false
    end

    test "handles whitespace" do
      assert ResumeToken.is_resume_line("  codex resume abc  ") == true
      assert ResumeToken.is_resume_line("\tclauded --resume xyz\n") == false
    end

    test "is case insensitive" do
      assert ResumeToken.is_resume_line("CODEX RESUME abc") == true
      assert ResumeToken.is_resume_line("Claude --Resume xyz") == true
    end

    test "matches opencode and pi resume lines" do
      assert ResumeToken.is_resume_line("opencode --session ses_abc123") == true
      assert ResumeToken.is_resume_line("`opencode run --session ses_abc123`") == true
      assert ResumeToken.is_resume_line("pi --session s1") == true
      assert ResumeToken.is_resume_line("`pi --session \"~/x y.jsonl\"`") == true
      assert ResumeToken.is_resume_line("Please run pi --session s1") == false
    end
  end

  describe "ResumeToken.is_resume_line/2" do
    test "returns true only for matching engine" do
      assert ResumeToken.is_resume_line("codex resume abc", "codex") == true
      assert ResumeToken.is_resume_line("codex resume abc", "claude") == false
      assert ResumeToken.is_resume_line("claude --resume xyz", "claude") == true
      assert ResumeToken.is_resume_line("claude --resume xyz", "codex") == false
    end
  end

  describe "Action" do
    test "creates action with default detail" do
      action = Action.new("cmd_1", :command, "ls -la")
      assert action.id == "cmd_1"
      assert action.kind == :command
      assert action.title == "ls -la"
      assert action.detail == %{}
    end

    test "creates action with detail" do
      detail = %{exit_code: 0, duration: 100}
      action = Action.new("cmd_1", :command, "ls -la", detail)
      assert action.detail == detail
    end
  end

  describe "StartedEvent" do
    test "creates event with required fields" do
      token = ResumeToken.new("codex", "thread_123")
      event = StartedEvent.new("codex", token)
      assert event.type == :started
      assert event.engine == "codex"
      assert event.resume == token
      assert event.title == nil
      assert event.meta == nil
    end

    test "implements Jason.Encoder (including nested ResumeToken)" do
      token = ResumeToken.new("codex", "thread_123")
      event = StartedEvent.new("codex", token)

      assert Jason.encode!(event) |> Jason.decode!() == %{
               "engine" => "codex",
               "meta" => nil,
               "resume" => %{"engine" => "codex", "value" => "thread_123"},
               "title" => nil,
               "type" => "started"
             }
    end

    test "creates event with optional fields" do
      token = ResumeToken.new("codex", "thread_123")
      event = StartedEvent.new("codex", token, title: "My Session", meta: %{foo: "bar"})
      assert event.title == "My Session"
      assert event.meta == %{foo: "bar"}
    end
  end

  describe "ActionEvent" do
    test "creates action event" do
      action = Action.new("cmd_1", :command, "ls -la")
      event = ActionEvent.new("codex", action, :started)
      assert event.type == :action
      assert event.engine == "codex"
      assert event.action == action
      assert event.phase == :started
    end

    test "creates completed action event with ok status" do
      action = Action.new("cmd_1", :command, "ls -la")
      event = ActionEvent.new("codex", action, :completed, ok: true)
      assert event.ok == true
    end
  end

  describe "CompletedEvent" do
    test "creates successful completion" do
      event = CompletedEvent.ok("codex", "Done!")
      assert event.type == :completed
      assert event.engine == "codex"
      assert event.ok == true
      assert event.answer == "Done!"
      assert event.error == nil
    end

    test "creates successful completion with resume" do
      token = ResumeToken.new("codex", "thread_123")
      event = CompletedEvent.ok("codex", "Done!", resume: token)
      assert event.resume == token
    end

    test "creates error completion" do
      event = CompletedEvent.error("codex", "Something went wrong")
      assert event.ok == false
      assert event.error == "Something went wrong"
      assert event.answer == ""
    end

    test "creates error completion with partial answer" do
      event = CompletedEvent.error("codex", "Failed", answer: "Partial result")
      assert event.answer == "Partial result"
    end
  end

  describe "EventFactory" do
    test "creates factory for engine" do
      factory = EventFactory.new("codex")
      assert factory.engine == "codex"
      assert factory.resume == nil
      assert factory.note_seq == 0
    end

    test "started caches resume token" do
      factory = EventFactory.new("codex")
      token = ResumeToken.new("codex", "thread_123")

      {event, factory} = EventFactory.started(factory, token, title: "Test")

      assert event.type == :started
      assert event.resume == token
      assert factory.resume == token
    end

    test "started validates engine match" do
      factory = EventFactory.new("codex")
      token = ResumeToken.new("claude", "session_123")

      assert_raise RuntimeError, ~r/engine mismatch/, fn ->
        EventFactory.started(factory, token)
      end
    end

    test "action_started creates started action" do
      factory = EventFactory.new("codex")
      {event, _factory} = EventFactory.action_started(factory, "cmd_1", :command, "ls")

      assert event.phase == :started
      assert event.action.id == "cmd_1"
      assert event.action.kind == :command
      assert event.action.title == "ls"
    end

    test "action_completed creates completed action" do
      factory = EventFactory.new("codex")
      {event, _factory} = EventFactory.action_completed(factory, "cmd_1", :command, "ls", true)

      assert event.phase == :completed
      assert event.ok == true
    end

    test "note creates warning note with auto-incrementing id" do
      factory = EventFactory.new("codex")

      {event1, factory} = EventFactory.note(factory, "First note")
      {event2, _factory} = EventFactory.note(factory, "Second note")

      assert event1.action.id == "note_0"
      assert event2.action.id == "note_1"
    end

    test "completed_ok uses cached resume token" do
      factory = EventFactory.new("codex")
      token = ResumeToken.new("codex", "thread_123")

      {_started, factory} = EventFactory.started(factory, token)
      {completed, _factory} = EventFactory.completed_ok(factory, "Done!")

      assert completed.resume == token
    end

    test "completed_ok allows overriding resume token" do
      factory = EventFactory.new("codex")
      token1 = ResumeToken.new("codex", "thread_123")
      token2 = ResumeToken.new("codex", "thread_456")

      {_started, factory} = EventFactory.started(factory, token1)
      {completed, _factory} = EventFactory.completed_ok(factory, "Done!", resume: token2)

      assert completed.resume == token2
    end
  end
end
