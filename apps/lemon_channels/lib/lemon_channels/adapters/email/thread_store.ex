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

  ## Ownership

  Every row is owned by a **scope**: the inbox the mail was addressed to and the
  authorized sender, as built by `scope/2`. Lookups and writes only ever touch
  rows of the caller's scope, so one sender who learns (or guesses) another
  sender's Message-ID cannot join that thread, read its subject and reference
  chain through the agent's reply, or overwrite them. The inbound half scopes by
  `{account_id, sender}` of the authorized message and the outbound half by the
  payload's `{account_id, peer.id}`, which are the same pair for a reply.

  Rows written before scoping existed (keyed by a bare message or thread id)
  have no owner and are never read: a reply on such a thread starts fresh
  state rather than adopting metadata just because an id matches.

  ## Storage

  Two `LemonCore.Store` tables:

    * `:email_message_threads` — `{inbox, sender, message_id} => %{"thread_id" => …}`
    * `:email_thread_state` — `{inbox, sender, thread_id} => %{"references" => […], "subject" => …}`

  Every operation degrades to a no-op when no store is running or no scope is
  known: reads answer `nil`/`%{}` and writes answer without raising, so an
  adapter in a runtime with no store behaves exactly like the stateless one
  rather than failing to accept mail.
  """

  alias LemonChannels.Adapters.Email.MessageId
  alias LemonCore.Store

  @message_thread_table :email_message_threads
  @thread_state_table :email_thread_state

  @type scope :: {inbox :: binary(), sender :: binary()}

  @doc """
  The ownership scope for an inbox and a sender address, or `nil` when either
  is missing. Both are trimmed and lowercased.
  """
  @spec scope(term(), term()) :: scope() | nil
  def scope(inbox, sender) when is_binary(inbox) and is_binary(sender) do
    case {normalize_owner(inbox), normalize_owner(sender)} do
      {"", _sender} -> nil
      {_inbox, ""} -> nil
      scope -> scope
    end
  end

  def scope(_inbox, _sender), do: nil

  @doc """
  The thread id for a parsed message within `scope`.

  Returns the thread of the first ancestor known *in this scope* — nearest
  first, since the immediate parent is the strongest evidence — and otherwise
  `fallback`, which is the caller's stateless computation.
  """
  @spec resolve(map(), binary(), scope() | nil) :: binary()
  def resolve(parsed, fallback, scope) when is_binary(fallback) do
    candidates =
      [parsed[:message_id], parsed[:in_reply_to] | Enum.reverse(parsed[:references] || [])]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(candidates, fallback, &thread_of(scope, &1))
  end

  @doc """
  Records an inbound message against `thread_id` in `scope` and returns the
  thread's state.

  The returned map is authoritative for the send that follows even when the
  store is unavailable, since it is computed before being written.
  """
  @spec record_inbound(map(), binary(), scope() | nil) :: map()
  def record_inbound(parsed, thread_id, scope) when is_binary(thread_id) do
    existing = state(scope, thread_id)

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

    _ = put_message_thread(scope, parsed[:message_id], thread_id)
    _ = put_scoped(@thread_state_table, scope, thread_id, state)

    state
  end

  @doc """
  Records a message this adapter sent in `scope`, so the reply to it resolves
  to the same thread and the chain keeps growing.
  """
  @spec record_outbound(scope() | nil, binary() | nil, binary(), [binary()]) :: :ok
  def record_outbound(scope, thread_id, message_id, references)
      when is_binary(thread_id) and is_binary(message_id) do
    existing = state(scope, thread_id)

    _ = put_message_thread(scope, message_id, thread_id)

    _ =
      put_scoped(@thread_state_table, scope, thread_id, %{
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

  def record_outbound(_scope, _thread_id, _message_id, _references), do: :ok

  @doc """
  The stored state for a thread in `scope`, string-keyed, or `%{}` when there
  is none (including when `scope` is `nil`).
  """
  @spec state(scope() | nil, binary() | nil) :: map()
  def state(scope, thread_id) when is_binary(thread_id) do
    case get_scoped(@thread_state_table, scope, thread_id) do
      %{} = stored -> normalize_keys(stored)
      _ -> %{}
    end
  end

  def state(_scope, _thread_id), do: %{}

  defp thread_of(scope, message_id) when is_binary(message_id) do
    case get_scoped(@message_thread_table, scope, message_id) do
      %{"thread_id" => thread_id} when is_binary(thread_id) and thread_id != "" -> thread_id
      _ -> nil
    end
  end

  defp thread_of(_scope, _message_id), do: nil

  defp put_message_thread(scope, message_id, thread_id)
       when is_binary(message_id) and is_binary(thread_id) do
    put_scoped(@message_thread_table, scope, message_id, %{
      "thread_id" => thread_id,
      "updated_at_ms" => System.system_time(:millisecond)
    })
  end

  defp put_message_thread(_scope, _message_id, _thread_id), do: :ok

  defp normalize_owner(value), do: value |> String.trim() |> String.downcase()

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp get_scoped(table, {inbox, sender}, id), do: get(table, {inbox, sender, id})
  defp get_scoped(_table, _scope, _id), do: nil

  defp put_scoped(table, {inbox, sender}, id, value), do: put(table, {inbox, sender, id}, value)
  defp put_scoped(_table, _scope, _id, _value), do: :ok

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
