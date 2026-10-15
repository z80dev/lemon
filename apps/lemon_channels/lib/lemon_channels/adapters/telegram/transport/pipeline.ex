defmodule LemonChannels.Adapters.Telegram.Transport.Pipeline do
  @moduledoc """
  Telegram-local inbound pipeline coordinator.

  This module coordinates normalized Telegram ingress handling and returns
  adapter-local actions for side effects. It is intentionally Telegram-specific
  and is not yet a shared cross-channel abstraction.
  """

  alias LemonChannels.Adapters.Telegram.Transport.{
    Commands,
    InboundContext,
    RuntimeState,
    UpdateProcessor
  }

  @type action ::
          {:index_known_target, map()}
          | {:execute_inbound_message, map()}
          | {:handle_callback_query, map()}
          | {:submit_buffer, map()}
          | {:process_media_group, map()}
          | {:send_approval_request, map()}
          | {:log_drop, map(), term()}
          | {:reply_whoami, map()}
          | {:send_unpaired_notice, map()}
          | :noop

  @spec run(InboundContext.t(), map()) :: {map(), [action()]}
  def run(
        %InboundContext{kind: :buffer_flush, scope_key: scope_key, debounce_ref: debounce_ref},
        state
      ) do
    case RuntimeState.take_current_buffer(state, scope_key, debounce_ref) do
      {state, nil} -> {state, []}
      {state, buffer} -> {state, [{:submit_buffer, buffer}]}
    end
  end

  def run(
        %InboundContext{
          kind: :media_group_flush,
          scope_key: scope_key,
          debounce_ref: debounce_ref
        },
        state
      ) do
    case RuntimeState.take_current_media_group(state, scope_key, debounce_ref) do
      {state, nil} -> {state, []}
      {state, group} -> {state, [{:process_media_group, group}]}
    end
  end

  def run(%InboundContext{kind: :approval_requested, raw_update: payload}, state)
      when is_map(payload) do
    {state, [{:send_approval_request, payload}]}
  end

  def run(%InboundContext{kind: :callback_query, raw_update: update}, state)
      when is_map(update) do
    callback_query = update["callback_query"] || %{}

    if UpdateProcessor.authorized_callback_query?(state, callback_query) do
      {state, [{:index_known_target, update}, {:handle_callback_query, callback_query}]}
    else
      {state, [{:index_known_target, update}]}
    end
  end

  def run(%InboundContext{kind: :message, raw_update: update, inbound: inbound} = ctx, state)
      when is_map(update) and is_map(inbound) do
    # /whoami is answered before authorization: it is how an owner discovers
    # the chat id to pair, and it only echoes the requester's own ids.
    if Commands.whoami_command?(inbound.message[:text], Map.get(state, :bot_username)) do
      {state, [{:index_known_target, update}, {:reply_whoami, inbound}]}
    else
      route_message(state, update, inbound, ctx.chat_id || inbound_chat_id(inbound))
    end
  end

  def run(_event, state), do: {state, [:noop]}

  defp route_message(state, update, inbound, chat_id) do
    original_inbound = inbound

    case UpdateProcessor.route_authorized_inbound_action(state, inbound) do
      {:ok, inbound} ->
        actions =
          if LemonChannels.UserPromptSurface.capture(original_inbound) == true,
            do: [{:index_known_target, update}],
            else: [{:index_known_target, update}, {:execute_inbound_message, inbound}]

        {state, actions}

      {:drop, :unpaired, inbound} ->
        {state, notify?} =
          RuntimeState.claim_unpaired_notice(
            state,
            chat_id,
            System.monotonic_time(:millisecond)
          )

        notice = if notify?, do: [{:send_unpaired_notice, inbound}], else: []
        {state, [{:log_drop, inbound, :unpaired} | notice]}

      {:drop, reason, inbound} ->
        {state, [{:index_known_target, update}, {:log_drop, inbound, reason}]}

      {:seen, inbound} ->
        {state, [{:index_known_target, update}, {:log_drop, inbound, :dedupe}]}
    end
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
