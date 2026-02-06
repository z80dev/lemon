defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport that normalizes messages and forwards them to LemonRouter.

  This transport wraps the existing LemonGateway.Telegram.Transport polling logic
  but routes messages through the new lemon_channels -> lemon_router pipeline.
  """

  use GenServer

  require Logger

  alias LemonGateway.BindingResolver
  alias LemonChannels.Adapters.Telegram.Inbound
  alias LemonGateway.Telegram.OffsetStore

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000

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
        allow_queue_override:
          config[:allow_queue_override] || config["allow_queue_override"] || false,
        account_id: account_id,
        # If we're configured to drop pending updates on boot, start from 0 so we can
        # advance to the real "latest" update_id even if a stale stored offset is ahead.
        offset:
          if(drop_pending_updates, do: 0, else: initial_offset(config_offset, stored_offset)),
        drop_pending_updates?: drop_pending_updates,
        drop_pending_done?: false
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

  # Tool execution approval requests/resolutions are delivered on the `exec_approvals` bus topic.
  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    maybe_send_approval_request(state, payload)
    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
    case state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms) do
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

  defp handle_updates(state, updates) do
    Enum.reduce(updates, {state, state.offset}, fn update, {acc_state, max_id} ->
      id = update["update_id"] || max_id

      cond do
        is_map(update) and Map.has_key?(update, "callback_query") ->
          handle_callback_query(acc_state, update["callback_query"])

        true ->
          # Normalize and route through lemon_router
          case Inbound.normalize(update) do
            {:ok, inbound} ->
              # Set account_id from config
              inbound = %{inbound | account_id: acc_state.account_id}
              inbound = enrich_for_router(inbound, acc_state)

              # Check dedupe
              key = dedupe_key(inbound)

              if not is_seen?(key, acc_state.dedupe_ttl_ms) do
                mark_seen(key, acc_state.dedupe_ttl_ms)
                route_to_router(inbound)
              end

            {:error, _reason} ->
              # Unsupported update type, skip
              :ok
          end
      end

      {acc_state, max(max_id, id)}
    end)
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
        %LemonGateway.Types.ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
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

  defp is_seen?(key, ttl_ms) do
    case :ets.lookup(@dedupe_table, key) do
      [{^key, expires_at}] ->
        now = System.system_time(:millisecond)

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
    expires_at = System.system_time(:millisecond) + ttl_ms
    :ets.insert(@dedupe_table, {key, expires_at})
  rescue
    _ -> :ok
  end
end
