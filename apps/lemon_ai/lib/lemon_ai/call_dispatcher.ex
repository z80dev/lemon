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

  ## Configuration

  Concurrency caps are configured per-provider via `set_concurrency_cap/2`.
  Default cap is 10 concurrent requests per provider.

  The default queue timeout (120 seconds) can be overridden:

      config :lemon_ai, LemonAi.CallDispatcher, queue_timeout_ms: 120_000

  ## Telemetry

  - `[:lemon_ai, :dispatcher, :dispatch]` - every dispatch attempt
  - `[:lemon_ai, :dispatcher, :queued]` - the caller had to wait for a slot
  - `[:lemon_ai, :dispatcher, :rejected]` - rejected with `reason:`
    `:circuit_open`, `:rate_limited`, or `:max_concurrency` (queue wait timed out)
  """

  use GenServer

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  # Binary ids are user-configured custom providers (never converted to atoms).
  @type provider :: atom() | String.t()
  # {waiter_ref, from, from_pid, timeout_timer_ref}
  @type waiter :: {reference(), GenServer.from(), pid(), reference()}
  @type state :: %{
          concurrency_caps: %{provider() => pos_integer()},
          active_requests: %{provider() => non_neg_integer()},
          monitors: %{reference() => provider()},
          waiters: %{provider() => :queue.queue(waiter())}
        }

  @default_concurrency_cap 10
  @default_queue_timeout_ms 120_000
  @default_stream_result_timeout_ms 300_000
  @default_stream_cancel_reason :dispatcher_stream_timeout

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
              try do
                callback.()
                |> handle_dispatch_result(provider, slot_ref)
              rescue
                error ->
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

        {:error, :max_concurrency} = error ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:lemon_ai, :dispatcher, :rejected],
            %{duration: duration, system_time: System.system_time()},
            %{provider: provider, reason: :max_concurrency}
          )

          error
      end
    end
  end

  @doc """
  Set the concurrency cap for a provider.
  """
  @spec set_concurrency_cap(provider(), pos_integer()) :: :ok
  def set_concurrency_cap(provider, cap)
      when (is_atom(provider) or is_binary(provider)) and is_integer(cap) and cap > 0 do
    GenServer.call(__MODULE__, {:set_concurrency_cap, provider, cap})
  end

  @doc """
  Get the current concurrency cap for a provider.
  """
  @spec get_concurrency_cap(provider()) :: pos_integer()
  def get_concurrency_cap(provider) when is_atom(provider) or is_binary(provider) do
    GenServer.call(__MODULE__, {:get_concurrency_cap, provider})
  end

  @doc """
  Get the number of active requests for a provider.
  """
  @spec get_active_requests(provider()) :: non_neg_integer()
  def get_active_requests(provider) when is_atom(provider) or is_binary(provider) do
    GenServer.call(__MODULE__, {:get_active_requests, provider})
  end

  @doc """
  Get dispatcher state for debugging/monitoring.

  Includes per-provider caps, active request counts, and queued waiter counts.
  """
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      concurrency_caps: %{},
      active_requests: %{},
      monitors: %{},
      waiters: %{}
    }

    Logger.debug("CallDispatcher started")

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire_slot, provider, queue_timeout_ms}, {from_pid, _tag} = from, state) do
    cap = Map.get(state.concurrency_caps, provider, @default_concurrency_cap)
    active = Map.get(state.active_requests, provider, 0)

    cond do
      active < cap ->
        {monitor_ref, new_state} = grant_slot(state, provider, from_pid)
        {:reply, {:ok, monitor_ref}, new_state}

      queue_timeout_ms == 0 ->
        {:reply, {:error, :max_concurrency}, state}

      true ->
        {:noreply, enqueue_waiter(state, provider, from, from_pid, queue_timeout_ms)}
    end
  end

  @impl true
  def handle_call({:release_slot, monitor_ref}, _from, state) do
    {:reply, :ok, release_slot_by_ref(state, monitor_ref, demonitor: true)}
  end

  @impl true
  def handle_call({:set_concurrency_cap, provider, cap}, _from, state) do
    new_caps = Map.put(state.concurrency_caps, provider, cap)
    {:reply, :ok, grant_waiters(%{state | concurrency_caps: new_caps}, provider)}
  end

  @impl true
  def handle_call({:get_concurrency_cap, provider}, _from, state) do
    cap = Map.get(state.concurrency_caps, provider, @default_concurrency_cap)
    {:reply, cap, state}
  end

  @impl true
  def handle_call({:get_active_requests, provider}, _from, state) do
    active = Map.get(state.active_requests, provider, 0)
    {:reply, active, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    info = %{
      concurrency_caps: state.concurrency_caps,
      active_requests: state.active_requests,
      queued: Map.new(state.waiters, fn {provider, queue} -> {provider, :queue.len(queue)} end),
      default_cap: @default_concurrency_cap
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, release_slot_by_ref(state, monitor_ref)}
  end

  @impl true
  def handle_info({:waiter_timeout, provider, waiter_ref}, state) do
    queue = Map.get(state.waiters, provider, :queue.new())

    # A waiter granted a slot just before its timer fired is no longer queued;
    # the stale timeout message is ignored.
    case Enum.split_with(:queue.to_list(queue), &match?({^waiter_ref, _, _, _}, &1)) do
      {[{_waiter_ref, from, _pid, _timer_ref}], remaining} ->
        GenServer.reply(from, {:error, :max_concurrency})
        {:noreply, put_waiters(state, provider, :queue.from_list(remaining))}

      {[], _remaining} ->
        {:noreply, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # The client-side call timeout exceeds the queue timeout so the server's
  # `{:error, :max_concurrency}` reply always arrives first.
  defp acquire_slot(provider, queue_timeout_ms)
       when is_integer(queue_timeout_ms) and queue_timeout_ms >= 0 do
    GenServer.call(
      __MODULE__,
      {:acquire_slot, provider, queue_timeout_ms},
      queue_timeout_ms + 5_000
    )
  catch
    :exit, {:noproc, _} -> {:ok, nil}
  end

  defp release_slot(nil), do: :ok

  defp release_slot(monitor_ref) do
    GenServer.call(__MODULE__, {:release_slot, monitor_ref})
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp handle_dispatch_result({:ok, stream_pid} = result, provider, slot_ref)
       when is_pid(stream_pid) do
    case start_stream_tracking(provider, slot_ref, stream_pid) do
      :ok ->
        result

      {:error, reason} ->
        Logger.warning(
          "CallDispatcher failed to start stream tracking for #{inspect(provider)}: #{inspect(reason)}"
        )

        release_slot(slot_ref)
        LemonAi.CircuitBreaker.record_failure(provider, {:stream_tracking_start_failed, reason})
        result
    end
  end

  defp handle_dispatch_result(result, provider, slot_ref) do
    record_result(provider, result)
    release_slot(slot_ref)
    result
  end

  defp start_stream_tracking(provider, slot_ref, stream_pid) do
    case Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
           track_stream_result(provider, slot_ref, stream_pid)
         end) do
      {:ok, tracker_pid} ->
        case LemonAi.EventStream.subscribe_result(stream_pid, tracker_pid) do
          {:ok, result_ref} ->
            send(tracker_pid, {:track_stream_result, result_ref})
            :ok

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

  defp track_stream_result(provider, slot_ref, stream_pid) do
    try do
      terminal_result = await_stream_terminal_result(stream_pid)
      record_stream_terminal_result(provider, terminal_result)
    rescue
      error ->
        Logger.warning(
          "CallDispatcher stream tracking crashed for #{inspect(provider)}: #{Exception.message(error)}"
        )

        LemonAi.CircuitBreaker.record_failure(
          provider,
          {:stream_tracking_exception, Exception.message(error)}
        )
    catch
      # A :shutdown exit of the tracked stream is a deliberate teardown — a
      # consumer cancel propagated through a link cascade (e.g. the fallback
      # wrapper's relay task being shut down), not a provider failure. Record
      # neither success nor failure.
      :exit, :shutdown ->
        :ok

      :exit, {:shutdown, _} ->
        :ok

      :exit, {{:shutdown, _}, _} ->
        :ok

      :exit, reason ->
        Logger.warning(
          "CallDispatcher stream tracking exited for #{inspect(provider)}: #{inspect(reason)}"
        )

        LemonAi.CircuitBreaker.record_failure(provider, {:stream_tracking_exit, reason})
    after
      release_slot(slot_ref)
    end
  end

  defp await_stream_terminal_result(stream_pid) do
    timeout_ms = stream_result_timeout_ms()

    receive do
      {:track_stream_result, result_ref} ->
        stream_ref = Process.monitor(stream_pid)

        receive do
          {:event_stream_result, ^result_ref, terminal_result} ->
            Process.demonitor(stream_ref, [:flush])
            terminal_result

          {:DOWN, ^stream_ref, :process, ^stream_pid, reason} ->
            {:error, {:stream_exit, reason}}
        after
          timeout_ms ->
            Process.demonitor(stream_ref, [:flush])

            Logger.warning(
              "CallDispatcher stream tracking timeout after #{timeout_ms}ms stream=#{inspect(stream_pid)}"
            )

            _ = LemonAi.EventStream.cancel(stream_pid, @default_stream_cancel_reason)
            {:error, :timeout}
        end
    end
  end

  defp stream_result_timeout_ms do
    case Application.get_env(:lemon_ai, __MODULE__, [])
         |> Keyword.get(:stream_result_timeout_ms, @default_stream_result_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_stream_result_timeout_ms
    end
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

  defp record_stream_terminal_result(provider, {:error, reason}) do
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

  defp release_slot_by_ref(state, monitor_ref, opts \\ [])
  defp release_slot_by_ref(state, nil, _opts), do: state

  defp release_slot_by_ref(state, monitor_ref, opts) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        state

      {provider, new_monitors} ->
        if Keyword.get(opts, :demonitor, false) do
          Process.demonitor(monitor_ref, [:flush])
        end

        new_active =
          Map.update(state.active_requests, provider, 0, fn count ->
            max(0, count - 1)
          end)

        grant_waiters(%{state | active_requests: new_active, monitors: new_monitors}, provider)
    end
  end

  defp grant_slot(state, provider, pid) do
    monitor_ref = Process.monitor(pid)
    new_active = Map.update(state.active_requests, provider, 1, &(&1 + 1))
    new_monitors = Map.put(state.monitors, monitor_ref, provider)

    {monitor_ref, %{state | active_requests: new_active, monitors: new_monitors}}
  end

  defp enqueue_waiter(state, provider, from, from_pid, queue_timeout_ms) do
    waiter_ref = make_ref()

    timer_ref =
      Process.send_after(self(), {:waiter_timeout, provider, waiter_ref}, queue_timeout_ms)

    :telemetry.execute(
      [:lemon_ai, :dispatcher, :queued],
      %{system_time: System.system_time()},
      %{provider: provider}
    )

    queue = Map.get(state.waiters, provider, :queue.new())
    waiter = {waiter_ref, from, from_pid, timer_ref}

    put_waiters(state, provider, :queue.in(waiter, queue))
  end

  # Grants free slots to queued waiters in arrival order. A waiter whose
  # process already died is still granted: monitoring a dead pid delivers an
  # immediate `:DOWN`, which releases the slot and grants the next waiter.
  defp grant_waiters(state, provider) do
    cap = Map.get(state.concurrency_caps, provider, @default_concurrency_cap)
    active = Map.get(state.active_requests, provider, 0)
    queue = Map.get(state.waiters, provider, :queue.new())

    with true <- active < cap,
         {{:value, {_waiter_ref, from, from_pid, timer_ref}}, remaining} <- :queue.out(queue) do
      Process.cancel_timer(timer_ref)

      {monitor_ref, new_state} =
        state
        |> put_waiters(provider, remaining)
        |> grant_slot(provider, from_pid)

      GenServer.reply(from, {:ok, monitor_ref})
      grant_waiters(new_state, provider)
    else
      _ -> state
    end
  end

  defp put_waiters(state, provider, queue) do
    new_waiters =
      if :queue.is_empty(queue) do
        Map.delete(state.waiters, provider)
      else
        Map.put(state.waiters, provider, queue)
      end

    %{state | waiters: new_waiters}
  end

  defp record_result(provider, result) do
    case result do
      {:ok, _} ->
        LemonAi.CircuitBreaker.record_success(provider)

      {:error, reason} ->
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
