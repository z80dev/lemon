defmodule LemonGateway.Transports.Webhook.Callback do
  @moduledoc """
  Callback delivery for webhook transport.

  Handles sending HTTP POST callbacks to external URLs after run completion,
  with support for synchronous waiting, asynchronous background delivery,
  and exponential backoff retries.
  """

  require Logger

  import LemonGateway.Transports.Webhook.Helpers

  @default_timeout_ms 30_000
  @callback_waiter_ready_timeout_ms 1_000

  @doc """
  Prepares the wait/subscription setup before submitting a run.

  For `:sync` mode, subscribes to the run's Bus topic so completion events
  can be received.

  For `:async` mode with a callback URL, starts a background task that
  waits for completion and delivers the callback.
  """
  @spec prepare_wait_before_submit(atom(), map()) :: {:ok, map(), term()} | {:error, term()}
  def prepare_wait_before_submit(:sync, %{run_id: run_id}) do
    topic = LemonCore.Bus.run_topic(run_id)
    :ok = LemonCore.Bus.subscribe(topic)
    {:ok, %{sync_topic: topic}, nil}
  rescue
    error ->
      {:error, {:wait_prepare_failed, Exception.message(error)}}
  end

  def prepare_wait_before_submit(:async, %{callback_url: callback_url} = run_ctx)
      when is_binary(callback_url) and callback_url != "" do
    start_async_callback_waiter(run_ctx)
  end

  def prepare_wait_before_submit(_mode, _run_ctx), do: {:ok, %{}, nil}

  @doc """
  Cleans up wait resources (Bus subscription or callback waiter process).
  """
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

  @doc """
  Executes a callback within a sync subscription scope, ensuring the
  Bus subscription is cleaned up afterward.
  """
  @spec with_sync_subscription(map(), (-> term())) :: term()
  def with_sync_subscription(%{sync_topic: topic}, callback) when is_binary(topic) do
    try do
      callback.()
    after
      _ = LemonCore.Bus.unsubscribe(topic)
    end
  end

  def with_sync_subscription(_run_ctx, callback), do: callback.()

  @doc """
  Waits for a run to complete by listening for Bus events.
  """
  @spec wait_for_run_completion(String.t(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_run_completion(run_id, timeout_ms, opts \\ [])

  def wait_for_run_completion(run_id, timeout_ms, opts)
      when is_binary(run_id) and is_list(opts) do
    topic = LemonCore.Bus.run_topic(run_id)
    subscribe? = Keyword.get(opts, :subscribe?, true)
    timeout_ms = int_value(timeout_ms, @default_timeout_ms)
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

  @doc """
  Optionally sends a callback if a URL is provided.
  Returns a status map or nil.
  """
  @spec maybe_send_callback(String.t() | nil, map(), integer()) :: map() | nil
  def maybe_send_callback(nil, _payload, _timeout_ms), do: nil
  def maybe_send_callback("", _payload, _timeout_ms), do: nil

  def maybe_send_callback(callback_url, payload, timeout_ms) do
    case send_callback(callback_url, payload, timeout_ms) do
      {:ok, status} ->
        %{status: "sent", http_status: status}

      {:error, reason} ->
        %{status: "failed", error: inspect(reason)}
    end
  end

  @doc """
  Sends a callback with exponential backoff retries.
  """
  @spec send_callback_with_retry(String.t(), map(), integer(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_callback_with_retry(callback_url, payload, timeout_ms, retry_config) do
    send_callback_with_retry(callback_url, payload, timeout_ms, retry_config, 1)
  end

  @doc """
  Checks whether an HTTP status code indicates success (2xx).
  """
  @spec callback_success_status?(term()) :: boolean()
  def callback_success_status?(status) when is_integer(status), do: status in 200..299
  def callback_success_status?(_status), do: false

  @doc """
  Builds the callback payload for a completed run.
  """
  @spec callback_payload(map(), map()) :: map()
  def callback_payload(run_ctx, run_payload) do
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

  @doc """
  Extracts the completed payload from a run result.
  """
  @spec completed_payload(map()) :: term()
  def completed_payload(payload) do
    fetch(payload, :completed) || payload
  end

  # --- Private helpers ---

  defp start_async_callback_waiter(run_ctx) do
    parent = self()
    ready_ref = make_ref()

    case Task.start(fn -> async_callback_waiter(parent, ready_ref, run_ctx) end) do
      {:ok, pid} ->
        receive do
          {^ready_ref, :subscribed} ->
            {:ok, %{callback_waiter_pid: pid}, %{status: "scheduled", url: run_ctx.callback_url}}

          {^ready_ref, {:error, reason}} ->
            {:error, reason}
        after
          @callback_waiter_ready_timeout_ms ->
            Process.exit(pid, :kill)
            {:error, :callback_waiter_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp async_callback_waiter(parent, ready_ref, run_ctx) do
    topic = LemonCore.Bus.run_topic(run_ctx.run_id)

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
           send_callback_with_retry(
             run_ctx.callback_url,
             callback_payload(run_ctx, run_payload),
             run_ctx.timeout_ms,
             run_ctx.callback_retry
           ) do
      :ok
    else
      {:error, :timeout} ->
        Logger.warning("webhook callback wait timed out for run_id=#{run_ctx.run_id}")

      {:error, reason} ->
        Logger.warning("webhook callback failed for run_id=#{run_ctx.run_id}: #{inspect(reason)}")
    end
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
  defp extract_run_completed({:run_completed, payload}), do: {:ok, payload}
  defp extract_run_completed(_), do: :skip

  defp send_callback(callback_url, payload, timeout_ms) when is_binary(callback_url) do
    request_timeout = int_value(timeout_ms, @default_timeout_ms)
    body = Jason.encode!(payload)

    request =
      {String.to_charlist(callback_url), [{~c"content-type", ~c"application/json"}],
       ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           [timeout: request_timeout, connect_timeout: min(request_timeout, 5_000)],
           []
         ) do
      {:ok, {{_http_version, status, _reason_phrase}, _headers, _resp_body}} ->
        if callback_success_status?(status) do
          {:ok, status}
        else
          {:error, {:unexpected_status, status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:callback_failed, Exception.message(error)}}
  end

  defp send_callback(_callback_url, _payload, _timeout_ms), do: {:error, :invalid_callback_url}

  defp send_callback_with_retry(callback_url, payload, timeout_ms, retry_config, attempt) do
    case send_callback(callback_url, payload, timeout_ms) do
      {:ok, status} ->
        {:ok, status}

      {:error, _reason} = error ->
        if attempt >= retry_config.max_attempts do
          error
        else
          Process.sleep(backoff_delay_ms(retry_config, attempt))
          send_callback_with_retry(callback_url, payload, timeout_ms, retry_config, attempt + 1)
        end
    end
  end

  defp backoff_delay_ms(retry_config, attempt) do
    scaled = trunc(retry_config.backoff_ms * :math.pow(2, max(attempt - 1, 0)))
    min(scaled, retry_config.backoff_max_ms)
  end
end
