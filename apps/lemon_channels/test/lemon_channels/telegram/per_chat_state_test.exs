defmodule LemonChannels.Telegram.PerChatStateTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonCore.{ChatState, ChatStateStore, ResumeToken}

  test "last_engine_hint reads core chat state structs" do
    session_key = "agent:test:telegram:default:chat:#{System.unique_integer([:positive])}"

    on_exit(fn -> ChatStateStore.delete(session_key) end)

    assert :ok =
             ChatStateStore.put(session_key, %ChatState{
               last_engine: "codex",
               last_resume_token: "thread-1"
             })

    assert PerChatState.last_engine_hint(session_key) == "codex"
  end

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
