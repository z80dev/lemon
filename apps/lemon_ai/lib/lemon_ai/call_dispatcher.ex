defmodule LemonAi.CallDispatcher do
  @moduledoc """
  Central dispatcher for routing AI provider requests through rate limiting
  and circuit breaking infrastructure.

  ## Overview

  This module acts as a coordination point that:

  1. Checks the circuit breaker state
  2. Enforces per-provider concurrency limits, queueing callers FIFO while
     the provider is at its cap
  3. Acquires a rate limit permit
  4. Returns appropriate errors when conditions aren't met

  ## Usage

      # Dispatch a request (typically wrapping an actual provider call)
      case LemonAi.CallDispatcher.dispatch(:anthropic, fn -> make_api_call() end) do
        {:ok, result} -> handle_result(result)
        {:error, :rate_limited} -> retry_later()
        {:error, :circuit_open} -> use_fallback()
        # No slot freed up within the queue timeout
        {:error, :max_concurrency} -> report_overloaded()
        {:error, reason} -> handle_error(reason)
      end

  ## Concurrency queueing

  When a provider already has `cap` requests in flight, `dispatch/3` does not
  fail immediately: the caller waits in a per-provider FIFO queue until a slot
  is released (or the cap is raised). If no slot is granted within the queue
  timeout, the call returns `{:error, :max_concurrency}` without running the
  callback. Pass `queue_timeout_ms: 0` to fail fast instead of waiting.

  Admission fails closed with `{:error, :admission_unavailable}` while a provider's
  slot authority is unavailable. Leases and configured caps survive authority
  and dispatcher restarts; other providers use independent authorities. The error
  is classified as transient by `LemonAi.Error`.

  ## Configuration

  Concurrency caps are configured per-provider via `set_concurrency_cap/2`.
  Default cap is 10 concurrent requests per provider.

  The default queue timeout (120 seconds) can be overridden:

      config :lemon_ai, LemonAi.CallDispatcher, queue_timeout_ms: 120_000

  ## Telemetry

  - `[:lemon_ai, :dispatcher, :dispatch]` - every dispatch attempt
  - `[:lemon_ai, :dispatcher, :queued]` - the caller had to wait for a slot
  - `[:lemon_ai, :dispatcher, :rejected]` - rejected with `reason:`
    `:circuit_open`, `:rate_limited`, `:admission_unavailable`, or
    `:max_concurrency` (queue wait timed out)
  - `[:lemon_ai, :model_call, :start | :stop | :exception]` - one span per
    admitted model call (rejected dispatches never start one). Streaming calls
    stop when the stream reaches its terminal state, not when `dispatch/3`
    returns. See `LemonAi.ModelCallTelemetry` for measurements and metadata.

  Callers may pass `model_call: %{model: id, api: api, call_kind: :stream | :complete}`
  in the dispatch options to label the span; only those keys are read.
  """

  use GenServer

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      pair -> pair
    end)
  end

  require Logger

  alias LemonAi.CallDispatcher.Slots

  # ============================================================================
  # Types
  # ============================================================================

  # Binary ids are user-configured custom providers (never converted to atoms).
  @type provider :: atom() | String.t()

  @default_queue_timeout_ms 120_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the call dispatcher.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatch a request through rate limiting and circuit breaking.

  Returns the callback result, or an error if the request was blocked by
  the circuit breaker, rate limiting, or concurrency limits. When the provider
  is at its concurrency cap the caller waits (FIFO) for a free slot; a wait
  that exceeds the queue timeout returns `{:error, :max_concurrency}`.

  ## Options

    * `:queue_timeout_ms` - how long to wait for a concurrency slot when the
      provider is at its cap. `0` fails fast. Defaults to the
      `:queue_timeout_ms` application config, or 120 seconds.
    * `:stream_idle_timeout` - Maximum silence between stream events, in ms
      (default 300,000). Also configurable under this module's application config.
    * `:stream_timeout` - Independent hard stream ceiling, in ms (default
      1,800,000). Also configurable under this module's application config.
      Both limits accept `:infinity`; per-call values override application config.
    * `:model_call` - optional `%{model: id, api: api, call_kind: kind}` labels
      for the `[:lemon_ai, :model_call, _]` telemetry span.
    * `:hedge_input_tokens` - zero-arity input-token estimate, required for opt-in
      model hedging. `LemonAi.stream/3` and `complete/3` supply it automatically.
      Unlabelled callbacks (including tools) never hedge.

  ## Examples

      LemonAi.CallDispatcher.dispatch(:anthropic, fn ->
        LemonAi.Providers.Anthropic.call(params)
      end)

      LemonAi.CallDispatcher.dispatch(:anthropic, callback, queue_timeout_ms: 0)
  """
  @spec dispatch(provider(), (-> result), keyword()) :: result | {:error, atom()}
        when result: any()
  def dispatch(provider, callback, opts \\ [])
      when (is_atom(provider) or is_binary(provider)) and is_function(callback, 0) and
             is_list(opts) do
    queue_timeout_ms = Keyword.get_lazy(opts, :queue_timeout_ms, &default_queue_timeout_ms/0)
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:lemon_ai, :dispatcher, :dispatch],
      %{system_time: System.system_time()},
      %{provider: provider}
    )

    # Ensure per-provider services are available
    _ = LemonAi.RateLimiter.ensure_started(provider)
    _ = LemonAi.CircuitBreaker.ensure_started(provider)

    # Check circuit breaker first (fast fail)
    if LemonAi.CircuitBreaker.open?(provider) do
      duration = System.monotonic_time() - start_time
      retry_after_ms = LemonAi.CircuitBreaker.time_until_recovery(provider)

      :telemetry.execute(
        [:lemon_ai, :dispatcher, :rejected],
        %{duration: duration, system_time: System.system_time()},
        %{provider: provider, reason: :circuit_open, retry_after_ms: retry_after_ms}
      )

      {:error, :circuit_open}
    else
      # Acquire a concurrency slot (waiting in the queue if at cap), then a
      # rate limit permit
      case acquire_slot(provider, queue_timeout_ms) do
        {:ok, slot_ref} ->
          case LemonAi.RateLimiter.acquire(provider) do
            :ok ->
              hedge_key = register_model_request(provider, opts)
              span = LemonAi.ModelCallTelemetry.start(provider, opts)

              try do
                callback
                |> invoke_callback(span)
                |> handle_dispatch_result(provider, slot_ref, opts, span)
                |> maybe_hedge(provider, callback, opts, hedge_key, span.start_monotonic)
              rescue
                error ->
                  record_last_error(provider, error)
                  release_slot(slot_ref)

                  LemonAi.CircuitBreaker.record_failure(
                    provider,
                    {:exception, Exception.message(error)}
                  )

                  reraise error, __STACKTRACE__
              after
                LemonAi.RateLimiter.release(provider)
              end

            {:error, :rate_limited} = error ->
              duration = System.monotonic_time() - start_time

              :telemetry.execute(
                [:lemon_ai, :dispatcher, :rejected],
                %{duration: duration, system_time: System.system_time()},
                %{provider: provider, reason: :rate_limited}
              )

              release_slot(slot_ref)
              error
          end

        {:error, reason} = error when reason in [:max_concurrency, :admission_unavailable] ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:lemon_ai, :dispatcher, :rejected],
            %{duration: duration, system_time: System.system_time()},
            %{provider: provider, reason: reason}
          )

          error
      end
    end
  end

  @doc """
  Set the concurrency cap for a provider.

  Returns `{:error, :admission_unavailable}` while its authority is down.
  """
  @spec set_concurrency_cap(provider(), pos_integer()) :: :ok | {:error, :admission_unavailable}
  def set_concurrency_cap(provider, cap)
      when (is_atom(provider) or is_binary(provider)) and is_integer(cap) and cap > 0 do
    Slots.call(provider, {:set_cap, cap})
  end

  @doc """
  Get the current concurrency cap for a provider.

  Returns `{:error, :admission_unavailable}` while its authority is down.
  """
  @spec get_concurrency_cap(provider()) :: pos_integer() | {:error, :admission_unavailable}
  def get_concurrency_cap(provider) when is_atom(provider) or is_binary(provider) do
    Slots.call(provider, :get_cap)
  end

  @doc """
  Get the number of active requests for a provider.

  Returns `{:error, :admission_unavailable}` while its authority is down.
  """
  @spec get_active_requests(provider()) :: non_neg_integer() | {:error, :admission_unavailable}
  def get_active_requests(provider) when is_atom(provider) or is_binary(provider) do
    Slots.call(provider, :active)
  end

  @doc """
  Get dispatcher state for debugging/monitoring.

  Includes per-provider caps, active request counts, and queued waiter counts.
  Providers whose authorities cannot answer are listed in `:unavailable`, not
  reported as having zero active requests.
  """
  @spec get_state() :: map()
  def get_state do
    initial = %{
      concurrency_caps: %{},
      active_requests: %{},
      queued: %{},
      unavailable: [],
      default_cap: 10
    }

    Enum.reduce(Slots.providers(), initial, fn provider, acc ->
      case Slots.call(provider, :snapshot) do
        %{cap: cap, active: active, queued: queued} ->
          %{
            acc
            | concurrency_caps: Map.put(acc.concurrency_caps, provider, cap),
              active_requests: Map.put(acc.active_requests, provider, active),
              queued: Map.put(acc.queued, provider, queued)
          }

        {:error, :admission_unavailable} ->
          %{acc | unavailable: [provider | acc.unavailable]}
      end
    end)
  end

  @doc "Returns the bounded latency window and duplicate-input accounting for a model."
  def hedging_state(provider, model) do
    GenServer.call(__MODULE__, {:hedge_state, {provider, model}})
  end

  @doc false
  def hedge_claim(key), do: hedge_policy_call({:hedge_claim, key}, false)

  @doc false
  def hedge_refund(key), do: hedge_policy_call({:hedge_refund, key}, :ok)

  @doc false
  def hedge_charge(key, tokens),
    do: hedge_policy_call({:hedge_charge, key, tokens}, {:error, :unavailable})

  @doc "Last observed provider failure, with a bounded, credential-free summary."
  def last_error(provider) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:last_error, to_string(provider)})
    end
  end

  defp record_last_error(provider, reason) do
    message =
      case LemonAi.Error.classify(reason) do
        :auth -> "Provider authentication failed. Check the key with lemon setup."
        :rate_limit -> "Provider rate limit exceeded. Check usage and account limits."
        :context_length -> "The request exceeded the provider context limit."
        :client -> "The provider rejected the request. Check the model configuration."
        :server -> "The provider reported a server error."
        :transient -> "The provider is temporarily unavailable. Check connectivity."
        _ -> "The provider request failed. Check the Lemon host diagnostics."
      end

    error = %{"message" => message, "atMs" => System.system_time(:millisecond)}
    GenServer.call(__MODULE__, {:record_last_error, to_string(provider), error})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{last_errors: %{}, hedging: %{}}

    Logger.debug("CallDispatcher started")

    {:ok, state}
  end

  @impl true
  def handle_call({:last_error, provider}, _from, state) do
    {:reply, Map.get(state.last_errors, provider), state}
  end

  def handle_call({:record_last_error, provider, error}, _from, state) do
    {:reply, :ok, %{state | last_errors: Map.put(state.last_errors, provider, error)}}
  end

  def handle_call({:hedge_state, key}, _from, state) do
    {:reply, Map.get(state.hedging, key, new_hedge_window()), state}
  end

  def handle_call({:hedge_request, key, enabled?}, _from, state) do
    window = Map.get(state.hedging, key, new_hedge_window())
    window = %{window | requests: window.requests + 1}

    deadline =
      if enabled? and window.samples != [] do
        sorted = Enum.sort(window.samples)
        Enum.at(sorted, div(length(sorted) * 9 + 9, 10) - 1)
      end

    {:reply, deadline, put_in(state, [:hedging, key], window)}
  end

  def handle_call({:hedge_sample, key, milliseconds}, _from, state) do
    window = Map.get(state.hedging, key, new_hedge_window())
    # Caller policy: retain the latest 100 completed first-event observations.
    window = %{window | samples: Enum.take([max(milliseconds, 1) | window.samples], 100)}
    {:reply, :ok, put_in(state, [:hedging, key], window)}
  end

  def handle_call({:hedge_claim, key}, _from, state) do
    window = Map.get(state.hedging, key, new_hedge_window())
    allowed? = (window.hedges + 1) * 10 <= window.requests
    window = if allowed?, do: %{window | hedges: window.hedges + 1}, else: window
    {:reply, allowed?, put_in(state, [:hedging, key], window)}
  end

  def handle_call({:hedge_refund, key}, _from, state) do
    window = Map.get(state.hedging, key, new_hedge_window())
    {:reply, :ok, put_in(state, [:hedging, key], %{window | hedges: max(window.hedges - 1, 0)})}
  end

  def handle_call({:hedge_charge, key, tokens}, _from, state) do
    case Map.get(state.hedging, key) do
      %{hedges: hedges} = window when hedges > 0 ->
        window = %{window | duplicate_input_tokens: window.duplicate_input_tokens + tokens}
        {:reply, :ok, put_in(state, [:hedging, key], window)}

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  defp new_hedge_window do
    %{requests: 0, hedges: 0, samples: [], duplicate_input_tokens: 0}
  end

  defp register_model_request(provider, opts) do
    case {Keyword.get(opts, :model_call), Keyword.get(opts, :hedge_attempt, false)} do
      {%{model: model, call_kind: kind}, false} when kind in [:stream, :complete] ->
        key = {provider, model}
        config = Application.get_env(:lemon_ai, __MODULE__, [])

        enabled? =
          Map.get(Keyword.get(config, :hedging, %{}), provider, false) == true and
            is_function(Keyword.get(opts, :hedge_input_tokens), 0)

        deadline = hedge_policy_call({:hedge_request, key, enabled?}, nil)
        {key, deadline}

      _ ->
        nil
    end
  end

  defp maybe_hedge({:ok, stream}, provider, callback, opts, {key, deadline}, started_at)
       when is_pid(stream) and is_integer(deadline) do
    elapsed =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    LemonAi.CallDispatcher.Hedge.start(
      stream,
      provider,
      callback,
      opts,
      key,
      max(deadline - elapsed, 0)
    )
  end

  defp maybe_hedge(result, _provider, _callback, _opts, _key, _started_at), do: result

  defp hedge_policy_call(message, fallback) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> fallback
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # The client-side call timeout exceeds the queue timeout so the server's
  # `{:error, :max_concurrency}` reply always arrives first.
  defp acquire_slot(provider, queue_timeout_ms)
       when is_integer(queue_timeout_ms) and queue_timeout_ms >= 0 do
    lease = make_ref()

    case Slots.call(provider, {:acquire, lease, queue_timeout_ms}, queue_timeout_ms + 5_000) do
      {:ok, _slot} = result ->
        result

      {:error, _reason} = error ->
        Slots.release(provider, lease)
        error
    end
  end

  defp release_slot({provider, lease}) do
    Slots.release(provider, lease)
  end

  defp handle_dispatch_result({:ok, stream_pid} = result, provider, slot_ref, opts, span)
       when is_pid(stream_pid) do
    case start_stream_tracking(provider, slot_ref, stream_pid, opts, span) do
      :ok ->
        result

      {:error, reason} ->
        Logger.warning(
          "CallDispatcher failed to start stream tracking for #{inspect(provider)}: #{inspect(reason)}"
        )

        LemonAi.ModelCallTelemetry.stop_failure(span, :error, :stream_tracking_failed)
        release_slot(slot_ref)
        LemonAi.CircuitBreaker.record_failure(provider, {:stream_tracking_start_failed, reason})
        result
    end
  end

  defp handle_dispatch_result(result, provider, slot_ref, _opts, span) do
    # Stop first: nothing below may leave the span open.
    LemonAi.ModelCallTelemetry.stop_result(span, result)
    record_result(provider, result)
    release_slot(slot_ref)
    result
  end

  # Wraps only the model callback so a raise, throw or exit closes the span
  # exactly once; the original failure is re-raised untouched.
  defp invoke_callback(callback, span) do
    callback.()
  catch
    kind, reason ->
      LemonAi.ModelCallTelemetry.exception(span, kind, reason)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp start_stream_tracking(provider, slot_ref, stream_pid, opts, span) do
    case Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
           track_stream_result(provider, slot_ref, stream_pid, span)
         end) do
      {:ok, tracker_pid} ->
        with :ok <-
               LemonAi.EventStream.configure_timeouts(stream_pid, stream_timeout_options(opts)),
             {:ok, result_ref} <-
               LemonAi.EventStream.subscribe_result(stream_pid, tracker_pid, first_event: true) do
          send(tracker_pid, {:track_stream_result, result_ref})
          :ok
        else
          {:error, reason} ->
            Process.exit(tracker_pid, :shutdown)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  # The tracker owns the model-call span once tracking started: every path
  # below emits exactly one `:stop`, and only as its last step (after the
  # breaker bookkeeping), so a failure while recording is still reported once.
  defp track_stream_result(provider, slot_ref, stream_pid, span) do
    {terminal_result, first_event_at, ended_at} = await_stream_terminal_result(stream_pid)

    if is_integer(first_event_at) and is_binary(span.metadata[:model]) do
      milliseconds =
        System.convert_time_unit(
          max(first_event_at - span.start_monotonic, 0),
          :native,
          :millisecond
        )

      hedge_policy_call({:hedge_sample, {provider, span.metadata.model}, milliseconds}, :ok)
    end

    record_stream_terminal_result(provider, terminal_result)
    LemonAi.ModelCallTelemetry.stop_stream(span, terminal_result, first_event_at, ended_at)
  rescue
    error ->
      Logger.warning(
        "CallDispatcher stream tracking crashed for #{inspect(provider)}: #{Exception.message(error)}"
      )

      LemonAi.CircuitBreaker.record_failure(
        provider,
        {:stream_tracking_exception, Exception.message(error)}
      )

      LemonAi.ModelCallTelemetry.stop_failure(span, :error, :stream_tracking_exit)
  catch
    # A :shutdown exit of the tracked stream is a deliberate teardown — a
    # consumer cancel propagated through a link cascade (e.g. the fallback
    # wrapper's relay task being shut down), not a provider failure. Record
    # neither success nor failure.
    :exit, :shutdown ->
      LemonAi.ModelCallTelemetry.stop_failure(span, :canceled, :shutdown)

    :exit, {:shutdown, _} ->
      LemonAi.ModelCallTelemetry.stop_failure(span, :canceled, :shutdown)

    :exit, {{:shutdown, _}, _} ->
      LemonAi.ModelCallTelemetry.stop_failure(span, :canceled, :shutdown)

    :exit, reason ->
      Logger.warning(
        "CallDispatcher stream tracking exited for #{inspect(provider)}: #{inspect(reason)}"
      )

      LemonAi.CircuitBreaker.record_failure(provider, {:stream_tracking_exit, reason})
      LemonAi.ModelCallTelemetry.stop_failure(span, :error, :stream_tracking_exit)
  after
    release_slot(slot_ref)
  end

  defp await_stream_terminal_result(stream_pid) do
    # EventStream owns both deadlines. Tracking must not impose another absolute
    # deadline or consume events away from the caller.
    receive do
      {:track_stream_result, result_ref} ->
        stream_ref = Process.monitor(stream_pid)
        await_terminal_loop(stream_pid, stream_ref, result_ref, nil)
    end
  end

  # The stream sends `:event_stream_first_event` (at most once) before the
  # result message, so the first-event time is always known by the time the
  # terminal result arrives.
  defp await_terminal_loop(stream_pid, stream_ref, result_ref, first_event_at) do
    receive do
      {:event_stream_first_event, ^result_ref, at} ->
        await_terminal_loop(stream_pid, stream_ref, result_ref, first_event_at || at)

      {:event_stream_result, ^result_ref, terminal_result} ->
        ended_at = System.monotonic_time()
        Process.demonitor(stream_ref, [:flush])
        {terminal_result, first_event_at, ended_at}

      {:DOWN, ^stream_ref, :process, ^stream_pid, reason} ->
        {{:error, {:stream_exit, reason}}, first_event_at, System.monotonic_time()}
    end
  end

  defp stream_timeout_options(opts) do
    config = Application.get_env(:lemon_ai, __MODULE__, [])

    Enum.reduce(
      [stream_timeout: :timeout, stream_idle_timeout: :idle_timeout],
      [
        timeout_reason: :dispatcher_stream_timeout,
        idle_timeout_reason: :dispatcher_stream_idle_timeout
      ],
      fn {key, stream_key}, acc ->
        case Keyword.get(opts, key, Keyword.get(config, key)) do
          nil -> acc
          value -> Keyword.put(acc, stream_key, value)
        end
      end
    )
  end

  defp default_queue_timeout_ms do
    case Application.get_env(:lemon_ai, __MODULE__, [])
         |> Keyword.get(:queue_timeout_ms, @default_queue_timeout_ms) do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_queue_timeout_ms
    end
  end

  defp record_stream_terminal_result(provider, {:ok, _message}) do
    LemonAi.CircuitBreaker.record_success(provider)
  end

  defp record_stream_terminal_result(provider, {:error, {:canceled, _} = reason}) do
    if LemonAi.Error.stream_terminal_breaker_failure?(reason) do
      record_last_error(provider, reason)
      LemonAi.CircuitBreaker.record_failure(provider, reason)
    end
  end

  defp record_stream_terminal_result(provider, {:error, reason}) do
    record_last_error(provider, reason)
    # Stream-terminal errors are NOT automatically service failures: a
    # 401/429/400 can surface after the connection is established — the
    # provider rejects the request mid-stream, or the HTTP error body arrives
    # as the stream's terminal event. Classify first so one bad credential or
    # malformed request cannot trip the whole provider's circuit breaker.
    if LemonAi.Error.stream_terminal_breaker_failure?(reason) do
      LemonAi.CircuitBreaker.record_failure(provider, reason)
    else
      :ok
    end
  end

  defp record_stream_terminal_result(provider, unexpected_result) do
    LemonAi.CircuitBreaker.record_failure(
      provider,
      {:unexpected_stream_result, unexpected_result}
    )
  end

  defp record_result(provider, result) do
    case result do
      {:ok, _} ->
        LemonAi.CircuitBreaker.record_success(provider)

      {:error, reason} ->
        record_last_error(provider, reason)
        # Only count errors that indicate the SERVICE is unhealthy, not errors
        # caused by the request itself: client errors (400, 413), rate limits
        # (429), and auth errors (401/403) must not trip the circuit breaker.
        # The decision is owned by LemonAi.Error so all callers share one set.
        if LemonAi.Error.circuit_breaker_failure?(reason) do
          LemonAi.CircuitBreaker.record_failure(provider, reason)
        else
          :ok
        end

      # For non-tuple results, assume success
      _ ->
        LemonAi.CircuitBreaker.record_success(provider)
    end
  end
end
