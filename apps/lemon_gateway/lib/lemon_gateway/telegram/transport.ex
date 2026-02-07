defmodule LemonGateway.Telegram.Transport do
  @moduledoc false
  use LemonGateway.Transport
  use GenServer

  require Logger

  alias LemonGateway.Telegram.{API, Dedupe, OffsetStore, TriggerMode}
  alias LemonGateway.Telegram.PollerLock
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}
  alias LemonGateway.{BindingResolver, ChatState, Config, EngineRegistry, Store}
  alias LemonCore.SessionKey

  @impl LemonGateway.Transport
  def id, do: "telegram"

  @impl LemonGateway.Transport

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000

  def start_link(opts) do
    # Legacy transport is intentionally disabled. Telegram polling is owned by
    # lemon_channels (LemonChannels.Adapters.Telegram.Transport).
    #
    # Keep an escape hatch for tests/dev via `force: true`, but refuse to start
    # if the lemon_channels transport is already running (double-polling duplicates work).
    force = Keyword.get(opts || [], :force, false)

    channels_running? =
      Code.ensure_loaded?(LemonChannels.Adapters.Telegram.Transport) and
        is_pid(Process.whereis(LemonChannels.Adapters.Telegram.Transport))

    cond do
      not force ->
        Logger.warning(
          "Legacy Telegram transport is disabled; use lemon_channels Telegram adapter instead"
        )

        :ignore

      channels_running? ->
        Logger.warning(
          "Refusing to start legacy Telegram transport because lemon_channels Telegram transport is already running"
        )

        :ignore

      true ->
      config =
        base_telegram_config()
        |> merge_config(Application.get_env(:lemon_gateway, :telegram))

      token = config[:bot_token] || config["bot_token"]

      if is_binary(token) and token != "" do
        GenServer.start_link(__MODULE__, config, name: __MODULE__)
      else
        :ignore
      end
    end
  end

  @impl true
  def init(config) do
    account_id = config[:account_id] || config["account_id"] || "default"
    token = config[:bot_token] || config["bot_token"]

    case PollerLock.acquire(account_id, token) do
      :ok ->
        :ok = Dedupe.init()
        :ok = ensure_httpc()

        config_offset = config[:offset] || config["offset"]
        stored_offset = OffsetStore.get(account_id, token)

        drop_pending_updates =
          config[:drop_pending_updates] || config["drop_pending_updates"] || false

        # If enabled, drop any pending Telegram updates on every boot unless an explicit offset is set.
        # This prevents the bot from replying to historical messages after downtime.
        drop_pending_updates = drop_pending_updates && is_nil(config_offset)

        {bot_id, bot_username} =
          resolve_bot_identity(
            config[:bot_id] || config["bot_id"],
            config[:bot_username] || config["bot_username"],
            config[:api_mod] || API,
            token
          )

        state = %{
          token: token,
          api_mod: config[:api_mod] || API,
          poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
          dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
          debounce_ms: config[:debounce_ms] || @default_debounce_ms,
          allowed_chat_ids: Map.get(config, :allowed_chat_ids, nil),
          allow_queue_override: Map.get(config, :allow_queue_override, false),
          account_id: account_id,
          # If configured to drop pending updates on boot, start from 0 so we can
          # advance to the live edge even if a stale stored offset is ahead.
          offset:
            if(drop_pending_updates, do: 0, else: initial_offset(config_offset, stored_offset)),
          drop_pending_updates?: drop_pending_updates,
          drop_pending_done?: false,
          buffers: %{},
          approval_messages: %{},
          # run_id => %{scope, session_key, message_id, peer_kind}
          pending_new: %{},
          bot_id: bot_id,
          bot_username: bot_username
        }

        maybe_subscribe_exec_approvals()
        send(self(), :poll)
        {:ok, state}

      {:error, :locked} ->
        Logger.warning(
          "Telegram poller already running for account_id=#{inspect(account_id)}; refusing to start legacy transport"
        )

        :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_updates(state)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:debounce_flush, scope_key, debounce_ref}, state) do
    {buffer, buffers} = Map.pop(state.buffers, scope_key)

    state =
      cond do
        buffer && buffer.debounce_ref == debounce_ref ->
          flush_buffer(buffer, state)
          %{state | buffers: buffers}

        buffer ->
          %{state | buffers: Map.put(state.buffers, scope_key, buffer)}

        true ->
          state
      end

    {:noreply, state}
  end

  # Receive approval request/resolution events from LemonCore.Bus ("exec_approvals" topic)
  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    approval_id = payload[:approval_id] || get_in(payload, [:pending, :id])
    pending = payload[:pending]

    state =
      if is_binary(approval_id) and is_map(pending) do
        maybe_send_approval_prompt(state, approval_id, pending)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved, payload: payload}, state) do
    approval_id = payload[:approval_id]
    decision = payload[:decision]
    pending = payload[:pending]

    state =
      if is_binary(approval_id) do
        maybe_mark_approval_resolved(state, approval_id, decision, pending)
      else
        state
      end

    {:noreply, state}
  end

  # /new triggers an internal "memory reflection" run; clear auto-resume only after it completes.
  def handle_info({:lemon_gateway_run_completed, job, completed}, state) do
    run_id =
      cond do
        is_map(completed) and is_binary(completed.run_id) -> completed.run_id
        is_map(job) and is_binary(job.run_id) -> job.run_id
        true -> nil
      end

    case run_id && Map.get(state.pending_new, run_id) do
      %{
        scope: %ChatScope{} = scope,
        session_key: session_key,
        message_id: message_id
      } = pending ->
        _ = safe_delete_chat_state(scope)
        _ = safe_delete_chat_state(session_key)
        # Store writes are async; do a second delete shortly after to win races.
        Process.send_after(self(), {:new_session_cleanup, scope, session_key}, 50)

        msg0 =
          if is_map(completed) and completed[:ok] == false do
            "Started a new session (memory recording failed)."
          else
            "Started a new session."
          end

        msg =
          case pending[:project] do
            %{id: id, root: root} when is_binary(id) and is_binary(root) ->
              msg0 <> "\nProject: #{id} (#{root})"

            _ ->
              msg0
          end

        _ = send_system_message(state, scope.chat_id, scope.topic_id, message_id, msg)
        {:noreply, %{state | pending_new: Map.delete(state.pending_new, run_id)}}

      _ ->
        {:noreply, state}
    end
  rescue
    _ -> {:noreply, state}
  end

  # Best-effort second pass to clear chat state in case a late write races with the first delete.
  def handle_info({:new_session_cleanup, %ChatScope{} = scope, session_key}, state) do
    _ = safe_delete_chat_state(scope)
    _ = safe_delete_chat_state(session_key)
    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = PollerLock.release(state.account_id, state.token)
    :ok
  end

  defp poll_updates(state) do
    _ = PollerLock.heartbeat(state.account_id, state.token)

    case state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        if state.drop_pending_updates? and not state.drop_pending_done? do
          if updates == [] do
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
  end

  defp handle_updates(state, updates) do
    # If updates is empty, keep max_id at offset - 1 so we don't accidentally advance the offset.
    Enum.reduce(updates, {state, state.offset - 1}, fn update, {state, max_id} ->
      id = update["update_id"] || max_id
      state = handle_update(state, update)
      {state, max(max_id, id)}
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

  defp handle_update(state, %{"message" => message} = _update) do
    with %{"text" => text} <- message do
      chat = message["chat"] || %{}
      chat_id = chat["id"]
      topic_id = message["message_thread_id"]
      message_id = message["message_id"]
      reply_to_message = message["reply_to_message"]
      peer_kind = peer_kind(chat)

      if allowed_chat?(state.allowed_chat_ids, chat_id) do
        scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
        key = {chat_id, topic_id, message_id}

        case Dedupe.check_and_mark(key, state.dedupe_ttl_ms) do
          :seen ->
            state

          :new ->
            cond do
              trigger_command?(text, state.bot_username) ->
                handle_trigger_command(state, scope, message_id, message, text)

              resume_command?(text, state.bot_username) ->
                handle_resume_command(state, scope, message_id, peer_kind, text)

              recompile_command?(text, state.bot_username) ->
                handle_recompile_command(state, scope, message_id, peer_kind, text)

              new_command?(text, state.bot_username) ->
                args = telegram_command_args(text, "new")
                handle_new_session(state, scope, message_id, peer_kind, args)

              cancel_command?(text, state.bot_username) ->
                handle_cancel(scope, message)
                state

              should_ignore_for_trigger?(state, scope, message, text) ->
                state

              command_message_for_bot?(text, state.bot_username) ->
                submit_job_immediate(state, scope, message_id, text, reply_to_message, peer_kind)

              true ->
                enqueue_buffer(state, scope, message_id, text, reply_to_message, peer_kind)
            end
        end
      else
        state
      end
    else
      _ -> state
    end
  end

  defp handle_update(state, %{"callback_query" => cb} = _update) do
    handle_callback_query(state, cb)
  end

  defp handle_update(state, _update), do: state

  defp enqueue_buffer(state, scope, message_id, text, reply_to_message, peer_kind) do
    key = scope_key(scope)
    reply_to_text = reply_text(reply_to_message)

    case Map.get(state.buffers, key) do
      nil ->
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

        buffer = %{
          scope: scope,
          peer_kind: peer_kind,
          messages: [%{id: message_id, text: text, reply_to_text: reply_to_text}],
          timer_ref: timer_ref,
          debounce_ref: debounce_ref
        }

        %{state | buffers: Map.put(state.buffers, key, buffer)}

      buffer ->
        _ = Process.cancel_timer(buffer.timer_ref)
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)

        messages =
          buffer.messages ++ [%{id: message_id, text: text, reply_to_text: reply_to_text}]

        buffer = %{
          buffer
          | messages: messages,
            timer_ref: timer_ref,
            debounce_ref: debounce_ref,
            peer_kind: peer_kind
        }

        %{state | buffers: Map.put(state.buffers, key, buffer)}
    end
  end

  defp flush_buffer(%{messages: messages, scope: scope, peer_kind: peer_kind} = _buffer, state) do
    {text, last_id, reply_to_text} = join_messages(messages)
    submit_job_immediate(state, scope, last_id, text, reply_to_text, peer_kind)
  end

  defp submit_job_immediate(state, scope, message_id, text, reply_to_message, peer_kind) do
    progress_msg_id = send_progress(state, scope, message_id)
    reply_text = reply_text(reply_to_message)

    # Resolve queue mode: explicit override > binding > default (:collect)
    base_queue_mode = BindingResolver.resolve_queue_mode(scope) || :collect
    {queue_mode, queue_stripped_text} = parse_queue_override(text, state)
    final_queue_mode = queue_mode || base_queue_mode
    # Use stripped text if queue override was applied, otherwise original text
    text_after_queue = if queue_mode, do: queue_stripped_text, else: text

    # Strip engine directive (e.g., /claude, /codex, /lemon) from start of text
    {directive_engine, final_text} = strip_engine_directive(text_after_queue)

    # Parse routing with pre-extracted engine hint
    {resume, engine_hint} = parse_routing(final_text, reply_text, directive_engine)
    {resume, engine_hint} = maybe_apply_auto_resume(scope, resume, engine_hint)

    # Resolve agent_id/profile and build canonical session_key for approvals + resume
    agent_id = BindingResolver.resolve_agent_id(scope)
    session_key = build_session_key(agent_id, state.account_id, peer_kind, scope)

    # Agent profile comes from canonical TOML config; optionally scoped by project cwd if bound.
    cwd = BindingResolver.resolve_cwd(scope)
    profile = get_profile(agent_id, cwd)

    tool_policy = profile[:tool_policy] || profile["tool_policy"]
    system_prompt = profile[:system_prompt] || profile["system_prompt"]
    model = resolve_model(profile[:model] || profile["model"])

    job = %Job{
      run_id: LemonCore.Id.run_id(),
      session_key: session_key,
      prompt: final_text,
      scope: scope,
      user_msg_id: message_id,
      text: final_text,
      resume: resume,
      engine_hint: engine_hint,
      queue_mode: final_queue_mode,
      cwd: cwd,
      tool_policy: tool_policy,
      meta: %{
        notify_pid: self(),
        chat_id: scope.chat_id,
        progress_msg_id: progress_msg_id,
        user_msg_id: message_id,
        origin: :telegram,
        agent_id: agent_id,
        system_prompt: system_prompt,
        model: model
      }
    }

    LemonGateway.submit(job)
    state
  end

  @doc false
  def parse_routing(text, reply_to_text \\ nil, pre_extracted_engine \\ nil) do
    resume = extract_resume_token(text) || extract_resume_token(reply_to_text || "")

    # If resume found, prefer its engine; otherwise use pre-extracted engine hint
    # (from strip_engine_directive), or fall back to extracting from remaining text
    engine_hint =
      case resume do
        %{engine: engine} -> engine
        nil -> pre_extracted_engine || extract_command_hint(text)
      end

    {resume, engine_hint}
  end

  defp maybe_apply_auto_resume(_scope, %ResumeToken{} = resume, engine_hint),
    do: {resume, engine_hint}

  defp maybe_apply_auto_resume(_scope, _resume, engine_hint) when is_binary(engine_hint),
    do: {nil, engine_hint}

  defp maybe_apply_auto_resume(scope, _resume, _engine_hint) do
    if Config.get(:auto_resume) do
      case Store.get_chat_state(scope) do
        %ChatState{last_engine: engine, last_resume_token: token}
        when is_binary(engine) and is_binary(token) ->
          {%ResumeToken{engine: engine, value: token}, engine}

        %{} = map ->
          engine = map.last_engine || map[:last_engine] || map["last_engine"]
          token = map.last_resume_token || map[:last_resume_token] || map["last_resume_token"]

          if is_binary(engine) and is_binary(token) do
            {%ResumeToken{engine: engine, value: token}, engine}
          else
            {nil, nil}
          end

        _ ->
          {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp extract_resume_token(text) do
    case EngineRegistry.extract_resume(text) do
      {:ok, token} -> token
      :none -> nil
    end
  end

  defp extract_command_hint(text) do
    trimmed = String.trim_leading(text)

    case Regex.run(~r{^/([a-z][a-z0-9_-]*)(?:\s|$)}i, trimmed) do
      [_, cmd] ->
        cmd_lower = String.downcase(cmd)
        # Verify it's a registered engine
        if EngineRegistry.get_engine(cmd_lower) do
          cmd_lower
        else
          nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Strips an engine directive from the start of the text.

  Looks for `/codex`, `/claude`, or `/lemon` at the start of the text (after trimming
  leading whitespace). If found, strips that line (including the newline) from the text.

  Returns `{engine_hint, stripped_text}` where engine_hint is the detected engine or nil.

  ## Examples

      iex> strip_engine_directive("/claude\\nWhat is the weather?")
      {"claude", "What is the weather?"}

      iex> strip_engine_directive("What is the weather?")
      {nil, "What is the weather?"}

      iex> strip_engine_directive("/codex")
      {"codex", ""}
  """
  def strip_engine_directive(text) when is_binary(text) do
    trimmed = String.trim_leading(text)

    case Regex.run(~r{^/(codex|claude|lemon)(?:\s|$)}i, trimmed) do
      [match, cmd] ->
        engine = String.downcase(cmd)
        # Strip the directive line (everything up to and including the first newline)
        rest = String.slice(trimmed, String.length(match)..-1//1)
        # If the match ended with whitespace (not newline), we may have more content on same line
        # We want to strip just the directive, preserving any same-line content after whitespace
        stripped =
          if String.ends_with?(match, "\n") or String.ends_with?(match, "\r\n") do
            rest
          else
            # Match was followed by space or end of string
            # Check if there's a newline to strip
            case String.split(rest, ~r/\r?\n/, parts: 2) do
              [first_line, remaining] ->
                # If first_line is empty or just whitespace, return remaining
                if String.trim(first_line) == "" do
                  remaining
                else
                  # There's content on the same line after the directive
                  String.trim_leading(first_line) <> "\n" <> remaining
                end

              [only_line] ->
                String.trim_leading(only_line)
            end
          end

        {engine, stripped}

      _ ->
        {nil, text}
    end
  end

  def strip_engine_directive(nil), do: {nil, nil}

  defp send_progress(state, scope, reply_to) do
    case state.api_mod.send_message(state.token, scope.chat_id, "Running…", reply_to) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} ->
        msg_id

      _ ->
        nil
    end
  end

  defp join_messages(messages) do
    text = Enum.map_join(messages, "\n\n", & &1.text)
    last = List.last(messages)
    {text, last.id, last.reply_to_text}
  end

  defp allowed_chat?(nil, _chat_id), do: true
  defp allowed_chat?(list, chat_id) when is_list(list), do: chat_id in list

  defp peer_kind(%{"type" => "private"}), do: :dm
  defp peer_kind(%{"type" => "group"}), do: :group
  defp peer_kind(%{"type" => "supergroup"}), do: :group
  defp peer_kind(%{"type" => "channel"}), do: :channel
  defp peer_kind(_), do: :unknown

  defp command_message_for_bot?(text, bot_username) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r{^/([a-z][a-z0-9_]*)(?:@([\w_]+))?(?:\s|$)}i, trimmed) do
      # Note: Elixir's Regex.run/2 omits optional capture groups when they don't match.
      # For "/cmd" (no @BotName suffix), we only get [full_match, cmd].
      [_, _cmd] ->
        true

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

  defp cancel_command?(text, bot_username) do
    telegram_command?(text, "cancel", bot_username)
  end

  defp new_command?(text, bot_username) do
    telegram_command?(text, "new", bot_username)
  end

  defp resume_command?(text, bot_username) do
    telegram_command?(text, "resume", bot_username)
  end

  defp recompile_command?(text, bot_username) do
    telegram_command?(text, "recompile", bot_username)
  end

  defp trigger_command?(text, bot_username) do
    telegram_command?(text, "trigger", bot_username)
  end

  # Telegram commands in groups may include a bot username suffix: /cmd@BotName
  defp telegram_command?(text, cmd, bot_username) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:@([\w_]+))?(?:\s|$)/i, trimmed) do
      # "/cmd" without a @BotName suffix => only the full match is returned.
      [_] ->
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

  # Queue override commands: /steer, /followup, /interrupt
  # Only allowed if transport config permits (allow_queue_override: true)
  # Returns {queue_mode, stripped_text} where stripped_text has the override prefix removed
  defp parse_queue_override(text, state) do
    allow_override = Map.get(state, :allow_queue_override, false)

    if allow_override do
      trimmed = String.trim_leading(text)

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

  # Match override command with boundary (end or whitespace), case-insensitive
  defp match_override?(text, cmd) do
    Regex.match?(~r/^\/#{cmd}(?:\s|$)/i, text)
  end

  # Strips the queue override prefix from text (case-insensitive match)
  # Preserves any text after the command
  defp strip_queue_prefix(text, prefix) do
    prefix_len = String.length(prefix)
    remaining = String.slice(text, prefix_len..-1//1)
    String.trim_leading(remaining)
  end

  defp handle_cancel(scope, message) do
    reply = message["reply_to_message"] || %{}
    replied_id = reply["message_id"]

    if replied_id do
      LemonGateway.Runtime.cancel_by_progress_msg(scope, replied_id)
    end
  end

  defp handle_resume_command(state, %ChatScope{} = scope, message_id, peer_kind, text) do
    state = drop_buffer_for(state, scope)

    agent_id = BindingResolver.resolve_agent_id(scope)
    session_key = build_session_key(agent_id, state.account_id, peer_kind, scope)
    args = telegram_command_args(text, "resume") || ""

    cond do
      args == "" ->
        sessions = list_recent_sessions(scope, 20)

        msg =
          case sessions do
            [] ->
              "No sessions found yet."

            list ->
              header = "Available sessions (most recent first):"

              body =
                list
                |> Enum.with_index(1)
                |> Enum.map(fn {%ResumeToken{} = r, idx} ->
                  "#{idx}. #{r.engine}: #{abbrev(r.value)}"
                end)
                |> Enum.join("\n")

              usage = "Use /resume <number> to switch sessions."
              Enum.join([header, body, usage], "\n\n")
          end

        _ = send_system_message(state, scope.chat_id, scope.topic_id, message_id, msg)
        state

      true ->
        {selector, prompt_part} =
          case String.split(args, ~r/\s+/, parts: 2) do
            [a] -> {a, ""}
            [a, rest] -> {a, String.trim(rest || "")}
            _ -> {args, ""}
          end

        sessions = list_recent_sessions(scope, 50)
        resume = resolve_resume_selector(selector, sessions)

        if match?(%ResumeToken{}, resume) do
          now = System.system_time(:millisecond)

          payload = %{
            last_engine: resume.engine,
            last_resume_token: resume.value,
            updated_at: now
          }

          Store.put_chat_state(scope, payload)
          Store.put_chat_state(session_key, payload)

          _ =
            send_system_message(
              state,
              scope.chat_id,
              scope.topic_id,
              message_id,
              "Resuming session: #{resume.engine}: #{abbrev(resume.value)}"
            )

          if prompt_part != "" do
            resume_line = format_resume_line(resume)

            submit_job_immediate(
              state,
              scope,
              message_id,
              String.trim("#{resume_line}\n#{prompt_part}"),
              nil,
              peer_kind
            )
          else
            state
          end
        else
          _ =
            send_system_message(
              state,
              scope.chat_id,
              scope.topic_id,
              message_id,
              "Couldn't find that session. Try /resume to list sessions."
            )

          state
        end
    end
  rescue
    _ -> state
  end

  defp handle_recompile_command(state, %ChatScope{} = scope, message_id, peer_kind, text) do
    args = telegram_command_args(text, "recompile") || ""
    force? = String.contains?(String.downcase(args), "force")

    cond do
      peer_kind != :dm ->
        _ =
          send_system_message(
            state,
            scope.chat_id,
            scope.topic_id,
            message_id,
            "For safety, /recompile is only allowed in a private DM with the bot."
          )

        state

      not Code.ensure_loaded?(Mix) ->
        _ =
          send_system_message(
            state,
            scope.chat_id,
            scope.topic_id,
            message_id,
            "/recompile is not available in this runtime (Mix is not loaded). If this is a release, deploy a new release instead."
          )

        state

      true ->
        opts = %{}
        opts = maybe_put(opts, "reply_to_message_id", message_id)
        opts = maybe_put(opts, "message_thread_id", scope.topic_id)

        progress_id =
          case state.api_mod.send_message(state.token, scope.chat_id, "Recompiling...", opts, nil) do
            {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} -> msg_id
            _ -> nil
          end

        Task.start(fn ->
          result =
            case LemonGateway.Dev.recompile_and_reload(force: force?) do
              {:ok, info} ->
                err_count = length(info.errors)
                apps = Enum.map(info.apps, &Atom.to_string/1) |> Enum.join(", ")

                base =
                  "Recompile complete in #{info.compile_ms}ms\n" <>
                    "Apps: #{apps}\n" <>
                    "Modules: #{info.modules}\n" <>
                    "Reloaded: #{info.reloaded}\n" <>
                    "Skipped: #{info.skipped}\n" <>
                    "Errors: #{err_count}"

                if err_count > 0 do
                  # Keep this short; full error lists can be large.
                  first =
                    info.errors
                    |> Enum.take(5)
                    |> Enum.map(fn {m, r} -> "- #{inspect(m)}: #{inspect(r)}" end)
                    |> Enum.join("\n")

                  base <> "\n" <> first
                else
                  base
                end

              {:error, :mix_unavailable} ->
                "/recompile failed: Mix is unavailable in this runtime."

              {:error, other} ->
                "/recompile failed: #{inspect(other)}"
            end

          if is_integer(progress_id) do
            _ =
              state.api_mod.edit_message_text(
                state.token,
                scope.chat_id,
                progress_id,
                result,
                nil
              )
          else
            _ = send_system_message(state, scope.chat_id, scope.topic_id, message_id, result)
          end
        end)

        state
    end
  end

  defp list_recent_sessions(scope, limit) do
    history = Store.get_run_history(scope, limit: limit * 5)

    history
    |> Enum.map(fn {_run_id, data} ->
      summary = data[:summary] || %{}
      completed = summary[:completed]
      resume = completed && completed.resume
      {resume, data[:started_at] || 0}
    end)
    |> Enum.filter(fn {r, _ts} -> match?(%ResumeToken{}, r) end)
    |> Enum.sort_by(fn {_r, ts} -> ts end, :desc)
    |> Enum.reduce([], fn {%ResumeToken{} = r, _ts}, acc ->
      key = {r.engine, r.value}

      if Enum.any?(acc, fn %ResumeToken{} = rr -> {rr.engine, rr.value} == key end),
        do: acc,
        else: acc ++ [r]
    end)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp resolve_resume_selector(selector, sessions) do
    selector = String.trim(selector || "")

    cond do
      selector == "" ->
        nil

      Regex.match?(~r/^\d+$/, selector) ->
        idx = String.to_integer(selector)
        Enum.at(sessions, idx - 1)

      true ->
        case EngineRegistry.extract_resume(selector) do
          {:ok, %ResumeToken{} = token} -> token
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp format_resume_line(%ResumeToken{} = resume) do
    case EngineRegistry.get_engine(resume.engine) do
      nil -> "#{resume.engine} resume #{resume.value}"
      mod -> mod.format_resume(resume)
    end
  rescue
    _ -> "#{resume.engine} resume #{resume.value}"
  end

  defp abbrev(nil), do: ""

  defp abbrev(token) when is_binary(token) do
    if byte_size(token) > 40, do: String.slice(token, 0, 40) <> "…", else: token
  end

  defp handle_new_session(state, %ChatScope{} = scope, message_id, peer_kind, raw_selector) do
    state = drop_buffer_for(state, scope)

    agent_id = BindingResolver.resolve_agent_id(scope)
    session_key = build_session_key(agent_id, state.account_id, peer_kind, scope)

    selector =
      if is_binary(raw_selector) do
        raw_selector
        |> String.trim()
        |> case do
          "" -> nil
          other -> other
        end
      else
        nil
      end

    project_result =
      case selector do
        nil ->
          :noop

        sel ->
          maybe_select_project_for_scope(scope, sel)
      end

    case project_result do
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, scope.chat_id, scope.topic_id, message_id, msg)
        state

      _ ->
        history = fetch_run_history_for_memory(session_key, scope, limit: 8)
        transcript = format_run_history_transcript(history, max_chars: 12_000)

        if transcript == "" do
          _ = safe_delete_chat_state(scope)
          _ = safe_delete_chat_state(session_key)

          msg =
            case project_result do
              {:ok, %{id: id, root: root}} ->
                "Started a new session.\nProject: #{id} (#{root})"

              _ ->
                "Started a new session."
            end

          _ = send_system_message(state, scope.chat_id, scope.topic_id, message_id, msg)

          state
        else
          msg =
            case project_result do
              {:ok, %{id: id, root: root}} ->
                "Recording memories, then starting a new session…\nProject: #{id} (#{root})"

              _ ->
                "Recording memories, then starting a new session…"
            end

          _ = send_system_message(state, scope.chat_id, scope.topic_id, message_id, msg)

          prompt = memory_reflection_prompt(transcript)

          run_id = LemonCore.Id.run_id()
          engine_hint = last_engine_hint(scope, session_key)
          cwd = BindingResolver.resolve_cwd(scope)
          profile = get_profile(agent_id, cwd)

          tool_policy = profile[:tool_policy] || profile["tool_policy"]
          system_prompt = profile[:system_prompt] || profile["system_prompt"]
          model = resolve_model(profile[:model] || profile["model"])

          job = %Job{
            run_id: run_id,
            session_key: session_key,
            prompt: prompt,
            text: prompt,
            scope: scope,
            user_msg_id: message_id,
            engine_hint: engine_hint,
            queue_mode: :interrupt,
            tool_policy: tool_policy,
            meta: %{
              notify_pid: self(),
              origin: :telegram,
              chat_id: scope.chat_id,
              topic_id: scope.topic_id,
              user_msg_id: message_id,
              agent_id: agent_id,
              system_prompt: system_prompt,
              model: model,
              command: :new,
              record_memories: true
            }
          }

          LemonGateway.submit(job)

          pending = %{
            scope: scope,
            session_key: session_key,
            message_id: message_id,
            peer_kind: peer_kind,
            project:
              case project_result do
                {:ok, %{id: id, root: root}} -> %{id: id, root: root}
                _ -> nil
              end
          }

          %{state | pending_new: Map.put(state.pending_new, run_id, pending)}
        end
    end
  rescue
    _ -> state
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
            _ -> File.cwd!()
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

          # Register a dynamic project and bind this scope to it.
          # This is intentionally runtime-configurable (persisted via the gateway store backend).
          _ =
            if Code.ensure_loaded?(Store) and function_exported?(Store, :put, 3) do
              Store.put(:gateway_projects_dynamic, id, %{root: root, default_engine: nil})
              Store.put(:gateway_project_overrides, scope, id)
            else
              :ok
            end

          {:ok, %{id: id, root: root}}
        else
          {:error, "Project path does not exist: #{expanded}"}
        end

      true ->
        id = sel

        case BindingResolver.lookup_project(id) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 ->
            if File.dir?(Path.expand(root)) do
              _ =
                if Code.ensure_loaded?(Store) and function_exported?(Store, :put, 3) do
                  Store.put(:gateway_project_overrides, scope, id)
                else
                  :ok
                end

              {:ok, %{id: id, root: Path.expand(root)}}
            else
              {:error, "Configured project root does not exist: #{Path.expand(root)}"}
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

  defp fetch_run_history_for_memory(session_key, %ChatScope{} = scope, opts) do
    limit = Keyword.get(opts, :limit, 8)

    if Code.ensure_loaded?(Store) and function_exported?(Store, :get_run_history, 2) do
      history = Store.get_run_history(session_key, limit: limit)
      if history == [], do: Store.get_run_history(scope, limit: limit), else: history
    else
      []
    end
  rescue
    _ -> []
  end

  defp format_run_history_transcript(history, opts) when is_list(history) do
    max_chars = Keyword.get(opts, :max_chars, 12_000)

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
    s1 = Store.get_chat_state(session_key)
    s2 = Store.get_chat_state(scope)

    engine =
      (s1 && (s1[:last_engine] || s1["last_engine"] || s1.last_engine)) ||
        (s2 && (s2[:last_engine] || s2["last_engine"] || s2.last_engine))

    if is_binary(engine) and engine != "", do: engine, else: nil
  rescue
    _ -> nil
  end

  defp drop_buffer_for(state, %ChatScope{} = scope) do
    key = scope_key(scope)

    case Map.pop(state.buffers, key) do
      {nil, _buffers} ->
        state

      {buffer, buffers} ->
        _ = Process.cancel_timer(buffer.timer_ref)
        %{state | buffers: buffers}
    end
  end

  defp safe_delete_chat_state(key) do
    Store.delete_chat_state(key)
    :ok
  rescue
    _ -> :ok
  end

  defp send_system_message(state, chat_id, topic_id, reply_to_message_id, text)
       when is_integer(chat_id) and is_binary(text) do
    opts =
      %{}
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("message_thread_id", topic_id)

    state.api_mod.send_message(state.token, chat_id, text, opts, nil)
  rescue
    _ -> :ok
  end

  defp parse_int(nil), do: nil

  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

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

  defp should_ignore_for_trigger?(state, %ChatScope{} = scope, message, text) do
    case peer_kind(message["chat"] || %{}) do
      kind when kind in [:group, :channel] ->
        trigger_mode = trigger_mode_for(state, scope)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, message, text)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp trigger_mode_for(state, %ChatScope{} = scope) do
    account_id = state.account_id || "default"
    TriggerMode.resolve(account_id, scope.chat_id, scope.topic_id)
  rescue
    _ -> %{mode: :all, chat_mode: nil, topic_mode: nil, source: :default}
  end

  defp explicit_invocation?(state, message, text) do
    command_message_for_bot?(text, state.bot_username) or
      mention_of_bot?(state, message) or
      reply_to_bot?(state, message)
  rescue
    _ -> false
  end

  defp mention_of_bot?(state, message) do
    bot_username = state.bot_username
    bot_id = state.bot_id
    text = message["text"] || message["caption"] || ""

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

  defp reply_to_bot?(state, message) do
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

  defp message_entities(message) when is_map(message) do
    entities = message["entities"] || message["caption_entities"]
    if is_list(entities), do: entities, else: []
  end

  defp message_entities(_), do: []

  defp handle_trigger_command(state, %ChatScope{} = scope, message_id, message, text) do
    chat_id = scope.chat_id
    topic_id = scope.topic_id
    account_id = state.account_id || "default"
    args = telegram_command_args(text, "trigger") || ""
    arg = String.downcase(String.trim(args || ""))
    current = TriggerMode.resolve(account_id, chat_id, topic_id)

    case arg do
      "" ->
        _ =
          send_system_message(
            state,
            chat_id,
            topic_id,
            message_id,
            render_trigger_mode_status(current)
          )

        state

      "mentions" ->
        with true <- trigger_change_allowed?(state, message, chat_id),
             :ok <- TriggerMode.set(scope, account_id, :mentions) do
          _ =
            send_system_message(
              state,
              chat_id,
              topic_id,
              message_id,
              render_trigger_mode_set("mentions", scope)
            )

          state
        else
          false ->
            _ =
              send_system_message(
                state,
                chat_id,
                topic_id,
                message_id,
                "Trigger mode can only be changed by a group admin."
              )

            state

          _ ->
            state
        end

      "all" ->
        with true <- trigger_change_allowed?(state, message, chat_id),
             :ok <- TriggerMode.set(scope, account_id, :all) do
          _ =
            send_system_message(
              state,
              chat_id,
              topic_id,
              message_id,
              render_trigger_mode_set("all", scope)
            )

          state
        else
          false ->
            _ =
              send_system_message(
                state,
                chat_id,
                topic_id,
                message_id,
                "Trigger mode can only be changed by a group admin."
              )

            state

          _ ->
            state
        end

      "clear" ->
        cond do
          is_nil(topic_id) ->
            _ =
              send_system_message(
                state,
                chat_id,
                topic_id,
                message_id,
                "No topic override to clear. Use /trigger all or /trigger mentions to set chat defaults."
              )

            state

          trigger_change_allowed?(state, message, chat_id) ->
            :ok = TriggerMode.clear_topic(account_id, chat_id, topic_id)

            _ =
              send_system_message(
                state,
                chat_id,
                topic_id,
                message_id,
                "Cleared topic trigger override."
              )

            state

          true ->
            _ =
              send_system_message(
                state,
                chat_id,
                topic_id,
                message_id,
                "Trigger mode can only be changed by a group admin."
              )

            state
        end

      _ ->
        _ =
          send_system_message(
            state,
            chat_id,
            topic_id,
            message_id,
            "Usage: /trigger [mentions|all|clear]"
          )

        state
    end
  rescue
    _ -> state
  end

  defp trigger_change_allowed?(state, message, chat_id) do
    case peer_kind(message["chat"] || %{}) do
      :group ->
        sender_id = parse_int(get_in(message, ["from", "id"]))

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

  defp scope_key(%ChatScope{chat_id: chat_id, topic_id: topic_id}), do: {chat_id, topic_id}

  defp ensure_httpc do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp maybe_subscribe_exec_approvals do
    if Code.ensure_loaded?(LemonCore.Bus) do
      _ = LemonCore.Bus.subscribe("exec_approvals")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp build_session_key(agent_id, account_id, peer_kind, %ChatScope{} = scope) do
    SessionKey.channel_peer(%{
      agent_id: agent_id || "default",
      channel_id: "telegram",
      account_id: account_id || "default",
      peer_kind: peer_kind || :unknown,
      peer_id: to_string(scope.chat_id),
      thread_id: if(scope.topic_id, do: to_string(scope.topic_id), else: nil)
    })
  end

  defp get_profile(agent_id, cwd) do
    cfg = LemonCore.Config.cached(cwd)
    Map.get(cfg.agents || %{}, agent_id) || Map.get(cfg.agents || %{}, "default") || %{}
  end

  defp resolve_model(nil), do: nil

  defp resolve_model(model_str) when is_binary(model_str) do
    case String.split(model_str, ":", parts: 2) do
      [provider, id] ->
        with {:ok, provider_atom} <- safe_provider(provider) do
          Ai.Models.get_model(provider_atom, id)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp resolve_model(_), do: nil

  defp safe_provider("anthropic"), do: {:ok, :anthropic}
  defp safe_provider("openai"), do: {:ok, :openai}
  defp safe_provider("openai-codex"), do: {:ok, :"openai-codex"}
  defp safe_provider("google"), do: {:ok, :google}
  defp safe_provider("kimi"), do: {:ok, :kimi}
  defp safe_provider("aws-bedrock"), do: {:ok, :aws_bedrock}
  defp safe_provider("azure-openai-responses"), do: {:ok, :"azure-openai-responses"}
  defp safe_provider(_), do: :error

  defp maybe_send_approval_prompt(state, approval_id, pending) do
    session_key = pending[:session_key] || pending["session_key"]

    case SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: "telegram", account_id: account_id, peer_id: peer_id} ->
        if account_id == state.account_id do
          case Integer.parse(to_string(peer_id)) do
            {chat_id, _} ->
              if allowed_chat?(state.allowed_chat_ids, chat_id) do
                thread_id = pending_thread_id(session_key)

                opts =
                  %{}
                  |> maybe_put("message_thread_id", thread_id)
                  |> Map.put("reply_markup", approval_keyboard(approval_id))

                text = approval_text(pending)

                case state.api_mod.send_message(state.token, chat_id, text, opts, nil) do
                  {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} ->
                    %{
                      state
                      | approval_messages:
                          Map.put(state.approval_messages, approval_id, %{
                            chat_id: chat_id,
                            message_id: msg_id
                          })
                    }

                  _ ->
                    state
                end
              else
                state
              end

            _ ->
              state
          end
        else
          state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp maybe_mark_approval_resolved(state, approval_id, decision, _pending) do
    case Map.get(state.approval_messages, approval_id) do
      nil ->
        state

      %{chat_id: chat_id, message_id: message_id} ->
        decision_str =
          if is_atom(decision),
            do: Atom.to_string(decision),
            else: to_string(decision || "unknown")

        text = "Approval #{approval_id} resolved: #{decision_str}"

        _ =
          state.api_mod.edit_message_text(state.token, chat_id, message_id, text, %{
            "reply_markup" => %{"inline_keyboard" => []}
          })

        %{state | approval_messages: Map.delete(state.approval_messages, approval_id)}
    end
  rescue
    _ -> state
  end

  defp pending_thread_id(session_key) do
    case SessionKey.parse(session_key) do
      %{thread_id: nil} ->
        nil

      %{thread_id: tid} ->
        case Integer.parse(to_string(tid)) do
          {i, _} -> i
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp approval_keyboard(approval_id) do
    %{
      "inline_keyboard" => [
        [
          %{"text" => "Once", "callback_data" => "#{approval_id}|once"},
          %{"text" => "Session", "callback_data" => "#{approval_id}|session"},
          %{"text" => "Agent", "callback_data" => "#{approval_id}|agent"}
        ],
        [
          %{"text" => "Global", "callback_data" => "#{approval_id}|global"},
          %{"text" => "Deny", "callback_data" => "#{approval_id}|deny"}
        ]
      ]
    }
  end

  defp approval_text(pending) do
    tool = pending[:tool] || pending["tool"] || "tool"
    action = pending[:action] || pending["action"] || %{}
    rationale = pending[:rationale] || pending["rationale"]

    preview =
      action
      |> inspect(pretty: true, limit: 5, printable_limit: 500)
      |> String.slice(0, 700)

    base = "Approval required for tool: #{tool}\n\nAction:\n#{preview}"

    if is_binary(rationale) and rationale != "",
      do: base <> "\n\nReason: #{rationale}",
      else: base
  end

  defp handle_callback_query(state, cb) when is_map(cb) do
    id = cb["id"]
    data = cb["data"] || ""

    {approval_id, decision} = parse_callback_data(data)

    msg = cb["message"] || %{}
    chat = msg["chat"] || %{}
    chat_id = chat["id"]
    message_id = msg["message_id"]

    # Acknowledge quickly to stop the client spinner
    _ = if id, do: state.api_mod.answer_callback_query(state.token, id, %{}), else: :ok

    if allowed_chat?(state.allowed_chat_ids, chat_id) and is_binary(approval_id) do
      maybe_resolve_approval(approval_id, decision)

      # Best-effort UI feedback
      decision_str = Atom.to_string(decision)

      _ =
        state.api_mod.edit_message_text(
          state.token,
          chat_id,
          message_id,
          "Approval #{approval_id}: #{decision_str}",
          %{"reply_markup" => %{"inline_keyboard" => []}}
        )
    end

    state
  rescue
    _ -> state
  end

  defp parse_callback_data(data) when is_binary(data) do
    case String.split(data, "|", parts: 2) do
      [approval_id, decision_str] ->
        {approval_id, decision_from_str(decision_str)}

      _ ->
        {nil, :deny}
    end
  end

  defp decision_from_str("once"), do: :approve_once
  defp decision_from_str("session"), do: :approve_session
  defp decision_from_str("agent"), do: :approve_agent
  defp decision_from_str("global"), do: :approve_global
  defp decision_from_str("deny"), do: :deny
  defp decision_from_str(_), do: :deny

  defp maybe_resolve_approval(approval_id, decision) do
    LemonCore.ExecApprovals.resolve(approval_id, decision)
  rescue
    _ -> :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reply_text(nil), do: nil
  defp reply_text(%{"text" => text}) when is_binary(text), do: text
  defp reply_text(_), do: nil

  defp base_telegram_config do
    case Process.whereis(LemonGateway.Config) do
      nil -> %{}
      _ -> LemonGateway.Config.get(:telegram) || %{}
    end
  end

  defp merge_config(config, nil), do: config

  defp merge_config(config, opts) when is_list(opts) do
    Enum.reduce(opts, config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp merge_config(config, opts) when is_map(opts), do: Map.merge(config, opts)

  defp merge_config(config, _opts), do: config
end
