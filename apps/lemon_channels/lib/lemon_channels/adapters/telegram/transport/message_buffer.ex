defmodule LemonChannels.Adapters.Telegram.Transport.MessageBuffer do
  @moduledoc """
  Message buffering and debounce logic for the Telegram transport.

  Handles the accumulation of non-command messages within a configurable
  debounce window so that rapid-fire user messages are coalesced into a single
  inbound submission.

  Functions here operate on the `buffers` map from GenServer state but do not
  mutate state directly -- they return the updated buffers (or a full state map
  update) so the caller can apply it.
  """

  alias LemonChannels.Adapters.Telegram.Transport.Commands

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Add an inbound message to the debounce buffer for its scope key.

  Returns the updated `state` map with `buffers` modified.
  """
  def enqueue_buffer(state, inbound) do
    key = Commands.scope_key(inbound)

    case Map.get(state.buffers, key) do
      nil ->
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

        buffer = %{
          inbound: inbound,
          messages: [Commands.message_entry(inbound)],
          timer_ref: timer_ref,
          debounce_ref: debounce_ref
        }

        %{state | buffers: Map.put(state.buffers, key, buffer)}

      buffer ->
        _ = Process.cancel_timer(buffer.timer_ref)
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

        messages = [Commands.message_entry(inbound) | buffer.messages]
        inbound_last = inbound

        buffer = %{
          buffer
          | inbound: inbound_last,
            messages: messages,
            timer_ref: timer_ref,
            debounce_ref: debounce_ref
        }

        %{state | buffers: Map.put(state.buffers, key, buffer)}
    end
  end

  @doc """
  Collapse the buffered messages into a single inbound and submit it.

  This merges multiple message entries into one text block, then delegates
  to the `submit_fn` callback (which should be `&submit_inbound_now/2`).

  Returns `:ok` (the submission side-effect is performed via the callback).
  """
  def submit_buffer(%{messages: messages, inbound: inbound_last}, submit_fn)
      when is_function(submit_fn, 1) do
    {joined_text, last_id, last_reply_to_text, last_reply_to_id} =
      Commands.join_messages(Enum.reverse(messages))

    inbound =
      inbound_last
      |> put_in([Access.key!(:message), :text], joined_text)
      |> put_in([Access.key!(:message), :id], to_string(last_id))
      |> put_in([Access.key!(:message), :reply_to_id], last_reply_to_id)
      |> put_in([Access.key!(:meta), :user_msg_id], last_id)
      |> put_in([Access.key!(:meta), :reply_to_text], last_reply_to_text)

    submit_fn.(inbound)
  end

  @doc """
  Drop any pending buffer for the given inbound's scope key (e.g. when a
  command like /new or /resume should flush pending text).

  Returns the updated state.
  """
  def drop_buffer_for(state, inbound) do
    key = Commands.scope_key(inbound)

    case Map.pop(state.buffers, key) do
      {nil, _buffers} ->
        state

      {buffer, buffers} ->
        _ = Process.cancel_timer(buffer.timer_ref)
        %{state | buffers: buffers}
    end
  end
end
