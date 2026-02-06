defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport that normalizes messages and forwards them to LemonRouter.

  This transport wraps the existing LemonGateway.Telegram.Transport polling logic
  but routes messages through the new lemon_channels -> lemon_router pipeline.
  """

  use GenServer

  require Logger

  alias LemonGateway.BindingResolver
  alias LemonGateway.EngineRegistry
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

          state = %{
            token: token,
            api_mod: config[:api_mod] || LemonGateway.Telegram.API,
            poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
            dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
            debounce_ms: config[:debounce_ms] || config["debounce_ms"] || @default_debounce_ms,
            allow_queue_override:
              config[:allow_queue_override] || config["allow_queue_override"] || false,
            allowed_chat_ids:
              parse_allowed_chat_ids(config[:allowed_chat_ids] || config["allowed_chat_ids"]),
            deny_unbound_chats:
              config[:deny_unbound_chats] || config["deny_unbound_chats"] || false,
            account_id: account_id,
            # If we're configured to drop pending updates on boot, start from 0 so we can
            # advance to the real "latest" update_id even if a stale stored offset is ahead.
            offset:
              if(drop_pending_updates, do: 0, else: initial_offset(config_offset, stored_offset)),
            drop_pending_updates?: drop_pending_updates,
            drop_pending_done?: false,
            buffers: %{},
            # run_id => %{scope, session_key, chat_id, thread_id, user_msg_id}
            pending_new: %{}
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

  # Tool execution approval requests/resolutions are delivered on the `exec_approvals` bus topic.
  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    maybe_send_approval_request(state, payload)
    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  # Best-effort second pass to clear chat state in case a late write races with the first delete.
  def handle_info({:new_session_cleanup, %ChatScope{} = scope, session_key, chat_id, thread_id}, state) do
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
      } ->
        _ = safe_delete_chat_state(scope)
        _ = safe_delete_chat_state(session_key)
        _ = safe_delete_selected_resume(state, chat_id, thread_id)

        # Store writes are async; do a second delete shortly after to win races.
        Process.send_after(self(), {:new_session_cleanup, scope, session_key, chat_id, thread_id}, 50)

        topic = LemonCore.Bus.run_topic(run_id)
        _ = LemonCore.Bus.unsubscribe(topic)

        ok? =
          case event.payload do
            %{completed: %{ok: ok}} when is_boolean(ok) -> ok
            %{ok: ok} when is_boolean(ok) -> ok
            _ -> true
          end

        msg =
          if ok? do
            "Started a new session."
          else
            "Started a new session (memory recording failed)."
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
      resume_command?(original_text) ->
        handle_resume_command(state, inbound)

      new_command?(original_text) ->
        handle_new_session(state, inbound)

      cancel_command?(original_text) ->
        maybe_cancel_by_reply(state, inbound)
        state

      true ->
        {state, inbound} = maybe_switch_session_from_reply(state, inbound)
        inbound = maybe_apply_selected_resume(state, inbound, original_text)

        cond do
          command_message?(original_text) ->
            submit_inbound_now(state, inbound)

          true ->
            enqueue_buffer(state, inbound)
        end
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
      # Tool status messages are created lazily (only if tools/actions occur).
      |> Map.put(:status_msg_id, nil)
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
    telegram_command?(text, "cancel")
  end

  defp new_command?(text) do
    telegram_command?(text, "new")
  end

  defp resume_command?(text) do
    telegram_command?(text, "resume")
  end

  # Telegram commands in groups may include a bot username suffix: /cmd@BotName
  defp telegram_command?(text, cmd) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")
    Regex.match?(~r/^\/#{cmd}(?:@[\w_]+)?(?:\s|$)/i, trimmed)
  end

  defp telegram_command_args(text, cmd) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:@[\w_]+)?(?:\s+|$)(.*)$/is, trimmed) do
      [_, rest] -> String.trim(rest || "")
      _ -> nil
    end
  end

  defp command_message?(text) do
    String.trim_leading(text || "") |> String.starts_with?("/")
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

        case CoreStore.get(:telegram_msg_resume, key) do
          %ResumeToken{} = token -> {token, :msg_index}
          _ -> {nil, nil}
        end
    end
  rescue
    _ -> {nil, nil}
  end

  defp switching_session?(nil, %ResumeToken{}), do: true

  defp switching_session?(%{} = chat_state, %ResumeToken{} = resume) do
    last_engine = chat_state[:last_engine] || chat_state["last_engine"] || chat_state.last_engine
    last_token = chat_state[:last_resume_token] || chat_state["last_resume_token"] || chat_state.last_resume_token
    last_engine != resume.engine or last_token != resume.value
  rescue
    _ -> true
  end

  defp switching_session?(_other, _resume), do: true

  defp maybe_prefix_resume_to_prompt(inbound, %ResumeToken{} = resume) do
    if is_binary(inbound.message.text) and inbound.message.text != "" do
      resume_line = format_resume_line(resume)
      message = Map.put(inbound.message, :text, String.trim("#{resume_line}\n#{inbound.message.text}"))
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
                |> put_in([Access.key!(:message), :text], String.trim("#{format_resume_line(resume)}\n#{prompt_part}"))

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
    |> Enum.map(fn {_run_id, data} -> %{resume: extract_resume_from_history(data), started_at: data[:started_at] || 0} end)
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

	  defp handle_new_session(state, inbound) do
	    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
	    thread_id = parse_int(inbound.peer.thread_id)
	    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

	    state = drop_buffer_for(state, inbound)

	    state =
	      if is_integer(chat_id) do
	        scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
	        session_key = build_session_key(state, inbound, scope)

	        case submit_memory_reflection_before_new(state, inbound, scope, session_key, chat_id, thread_id, user_msg_id) do
	          {:ok, run_id, state} when is_binary(run_id) ->
	            if Code.ensure_loaded?(LemonCore.Bus) and function_exported?(LemonCore.Bus, :subscribe, 1) do
	              topic = LemonCore.Bus.run_topic(run_id)
	              _ = LemonCore.Bus.subscribe(topic)
	            end

	            _ =
	              send_system_message(
	                state,
	                chat_id,
	                thread_id,
	                user_msg_id,
	                "Recording memories, then starting a new session…"
	              )

	            pending = %{
	              scope: scope,
	              session_key: session_key,
	              chat_id: chat_id,
	              thread_id: thread_id,
	              user_msg_id: user_msg_id
	            }

	            %{state | pending_new: Map.put(state.pending_new, run_id, pending)}

	          _ ->
	            safe_delete_chat_state(scope)
	            safe_delete_chat_state(session_key)
	            safe_delete_selected_resume(state, chat_id, thread_id)
	            _ = send_system_message(state, chat_id, thread_id, user_msg_id, "Started a new session.")
	            state
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
	    if not (Code.ensure_loaded?(LemonRouter.RunOrchestrator) and
	              function_exported?(LemonRouter.RunOrchestrator, :submit, 1)) do
	      :skip
	    else
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

	        case LemonRouter.RunOrchestrator.submit(%{
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
	    end
	  rescue
	    _ -> :skip
	  end

	  defp submit_memory_reflection_before_new(_state, _inbound, _scope, _session_key, _chat_id, _thread_id, _user_msg_id),
	    do: :skip

	  defp fetch_run_history_for_memory(session_key, %ChatScope{} = scope, opts) do
	    limit = Keyword.get(opts, :limit, 8)

	    if Code.ensure_loaded?(LemonGateway.Store) and function_exported?(LemonGateway.Store, :get_run_history, 2) do
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
    _ = CoreStore.put(:telegram_selected_resume, {account_id, scope.chat_id, scope.topic_id}, resume)

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
    # Don't interfere with Telegram slash commands; those can be engine directives etc.
    if command_message?(original_text) do
      inbound
    else
      # If user already provided an explicit resume token, don't add another.
      case EngineRegistry.extract_resume(inbound.message.text || "") do
        {:ok, %ResumeToken{}} ->
          inbound

        _ ->
          chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
          thread_id = parse_int(inbound.peer.thread_id)

          if is_integer(chat_id) do
            key = {state.account_id || "default", chat_id, thread_id}

            case CoreStore.get(:telegram_selected_resume, key) do
              %ResumeToken{} = token ->
                maybe_prefix_resume_to_prompt(inbound, token)

              _ ->
                inbound
            end
          else
            inbound
          end
      end
    end
  rescue
    _ -> inbound
  end

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
