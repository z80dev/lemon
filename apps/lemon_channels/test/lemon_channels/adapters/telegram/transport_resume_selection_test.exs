defmodule LemonChannels.Adapters.Telegram.TransportResumeSelectionTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonChannels.Telegram.StateStore
  alias LemonCore.ResumeToken

  test "extract_explicit_resume_and_strip removes the resume line and keeps prompt text" do
    {resume, stripped} =
      ResumeSelection.extract_explicit_resume_and_strip(
        "codex resume abc123\nContinue with the fix."
      )

    assert %ResumeToken{engine: "codex", value: "abc123"} = resume
    assert stripped == "Continue with the fix."
  end

  test "extract_explicit_resume_and_strip also strips echo resume lines" do
    {resume, stripped} =
      ResumeSelection.extract_explicit_resume_and_strip(
        "echo resume session-123\nContinue with the fix."
      )

    assert %ResumeToken{engine: "echo", value: "session-123"} = resume
    assert stripped == "Continue with the fix."
  end

  test "extract_explicit_resume_and_strip does not treat engine-prefixed prompts as resume tokens" do
    text =
      "codex review comparing all five, give me an overview comparison, no tables in the response."

    assert {nil, ^text} = ResumeSelection.extract_explicit_resume_and_strip(text)
  end

  test "format helpers produce stable session references" do
    resume = %ResumeToken{engine: "claude", value: "token-123"}

    assert ResumeSelection.format_resume_line(resume) == "claude --resume token-123"
    assert ResumeSelection.format_session_ref(resume) == "claude: token-123"
  end

  test "format_resume_line/1 uses quoted pi syntax" do
    resume = %ResumeToken{engine: "pi", value: "token with spaces"}

    assert ResumeSelection.format_resume_line(resume) == ~s(pi --session "token with spaces")
  end

  test "handle_resume_command forwards prompt text with structured resume metadata" do
    account_id = "default"
    chat_id = 123
    thread_id = 456
    user_msg_id = 789

    on_exit(fn ->
      StateStore.delete_selected_resume({account_id, chat_id, thread_id})
    end)

    state = %{account_id: account_id}

    inbound = %{
      message: %{text: "/resume codex abc123 Continue with the fix."},
      meta: %{chat_id: chat_id, thread_id: thread_id}
    }

    callbacks = %{
      extract_chat_ids: fn _ -> {chat_id, thread_id} end,
      extract_message_ids: fn _ -> {chat_id, thread_id, user_msg_id} end,
      build_session_key: fn _state, _inbound, _scope ->
        "agent:default:telegram:default:dm:123"
      end,
      normalize_msg_id: fn id -> id end,
      send_system_message: fn _state, _chat_id, _thread_id, _reply_to_id, _text -> :ok end,
      submit_inbound_now: fn _state, submitted_inbound ->
        send(self(), {:submitted_inbound, submitted_inbound})
        state
      end
    }

    _ = ResumeSelection.handle_resume_command(state, inbound, callbacks)

    assert_receive {:submitted_inbound, submitted_inbound}
    assert submitted_inbound.message.text == "Continue with the fix."
    assert submitted_inbound.meta.resume == %ResumeToken{engine: "codex", value: "abc123"}
  end
end
