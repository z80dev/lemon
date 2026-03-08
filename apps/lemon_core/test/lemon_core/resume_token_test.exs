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
end
