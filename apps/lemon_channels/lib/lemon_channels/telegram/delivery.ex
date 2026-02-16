defmodule LemonChannels.Telegram.Delivery do
  @moduledoc """
  Stable Telegram delivery API with legacy compatibility fallback.

  This module provides small enqueue helpers for Telegram send/edit operations.
  It prefers the legacy `LemonGateway.Telegram.Outbox` while it is running,
  then falls back to `LemonChannels.Outbox` delivery.
  """

  alias LemonChannels.{OutboundPayload, Outbox}

  @legacy_outbox LemonGateway.Telegram.Outbox
  @channel_id "telegram"
  @default_account_id "default"
  @default_notify_tag :outbox_delivered

  @type chat_id :: integer() | binary()
  @type message_id :: integer() | binary()

  @type enqueue_opt ::
          {:account_id, binary()}
          | {:thread_id, integer() | binary()}
          | {:topic_id, integer() | binary()}
          | {:reply_to_message_id, integer() | binary()}
          | {:reply_to, integer() | binary()}
          | {:reply_markup, map()}
          | {:engine, atom()}
          | {:priority, integer()}
          | {:key, term()}
          | {:peer_kind, :dm | :group | :channel}
          | {:idempotency_key, binary()}
          | {:meta, map()}
          | {:notify, {pid(), reference()} | {pid(), reference(), atom()}}
          | {:notify_pid, pid()}
          | {:notify_ref, reference()}
          | {:notify_tag, atom()}

  @type legacy_fallback_opt ::
          {:context, map()}
          | {:notify, {pid(), reference(), atom()}}
          | {:on_failure, (OutboundPayload.t(), term(), map() -> term())}

  @doc false
  @spec legacy_outbox_available?() :: boolean()
  def legacy_outbox_available? do
    is_pid(Process.whereis(@legacy_outbox))
  end

  @doc false
  @spec enqueue_legacy_fallback(
          key :: term(),
          priority :: integer(),
          op :: term(),
          fallback_payload :: OutboundPayload.t(),
          opts :: [legacy_fallback_opt()]
        ) :: {:ok, reference()} | {:error, term()}
  def enqueue_legacy_fallback(
        key,
        priority,
        op,
        %OutboundPayload{} = fallback_payload,
        opts \\ []
      )
      when is_list(opts) do
    context = normalize_fallback_context(opts[:context])
    notify = fallback_notify(opts[:notify])
    on_failure = normalize_failure_callback(opts[:on_failure])

    case enqueue_legacy_for_fallback(op, key, priority, notify) do
      {:ok, ref} ->
        {:ok, ref}

      {:fallback, reason} ->
        maybe_emit_enqueue_failure(on_failure, fallback_payload, reason, context)

        fallback_payload
        |> attach_fallback_notify(notify)
        |> enqueue_channels_for_fallback(
          Map.put(context, :fallback, :channels_outbox),
          on_failure
        )
    end
  end

  @doc """
  Enqueue a Telegram send operation.

  Options:
  - `:reply_to_message_id` / `:reply_to`
  - `:thread_id` / `:topic_id`
  - `:reply_markup`
  - `:engine`
  - `:notify_pid`, `:notify_ref`, `:notify_tag` (or `:notify` tuple)
  """
  @spec enqueue_send(chat_id(), binary(), [enqueue_opt()]) :: :ok | {:error, term()}
  def enqueue_send(chat_id, text, opts \\ []) when is_list(opts) do
    text = normalize_text(text)
    notify = notify_details(opts)
    legacy_chat_id = legacy_numeric_id(chat_id)
    key = opts[:key] || {chat_id, make_ref(), :send}
    priority = opts[:priority] || 1

    legacy_payload =
      %{}
      |> Map.put(:text, text)
      |> maybe_put(:engine, opts[:engine])
      |> maybe_put(:reply_to_message_id, normalize_legacy_optional_id(reply_to_opt(opts)))
      |> maybe_put(:message_thread_id, normalize_legacy_optional_id(thread_id_opt(opts)))
      |> maybe_put(:reply_markup, opts[:reply_markup])

    legacy_op =
      case legacy_chat_id do
        {:ok, chat} -> {:send, chat, legacy_payload}
        :error -> :skip
      end

    fallback_payload =
      %OutboundPayload{
        channel_id: @channel_id,
        account_id: account_id(opts),
        peer: build_peer(chat_id, opts),
        kind: :text,
        content: text,
        idempotency_key: opts[:idempotency_key],
        reply_to: optional_string_id(reply_to_opt(opts)),
        meta: build_meta(opts, notify),
        notify_pid: notify.pid,
        notify_ref: notify.ref
      }

    dispatch(legacy_op, key, priority, notify, fallback_payload)
  end

  @doc """
  Enqueue a Telegram edit operation.

  Options:
  - `:reply_markup`
  - `:engine`
  - `:notify_pid`, `:notify_ref`, `:notify_tag` (or `:notify` tuple)
  """
  @spec enqueue_edit(chat_id(), message_id(), binary(), [enqueue_opt()]) :: :ok | {:error, term()}
  def enqueue_edit(chat_id, message_id, text, opts \\ []) when is_list(opts) do
    text = normalize_text(text)
    notify = notify_details(opts)
    legacy_chat_id = legacy_numeric_id(chat_id)
    legacy_message_id = legacy_numeric_id(message_id)
    key = opts[:key] || {chat_id, message_id, :edit}
    priority = opts[:priority] || 0

    legacy_payload =
      %{}
      |> Map.put(:text, text)
      |> maybe_put(:engine, opts[:engine])
      |> maybe_put(:reply_markup, opts[:reply_markup])

    legacy_op =
      case {legacy_chat_id, legacy_message_id} do
        {{:ok, chat}, {:ok, msg}} -> {:edit, chat, msg, legacy_payload}
        _ -> :skip
      end

    fallback_payload =
      %OutboundPayload{
        channel_id: @channel_id,
        account_id: account_id(opts),
        peer: build_peer(chat_id, opts),
        kind: :edit,
        content: %{message_id: string_id(message_id), text: text},
        idempotency_key: opts[:idempotency_key],
        meta: build_meta(opts, notify),
        notify_pid: notify.pid,
        notify_ref: notify.ref
      }

    dispatch(legacy_op, key, priority, notify, fallback_payload)
  end

  defp dispatch(legacy_op, key, priority, notify, fallback_payload) do
    case enqueue_legacy(legacy_op, key, priority, notify) do
      :ok -> :ok
      :fallback -> enqueue_channels(fallback_payload)
    end
  end

  defp enqueue_legacy(:skip, _key, _priority, _notify), do: :fallback

  defp enqueue_legacy(op, key, priority, notify) do
    if legacy_outbox_available?() do
      try do
        case notify do
          %{enabled?: true, pid: pid, ref: ref, tag: tag} ->
            @legacy_outbox.enqueue_with_notify(key, priority, op, pid, ref, tag)

          _ ->
            @legacy_outbox.enqueue(key, priority, op)
        end

        :ok
      rescue
        _ -> :fallback
      end
    else
      :fallback
    end
  end

  defp enqueue_channels(payload) do
    if channels_outbox_available?() do
      case Outbox.enqueue(payload) do
        {:ok, _ref} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :channels_outbox_unavailable}
    end
  rescue
    _ -> {:error, :channels_outbox_exception}
  end

  defp enqueue_legacy_for_fallback(:skip, _key, _priority, _notify), do: {:fallback, nil}

  defp enqueue_legacy_for_fallback(op, key, priority, notify) do
    if legacy_outbox_available?() do
      try do
        case notify do
          %{enabled?: true, pid: pid, ref: ref, tag: tag} ->
            @legacy_outbox.enqueue_with_notify(key, priority, op, pid, ref, tag)
            {:ok, ref}

          _ ->
            @legacy_outbox.enqueue(key, priority, op)
            {:ok, make_ref()}
        end
      rescue
        exception ->
          {:fallback, {:telegram_outbox_exception, Exception.message(exception)}}
      end
    else
      {:fallback, nil}
    end
  end

  defp enqueue_channels_for_fallback(payload, context, on_failure) do
    if channels_outbox_available?() do
      case Outbox.enqueue(payload) do
        {:ok, ref} ->
          {:ok, ref}

        {:error, :duplicate} = duplicate ->
          duplicate

        {:error, reason} = error ->
          maybe_emit_enqueue_failure(on_failure, payload, reason, context)
          error
      end
    else
      reason = :channels_outbox_unavailable
      maybe_emit_enqueue_failure(on_failure, payload, reason, context)
      {:error, reason}
    end
  rescue
    exception ->
      reason = {:channels_outbox_exception, Exception.message(exception)}
      maybe_emit_enqueue_failure(on_failure, payload, reason, context)
      {:error, reason}
  end

  defp attach_fallback_notify(
         %OutboundPayload{} = payload,
         %{enabled?: true, pid: notify_pid, ref: notify_ref, tag: notify_tag}
       ) do
    meta = payload.meta || %{}

    meta =
      if notify_tag == @default_notify_tag do
        meta
      else
        Map.put(meta, :notify_tag, notify_tag)
      end

    %{payload | notify_pid: notify_pid, notify_ref: notify_ref, meta: meta}
  end

  defp attach_fallback_notify(%OutboundPayload{} = payload, _notify), do: payload

  defp fallback_notify({pid, ref, tag})
       when is_pid(pid) and is_reference(ref) and is_atom(tag) do
    %{enabled?: true, pid: pid, ref: ref, tag: tag}
  end

  defp fallback_notify(_notify), do: %{enabled?: false, pid: nil, ref: nil, tag: nil}

  defp normalize_fallback_context(context) when is_map(context), do: context
  defp normalize_fallback_context(_context), do: %{}

  defp normalize_failure_callback(callback) when is_function(callback, 3), do: callback
  defp normalize_failure_callback(_callback), do: nil

  defp maybe_emit_enqueue_failure(_callback, _payload, nil, _context), do: :ok
  defp maybe_emit_enqueue_failure(nil, _payload, _reason, _context), do: :ok

  defp maybe_emit_enqueue_failure(callback, payload, reason, context) do
    try do
      callback.(payload, reason, context)
    rescue
      _ -> :ok
    end
  end

  defp channels_outbox_available? do
    is_pid(Process.whereis(Outbox))
  end

  defp build_meta(opts, notify) do
    meta =
      opts[:meta]
      |> normalize_meta()
      |> maybe_put(:reply_markup, opts[:reply_markup])
      |> maybe_put_notify_tag(notify)

    if map_size(meta) == 0, do: nil, else: meta
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp maybe_put_notify_tag(meta, %{enabled?: true, tag: tag}),
    do: Map.put(meta, :notify_tag, tag)

  defp maybe_put_notify_tag(meta, _notify), do: meta

  defp build_peer(chat_id, opts) do
    %{
      kind: normalize_peer_kind(opts[:peer_kind]),
      id: string_id(chat_id),
      thread_id: optional_string_id(thread_id_opt(opts))
    }
  end

  defp normalize_peer_kind(:group), do: :group
  defp normalize_peer_kind(:channel), do: :channel
  defp normalize_peer_kind(:dm), do: :dm
  defp normalize_peer_kind(_), do: :dm

  defp notify_details(opts) do
    case opts[:notify] do
      {pid, ref, tag}
      when is_pid(pid) and is_reference(ref) and is_atom(tag) and not is_nil(tag) ->
        %{enabled?: true, pid: pid, ref: ref, tag: tag}

      {pid, ref} when is_pid(pid) and is_reference(ref) ->
        %{enabled?: true, pid: pid, ref: ref, tag: normalize_notify_tag(opts[:notify_tag])}

      _ ->
        pid = opts[:notify_pid]
        ref = opts[:notify_ref]

        if is_pid(pid) and is_reference(ref) do
          %{enabled?: true, pid: pid, ref: ref, tag: normalize_notify_tag(opts[:notify_tag])}
        else
          %{enabled?: false, pid: nil, ref: nil, tag: @default_notify_tag}
        end
    end
  end

  defp normalize_notify_tag(tag) when is_atom(tag) and not is_nil(tag), do: tag
  defp normalize_notify_tag(_tag), do: @default_notify_tag

  defp account_id(opts) do
    value = opts[:account_id] || default_account_id()

    case value do
      account_id when is_binary(account_id) and account_id != "" -> account_id
      _ -> @default_account_id
    end
  end

  defp default_account_id do
    config = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}
    config[:account_id] || config["account_id"] || @default_account_id
  end

  defp reply_to_opt(opts), do: opts[:reply_to_message_id] || opts[:reply_to]
  defp thread_id_opt(opts), do: opts[:thread_id] || opts[:topic_id]

  defp legacy_numeric_id(id) when is_integer(id), do: {:ok, id}

  defp legacy_numeric_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp legacy_numeric_id(_id), do: :error

  defp normalize_legacy_optional_id(nil), do: nil

  defp normalize_legacy_optional_id(value) do
    case legacy_numeric_id(value) do
      {:ok, id} -> id
      :error -> value
    end
  end

  defp string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp string_id(id) when is_binary(id), do: id
  defp string_id(id), do: to_string(id)

  defp optional_string_id(nil), do: nil
  defp optional_string_id(id), do: string_id(id)

  defp normalize_text(nil), do: ""
  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(text), do: to_string(text)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
