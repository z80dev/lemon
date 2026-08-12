defmodule LemonCliRunners.ResumeFormatsTest do
  @moduledoc """
  The vendor half of the resume contract.

  These are the cases `LemonCore.ResumeToken` used to carry as a hardcoded table
  of per-vendor regexes. They now run against whatever
  `LemonCliRunners.Application` registered at boot, which is the point: the
  platform prints and parses these lines without knowing any of these vendors.
  """
  use ExUnit.Case, async: true

  alias LemonCore.ResumeFormats
  alias LemonCore.ResumeToken

  test "every vendor CLI registers its resume format at boot" do
    engines = ResumeFormats.list_engines()

    for module <- LemonCliRunners.Application.subagents() do
      assert module.id() in engines
    end
  end

  describe "format_plain/1" do
    test "renders each vendor's own syntax" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "codex", value: "thread_123"}) ==
               "codex resume thread_123"

      assert ResumeToken.format_plain(%ResumeToken{engine: "claude", value: "sess_123"}) ==
               "claude --resume sess_123"

      assert ResumeToken.format_plain(%ResumeToken{engine: "kimi", value: "kimi_123"}) ==
               "kimi --session kimi_123"

      assert ResumeToken.format_plain(%ResumeToken{engine: "opencode", value: "ses_123"}) ==
               "opencode --session ses_123"

      assert ResumeToken.format_plain(%ResumeToken{engine: "pi", value: "session_1"}) ==
               "pi --session session_1"
    end

    test "quotes pi session paths that contain spaces" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "pi", value: "needs spaces"}) ==
               ~s(pi --session "needs spaces")
    end

    test "format/1 wraps the vendor syntax in backticks" do
      assert ResumeToken.format(ResumeToken.new("claude", "session_456")) ==
               "`claude --resume session_456`"
    end
  end

  describe "extract_resume/1" do
    test "extracts each vendor's token from plain text" do
      assert %{engine: "codex", value: "thread_abc123"} =
               ResumeToken.extract_resume("codex resume thread_abc123")

      assert %{engine: "claude", value: "session_xyz"} =
               ResumeToken.extract_resume("claude --resume session_xyz")

      assert %{engine: "kimi", value: "sess_xyz"} =
               ResumeToken.extract_resume("kimi --session sess_xyz")

      assert %{engine: "opencode", value: "ses_494719016ffe85dkDMj0FPRbHK"} =
               ResumeToken.extract_resume("opencode --session ses_494719016ffe85dkDMj0FPRbHK")

      assert %{engine: "pi", value: "s1"} = ResumeToken.extract_resume("pi --session s1")
    end

    test "extracts tokens surrounded by prose and backticks" do
      assert %{engine: "codex", value: "thread_abc123"} =
               ResumeToken.extract_resume("Please run `codex resume thread_abc123`")

      assert %{engine: "claude", value: "session_xyz"} =
               ResumeToken.extract_resume("Run `claude --resume session_xyz` to continue")
    end

    test "accepts the wider opencode invocations users paste" do
      assert %{engine: "opencode", value: "ses_abc123"} =
               ResumeToken.extract_resume("opencode run --session ses_abc123")

      assert %{engine: "opencode", value: "ses_abc123"} =
               ResumeToken.extract_resume("opencode -s ses_abc123")
    end

    test "unquotes pi session paths" do
      assert %{engine: "pi", value: "~/pi sessions/s1.jsonl"} =
               ResumeToken.extract_resume(~s(pi --session "~/pi sessions/s1.jsonl"))
    end

    test "handles case insensitivity" do
      assert ResumeToken.extract_resume("CODEX resume ABC") != nil
      assert ResumeToken.extract_resume("Claude --Resume XYZ") != nil
      assert ResumeToken.extract_resume("OPENCODE --SESSION ses_abc") != nil
      assert ResumeToken.extract_resume("PI --SESSION s1") != nil
    end

    test "extracts the first registered format that matches" do
      token = ResumeToken.extract_resume("codex resume abc123 and claude --resume xyz")

      assert token.engine == "codex"
      assert token.value == "abc123"
    end

    test "handles tokens with various id formats" do
      assert ResumeToken.extract_resume("codex resume thread_abc_123").value == "thread_abc_123"

      assert ResumeToken.extract_resume("claude --resume session-xyz-456").value ==
               "session-xyz-456"
    end

    test "returns nil when no token is present" do
      assert ResumeToken.extract_resume("No token here") == nil
    end
  end

  describe "extract_resume/2" do
    test "extracts only the requested engine" do
      text = "codex resume abc123 and claude --resume xyz"

      assert ResumeToken.extract_resume(text, "codex").value == "abc123"
      assert ResumeToken.extract_resume(text, "claude").value == "xyz"
      assert ResumeToken.extract_resume("kimi --session sess_xyz", "kimi").value == "sess_xyz"
      assert ResumeToken.extract_resume(text, "lemon") == nil
    end
  end

  describe "is_resume_line/1" do
    test "accepts a line that is nothing but a vendor resume command" do
      assert ResumeToken.is_resume_line("codex resume thread_abc123")
      assert ResumeToken.is_resume_line("`codex resume thread_abc123`")
      assert ResumeToken.is_resume_line("claude --resume session_xyz")
      assert ResumeToken.is_resume_line("`claude --resume session_xyz`")
      assert ResumeToken.is_resume_line("kimi --session sess_xyz")
      assert ResumeToken.is_resume_line("opencode --session ses_abc123")
      assert ResumeToken.is_resume_line("`opencode run --session ses_abc123`")
      assert ResumeToken.is_resume_line("pi --session s1")
      assert ResumeToken.is_resume_line(~s(`pi --session "~/x y.jsonl"`))
    end

    test "rejects a vendor resume command embedded in prose" do
      assert ResumeToken.is_resume_line("Please run codex resume abc") == false
      assert ResumeToken.is_resume_line("codex resume abc to continue") == false
      assert ResumeToken.is_resume_line("Please run pi --session s1") == false
      assert ResumeToken.is_resume_line("\tclauded --resume xyz\n") == false
    end

    test "handles whitespace and case" do
      assert ResumeToken.is_resume_line("  codex resume abc  ")
      assert ResumeToken.is_resume_line("CODEX RESUME abc")
      assert ResumeToken.is_resume_line("Claude --Resume xyz")
    end
  end

  describe "is_resume_line/2" do
    test "answers for the named engine only" do
      assert ResumeToken.is_resume_line("codex resume abc", "codex")
      assert ResumeToken.is_resume_line("codex resume abc", "claude") == false
      assert ResumeToken.is_resume_line("claude --resume xyz", "claude")
      assert ResumeToken.is_resume_line("claude --resume xyz", "codex") == false
      assert ResumeToken.is_resume_line("kimi --session sess_xyz", "kimi")
    end
  end

  describe "round trip" do
    test "every registered vendor format re-reads what it printed" do
      values = %{
        "codex" => "thread_abc123",
        "claude" => "session-xyz",
        "kimi" => "sess_1",
        "opencode" => "ses_abc123",
        "pi" => "~/pi sessions/s1.jsonl"
      }

      for module <- LemonCliRunners.Application.subagents() do
        engine = module.id()
        token = ResumeToken.new(engine, Map.fetch!(values, engine))
        line = ResumeToken.format_plain(token)

        assert ResumeToken.is_resume_line(line), "#{engine}: #{line} is not a resume line"
        assert ResumeToken.extract_resume(line) == token
        assert ResumeToken.extract_resume(line, engine) == token
      end
    end
  end
end
