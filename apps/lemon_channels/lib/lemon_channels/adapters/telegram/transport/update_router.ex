defmodule LemonChannels.Adapters.Telegram.Transport.UpdateRouter do
  @moduledoc """
  Routing of Telegram update types to handlers.

  Determines whether an update is a callback query or a regular message,
  applies trigger-mode filtering (mentions-only vs all), and delegates to
  the appropriate handler callback.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Inbound
  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonChannels.Telegram.TriggerMode
  alias LemonCore.ChatScope

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Route a single Telegram update. Callback queries are handled via
  `callback_query_fn`, regular messages via `inbound_fn`.

  Returns the updated state.
  """
  def process_single_update(
        state,
        %{"callback_query" => cb} = _update,
        _id,
        callback_query_fn,
        _inbound_fn,
        voice_fn
      ) do
    _ = voice_fn
    if authorized_callback_query?(state, cb), do: callback_query_fn.(state, cb)
    state
  end

  def process_single_update(state, update, id, _callback_query_fn, inbound_fn, voice_fn) do
    with {:ok, inbound} <- Inbound.normalize(update),
         inbound <- UpdateProcessor.prepare_inbound(inbound, state, update, id),
         {:ok, inbound} <- voice_fn.(state, inbound) do
      UpdateProcessor.route_authorized_inbound(state, inbound, inbound_fn)
    else
      {:error, _reason} -> state
      {:skip, new_state} -> new_state
    end
  end

  @doc """
  Returns true when the message should be ignored due to trigger-mode
  filtering (e.g. group chats in mentions-only mode where the bot is not
  explicitly mentioned).
  """
  def should_ignore_for_trigger?(state, inbound, text) do
    case inbound.peer.kind do
      :group ->
        trigger_mode = trigger_mode_for(state, inbound)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, inbound, text)

      :channel ->
        trigger_mode = trigger_mode_for(state, inbound)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, inbound, text)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  Log a drop/ignore event when debug logging is enabled.
  """
  def maybe_log_drop(state, inbound, reason) do
    if state.debug_inbound or state.log_drops do
      meta = inbound.meta || %{}

      Logger.debug(
        "Telegram inbound dropped (#{inspect(reason)}) chat_id=#{inspect(meta[:chat_id])} update_id=#{inspect(meta[:update_id])} msg_id=#{inspect(meta[:user_msg_id])} peer=#{inspect(inbound.peer)}"
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Check whether a callback query comes from an authorized chat.
  """
  def authorized_callback_query?(state, cb) when is_map(cb) do
    msg = cb["message"] || %{}
    chat_id = get_in(msg, ["chat", "id"])

    cond do
      not is_integer(chat_id) ->
        false

      not allowed_chat?(state.allowed_chat_ids, chat_id) ->
        false

      state.deny_unbound_chats ->
        topic_id = msg["message_thread_id"]
        scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: parse_int(topic_id)}
        binding_exists?(scope)

      true ->
        true
    end
  rescue
    _ -> false
  end

  def authorized_callback_query?(_state, _cb), do: false

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp trigger_mode_for(state, inbound) do
    {chat_id, topic_id} = extract_chat_ids(inbound)
    account_id = state.account_id || "default"

    if is_integer(chat_id) do
      TriggerMode.resolve(account_id, chat_id, topic_id)
    else
      %{mode: :all, chat_mode: nil, topic_mode: nil, source: :default}
    end
  rescue
    _ -> %{mode: :all, chat_mode: nil, topic_mode: nil, source: :default}
  end

  defp explicit_invocation?(state, inbound, text) do
    Commands.command_message_for_bot?(text, state.bot_username) or
      mention_of_bot?(state, inbound) or
      reply_to_bot?(state, inbound)
  rescue
    _ -> false
  end

  defp mention_of_bot?(state, inbound) do
    bot_username = state.bot_username
    bot_id = state.bot_id
    message = inbound_message_from_update(inbound.raw)
    text = message["text"] || message["caption"] || inbound.message.text || ""

    mention_by_username =
      if is_binary(bot_username) and bot_username != "" do
        Regex.match?(~r/(?:^|\W)@#{Regex.escape(bot_username)}(?:\b|$)/i, text || "")
      else
        false
      end

    mention_by_id =
      if is_integer(bot_id) do
        entities = message_entities(message)

        Enum.any?(entities, fn entity ->
          case entity do
            %{"type" => "text_mention", "user" => %{"id" => id}} ->
              parse_int(id) == bot_id

            _ ->
              false
          end
        end)
      else
        false
      end

    mention_by_username or mention_by_id
  rescue
    _ -> false
  end

  defp reply_to_bot?(state, inbound) do
    message = inbound_message_from_update(inbound.raw)
    reply = message["reply_to_message"] || %{}
    thread_id = message["message_thread_id"]

    cond do
      reply == %{} ->
        false

      topic_root_reply?(thread_id, reply) ->
        false

      is_integer(state.bot_id) and get_in(reply, ["from", "id"]) == state.bot_id ->
        true

      is_binary(state.bot_username) and state.bot_username != "" ->
        reply_username = get_in(reply, ["from", "username"])

        is_binary(reply_username) and
          String.downcase(reply_username) == String.downcase(state.bot_username)

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp topic_root_reply?(thread_id, reply) do
    is_integer(thread_id) and is_map(reply) and reply["message_id"] == thread_id
  end

  @doc false
  def inbound_message_from_update(update) when is_map(update) do
    cond do
      is_map(update["message"]) -> update["message"]
      is_map(update["edited_message"]) -> update["edited_message"]
      is_map(update["channel_post"]) -> update["channel_post"]
      true -> %{}
    end
  end

  def inbound_message_from_update(_), do: %{}

  defp message_entities(message) when is_map(message) do
    entities = message["entities"] || message["caption_entities"]
    if is_list(entities), do: entities, else: []
  end

  defp message_entities(_), do: []

  defp binding_exists?(%ChatScope{} = scope) do
    case LemonChannels.BindingResolver.resolve_binding(scope) do
      nil -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  defp allowed_chat?(nil, _chat_id), do: true
  defp allowed_chat?(list, chat_id) when is_list(list), do: chat_id in list

  defp extract_chat_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    {chat_id, thread_id}
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end
end
