defmodule LemonChannels.Adapters.Telegram.Transport.UpdateProcessor do
  @moduledoc """
  Update processing pipeline for the Telegram transport.

  Handles the flow from raw Telegram updates through normalization,
  authorization, deduplication, and routing. Also includes known-target
  indexing for chat metadata tracking.
  """

  require Logger

  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.ChatScope
  alias LemonCore.MapHelpers
  alias LemonCore.Store, as: CoreStore

  @known_target_write_interval_ms 30_000

  # ---------------------------------------------------------------------------
  # Update processing pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Check authorization and deduplication, then hand off to the inbound handler.

  The `handle_fn` callback receives `(state, inbound)` and returns the
  updated state. This allows the main GenServer to supply its own
  `handle_inbound_message/2`.
  """
  def route_authorized_inbound(state, inbound, handle_fn) do
    inbound = enrich_for_router(inbound, state)
    key = TransportShared.inbound_message_dedupe_key(inbound)

    with :ok <- authorized_inbound_reason(state, inbound),
         :new <- TransportShared.check_and_mark_dedupe(:channels, key, state.dedupe_ttl_ms) do
      handle_fn.(state, inbound)
    else
      {:drop, why} ->
        maybe_log_drop(state, inbound, why)
        state

      :seen ->
        maybe_log_drop(state, inbound, :dedupe)
        state
    end
  end

  @doc """
  Enrich an inbound with update_id, account_id, and reply-to text.
  """
  def prepare_inbound(inbound, state, update, id) do
    meta = Map.put(inbound.meta || %{}, :update_id, id)

    inbound
    |> Map.put(:account_id, state.account_id)
    |> Map.put(:meta, meta)
    |> maybe_put_reply_to_text(update)
  end

  # ---------------------------------------------------------------------------
  # Known-target indexing
  # ---------------------------------------------------------------------------

  @doc """
  Index chat metadata from an update for known-target tracking.

  This allows the system to maintain a registry of chats/topics that have
  interacted with the bot.
  """
  def maybe_index_known_target(state, update) when is_map(update) do
    account_id = state.account_id || "default"
    message = extract_chat_message(update)

    with true <- is_binary(account_id) and account_id != "",
         true <- is_map(message),
         chat when is_map(chat) <- message["chat"],
         chat_id when is_integer(chat_id) <- parse_int(chat["id"]) do
      topic_id = parse_int(message["message_thread_id"])
      key = {account_id, chat_id, topic_id}
      existing = CoreStore.get(:telegram_known_targets, key) || %{}
      now = System.system_time(:millisecond)

      entry =
        %{
          channel_id: "telegram",
          account_id: account_id,
          peer_kind: peer_kind_from_chat_type(chat["type"]),
          peer_id: to_string(chat_id),
          thread_id: if(is_integer(topic_id), do: to_string(topic_id), else: nil),
          chat_id: chat_id,
          topic_id: topic_id,
          chat_type: coalesce_text(chat["type"], existing, :chat_type),
          chat_title: coalesce_text(chat["title"], existing, :chat_title),
          chat_username: coalesce_text(chat["username"], existing, :chat_username),
          chat_display_name: coalesce_text(chat_display_name(chat), existing, :chat_display_name),
          topic_name:
            coalesce_text(extract_topic_name_from_message(message), existing, :topic_name),
          updated_at_ms: now,
          first_seen_at_ms: map_get(existing, :first_seen_at_ms) || now
        }
        |> maybe_put(
          :last_message_id,
          parse_int(message["message_id"]) || map_get(existing, :last_message_id)
        )

      if should_persist_known_target?(existing, entry, now) do
        _ = CoreStore.put(:telegram_known_targets, key, entry)
      end

      state
    else
      _ -> state
    end
  rescue
    _ -> state
  end

  def maybe_index_known_target(state, _), do: state

  # ---------------------------------------------------------------------------
  # Message extraction helpers
  # ---------------------------------------------------------------------------

  def extract_chat_message(update) when is_map(update) do
    update["message"] ||
      update["edited_message"] ||
      update["channel_post"] ||
      get_in(update, ["callback_query", "message"])
  end

  def extract_chat_message(_), do: nil

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp should_persist_known_target?(existing, entry, now_ms) do
    significant_change? = known_target_changed?(existing, entry)
    existing_updated_at_ms = parse_int(map_get(existing, :updated_at_ms)) || 0

    significant_change? or now_ms - existing_updated_at_ms >= @known_target_write_interval_ms
  end

  defp known_target_changed?(existing, entry) do
    keys = [
      :channel_id,
      :account_id,
      :peer_kind,
      :peer_id,
      :thread_id,
      :chat_id,
      :topic_id,
      :chat_type,
      :chat_title,
      :chat_username,
      :chat_display_name,
      :topic_name
    ]

    Enum.any?(keys, fn key ->
      map_get(existing, key) != map_get(entry, key)
    end)
  end

  defp extract_topic_name_from_message(message) when is_map(message) do
    (message["forum_topic_created"] && message["forum_topic_created"]["name"]) ||
      (message["forum_topic_edited"] && message["forum_topic_edited"]["name"]) ||
      get_in(message, ["reply_to_message", "forum_topic_created", "name"]) ||
      get_in(message, ["reply_to_message", "forum_topic_edited", "name"])
  end

  defp extract_topic_name_from_message(_), do: nil

  defp chat_display_name(%{"type" => "private"} = chat) do
    [chat["first_name"], chat["last_name"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
    |> case do
      "" -> chat["username"]
      name -> name
    end
  end

  defp chat_display_name(chat) when is_map(chat) do
    chat["title"] || chat["username"]
  end

  defp chat_display_name(_), do: nil

  defp coalesce_text(value, existing, key) do
    normalize_blank(value) || normalize_blank(map_get(existing, key))
  end

  defp map_get(map, key), do: MapHelpers.get_key(map, key)

  defp maybe_put_reply_to_text(inbound, update) do
    reply_to_text = extract_reply_to_text(update)

    if is_binary(reply_to_text) and reply_to_text != "" do
      %{inbound | meta: Map.put(inbound.meta || %{}, :reply_to_text, reply_to_text)}
    else
      inbound
    end
  rescue
    _ -> inbound
  end

  defp extract_reply_to_text(update) when is_map(update) do
    message =
      cond do
        is_map(update["message"]) -> update["message"]
        is_map(update["edited_message"]) -> update["edited_message"]
        is_map(update["channel_post"]) -> update["channel_post"]
        true -> %{}
      end

    reply = message["reply_to_message"] || %{}
    reply["text"] || reply["caption"]
  end

  defp authorized_inbound_reason(state, inbound) do
    {chat_id, _thread_id} = extract_chat_ids(inbound)

    cond do
      not is_integer(chat_id) ->
        {:drop, :no_chat_id}

      not allowed_chat?(state.allowed_chat_ids, chat_id) ->
        {:drop, :chat_not_allowed}

      state.deny_unbound_chats ->
        scope = inbound_scope(inbound, chat_id)

        if is_nil(scope) do
          {:drop, :unbound_chat}
        else
          if binding_exists?(scope), do: :ok, else: {:drop, :unbound_chat}
        end

      true ->
        :ok
    end
  rescue
    _ -> {:drop, :unauthorized_error}
  end

  defp inbound_scope(inbound, chat_id) when is_integer(chat_id) do
    topic_id = parse_int(inbound.peer.thread_id)
    %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
  rescue
    _ -> nil
  end

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

  defp enrich_for_router(inbound, state) do
    {chat_id, topic_id} = extract_chat_ids(inbound)

    scope =
      if is_integer(chat_id) do
        %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
      else
        nil
      end

    agent_id =
      if scope do
        LemonChannels.BindingResolver.resolve_agent_id(scope)
      end

    base_queue_mode =
      if scope do
        LemonChannels.BindingResolver.resolve_queue_mode(scope)
      end

    cwd =
      if scope do
        LemonChannels.BindingResolver.resolve_cwd(scope)
      end

    {override_mode, stripped_after_override} =
      parse_queue_override(inbound.message.text, state.allow_queue_override)

    queue_mode = override_mode || base_queue_mode || :collect
    text_after_queue = if override_mode, do: stripped_after_override, else: inbound.message.text

    {directive_engine, text_after_directive} = strip_engine_directive(text_after_queue)

    engine_id = directive_engine || extract_command_hint(text_after_directive)

    meta =
      (inbound.meta || %{})
      |> Map.put(:agent_id, agent_id || (inbound.meta && inbound.meta[:agent_id]) || "default")
      |> Map.put(:queue_mode, queue_mode)
      |> Map.put(:engine_id, engine_id)
      |> Map.put(:directive_engine, directive_engine)
      |> Map.put(:topic_id, topic_id)
      |> maybe_put(:cwd, cwd)

    message = Map.put(inbound.message, :text, text_after_directive)

    %{inbound | message: message, meta: meta}
  end

  defp strip_engine_directive(text) when is_binary(text) do
    trimmed = String.trim(text)

    case Regex.run(~r{^/(lemon|codex|claude|opencode|pi|echo)\b\s*(.*)$}is, trimmed) do
      [_, engine, rest] -> {String.downcase(engine), String.trim(rest)}
      _ -> {nil, trimmed}
    end
  end

  defp strip_engine_directive(_), do: {nil, ""}

  defp parse_queue_override(text, allow_override) do
    if allow_override do
      trimmed = String.trim_leading(text || "")

      cond do
        match_override?(trimmed, "steer") ->
          {:steer, strip_queue_prefix(trimmed, "/steer")}

        match_override?(trimmed, "followup") ->
          {:followup, strip_queue_prefix(trimmed, "/followup")}

        match_override?(trimmed, "interrupt") ->
          {:interrupt, strip_queue_prefix(trimmed, "/interrupt")}

        true ->
          {nil, text}
      end
    else
      {nil, text}
    end
  end

  defp match_override?(text, cmd) do
    Regex.match?(~r/^\/#{cmd}(?:\s|$)/i, text)
  end

  defp strip_queue_prefix(text, prefix) do
    prefix_len = String.length(prefix)
    remaining = String.slice(text, prefix_len..-1//1)
    String.trim_leading(remaining)
  end

  defp extract_command_hint(text) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r{^/([a-z][a-z0-9_-]*)(?:\s|$)}i, trimmed) do
      [_, cmd] ->
        cmd_lower = String.downcase(cmd)

        if Code.ensure_loaded?(LemonChannels.EngineRegistry) and
             function_exported?(LemonChannels.EngineRegistry, :get_engine, 1) and
             LemonChannels.EngineRegistry.get_engine(cmd_lower) do
          cmd_lower
        else
          nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp maybe_log_drop(state, inbound, reason) do
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

  defp peer_kind_from_chat_type("private"), do: :dm
  defp peer_kind_from_chat_type("group"), do: :group
  defp peer_kind_from_chat_type("supergroup"), do: :group
  defp peer_kind_from_chat_type("channel"), do: :channel
  defp peer_kind_from_chat_type(_), do: :unknown

  defp extract_chat_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    {chat_id, thread_id}
  end

  defp normalize_blank(nil), do: nil
  defp normalize_blank(""), do: nil
  defp normalize_blank(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end
end
