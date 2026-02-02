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
          monitors: %{reference() => provider()},
          owners: %{{pid(), provider()} => [reference()]}
        }

  @default_concurrency_cap 10

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

    :telemetry.execute(
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

      :telemetry.execute(
        [:ai, :dispatcher, :rejected],
        %{duration: duration, system_time: System.system_time()},
        %{provider: provider, reason: :circuit_open}
      )

      {:error, :circuit_open}
    else
      # Try to acquire concurrency slot and rate limit permit
      case acquire_slot(provider) do
        :ok ->
          case Ai.RateLimiter.acquire(provider) do
            :ok ->
              try do
                result = callback.()
                record_result(provider, result)
                result
              rescue
                error ->
                  Ai.CircuitBreaker.record_failure(provider)
                  reraise error, __STACKTRACE__
              after
                release_slot(provider)
                Ai.RateLimiter.release(provider)
              end

            {:error, :rate_limited} = error ->
              duration = System.monotonic_time() - start_time

              :telemetry.execute(
                [:ai, :dispatcher, :rejected],
                %{duration: duration, system_time: System.system_time()},
                %{provider: provider, reason: :rate_limited}
              )

              release_slot(provider)
              error
          end

        {:error, :max_concurrency} = error ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
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
      monitors: %{},
      owners: %{}
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

      new_owners =
        Map.update(state.owners, {from_pid, provider}, [monitor_ref], fn refs ->
          [monitor_ref | refs]
        end)

      {:reply, :ok,
       %{state | active_requests: new_active, monitors: new_monitors, owners: new_owners}}
    else
      {:reply, {:error, :max_concurrency}, state}
    end
  end

  @impl true
  def handle_call({:release_slot, provider}, {from_pid, _tag}, state) do
    key = {from_pid, provider}

    case Map.get(state.owners, key, []) do
      [monitor_ref | rest] ->
        Process.demonitor(monitor_ref, [:flush])

        new_active =
          Map.update(state.active_requests, provider, 0, fn count ->
            max(0, count - 1)
          end)

        new_monitors = Map.delete(state.monitors, monitor_ref)

        new_owners =
          case rest do
            [] -> Map.delete(state.owners, key)
            _ -> Map.put(state.owners, key, rest)
          end

        {:reply, :ok,
         %{state | active_requests: new_active, monitors: new_monitors, owners: new_owners}}

      [] ->
        {:reply, :ok, state}
    end
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
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {provider, new_monitors} ->
        new_active =
          Map.update(state.active_requests, provider, 0, fn count ->
            max(0, count - 1)
          end)

        new_owners =
          Enum.reduce(state.owners, %{}, fn {key, refs}, acc ->
            case List.delete(refs, monitor_ref) do
              [] -> acc
              updated_refs -> Map.put(acc, key, updated_refs)
            end
          end)

        {:noreply,
         %{state | active_requests: new_active, monitors: new_monitors, owners: new_owners}}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp acquire_slot(provider) do
    GenServer.call(__MODULE__, {:acquire_slot, provider})
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp release_slot(provider) do
    GenServer.call(__MODULE__, {:release_slot, provider})
  catch
    :exit, {:noproc, _} -> :ok
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
