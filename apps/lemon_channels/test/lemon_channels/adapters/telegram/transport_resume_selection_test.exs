defmodule LemonChannels.Adapters.Telegram.TransportResumeSelectionTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonCore.ResumeToken

  test "extract_explicit_resume_and_strip removes the resume line and keeps prompt text" do
    {resume, stripped} =
      ResumeSelection.extract_explicit_resume_and_strip(
        "codex resume abc123\nContinue with the fix."
      )

    assert %ResumeToken{engine: "codex", value: "abc123"} = resume
    assert stripped == "Continue with the fix."
  end

  test "format helpers produce stable session references" do
    resume = %ResumeToken{engine: "claude", value: "token-123"}

    assert ResumeSelection.format_resume_line(resume) == "claude --resume token-123"
    assert ResumeSelection.format_session_ref(resume) == "claude: token-123"
  end
end
