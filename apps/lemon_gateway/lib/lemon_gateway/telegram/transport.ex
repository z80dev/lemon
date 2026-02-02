defmodule LemonGateway.Telegram.Transport do
  @moduledoc false
  use GenServer

  alias LemonGateway.Telegram.{API, Dedupe}
  alias LemonGateway.Types.{ChatScope, Job}
  alias LemonGateway.Event.Completed

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
      poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
      dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
      debounce_ms: config[:debounce_ms] || @default_debounce_ms,
      allowed_chat_ids: Map.get(config, :allowed_chat_ids, nil),
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

  def handle_info({:debounce_flush, scope_key}, state) do
    {buffer, buffers} = Map.pop(state.buffers, scope_key)

    state =
      if buffer do
        flush_buffer(buffer, state)
        %{state | buffers: buffers}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:lemon_gateway_run_completed, job, %Completed{} = completed}, state) do
    meta = job.meta || %{}
    chat_id = meta[:chat_id]
    reply_to = meta[:progress_msg_id] || meta[:user_msg_id]

    if chat_id do
      text = format_completion(completed)
      _ = API.send_message(state.token, chat_id, text, reply_to)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
    case API.get_updates(state.token, state.offset, state.poll_interval_ms) do
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

      if allowed_chat?(state.allowed_chat_ids, chat_id) do
        scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
        key = {chat_id, topic_id, message_id}

        case Dedupe.check_and_mark(key, state.dedupe_ttl_ms) do
          :seen ->
            state

          :new ->
            if command_message?(text) do
              submit_job_immediate(state, scope, message_id, text)
            else
              enqueue_buffer(state, scope, message_id, text)
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

  defp enqueue_buffer(state, scope, message_id, text) do
    key = scope_key(scope)

    case Map.get(state.buffers, key) do
      nil ->
        timer_ref = Process.send_after(self(), {:debounce_flush, key}, state.debounce_ms)
        buffer = %{scope: scope, messages: [%{id: message_id, text: text}], timer_ref: timer_ref}
        %{state | buffers: Map.put(state.buffers, key, buffer)}

      buffer ->
        messages = buffer.messages ++ [%{id: message_id, text: text}]
        buffer = %{buffer | messages: messages}
        %{state | buffers: Map.put(state.buffers, key, buffer)}
    end
  end

  defp flush_buffer(%{messages: messages, scope: scope} = _buffer, state) do
    {text, last_id} = join_messages(messages)
    submit_job_immediate(state, scope, last_id, text)
  end

  defp submit_job_immediate(state, scope, message_id, text) do
    progress_msg_id = send_progress(state, scope, message_id)

    job = %Job{
      scope: scope,
      user_msg_id: message_id,
      text: text,
      resume: nil,
      engine_hint: nil,
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

  defp send_progress(state, scope, reply_to) do
    case API.send_message(state.token, scope.chat_id, "Running…", reply_to) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} -> msg_id
      _ -> nil
    end
  end

  defp join_messages(messages) do
    text = Enum.map_join(messages, "\n\n", & &1.text)
    last_id = List.last(messages).id
    {text, last_id}
  end

  defp allowed_chat?(nil, _chat_id), do: true
  defp allowed_chat?(list, chat_id) when is_list(list), do: chat_id in list

  defp command_message?(text) do
    String.trim_leading(text) |> String.starts_with?("/")
  end

  defp scope_key(%ChatScope{chat_id: chat_id, topic_id: topic_id}), do: {chat_id, topic_id}

  defp format_completion(%Completed{ok: true, answer: answer}) do
    "Done.\n\n" <> (answer || "")
  end

  defp format_completion(%Completed{ok: false, error: error}) do
    "Error.\n\n" <> to_string(error || "unknown")
  end

  defp ensure_httpc do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end
end
