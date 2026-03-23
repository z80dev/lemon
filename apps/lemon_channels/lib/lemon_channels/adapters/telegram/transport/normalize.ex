defmodule LemonChannels.Adapters.Telegram.Transport.Normalize do
  @moduledoc """
  Telegram-local normalization helpers for raw updates and transport timer events.

  The goal is to stop re-parsing raw Telegram payload shapes throughout the
  transport shell. This module keeps the normalization boundary local to the
  Telegram adapter for now.
  """

  alias LemonChannels.Adapters.Telegram.Inbound
  alias LemonChannels.Adapters.Telegram.Transport.InboundContext
  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor

  @spec event(map(), term(), integer() | nil) ::
          {:ok, InboundContext.t()} | {:error, term()} | {:skip, map()}
  def event(state, event, update_id \\ nil)

  def event(state, {:debounce_flush, scope_key, debounce_ref}, _update_id) do
    {:ok,
     %InboundContext{
       kind: :buffer_flush,
       account_id: account_id(state),
       scope_key: scope_key,
       debounce_ref: debounce_ref,
       meta: %{scope_key: scope_key}
     }}
  end

  def event(state, {:media_group_flush, group_key, debounce_ref}, _update_id) do
    {:ok,
     %InboundContext{
       kind: :media_group_flush,
       account_id: account_id(state),
       scope_key: group_key,
       debounce_ref: debounce_ref,
       meta: %{scope_key: group_key}
     }}
  end

  def event(state, {:approval_requested, payload}, _update_id) do
    {:ok,
     %InboundContext{
       kind: :approval_requested,
       account_id: account_id(state),
       raw_update: payload,
       meta: %{}
     }}
  end

  def event(state, %{"callback_query" => callback_query} = update, update_id) do
    message = callback_query["message"] || %{}
    chat = message["chat"] || %{}

    {:ok,
     %InboundContext{
       kind: :callback_query,
       account_id: account_id(state),
       chat_id: parse_int(chat["id"]),
       thread_id: parse_int(message["message_thread_id"]),
       sender_id:
         parse_int(get_in(callback_query, ["from", "id"])) ||
           get_in(callback_query, ["from", "id"]),
       message_id: parse_int(message["message_id"]),
       callback_id: callback_query["id"],
       callback_data: callback_query["data"],
       raw_update: update,
       meta: %{update_id: update_id}
     }}
  end

  def event(state, update, update_id) when is_map(update) do
    with {:ok, inbound} <- Inbound.normalize(update) do
      inbound = UpdateProcessor.prepare_inbound(inbound, state, update, update_id)

      {:ok,
       %InboundContext{
         kind: :message,
         account_id: inbound.account_id,
         chat_id: meta_int(inbound.meta, :chat_id),
         thread_id: meta_int(inbound.meta, :topic_id),
         sender_id: sender_id(inbound),
         message_id: parse_int(inbound.message[:id] || inbound.message["id"]),
         user_msg_id: meta_int(inbound.meta, :user_msg_id),
         text: inbound.message[:text] || inbound.message["text"],
         reply_to_text: inbound.meta[:reply_to_text],
         reply_to_id: parse_int(inbound.message[:reply_to_id] || inbound.message["reply_to_id"]),
         media_group_id: inbound.meta[:media_group_id],
         raw_update: update,
         inbound: inbound,
         meta: inbound.meta || %{}
       }}
    else
      {:error, reason} -> {:error, reason}
      {:skip, new_state} -> {:skip, new_state}
    end
  end

  def event(_state, _event, _update_id), do: {:error, :unsupported_event}

  defp meta_int(meta, key) when is_map(meta) do
    parse_int(meta[key] || meta[to_string(key)])
  end

  defp account_id(state) when is_map(state), do: Map.get(state, :account_id)
  defp account_id(_state), do: nil

  defp sender_id(%{sender: %{id: id}}), do: parse_int(id) || id
  defp sender_id(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
