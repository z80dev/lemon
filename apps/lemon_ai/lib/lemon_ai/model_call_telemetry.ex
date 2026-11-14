defmodule LemonAi.ModelCallTelemetry do
  @moduledoc """
  Span-style telemetry for one admitted model call, emitted by
  `LemonAi.CallDispatcher`.

  ## Events

    * `[:lemon_ai, :model_call, :start]` - measurements `%{system_time,
      monotonic_time}`; metadata `%{provider, telemetry_span_context}` plus
      `model` (model id), `api` and `call_kind` (`:stream | :complete`) when the
      caller supplied them.
    * `[:lemon_ai, :model_call, :stop]` - measurements `%{duration}` (native
      units, monotonic delta), `first_event_duration` (native, time to the first
      text/thinking/tool-call delta, only when one was observed) and
      `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`
      (each only when the provider reported it); metadata is the start metadata
      plus `outcome` (`:ok | :error | :canceled | :aborted`), `stop_reason` when
      the final message has one, and `error_category` for every non-`:ok`
      outcome.
    * `[:lemon_ai, :model_call, :exception]` - the dispatch callback raised,
      threw or exited. Measurements `%{duration}`; metadata is the start metadata
      plus `kind` (`:error | :throw | :exit`) and `reason` (the exception
      module for `:error`, otherwise the kind).

  Exactly one `:stop` or `:exception` follows every `:start`. Calls rejected by
  the circuit breaker, rate limiter or concurrency queue never start a span.
  For streams the `:stop` fires when the stream reaches its terminal state
  (done, error, cancel, timeout or producer death), not when the dispatch
  callback returns.

  `error_category` is a bounded atom: an `LemonAi.Error.classify/1` category
  (`:auth`, `:rate_limit`, `:context_length`, `:client`, `:server`,
  `:transient`, `:unknown`), a cancel cause (`:canceled`, `:timeout`,
  `:idle_timeout`, `:owner_down`, `:shutdown`), `:aborted`, `:stream_exit`,
  `:stream_tracking_failed`, `:stream_tracking_exit` or `:unexpected_result`.
  Prompts, messages, credentials, URLs and raw error terms are never included.
  """

  alias LemonAi.Error

  @event [:lemon_ai, :model_call]
  @call_kinds [:stream, :complete]

  @typedoc "Opaque span handle returned by `start/2`."
  @type span :: %{
          ref: reference(),
          start_monotonic: integer(),
          metadata: map()
        }

  @doc """
  Emit `:start` for `provider`. `opts` may carry a `:model_call` map with
  `:model`, `:api` and `:call_kind`; anything else is ignored.
  """
  @spec start(atom() | String.t(), keyword()) :: span()
  def start(provider, opts) do
    ref = make_ref()

    metadata =
      %{provider: provider, telemetry_span_context: ref}
      |> Map.merge(model_metadata(Keyword.get(opts, :model_call)))

    start_monotonic = System.monotonic_time()

    :telemetry.execute(
      @event ++ [:start],
      %{system_time: System.system_time(), monotonic_time: start_monotonic},
      metadata
    )

    %{ref: ref, start_monotonic: start_monotonic, metadata: metadata}
  end

  @doc """
  Emit `:stop` for a non-streaming callback result.
  """
  @spec stop_result(span(), term()) :: :ok
  def stop_result(span, result) do
    {outcome, category, message} = describe_result(result)
    emit_stop(span, outcome, category, message, nil, System.monotonic_time())
  end

  @doc """
  Emit `:stop` for the terminal result of a tracked stream.

  `first_event_at` is the native monotonic time of the first content delta (or
  `nil`), `ended_at` the native monotonic time the terminal result arrived.
  """
  @spec stop_stream(span(), term(), integer() | nil, integer()) :: :ok
  def stop_stream(span, terminal_result, first_event_at, ended_at) do
    {outcome, category, message} = describe_terminal(terminal_result)
    emit_stop(span, outcome, category, message, first_event_at, ended_at)
  end

  @doc """
  Emit `:stop` for a call that ended without a usable result (for example the
  stream tracker could not start or crashed).
  """
  @spec stop_failure(span(), :error | :canceled, atom()) :: :ok
  def stop_failure(span, outcome, category) do
    emit_stop(span, outcome, category, nil, nil, System.monotonic_time())
  end

  @doc """
  Emit `:exception` for a callback that raised, threw or exited.
  """
  @spec exception(span(), :error | :throw | :exit, term()) :: :ok
  def exception(span, kind, reason) do
    :telemetry.execute(
      @event ++ [:exception],
      %{duration: System.monotonic_time() - span.start_monotonic},
      Map.merge(span.metadata, %{kind: kind, reason: exception_reason(kind, reason)})
    )
  end

  # ---------------------------------------------------------------------------

  defp emit_stop(span, outcome, category, message, first_event_at, ended_at) do
    measurements =
      %{duration: max(ended_at - span.start_monotonic, 0)}
      |> put_first_event_duration(span, first_event_at)
      |> Map.merge(usage_measurements(message))

    metadata =
      span.metadata
      |> Map.put(:outcome, outcome)
      |> put_present(:stop_reason, stop_reason(message))
      |> put_present(:error_category, category)

    :telemetry.execute(@event ++ [:stop], measurements, metadata)
  end

  defp put_first_event_duration(measurements, _span, nil), do: measurements

  defp put_first_event_duration(measurements, span, first_event_at) do
    Map.put(measurements, :first_event_duration, max(first_event_at - span.start_monotonic, 0))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp model_metadata(%{} = model_call) do
    Enum.reduce(model_call, %{}, fn
      {:model, model}, acc when is_binary(model) -> Map.put(acc, :model, model)
      {:api, api}, acc when is_atom(api) or is_binary(api) -> Map.put(acc, :api, api)
      {:call_kind, kind}, acc when kind in @call_kinds -> Map.put(acc, :call_kind, kind)
      _other, acc -> acc
    end)
  end

  defp model_metadata(_other), do: %{}

  defp describe_result({:ok, message}), do: describe_message(:ok, message)
  defp describe_result({:error, reason}), do: describe_error(reason)
  defp describe_result(_other), do: {:ok, nil, nil}

  defp describe_terminal({:ok, message}), do: describe_message(:ok, message)

  defp describe_terminal({:error, {:canceled, reason}}),
    do: {:canceled, cancel_category(reason), nil}

  defp describe_terminal({:error, {:stream_exit, _reason}}), do: {:error, :stream_exit, nil}
  defp describe_terminal({:error, reason}), do: describe_error(reason)
  defp describe_terminal(_unexpected), do: {:error, :unexpected_result, nil}

  defp describe_message(:ok, message) when is_map(message) do
    if stop_reason(message) == :aborted,
      do: {:aborted, :aborted, message},
      else: {:ok, nil, message}
  end

  defp describe_message(:ok, _other), do: {:ok, nil, nil}

  defp describe_error(reason) when is_map(reason) do
    if stop_reason(reason) == :aborted,
      do: {:aborted, :aborted, reason},
      else: {:error, classify(reason), reason}
  end

  defp describe_error(reason), do: {:error, classify(reason), nil}

  defp classify(reason) do
    Error.classify(reason)
  rescue
    _ -> :unknown
  end

  defp cancel_category(:shutdown), do: :shutdown
  defp cancel_category(:owner_down), do: :owner_down

  defp cancel_category(reason)
       when reason in [:timeout, :stream_timeout, :dispatcher_stream_timeout],
       do: :timeout

  defp cancel_category(reason)
       when reason in [:stream_idle_timeout, :dispatcher_stream_idle_timeout],
       do: :idle_timeout

  defp cancel_category(_reason), do: :canceled

  defp stop_reason(%{stop_reason: reason}) when is_atom(reason) and not is_nil(reason), do: reason
  defp stop_reason(_message), do: nil

  defp usage_measurements(%{usage: %{} = usage}) do
    [
      input: :input_tokens,
      output: :output_tokens,
      cache_read: :cache_read_tokens,
      cache_write: :cache_write_tokens
    ]
    |> Enum.flat_map(fn {field, key} ->
      case Map.get(usage, field) do
        count when is_integer(count) and count >= 0 -> [{key, count}]
        _unknown -> []
      end
    end)
    |> Map.new()
  end

  defp usage_measurements(_message), do: %{}

  defp exception_reason(:error, reason) do
    case Exception.normalize(:error, reason) do
      %{__exception__: true, __struct__: module} -> module
      _other -> :error
    end
  end

  defp exception_reason(kind, _reason), do: kind
end
