defmodule Ai.RateLimiter do
  @moduledoc """
  Token bucket rate limiter GenServer for managing per-provider request rates.

  ## Overview

  This module implements a token bucket algorithm where tokens are added at a
  configurable rate up to a maximum capacity. Each request consumes one token,
  and requests are rejected when no tokens are available.

  ## Usage

      # Start the rate limiter (typically via supervision tree)
      {:ok, pid} = Ai.RateLimiter.start_link(
        provider: :anthropic,
        tokens_per_second: 10,
        max_tokens: 20
      )

      # Check if a request is allowed
      case Ai.RateLimiter.acquire(:anthropic) do
        :ok -> # proceed with request
        {:error, :rate_limited} -> # back off
      end

      # Return a permit after request completes (optional, for concurrency tracking)
      Ai.RateLimiter.release(:anthropic)

  ## Configuration

  - `tokens_per_second` - Rate at which tokens are replenished (default: 10)
  - `max_tokens` - Maximum bucket capacity (default: 20)
  - `provider` - Provider identifier (required)
  """

  use GenServer

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @type provider :: atom()
  @type state :: %{
          provider: provider(),
          tokens: float(),
          max_tokens: pos_integer(),
          tokens_per_second: pos_integer(),
          last_refill: integer()
        }

  @default_tokens_per_second 10
  @default_max_tokens 20

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a rate limiter for a provider.

  ## Options

  - `:provider` - Provider identifier (required)
  - `:tokens_per_second` - Token refill rate (default: 10)
  - `:max_tokens` - Maximum bucket capacity (default: 20)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    provider = Keyword.fetch!(opts, :provider)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(provider))
  end

  @doc """
  Ensure a rate limiter exists for the provider.

  Starts a limiter under `Ai.ProviderSupervisor` when available.
  """
  @spec ensure_started(provider(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(provider, opts \\ []) when is_atom(provider) do
    case GenServer.whereis(via_tuple(provider)) do
      nil ->
        opts =
          opts
          |> Keyword.put_new(:provider, provider)
          |> Keyword.put_new(:tokens_per_second, default_tokens_per_second())
          |> Keyword.put_new(:max_tokens, default_max_tokens())

        start_provider_child(opts)

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Attempt to acquire a permit for the given provider.

  Returns `:ok` if a token was available, or `{:error, :rate_limited}` if the
  bucket is empty.
  """
  @spec acquire(provider()) :: :ok | {:error, :rate_limited}
  def acquire(provider) do
    _ = ensure_started(provider)
    GenServer.call(via_tuple(provider), :acquire)
  catch
    :exit, {:noproc, _} -> {:error, :rate_limited}
  end

  @doc """
  Release a permit back to the limiter.

  This is a no-op for token bucket rate limiting (tokens auto-refill),
  but can be used for tracking active requests.
  """
  @spec release(provider()) :: :ok
  def release(provider) do
    _ = ensure_started(provider)
    GenServer.cast(via_tuple(provider), :release)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Get current state for debugging/monitoring.
  """
  @spec get_state(provider()) :: {:ok, map()} | {:error, :not_found}
  def get_state(provider) do
    _ = ensure_started(provider)
    GenServer.call(via_tuple(provider), :get_state)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    provider = Keyword.fetch!(opts, :provider)
    tokens_per_second = Keyword.get(opts, :tokens_per_second, 10)
    max_tokens = Keyword.get(opts, :max_tokens, 20)

    state = %{
      provider: provider,
      tokens: max_tokens * 1.0,
      max_tokens: max_tokens,
      tokens_per_second: tokens_per_second,
      last_refill: System.monotonic_time(:millisecond)
    }

    Logger.debug("RateLimiter started for #{provider}: #{tokens_per_second}/s, max #{max_tokens}")

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    state = refill_tokens(state)

    if state.tokens >= 1.0 do
      {:reply, :ok, %{state | tokens: state.tokens - 1.0}}
    else
      {:reply, {:error, :rate_limited}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state = refill_tokens(state)

    info = %{
      provider: state.provider,
      available_tokens: trunc(state.tokens),
      max_tokens: state.max_tokens,
      tokens_per_second: state.tokens_per_second
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_cast(:release, state) do
    # Token bucket doesn't need explicit release - tokens auto-refill
    # This callback exists for API consistency
    {:noreply, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp refill_tokens(state) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - state.last_refill
    tokens_to_add = elapsed_ms / 1000.0 * state.tokens_per_second
    new_tokens = min(state.tokens + tokens_to_add, state.max_tokens * 1.0)

    %{state | tokens: new_tokens, last_refill: now}
  end

  defp via_tuple(provider) do
    {:via, Registry, {Ai.RateLimiterRegistry, provider}}
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
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, {:already_present, _}} ->
          case GenServer.whereis(via_tuple(provider)) do
            nil -> {:error, :already_present}
            pid -> {:ok, pid}
          end

        other ->
          other
      end
    else
      case start_link(opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    end
  end

  defp default_tokens_per_second do
    Application.get_env(:ai, :rate_limiter, [])
    |> Keyword.get(:tokens_per_second, @default_tokens_per_second)
  end

  defp default_max_tokens do
    Application.get_env(:ai, :rate_limiter, [])
    |> Keyword.get(:max_tokens, @default_max_tokens)
  end
end
