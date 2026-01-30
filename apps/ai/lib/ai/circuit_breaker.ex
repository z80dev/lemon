defmodule Ai.CircuitBreaker do
  @moduledoc """
  Circuit breaker GenServer for managing per-provider failure states.

  ## Overview

  This module implements the circuit breaker pattern with three states:

  - **Closed** - Normal operation, requests pass through
  - **Open** - Too many failures, requests are rejected immediately
  - **Half-Open** - Testing if service has recovered, limited requests allowed

  ## Usage

      # Start the circuit breaker (typically via supervision tree)
      {:ok, pid} = Ai.CircuitBreaker.start_link(
        provider: :anthropic,
        failure_threshold: 5,
        recovery_timeout: 30_000
      )

      # Check if circuit is open before making request
      if Ai.CircuitBreaker.is_open?(:anthropic) do
        {:error, :circuit_open}
      else
        # make request...
        case result do
          {:ok, _} -> Ai.CircuitBreaker.record_success(:anthropic)
          {:error, _} -> Ai.CircuitBreaker.record_failure(:anthropic)
        end
      end

  ## Configuration

  - `failure_threshold` - Number of failures before opening circuit (default: 5)
  - `recovery_timeout` - Milliseconds before attempting recovery (default: 30000)
  - `provider` - Provider identifier (required)
  """

  use GenServer

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @type provider :: atom()
  @type circuit_state :: :closed | :open | :half_open
  @type state :: %{
          provider: provider(),
          circuit_state: circuit_state(),
          failure_count: non_neg_integer(),
          failure_threshold: pos_integer(),
          recovery_timeout: pos_integer(),
          last_failure_time: integer() | nil,
          success_count_in_half_open: non_neg_integer()
        }

  # Number of successes required in half_open to close the circuit
  @half_open_success_threshold 2

  @default_failure_threshold 5
  @default_recovery_timeout 30_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a circuit breaker for a provider.

  ## Options

  - `:provider` - Provider identifier (required)
  - `:failure_threshold` - Failures before opening (default: 5)
  - `:recovery_timeout` - Recovery wait time in ms (default: 30000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    provider = Keyword.fetch!(opts, :provider)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(provider))
  end

  @doc """
  Ensure a circuit breaker exists for the provider.

  Starts a breaker under `Ai.ProviderSupervisor` when available.
  """
  @spec ensure_started(provider(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(provider, opts \\ []) when is_atom(provider) do
    case GenServer.whereis(via_tuple(provider)) do
      nil ->
        opts =
          opts
          |> Keyword.put_new(:provider, provider)
          |> Keyword.put_new(:failure_threshold, default_failure_threshold())
          |> Keyword.put_new(:recovery_timeout, default_recovery_timeout())

        start_provider_child(opts)

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Check if the circuit is open (requests should be rejected).

  Returns `true` if the circuit is open, `false` if closed or half-open.
  In half-open state, limited requests are allowed through.
  """
  @spec is_open?(provider()) :: boolean()
  def is_open?(provider) do
    _ = ensure_started(provider)
    GenServer.call(via_tuple(provider), :is_open?)
  catch
    :exit, {:noproc, _} -> false
  end

  @doc """
  Record a successful request. Helps close the circuit.
  """
  @spec record_success(provider()) :: :ok
  def record_success(provider) do
    _ = ensure_started(provider)
    GenServer.cast(via_tuple(provider), :record_success)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Record a failed request. May open the circuit.
  """
  @spec record_failure(provider()) :: :ok
  def record_failure(provider) do
    _ = ensure_started(provider)
    GenServer.cast(via_tuple(provider), :record_failure)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Get current circuit state for debugging/monitoring.
  """
  @spec get_state(provider()) :: {:ok, map()} | {:error, :not_found}
  def get_state(provider) do
    _ = ensure_started(provider)
    GenServer.call(via_tuple(provider), :get_state)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Reset the circuit breaker to closed state. Useful for testing or manual recovery.
  """
  @spec reset(provider()) :: :ok
  def reset(provider) do
    _ = ensure_started(provider)
    GenServer.cast(via_tuple(provider), :reset)
  catch
    :exit, {:noproc, _} -> :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    provider = Keyword.fetch!(opts, :provider)
    failure_threshold = Keyword.get(opts, :failure_threshold, 5)
    recovery_timeout = Keyword.get(opts, :recovery_timeout, 30_000)

    state = %{
      provider: provider,
      circuit_state: :closed,
      failure_count: 0,
      failure_threshold: failure_threshold,
      recovery_timeout: recovery_timeout,
      last_failure_time: nil,
      success_count_in_half_open: 0
    }

    Logger.debug(
      "CircuitBreaker started for #{provider}: threshold #{failure_threshold}, timeout #{recovery_timeout}ms"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:is_open?, _from, state) do
    state = maybe_transition_to_half_open(state)
    is_open = state.circuit_state == :open
    {:reply, is_open, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state = maybe_transition_to_half_open(state)

    info = %{
      provider: state.provider,
      circuit_state: state.circuit_state,
      failure_count: state.failure_count,
      failure_threshold: state.failure_threshold,
      recovery_timeout: state.recovery_timeout
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_cast(:record_success, state) do
    state = maybe_transition_to_half_open(state)

    new_state =
      case state.circuit_state do
        :closed ->
          # Reset failure count on success
          %{state | failure_count: 0}

        :half_open ->
          new_count = state.success_count_in_half_open + 1

          if new_count >= @half_open_success_threshold do
            Logger.info("CircuitBreaker for #{state.provider} closed after recovery")
            %{state | circuit_state: :closed, failure_count: 0, success_count_in_half_open: 0}
          else
            %{state | success_count_in_half_open: new_count}
          end

        :open ->
          # Shouldn't happen, but ignore
          state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:record_failure, state) do
    state = maybe_transition_to_half_open(state)

    new_state =
      case state.circuit_state do
        :closed ->
          new_count = state.failure_count + 1

          if new_count >= state.failure_threshold do
            Logger.warning("CircuitBreaker for #{state.provider} opened after #{new_count} failures")

            %{
              state
              | circuit_state: :open,
                failure_count: new_count,
                last_failure_time: System.monotonic_time(:millisecond)
            }
          else
            %{state | failure_count: new_count}
          end

        :half_open ->
          # Any failure in half-open reopens the circuit
          Logger.warning("CircuitBreaker for #{state.provider} reopened (failure in half-open)")

          %{
            state
            | circuit_state: :open,
              last_failure_time: System.monotonic_time(:millisecond),
              success_count_in_half_open: 0
          }

        :open ->
          # Update failure time to extend recovery timeout
          %{state | last_failure_time: System.monotonic_time(:millisecond)}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:reset, state) do
    Logger.info("CircuitBreaker for #{state.provider} manually reset")

    new_state = %{
      state
      | circuit_state: :closed,
        failure_count: 0,
        last_failure_time: nil,
        success_count_in_half_open: 0
    }

    {:noreply, new_state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_transition_to_half_open(%{circuit_state: :open} = state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - (state.last_failure_time || now)

    if elapsed >= state.recovery_timeout do
      Logger.info("CircuitBreaker for #{state.provider} entering half-open state")
      %{state | circuit_state: :half_open, success_count_in_half_open: 0}
    else
      state
    end
  end

  defp maybe_transition_to_half_open(state), do: state

  defp via_tuple(provider) do
    {:via, Registry, {Ai.CircuitBreakerRegistry, provider}}
  end

  defp start_provider_child(opts) do
    if Process.whereis(Ai.ProviderSupervisor) do
      provider = Keyword.fetch!(opts, :provider)

      child_spec = %{
        id: {__MODULE__, provider},
        start: {__MODULE__, :start_link, [opts]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }

      case DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, {:already_present, _}} ->
          case GenServer.whereis(via_tuple(provider)) do
            nil -> {:error, :already_present}
            pid -> {:ok, pid}
          end
        other -> other
      end
    else
      case start_link(opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    end
  end

  defp default_failure_threshold do
    Application.get_env(:ai, :circuit_breaker, [])
    |> Keyword.get(:failure_threshold, @default_failure_threshold)
  end

  defp default_recovery_timeout do
    Application.get_env(:ai, :circuit_breaker, [])
    |> Keyword.get(:recovery_timeout, @default_recovery_timeout)
  end
end
