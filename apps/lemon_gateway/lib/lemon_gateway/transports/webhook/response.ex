defmodule LemonGateway.Transports.Webhook.Response do
  @moduledoc """
  Response shaping, completion waiting, and callback delivery helpers for the webhook transport.
  """

  require Logger

  # Callback responses are ignored beyond their status; bound what is read.
  @callback_response_max_bytes 1_048_576

  @spec response_for_run(map(), keyword()) ::
          {:ok, integer(), map()} | {:error, :run_timeout | term()}
  def response_for_run(%{submission_status: :outcome_unknown} = run_ctx, _opts) do
    cleanup_unknown_sync_subscription(run_ctx)

    payload = %{
      run_id: run_ctx.run_id,
      session_key: run_ctx.session_key,
      mode: Atom.to_string(run_ctx.mode),
      status: "outcome_unknown",
      retry_safe: false
    }

    {:ok, 200, maybe_put(payload, :callback, run_ctx.callback_status)}
  end

  def response_for_run(%{mode: :sync} = run_ctx, _opts) do
    with_sync_subscription(run_ctx, fn ->
      case wait_for_run_completion(run_ctx.run_id, run_ctx.timeout_ms, subscribe?: false) do
        {:ok, run_payload} ->
          callback = maybe_send_callback(run_ctx, callback_payload(run_ctx, run_payload))

          payload =
            %{
              run_id: run_ctx.run_id,
              session_key: run_ctx.session_key,
              mode: "sync",
              completed: completed_payload(run_payload),
              duration_ms: fetch(run_payload, :duration_ms)
            }
            |> maybe_put(:callback, callback)

          {:ok, 200, payload}

        {:error, :timeout} ->
          {:error, :run_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def response_for_run(run_ctx, _opts) do
    payload =
      %{
        run_id: run_ctx.run_id,
        session_key: run_ctx.session_key,
        mode: "async",
        status: "accepted"
      }
      |> maybe_put(:callback, run_ctx.callback_status)

    {:ok, 202, payload}
  end

  @spec prepare_wait_before_submit(atom(), map(), keyword()) ::
          {:ok, map(), map() | nil} | {:error, term()}
  def prepare_wait_before_submit(:sync, %{run_id: run_id}, _opts) do
    topic = LemonCore.Bus.run_done_topic(run_id)
    :ok = LemonCore.Bus.subscribe(topic)
    {:ok, %{sync_topic: topic}, nil}
  rescue
    error ->
      {:error, {:wait_prepare_failed, Exception.message(error)}}
  end

  def prepare_wait_before_submit(:async, %{callback_url: callback_url} = run_ctx, opts)
      when is_binary(callback_url) and callback_url != "" do
    start_async_callback_waiter(run_ctx, opts)
  end

  def prepare_wait_before_submit(_mode, _run_ctx, _opts), do: {:ok, %{}, nil}

  @spec cleanup_wait_setup(map()) :: :ok
  def cleanup_wait_setup(%{sync_topic: topic}) when is_binary(topic) do
    _ = LemonCore.Bus.unsubscribe(topic)
    :ok
  end

  def cleanup_wait_setup(%{callback_waiter_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def cleanup_wait_setup(_wait_setup), do: :ok

  @spec wait_for_run_completion(binary(), integer(), keyword()) ::
          {:ok, map()} | {:error, :timeout | :invalid_run_id | term()}
  def wait_for_run_completion(run_id, timeout_ms, opts \\ [])

  def wait_for_run_completion(run_id, timeout_ms, opts)
      when is_binary(run_id) and is_list(opts) do
    topic = LemonCore.Bus.run_done_topic(run_id)
    subscribe? = Keyword.get(opts, :subscribe?, true)
    timeout_ms = int_value(timeout_ms, 30_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if subscribe? do
      :ok = LemonCore.Bus.subscribe(topic)
    end

    try do
      wait_for_run_completion_loop(deadline)
    after
      if subscribe? do
        _ = LemonCore.Bus.unsubscribe(topic)
      end
    end
  rescue
    error ->
      {:error, {:wait_failed, Exception.message(error)}}
  end

  def wait_for_run_completion(_run_id, _timeout_ms, _opts), do: {:error, :invalid_run_id}

  @spec callback_success_status?(term()) :: boolean()
  def callback_success_status?(status) when is_integer(status), do: status in 200..299
  def callback_success_status?(_status), do: false

  defp start_async_callback_waiter(run_ctx, opts) do
    parent = self()
    ready_ref = make_ref()
    ready_timeout_ms = Keyword.get(opts, :callback_waiter_ready_timeout_ms, 1_000)

    {:ok, pid} = Task.start(fn -> async_callback_waiter(parent, ready_ref, run_ctx) end)

    receive do
      {^ready_ref, :subscribed} ->
        {:ok, %{callback_waiter_pid: pid}, %{status: "scheduled", url: run_ctx.callback_url}}

      {^ready_ref, {:error, reason}} ->
        {:error, reason}
    after
      ready_timeout_ms ->
        Process.exit(pid, :kill)
        {:error, :callback_waiter_timeout}
    end
  end

  defp async_callback_waiter(parent, ready_ref, run_ctx) do
    topic = LemonCore.Bus.run_done_topic(run_ctx.run_id)

    case LemonCore.Bus.subscribe(topic) do
      :ok ->
        send(parent, {ready_ref, :subscribed})

        try do
          deliver_callback_after_completion(run_ctx)
        after
          _ = LemonCore.Bus.unsubscribe(topic)
        end

      error ->
        send(parent, {ready_ref, {:error, error}})
    end
  rescue
    error ->
      send(parent, {ready_ref, {:error, {:callback_waiter_failed, Exception.message(error)}}})
  end

  defp deliver_callback_after_completion(run_ctx) do
    with {:ok, run_payload} <-
           wait_for_run_completion(run_ctx.run_id, run_ctx.callback_wait_timeout_ms,
             subscribe?: false
           ),
         {:ok, _status} <-
           send_callback_with_retry(run_ctx, callback_payload(run_ctx, run_payload)) do
      :ok
    else
      {:error, :timeout} ->
        Logger.warning("webhook callback wait timed out for run_id=#{run_ctx.run_id}")

      {:error, reason} ->
        Logger.warning("webhook callback failed for run_id=#{run_ctx.run_id}: #{inspect(reason)}")
    end
  end

  defp with_sync_subscription(%{sync_topic: topic}, callback) when is_binary(topic) do
    try do
      callback.()
    after
      _ = LemonCore.Bus.unsubscribe(topic)
    end
  end

  defp with_sync_subscription(_run_ctx, callback), do: callback.()

  defp cleanup_unknown_sync_subscription(%{mode: :sync, sync_topic: topic})
       when is_binary(topic) do
    _ = LemonCore.Bus.unsubscribe(topic)
    :ok
  end

  defp cleanup_unknown_sync_subscription(_run_ctx), do: :ok

  defp maybe_send_callback(%{callback_url: url} = run_ctx, payload)
       when is_binary(url) and url != "" do
    case send_callback(run_ctx, payload) do
      {:ok, status} -> %{status: "sent", http_status: status}
      {:error, reason} -> %{status: "failed", error: inspect(reason)}
    end
  end

  defp maybe_send_callback(_run_ctx, _payload), do: nil

  # The destination is re-authorized and pinned on every attempt (DNS may have
  # changed since submission), and a redirect is a failed delivery: the POST is
  # never replayed to a location the operator did not approve.
  defp send_callback(%{callback_url: callback_url} = run_ctx, payload)
       when is_binary(callback_url) do
    case LemonCore.Net.HTTP.request(:post, callback_url,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(payload),
           timeout_ms: int_value(run_ctx.timeout_ms, 30_000),
           max_body_bytes: @callback_response_max_bytes,
           allow_private: Map.get(run_ctx, :callback_allow_private, false) == true
         ) do
      {:ok, %{status: status}} ->
        if callback_success_status?(status),
          do: {:ok, status},
          else: {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:callback_failed, Exception.message(error)}}
  end

  defp send_callback(_run_ctx, _payload), do: {:error, :invalid_callback_url}

  defp send_callback_with_retry(run_ctx, payload) do
    send_callback_with_retry(run_ctx, payload, run_ctx.callback_retry, 1)
  end

  defp send_callback_with_retry(run_ctx, payload, retry_config, attempt) do
    case send_callback(run_ctx, payload) do
      {:ok, status} ->
        {:ok, status}

      {:error, _reason} = error ->
        if attempt >= retry_config.max_attempts do
          error
        else
          Process.sleep(backoff_delay_ms(retry_config, attempt))
          send_callback_with_retry(run_ctx, payload, retry_config, attempt + 1)
        end
    end
  end

  defp backoff_delay_ms(retry_config, attempt) do
    LemonCore.Retry.capped_backoff(
      retry_config.backoff_ms,
      max(attempt - 1, 0),
      retry_config.backoff_max_ms
    )
  end

  defp callback_payload(run_ctx, run_payload) do
    %{
      integration_id: run_ctx.integration_id,
      run_id: run_ctx.run_id,
      session_key: run_ctx.session_key,
      completed: completed_payload(run_payload),
      duration_ms: fetch(run_payload, :duration_ms),
      metadata: run_ctx.metadata,
      attachments: run_ctx.attachments
    }
  end

  defp completed_payload(payload) do
    fetch(payload, :completed) || payload
  end

  defp wait_for_run_completion_loop(deadline_ms) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline_ms - now

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        message ->
          case extract_run_completed(message) do
            {:ok, payload} -> {:ok, payload}
            :skip -> wait_for_run_completion_loop(deadline_ms)
          end
      after
        remaining ->
          {:error, :timeout}
      end
    end
  end

  defp extract_run_completed(%LemonCore.Event{type: :run_completed, payload: payload}),
    do: {:ok, payload}

  defp extract_run_completed(%{type: :run_completed, payload: payload}), do: {:ok, payload}
  defp extract_run_completed(_), do: :skip

  defp int_value(nil, default), do: default
  defp int_value(value, _default) when is_integer(value), do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      _ -> default
    end
  end

  defp int_value(_value, default), do: default

  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp fetch(list, key) when is_list(list),
    do: Keyword.get(list, key) || Keyword.get(list, to_string(key))

  defp fetch(_value, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
