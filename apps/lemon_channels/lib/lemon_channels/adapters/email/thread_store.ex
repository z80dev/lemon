defmodule LemonChannels.Adapters.Email.ThreadStore do
  @moduledoc """
  Per-thread state for the email adapter: which thread a message id belongs to,
  and what a reply on that thread needs in order to thread correctly.

  ## Why this exists

  Two independent reasons, either of which would justify it on its own.

  **Stateless resolution cannot stitch a chain it meets out of order.**
  `LemonChannels.Adapters.Email.thread_id/1` picks the oldest ancestor named in
  the message itself, which is correct for a well-behaved client. It is wrong
  the moment the first message the adapter sees is the *middle* of a chain —
  message C referencing B and A arrives first and seeds thread "A"; if a client
  then sends B naming only A, both land together only because A happens to be
  named in both. A client that trims `References` to just its parent breaks
  that, and the conversation splits in two. Recording `message id → thread id`
  as messages arrive closes the gap: any later message naming *any* known
  ancestor joins the existing thread.

  **Outbound has nowhere else to get its headers.**
  `LemonChannels.OutboundPayload` carries the recipient, a thread id and the id
  being replied to, but no `Subject` and no `References` chain — nor should it,
  since those are email's business and not the platform's. Without persisted
  state a reply would have to invent a subject and send an empty `References`,
  which is the difference between a reply that lands inside the recipient's
  existing conversation and one that starts a new one.

  ## Storage

  Two `LemonCore.Store` tables, carried over unchanged from
  `LemonGateway.Transports.Email` so an existing deployment's threads survive
  the cutover:

    * `:email_message_threads` — `message_id => %{"thread_id" => …}`
    * `:email_thread_state` — `thread_id => %{"references" => […], "subject" => …}`

  Every operation degrades to a no-op when no store is running: reads answer
  `nil` and writes answer `{:error, :store_unavailable}` without raising, so an
  adapter in a runtime with no store behaves exactly like the stateless one
  rather than failing to accept mail.
  """

  alias LemonChannels.Adapters.Email.MessageId
  alias LemonCore.Store

  @message_thread_table :email_message_threads
  @thread_state_table :email_thread_state

  @doc """
  The thread id for a parsed message.

  Returns the thread of the first known ancestor — nearest first, since the
  immediate parent is the strongest evidence — and otherwise `fallback`, which
  is the caller's stateless computation.
  """
  @spec resolve(map(), binary()) :: binary()
  def resolve(parsed, fallback) when is_binary(fallback) do
    candidates =
      [parsed[:message_id], parsed[:in_reply_to] | Enum.reverse(parsed[:references] || [])]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(candidates, fallback, &thread_of/1)
  end

  @doc """
  Records an inbound message against `thread_id` and returns the thread's state.

  The returned map is authoritative for the send that follows even when the
  store is unavailable, since it is computed before being written.
  """
  @spec record_inbound(map(), binary()) :: map()
  def record_inbound(parsed, thread_id) when is_binary(thread_id) do
    existing = state(thread_id)

    references =
      MessageId.merge([
        existing["references"],
        parsed[:references],
        [parsed[:in_reply_to]],
        [parsed[:message_id]]
      ])

    state = %{
      "thread_id" => thread_id,
      "references" => references,
      "last_message_id" => parsed[:message_id] || existing["last_message_id"],
      "subject" => parsed[:subject] || existing["subject"],
      "recipient" => List.first(parsed[:to] || []) || existing["recipient"],
      "sender" => parsed[:from] || existing["sender"],
      "updated_at_ms" => System.system_time(:millisecond)
    }

    _ = put_message_thread(parsed[:message_id], thread_id)
    _ = put(@thread_state_table, thread_id, state)

    state
  end

  @doc """
  Records a message this adapter sent, so the reply to it resolves to the same
  thread and the chain keeps growing.
  """
  @spec record_outbound(binary() | nil, binary(), [binary()]) :: :ok
  def record_outbound(thread_id, message_id, references)
      when is_binary(thread_id) and is_binary(message_id) do
    existing = state(thread_id)

    _ = put_message_thread(message_id, thread_id)

    _ =
      put(@thread_state_table, thread_id, %{
        "thread_id" => thread_id,
        "references" => MessageId.merge([existing["references"], references, [message_id]]),
        "last_message_id" => message_id,
        "subject" => existing["subject"],
        "recipient" => existing["recipient"],
        "sender" => existing["sender"],
        "updated_at_ms" => System.system_time(:millisecond)
      })

    :ok
  end

  def record_outbound(_thread_id, _message_id, _references), do: :ok

  @doc """
  The stored state for a thread, string-keyed, or `%{}` when there is none.

  Normalizes atom-keyed values too: the tables outlive process restarts and
  backend swaps, and older rows were written with atom keys.
  """
  @spec state(binary() | nil) :: map()
  def state(thread_id) when is_binary(thread_id) do
    case get(@thread_state_table, thread_id) do
      %{} = stored -> normalize_keys(stored)
      _ -> %{}
    end
  end

  def state(_thread_id), do: %{}

  defp thread_of(message_id) when is_binary(message_id) do
    case get(@message_thread_table, message_id) do
      %{"thread_id" => thread_id} when is_binary(thread_id) and thread_id != "" -> thread_id
      %{thread_id: thread_id} when is_binary(thread_id) and thread_id != "" -> thread_id
      thread_id when is_binary(thread_id) and thread_id != "" -> thread_id
      _ -> nil
    end
  end

  defp thread_of(_message_id), do: nil

  defp put_message_thread(message_id, thread_id)
       when is_binary(message_id) and is_binary(thread_id) do
    put(@message_thread_table, message_id, %{
      "thread_id" => thread_id,
      "updated_at_ms" => System.system_time(:millisecond)
    })
  end

  defp put_message_thread(_message_id, _thread_id), do: :ok

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  # The store is optional infrastructure for this adapter, not a dependency of
  # accepting mail — a failed read or write costs thread continuity, nothing
  # more, so neither is allowed to propagate.
  defp get(table, key) do
    Store.get(table, key)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp put(table, key, value) do
    Store.put(table, key, value)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
