defmodule LemonGateway.Telegram.Outbox do
  @moduledoc """
  Throttled Telegram message send/edit/delete queue with retry logic.

  Implements a GenServer-based priority queue that coalesces rapid edits,
  respects Telegram rate limits (HTTP 429), and retries transient failures
  with exponential backoff up to a configurable maximum.
  """
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

  @spec enqueue_with_notify(
          term(),
          integer(),
          term(),
          pid(),
          reference(),
          atom()
        ) :: :ok
  def enqueue_with_notify(
        key,
        priority,
        op,
        notify_pid,
        notify_ref,
        notify_tag \\ :outbox_delivered
      )
      when is_pid(notify_pid) and is_reference(notify_ref) and is_atom(notify_tag) do
    GenServer.cast(
      __MODULE__,
      {:enqueue, key, priority, {op, {notify_pid, notify_ref, notify_tag}}}
    )
  end

  @impl true
  def init(config) do
    state = %{
      token: config[:bot_token] || config["bot_token"],
      api_mod: resolve_api_mod(config),
      edit_throttle_ms: config[:edit_throttle_ms] || @default_edit_throttle,
      # Default to true now that we render via Telegram entities (robust, no MarkdownV2 escaping).
      use_markdown:
        case Map.fetch(config, :use_markdown) do
          {:ok, v} ->
            v

          :error ->
            Map.get(config, "use_markdown")
        end
        |> then(fn v ->
          # Allow explicit `false`; only default to true when unset.
          if is_nil(v), do: true, else: v
        end),
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
        {:ok, result} ->
          _ = maybe_notify(op, {:ok, result})
          {:noreply, state}

        {:error, reason, retry_after_ms} ->
          state = enqueue_with_retry(state, key, priority, op, retry_after_ms)

          # Notify only on terminal failures (non-retryable or max-retries).
          if retry_after_ms == 0 do
            _ = maybe_notify(op, {:error, reason})
          end

          {:noreply, state}
      end
    else
      # If we're deleting a message, drop any pending edit for that same message id.
      {queue0, ops0} = maybe_drop_related_ops(state.queue, state.ops, op)

      {queue, ops} =
        if Map.has_key?(ops0, key) do
          # Update existing op, keep position in queue
          {queue0, Map.put(ops0, key, {priority, op})}
        else
          # Add new entry to queue sorted by priority
          queue = insert_by_priority(queue0, {key, priority})
          {queue, Map.put(ops0, key, {priority, op})}
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
            {:ok, result} ->
              _ = maybe_notify(op, {:ok, result})
              # Clear retry state on success
              %{state | retry_state: Map.delete(state.retry_state, key)}

            {:error, reason, retry_after_ms} ->
              state2 = enqueue_with_retry(state, key, default_priority(op), op, retry_after_ms)

              # Notify only on terminal failures (non-retryable or max-retries).
              if retry_after_ms == 0 do
                _ = maybe_notify(op, {:error, reason})
              end

              state2
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
      # Use a 0ms timer (instead of `send/2`) to reduce races where `:drain` runs
      # before a burst of subsequent enqueues can coalesce.
      Process.send_after(self(), :drain, 0)
      state
    else
      state
    end
  end

  defp default_priority({op, {_pid, _ref, _tag}}), do: default_priority(op)
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
      _ = maybe_notify(op, {:error, :max_retries})
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

  defp execute_op(state, {op, {_pid, _ref, _tag}}), do: execute_op(state, op)

  defp execute_op(state, {:edit, chat_id, message_id, %{text: text} = payload}) do
    engine = payload[:engine]
    reply_markup = payload[:reply_markup] || payload["reply_markup"]
    truncated_text = truncate_text(text, engine)
    {formatted_text, opts} = format_text(truncated_text, state.use_markdown)

    opts =
      cond do
        is_map(opts) ->
          maybe_put_opt(opts, :reply_markup, reply_markup)

        is_nil(opts) and not is_nil(reply_markup) ->
          maybe_put_opt(%{}, :reply_markup, reply_markup)

        true ->
          opts
      end

    state
    |> safe_api_call(fn ->
      state.api_mod.edit_message_text(
        state.token,
        chat_id,
        message_id,
        formatted_text,
        opts
      )
    end)
    |> handle_api_result()
  end

  defp execute_op(state, {:send, chat_id, payload}) do
    text = payload[:text] || payload["text"] || ""
    engine = payload[:engine]
    reply_markup = payload[:reply_markup] || payload["reply_markup"]
    reply_to = payload[:reply_to_message_id] || payload["reply_to_message_id"]
    thread_id = payload[:message_thread_id] || payload["message_thread_id"]
    truncated_text = truncate_text(text, engine)
    {formatted_text, opts} = format_text(truncated_text, state.use_markdown)

    state
    |> safe_api_call(fn ->
      # Keep the legacy call shape (reply_to + parse_mode) unless we need extra options
      # (e.g. Telegram entities for markdown rendering).
      if is_map(opts) do
        opts =
          opts
          |> maybe_put_opt(:reply_to_message_id, reply_to)
          |> maybe_put_opt(:message_thread_id, thread_id)
          |> maybe_put_opt(:reply_markup, reply_markup)

        state.api_mod.send_message(state.token, chat_id, formatted_text, opts, nil)
      else
        # Even when markdown/entities are disabled, preserve topic routing and reply threading.
        opts =
          %{}
          |> maybe_put_opt(:reply_to_message_id, reply_to)
          |> maybe_put_opt(:message_thread_id, thread_id)
          |> maybe_put_opt(:reply_markup, reply_markup)

        state.api_mod.send_message(state.token, chat_id, formatted_text, opts, nil)
      end
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

  defp maybe_put_opt(map, _key, nil), do: map
  defp maybe_put_opt(map, key, value), do: Map.put(map, key, value)

  defp maybe_drop_related_ops(queue, ops, op) do
    inner =
      case op do
        {o, {_pid, _ref, _tag}} -> o
        other -> other
      end

    case inner do
      {:delete, chat_id, message_id} ->
        edit_key = {chat_id, message_id, :edit}
        queue = Enum.reject(queue, fn {k, _p} -> k == edit_key end)
        ops = Map.delete(ops, edit_key)
        {queue, ops}

      _ ->
        {queue, ops}
    end
  rescue
    _ -> {queue, ops}
  end

  defp maybe_notify({_, {pid, ref, tag}}, result) when is_pid(pid) and is_reference(ref) do
    try do
      send(pid, {tag, ref, result})
    rescue
      _ -> :ok
    end

    :ok
  end

  defp maybe_notify(_op, _result), do: :ok

  defp resolve_api_mod(config) do
    config
    |> fetch_config(:api_mod, API)
    |> normalize_api_mod()
  end

  defp fetch_config(config, key, default) when is_map(config) and is_atom(key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key)) || default
  end

  defp normalize_api_mod(mod) when is_atom(mod), do: mod
  defp normalize_api_mod(""), do: API

  defp normalize_api_mod(mod) when is_binary(mod) do
    try do
      if String.starts_with?(mod, "Elixir.") do
        String.to_existing_atom(mod)
      else
        String.to_existing_atom("Elixir." <> mod)
      end
    rescue
      _ -> API
    end
  end

  defp normalize_api_mod(_), do: API

  defp merge_config(config, nil), do: config

  defp merge_config(config, opts) when is_list(opts) do
    Enum.reduce(opts, config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp merge_config(config, opts) when is_map(opts), do: Map.merge(config, opts)

  defp merge_config(config, _opts), do: config
end
