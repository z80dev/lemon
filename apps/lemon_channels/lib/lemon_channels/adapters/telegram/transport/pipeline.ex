defmodule LemonChannels.Adapters.Telegram.Transport.Pipeline do
  @moduledoc """
  Telegram-local inbound pipeline coordinator.

  This module coordinates normalized Telegram ingress handling and returns
  adapter-local actions for side effects. It is intentionally Telegram-specific
  and is not yet a shared cross-channel abstraction.
  """

  alias LemonChannels.Adapters.Telegram.Transport.{
    InboundContext,
    MessageBuffer,
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

  def run(%InboundContext{kind: :message, raw_update: update, inbound: inbound}, state)
      when is_map(update) and is_map(inbound) do
    case UpdateProcessor.route_authorized_inbound_action(state, inbound) do
      {:ok, inbound} ->
        {state, [{:index_known_target, update}, {:execute_inbound_message, inbound}]}

      {:drop, reason, inbound} ->
        {state, [{:index_known_target, update}, {:log_drop, inbound, reason}]}

      {:seen, inbound} ->
        {state, [{:index_known_target, update}, {:log_drop, inbound, :dedupe}]}
    end
  end

  def run(_event, state), do: {state, [:noop]}

  @spec buffered_inbound(map()) :: map()
  def buffered_inbound(buffer) when is_map(buffer) do
    MessageBuffer.build_inbound(buffer)
  end
end
