defmodule LemonChannels.Telegram.Delivery do
  @moduledoc """
  Telegram delivery helpers backed only by LemonChannels.Outbox.
  """

  alias LemonChannels.{OutboundPayload, Outbox}

  @channel_id "telegram"
  @default_account_id "default"
  @default_notify_tag :outbox_delivered

  @type chat_id :: integer() | binary()
  @type enqueue_opt ::
          {:account_id, binary()}
          | {:thread_id, integer() | binary()}
          | {:topic_id, integer() | binary()}
          | {:reply_to_message_id, integer() | binary()}
          | {:reply_to, integer() | binary()}
          | {:reply_markup, map()}
          | {:priority, integer()}
          | {:key, term()}
          | {:peer_kind, :dm | :group | :channel}
          | {:idempotency_key, binary()}
          | {:meta, map()}
          | {:notify, {pid(), reference()} | {pid(), reference(), atom()}}
          | {:notify_pid, pid()}
          | {:notify_ref, reference()}
          | {:notify_tag, atom()}

  @spec enqueue_send(chat_id(), binary(), [enqueue_opt()]) :: :ok | {:error, term()}
  def enqueue_send(chat_id, text, opts \\ []) when is_list(opts) do
    notify = notify_details(opts)

    payload =
      %OutboundPayload{
        channel_id: @channel_id,
        account_id: account_id(opts),
        peer: build_peer(chat_id, opts),
        kind: :text,
        content: normalize_text(text),
        idempotency_key: opts[:idempotency_key],
        reply_to: optional_string_id(reply_to_opt(opts)),
        meta: build_meta(opts, notify),
        notify_pid: notify.pid,
        notify_ref: notify.ref
      }

    case enqueue_channels(payload) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_channels(payload) do
    if channels_outbox_available?() do
      try do
        Outbox.enqueue(payload)
      catch
        :exit, {:timeout, _} -> {:error, :channels_outbox_timeout}
        :exit, reason -> {:error, {:channels_outbox_exit, reason}}
      end
    else
      {:error, :channels_outbox_unavailable}
    end
  rescue
    _ -> {:error, :channels_outbox_exception}
  end

  defp channels_outbox_available? do
    is_pid(Process.whereis(Outbox))
  end

  defp account_id(opts) do
    case opts[:account_id] do
      account when is_binary(account) and account != "" -> account
      account when is_atom(account) -> Atom.to_string(account)
      _ -> @default_account_id
    end
  end

  defp build_peer(chat_id, opts) do
    %{
      kind: opts[:peer_kind] || :dm,
      id: string_id(chat_id),
      thread_id: optional_string_id(thread_id_opt(opts))
    }
  end

  defp build_meta(opts, notify) do
    base =
      case opts[:meta] do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    base
    |> maybe_put(:reply_markup, opts[:reply_markup])
    |> maybe_put(:topic_id, optional_string_id(thread_id_opt(opts)))
    |> maybe_put(:notify_tag, notify.tag)
  end

  defp notify_details(opts) when is_list(opts) do
    cond do
      match?(
        {pid, ref, tag} when is_pid(pid) and is_reference(ref) and is_atom(tag),
        opts[:notify]
      ) ->
        {pid, ref, tag} = opts[:notify]
        %{enabled?: true, pid: pid, ref: ref, tag: tag}

      match?({pid, ref} when is_pid(pid) and is_reference(ref), opts[:notify]) ->
        {pid, ref} = opts[:notify]
        %{enabled?: true, pid: pid, ref: ref, tag: opts[:notify_tag] || @default_notify_tag}

      is_pid(opts[:notify_pid]) and is_reference(opts[:notify_ref]) ->
        %{
          enabled?: true,
          pid: opts[:notify_pid],
          ref: opts[:notify_ref],
          tag: opts[:notify_tag] || @default_notify_tag
        }

      true ->
        %{enabled?: false, pid: nil, ref: nil, tag: nil}
    end
  end

  defp thread_id_opt(opts), do: opts[:thread_id] || opts[:topic_id]
  defp reply_to_opt(opts), do: opts[:reply_to_message_id] || opts[:reply_to]

  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(text) when is_nil(text), do: ""
  defp normalize_text(text), do: to_string(text)

  defp string_id(id) when is_binary(id), do: id
  defp string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp string_id(id), do: to_string(id)

  defp optional_string_id(nil), do: nil
  defp optional_string_id(id), do: string_id(id)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
