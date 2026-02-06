defmodule LemonGateway.Telegram.Outbox do
  @moduledoc false
  use GenServer

  alias LemonGateway.Telegram.API
  alias LemonGateway.Telegram.Formatter
  alias LemonGateway.Telegram.Truncate

  @default_edit_throttle 400
  @max_retries 3
  @base_backoff_ms 1000

  # Priority constants (lower = higher priority)
  @priority_delete -1
  @priority_edit 0
  @priority_send 1

  def start_link(opts) do
    base =
      case Process.whereis(LemonGateway.Config) do
        nil -> %{}
        _ -> LemonGateway.Config.get(:telegram) || %{}
      end

    config =
      base
      |> merge_config(Application.get_env(:lemon_gateway, :telegram))
      |> merge_config(opts)

    token = config[:bot_token] || config["bot_token"]

    if is_binary(token) and token != "" do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    else
      :ignore
    end
  end

  @spec enqueue(term(), integer(), term()) :: :ok
  def enqueue(key, priority, op) do
    GenServer.cast(__MODULE__, {:enqueue, key, priority, op})
  end

  @impl true
  def init(config) do
    state = %{
      token: config[:bot_token] || config["bot_token"],
      api_mod: config[:api_mod] || API,
      edit_throttle_ms: config[:edit_throttle_ms] || @default_edit_throttle,
      use_markdown: config[:use_markdown] || false,
      queue: [],
      ops: %{},
      retry_state: %{},
      next_at: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, key, priority, op}, state) do
    priority = priority || default_priority(op)

    if state.edit_throttle_ms == 0 do
      case execute_op(state, op) do
        {:ok, _result} ->
          {:noreply, state}

        {:error, _reason, retry_after_ms} ->
          state = enqueue_with_retry(state, key, priority, op, retry_after_ms)
          {:noreply, state}
      end
    else
      {queue, ops} =
        if Map.has_key?(state.ops, key) do
          # Update existing op, keep position in queue
          {state.queue, Map.put(state.ops, key, {priority, op})}
        else
          # Add new entry to queue sorted by priority
          queue = insert_by_priority(state.queue, {key, priority})
          {queue, Map.put(state.ops, key, {priority, op})}
        end

      state = %{state | queue: queue, ops: ops}
      state = schedule_drain(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:drain, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      state.queue == [] ->
        {:noreply, %{state | next_at: 0}}

      state.next_at > 0 and now < state.next_at ->
        Process.send_after(self(), :drain, state.next_at - now)
        {:noreply, state}

      true ->
        [{key, _priority} | rest] = state.queue
        {{_priority, op}, ops} = Map.pop(state.ops, key)
        state = %{state | queue: rest, ops: ops}

        state =
          case execute_op(state, op) do
            {:ok, _result} ->
              # Clear retry state on success
              %{state | retry_state: Map.delete(state.retry_state, key)}

            {:error, _reason, retry_after_ms} ->
              enqueue_with_retry(state, key, default_priority(op), op, retry_after_ms)
          end

        next_at = now + state.edit_throttle_ms
        state = %{state | next_at: next_at}
        Process.send_after(self(), :drain, state.edit_throttle_ms)
        {:noreply, state}
    end
  end

  def handle_info({:retry, key, priority, op}, state) do
    # Re-enqueue the operation for retry
    {queue, ops} =
      if Map.has_key?(state.ops, key) do
        # Key already has a newer op, skip retry
        {state.queue, state.ops}
      else
        queue = insert_by_priority(state.queue, {key, priority})
        {queue, Map.put(state.ops, key, {priority, op})}
      end

    state = %{state | queue: queue, ops: ops}
    state = schedule_drain(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_drain(state) do
    if state.next_at == 0 do
      send(self(), :drain)
      state
    else
      state
    end
  end

  defp default_priority({:delete, _chat_id, _message_id}), do: @priority_delete
  defp default_priority({:edit, _chat_id, _message_id, _payload}), do: @priority_edit
  defp default_priority({:send, _chat_id, _payload}), do: @priority_send
  defp default_priority(_), do: @priority_send

  defp insert_by_priority(queue, {key, priority}) do
    {before, after_} = Enum.split_while(queue, fn {_k, p} -> p <= priority end)
    before ++ [{key, priority}] ++ after_
  end

  defp enqueue_with_retry(state, _key, _priority, _op, 0) do
    # Non-retryable error (e.g., 4xx client errors except 429)
    state
  end

  defp enqueue_with_retry(state, key, priority, op, retry_after_ms) do
    retry_count = Map.get(state.retry_state, key, 0)

    if retry_count >= @max_retries do
      # Max retries reached, drop the operation
      state
    else
      # Calculate backoff with exponential increase
      backoff_ms = max(retry_after_ms, @base_backoff_ms * trunc(:math.pow(2, retry_count)))
      new_retry_state = Map.put(state.retry_state, key, retry_count + 1)

      # Schedule retry after backoff
      Process.send_after(self(), {:retry, key, priority, op}, backoff_ms)

      %{state | retry_state: new_retry_state}
    end
  end

  defp execute_op(state, {:edit, chat_id, message_id, %{text: text} = payload}) do
    engine = payload[:engine]
    truncated_text = truncate_text(text, engine)
    {formatted_text, parse_mode} = format_text(truncated_text, state.use_markdown)

    state
    |> safe_api_call(fn ->
      state.api_mod.edit_message_text(
        state.token,
        chat_id,
        message_id,
        formatted_text,
        parse_mode
      )
    end)
    |> handle_api_result()
  end

  defp execute_op(state, {:send, chat_id, payload}) do
    text = payload[:text] || payload["text"] || ""
    engine = payload[:engine]
    reply_to = payload[:reply_to_message_id] || payload["reply_to_message_id"]
    truncated_text = truncate_text(text, engine)
    {formatted_text, parse_mode} = format_text(truncated_text, state.use_markdown)

    state
    |> safe_api_call(fn ->
      state.api_mod.send_message(state.token, chat_id, formatted_text, reply_to, parse_mode)
    end)
    |> handle_api_result()
  end

  defp execute_op(state, {:delete, chat_id, message_id}) do
    state
    |> safe_api_call(fn ->
      state.api_mod.delete_message(state.token, chat_id, message_id)
    end)
    |> handle_api_result()
  end

  defp safe_api_call(_state, fun) do
    try do
      fun.()
    rescue
      error -> {:error, {:api_error, error}}
    catch
      :exit, reason -> {:error, {:api_exit, reason}}
    end
  end

  defp handle_api_result({:ok, _} = ok), do: ok
  defp handle_api_result({:error, reason}), do: handle_api_error(reason)

  defp handle_api_error({:http_error, 429, response_body}) do
    # Rate limited - check for retry_after in response
    retry_after_ms =
      case Jason.decode(response_body) do
        {:ok, %{"parameters" => %{"retry_after" => seconds}}} when is_number(seconds) ->
          # Convert seconds to milliseconds
          trunc(seconds * 1000)

        _ ->
          @base_backoff_ms
      end

    {:error, :rate_limited, retry_after_ms}
  end

  defp handle_api_error({:http_error, status, _response_body})
       when status >= 500 and status < 600 do
    # Server errors are retryable
    {:error, {:server_error, status}, @base_backoff_ms}
  end

  defp handle_api_error({:http_error, status, _response_body}) do
    # Client errors (4xx except 429) are not retryable
    {:error, {:client_error, status}, 0}
  end

  defp handle_api_error(:timeout) do
    {:error, :timeout, @base_backoff_ms}
  end

  defp handle_api_error({:failed_connect, _} = reason) do
    {:error, reason, @base_backoff_ms}
  end

  defp handle_api_error({:api_exit, reason}) do
    {:error, {:api_exit, reason}, @base_backoff_ms}
  end

  defp handle_api_error({:api_error, reason}) do
    {:error, {:api_error, reason}, @base_backoff_ms}
  end

  defp handle_api_error(reason) do
    # Unknown errors - attempt retry with base backoff
    {:error, reason, @base_backoff_ms}
  end

  defp truncate_text(text, nil) do
    # No engine specified, use generic truncation
    Truncate.truncate_for_telegram(text)
  end

  defp truncate_text(text, engine_module) when is_atom(engine_module) do
    Truncate.truncate_for_telegram(text, engine_module)
  end

  defp truncate_text(text, _) do
    Truncate.truncate_for_telegram(text)
  end

  defp format_text(text, true) do
    Formatter.prepare_for_telegram(text)
  end

  defp format_text(text, _use_markdown) do
    {text, nil}
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
