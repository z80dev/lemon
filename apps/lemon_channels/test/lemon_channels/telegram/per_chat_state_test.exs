defmodule LemonChannels.Telegram.PerChatStateTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonCore.{ChatState, ResumeToken}

  test "switching_session reads core chat state structs" do
    state = %ChatState{last_engine: "codex", last_resume_token: "thread-1"}

    refute ResumeSelection.switching_session?(state, %ResumeToken{
             engine: "codex",
             value: "thread-1"
           })

    assert ResumeSelection.switching_session?(state, %ResumeToken{
             engine: "claude",
             value: "thread-1"
           })
  end
end
