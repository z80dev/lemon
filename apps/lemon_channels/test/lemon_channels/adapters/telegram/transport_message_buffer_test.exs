defmodule LemonChannels.Adapters.Telegram.TransportMessageBufferTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer

  test "rapid messages in one scope are debounced into one buffer" do
    state = base_state()
    scope_chat = 500

    first = inbound_message(scope_chat, 1, "first")
    second = inbound_message(scope_chat, 2, "second")

    state = MessageBuffer.enqueue_buffer(state, first)
    state = MessageBuffer.enqueue_buffer(state, second)

    buffer = buffer_for(state, first)

    assert Enum.map(buffer.messages, & &1.text) == ["second", "first"]
    assert buffer.inbound == second
    assert length(buffer.messages) == 2

    MessageBuffer.drop_buffer_for(state, second)
  end

  test "buffer timer ref is replaced when messages arrive rapidly" do
    state = base_state(1_000)
    scope_chat = 501

    first = inbound_message(scope_chat, 11, "a")
    second = inbound_message(scope_chat, 12, "b")

    state = MessageBuffer.enqueue_buffer(state, first)
    buffer_before = buffer_for(state, first)
    timer_before = buffer_before.timer_ref
    assert :erlang.read_timer(timer_before) > 0

    state = MessageBuffer.enqueue_buffer(state, second)
    buffer_after = buffer_for(state, second)
    timer_after = buffer_after.timer_ref

    assert timer_before != timer_after
    assert :erlang.cancel_timer(timer_before) == false
    assert is_integer(:erlang.read_timer(timer_after))

    MessageBuffer.drop_buffer_for(state, second)
  end

  test "merge order preserves oldest-to-newest text with newest reply metadata" do
    state = base_state()
    scope_chat = 502

    first =
      inbound_message(scope_chat, 21, "first",
        reply_to_id: 9001,
        reply_to_text: "old",
        user_msg_id: 210
      )

    second =
      inbound_message(scope_chat, 22, "second",
        reply_to_id: 9002,
        reply_to_text: "middle",
        user_msg_id: 220
      )

    third =
      inbound_message(scope_chat, 23, "third",
        reply_to_id: 9003,
        reply_to_text: "latest",
        user_msg_id: 230
      )

    state = MessageBuffer.enqueue_buffer(state, first)
    state = MessageBuffer.enqueue_buffer(state, second)
    state = MessageBuffer.enqueue_buffer(state, third)

    buffer = buffer_for(state, third)

    MessageBuffer.submit_buffer(buffer, fn inbound ->
      send(self(), {:submitted, inbound})
    end)

    assert_receive {:submitted, submitted}, 200

    assert submitted.message.text == "first\n\nsecond\n\nthird"
    assert submitted.message.reply_to_id == 9003
    assert submitted.meta[:reply_to_text] == "latest"
    assert submitted.meta[:user_msg_id] == 230
    assert submitted.message.id == "23"

    MessageBuffer.drop_buffer_for(state, third)
  end

  test "drop_buffer_for removes only the specified scope" do
    state = base_state()

    first_scope = inbound_message(600, 31, "first")
    second_scope = inbound_message(601, 41, "second")

    state =
      state
      |> MessageBuffer.enqueue_buffer(first_scope)
      |> MessageBuffer.enqueue_buffer(second_scope)

    assert map_size(state.buffers) == 2

    state = MessageBuffer.drop_buffer_for(state, first_scope)
    refute Map.has_key?(state.buffers, Commands.scope_key(first_scope))
    assert Map.has_key?(state.buffers, Commands.scope_key(second_scope))
    assert map_size(state.buffers) == 1
  end

  test "same chat but different topics buffer separately" do
    state = base_state()
    first_topic = inbound_message(700, 51, "topic one", thread_id: 111)
    second_topic = inbound_message(700, 52, "topic two", thread_id: 222)

    state =
      state
      |> MessageBuffer.enqueue_buffer(first_topic)
      |> MessageBuffer.enqueue_buffer(second_topic)

    assert map_size(state.buffers) == 2
    assert Map.has_key?(state.buffers, Commands.scope_key(first_topic))
    assert Map.has_key?(state.buffers, Commands.scope_key(second_topic))
  end

  defp base_state(debounce_ms \\ 5_000) do
    %{buffers: %{}, debounce_ms: debounce_ms}
  end

  defp buffer_for(state, inbound) do
    key = Commands.scope_key(inbound)
    state.buffers[key]
  end

  defp inbound_message(chat_id, message_id, text, opts \\ []) do
    thread_id = Keyword.get(opts, :thread_id)

    %{
      peer: %{
        id: Integer.to_string(chat_id),
        thread_id: thread_id && Integer.to_string(thread_id)
      },
      message: %{
        id: Integer.to_string(message_id),
        text: text,
        reply_to_id: Keyword.get(opts, :reply_to_id)
      },
      meta: %{
        chat_id: chat_id,
        topic_id: thread_id,
        user_msg_id: Keyword.get(opts, :user_msg_id, message_id),
        reply_to_text: Keyword.get(opts, :reply_to_text)
      }
    }
  end
end
