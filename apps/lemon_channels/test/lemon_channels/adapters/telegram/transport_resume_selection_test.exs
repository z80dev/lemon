defmodule LemonChannels.Adapters.Telegram.TransportResumeSelectionTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonChannels.Telegram.StateStore
  alias LemonCore.ResumeToken

  test "extract_explicit_resume_and_strip accepts native resume lines and keeps prompt text" do
    {resume, stripped} =
      ResumeSelection.extract_explicit_resume_and_strip(
        "lemon resume abc123\nContinue with the fix."
      )

    assert %ResumeToken{engine: "lemon", value: "abc123"} = resume
    assert stripped == "Continue with the fix."
  end

  test "extract_explicit_resume_and_strip ignores ordinary prose containing resume" do
    text = "please resume the migration tomorrow"

    assert {nil, ^text} = ResumeSelection.extract_explicit_resume_and_strip(text)
  end

  test "handle_resume_command reports session-not-found for unknown numeric selectors" do
    state = %{account_id: "default"}
    chat_id = 125
    thread_id = 458
    user_msg_id = 791
    parent = self()

    inbound = %{
      message: %{text: "/resume 9 keep going"},
      meta: %{chat_id: chat_id, thread_id: thread_id}
    }

    callbacks = %{
      extract_chat_ids: fn _ -> {chat_id, thread_id} end,
      extract_message_ids: fn _ -> {chat_id, thread_id, user_msg_id} end,
      build_session_key: fn _state, _inbound, _scope ->
        "agent:default:telegram:default:dm:125"
      end,
      normalize_msg_id: fn id -> id end,
      send_system_message: fn _state, _chat_id, _thread_id, _reply_to_id, text ->
        send(parent, {:system_message, text})
        :ok
      end,
      submit_inbound_now: fn _state, submitted_inbound ->
        send(parent, {:submitted_inbound, submitted_inbound})
        state
      end
    }

    assert state == ResumeSelection.handle_resume_command(state, inbound, callbacks)
    assert_receive {:system_message, message}
    assert message =~ "Couldn't find that session"
    refute message =~ "unsupported"
    refute_receive {:submitted_inbound, _}
  end

  test "handle_resume_command rejects vendor resumes with native guidance" do
    state = %{account_id: "default"}
    chat_id = 124
    thread_id = 457
    user_msg_id = 790
    parent = self()

    inbound = %{
      message: %{text: "/resume echo resume session-123"},
      meta: %{chat_id: chat_id, thread_id: thread_id}
    }

    callbacks = %{
      extract_chat_ids: fn _ -> {chat_id, thread_id} end,
      extract_message_ids: fn _ -> {chat_id, thread_id, user_msg_id} end,
      build_session_key: fn _state, _inbound, _scope ->
        "agent:default:telegram:default:dm:124"
      end,
      normalize_msg_id: fn id -> id end,
      send_system_message: fn _state, _chat_id, _thread_id, _reply_to_id, text ->
        send(parent, {:system_message, text})
        :ok
      end,
      submit_inbound_now: fn _state, submitted_inbound ->
        send(parent, {:submitted_inbound, submitted_inbound})
        state
      end
    }

    assert state == ResumeSelection.handle_resume_command(state, inbound, callbacks)
    assert_receive {:system_message, message}
    assert message =~ "Top-level resume only supports Lemon sessions."
    assert message =~ "`lemon resume <session-id>`"
    refute_receive {:submitted_inbound, _}
  end

  test "extract_explicit_resume_and_strip does not treat engine-prefixed prompts as resume tokens" do
    text =
      "codex review comparing all five, give me an overview comparison, no tables in the response."

    assert {nil, ^text} = ResumeSelection.extract_explicit_resume_and_strip(text)
  end

  test "format_session_ref/1 produces stable native session references" do
    resume = %ResumeToken{engine: "lemon", value: "token with spaces"}

    assert ResumeSelection.format_session_ref(resume) == "lemon: token with spaces"
  end

  test "handle_resume_command selects a native session and forwards prompt text with structured metadata" do
    account_id = "default"
    chat_id = 123
    thread_id = 456
    user_msg_id = 789

    on_exit(fn ->
      StateStore.delete_selected_resume({account_id, chat_id, thread_id})
    end)

    state = %{account_id: account_id}

    inbound = %{
      message: %{text: "/resume lemon abc123 Continue with the fix."},
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
    assert submitted_inbound.meta.resume == %ResumeToken{engine: "lemon", value: "abc123"}

    assert StateStore.get_selected_resume({account_id, chat_id, thread_id}) ==
             %ResumeToken{engine: "lemon", value: "abc123"}
  end
end
