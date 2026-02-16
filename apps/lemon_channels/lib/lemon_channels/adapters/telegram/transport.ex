defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport that normalizes messages and forwards them to the router.

  This transport wraps the existing LemonGateway.Telegram.Transport polling logic
  but routes messages through the new lemon_channels -> lemon_router pipeline.
  """

  use GenServer

  require Logger

  alias LemonGateway.BindingResolver
  alias LemonGateway.Cwd
  alias LemonGateway.EngineRegistry
  alias LemonGateway.Store
  alias LemonGateway.Telegram.TriggerMode
  alias LemonGateway.Types.ChatScope
  alias LemonGateway.Types.ResumeToken
  alias LemonCore.SessionKey
  alias LemonCore.Store, as: CoreStore
  alias LemonChannels.Adapters.Telegram.Inbound
  alias LemonGateway.Telegram.OffsetStore
  alias LemonGateway.Telegram.PollerLock

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000
  @cancel_callback_prefix "lemon:cancel"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Source of truth is TOML-backed LemonGateway.Config (when running), but allow
    # Application env overrides (tests/dev) and per-process opts.
    base = LemonChannels.GatewayConfig.get(:telegram, %{})

    config =
      base
      |> merge_config(Application.get_env(:lemon_gateway, :telegram))
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    token = config[:bot_token] || config["bot_token"]

    if is_binary(token) and token != "" do
      account_id = config[:account_id] || config["account_id"] || "default"

      # Prefer the lemon_channels transport. If the legacy poller is already running
      # (transient startup ordering), stop it so we don't double-submit jobs.
      _ = stop_legacy_transport()

      case PollerLock.acquire(account_id, token) do
        :ok ->
          # Initialize dedupe ETS table
          ensure_dedupe_table()

          config_offset = config[:offset] || config["offset"]
          stored_offset = OffsetStore.get(account_id, token)

          drop_pending_updates =
            config[:drop_pending_updates] || config["drop_pending_updates"] || false

          # If enabled, drop any pending Telegram updates on every boot unless an explicit offset is set.
          # This prevents the bot from replying to historical messages after downtime.
          drop_pending_updates = drop_pending_updates && is_nil(config_offset)

          {openai_api_key, openai_base_url} = resolve_openai_provider()

          {bot_id, bot_username} =
            resolve_bot_identity(
              config[:bot_id] || config["bot_id"],
              config[:bot_username] || config["bot_username"],
              config[:api_mod] || LemonGateway.Telegram.API,
              token
            )

          state = %{
            token: token,
            api_mod: config[:api_mod] || LemonGateway.Telegram.API,
            poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
            dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
            debounce_ms: config[:debounce_ms] || config["debounce_ms"] || @default_debounce_ms,
            # When true, emit debug logs for inbound decisions (drops, routing, etc).
            debug_inbound: config[:debug_inbound] || config["debug_inbound"] || false,
            # When true, log drop/ignore reasons even if debug_inbound is false.
            log_drops: config[:log_drops] || config["log_drops"] || false,
            allow_queue_override:
              config[:allow_queue_override] || config["allow_queue_override"] || false,
            allowed_chat_ids:
              parse_allowed_chat_ids(config[:allowed_chat_ids] || config["allowed_chat_ids"]),
            deny_unbound_chats:
              config[:deny_unbound_chats] || config["deny_unbound_chats"] || false,
            account_id: account_id,
            voice_transcription:
              config[:voice_transcription] || config["voice_transcription"] || false,
            voice_transcription_model:
              config[:voice_transcription_model] || config["voice_transcription_model"] ||
                "gpt-4o-mini-transcribe",
            voice_transcription_base_url:
              normalize_blank(
                config[:voice_transcription_base_url] || config["voice_transcription_base_url"]
              ) || openai_base_url,
            voice_transcription_api_key:
              normalize_blank(
                config[:voice_transcription_api_key] || config["voice_transcription_api_key"]
              ) || openai_api_key,
            voice_max_bytes:
              config[:voice_max_bytes] || config["voice_max_bytes"] || 10 * 1024 * 1024,
            voice_transcriber:
              config[:voice_transcriber] || LemonChannels.Adapters.Telegram.VoiceTranscriber,
            # If we're configured to drop pending updates on boot, start from 0 so we can
            # advance to the real "latest" update_id even if a stale stored offset is ahead.
            offset:
              if(drop_pending_updates, do: 0, else: initial_offset(config_offset, stored_offset)),
            drop_pending_updates?: drop_pending_updates,
            drop_pending_done?: false,
            buffers: %{},
            media_groups: %{},
            # run_id => %{scope, session_key, chat_id, thread_id, user_msg_id}
            pending_new: %{},
            bot_id: bot_id,
            bot_username: bot_username,
            files: config[:files] || config["files"] || %{},
            last_poll_error: nil,
            last_poll_error_log_ts: nil
          }

          maybe_subscribe_exec_approvals()
          send(self(), :poll)
          {:ok, state}

        {:error, :locked} ->
          Logger.warning(
            "Telegram poller already running for account_id=#{inspect(account_id)}; refusing to start lemon_channels transport"
          )

          :ignore
      end
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

  # Media group flush for Telegram albums of documents.
  def handle_info({:media_group_flush, group_key, debounce_ref}, state) do
    {group, media_groups} = Map.pop(state.media_groups, group_key)

    state =
      cond do
        group && group.debounce_ref == debounce_ref ->
          process_media_group(group, state)
          %{state | media_groups: media_groups}

        group ->
          # Stale timer; keep latest buffer.
          %{state | media_groups: Map.put(state.media_groups, group_key, group)}

        true ->
          state
      end

    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  # Tool execution approval requests/resolutions are delivered on the `exec_approvals` bus topic.
  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    maybe_send_approval_request(state, payload)
    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  # Best-effort second pass to clear chat state in case a late write races with the first delete.
  def handle_info(
        {:new_session_cleanup, %ChatScope{} = scope, session_key, chat_id, thread_id},
        state
      ) do
    _ = safe_delete_chat_state(scope)
    _ = safe_delete_chat_state(session_key)
    _ = safe_delete_selected_resume(state, chat_id, thread_id)
    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  # /new triggers an internal "memory reflection" run; only clear auto-resume after it completes.
  def handle_info(%LemonCore.Event{type: :run_completed, meta: meta} = event, state) do
    run_id = (meta || %{})[:run_id] || (meta || %{})["run_id"]

    case run_id && Map.get(state.pending_new, run_id) do
      %{
        scope: %ChatScope{} = scope,
        session_key: session_key,
        chat_id: chat_id,
        thread_id: thread_id,
        user_msg_id: user_msg_id
      } = pending ->
        _ = safe_delete_chat_state(scope)
        _ = safe_delete_chat_state(session_key)
        _ = safe_delete_selected_resume(state, chat_id, thread_id)

        # Store writes are async; do a second delete shortly after to win races.
        Process.send_after(
          self(),
          {:new_session_cleanup, scope, session_key, chat_id, thread_id},
          50
        )

        topic = LemonCore.Bus.run_topic(run_id)
        _ = LemonCore.Bus.unsubscribe(topic)

        ok? =
          case event.payload do
            %{completed: %{ok: ok}} when is_boolean(ok) -> ok
            %{ok: ok} when is_boolean(ok) -> ok
            _ -> true
          end

        msg0 =
          if ok? do
            "Started a new session."
          else
            "Started a new session (memory recording failed)."
          end

        msg =
          case pending[:project] do
            %{id: id, root: root} when is_binary(id) and is_binary(root) ->
              msg0 <> "\nProject: #{id} (#{root})"

            _ ->
              msg0
          end

        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)

        {:noreply, %{state | pending_new: Map.delete(state.pending_new, run_id)}}

      _ ->
        {:noreply, state}
    end
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = PollerLock.release(state.account_id, state.token)
    :ok
  end

  defp stop_legacy_transport do
    if Code.ensure_loaded?(LemonGateway.Telegram.Transport) do
      case Process.whereis(LemonGateway.Telegram.Transport) do
        pid when is_pid(pid) ->
          GenServer.stop(pid, :normal)

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp poll_updates(state) do
    _ = PollerLock.heartbeat(state.account_id, state.token)

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

      {:error, reason} ->
        maybe_log_poll_error(state, reason)

      other ->
        maybe_log_poll_error(state, other)
    end
  rescue
    e ->
      Logger.warning("Telegram poll error: #{inspect(e)}")
      state
  end

  defp maybe_log_poll_error(state, reason) do
    now = System.monotonic_time(:millisecond)
    last_ts = state.last_poll_error_log_ts
    last_reason = state.last_poll_error

    should_log? =
      cond do
        is_nil(last_ts) ->
          true

        now - last_ts > 60_000 ->
          true

        last_reason != reason ->
          true

        true ->
          false
      end

    if should_log? do
      msg =
        case reason do
          {:http_error, 409, body} ->
            body_s = body |> to_string() |> String.slice(0, 200)

            "Telegram getUpdates returned HTTP 409 Conflict (#{body_s}). " <>
              "This usually means a webhook is set for the bot, which conflicts with polling. " <>
              "Fix: call Telegram Bot API deleteWebhook (optionally with drop_pending_updates=true), " <>
              "then restart the gateway."

          other ->
            "Telegram getUpdates failed: #{inspect(other)}"
        end

      Logger.warning(msg)
    end

    %{state | last_poll_error: reason, last_poll_error_log_ts: now}
  rescue
    _ -> state
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
    # If updates is empty, keep max_id at offset - 1 so we don't accidentally advance the offset.
    Enum.reduce(updates, {state, state.offset - 1}, fn update, {acc_state, max_id} ->
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
              inbound =
                inbound
                |> Map.put(:account_id, acc_state.account_id)
                |> then(fn inbound ->
                  # Preserve update_id for troubleshooting/log correlation.
                  meta = Map.put(inbound.meta || %{}, :update_id, id)
                  %{inbound | meta: meta}
                end)

              inbound = inbound |> maybe_put_reply_to_text(update)

              case maybe_transcribe_voice(acc_state, inbound) do
                {:ok, inbound} ->
                  inbound = enrich_for_router(inbound, acc_state)

                  # Check dedupe
                  key = dedupe_key(inbound)

                  cond do
                    true ->
                      case authorized_inbound_reason(acc_state, inbound) do
                        :ok ->
                          if is_seen?(key, acc_state.dedupe_ttl_ms) do
                            maybe_log_drop(acc_state, inbound, :dedupe)
                            {acc_state, max(max_id, id)}
                          else
                            mark_seen(key, acc_state.dedupe_ttl_ms)
                            acc_state = handle_inbound_message(acc_state, inbound)
                            {acc_state, max(max_id, id)}
                          end

                        {:drop, why} ->
                          maybe_log_drop(acc_state, inbound, why)
                          {acc_state, max(max_id, id)}
                      end
                  end

                {:skip, acc_state} ->
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
      media_group_member?(inbound) and media_group_exists?(state, inbound) ->
        enqueue_media_group(state, inbound)

      file_command?(original_text, state.bot_username) and media_group_member?(inbound) ->
        # If this is a /file put command attached to a media group document, batch the whole group.
        enqueue_media_group(state, inbound)

      file_command?(original_text, state.bot_username) ->
        handle_file_command(state, inbound)

      should_auto_put_document?(state, inbound) ->
        if media_group_member?(inbound) do
          enqueue_media_group(state, inbound)
        else
          handle_document_auto_put(state, inbound)
        end

      trigger_command?(original_text, state.bot_username) ->
        handle_trigger_command(state, inbound)

      resume_command?(original_text, state.bot_username) ->
        handle_resume_command(state, inbound)

      new_command?(original_text, state.bot_username) ->
        args = telegram_command_args(original_text, "new")
        handle_new_session(state, inbound, args)

      cancel_command?(original_text, state.bot_username) ->
        maybe_cancel_by_reply(state, inbound)
        state

      true ->
        cond do
          should_ignore_for_trigger?(state, inbound, original_text) ->
            maybe_log_drop(state, inbound, :trigger_mentions)
            state

          true ->
            inbound = maybe_mark_fork_when_busy(state, inbound)
            {state, inbound} = maybe_switch_session_from_reply(state, inbound)
            inbound = maybe_apply_selected_resume(state, inbound, original_text)

            cond do
              command_message_for_bot?(original_text, state.bot_username) ->
                submit_inbound_now(state, inbound)

              true ->
                enqueue_buffer(state, inbound)
            end
        end
    end
  rescue
    e ->
      meta = inbound.meta || %{}

      Logger.warning(
        "Telegram inbound handler crashed (chat_id=#{inspect(meta[:chat_id])} update_id=#{inspect(meta[:update_id])} msg_id=#{inspect(meta[:user_msg_id])}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      state
  end

  defp enqueue_buffer(state, inbound) do
    key = scope_key(inbound)

    case Map.get(state.buffers, key) do
      nil ->
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

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

        timer_ref =
          Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

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

    scope =
      if is_integer(chat_id) do
        %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      else
        nil
      end

    meta0 =
      (inbound.meta || %{})
      |> Map.put(:progress_msg_id, progress_msg_id)
      |> Map.put(:user_msg_id, user_msg_id)
      # Tool status messages are created lazily (only if tools/actions occur).
      |> Map.put(:status_msg_id, nil)
      |> Map.put(:topic_id, thread_id)

    {session_key, forked?} = resolve_session_key(state, inbound, scope, meta0)

    meta =
      meta0
      |> Map.put(:session_key, session_key)
      |> Map.put(:forked_session, forked?)

    # Allow reply-to routing into the correct session even while a run is in-flight.
    _ =
      maybe_index_telegram_msg_session(state, scope, session_key, [progress_msg_id, user_msg_id])

    inbound = %{inbound | meta: meta}
    route_to_router(inbound)
    state
  end

  defp send_progress(state, chat_id, thread_id, reply_to_message_id) do
    cancel_markup = %{
      "inline_keyboard" => [
        [
          %{
            "text" => "cancel",
            "callback_data" => @cancel_callback_prefix
          }
        ]
      ]
    }

    opts =
      %{}
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("message_thread_id", thread_id)
      |> maybe_put("reply_markup", cancel_markup)

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
          scope = %LemonGateway.Types.ChatScope{
            transport: :telegram,
            chat_id: chat_id,
            topic_id: thread_id
          }

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

  defp cancel_command?(text, bot_username) do
    telegram_command?(text, "cancel", bot_username)
  end

  defp new_command?(text, bot_username) do
    telegram_command?(text, "new", bot_username)
  end

  defp resume_command?(text, bot_username) do
    telegram_command?(text, "resume", bot_username)
  end

  defp trigger_command?(text, bot_username) do
    telegram_command?(text, "trigger", bot_username)
  end

  defp file_command?(text, bot_username) do
    telegram_command?(text, "file", bot_username)
  end

  defp media_group_member?(inbound) do
    mg = inbound.meta && (inbound.meta[:media_group_id] || inbound.meta["media_group_id"])
    doc = inbound.meta && (inbound.meta[:document] || inbound.meta["document"])
    is_binary(mg) and mg != "" and is_map(doc) and map_size(doc) > 0
  rescue
    _ -> false
  end

  defp media_group_key(state, inbound) do
    account_id = state.account_id || "default"
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    mg = inbound.meta && (inbound.meta[:media_group_id] || inbound.meta["media_group_id"])

    {account_id, chat_id, thread_id, mg}
  end

  defp media_group_exists?(state, inbound) do
    key = media_group_key(state, inbound)
    Map.has_key?(state.media_groups || %{}, key)
  rescue
    _ -> false
  end

  defp media_group_debounce_ms(state) do
    cfg = files_cfg(state)
    parse_int(cfg[:media_group_debounce_ms] || cfg["media_group_debounce_ms"]) || 1_000
  rescue
    _ -> 1_000
  end

  defp enqueue_media_group(state, inbound) do
    group_key = media_group_key(state, inbound)
    debounce_ms = media_group_debounce_ms(state)

    case Map.get(state.media_groups, group_key) do
      nil ->
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:media_group_flush, group_key, debounce_ref}, debounce_ms)

        group = %{
          items: [inbound],
          timer_ref: timer_ref,
          debounce_ref: debounce_ref
        }

        %{state | media_groups: Map.put(state.media_groups, group_key, group)}

      group ->
        _ = Process.cancel_timer(group.timer_ref)
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:media_group_flush, group_key, debounce_ref}, debounce_ms)

        group = %{
          group
          | items: group.items ++ [inbound],
            timer_ref: timer_ref,
            debounce_ref: debounce_ref
        }

        %{state | media_groups: Map.put(state.media_groups, group_key, group)}
    end
  rescue
    _ -> state
  end

  defp process_media_group(group, state) do
    items = group.items || []
    first = List.first(items)

    if not is_map(first) do
      :ok
    else
      chat_id = first.meta[:chat_id] || parse_int(first.peer.id)
      thread_id = parse_int(first.peer.thread_id)
      user_msg_id = first.meta[:user_msg_id] || parse_int(first.message.id)

      # If any item has a /file put command caption, use that; else auto-put behavior.
      file_put =
        Enum.find(items, fn inbound ->
          txt = inbound.message.text || ""

          file_command?(txt, state.bot_username) and
            String.starts_with?(String.trim_leading(txt), "/file") and
            String.starts_with?(String.trim(telegram_command_args(txt, "file") || ""), "put")
        end)

      if file_put do
        # Delegate to handle_file_command by synthesizing a single inbound, but batch semantics:
        handle_file_put_media_group(state, file_put, items, chat_id, thread_id, user_msg_id)
      else
        handle_auto_put_media_group(state, items, chat_id, thread_id, user_msg_id)
      end
    end
  rescue
    _ -> :ok
  end

  defp handle_auto_put_media_group(state, items, chat_id, thread_id, user_msg_id) do
    cfg = files_cfg(state)

    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, List.first(items), chat_id),
         {:ok, root} <- files_project_root(List.first(items), chat_id, thread_id) do
      uploads_dir = cfg[:uploads_dir] || cfg["uploads_dir"] || "incoming"

      results =
        Enum.map(items, fn inbound ->
          doc = (inbound.meta && (inbound.meta[:document] || inbound.meta["document"])) || %{}
          filename = doc[:file_name] || doc["file_name"] || "upload.bin"
          rel = Path.join(uploads_dir, filename)

          with {:ok, abs} <- resolve_dest_abs(root, rel),
               :ok <- ensure_not_denied(root, rel, cfg),
               {:ok, bytes} <- download_document_bytes(state, inbound),
               :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
               {:ok, final_rel, _} <- write_document(rel, abs, bytes, force: false) do
            {:ok, final_rel}
          else
            {:error, msg} -> {:error, msg}
            _ -> {:error, "upload failed"}
          end
        end)

      ok_paths = for {:ok, p} <- results, do: p
      err_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

      msg =
        cond do
          ok_paths == [] ->
            "Upload failed."

          err_count == 0 ->
            "Uploaded #{length(ok_paths)} files:\n" <> Enum.map_join(ok_paths, "\n", &"- #{&1}")

          true ->
            "Uploaded #{length(ok_paths)} files (#{err_count} failed):\n" <>
              Enum.map_join(ok_paths, "\n", &"- #{&1}")
        end

      _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
      :ok
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        :ok

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File uploads are restricted."
          )

        :ok

      _ ->
        :ok
    end
  end

  defp handle_file_put_media_group(
         state,
         file_put_inbound,
         items,
         chat_id,
         thread_id,
         user_msg_id
       ) do
    cfg = files_cfg(state)

    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
    root = BindingResolver.resolve_cwd(scope)

    args = telegram_command_args(file_put_inbound.message.text || "", "file") || ""
    parts = String.split(String.trim(args || ""), ~r/\s+/, trim: true)

    # Expect: put [--force] <path>
    rest =
      case parts do
        ["put" | tail] -> tail
        _ -> []
      end

    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, file_put_inbound, chat_id),
         {:ok, root} <- ensure_project_root(root),
         {:ok, force, dest_rel0} <- parse_file_put_args(cfg, file_put_inbound, rest) do
      # For multiple files, require a directory destination: `incoming/`
      dest_rel =
        if String.ends_with?(dest_rel0, "/") do
          dest_rel0
        else
          dest_rel0
        end

      if length(items) > 1 and not String.ends_with?(dest_rel, "/") do
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "For multiple files, use a directory path ending with '/'. Example: /file put incoming/"
          )

        :ok
      else
        results =
          Enum.map(items, fn inbound ->
            doc = (inbound.meta && (inbound.meta[:document] || inbound.meta["document"])) || %{}
            filename = doc[:file_name] || doc["file_name"] || "upload.bin"

            rel =
              if String.ends_with?(dest_rel, "/") do
                Path.join(dest_rel, filename)
              else
                dest_rel
              end

            with {:ok, abs} <- resolve_dest_abs(root, rel),
                 :ok <- ensure_not_denied(root, rel, cfg),
                 {:ok, bytes} <- download_document_bytes(state, inbound),
                 :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
                 {:ok, final_rel, _} <- write_document(rel, abs, bytes, force: force) do
              {:ok, final_rel}
            else
              {:error, msg} -> {:error, msg}
              _ -> {:error, "upload failed"}
            end
          end)

        ok_paths = for {:ok, p} <- results, do: p
        err_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

        msg =
          cond do
            ok_paths == [] ->
              "Upload failed."

            err_count == 0 ->
              "Saved #{length(ok_paths)} files:\n" <> Enum.map_join(ok_paths, "\n", &"- #{&1}")

            true ->
              "Saved #{length(ok_paths)} files (#{err_count} failed):\n" <>
                Enum.map_join(ok_paths, "\n", &"- #{&1}")
          end

        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        :ok
      end
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        :ok

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File uploads are restricted."
          )

        :ok

      _ ->
        :ok
    end
  end

  # Telegram file transfer (Takopi parity):
  # - /file put [--force] <path>
  # - /file get <path>
  # - optional auto-put for bare document uploads (configured under gateway.telegram.files)
  defp should_auto_put_document?(state, inbound) do
    cfg = files_cfg(state)

    enabled? = truthy(cfg[:enabled] || cfg["enabled"])
    auto_put? = truthy(cfg[:auto_put] || cfg["auto_put"])

    doc = inbound.meta && (inbound.meta[:document] || inbound.meta["document"])

    enabled? and auto_put? and is_map(doc) and map_size(doc) > 0 and
      not command_message_for_bot?(inbound.message.text || "", state.bot_username)
  rescue
    _ -> false
  end

  defp handle_document_auto_put(state, inbound) do
    cfg = files_cfg(state)
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

    with true <- is_integer(chat_id),
         :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, inbound, chat_id),
         {:ok, root} <- files_project_root(inbound, chat_id, thread_id),
         {:ok, dest_rel} <- auto_put_destination(cfg, inbound),
         {:ok, dest_abs} <- resolve_dest_abs(root, dest_rel),
         :ok <- ensure_not_denied(root, dest_rel, cfg),
         {:ok, bytes} <- download_document_bytes(state, inbound),
         :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
         {:ok, final_rel, _final_abs} <- write_document(dest_rel, dest_abs, bytes, force: false) do
      _ = send_system_message(state, chat_id, thread_id, user_msg_id, "Uploaded: #{final_rel}")

      mode = cfg[:auto_put_mode] || cfg["auto_put_mode"] || "upload"
      caption = String.trim(inbound.message.text || "")

      cond do
        mode == "prompt" and caption != "" ->
          prompt = String.trim("#{caption}\n\n[uploaded: #{final_rel}]")
          inbound = %{inbound | message: Map.put(inbound.message, :text, prompt)}

          if should_ignore_for_trigger?(state, inbound, prompt) do
            state
          else
            {state, inbound} = maybe_switch_session_from_reply(state, inbound)
            inbound = maybe_apply_selected_resume(state, inbound, prompt)
            submit_inbound_now(state, inbound)
          end

        true ->
          state
      end
    else
      {:error, msg} when is_binary(msg) ->
        _ =
          is_integer(chat_id) && send_system_message(state, chat_id, thread_id, user_msg_id, msg)

        state

      false ->
        _ =
          is_integer(chat_id) &&
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "File uploads are restricted."
            )

        state

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp handle_file_command(state, inbound) do
    cfg = files_cfg(state)
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)
    args = telegram_command_args(inbound.message.text, "file") || ""

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      root = BindingResolver.resolve_cwd(scope)

      parts = String.split(String.trim(args || ""), ~r/\s+/, trim: true)

      case parts do
        [] ->
          _ = send_system_message(state, chat_id, thread_id, user_msg_id, file_usage())
          state

        ["put" | rest] ->
          handle_file_put(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest)

        ["get" | rest] ->
          handle_file_get(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest)

        _ ->
          _ = send_system_message(state, chat_id, thread_id, user_msg_id, file_usage())
          state
      end
    end
  rescue
    _ -> state
  end

  defp handle_file_put(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest) do
    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, inbound, chat_id),
         {:ok, root} <- ensure_project_root(root),
         {:ok, force, dest_rel} <- parse_file_put_args(cfg, inbound, rest),
         {:ok, dest_abs} <- resolve_dest_abs(root, dest_rel),
         :ok <- ensure_not_denied(root, dest_rel, cfg),
         {:ok, bytes} <- download_document_bytes(state, inbound),
         :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
         {:ok, final_rel, _final_abs} <- write_document(dest_rel, dest_abs, bytes, force: force) do
      _ = send_system_message(state, chat_id, thread_id, user_msg_id, "Saved: #{final_rel}")
      state
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        state

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File uploads are restricted."
          )

        state

      _ ->
        state
    end
  end

  defp handle_file_get(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest) do
    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, inbound, chat_id),
         {:ok, root} <- ensure_project_root(root),
         {:ok, rel} <- parse_file_get_args(rest),
         {:ok, abs} <- resolve_dest_abs(root, rel),
         :ok <- ensure_not_denied(root, rel, cfg),
         {:ok, kind, send_path, filename} <- prepare_file_get(abs),
         :ok <- enforce_path_size(send_path, cfg, :max_download_bytes, 50 * 1024 * 1024),
         :ok <- send_document_reply(state, chat_id, thread_id, user_msg_id, send_path, filename) do
      if kind == :zip do
        _ = File.rm(send_path)
      end

      state
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        state

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File downloads are restricted."
          )

        state

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp files_cfg(state) do
    cfg = state.files || %{}
    if is_map(cfg), do: cfg, else: %{}
  end

  defp truthy(v), do: v in [true, "true", 1, "1", true]

  defp ensure_files_enabled(cfg) do
    if truthy(cfg[:enabled] || cfg["enabled"]) do
      :ok
    else
      {:error, "File transfer is disabled. Enable it under [gateway.telegram.files]."}
    end
  end

  defp files_sender_allowed?(state, inbound, chat_id) do
    cfg = files_cfg(state)
    allowed = cfg[:allowed_user_ids] || cfg["allowed_user_ids"] || []
    allowed = if is_list(allowed), do: allowed, else: []

    sender_id = parse_int(inbound.sender && inbound.sender.id)

    cond do
      is_integer(sender_id) and Enum.any?(allowed, fn x -> parse_int(x) == sender_id end) ->
        true

      inbound.peer.kind in [:group, :channel] ->
        if allowed == [] do
          sender_admin?(state, chat_id, sender_id)
        else
          false
        end

      true ->
        true
    end
  rescue
    _ -> false
  end

  defp files_project_root(_inbound, chat_id, thread_id) do
    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

    root = BindingResolver.resolve_cwd(scope)
    ensure_project_root(root)
  rescue
    _ -> ensure_project_root(nil)
  end

  defp ensure_project_root(root) when is_binary(root) and byte_size(root) > 0,
    do: {:ok, Path.expand(root)}

  defp ensure_project_root(_) do
    case Cwd.default_cwd() do
      cwd when is_binary(cwd) and byte_size(cwd) > 0 -> {:ok, Path.expand(cwd)}
      _ -> {:error, "No accessible working directory configured."}
    end
  end

  defp auto_put_destination(cfg, inbound) do
    uploads_dir = cfg[:uploads_dir] || cfg["uploads_dir"] || "incoming"
    doc = (inbound.meta && (inbound.meta[:document] || inbound.meta["document"])) || %{}
    filename = doc[:file_name] || doc["file_name"] || "upload.bin"
    {:ok, Path.join(uploads_dir, filename)}
  end

  defp parse_file_put_args(cfg, inbound, rest) do
    rest = rest || []

    {force, rest} =
      case rest do
        ["--force" | tail] -> {true, tail}
        tail -> {false, tail}
      end

    dest =
      case rest do
        [path | _] when is_binary(path) and path != "" ->
          path

        _ ->
          uploads_dir = cfg[:uploads_dir] || cfg["uploads_dir"] || "incoming"
          doc = (inbound.meta && (inbound.meta[:document] || inbound.meta["document"])) || %{}
          filename = doc[:file_name] || doc["file_name"] || "upload.bin"
          Path.join(uploads_dir, filename)
      end

    if is_binary(dest) and String.trim(dest) != "" do
      {:ok, force, String.trim(dest)}
    else
      {:error, file_usage()}
    end
  end

  defp parse_file_get_args(rest) do
    case rest do
      [path | _] when is_binary(path) and path != "" -> {:ok, String.trim(path)}
      _ -> {:error, file_usage()}
    end
  end

  defp resolve_dest_abs(root, rel) do
    rel = String.trim(rel || "")

    cond do
      rel == "" ->
        {:error, file_usage()}

      Path.type(rel) == :absolute ->
        {:error, "Path must be relative to the active working directory root."}

      String.contains?(rel, "\\0") ->
        {:error, "Invalid path."}

      true ->
        root = Path.expand(root)
        abs = Path.expand(rel, root)

        if within_root?(root, abs) do
          {:ok, abs}
        else
          {:error, "Path escapes the active working directory root."}
        end
    end
  rescue
    _ -> {:error, "Invalid path."}
  end

  defp within_root?(root, abs) when is_binary(root) and is_binary(abs) do
    root = Path.expand(root)
    abs = Path.expand(abs)
    abs == root or String.starts_with?(abs, root <> "/")
  end

  defp ensure_not_denied(root, rel, cfg) do
    globs = cfg[:deny_globs] || cfg["deny_globs"] || []
    globs = if is_list(globs), do: globs, else: []

    if denied_by_globs?(root, rel, globs) do
      {:error, "Access denied for that path."}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp denied_by_globs?(_root, _rel, []), do: false

  defp denied_by_globs?(root, rel, globs) do
    root = Path.expand(root)
    abs = Path.expand(rel, root)

    Enum.any?(globs, fn glob ->
      matches = Path.wildcard(Path.join(root, glob), match_dot: true)
      Enum.any?(matches, fn m -> Path.expand(m) == abs end)
    end)
  end

  defp download_document_bytes(state, inbound) do
    doc = (inbound.meta && (inbound.meta[:document] || inbound.meta["document"])) || %{}
    file_id = doc[:file_id] || doc["file_id"]

    cond do
      not is_binary(file_id) or file_id == "" ->
        {:error, "Attach a Telegram document and use:\n/file put [--force] <path>"}

      true ->
        with {:ok, %{"ok" => true, "result" => %{"file_path" => file_path}}} <-
               state.api_mod.get_file(state.token, file_id),
             {:ok, bytes} <- state.api_mod.download_file(state.token, file_path) do
          {:ok, bytes}
        else
          _ -> {:error, "Failed to download the file from Telegram."}
        end
    end
  rescue
    _ -> {:error, "Failed to download the file from Telegram."}
  end

  defp enforce_bytes_limit(bytes, cfg, key, default_max) when is_binary(bytes) do
    max = parse_int(cfg[key] || cfg[to_string(key)]) || default_max

    if is_integer(max) and max > 0 and byte_size(bytes) > max do
      {:error, "File is too large."}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp write_document(rel, abs, bytes, opts) do
    force = Keyword.get(opts, :force, false)
    abs = Path.expand(abs)
    rel = String.trim(rel || "")

    dir = Path.dirname(abs)
    File.mkdir_p!(dir)

    cond do
      not force and File.exists?(abs) ->
        {:error, "File already exists. Use /file put --force <path> to overwrite."}

      true ->
        tmp = abs <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
        File.write!(tmp, bytes)
        File.rename!(tmp, abs)
        {:ok, rel, abs}
    end
  rescue
    _ -> {:error, "Failed to write file."}
  end

  defp prepare_file_get(abs) do
    cond do
      File.regular?(abs) ->
        {:ok, :file, abs, Path.basename(abs)}

      File.dir?(abs) ->
        tmp =
          Path.join(
            System.tmp_dir!(),
            "lemon-telegram-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}.zip"
          )

        case zip_dir(abs, tmp) do
          :ok -> {:ok, :zip, tmp, Path.basename(abs) <> ".zip"}
          {:error, _} -> {:error, "Failed to zip directory."}
        end

      true ->
        {:error, "Not found."}
    end
  rescue
    _ -> {:error, "Not found."}
  end

  defp zip_dir(dir, zip_path) do
    files =
      Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))

    _ =
      :zip.create(
        to_charlist(zip_path),
        Enum.map(files, &to_charlist/1),
        cwd: to_charlist(dir)
      )

    :ok
  rescue
    _ -> {:error, :zip_failed}
  end

  defp enforce_path_size(path, cfg, key, default_max) do
    max = parse_int(cfg[key] || cfg[to_string(key)]) || default_max

    if is_integer(max) and max > 0 do
      size =
        case File.stat(path) do
          {:ok, %File.Stat{size: s}} -> s
          _ -> 0
        end

      if is_integer(size) and size > max, do: {:error, "File is too large."}, else: :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp send_document_reply(state, chat_id, thread_id, reply_to_id, path, filename) do
    if function_exported?(state.api_mod, :send_document, 4) do
      opts =
        %{}
        |> maybe_put("reply_to_message_id", reply_to_id)
        |> maybe_put("message_thread_id", thread_id)
        |> maybe_put("caption", filename)

      case state.api_mod.send_document(state.token, chat_id, {:path, path}, opts) do
        {:ok, _} -> :ok
        _ -> {:error, "Failed to send file."}
      end
    else
      {:error, "This Telegram API module does not support sendDocument."}
    end
  rescue
    _ -> {:error, "Failed to send file."}
  end

  defp file_usage do
    "Usage:\n/file put [--force] <path>\n/file get <path>"
  end

  # Telegram commands in groups may include a bot username suffix: /cmd@BotName
  defp telegram_command?(text, cmd, bot_username) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:@([\w_]+))?(?:\s|$)/i, trimmed) do
      # No @suffix: Regex.run/2 returns only the full match (no capture entries).
      [_full] ->
        true

      [_, nil] ->
        true

      [_, ""] ->
        true

      [_, target] when is_binary(bot_username) and bot_username != "" ->
        String.downcase(target) == String.downcase(bot_username)

      [_, _target] ->
        true

      _ ->
        false
    end
  end

  defp telegram_command_args(text, cmd) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:@[\w_]+)?(?:\s+|$)(.*)$/is, trimmed) do
      [_, rest] -> String.trim(rest || "")
      _ -> nil
    end
  end

  defp maybe_select_project_for_scope(%ChatScope{} = scope, selector) when is_binary(selector) do
    sel = String.trim(selector || "")

    cond do
      sel == "" ->
        :noop

      looks_like_path?(sel) ->
        base =
          case BindingResolver.resolve_cwd(scope) do
            cwd when is_binary(cwd) and byte_size(cwd) > 0 -> cwd
            _ -> Cwd.default_cwd()
          end

        expanded =
          case Path.type(sel) do
            :absolute -> Path.expand(sel)
            :relative -> Path.expand(sel, base)
            _ -> Path.expand(sel, base)
          end

        if File.dir?(expanded) do
          id = Path.basename(expanded)
          root = expanded

          if Code.ensure_loaded?(Store) and function_exported?(Store, :put, 3) do
            Store.put(:gateway_projects_dynamic, id, %{root: root, default_engine: nil})
            Store.put(:gateway_project_overrides, scope, id)
          end

          {:ok, %{id: id, root: root}}
        else
          {:error, "Project path does not exist: #{expanded}"}
        end

      true ->
        id = sel

        case BindingResolver.lookup_project(id) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 ->
            root = Path.expand(root)

            if File.dir?(root) do
              if Code.ensure_loaded?(Store) and function_exported?(Store, :put, 3) do
                Store.put(:gateway_project_overrides, scope, id)
              end

              {:ok, %{id: id, root: root}}
            else
              {:error, "Configured project root does not exist: #{root}"}
            end

          _ ->
            {:error, "Unknown project: #{id}"}
        end
    end
  rescue
    _ -> {:error, "Failed to select project."}
  end

  defp looks_like_path?(s) when is_binary(s) do
    String.starts_with?(s, "/") or String.starts_with?(s, "~") or String.starts_with?(s, ".") or
      String.contains?(s, "/")
  end

  defp command_message?(text) do
    String.trim_leading(text || "") |> String.starts_with?("/")
  end

  defp command_message_for_bot?(text, bot_username) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r{^/([a-z][a-z0-9_]*)(?:@([\w_]+))?(?:\s|$)}i, trimmed) do
      [_, _cmd, nil] ->
        true

      [_, _cmd, ""] ->
        true

      [_, _cmd, target] when is_binary(bot_username) and bot_username != "" ->
        String.downcase(target) == String.downcase(bot_username)

      [_, _cmd, _target] ->
        true

      _ ->
        false
    end
  end

  defp maybe_switch_session_from_reply(state, inbound) do
    reply_to_id = normalize_msg_id(inbound.message.reply_to_id || inbound.meta[:reply_to_id])

    cond do
      not is_integer(reply_to_id) ->
        {state, inbound}

      true ->
        chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
        thread_id = parse_int(inbound.peer.thread_id)

        if not is_integer(chat_id) do
          {state, inbound}
        else
          scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
          session_key = build_session_key(state, inbound, scope)

          {resume, source} = resume_from_reply(state, inbound, chat_id, thread_id, reply_to_id)

          if match?(%ResumeToken{}, resume) do
            current = safe_get_chat_state(session_key) || safe_get_chat_state(scope)

            if switching_session?(current, resume) do
              set_chat_resume(scope, session_key, resume)

              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  normalize_msg_id(inbound.message.id) || inbound.meta[:user_msg_id],
                  "Resuming session: #{format_session_ref(resume)}"
                )

              inbound =
                case source do
                  :reply_text ->
                    inbound

                  :msg_index ->
                    # Ensure the very next run explicitly resumes, even if auto-resume is off.
                    maybe_prefix_resume_to_prompt(inbound, resume)
                end

              {state, inbound}
            else
              {state, inbound}
            end
          else
            {state, inbound}
          end
        end
    end
  rescue
    _ -> {state, inbound}
  end

  defp resume_from_reply(state, inbound, chat_id, thread_id, reply_to_id) do
    reply_text = inbound.meta[:reply_to_text]

    cond do
      is_binary(reply_text) and reply_text != "" ->
        case EngineRegistry.extract_resume(reply_text) do
          {:ok, %ResumeToken{} = token} -> {token, :reply_text}
          _ -> {nil, nil}
        end

      true ->
        key = {state.account_id || "default", chat_id, thread_id, reply_to_id}

        token =
          cond do
            Code.ensure_loaded?(Store) and function_exported?(Store, :get, 2) ->
              Store.get(:telegram_msg_resume, key)

            Code.ensure_loaded?(CoreStore) and function_exported?(CoreStore, :get, 2) ->
              CoreStore.get(:telegram_msg_resume, key)

            true ->
              nil
          end

        case token do
          %ResumeToken{} = tok -> {tok, :msg_index}
          _ -> {nil, nil}
        end
    end
  rescue
    _ -> {nil, nil}
  end

  defp switching_session?(nil, %ResumeToken{}), do: true

  defp switching_session?(%{} = chat_state, %ResumeToken{} = resume) do
    last_engine = chat_state[:last_engine] || chat_state["last_engine"] || chat_state.last_engine

    last_token =
      chat_state[:last_resume_token] || chat_state["last_resume_token"] ||
        chat_state.last_resume_token

    last_engine != resume.engine or last_token != resume.value
  rescue
    _ -> true
  end

  defp switching_session?(_other, _resume), do: true

  defp maybe_prefix_resume_to_prompt(inbound, %ResumeToken{} = resume) do
    if is_binary(inbound.message.text) and inbound.message.text != "" do
      resume_line = format_resume_line(resume)

      message =
        Map.put(inbound.message, :text, String.trim("#{resume_line}\n#{inbound.message.text}"))

      %{inbound | message: message}
    else
      inbound
    end
  rescue
    _ -> inbound
  end

  defp handle_resume_command(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      args = telegram_command_args(inbound.message.text, "resume") || ""

      state = drop_buffer_for(state, inbound)

      cond do
        args == "" ->
          sessions = list_recent_sessions(scope, limit: 20)

          text =
            case sessions do
              [] ->
                "No sessions found yet."

              list ->
                header = "Available sessions (most recent first):"

                body =
                  list
                  |> Enum.with_index(1)
                  |> Enum.map(fn {%{resume: r}, idx} -> "#{idx}. #{format_session_ref(r)}" end)
                  |> Enum.join("\n")

                usage = "Use /resume <number> to switch sessions."
                Enum.join([header, body, usage], "\n\n")
            end

          _ = send_system_message(state, chat_id, thread_id, user_msg_id, text)
          state

        true ->
          {selector, prompt_part} =
            case String.split(args, ~r/\s+/, parts: 2) do
              [a] -> {a, ""}
              [a, rest] -> {a, String.trim(rest || "")}
              _ -> {args, ""}
            end

          sessions = list_recent_sessions(scope, limit: 50)
          resume = resolve_resume_selector(selector, sessions)

          if match?(%ResumeToken{}, resume) do
            set_chat_resume(scope, session_key, resume)

            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Resuming session: #{format_session_ref(resume)}"
              )

            if prompt_part != "" do
              inbound =
                inbound
                |> put_in(
                  [Access.key!(:message), :text],
                  String.trim("#{format_resume_line(resume)}\n#{prompt_part}")
                )

              submit_inbound_now(state, inbound)
            else
              state
            end
          else
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Couldn't find that session. Try /resume to list sessions."
              )

            state
          end
      end
    end
  rescue
    _ -> state
  end

  defp resolve_resume_selector(selector, sessions) when is_binary(selector) do
    selector = String.trim(selector)

    cond do
      selector == "" ->
        nil

      Regex.match?(~r/^\d+$/, selector) ->
        idx = String.to_integer(selector)

        case Enum.at(sessions, idx - 1) do
          %{resume: %ResumeToken{} = r} -> r
          _ -> nil
        end

      true ->
        # Accept a full resume line (e.g., "codex resume X", "claude --resume X").
        case EngineRegistry.extract_resume(selector) do
          {:ok, %ResumeToken{} = token} ->
            token

          _ ->
            # Accept "engine token" shorthand.
            case String.split(selector, ~r/\s+/, parts: 2) do
              [engine_id, token_value] ->
                engine_id = String.downcase(engine_id || "")

                if EngineRegistry.get_engine(engine_id) && token_value && token_value != "" do
                  %ResumeToken{engine: engine_id, value: String.trim(token_value)}
                else
                  find_by_token_value(selector, sessions)
                end

              _ ->
                find_by_token_value(selector, sessions)
            end
        end
    end
  rescue
    _ -> nil
  end

  defp find_by_token_value(value, sessions) do
    v = String.trim(value || "")

    Enum.find_value(sessions, fn
      %{resume: %ResumeToken{value: ^v} = r} -> r
      _ -> nil
    end)
  end

  defp list_recent_sessions(%ChatScope{} = scope, opts) do
    limit = Keyword.get(opts, :limit, 20)

    history =
      if Code.ensure_loaded?(LemonGateway.Store) and
           function_exported?(LemonGateway.Store, :get_run_history, 2) do
        LemonGateway.Store.get_run_history(scope, limit: limit * 5)
      else
        []
      end

    history
    |> Enum.map(fn {_run_id, data} ->
      %{resume: extract_resume_from_history(data), started_at: data[:started_at] || 0}
    end)
    |> Enum.filter(fn %{resume: r} -> match?(%ResumeToken{}, r) end)
    |> Enum.sort_by(& &1.started_at, :desc)
    |> Enum.reduce([], fn %{resume: r, started_at: ts}, acc ->
      key = {r.engine, r.value}

      if Enum.any?(acc, fn %{resume: rr} -> {rr.engine, rr.value} == key end) do
        acc
      else
        acc ++ [%{resume: r, started_at: ts}]
      end
    end)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp extract_resume_from_history(data) when is_map(data) do
    summary = data[:summary] || data["summary"] || %{}
    completed = summary[:completed] || summary["completed"]

    resume =
      cond do
        is_map(completed) and is_struct(completed) and Map.has_key?(completed, :resume) ->
          Map.get(completed, :resume)

        is_map(completed) ->
          completed[:resume] || completed["resume"]

        true ->
          nil
      end

    case resume do
      %ResumeToken{} = r -> r
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_resume_from_history(_), do: nil

  defp handle_new_session(state, inbound, raw_selector) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

    state = drop_buffer_for(state, inbound)

    state =
      if is_integer(chat_id) do
        scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
        session_key = build_session_key(state, inbound, scope)

        selector =
          if is_binary(raw_selector) do
            case String.trim(raw_selector || "") do
              "" -> nil
              other -> other
            end
          else
            nil
          end

        project_result =
          case selector do
            nil -> :noop
            sel -> maybe_select_project_for_scope(scope, sel)
          end

        case project_result do
          {:error, msg} when is_binary(msg) ->
            _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
            state

          _ ->
            _ = safe_abort_session(session_key, :new_session)

            case submit_memory_reflection_before_new(
                   state,
                   inbound,
                   scope,
                   session_key,
                   chat_id,
                   thread_id,
                   user_msg_id
                 ) do
              {:ok, run_id, state} when is_binary(run_id) ->
                if Code.ensure_loaded?(LemonCore.Bus) and
                     function_exported?(LemonCore.Bus, :subscribe, 1) do
                  topic = LemonCore.Bus.run_topic(run_id)
                  _ = LemonCore.Bus.subscribe(topic)
                end

                msg =
                  case project_result do
                    {:ok, %{id: id, root: root}} ->
                      "Recording memories, then starting a new session…\nProject: #{id} (#{root})"

                    _ ->
                      "Recording memories, then starting a new session…"
                  end

                _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)

                pending = %{
                  scope: scope,
                  session_key: session_key,
                  chat_id: chat_id,
                  thread_id: thread_id,
                  user_msg_id: user_msg_id,
                  project:
                    case project_result do
                      {:ok, %{id: id, root: root}} -> %{id: id, root: root}
                      _ -> nil
                    end
                }

                %{state | pending_new: Map.put(state.pending_new, run_id, pending)}

              _ ->
                safe_delete_chat_state(scope)
                safe_delete_chat_state(session_key)
                safe_delete_selected_resume(state, chat_id, thread_id)

                msg =
                  case project_result do
                    {:ok, %{id: id, root: root}} ->
                      "Started a new session.\nProject: #{id} (#{root})"

                    _ ->
                      "Started a new session."
                  end

                _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
                state
            end
        end
      else
        state
      end

    state
  rescue
    _ -> state
  end

  defp submit_memory_reflection_before_new(
         state,
         inbound,
         %ChatScope{} = scope,
         session_key,
         _chat_id,
         thread_id,
         user_msg_id
       )
       when is_binary(session_key) do
    history = fetch_run_history_for_memory(session_key, scope, limit: 8)
    transcript = format_run_history_transcript(history, max_chars: 12_000)

    if transcript == "" do
      :skip
    else
      prompt = memory_reflection_prompt(transcript)

      # Internal run: avoid creating "Running…" / tool status messages.
      progress_msg_id = nil
      status_msg_id = nil

      engine_id = last_engine_hint(scope, session_key) || (inbound.meta || %{})[:engine_id]
      agent_id = (inbound.meta || %{})[:agent_id] || "default"

      meta =
        (inbound.meta || %{})
        |> Map.put(:progress_msg_id, progress_msg_id)
        |> Map.put(:status_msg_id, status_msg_id)
        |> Map.put(:topic_id, thread_id)
        |> Map.put(:user_msg_id, user_msg_id)
        |> Map.put(:command, :new)
        |> Map.put(:record_memories, true)
        |> Map.merge(%{
          channel_id: inbound.channel_id,
          account_id: inbound.account_id,
          peer: inbound.peer,
          sender: inbound.sender,
          raw: inbound.raw
        })

      case LemonCore.RouterBridge.submit_run(%{
             origin: :channel,
             session_key: session_key,
             agent_id: agent_id,
             prompt: prompt,
             queue_mode: :interrupt,
             engine_id: engine_id,
             meta: meta
           }) do
        {:ok, run_id} when is_binary(run_id) -> {:ok, run_id, state}
        _ -> :skip
      end
    end
  rescue
    _ -> :skip
  end

  defp submit_memory_reflection_before_new(
         _state,
         _inbound,
         _scope,
         _session_key,
         _chat_id,
         _thread_id,
         _user_msg_id
       ),
       do: :skip

  defp fetch_run_history_for_memory(session_key, %ChatScope{} = scope, opts) do
    limit = Keyword.get(opts, :limit, 8)

    if Code.ensure_loaded?(LemonGateway.Store) and
         function_exported?(LemonGateway.Store, :get_run_history, 2) do
      history = LemonGateway.Store.get_run_history(session_key, limit: limit)
      if history == [], do: LemonGateway.Store.get_run_history(scope, limit: limit), else: history
    else
      []
    end
  rescue
    _ -> []
  end

  defp format_run_history_transcript(history, opts) when is_list(history) do
    max_chars = Keyword.get(opts, :max_chars, 12_000)

    # `get_run_history/2` returns most-recent first; format oldest->newest for the model.
    text =
      history
      |> Enum.reverse()
      |> Enum.map(&format_run_history_entry/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.trim()

    if byte_size(text) > max_chars do
      String.slice(text, byte_size(text) - max_chars, max_chars)
    else
      text
    end
  rescue
    _ -> ""
  end

  defp format_run_history_transcript(_other, _opts), do: ""

  defp format_run_history_entry({_run_id, data}) when is_map(data) do
    summary = data[:summary] || data["summary"] || %{}
    prompt = summary[:prompt] || summary["prompt"] || ""

    completed = summary[:completed] || summary["completed"] || %{}

    answer =
      cond do
        is_map(completed) -> completed[:answer] || completed["answer"] || ""
        true -> ""
      end

    prompt = prompt |> to_string() |> String.trim()
    answer = answer |> to_string() |> String.trim()

    cond do
      prompt == "" and answer == "" -> ""
      answer == "" -> "User:\n#{prompt}"
      true -> "User:\n#{prompt}\n\nAssistant:\n#{answer}"
    end
  rescue
    _ -> ""
  end

  defp format_run_history_entry(_), do: ""

  defp memory_reflection_prompt(transcript) when is_binary(transcript) do
    """
    Before we start a new session, review the recent conversation transcript below.

    Task:
    - Record any durable, re-usable memories or learnings (preferences, recurring context, decisions, project facts, ongoing tasks) using the available memory workflow/tools.
    - If there is nothing worth saving, do not invent anything; just respond with "No memories to record."
    - Do not include private/secret data in durable memory.
    - In your final response, be brief (1-2 sentences) and do not paste the memories verbatim.

    Transcript (most recent portion):
    #{transcript}
    """
    |> String.trim()
  end

  defp last_engine_hint(%ChatScope{} = scope, session_key) do
    s1 = safe_get_chat_state(session_key)
    s2 = safe_get_chat_state(scope)

    engine =
      (s1 && (s1[:last_engine] || s1["last_engine"] || s1.last_engine)) ||
        (s2 && (s2[:last_engine] || s2["last_engine"] || s2.last_engine))

    if is_binary(engine) and engine != "", do: engine, else: nil
  rescue
    _ -> nil
  end

  defp drop_buffer_for(state, inbound) do
    key = scope_key(inbound)

    case Map.pop(state.buffers, key) do
      {nil, _buffers} ->
        state

      {buffer, buffers} ->
        _ = Process.cancel_timer(buffer.timer_ref)
        %{state | buffers: buffers}
    end
  end

  defp safe_delete_chat_state(key) do
    if Code.ensure_loaded?(LemonGateway.Store) and
         function_exported?(LemonGateway.Store, :delete_chat_state, 1) do
      LemonGateway.Store.delete_chat_state(key)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp safe_abort_session(session_key, reason)
       when is_binary(session_key) and byte_size(session_key) > 0 do
    _ = LemonCore.RouterBridge.abort_session(session_key, reason)
    :ok
  rescue
    _ -> :ok
  end

  defp safe_abort_session(_, _), do: :ok

  defp safe_delete_selected_resume(state, chat_id, thread_id)
       when is_integer(chat_id) do
    key = {state.account_id || "default", chat_id, thread_id}
    _ = CoreStore.delete(:telegram_selected_resume, key)
    :ok
  rescue
    _ -> :ok
  end

  defp safe_get_chat_state(key) do
    if Code.ensure_loaded?(LemonGateway.Store) and
         function_exported?(LemonGateway.Store, :get_chat_state, 1) do
      LemonGateway.Store.get_chat_state(key)
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp set_chat_resume(%ChatScope{} = scope, session_key, %ResumeToken{} = resume)
       when is_binary(session_key) do
    now = System.system_time(:millisecond)

    payload = %{
      last_engine: resume.engine,
      last_resume_token: resume.value,
      updated_at: now
    }

    if Code.ensure_loaded?(LemonGateway.Store) and
         function_exported?(LemonGateway.Store, :put_chat_state, 2) do
      LemonGateway.Store.put_chat_state(scope, payload)
      LemonGateway.Store.put_chat_state(session_key, payload)
    end

    # Persist the explicitly selected session for subsequent messages, even if
    # LemonGateway.Config.auto_resume is disabled.
    account_id = state_account_id_from_session_key(session_key)

    _ =
      CoreStore.put(
        :telegram_selected_resume,
        {account_id, scope.chat_id, scope.topic_id},
        resume
      )

    :ok
  rescue
    _ -> :ok
  end

  defp state_account_id_from_session_key(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{account_id: account_id} when is_binary(account_id) -> account_id
      _ -> "default"
    end
  rescue
    _ -> "default"
  end

  defp state_account_id_from_session_key(_), do: "default"

  defp build_session_key(state, inbound, %ChatScope{} = scope) do
    agent_id =
      inbound.meta[:agent_id] ||
        (inbound.meta && inbound.meta["agent_id"]) ||
        BindingResolver.resolve_agent_id(scope) ||
        "default"

    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "telegram",
      account_id: state.account_id || "default",
      peer_kind: inbound.peer.kind || :unknown,
      peer_id: to_string(scope.chat_id),
      thread_id: inbound.peer.thread_id
    })
  end

  defp format_resume_line(%ResumeToken{} = resume) do
    case EngineRegistry.get_engine(resume.engine) do
      nil -> "#{resume.engine} resume #{resume.value}"
      mod -> mod.format_resume(resume)
    end
  rescue
    _ -> "#{resume.engine} resume #{resume.value}"
  end

  defp format_session_ref(%ResumeToken{} = resume) do
    token = resume.value || ""

    abbreviated =
      if byte_size(token) > 40 do
        String.slice(token, 0, 40) <> "…"
      else
        token
      end

    "#{resume.engine}: #{abbreviated}"
  end

  defp normalize_msg_id(nil), do: nil
  defp normalize_msg_id(i) when is_integer(i), do: i

  defp normalize_msg_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp normalize_msg_id(_), do: nil

  defp maybe_apply_selected_resume(state, inbound, original_text) do
    meta = inbound.meta || %{}

    cond do
      # Don't interfere with Telegram slash commands; those can be engine directives etc.
      command_message?(original_text) ->
        inbound

      # Forked sessions are meant to run independently; avoid implicitly resuming
      # the currently-selected session when we auto-fork due to the base session
      # being busy.
      meta[:fork_when_busy] == true or meta["fork_when_busy"] == true ->
        inbound

      # If user already provided an explicit resume token, don't add another.
      match?({:ok, %ResumeToken{}}, EngineRegistry.extract_resume(inbound.message.text || "")) ->
        inbound

      true ->
        chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
        thread_id = parse_int(inbound.peer.thread_id)

        if is_integer(chat_id) do
          key = {state.account_id || "default", chat_id, thread_id}

          case CoreStore.get(:telegram_selected_resume, key) do
            %ResumeToken{} = token -> maybe_prefix_resume_to_prompt(inbound, token)
            _ -> inbound
          end
        else
          inbound
        end
    end
  rescue
    _ -> inbound
  end

  # Mark an inbound as eligible for a new parallel session when the base session is busy.
  #
  # This is applied before buffering so we can avoid prefixing resume tokens to
  # auto-forked sessions.
  defp maybe_mark_fork_when_busy(state, inbound) do
    reply_to_id = normalize_msg_id(inbound.message.reply_to_id || inbound.meta[:reply_to_id])

    cond do
      is_integer(reply_to_id) ->
        inbound

      true ->
        chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
        thread_id = parse_int(inbound.peer.thread_id)

        if is_integer(chat_id) do
          scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
          base_session_key = build_session_key(state, inbound, scope)

          if is_binary(base_session_key) and session_busy?(base_session_key) do
            meta = Map.put(inbound.meta || %{}, :fork_when_busy, true)
            %{inbound | meta: meta}
          else
            inbound
          end
        else
          inbound
        end
    end
  rescue
    _ -> inbound
  end

  defp session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    thread_key = {:session, session_key}

    case LemonGateway.ThreadRegistry.whereis(thread_key) do
      pid when is_pid(pid) ->
        st = :sys.get_state(pid)
        current_run = Map.get(st, :current_run) || Map.get(st, "current_run")
        jobs = Map.get(st, :jobs) || Map.get(st, "jobs")
        slot_pending = Map.get(st, :slot_pending) || Map.get(st, "slot_pending")

        queued? =
          cond do
            is_tuple(jobs) and tuple_size(jobs) == 2 ->
              :queue.len(jobs) > 0

            true ->
              false
          end

        is_pid(current_run) or slot_pending == true or queued?

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp session_busy?(_), do: false

  defp resolve_session_key(state, inbound, %ChatScope{} = scope, meta0) do
    meta = meta0 || %{}

    explicit =
      cond do
        is_binary(meta[:session_key]) and meta[:session_key] != "" -> meta[:session_key]
        is_binary(meta["session_key"]) and meta["session_key"] != "" -> meta["session_key"]
        true -> nil
      end

    base_session_key = build_session_key(state, inbound, scope)

    reply_to_id =
      normalize_msg_id(inbound.message.reply_to_id || meta[:reply_to_id] || meta["reply_to_id"])

    session_key =
      cond do
        is_binary(explicit) and explicit != "" ->
          explicit

        is_integer(reply_to_id) ->
          lookup_session_key_for_reply(state, scope, reply_to_id) || base_session_key

        (meta[:fork_when_busy] == true or meta["fork_when_busy"] == true) and
            is_integer(meta[:user_msg_id] || meta["user_msg_id"]) ->
          fork_id = meta[:user_msg_id] || meta["user_msg_id"]
          maybe_with_sub_id(base_session_key, fork_id)

        true ->
          base_session_key
      end

    forked? = is_binary(session_key) and session_key != base_session_key

    {session_key, forked?}
  rescue
    _ ->
      base_session_key = build_session_key(state, inbound, scope)
      {base_session_key, false}
  end

  defp resolve_session_key(_state, _inbound, _scope, meta0) do
    meta = meta0 || %{}

    explicit =
      cond do
        is_binary(meta[:session_key]) and meta[:session_key] != "" -> meta[:session_key]
        is_binary(meta["session_key"]) and meta["session_key"] != "" -> meta["session_key"]
        true -> nil
      end

    {explicit, false}
  end

  defp maybe_with_sub_id(session_key, sub_id)
       when is_binary(session_key) and session_key != "" and
              (is_binary(sub_id) or is_integer(sub_id)) do
    if String.contains?(session_key, ":sub:") do
      session_key
    else
      session_key <> ":sub:" <> to_string(sub_id)
    end
  rescue
    _ -> session_key
  end

  defp maybe_with_sub_id(session_key, _sub_id), do: session_key

  defp lookup_session_key_for_reply(state, %ChatScope{} = scope, reply_to_id)
       when is_integer(reply_to_id) do
    key = {state.account_id || "default", scope.chat_id, scope.topic_id, reply_to_id}

    case CoreStore.get(:telegram_msg_session, key) do
      sk when is_binary(sk) and sk != "" -> sk
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp lookup_session_key_for_reply(_state, _scope, _reply_to_id), do: nil

  defp maybe_index_telegram_msg_session(state, %ChatScope{} = scope, session_key, msg_ids)
       when is_list(msg_ids) and is_binary(session_key) and session_key != "" do
    account_id = state.account_id || "default"

    msg_ids
    |> Enum.map(&normalize_msg_id/1)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.each(fn msg_id ->
      key = {account_id, scope.chat_id, scope.topic_id, msg_id}
      _ = CoreStore.put(:telegram_msg_session, key, session_key)
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_index_telegram_msg_session(_state, _scope, _session_key, _msg_ids), do: :ok

  defp send_system_message(state, chat_id, thread_id, reply_to_message_id, text)
       when is_integer(chat_id) and is_binary(text) do
    opts =
      %{}
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("message_thread_id", thread_id)

    state.api_mod.send_message(state.token, chat_id, text, opts, nil)
  rescue
    _ -> :ok
  end

  defp resolve_bot_identity(bot_id, bot_username, api_mod, token) do
    bot_id = parse_int(bot_id) || bot_id
    bot_username = normalize_bot_username(bot_username)

    cond do
      is_integer(bot_id) and is_binary(bot_username) and bot_username != "" ->
        {bot_id, bot_username}

      function_exported?(api_mod, :get_me, 1) ->
        case api_mod.get_me(token) do
          {:ok, %{"ok" => true, "result" => %{"id" => id, "username" => username}}} ->
            {parse_int(id) || id, normalize_bot_username(username)}

          _ ->
            {bot_id, bot_username}
        end

      true ->
        {bot_id, bot_username}
    end
  rescue
    _ -> {bot_id, bot_username}
  end

  defp normalize_bot_username(nil), do: nil

  defp normalize_bot_username(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp should_ignore_for_trigger?(state, inbound, text) do
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

  defp trigger_mode_for(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    topic_id = parse_int(inbound.peer.thread_id)
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
    command_message_for_bot?(text, state.bot_username) or
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

  defp inbound_message_from_update(update) when is_map(update) do
    cond do
      is_map(update["message"]) -> update["message"]
      is_map(update["edited_message"]) -> update["edited_message"]
      is_map(update["channel_post"]) -> update["channel_post"]
      true -> %{}
    end
  end

  defp inbound_message_from_update(_), do: %{}

  defp message_entities(message) when is_map(message) do
    entities = message["entities"] || message["caption_entities"]
    if is_list(entities), do: entities, else: []
  end

  defp message_entities(_), do: []

  defp handle_trigger_command(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)
    args = telegram_command_args(inbound.message.text, "trigger") || ""
    arg = String.downcase(String.trim(args || ""))
    account_id = state.account_id || "default"

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      current = TriggerMode.resolve(account_id, chat_id, thread_id)

      case arg do
        "" ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_trigger_mode_status(current)
            )

          state

        "mentions" ->
          with true <- trigger_change_allowed?(state, inbound, chat_id),
               :ok <- TriggerMode.set(scope, account_id, :mentions) do
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                render_trigger_mode_set("mentions", scope)
              )

            state
          else
            false ->
              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  "Trigger mode can only be changed by a group admin."
                )

              state

            _ ->
              state
          end

        "all" ->
          with true <- trigger_change_allowed?(state, inbound, chat_id),
               :ok <- TriggerMode.set(scope, account_id, :all) do
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                render_trigger_mode_set("all", scope)
              )

            state
          else
            false ->
              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  "Trigger mode can only be changed by a group admin."
                )

              state

            _ ->
              state
          end

        "clear" ->
          cond do
            is_nil(thread_id) ->
              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  "No topic override to clear. Use /trigger all or /trigger mentions to set chat defaults."
                )

              state

            trigger_change_allowed?(state, inbound, chat_id) ->
              :ok = TriggerMode.clear_topic(account_id, chat_id, thread_id)

              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  "Cleared topic trigger override."
                )

              state

            true ->
              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  "Trigger mode can only be changed by a group admin."
                )

              state
          end

        _ ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Usage: /trigger [mentions|all|clear]"
            )

          state
      end
    end
  rescue
    _ -> state
  end

  defp trigger_change_allowed?(state, inbound, chat_id) do
    case inbound.peer.kind do
      :group ->
        sender_id = parse_int(inbound.sender && inbound.sender.id)

        if is_integer(sender_id) do
          sender_admin?(state, chat_id, sender_id)
        else
          false
        end

      _ ->
        true
    end
  end

  defp sender_admin?(state, chat_id, sender_id) do
    if function_exported?(state.api_mod, :get_chat_member, 3) do
      case state.api_mod.get_chat_member(state.token, chat_id, sender_id) do
        {:ok, %{"ok" => true, "result" => %{"status" => status}}}
        when status in ["administrator", "creator"] ->
          true

        _ ->
          false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp render_trigger_mode_status(%{mode: mode, chat_mode: chat_mode, topic_mode: topic_mode}) do
    base =
      case mode do
        :mentions -> "Trigger mode: mentions-only."
        _ -> "Trigger mode: all."
      end

    chat_line =
      case chat_mode do
        :mentions -> "Chat default: mentions-only."
        :all -> "Chat default: all."
        _ -> "Chat default: all."
      end

    topic_line =
      case topic_mode do
        :mentions -> "Topic override: mentions-only."
        :all -> "Topic override: all."
        _ -> "Topic override: none."
      end

    [base, chat_line, topic_line, "Use /trigger mentions|all|clear."]
    |> Enum.join("\n")
  end

  defp render_trigger_mode_set(mode, %ChatScope{topic_id: nil}) do
    "Trigger mode set to #{mode} for this chat."
  end

  defp render_trigger_mode_set(mode, %ChatScope{topic_id: _}) do
    "Trigger mode set to #{mode} for this topic."
  end

  defp authorized_inbound_reason(state, inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)

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
    case LemonCore.RouterBridge.handle_inbound(inbound) do
      :ok ->
        :ok

      other ->
        meta = inbound.meta || %{}

        Logger.warning(
          "RouterBridge.handle_inbound failed for telegram inbound (chat_id=#{inspect(meta[:chat_id])} update_id=#{inspect(meta[:update_id])} msg_id=#{inspect(meta[:user_msg_id])}): " <>
            inspect(other)
        )

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

    cond do
      data == @cancel_callback_prefix ->
        msg = cb["message"] || %{}
        chat_id = get_in(msg, ["chat", "id"])
        topic_id = parse_int(msg["message_thread_id"])
        message_id = msg["message_id"]

        if is_integer(chat_id) and is_integer(message_id) do
          scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}

          if Code.ensure_loaded?(LemonGateway.Runtime) and
               function_exported?(LemonGateway.Runtime, :cancel_by_progress_msg, 2) do
            LemonGateway.Runtime.cancel_by_progress_msg(scope, message_id)
          end
        end

        _ = state.api_mod.answer_callback_query(state.token, cb_id, %{"text" => "cancelling..."})
        :ok

      String.starts_with?(data, @cancel_callback_prefix <> ":") ->
        run_id = String.trim_leading(data, @cancel_callback_prefix <> ":")

        if is_binary(run_id) and run_id != "" and Code.ensure_loaded?(LemonGateway.Runtime) and
             function_exported?(LemonGateway.Runtime, :cancel_by_run_id, 2) do
          LemonGateway.Runtime.cancel_by_run_id(run_id, :user_requested)
        end

        _ = state.api_mod.answer_callback_query(state.token, cb_id, %{"text" => "cancelling..."})
        :ok

      true ->
        {approval_id, decision} = parse_approval_callback(data)

        if is_binary(approval_id) and decision do
          _ = LemonCore.ExecApprovals.resolve(approval_id, decision)

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
    end
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

    cwd =
      if scope do
        BindingResolver.resolve_cwd(scope)
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
      |> maybe_put(:cwd, cwd)

    message = Map.put(inbound.message, :text, text_after_directive)

    %{inbound | message: message, meta: meta}
  end

  defp maybe_transcribe_voice(state, inbound) do
    voice = inbound.meta && inbound.meta[:voice]

    cond do
      not is_map(voice) or map_size(voice) == 0 ->
        {:ok, inbound}

      not state.voice_transcription ->
        if is_binary(inbound.message.text) and inbound.message.text != "" do
          {:ok, inbound}
        else
          _ = maybe_send_voice_error(state, inbound, "Voice transcription is disabled.")
          {:skip, state}
        end

      not is_binary(state.voice_transcription_api_key) or state.voice_transcription_api_key == "" ->
        _ = maybe_send_voice_error(state, inbound, "Voice transcription requires an API key.")
        {:skip, state}

      true ->
        case transcribe_voice(state, inbound, voice) do
          {:ok, transcript} ->
            message = Map.put(inbound.message, :text, String.trim(transcript || ""))
            meta = Map.put(inbound.meta || %{}, :voice_transcribed, true)
            {:ok, %{inbound | message: message, meta: meta}}

          {:error, reason} ->
            _ = maybe_send_voice_error(state, inbound, format_voice_error(reason))
            {:skip, state}
        end
    end
  end

  defp transcribe_voice(state, _inbound, voice) do
    file_id = voice[:file_id] || voice["file_id"]
    file_size = parse_int(voice[:file_size] || voice["file_size"])
    max_bytes = parse_int(state.voice_max_bytes)

    if is_integer(max_bytes) and is_integer(file_size) and file_size > max_bytes do
      {:error, :voice_too_large}
    else
      ensure_httpc()

      with {:ok, file_path} <- fetch_voice_file(state, file_id),
           {:ok, audio_bytes} <- fetch_voice_bytes(state, file_path),
           :ok <- enforce_voice_size(audio_bytes, max_bytes) do
        transcriber = state.voice_transcriber
        mime_type = voice[:mime_type] || voice["mime_type"]

        transcriber.transcribe(%{
          model: state.voice_transcription_model,
          base_url: state.voice_transcription_base_url,
          api_key: state.voice_transcription_api_key,
          audio_bytes: audio_bytes,
          mime_type: mime_type
        })
      end
    end
  end

  defp fetch_voice_file(state, file_id) when is_binary(file_id) do
    case state.api_mod.get_file(state.token, file_id) do
      {:ok, %{"ok" => true, "result" => %{"file_path" => file_path}}} when is_binary(file_path) ->
        {:ok, file_path}

      {:ok, %{"result" => %{"file_path" => file_path}}} when is_binary(file_path) ->
        {:ok, file_path}

      other ->
        {:error, {:telegram_file_lookup_failed, other}}
    end
  end

  defp fetch_voice_file(_state, _file_id), do: {:error, :missing_file_id}

  defp fetch_voice_bytes(state, file_path) do
    case state.api_mod.download_file(state.token, file_path) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      other -> {:error, {:telegram_download_failed, other}}
    end
  end

  defp enforce_voice_size(_bytes, max_bytes) when not is_integer(max_bytes), do: :ok

  defp enforce_voice_size(bytes, max_bytes) when is_binary(bytes) do
    if byte_size(bytes) > max_bytes do
      {:error, :voice_too_large}
    else
      :ok
    end
  end

  defp maybe_send_voice_error(state, inbound, text) when is_binary(text) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

    if is_integer(chat_id) do
      send_system_message(state, chat_id, thread_id, user_msg_id, text)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp format_voice_error(:voice_too_large), do: "Voice message is too large to transcribe."
  defp format_voice_error(:missing_api_key), do: "Voice transcription requires an API key."

  defp format_voice_error({:http_error, status, msg}) do
    msg =
      if is_binary(msg) and msg != "" do
        String.slice(msg, 0, 200)
      else
        "request failed"
      end

    "Voice transcription failed (#{status}): #{msg}"
  end

  defp format_voice_error({:telegram_file_lookup_failed, _}), do: "Failed to fetch voice file."
  defp format_voice_error({:telegram_download_failed, _}), do: "Failed to download voice file."
  defp format_voice_error(other), do: "Voice transcription failed: #{inspect(other)}"

  defp ensure_httpc do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
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

  defp resolve_openai_provider do
    provider =
      try do
        cfg = LemonCore.Config.load()
        providers = cfg.providers || %{}
        Map.get(providers, "openai") || Map.get(providers, :openai) || %{}
      rescue
        _ -> %{}
      end

    {get_field(provider, :api_key), get_field(provider, :base_url)}
  end

  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_blank(nil), do: nil
  defp normalize_blank(""), do: nil
  defp normalize_blank(value), do: value

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
    LemonCore.Dedupe.Ets.init(@dedupe_table)
  end

  defp dedupe_key(inbound) do
    {inbound.peer.id, inbound.message.id}
  end

  defp is_seen?(key, ttl_ms) do
    LemonCore.Dedupe.Ets.seen?(@dedupe_table, key, ttl_ms)
  end

  defp mark_seen(key, ttl_ms) do
    # Marking updates the timestamp, effectively extending TTL from "now".
    _ = ttl_ms
    LemonCore.Dedupe.Ets.mark(@dedupe_table, key)
    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
