defmodule LemonCore.ResumeTokenTest do
  use ExUnit.Case, async: true

  alias LemonCore.ResumeToken

  test "format_plain/1 renders builtin engine syntax" do
    assert ResumeToken.format_plain(%ResumeToken{engine: "codex", value: "thread_123"}) ==
             "codex resume thread_123"

    assert ResumeToken.format_plain(%ResumeToken{engine: "claude", value: "sess_123"}) ==
             "claude --resume sess_123"

    assert ResumeToken.format_plain(%ResumeToken{engine: "kimi", value: "kimi_123"}) ==
             "kimi --session kimi_123"

    assert ResumeToken.format_plain(%ResumeToken{engine: "opencode", value: "ses_123"}) ==
             "opencode --session ses_123"

    assert ResumeToken.format_plain(%ResumeToken{engine: "pi", value: "needs spaces"}) ==
             ~s(pi --session "needs spaces")

    assert ResumeToken.format_plain(%ResumeToken{engine: "lemon", value: "abc123"}) ==
             "lemon resume abc123"
  end

  test "format_plain/1 falls back to generic syntax for unknown engines" do
    assert ResumeToken.format_plain(%ResumeToken{engine: "custom", value: "token"}) ==
             "custom resume token"
  end

  test "format/1 wraps format_plain/1 in backticks" do
    token = %ResumeToken{engine: "claude", value: "sess_123"}

    assert ResumeToken.format(token) == "`claude --resume sess_123`"
  end

  describe "new/2 and format/1" do
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
      assert %{engine: "codex", value: "thread_abc123"} = token
    end

    test "extracts codex token with backticks" do
      token = ResumeToken.extract_resume("Please run `codex resume thread_abc123`")
      assert %{engine: "codex", value: "thread_abc123"} = token
    end

    test "extracts claude token from plain text" do
      token = ResumeToken.extract_resume("claude --resume session_xyz")
      assert %{engine: "claude", value: "session_xyz"} = token
    end

    test "extracts claude token with backticks" do
      token = ResumeToken.extract_resume("Run `claude --resume session_xyz` to continue")
      assert %{engine: "claude", value: "session_xyz"} = token
    end

    test "extracts lemon token from plain text" do
      token = ResumeToken.extract_resume("lemon resume abc12345")
      assert %{engine: "lemon", value: "abc12345"} = token
    end

    test "extracts lemon token with backticks" do
      token = ResumeToken.extract_resume("Continue with `lemon resume abc12345`")
      assert %{engine: "lemon", value: "abc12345"} = token
    end

    test "extracts opencode token" do
      token = ResumeToken.extract_resume("opencode --session ses_494719016ffe85dkDMj0FPRbHK")
      assert %{engine: "opencode", value: value} = token
      assert String.starts_with?(value, "ses_")
    end

    test "extracts pi token (including quoted tokens)" do
      token = ResumeToken.extract_resume("pi --session s1")
      assert %{engine: "pi", value: "s1"} = token

      token = ResumeToken.extract_resume("pi --session \"~/pi sessions/s1.jsonl\"")
      assert %{engine: "pi", value: "~/pi sessions/s1.jsonl"} = token
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
      assert ResumeToken.extract_resume("kimi --session sess_xyz", "kimi").value == "sess_xyz"
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
      assert ResumeToken.is_resume_line("kimi --session sess_xyz", "kimi") == true
    end
  end
end
