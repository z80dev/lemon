defmodule LemonGateway.Telegram.Transport do
  @moduledoc false
  use LemonGateway.Transport
  use GenServer

  alias LemonGateway.Telegram.{API, Dedupe, OffsetStore}
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}
  alias LemonGateway.{BindingResolver, ChatState, Config, EngineRegistry, Store}
  alias LemonCore.SessionKey

  @impl LemonGateway.Transport
  def id, do: "telegram"

  @impl LemonGateway.Transport

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000

  def start_link(_opts) do
    # Defense-in-depth: never run the legacy Telegram poller if the lemon_channels-based
    # Telegram transport is active. Having both will double-submit jobs and can surface
    # as "out of nowhere" late replies (a second run finishing later).
    if Code.ensure_loaded?(LemonChannels.Adapters.Telegram.Transport) and
         is_pid(Process.whereis(LemonChannels.Adapters.Telegram.Transport)) do
      :ignore
    else
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
    :ok = Dedupe.init()
    :ok = ensure_httpc()

    account_id = config[:account_id] || config["account_id"] || "default"
    config_offset = config[:offset] || config["offset"]
    stored_offset = OffsetStore.get(account_id, config[:bot_token] || config["bot_token"])

    drop_pending_updates =
      config[:drop_pending_updates] || config["drop_pending_updates"] || false

    # If enabled, drop any pending Telegram updates on every boot unless an explicit offset is set.
    # This prevents the bot from replying to historical messages after downtime.
    drop_pending_updates = drop_pending_updates && is_nil(config_offset)

    state = %{
      token: config[:bot_token] || config["bot_token"],
      api_mod: config[:api_mod] || API,
      poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
      dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
      debounce_ms: config[:debounce_ms] || @default_debounce_ms,
      allowed_chat_ids: Map.get(config, :allowed_chat_ids, nil),
      allow_queue_override: Map.get(config, :allow_queue_override, false),
      account_id: account_id,
      # If configured to drop pending updates on boot, start from 0 so we can
      # advance to the live edge even if a stale stored offset is ahead.
      offset: if(drop_pending_updates, do: 0, else: initial_offset(config_offset, stored_offset)),
      drop_pending_updates?: drop_pending_updates,
      drop_pending_done?: false,
      buffers: %{},
      approval_messages: %{}
    }

    maybe_subscribe_exec_approvals()
    send(self(), :poll)
    {:ok, state}
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

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
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
    Enum.reduce(updates, {state, state.offset}, fn update, {state, max_id} ->
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
              cancel_command?(text) ->
                handle_cancel(scope, message)
                state

              command_message?(text) ->
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

  defp command_message?(text) do
    String.trim_leading(text) |> String.starts_with?("/")
  end

  defp cancel_command?(text) do
    String.trim(String.downcase(text)) == "/cancel"
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
    cfg = LemonCore.Config.load(cwd)
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
    if Code.ensure_loaded?(LemonRouter.ApprovalsBridge) do
      LemonRouter.ApprovalsBridge.resolve(approval_id, decision)
    end

    :ok
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
