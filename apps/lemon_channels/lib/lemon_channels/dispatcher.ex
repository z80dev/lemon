defmodule LemonChannels.Dispatcher do
  @moduledoc """
  Translates `LemonCore.OutputIntent` structs into channel-specific
  outbound work. This is the single entry point for router -> channels
  delivery.

  The router should call `Dispatcher.dispatch(intent)` instead of
  directly constructing `LemonChannels.OutboundPayload` structs.

  ## Intent-to-Payload Mapping

  Each `OutputIntent.op` maps to a specific `OutboundPayload.kind`:

  | Intent op         | Payload kind | Content shape                       |
  |--------------------|-------------|--------------------------------------|
  | `:stream_append`   | `:text`     | `body.text` (binary)                 |
  | `:stream_replace`  | `:edit`     | `%{message_id: ..., text: ...}`      |
  | `:tool_status`     | `:text`     | `body.text` (binary)                 |
  | `:final_text`      | `:text`     | `body.text` (binary)                 |
  | `:fanout_text`     | `:text`     | `body.text` (binary)                 |
  | `:send_files`      | `:file`     | `body.files` (list of file maps)     |
  | `:keepalive_prompt` | `:text`    | `body.text` (binary)                 |
  """

  require Logger

  alias LemonCore.OutputIntent
  alias LemonCore.ChannelRoute
  alias LemonChannels.OutboundPayload

  @doc """
  Dispatches an output intent to the appropriate channel adapter.

  Translates the intent into an `OutboundPayload` and enqueues it
  via the existing outbox infrastructure.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec dispatch(OutputIntent.t()) :: :ok | {:error, term()}
  def dispatch(%OutputIntent{route: %ChannelRoute{} = _route} = intent) do
    payload = intent_to_payload(intent)
    deliver(payload)
  end

  @doc """
  Dispatch a keepalive prompt intent with channel-specific action rendering.

  This is the entry point for intents that carry interactive actions
  (e.g. the watchdog keepalive prompt with "Keep Waiting" / "Stop Run" buttons).
  The `body.actions` list is rendered into channel-specific markup
  (e.g. Telegram inline keyboards) and placed in the payload's meta.
  """
  @spec dispatch_with_actions(OutputIntent.t()) :: :ok | {:error, term()}
  def dispatch_with_actions(%OutputIntent{route: %ChannelRoute{}} = intent) do
    payload = intent_to_payload_with_actions(intent)
    deliver(payload)
  end

  @doc """
  Translates an `OutputIntent` into an `OutboundPayload`.

  This is exposed for testing and for callers that need the payload
  without immediate delivery.
  """
  @spec intent_to_payload(OutputIntent.t()) :: OutboundPayload.t()
  def intent_to_payload(%OutputIntent{route: %ChannelRoute{} = route} = intent) do
    {kind, content} = translate_op(intent.op, intent.body)

    struct!(OutboundPayload,
      channel_id: route.channel_id,
      account_id: route.account_id,
      peer: %{
        kind: route.peer_kind,
        id: route.peer_id,
        thread_id: route.thread_id
      },
      kind: kind,
      content: content,
      idempotency_key: intent.meta[:idempotency_key],
      reply_to: intent.meta[:reply_to],
      meta: Map.drop(intent.meta, [:idempotency_key, :reply_to, :notify_pid, :notify_ref]),
      notify_pid: intent.meta[:notify_pid],
      notify_ref: intent.meta[:notify_ref]
    )
  end

  @doc """
  Translates a `:keepalive_prompt` intent into an `OutboundPayload`,
  rendering channel-specific prompt actions (e.g. inline keyboard for
  Telegram) from the intent body's `:actions` list.

  Each action in the list should be a map with `:id` and `:label` keys.
  The `:id` becomes the callback_data for Telegram inline keyboards.
  """
  @spec intent_to_payload_with_actions(OutputIntent.t()) :: OutboundPayload.t()
  def intent_to_payload_with_actions(%OutputIntent{route: %ChannelRoute{} = route} = intent) do
    {kind, content} = translate_op(intent.op, intent.body)
    actions = Map.get(intent.body, :actions, [])
    reply_markup = render_prompt_actions(route.channel_id, actions)

    base_meta =
      Map.drop(intent.meta, [:idempotency_key, :reply_to, :notify_pid, :notify_ref])

    meta =
      if reply_markup do
        Map.put(base_meta, :reply_markup, reply_markup)
      else
        base_meta
      end

    struct!(OutboundPayload,
      channel_id: route.channel_id,
      account_id: route.account_id,
      peer: %{
        kind: route.peer_kind,
        id: route.peer_id,
        thread_id: route.thread_id
      },
      kind: kind,
      content: content,
      idempotency_key: intent.meta[:idempotency_key],
      reply_to: intent.meta[:reply_to],
      meta: meta,
      notify_pid: intent.meta[:notify_pid],
      notify_ref: intent.meta[:notify_ref]
    )
  end

  # -- Channel-specific prompt action rendering --

  @doc false
  def render_prompt_actions(_channel_id, nil), do: nil
  def render_prompt_actions(_channel_id, []), do: nil

  def render_prompt_actions("telegram", actions) when is_list(actions) do
    buttons =
      Enum.map(actions, fn action ->
        %{
          "text" => to_string(action[:label] || action["label"] || ""),
          "callback_data" => to_string(action[:id] || action["id"] || "")
        }
      end)

    %{"inline_keyboard" => [buttons]}
  end

  def render_prompt_actions(_channel_id, actions) when is_list(actions) do
    # For non-Telegram channels, store actions as structured data.
    # The outbound adapter can decide how to render them.
    %{"actions" => actions}
  end

  # -- Private: op -> {kind, content} translation --

  defp translate_op(:stream_append, body) do
    {:text, Map.get(body, :text, "")}
  end

  defp translate_op(:stream_replace, body) do
    {:edit, %{message_id: body[:message_id], text: Map.get(body, :text, "")}}
  end

  defp translate_op(:tool_status, body) do
    {:text, Map.get(body, :text, "")}
  end

  defp translate_op(:keepalive_prompt, body) do
    {:text, Map.get(body, :text, "")}
  end

  defp translate_op(:final_text, body) do
    {:text, Map.get(body, :text, "")}
  end

  defp translate_op(:fanout_text, body) do
    {:text, Map.get(body, :text, "")}
  end

  defp translate_op(:send_files, body) do
    {:file, Map.get(body, :files, [])}
  end

  # -- Private: delivery via existing outbox --

  defp deliver(%OutboundPayload{} = payload) do
    if is_pid(Process.whereis(LemonChannels.Outbox)) do
      case LemonChannels.Outbox.enqueue(payload) do
        {:ok, _ref} -> :ok
        {:error, :duplicate} -> :ok
        {:error, reason} = error ->
          Logger.warning(
            "Dispatcher: failed to enqueue payload " <>
              "channel_id=#{inspect(payload.channel_id)} " <>
              "kind=#{inspect(payload.kind)} " <>
              "reason=#{inspect(reason)}"
          )

          error
      end
    else
      {:error, :outbox_unavailable}
    end
  rescue
    e ->
      reason = {:dispatch_exception, Exception.message(e)}

      Logger.warning(
        "Dispatcher: exception during delivery " <>
          "channel_id=#{inspect(payload.channel_id)} " <>
          "reason=#{inspect(reason)}"
      )

      {:error, reason}
  end
end
