defmodule LemonCore.ResumeTokenTest do
  use ExUnit.Case, async: true

  alias LemonCore.ResumeToken

  describe "new/2" do
    test "creates a resume token with engine and value" do
      token = ResumeToken.new("codex", "thread_abc123")
      assert %ResumeToken{engine: "codex", value: "thread_abc123"} = token
    end
  end

  describe "extract_resume/1" do
    test "extracts codex resume token from plain text" do
      assert %ResumeToken{engine: "codex", value: "thread_abc123"} =
               ResumeToken.extract_resume("codex resume thread_abc123")
    end

    test "extracts codex resume token with backticks" do
      assert %ResumeToken{engine: "codex", value: "thread_abc123"} =
               ResumeToken.extract_resume("`codex resume thread_abc123`")
    end

    test "extracts codex resume from surrounding text" do
      assert %ResumeToken{engine: "codex", value: "thread_abc123"} =
               ResumeToken.extract_resume("Please run `codex resume thread_abc123`")
    end

    test "extracts claude resume token" do
      assert %ResumeToken{engine: "claude", value: "session_xyz"} =
               ResumeToken.extract_resume("claude --resume session_xyz")
    end

    test "extracts claude resume with backticks" do
      assert %ResumeToken{engine: "claude", value: "session_xyz"} =
               ResumeToken.extract_resume("`claude --resume session_xyz`")
    end

    test "extracts kimi session token" do
      assert %ResumeToken{engine: "kimi", value: "session_kimi"} =
               ResumeToken.extract_resume("kimi --session session_kimi")
    end

    test "extracts opencode session token" do
      assert %ResumeToken{engine: "opencode", value: "ses_ABC123"} =
               ResumeToken.extract_resume("opencode --session ses_ABC123")
    end

    test "extracts opencode run session token" do
      assert %ResumeToken{engine: "opencode", value: "ses_XYZ"} =
               ResumeToken.extract_resume("opencode run --session ses_XYZ")
    end

    test "extracts pi session token" do
      assert %ResumeToken{engine: "pi", value: "my-token"} =
               ResumeToken.extract_resume("pi --session my-token")
    end

    test "extracts pi session token with quoted value" do
      assert %ResumeToken{engine: "pi", value: "my token with spaces"} =
               ResumeToken.extract_resume(~s(pi --session "my token with spaces"))
    end

    test "extracts lemon resume token" do
      assert %ResumeToken{engine: "lemon", value: "abc12345"} =
               ResumeToken.extract_resume("lemon resume abc12345")
    end

    test "returns nil when no resume token found" do
      assert nil == ResumeToken.extract_resume("No resume token here")
    end

    test "returns nil for empty string" do
      assert nil == ResumeToken.extract_resume("")
    end

    test "returns nil for non-string input" do
      assert nil == ResumeToken.extract_resume(123)
    end

    test "extracts first token when multiple engines present" do
      text = "codex resume thread_one\nclaude --resume session_two"

      assert %ResumeToken{engine: "codex", value: "thread_one"} =
               ResumeToken.extract_resume(text)
    end

    test "is case-insensitive for engine names" do
      assert %ResumeToken{engine: "codex", value: "thread_abc"} =
               ResumeToken.extract_resume("CODEX resume thread_abc")
    end
  end

  describe "extract_resume/2 (engine-specific)" do
    test "extracts token for specified engine" do
      assert %ResumeToken{engine: "codex", value: "abc"} =
               ResumeToken.extract_resume("codex resume abc", "codex")
    end

    test "returns nil when text contains different engine" do
      assert nil == ResumeToken.extract_resume("codex resume abc", "claude")
    end
  end

  describe "is_resume_line/1" do
    test "matches plain codex resume line" do
      assert ResumeToken.is_resume_line("codex resume thread_abc123")
    end

    test "matches backtick-wrapped codex resume line" do
      assert ResumeToken.is_resume_line("`codex resume thread_abc123`")
    end

    test "matches claude resume line" do
      assert ResumeToken.is_resume_line("claude --resume session_xyz")
    end

    test "matches backtick-wrapped claude resume line" do
      assert ResumeToken.is_resume_line("`claude --resume session_xyz`")
    end

    test "matches kimi session line" do
      assert ResumeToken.is_resume_line("kimi --session session_kimi")
    end

    test "matches lemon resume line" do
      assert ResumeToken.is_resume_line("lemon resume abc12345")
    end

    test "matches with surrounding whitespace" do
      assert ResumeToken.is_resume_line("  codex resume thread_abc123  ")
    end

    test "rejects line with surrounding text" do
      refute ResumeToken.is_resume_line("Please run codex resume abc")
    end

    test "rejects ordinary text" do
      refute ResumeToken.is_resume_line("Some other text")
    end

    test "rejects empty string" do
      refute ResumeToken.is_resume_line("")
    end

    test "returns false for non-string input" do
      refute ResumeToken.is_resume_line(nil)
    end
  end

  describe "is_resume_line/2 (engine-specific)" do
    test "matches for correct engine" do
      assert ResumeToken.is_resume_line("codex resume abc", "codex")
    end

    test "rejects for wrong engine" do
      refute ResumeToken.is_resume_line("codex resume abc", "claude")
    end
  end

  describe "format/1" do
    test "formats codex token" do
      token = ResumeToken.new("codex", "thread_abc123")
      assert ResumeToken.format(token) == "`codex resume thread_abc123`"
    end

    test "formats claude token" do
      token = ResumeToken.new("claude", "session_xyz")
      assert ResumeToken.format(token) == "`claude --resume session_xyz`"
    end

    test "formats kimi token" do
      token = ResumeToken.new("kimi", "session_kimi")
      assert ResumeToken.format(token) == "`kimi --session session_kimi`"
    end

    test "formats opencode token" do
      token = ResumeToken.new("opencode", "ses_ABC123")
      assert ResumeToken.format(token) == "`opencode --session ses_ABC123`"
    end

    test "formats pi token" do
      token = ResumeToken.new("pi", "simple-token")
      assert ResumeToken.format(token) == "`pi --session simple-token`"
    end

    test "formats pi token with spaces using quotes" do
      token = ResumeToken.new("pi", "token with spaces")
      assert ResumeToken.format(token) == "`pi --session \"token with spaces\"`"
    end

    test "formats lemon token" do
      token = ResumeToken.new("lemon", "abc12345")
      assert ResumeToken.format(token) == "`lemon resume abc12345`"
    end

    test "formats unknown engine with generic pattern" do
      token = ResumeToken.new("custom", "session_id")
      assert ResumeToken.format(token) == "`custom resume session_id`"
    end
  end

  describe "round-trip: format then extract" do
    test "codex token round-trips correctly" do
      original = ResumeToken.new("codex", "thread_abc123")
      formatted = ResumeToken.format(original)
      extracted = ResumeToken.extract_resume(formatted)
      assert extracted.engine == original.engine
      assert extracted.value == original.value
    end

    test "claude token round-trips correctly" do
      original = ResumeToken.new("claude", "session_xyz")
      formatted = ResumeToken.format(original)
      extracted = ResumeToken.extract_resume(formatted)
      assert extracted.engine == original.engine
      assert extracted.value == original.value
    end

    test "kimi token round-trips correctly" do
      original = ResumeToken.new("kimi", "session_kimi")
      formatted = ResumeToken.format(original)
      extracted = ResumeToken.extract_resume(formatted)
      assert extracted.engine == original.engine
      assert extracted.value == original.value
    end

    test "lemon token round-trips correctly" do
      original = ResumeToken.new("lemon", "abc12345")
      formatted = ResumeToken.format(original)
      extracted = ResumeToken.extract_resume(formatted)
      assert extracted.engine == original.engine
      assert extracted.value == original.value
    end
  end

  describe "JSON encoding" do
    test "encodes to JSON with only engine and value fields" do
      token = ResumeToken.new("codex", "thread_abc123")
      json = Jason.encode!(token)
      decoded = Jason.decode!(json)
      assert decoded == %{"engine" => "codex", "value" => "thread_abc123"}
    end
  end
end
