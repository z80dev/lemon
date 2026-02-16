defmodule LemonRouter.ChannelsDelivery do
  @moduledoc false

  require Logger

  alias LemonChannels.OutboundPayload
  alias LemonChannels.Telegram.Delivery, as: TelegramDelivery

  @enqueue_failure_event [:lemon_router, :channels_delivery, :enqueue, :failure]

  @spec telegram_outbox_available?() :: boolean()
  def telegram_outbox_available? do
    TelegramDelivery.legacy_outbox_available?()
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
    TelegramDelivery.enqueue_legacy_fallback(
      key,
      priority,
      op,
      fallback_payload,
      context: normalize_context(opts[:context]),
      on_failure: &emit_enqueue_failure/3
    )
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
    TelegramDelivery.enqueue_legacy_fallback(
      key,
      priority,
      op,
      fallback_payload,
      context: normalize_context(opts[:context]),
      notify: {notify_pid, notify_ref, notify_tag},
      on_failure: &emit_enqueue_failure/3
    )
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
