defmodule LemonChannels.Adapters.Telegram.Transport.Pipeline do
  @moduledoc """
  Telegram-local inbound pipeline coordinator.

  Coordinates normalized Telegram ingress handling and invokes transport-local
  callbacks for side effects.
  """

  alias LemonChannels.Adapters.Telegram.Transport.{
    Commands,
    InboundContext,
    RuntimeState,
    UpdateProcessor
  }

  @spec run(InboundContext.t(), map(), map()) :: map()
  def run(
        %InboundContext{kind: :buffer_flush, scope_key: scope_key, debounce_ref: debounce_ref},
        state,
        callbacks
      ) do
    case RuntimeState.take_current_buffer(state, scope_key, debounce_ref) do
      {state, nil} -> state
      {state, buffer} -> callbacks.submit_buffer.(state, buffer)
    end
  end

  def run(
        %InboundContext{
          kind: :media_group_flush,
          scope_key: scope_key,
          debounce_ref: debounce_ref
        },
        state,
        callbacks
      ) do
    case RuntimeState.take_current_media_group(state, scope_key, debounce_ref) do
      {state, nil} -> state
      {state, group} ->
        callbacks.process_media_group.(state, group)
        state
    end
  end

  def run(%InboundContext{kind: :approval_requested, raw_update: payload}, state, callbacks)
      when is_map(payload) do
    callbacks.start_async_task.(state, fn ->
      callbacks.send_approval_request.(state, payload)
    end)

    state
  end

  def run(%InboundContext{kind: :callback_query, raw_update: update}, state, callbacks)
      when is_map(update) do
    callback_query = update["callback_query"] || %{}
    authorized? = UpdateProcessor.authorized_callback_query?(state, callback_query)
    state = callbacks.index_known_target.(state, update)

    if authorized? do
      callbacks.handle_callback_query.(state, callback_query)
    end

    state
  end

  def run(%InboundContext{kind: :message, raw_update: update, inbound: inbound} = ctx, state, callbacks)
      when is_map(update) and is_map(inbound) do
    # /whoami is answered before authorization: it is how an owner discovers
    # the chat id to pair, and it only echoes the requester's own ids.
    if Commands.whoami_command?(inbound.message[:text], Map.get(state, :bot_username)) do
      state = callbacks.index_known_target.(state, update)
      callbacks.reply_whoami.(state, inbound)
      state
    else
      route_message(state, update, inbound, ctx.chat_id || inbound_chat_id(inbound), callbacks)
    end
  end

  def run(_event, state, _callbacks), do: state

  defp route_message(state, update, inbound, chat_id, callbacks) do
    original_inbound = inbound

    case UpdateProcessor.route_authorized_inbound_action(state, inbound) do
      {:ok, inbound} ->
        captured? = LemonChannels.UserPromptSurface.capture(original_inbound) == true
        state = callbacks.index_known_target.(state, update)

        if captured?,
          do: state,
          else: callbacks.execute_inbound_message.(state, inbound)

      {:drop, reason, inbound} when reason in [:unpaired, :chat_not_allowed] ->
        unauthorized_message(state, inbound, chat_id, reason, callbacks)

      {:drop, reason, inbound} ->
        state = callbacks.index_known_target.(state, update)
        callbacks.maybe_log_drop.(state, inbound, reason)
        state

      {:seen, inbound} ->
        state = callbacks.index_known_target.(state, update)
        callbacks.maybe_log_drop.(state, inbound, :dedupe)
        state
    end
  end

  defp unauthorized_message(
         %{unauthorized_dm_behavior: "pair"} = state,
         inbound,
         _chat_id,
         reason,
         callbacks
       ) do
    callbacks.maybe_log_drop.(state, inbound, reason)
    if inbound.peer.kind == :dm, do: callbacks.send_unpaired_notice.(state, inbound)
    state
  end

  defp unauthorized_message(state, inbound, chat_id, :unpaired, callbacks) do
    {state, notify?} =
      RuntimeState.claim_unpaired_notice(state, chat_id, System.monotonic_time(:millisecond))

    callbacks.maybe_log_drop.(state, inbound, :unpaired)
    if notify?, do: callbacks.send_unpaired_notice.(state, inbound)
    state
  end

  defp unauthorized_message(state, inbound, _chat_id, reason, callbacks) do
    callbacks.maybe_log_drop.(state, inbound, reason)
    state
  end

  defp inbound_chat_id(inbound) do
    case (inbound.meta || %{})[:chat_id] || inbound.peer.id do
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
