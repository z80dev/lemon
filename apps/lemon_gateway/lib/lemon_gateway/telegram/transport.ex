defmodule LemonGateway.Telegram.Transport do
  @moduledoc false
  use LemonGateway.Transport
  use GenServer

  alias LemonGateway.Telegram.{API, Dedupe}
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}
  alias LemonGateway.{BindingResolver, ChatState, Config, EngineRegistry, Store}

  @impl LemonGateway.Transport
  def id, do: "telegram"

  @impl LemonGateway.Transport

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000

  def start_link(_opts) do
    config = Application.get_env(:lemon_gateway, :telegram, %{})
    token = config[:bot_token] || config["bot_token"]

    if is_binary(token) and token != "" do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(config) do
    :ok = Dedupe.init()
    :ok = ensure_httpc()

    state = %{
      token: config[:bot_token] || config["bot_token"],
      api_mod: config[:api_mod] || API,
      poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
      dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
      debounce_ms: config[:debounce_ms] || @default_debounce_ms,
      allowed_chat_ids: Map.get(config, :allowed_chat_ids, nil),
      allow_queue_override: Map.get(config, :allow_queue_override, false),
      offset: config[:offset] || 0,
      buffers: %{}
    }

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

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
    case state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        {state, max_id} = handle_updates(state, updates)
        %{state | offset: max(state.offset, max_id + 1)}

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

  defp handle_update(state, %{"message" => message} = _update) do
    with %{"text" => text} <- message do
      chat = message["chat"] || %{}
      chat_id = chat["id"]
      topic_id = message["message_thread_id"]
      message_id = message["message_id"]
      reply_to_message = message["reply_to_message"]

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
                submit_job_immediate(state, scope, message_id, text, reply_to_message)

              true ->
                enqueue_buffer(state, scope, message_id, text, reply_to_message)
            end
        end
      else
        state
      end
    else
      _ -> state
    end
  end

  defp handle_update(state, _update), do: state

  defp enqueue_buffer(state, scope, message_id, text, reply_to_message) do
    key = scope_key(scope)
    reply_to_text = reply_text(reply_to_message)

    case Map.get(state.buffers, key) do
      nil ->
        debounce_ref = make_ref()
        timer_ref = Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)
        buffer = %{
          scope: scope,
          messages: [%{id: message_id, text: text, reply_to_text: reply_to_text}],
          timer_ref: timer_ref,
          debounce_ref: debounce_ref
        }
        %{state | buffers: Map.put(state.buffers, key, buffer)}

      buffer ->
        _ = Process.cancel_timer(buffer.timer_ref)
        debounce_ref = make_ref()
        timer_ref = Process.send_after(self(), {:debounce_flush, key, debounce_ref}, state.debounce_ms)
        messages = buffer.messages ++ [%{id: message_id, text: text, reply_to_text: reply_to_text}]
        buffer = %{buffer | messages: messages, timer_ref: timer_ref, debounce_ref: debounce_ref}
        %{state | buffers: Map.put(state.buffers, key, buffer)}
    end
  end

  defp flush_buffer(%{messages: messages, scope: scope} = _buffer, state) do
    {text, last_id, reply_to_text} = join_messages(messages)
    submit_job_immediate(state, scope, last_id, text, reply_to_text)
  end

  defp submit_job_immediate(state, scope, message_id, text, reply_to_message) do
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

    job = %Job{
      scope: scope,
      user_msg_id: message_id,
      text: final_text,
      resume: resume,
      engine_hint: engine_hint,
      queue_mode: final_queue_mode,
      meta: %{
        notify_pid: self(),
        chat_id: scope.chat_id,
        progress_msg_id: progress_msg_id,
        user_msg_id: message_id
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
      _ -> nil
    end
  end

  defp join_messages(messages) do
    text = Enum.map_join(messages, "\n\n", & &1.text)
    last = List.last(messages)
    {text, last.id, last.reply_to_text}
  end

  defp allowed_chat?(nil, _chat_id), do: true
  defp allowed_chat?(list, chat_id) when is_list(list), do: chat_id in list

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

  defp reply_text(nil), do: nil
  defp reply_text(%{"text" => text}) when is_binary(text), do: text
  defp reply_text(_), do: nil
end
