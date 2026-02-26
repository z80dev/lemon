defmodule Ai.CallDispatcher do
  @moduledoc """
  Central dispatcher for routing AI provider requests through rate limiting
  and circuit breaking infrastructure.

  ## Overview

  This module acts as a coordination point that:

  1. Checks the circuit breaker state
  2. Acquires a rate limit permit
  3. Enforces per-provider concurrency limits
  4. Returns appropriate errors when conditions aren't met

  ## Usage

      # Dispatch a request (typically wrapping an actual provider call)
      case Ai.CallDispatcher.dispatch(:anthropic, fn -> make_api_call() end) do
        {:ok, result} -> handle_result(result)
        {:error, :rate_limited} -> retry_later()
        {:error, :circuit_open} -> use_fallback()
        {:error, :max_concurrency} -> queue_request()
        {:error, reason} -> handle_error(reason)
      end

  ## Configuration

  Concurrency caps are configured per-provider via `set_concurrency_cap/2`.
  Default cap is 10 concurrent requests per provider.
  """

  use GenServer

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @type provider :: atom()
  @type state :: %{
          concurrency_caps: %{provider() => pos_integer()},
          active_requests: %{provider() => non_neg_integer()},
          monitors: %{reference() => provider()}
        }

  @default_concurrency_cap 10
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
  rate limiting, circuit breaker, or concurrency limits.

  ## Examples

      Ai.CallDispatcher.dispatch(:anthropic, fn ->
        Ai.Providers.Anthropic.call(params)
      end)
  """
  @spec dispatch(provider(), (-> result)) :: result | {:error, atom()} when result: any()
  def dispatch(provider, callback) when is_atom(provider) and is_function(callback, 0) do
    start_time = System.monotonic_time()

    LemonCore.Telemetry.emit(
      [:ai, :dispatcher, :dispatch],
      %{system_time: System.system_time()},
      %{provider: provider}
    )

    # Ensure per-provider services are available
    _ = Ai.RateLimiter.ensure_started(provider)
    _ = Ai.CircuitBreaker.ensure_started(provider)

    # Check circuit breaker first (fast fail)
    if Ai.CircuitBreaker.is_open?(provider) do
      duration = System.monotonic_time() - start_time

      LemonCore.Telemetry.emit(
        [:ai, :dispatcher, :rejected],
        %{duration: duration, system_time: System.system_time()},
        %{provider: provider, reason: :circuit_open}
      )

      {:error, :circuit_open}
    else
      # Try to acquire concurrency slot and rate limit permit
      case acquire_slot(provider) do
        {:ok, slot_ref} ->
          case Ai.RateLimiter.acquire(provider) do
            :ok ->
              try do
                callback.()
                |> handle_dispatch_result(provider, slot_ref)
              rescue
                error ->
                  release_slot(slot_ref)
                  Ai.CircuitBreaker.record_failure(provider)
                  reraise error, __STACKTRACE__
              after
                Ai.RateLimiter.release(provider)
              end

            {:error, :rate_limited} = error ->
              duration = System.monotonic_time() - start_time

              LemonCore.Telemetry.emit(
                [:ai, :dispatcher, :rejected],
                %{duration: duration, system_time: System.system_time()},
                %{provider: provider, reason: :rate_limited}
              )

              release_slot(slot_ref)
              error
          end

        {:error, :max_concurrency} = error ->
          duration = System.monotonic_time() - start_time

          LemonCore.Telemetry.emit(
            [:ai, :dispatcher, :rejected],
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
  def set_concurrency_cap(provider, cap) when is_atom(provider) and is_integer(cap) and cap > 0 do
    GenServer.call(__MODULE__, {:set_concurrency_cap, provider, cap})
  end

  @doc """
  Get the current concurrency cap for a provider.
  """
  @spec get_concurrency_cap(provider()) :: pos_integer()
  def get_concurrency_cap(provider) when is_atom(provider) do
    GenServer.call(__MODULE__, {:get_concurrency_cap, provider})
  end

  @doc """
  Get the number of active requests for a provider.
  """
  @spec get_active_requests(provider()) :: non_neg_integer()
  def get_active_requests(provider) when is_atom(provider) do
    GenServer.call(__MODULE__, {:get_active_requests, provider})
  end

  @doc """
  Get dispatcher state for debugging/monitoring.
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
      monitors: %{}
    }

    Logger.debug("CallDispatcher started")

    {:ok, state}
  end

  def handle_call({:acquire_slot, provider}, {from_pid, _tag}, state) do
    cap = Map.get(state.concurrency_caps, provider, @default_concurrency_cap)
    active = Map.get(state.active_requests, provider, 0)

    if active < cap do
      monitor_ref = Process.monitor(from_pid)

      new_active = Map.update(state.active_requests, provider, 1, &(&1 + 1))
      new_monitors = Map.put(state.monitors, monitor_ref, provider)

      {:reply, {:ok, monitor_ref}, %{state | active_requests: new_active, monitors: new_monitors}}
    else
      {:reply, {:error, :max_concurrency}, state}
    end
  end

  @impl true
  def handle_call({:release_slot, monitor_ref}, _from, state) do
    {:reply, :ok, release_slot_by_ref(state, monitor_ref, demonitor: true)}
  end

  @impl true
  def handle_call({:set_concurrency_cap, provider, cap}, _from, state) do
    new_caps = Map.put(state.concurrency_caps, provider, cap)
    {:reply, :ok, %{state | concurrency_caps: new_caps}}
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
      default_cap: @default_concurrency_cap
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, release_slot_by_ref(state, monitor_ref)}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp acquire_slot(provider) do
    GenServer.call(__MODULE__, {:acquire_slot, provider})
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
        Ai.CircuitBreaker.record_failure(provider)
        result
    end
  end

  defp handle_dispatch_result(result, provider, slot_ref) do
    record_result(provider, result)
    release_slot(slot_ref)
    result
  end

  defp start_stream_tracking(provider, slot_ref, stream_pid) do
    case Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
           track_stream_result(provider, slot_ref, stream_pid)
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
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

        Ai.CircuitBreaker.record_failure(provider)
    catch
      :exit, reason ->
        Logger.warning(
          "CallDispatcher stream tracking exited for #{inspect(provider)}: #{inspect(reason)}"
        )

        Ai.CircuitBreaker.record_failure(provider)
    after
      release_slot(slot_ref)
    end
  end

  defp await_stream_terminal_result(stream_pid) do
    timeout_ms = stream_result_timeout_ms()

    case Ai.EventStream.result(stream_pid, timeout_ms) do
      {:error, :timeout} = timeout_error ->
        Logger.warning(
          "CallDispatcher stream tracking timeout after #{timeout_ms}ms stream=#{inspect(stream_pid)}"
        )

        _ = Ai.EventStream.cancel(stream_pid, @default_stream_cancel_reason)
        timeout_error

      other ->
        other
    end
  end

  defp stream_result_timeout_ms do
    case Application.get_env(:ai, __MODULE__, [])
         |> Keyword.get(:stream_result_timeout_ms, @default_stream_result_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_stream_result_timeout_ms
    end
  end

  defp record_stream_terminal_result(provider, {:ok, _message}) do
    Ai.CircuitBreaker.record_success(provider)
  end

  defp record_stream_terminal_result(provider, {:error, _reason}) do
    Ai.CircuitBreaker.record_failure(provider)
  end

  defp record_stream_terminal_result(provider, _unexpected_result) do
    Ai.CircuitBreaker.record_failure(provider)
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

        %{state | active_requests: new_active, monitors: new_monitors}
    end
  end

  defp record_result(provider, result) do
    case result do
      {:ok, _} -> Ai.CircuitBreaker.record_success(provider)
      {:error, _} -> Ai.CircuitBreaker.record_failure(provider)
      # For non-tuple results, assume success
      _ -> Ai.CircuitBreaker.record_success(provider)
    end
  end
end
