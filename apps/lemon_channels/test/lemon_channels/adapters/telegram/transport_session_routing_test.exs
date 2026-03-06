defmodule LemonChannels.Adapters.Telegram.TransportSessionRoutingTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.SessionRouting
  alias LemonChannels.Telegram.ResumeIndexStore
  alias LemonCore.ChatScope
  alias LemonCore.SessionKey

  test "maybe_mark_new_session_pending annotates inbound when a matching pending /new exists" do
    chat_id = System.unique_integer([:positive])
    thread_id = System.unique_integer([:positive])

    inbound = %{meta: %{}, message: %{reply_to_id: nil}}

    annotated =
      SessionRouting.maybe_mark_new_session_pending(
        %{"run-1" => %{chat_id: chat_id, thread_id: thread_id}},
        chat_id,
        thread_id,
        inbound
      )

    assert annotated.meta[:new_session_pending] == true
    assert annotated.meta[:disable_auto_resume] == true
  end

  test "resolve_session_key follows reply-to session indices for the current generation" do
    account_id = "default"
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])
    reply_to_id = System.unique_integer([:positive])

    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}

    base_session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: account_id,
        peer_kind: :group,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id)
      })

    reply_session_key = base_session_key <> ":sub:reply"

    on_exit(fn ->
      _ = ResumeIndexStore.delete_thread(account_id, chat_id, topic_id, generation: :all)
    end)

    :ok =
      ResumeIndexStore.put_session(
        account_id,
        chat_id,
        topic_id,
        reply_to_id,
        reply_session_key,
        generation: 3
      )

    inbound = %{
      meta: %{agent_id: "default"},
      peer: %{kind: :group, thread_id: Integer.to_string(topic_id)},
      message: %{reply_to_id: reply_to_id}
    }

    assert {^reply_session_key, true} =
             SessionRouting.resolve_session_key(account_id, inbound, scope, %{}, 3)
  end

  test "maybe_index_telegram_msg_session stores normalized message ids for reply routing" do
    account_id = "default"
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])
    session_key = "telegram:test:session:#{System.unique_integer([:positive])}"
    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}

    on_exit(fn ->
      _ = ResumeIndexStore.delete_thread(account_id, chat_id, topic_id, generation: :all)
    end)

    assert :ok =
             SessionRouting.maybe_index_telegram_msg_session(
               account_id,
               scope,
               session_key,
               ["101", 102, nil, "102"],
               2
             )

    assert ResumeIndexStore.get_session(account_id, chat_id, topic_id, 101, generation: 2) ==
             session_key

    assert ResumeIndexStore.get_session(account_id, chat_id, topic_id, 102, generation: 2) ==
             session_key
  end
end
