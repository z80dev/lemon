defmodule LemonAi.Providers.StreamTransport do
  @moduledoc """
  Shared streaming HTTP transport for provider wire protocols.

  `post_sse/5` POSTs a request with `into: :self` and returns a lazy,
  single-pass stream of `LemonAi.Providers.SSEParser` items. `post_stream/5`
  returns the raw body chunks for binary framings such as Bedrock event
  streams. Both follow one contract:

    * A failure before the response body is consumed — a non-2xx status or a
      transport error — is retried through `LemonAi.Retry.run/2` only when
      `LemonAi.Error.retryable?/1` accepts it and the caller's bounded policy
      allows another attempt. Rate limits surface instead of sleeping when the
      policy has an alternate candidate. A response whose body has started is
      never replayed here; callers that own a larger budget pass a one-attempt
      policy.
    * A non-2xx body is read with a 16 KiB and one-second bound, then
      classified by `LemonAi.Error.parse_http_error/4` (or the `:http_error`
      option). The returned error never carries the raw body or the
      transport struct.
    * The stream consumes only its own response's messages: unrelated
      `{ref, :done}`, `{:error, _}` or `:DOWN` messages in the caller's mailbox
      neither end nor fail it. The response is canceled on every exit — EOF,
      consumer halt, exception and timeout — and its queued messages removed.
    * A transport error, loss of the connection process or `idle_timeout`
      without a body message ends the stream with one final
      `{:stream_error, details}` item carrying `LemonAi.Error.to_error_details/1`
      output. A clean EOF only ends the stream: the protocol parser must check
      that its terminal event arrived and report `truncated/1` otherwise.

  Owner death needs no message: Req's HTTP/1 connection process is linked to
  the requesting process and exits with it.
  """

  alias LemonAi.{Error, Retry}
  alias LemonAi.Providers.SSEParser

  require Logger

  @default_idle_timeout 300_000
  @max_error_body_bytes 16_384
  @error_body_timeout 1_000
  @cancel_drain_timeout 1_000

  @type url :: String.t() | (non_neg_integer() -> String.t())
  @type body :: map() | binary()
  @type result :: {:ok, Enumerable.t()} | {:error, Error.parsed_error(), non_neg_integer() | nil}

  @doc """
  POSTs `body` (a map is sent as JSON, a binary as-is) and returns its SSE items.

  `url` may be a function of the zero-based attempt for endpoint fallback.
  Options: `:provider` (error messages), `:idle_timeout` (milliseconds or
  `:infinity`, default 300,000) and `:http_error`, a
  `(status, body, headers -> parsed_error)` classifier for non-2xx responses.
  """
  @spec post_sse(url(), Enumerable.t(), body(), Retry.Policy.t(), keyword()) :: result()
  def post_sse(url, headers, body, policy, opts \\ []) do
    with {:ok, response} <- post(url, headers, body, policy, opts) do
      {:ok, sse_events(response, idle_timeout(opts))}
    end
  end

  @doc "Like `post_sse/5`, but streams raw binary body chunks for non-SSE framings."
  @spec post_stream(url(), Enumerable.t(), body(), Retry.Policy.t(), keyword()) :: result()
  def post_stream(url, headers, body, policy, opts \\ []) do
    with {:ok, response} <- post(url, headers, body, policy, opts) do
      {:ok, body_chunks(response, idle_timeout(opts))}
    end
  end

  @doc """
  The transport idle limit for a provider stream.

  The `LemonAi.EventStream` watchdog cancels after the same silence between
  events; the transport detects it slightly earlier so the provider reports a
  classified error with its partial output instead of a generic cancel.
  """
  @spec idle_timeout_for(timeout() | nil) :: timeout()
  def idle_timeout_for(ms) when is_integer(ms) and ms > 0, do: ms - min(div(ms, 10), 1_000)
  def idle_timeout_for(:infinity), do: :infinity
  def idle_timeout_for(_), do: @default_idle_timeout

  @doc """
  Classified error for a stream that ended before the provider's terminal event.

  The connection closed early, so the details are transient and retryable; a
  partial generation must never be reported as a successful stop.
  """
  @spec truncated(atom() | String.t() | nil) :: Error.parsed_error()
  def truncated(provider) do
    details = Error.to_error_details(:closed)
    service = if is_nil(provider), do: "the model provider", else: "provider #{provider}"

    %{
      details
      | message:
          "Connection to #{service} closed before the response completed. Please try again."
    }
  end

  @doc "Classified details for a complete stream event or frame that cannot be decoded."
  @spec malformed_event() :: Error.parsed_error()
  def malformed_event do
    %{
      category: :server,
      status: nil,
      message: "Model provider sent a malformed stream event. Please try again.",
      provider_message: nil,
      rate_limit_info: nil,
      retryable: true
    }
  end

  @doc """
  Collect a bounded HTTP error body for classification, not public display.

  Async bodies are limited to 16 KiB and a total elapsed deadline (one second by
  default). The transport is canceled and its queued messages cleaned up before
  returning, including on completion, timeout or transport failure. Unknown body
  terms are never inspected.
  """
  @spec error_body(term()) :: String.t()
  def error_body(body), do: error_body(body, @error_body_timeout)

  @spec error_body(term(), non_neg_integer()) :: String.t()
  def error_body(body, _timeout_ms) when is_binary(body) do
    body
    |> binary_part(0, min(byte_size(body), @max_error_body_bytes))
    |> :binary.copy()
    |> valid_utf8_prefix()
  end

  def error_body(%Req.Response.Async{} = async, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    response = %Req.Response{body: async}
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect_error_body(response, [], 0, deadline)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> valid_utf8_prefix()
    after
      Req.cancel_async_response(response)
    end
  end

  def error_body(%_{} = _body, _timeout_ms), do: ""

  def error_body(body, timeout_ms) when is_map(body) do
    case Jason.encode(body) do
      {:ok, text} -> error_body(text, timeout_ms)
      {:error, _} -> ""
    end
  end

  def error_body(_body, _timeout_ms), do: ""

  # ============================================================================
  # Request and retry
  # ============================================================================

  defp post(url, headers, body, policy, opts) do
    idle_timeout = idle_timeout(opts)

    options =
      policy
      |> Map.from_struct()
      |> Map.merge(%{
        failure: fn
          {:ok, _response} -> :success
          {:error, error} -> {:failed, error}
        end,
        retryable?: &(Error.retryable?(&1) and not Retry.rotate_rate_limit?(policy, &1))
      })

    Retry.run(
      fn attempt ->
        result = request(url_for(url, attempt - 1), headers, body, idle_timeout)
        log_failed_attempt(result, attempt)
        result
      end,
      options
    )
    |> case do
      {:ok, response} ->
        {:ok, response}

      {:error, {:http_error, status, error_body, response_headers}} ->
        details = classify_http(opts, status, error_body, response_headers)
        {:error, details, Retry.retry_after_ms(response_headers)}

      {:error, reason} ->
        details = Error.to_error_details(reason)
        {:error, %{details | message: Error.format_error(reason, opts[:provider])}, nil}
    end
  end

  defp request(url, headers, body, idle_timeout) do
    options =
      [
        headers: headers,
        retry: false,
        into: :self,
        receive_timeout: receive_timeout(idle_timeout)
      ] ++ body_option(body)

    case Req.post(url, options) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, headers: response_headers, body: error_body}} ->
        {:error, {:http_error, status, error_body(error_body), response_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp body_option(body) when is_map(body), do: [json: body]
  defp body_option(body) when is_binary(body), do: [body: body]

  defp url_for(url, _attempt) when is_binary(url), do: url
  defp url_for(url, attempt) when is_function(url, 1), do: url.(attempt)

  defp classify_http(opts, status, body, headers) do
    case Keyword.get(opts, :http_error) do
      nil -> Error.parse_http_error(status, body, headers, opts[:provider])
      classify -> classify.(status, body, headers)
    end
  end

  defp log_failed_attempt({:error, {:http_error, status, body, headers}}, attempt) do
    category = Error.parse_http_error(status, body, headers).category

    Logger.warning(
      "Provider request failed: status=#{status} category=#{category} attempt=#{attempt}"
    )
  end

  defp log_failed_attempt({:error, reason}, attempt) do
    Logger.warning(
      "Provider transport failed: category=#{Error.classify(reason)} attempt=#{attempt}"
    )
  end

  defp log_failed_attempt(_result, _attempt), do: :ok

  defp idle_timeout(opts), do: Keyword.get(opts, :idle_timeout, @default_idle_timeout)

  # The connection's own receive timeout only backs up the stream's idle timer.
  defp receive_timeout(:infinity), do: :infinity
  defp receive_timeout(idle_timeout), do: idle_timeout + 1_000

  # ============================================================================
  # Response body
  # ============================================================================

  @doc """
  The SSE items of an already-started `into: :self` response, under the
  stream contract of `post_sse/5`: own messages only, cancel on every exit and
  a final `{:stream_error, details}` on failure or `idle_timeout` silence.
  """
  @spec sse_events(Req.Response.t(), timeout()) :: Enumerable.t()
  def sse_events(%Req.Response{body: %Req.Response.Async{}} = response, idle_timeout) do
    body_stream(response, idle_timeout, &SSEParser.parse_sse_chunk/1, fn buffer ->
      {items, _rest} = SSEParser.parse_sse_chunk(buffer <> "\n\n")
      items
    end)
  end

  defp body_chunks(response, idle_timeout) do
    body_stream(response, idle_timeout, &{[&1], ""}, fn _buffer -> [] end)
  end

  defp body_stream(
         %Req.Response{body: %Req.Response.Async{} = async} = response,
         idle,
         decode,
         flush
       ) do
    Stream.resource(
      fn -> %{buffer: "", done?: false, monitor: monitor_connection(async)} end,
      fn
        %{done?: true} = state -> {:halt, state}
        state -> next_items(response, state, idle, decode, flush)
      end,
      fn state -> cancel(response, state.monitor) end
    )
  end

  defp next_items(%Req.Response{body: %{ref: ref}} = response, state, idle, decode, flush) do
    monitor = state.monitor

    receive do
      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          {:ok, parts} -> Enum.reduce(parts, {[], state}, &apply_part(&1, &2, decode, flush))
          {:error, reason} -> fail(state, Error.to_error_details(reason))
          :unknown -> {[], state}
        end

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        fail(state, Error.to_error_details(:closed))
    after
      idle -> fail(state, Error.to_error_details(:stream_idle_timeout))
    end
  end

  defp apply_part(_part, {items, %{done?: true} = state}, _decode, _flush), do: {items, state}

  defp apply_part({:data, chunk}, {items, state}, decode, _flush) do
    {parsed, buffer} = decode.(state.buffer <> chunk)
    {items ++ parsed, %{state | buffer: buffer, done?: stream_error?(parsed)}}
  end

  defp apply_part(:done, {items, state}, _decode, flush),
    do: {items ++ flush.(state.buffer), %{state | buffer: "", done?: true}}

  defp apply_part(_part, acc, _decode, _flush), do: acc

  defp stream_error?(items),
    do: match?([_ | _], items) and match?({:stream_error, _}, List.last(items))

  defp fail(state, details), do: {[{:stream_error, details}], %{state | done?: true}}

  # Req's HTTP/1 response process is the second element of its request ref.
  # Monitor it so its exit without a terminal message fails the stream.
  defp monitor_connection(%Req.Response.Async{ref: {_pool, pid}}) when is_pid(pid),
    do: Process.monitor(pid)

  defp monitor_connection(_async), do: nil

  # Cancel, then wait for the connection process to exit so none of its
  # messages can arrive after the final mailbox cleanup.
  defp cancel(%Req.Response{body: %{ref: ref}} = response, monitor) do
    Req.cancel_async_response(response)

    if monitor do
      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      after
        @cancel_drain_timeout -> Process.demonitor(monitor, [:flush])
      end
    end

    drain(ref)
  end

  defp drain(ref) do
    receive do
      {^ref, _} -> drain(ref)
    after
      0 -> :ok
    end
  end

  defp collect_error_body(_response, chunks, size, _deadline)
       when size >= @max_error_body_bytes,
       do: chunks

  defp collect_error_body(%Req.Response{body: %{ref: ref}} = response, chunks, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      chunks
    else
      receive do
        {^ref, _} = message ->
          case Req.parse_message(response, message) do
            {:ok, parts} ->
              case collect_parts(parts, chunks, size) do
                {:cont, chunks, size} -> collect_error_body(response, chunks, size, deadline)
                {:halt, chunks} -> chunks
              end

            {:error, _} ->
              chunks

            :unknown ->
              collect_error_body(response, chunks, size, deadline)
          end
      after
        remaining -> chunks
      end
    end
  end

  defp collect_parts([], chunks, size), do: {:cont, chunks, size}
  defp collect_parts([:done | _], chunks, _size), do: {:halt, chunks}

  defp collect_parts([{:data, chunk} | rest], chunks, size) when is_binary(chunk) do
    length = min(byte_size(chunk), @max_error_body_bytes - size)
    collect_parts(rest, [binary_part(chunk, 0, length) | chunks], size + length)
  end

  defp collect_parts([_ | rest], chunks, size), do: collect_parts(rest, chunks, size)

  # Discard incomplete/invalid suffixes rather than growing the byte-limited
  # body with replacement characters, or passing invalid UTF-8 to classifiers.
  defp valid_utf8_prefix(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      {:error, valid, _} -> valid
      {:incomplete, valid, _} -> valid
      valid when is_binary(valid) -> valid
    end
  end
end
