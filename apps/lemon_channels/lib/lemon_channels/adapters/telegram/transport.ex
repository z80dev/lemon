defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport that normalizes messages and forwards them to LemonRouter.

  This transport wraps the existing LemonGateway.Telegram.Transport polling logic
  but routes messages through the new lemon_channels -> lemon_router pipeline.
  """

  use GenServer

  require Logger

  alias LemonGateway.BindingResolver
  alias LemonGateway.Types.ChatScope
  alias LemonChannels.Adapters.Telegram.Inbound
  alias LemonGateway.Telegram.OffsetStore

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Source of truth is TOML-backed LemonGateway.Config, but allow Application env
    # overrides (used in tests and local dev) and per-process opts.
    base = Keyword.get(opts, :config, LemonGateway.Config.get(:telegram) || %{})

    config =
      base
      |> merge_config(Application.get_env(:lemon_gateway, :telegram))
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    token = config[:bot_token] || config["bot_token"]

    if is_binary(token) and token != "" do
      # Initialize dedupe ETS table
      ensure_dedupe_table()

      account_id = config[:account_id] || config["account_id"] || "default"
      config_offset = config[:offset] || config["offset"]
      stored_offset = OffsetStore.get(account_id, token)

      drop_pending_updates =
        config[:drop_pending_updates] || config["drop_pending_updates"] || false

      # If enabled, drop any pending Telegram updates on every boot unless an explicit offset is set.
      # This prevents the bot from replying to historical messages after downtime.
      drop_pending_updates = drop_pending_updates && is_nil(config_offset)

      state = %{
        token: token,
        api_mod: config[:api_mod] || LemonGateway.Telegram.API,
        poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
        dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
        debounce_ms: config[:debounce_ms] || config["debounce_ms"] || @default_debounce_ms,
        allow_queue_override:
          config[:allow_queue_override] || config["allow_queue_override"] || false,
        allowed_chat_ids: parse_allowed_chat_ids(config[:allowed_chat_ids] || config["allowed_chat_ids"]),
        deny_unbound_chats:
          config[:deny_unbound_chats] || config["deny_unbound_chats"] || false,
        account_id: account_id,
        # If we're configured to drop pending updates on boot, start from 0 so we can
        # advance to the real "latest" update_id even if a stale stored offset is ahead.
        offset:
          if(drop_pending_updates, do: 0, else: initial_offset(config_offset, stored_offset)),
        drop_pending_updates?: drop_pending_updates,
        drop_pending_done?: false,
        buffers: %{}
      }

      maybe_subscribe_exec_approvals()
      send(self(), :poll)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_updates(state)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, state}
  end

  # Debounce flush for buffered non-command messages.
  def handle_info({:debounce_flush, scope_key, debounce_ref}, state) do
    {buffer, buffers} = Map.pop(state.buffers, scope_key)

    state =
      cond do
        buffer && buffer.debounce_ref == debounce_ref ->
          submit_buffer(buffer, state)
          %{state | buffers: buffers}

        buffer ->
          # Stale timer; keep latest buffer.
          %{state | buffers: Map.put(state.buffers, scope_key, buffer)}

        true ->
          state
      end

    {:noreply, state}
  end

  # Tool execution approval requests/resolutions are delivered on the `exec_approvals` bus topic.
  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    maybe_send_approval_request(state, payload)
    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
    case safe_get_updates(state) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        if state.drop_pending_updates? and not state.drop_pending_done? do
          if updates == [] do
            # Nothing to drop; we're at the live edge.
            %{state | drop_pending_done?: true}
          else
            # Keep dropping until Telegram returns an empty batch (there can be >100 pending).
            max_id = max_update_id(updates, state.offset)
            new_offset = max(state.offset, max_id + 1)
            persist_offset(state, new_offset)
            %{state | offset: new_offset, drop_pending_done?: false}
          end
        else
          {state, max_id} = handle_updates(state, updates)
          new_offset = max(state.offset, max_id + 1)
          persist_offset(state, new_offset)
          %{state | offset: new_offset}
        end

      _ ->
        state
    end
  rescue
    e ->
      Logger.warning("Telegram poll error: #{inspect(e)}")
      state
  end

  defp safe_get_updates(state) do
    try do
      state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms)
    catch
      :exit, reason ->
        Logger.debug("Telegram get_updates exited: #{inspect(reason)}")
        {:error, {:exit, reason}}
    end
  end

  defp handle_updates(state, updates) do
    Enum.reduce(updates, {state, state.offset}, fn update, {acc_state, max_id} ->
      id = update["update_id"] || max_id

      cond do
        is_map(update) and Map.has_key?(update, "callback_query") ->
          if authorized_callback_query?(acc_state, update["callback_query"]) do
            handle_callback_query(acc_state, update["callback_query"])
          end

          {acc_state, max(max_id, id)}

        true ->
          # Normalize and route through lemon_router
          case Inbound.normalize(update) do
            {:ok, inbound} ->
              # Set account_id from config
              inbound = %{inbound | account_id: acc_state.account_id}

              inbound =
                inbound
                |> maybe_put_reply_to_text(update)
                |> enrich_for_router(acc_state)

              # Check dedupe
              key = dedupe_key(inbound)

              cond do
                not authorized_inbound?(acc_state, inbound) ->
                  {acc_state, max(max_id, id)}

                is_seen?(key, acc_state.dedupe_ttl_ms) ->
                  {acc_state, max(max_id, id)}

                true ->
                  mark_seen(key, acc_state.dedupe_ttl_ms)
                  acc_state = handle_inbound_message(acc_state, inbound)
                  {acc_state, max(max_id, id)}
              end

            {:error, _reason} ->
              # Unsupported update type, skip
              {acc_state, max(max_id, id)}
          end
      end
    end)
  end

  defp handle_inbound_message(state, inbound) do
    text = inbound.message.text || ""
    original_text = text

    cond do
      cancel_command?(original_text) ->
        maybe_cancel_by_reply(state, inbound)
        state

      command_message?(original_text) ->
        submit_inbound_now(state, inbound)

      true ->
        enqueue_buffer(state, inbound)
    end
  rescue
    _ -> state
  end

  defp enqueue_buffer(state, inbound) do
    key = scope_key(inbound)

    case Map.get(state.buffers, key) do
      nil ->
        debounce_ref = make_ref()
        timer_ref = Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

        buffer = %{
          inbound: inbound,
          messages: [message_entry(inbound)],
          timer_ref: timer_ref,
          debounce_ref: debounce_ref
        }

        %{state | buffers: Map.put(state.buffers, key, buffer)}

      buffer ->
        _ = Process.cancel_timer(buffer.timer_ref)
        debounce_ref = make_ref()
        timer_ref = Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

        messages = buffer.messages ++ [message_entry(inbound)]
        inbound_last = inbound

        buffer = %{
          buffer
          | inbound: inbound_last,
            messages: messages,
            timer_ref: timer_ref,
            debounce_ref: debounce_ref
        }

        %{state | buffers: Map.put(state.buffers, key, buffer)}
    end
  end

  defp submit_buffer(%{messages: messages, inbound: inbound_last}, state) do
    {joined_text, last_id, last_reply_to_text, last_reply_to_id} = join_messages(messages)

    inbound =
      inbound_last
      |> put_in([Access.key!(:message), :text], joined_text)
      |> put_in([Access.key!(:message), :id], to_string(last_id))
      |> put_in([Access.key!(:message), :reply_to_id], last_reply_to_id)
      |> put_in([Access.key!(:meta), :user_msg_id], last_id)
      |> put_in([Access.key!(:meta), :reply_to_text], last_reply_to_text)

    submit_inbound_now(state, inbound)
  end

  defp submit_inbound_now(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

    progress_msg_id =
      if is_integer(chat_id) and is_integer(user_msg_id) do
        send_progress(state, chat_id, thread_id, user_msg_id)
      else
        nil
      end

    meta =
      (inbound.meta || %{})
      |> Map.put(:progress_msg_id, progress_msg_id)
      |> Map.put(:topic_id, thread_id)

    inbound = %{inbound | meta: meta}
    route_to_router(inbound)
    state
  end

  defp send_progress(state, chat_id, thread_id, reply_to_message_id) do
    opts =
      %{}
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("message_thread_id", thread_id)

    case state.api_mod.send_message(state.token, chat_id, "Running…", opts, nil) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} -> msg_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_cancel_by_reply(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    reply_to_id = inbound.message.reply_to_id || inbound.meta[:reply_to_id]

    if is_integer(chat_id) and reply_to_id do
      case Integer.parse(to_string(reply_to_id)) do
        {progress_msg_id, _} ->
          scope = %LemonGateway.Types.ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

          if Code.ensure_loaded?(LemonGateway.Runtime) and
               function_exported?(LemonGateway.Runtime, :cancel_by_progress_msg, 2) do
            LemonGateway.Runtime.cancel_by_progress_msg(scope, progress_msg_id)
          end

          :ok

        _ ->
          :ok
      end
    end

    state
  rescue
    _ -> state
  end

  defp message_entry(inbound) do
    %{
      id: parse_int(inbound.message.id) || inbound.meta[:user_msg_id],
      text: inbound.message.text || "",
      reply_to_text: inbound.meta[:reply_to_text],
      reply_to_id: inbound.message.reply_to_id
    }
  end

  defp join_messages(messages) do
    text = Enum.map_join(messages, "\n\n", & &1.text)
    last = List.last(messages)
    {text, last.id, last.reply_to_text, last.reply_to_id}
  end

  defp scope_key(inbound) do
    chat_id = inbound.meta[:chat_id] || inbound.peer.id
    thread_id = inbound.peer.thread_id
    {chat_id, thread_id}
  end

  defp cancel_command?(text) do
    String.trim(String.downcase(text || "")) == "/cancel"
  end

  defp command_message?(text) do
    String.trim_leading(text || "") |> String.starts_with?("/")
  end

  defp authorized_inbound?(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)

    cond do
      not is_integer(chat_id) ->
        false

      not allowed_chat?(state.allowed_chat_ids, chat_id) ->
        false

      state.deny_unbound_chats ->
        scope = inbound_scope(inbound, chat_id)
        is_nil(scope) == false and binding_exists?(scope)

      true ->
        true
    end
  rescue
    _ -> false
  end

  defp authorized_callback_query?(state, cb) when is_map(cb) do
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

  defp authorized_callback_query?(_state, _cb), do: false

  defp inbound_scope(inbound, chat_id) when is_integer(chat_id) do
    topic_id = parse_int(inbound.peer.thread_id)
    %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
  rescue
    _ -> nil
  end

  defp binding_exists?(%ChatScope{} = scope) do
    case BindingResolver.resolve_binding(scope) do
      nil -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  defp allowed_chat?(nil, _chat_id), do: true
  defp allowed_chat?(list, chat_id) when is_list(list), do: chat_id in list

  defp parse_allowed_chat_ids(nil), do: nil

  defp parse_allowed_chat_ids(list) when is_list(list) do
    parsed =
      list
      |> Enum.map(&parse_int/1)
      |> Enum.filter(&is_integer/1)

    if parsed == [], do: [], else: parsed
  end

  defp parse_allowed_chat_ids(_), do: nil

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

  defp initial_offset(config_offset, stored_offset) do
    cond do
      is_integer(config_offset) -> config_offset
      is_integer(stored_offset) -> stored_offset
      true -> 0
    end
  end

  defp max_update_id([], offset), do: offset - 1

  defp max_update_id(updates, offset) do
    Enum.reduce(updates, offset - 1, fn update, acc ->
      case update["update_id"] do
        id when is_integer(id) -> max(acc, id)
        _ -> acc
      end
    end)
  end

  defp persist_offset(state, new_offset) do
    if new_offset != state.offset do
      OffsetStore.put(state.account_id, state.token, new_offset)
    end

    :ok
  end

  defp route_to_router(inbound) do
    # Forward to LemonRouter.Router.handle_inbound/1 if available
    if Code.ensure_loaded?(LemonRouter.Router) and
         function_exported?(LemonRouter.Router, :handle_inbound, 1) do
      LemonRouter.Router.handle_inbound(inbound)
    else
      # Fallback: emit telemetry for observability
      LemonCore.Telemetry.channel_inbound("telegram", %{
        peer_id: inbound.peer.id,
        peer_kind: inbound.peer.kind
      })
    end
  rescue
    e ->
      Logger.warning("Failed to route inbound message: #{inspect(e)}")
  end

  defp merge_config(base, nil), do: base

  defp merge_config(base, cfg) when is_map(cfg) do
    Map.merge(base || %{}, cfg)
  end

  defp merge_config(base, cfg) when is_list(cfg) do
    if Keyword.keyword?(cfg) do
      Map.merge(base || %{}, Enum.into(cfg, %{}))
    else
      base || %{}
    end
  end

  defp maybe_subscribe_exec_approvals do
    if Code.ensure_loaded?(LemonCore.Bus) and function_exported?(LemonCore.Bus, :subscribe, 1) do
      _ = LemonCore.Bus.subscribe("exec_approvals")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_send_approval_request(state, payload) when is_map(payload) do
    approval_id = payload[:approval_id] || payload["approval_id"]
    pending = payload[:pending] || payload["pending"] || %{}
    session_key = pending[:session_key] || pending["session_key"]

    with true <- is_binary(approval_id) and is_binary(session_key),
         %{kind: :channel_peer, channel_id: "telegram", account_id: account_id, peer_id: peer_id} <-
           LemonCore.SessionKey.parse(session_key),
         true <- is_nil(account_id) or account_id == state.account_id,
         chat_id when is_integer(chat_id) <- parse_int(peer_id) do
      tool = pending[:tool] || pending["tool"]
      action = pending[:action] || pending["action"]

      text =
        "Approval requested: #{tool}\n\n" <>
          "Action: #{format_action(action)}\n\n" <>
          "Choose:"

      reply_markup = %{
        "inline_keyboard" => [
          [
            %{"text" => "Approve once", "callback_data" => "#{approval_id}|once"},
            %{"text" => "Deny", "callback_data" => "#{approval_id}|deny"}
          ],
          [
            %{"text" => "Session", "callback_data" => "#{approval_id}|session"},
            %{"text" => "Agent", "callback_data" => "#{approval_id}|agent"},
            %{"text" => "Global", "callback_data" => "#{approval_id}|global"}
          ]
        ]
      }

      opts = %{"reply_markup" => reply_markup}
      _ = state.api_mod.send_message(state.token, chat_id, text, opts)
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_send_approval_request(_state, _payload), do: :ok

  defp format_action(action) when is_map(action) do
    cond do
      is_binary(action["cmd"]) -> action["cmd"]
      is_binary(action[:cmd]) -> action[:cmd]
      true -> inspect(action)
    end
  end

  defp format_action(other), do: inspect(other)

  defp handle_callback_query(state, cb) when is_map(cb) do
    cb_id = cb["id"]
    data = cb["data"] || ""

    {approval_id, decision} = parse_approval_callback(data)

    if is_binary(approval_id) and decision do
      _ = LemonRouter.ApprovalsBridge.resolve(approval_id, decision)

      _ = state.api_mod.answer_callback_query(state.token, cb_id, %{"text" => "Recorded"})

      msg = cb["message"] || %{}
      chat_id = get_in(msg, ["chat", "id"])
      message_id = msg["message_id"]

      if is_integer(chat_id) and is_integer(message_id) do
        _ =
          state.api_mod.edit_message_text(
            state.token,
            chat_id,
            message_id,
            "Approval: #{decision_label(decision)}",
            %{"reply_markup" => %{"inline_keyboard" => []}}
          )
      end
    else
      _ = state.api_mod.answer_callback_query(state.token, cb_id, %{"text" => "Unknown"})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp handle_callback_query(_state, _cb), do: :ok

  defp parse_approval_callback(data) when is_binary(data) do
    case String.split(data, "|", parts: 2) do
      [approval_id, "once"] -> {approval_id, :approve_once}
      [approval_id, "session"] -> {approval_id, :approve_session}
      [approval_id, "agent"] -> {approval_id, :approve_agent}
      [approval_id, "global"] -> {approval_id, :approve_global}
      [approval_id, "deny"] -> {approval_id, :deny}
      _ -> {nil, nil}
    end
  end

  defp decision_label(:approve_once), do: "approve once"
  defp decision_label(:approve_session), do: "approve session"
  defp decision_label(:approve_agent), do: "approve agent"
  defp decision_label(:approve_global), do: "approve global"
  defp decision_label(:deny), do: "deny"
  defp decision_label(other), do: inspect(other)

  # Apply Telegram-specific behavior parity with the legacy transport:
  # - binding-based queue_mode/agent selection
  # - optional queue override commands (/steer, /followup, /interrupt)
  # - optional engine directives (/claude, /codex, /lemon) and engine hint commands (e.g. /capture)
  defp enrich_for_router(inbound, state) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    topic_id = parse_int(inbound.peer.thread_id)

    scope =
      if is_integer(chat_id) do
        %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
      else
        nil
      end

    agent_id =
      if scope do
        BindingResolver.resolve_agent_id(scope)
      end

    base_queue_mode =
      if scope do
        BindingResolver.resolve_queue_mode(scope)
      end

    {override_mode, stripped_after_override} =
      parse_queue_override(inbound.message.text, state.allow_queue_override)

    queue_mode = override_mode || base_queue_mode || :collect
    text_after_queue = if override_mode, do: stripped_after_override, else: inbound.message.text

    {directive_engine, text_after_directive} =
      if Code.ensure_loaded?(LemonGateway.Telegram.Transport) and
           function_exported?(LemonGateway.Telegram.Transport, :strip_engine_directive, 1) do
        LemonGateway.Telegram.Transport.strip_engine_directive(text_after_queue)
      else
        {nil, text_after_queue}
      end

    engine_id = directive_engine || extract_command_hint(text_after_directive)

    meta =
      (inbound.meta || %{})
      |> Map.put(:agent_id, agent_id || (inbound.meta && inbound.meta[:agent_id]) || "default")
      |> Map.put(:queue_mode, queue_mode)
      |> Map.put(:engine_id, engine_id)
      |> Map.put(:topic_id, topic_id)

    message = Map.put(inbound.message, :text, text_after_directive)

    %{inbound | message: message, meta: meta}
  end

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

        if Code.ensure_loaded?(LemonGateway.EngineRegistry) and
             function_exported?(LemonGateway.EngineRegistry, :get_engine, 1) and
             LemonGateway.EngineRegistry.get_engine(cmd_lower) do
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

  defp parse_int(nil), do: nil

  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  # Dedupe helpers

  @dedupe_table :lemon_channels_telegram_dedupe

  defp ensure_dedupe_table do
    if :ets.whereis(@dedupe_table) == :undefined do
      :ets.new(@dedupe_table, [:named_table, :public, :set])
    end

    :ok
  end

  defp dedupe_key(inbound) do
    {inbound.peer.id, inbound.message.id}
  end

  defp is_seen?(key, _ttl_ms) do
    case :ets.lookup(@dedupe_table, key) do
      [{^key, expires_at}] ->
        now = System.monotonic_time(:millisecond)

        if now < expires_at do
          true
        else
          :ets.delete(@dedupe_table, key)
          false
        end

      [] ->
        false
    end
  rescue
    _ -> false
  end

  defp mark_seen(key, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@dedupe_table, {key, expires_at})
  rescue
    _ -> :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
