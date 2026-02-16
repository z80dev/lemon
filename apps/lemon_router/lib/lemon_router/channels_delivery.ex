defmodule LemonRouter.ChannelsDelivery do
  @moduledoc false

  require Logger

  alias LemonChannels.OutboundPayload

  @enqueue_failure_event [:lemon_router, :channels_delivery, :enqueue, :failure]

  @spec telegram_outbox_available?() :: boolean()
  def telegram_outbox_available? do
    is_pid(Process.whereis(LemonGateway.Telegram.Outbox))
  end

  @spec enqueue(OutboundPayload.t(), keyword()) :: {:ok, reference()} | {:error, term()}
  def enqueue(%OutboundPayload{} = payload, opts \\ []) do
    do_channels_enqueue(payload, normalize_context(opts[:context]))
  end

  @spec telegram_enqueue(
          key :: term(),
          priority :: integer(),
          op :: term(),
          fallback_payload :: OutboundPayload.t(),
          opts :: keyword()
        ) :: {:ok, reference()} | {:error, term()}
  def telegram_enqueue(key, priority, op, %OutboundPayload{} = fallback_payload, opts \\ []) do
    context = normalize_context(opts[:context])

    if telegram_outbox_available?() do
      LemonGateway.Telegram.Outbox.enqueue(key, priority, op)
      {:ok, make_ref()}
    else
      do_channels_enqueue(fallback_payload, Map.put(context, :fallback, :channels_outbox))
    end
  rescue
    exception ->
      context = normalize_context(opts[:context])
      reason = {:telegram_outbox_exception, Exception.message(exception)}
      emit_enqueue_failure(fallback_payload, reason, context)
      do_channels_enqueue(fallback_payload, Map.put(context, :fallback, :channels_outbox))
  end

  @spec telegram_enqueue_with_notify(
          key :: term(),
          priority :: integer(),
          op :: term(),
          fallback_payload :: OutboundPayload.t(),
          notify_pid :: pid(),
          notify_ref :: reference(),
          notify_tag :: atom(),
          opts :: keyword()
        ) :: {:ok, reference()} | {:error, term()}
  def telegram_enqueue_with_notify(
        key,
        priority,
        op,
        %OutboundPayload{} = fallback_payload,
        notify_pid,
        notify_ref,
        notify_tag \\ :outbox_delivered,
        opts \\ []
      )
      when is_pid(notify_pid) and is_reference(notify_ref) and is_atom(notify_tag) do
    context = normalize_context(opts[:context])

    if telegram_outbox_available?() do
      LemonGateway.Telegram.Outbox.enqueue_with_notify(
        key,
        priority,
        op,
        notify_pid,
        notify_ref,
        notify_tag
      )

      {:ok, notify_ref}
    else
      fallback_payload
      |> attach_notify(notify_pid, notify_ref, notify_tag)
      |> do_channels_enqueue(Map.put(context, :fallback, :channels_outbox))
    end
  rescue
    exception ->
      context = normalize_context(opts[:context])
      reason = {:telegram_outbox_exception, Exception.message(exception)}
      emit_enqueue_failure(fallback_payload, reason, context)

      fallback_payload
      |> attach_notify(notify_pid, notify_ref, notify_tag)
      |> do_channels_enqueue(Map.put(context, :fallback, :channels_outbox))
  end

  defp do_channels_enqueue(%OutboundPayload{} = payload, context) do
    if is_pid(Process.whereis(LemonChannels.Outbox)) do
      case LemonChannels.Outbox.enqueue(payload) do
        {:ok, ref} ->
          {:ok, ref}

        {:error, :duplicate} = duplicate ->
          duplicate

        {:error, reason} = error ->
          emit_enqueue_failure(payload, reason, context)
          error
      end
    else
      reason = :channels_outbox_unavailable
      emit_enqueue_failure(payload, reason, context)
      {:error, reason}
    end
  rescue
    exception ->
      reason = {:channels_outbox_exception, Exception.message(exception)}
      emit_enqueue_failure(payload, reason, context)
      {:error, reason}
  end

  defp attach_notify(%OutboundPayload{} = payload, notify_pid, notify_ref, notify_tag) do
    meta = payload.meta || %{}

    meta =
      if notify_tag == :outbox_delivered do
        meta
      else
        Map.put(meta, :notify_tag, notify_tag)
      end

    %{payload | notify_pid: notify_pid, notify_ref: notify_ref, meta: meta}
  end

  defp emit_enqueue_failure(%OutboundPayload{} = payload, reason, context) do
    metadata =
      Map.merge(
        %{
          reason: reason,
          channel_id: payload.channel_id,
          kind: payload.kind,
          idempotency_key: payload.idempotency_key
        },
        context
      )

    :telemetry.execute(@enqueue_failure_event, %{count: 1}, metadata)

    Logger.warning(
      "Failed to enqueue outbound payload in channels delivery abstraction: " <>
        "channel_id=#{inspect(payload.channel_id)} kind=#{inspect(payload.kind)} " <>
        "reason=#{inspect(reason)} context=#{inspect(context)}"
    )
  rescue
    _ -> :ok
  end

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(_), do: %{}
end
