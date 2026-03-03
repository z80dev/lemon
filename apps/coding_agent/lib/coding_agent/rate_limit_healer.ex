defmodule CodingAgent.RateLimitHealer do
  @moduledoc """
  Session self-healing state machine for recovering from rate-limit wedges.

  When a session hits rate limits, the session-local limiter enters a backoff state.
  Even after global quota resets, the session can remain wedged. This module
  implements a probe-based healing mechanism to detect when limits clear and
  automatically recover the session.

  ## State Machine

  ```
  :idle -> :probing -> :recovered
                   -> :failed -> :forking -> :forked
  ```

  ## Usage

      # Start healing for a session
      {:ok, healer} = RateLimitHealer.start_link(
        session_id: "session-123",
        provider: :anthropic,
        model: model_struct,
        on_healed: fn -> notify_session_healed() end,
        on_failed: fn -> trigger_session_fork() end
      )

      # Check healing status
      status = RateLimitHealer.status(healer)

      # Stop healing
      :ok = RateLimitHealer.stop(healer)
  """

  use GenServer
  require Logger

  alias Ai.Error

  # ============================================================================
  # Configuration
  # ============================================================================

  # Probe configuration
  @default_probe_interval_ms 30_000
  @default_max_probe_attempts 10
  @default_probe_timeout_ms 10_000
  @default_jitter_max_ms 5_000

  # Exponential backoff: base * 2^attempt + jitter
  @backoff_base_ms 1_000
  @backoff_max_ms 300_000

  # ============================================================================
  # Types
  # ============================================================================

  @type healing_state :: :idle | :probing | :recovered | :failed | :forking | :forked

  @type probe_result :: :rate_limited | :recovered | :error

  @type t :: %__MODULE__{
          session_id: String.t(),
          provider: atom(),
          model: Ai.Types.Model.t(),
          state: healing_state(),
          probe_count: non_neg_integer(),
          max_probe_attempts: pos_integer(),
          probe_interval_ms: pos_integer(),
          probe_timeout_ms: pos_integer(),
          next_probe_at: DateTime.t() | nil,
          probe_timer_ref: reference() | nil,
          on_healed: (() -> :ok) | nil,
          on_failed: (() -> :ok) | nil,
          fallback_strategy: :reset_backoff | :fallback_model | :fallback_provider | :fork,
          fallback_model: Ai.Types.Model.t() | nil,
          last_error: term() | nil,
          started_at: DateTime.t(),
          healed_at: DateTime.t() | nil,
          metadata: map()
        }

  defstruct [
    :session_id,
    :provider,
    :model,
    :state,
    :probe_count,
    :max_probe_attempts,
    :probe_interval_ms,
    :probe_timeout_ms,
    :next_probe_at,
    :probe_timer_ref,
    :on_healed,
    :on_failed,
    :fallback_strategy,
    :fallback_model,
    :last_error,
    :started_at,
    :healed_at,
    :metadata
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a rate limit healer for a session.

  ## Options

    * `:session_id` - The session identifier (required)
    * `:provider` - The AI provider atom (required)
    * `:model` - The current model struct (required)
    * `:on_healed` - Callback function when healing succeeds
    * `:on_failed` - Callback function when healing fails
    * `:max_probe_attempts` - Maximum probe attempts before giving up (default: 10)
    * `:probe_interval_ms` - Base interval between probes (default: 30s)
    * `:probe_timeout_ms` - Timeout for each probe request (default: 10s)
    * `:fallback_strategy` - Strategy when probing fails (default: :reset_backoff)
    * `:fallback_model` - Alternative model to use if :fallback_model strategy
    * `:metadata` - Additional context for telemetry

  ## Examples

      {:ok, healer} = RateLimitHealer.start_link(
        session_id: "sess-123",
        provider: :anthropic,
        model: current_model,
        on_healed: &notify_healed/0
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    name = Keyword.get(opts, :name, via_tuple(session_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current healing status.

  Returns a map with the current state, probe count, and timing information.
  """
  @spec status(GenServer.server()) :: %{
          state: healing_state(),
          probe_count: non_neg_integer(),
          max_attempts: pos_integer(),
          next_probe_in_ms: integer() | nil,
          started_at: DateTime.t(),
          healed_at: DateTime.t() | nil
        }
  def status(healer) do
    GenServer.call(healer, :status)
  end

  @doc """
  Manually trigger a probe request.

  Normally probes happen automatically on a schedule, but this allows
  forcing an immediate probe check.
  """
  @spec probe(GenServer.server()) :: {:ok, probe_result()} | {:error, term()}
  def probe(healer) do
    GenServer.call(healer, :probe, @default_probe_timeout_ms + 5_000)
  end

  @doc """
  Stop the healer and clean up resources.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(healer) do
    GenServer.stop(healer, :normal)
  end

  @doc """
  Mark the session as successfully healed from outside.

  This is useful when the caller detects recovery through other means.
  """
  @spec mark_healed(GenServer.server()) :: :ok
  def mark_healed(healer) do
    GenServer.call(healer, :mark_healed)
  end

  @doc """
  Mark healing as failed from outside.

  This triggers the fallback strategy or on_failed callback.
  """
  @spec mark_failed(GenServer.server(), term()) :: :ok
  def mark_failed(healer, reason) do
    GenServer.call(healer, {:mark_failed, reason})
  end

  @doc """
  Get the via tuple for registry lookup.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_tuple(session_id) do
    {:via, Registry, {CodingAgent.RateLimitHealerRegistry, session_id}}
  end

  @doc """
  Check if a healer exists for a session.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(session_id) do
    case Registry.lookup(CodingAgent.RateLimitHealerRegistry, session_id) do
      [] -> false
      [_ | _] -> true
    end
  end

  @doc """
  Lookup a healer pid for a session.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id) do
    case Registry.lookup(CodingAgent.RateLimitHealerRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    state = %__MODULE__{
      session_id: session_id,
      provider: provider,
      model: model,
      state: :idle,
      probe_count: 0,
      max_probe_attempts: Keyword.get(opts, :max_probe_attempts, @default_max_probe_attempts),
      probe_interval_ms: Keyword.get(opts, :probe_interval_ms, @default_probe_interval_ms),
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, @default_probe_timeout_ms),
      next_probe_at: nil,
      probe_timer_ref: nil,
      on_healed: Keyword.get(opts, :on_healed),
      on_failed: Keyword.get(opts, :on_failed),
      fallback_strategy: Keyword.get(opts, :fallback_strategy, :reset_backoff),
      fallback_model: Keyword.get(opts, :fallback_model),
      last_error: nil,
      started_at: DateTime.utc_now(),
      healed_at: nil,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    Logger.info("RateLimitHealer started for session #{session_id} on #{provider}")

    # Start probing immediately
    {:ok, schedule_probe(%{state | state: :probing})}
  end

  @impl true
  def handle_call(:status, _from, state) do
    next_probe_in_ms =
      if state.next_probe_at do
        DateTime.diff(state.next_probe_at, DateTime.utc_now(), :millisecond)
      else
        nil
      end

    reply = %{
      state: state.state,
      probe_count: state.probe_count,
      max_attempts: state.max_probe_attempts,
      next_probe_in_ms: max(next_probe_in_ms || 0, 0),
      started_at: state.started_at,
      healed_at: state.healed_at
    }

    {:reply, reply, state}
  end

  def handle_call(:probe, _from, state) do
    {result, new_state} = execute_probe(state)
    {:reply, {:ok, result}, new_state}
  end

  def handle_call(:mark_healed, _from, state) do
    new_state = transition_to_healed(state)
    {:reply, :ok, new_state}
  end

  def handle_call({:mark_failed, reason}, _from, state) do
    new_state = transition_to_failed(state, reason)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:probe, %{state: :probing} = state) do
    {result, new_state} = execute_probe(state)

    case result do
      :recovered ->
        {:noreply, transition_to_healed(new_state)}

      :rate_limited ->
        if new_state.probe_count >= new_state.max_probe_attempts do
          {:noreply, transition_to_failed(new_state, :max_probe_attempts_reached)}
        else
          {:noreply, schedule_probe(new_state)}
        end

      :error ->
        if new_state.probe_count >= new_state.max_probe_attempts do
          {:noreply, transition_to_failed(new_state, :probe_error)}
        else
          {:noreply, schedule_probe(new_state)}
        end
    end
  end

  def handle_info(:probe, state) do
    # Ignore probe messages when not in :probing state
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up timer if present
    if state.probe_timer_ref do
      Process.cancel_timer(state.probe_timer_ref)
    end

    Logger.info("RateLimitHealer stopped for session #{state.session_id} in state #{state.state}")
    emit_telemetry(:stopped, state, %{final_state: state.state})
    :ok
  end

  # ============================================================================
  # Probe Logic
  # ============================================================================

  @doc """
  Execute a single probe request to check if rate limits have cleared.

  This sends a minimal request to the provider to test connectivity
  without consuming significant quota.
  """
  @spec execute_probe(t()) :: {probe_result(), t()}
  def execute_probe(state) do
    probe_count = state.probe_count + 1

    emit_telemetry(:probe_attempt, state, %{
      probe_count: probe_count,
      max_attempts: state.max_probe_attempts
    })

    Logger.debug("RateLimitHealer probe #{probe_count}/#{state.max_probe_attempts} for #{state.session_id}")

    case do_probe_request(state) do
      :ok ->
        emit_telemetry(:probe_success, state, %{probe_count: probe_count})
        {:recovered, %{state | probe_count: probe_count, last_error: nil}}

      {:error, :rate_limited} ->
        emit_telemetry(:probe_rate_limited, state, %{probe_count: probe_count})
        {:rate_limited, %{state | probe_count: probe_count}}

      {:error, reason} ->
        emit_telemetry(:probe_error, state, %{
          probe_count: probe_count,
          error: inspect(reason)
        })

        {:error, %{state | probe_count: probe_count, last_error: reason}}
    end
  end

  @doc """
  Perform the actual probe request.

  This attempts a minimal operation to test if rate limits have cleared.
  By default, it tries to acquire a token from the rate limiter.
  """
  @spec do_probe_request(t()) :: :ok | {:error, term()}
  def do_probe_request(state) do
    # Try to acquire a permit from the rate limiter
    case Ai.RateLimiter.acquire(state.provider) do
      :ok ->
        # Also verify with a lightweight provider check if available
        verify_provider_connectivity(state)

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  @doc """
  Verify provider connectivity with a minimal check.

  This can be overridden per provider to do a more thorough check.
  """
  @spec verify_provider_connectivity(t()) :: :ok | {:error, term()}
  def verify_provider_connectivity(state) do
    # Default implementation: just check rate limiter
    # Providers can implement more sophisticated checks
    :ok
  end

  # ============================================================================
  # State Transitions
  # ============================================================================

  defp transition_to_healed(state) do
    if state.state == :recovered do
      state
    else
      healed_at = DateTime.utc_now()
      new_state = %{state | state: :recovered, healed_at: healed_at}

      emit_telemetry(:healed, new_state, %{
        probe_count: state.probe_count,
        duration_ms: DateTime.diff(healed_at, state.started_at, :millisecond)
      })

      Logger.info("RateLimitHealer: Session #{state.session_id} healed after #{state.probe_count} probes")

      # Execute callback if provided
      if state.on_healed do
        safe_execute_callback(state.on_healed, "on_healed")
      end

      new_state
    end
  end

  defp transition_to_failed(state, reason) do
    if state.state in [:failed, :forking, :forked] do
      state
    else
      new_state = %{state | state: :failed, last_error: reason}

      emit_telemetry(:failed, new_state, %{
        probe_count: state.probe_count,
        reason: inspect(reason),
        fallback_strategy: state.fallback_strategy
      })

      Logger.warning("RateLimitHealer: Session #{state.session_id} healing failed: #{inspect(reason)}")

      # Execute callback if provided
      if state.on_failed do
        safe_execute_callback(state.on_failed, "on_failed")
      end

      # Trigger fallback strategy
      trigger_fallback_strategy(new_state)
    end
  end

  defp trigger_fallback_strategy(state) do
    case state.fallback_strategy do
      :reset_backoff ->
        # Reset the rate limiter backoff for this provider
        Logger.info("RateLimitHealer: Resetting backoff for #{state.provider}")
        # The caller is responsible for actually resetting the backoff
        # State stays :failed until caller confirms recovery
        state

      :fallback_model ->
        Logger.info("RateLimitHealer: Switching to fallback model")
        %{state | state: :forking}

      :fallback_provider ->
        Logger.info("RateLimitHealer: Switching to fallback provider")
        %{state | state: :forking}

      :fork ->
        Logger.info("RateLimitHealer: Triggering session fork")
        %{state | state: :forking}

      _other ->
        state
    end
  end

  # ============================================================================
  # Scheduling
  # ============================================================================

  @doc """
  Schedule the next probe with exponential backoff and jitter.
  """
  @spec schedule_probe(t()) :: t()
  def schedule_probe(state) do
    # Calculate delay with exponential backoff
    delay_ms = calculate_backoff_delay(state.probe_count)

    # Add jitter to avoid thundering herd
    jitter_ms = :rand.uniform(@default_jitter_max_ms)
    total_delay_ms = min(delay_ms + jitter_ms, @backoff_max_ms)

    next_probe_at = DateTime.add(DateTime.utc_now(), total_delay_ms, :millisecond)

    timer_ref = Process.send_after(self(), :probe, total_delay_ms)

    %{
      state
      | next_probe_at: next_probe_at,
        probe_timer_ref: timer_ref
    }
  end

  @doc """
  Calculate the backoff delay for a given probe attempt.

  Uses exponential backoff: base * 2^attempt, capped at max.
  """
  @spec calculate_backoff_delay(non_neg_integer()) :: pos_integer()
  def calculate_backoff_delay(attempt) when attempt >= 0 do
    delay = @backoff_base_ms * :math.pow(2, attempt)
    min(round(delay), @backoff_max_ms)
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  @doc """
  Emit telemetry events for healing lifecycle.

  Events:
    * `[:coding_agent, :rate_limit_healer, :probe_attempt]` - A probe was attempted
    * `[:coding_agent, :rate_limit_healer, :probe_success]` - Probe detected recovery
    * `[:coding_agent, :rate_limit_healer, :probe_rate_limited]` - Probe hit rate limit
    * `[:coding_agent, :rate_limit_healer, :probe_error]` - Probe encountered error
    * `[:coding_agent, :rate_limit_healer, :healed]` - Session was healed
    * `[:coding_agent, :rate_limit_healer, :failed]` - Healing failed
    * `[:coding_agent, :rate_limit_healer, :stopped]` - Healer stopped
  """
  @spec emit_telemetry(
          :probe_attempt | :probe_success | :probe_rate_limited | :probe_error | :healed
          | :failed | :stopped,
          t(),
          map()
        ) :: :ok
  def emit_telemetry(event, state, measurements) do
    metadata = %{
      session_id: state.session_id,
      provider: state.provider,
      model: state.model.id,
      healing_state: state.state,
      probe_count: state.probe_count
    }

    :telemetry.execute([:coding_agent, :rate_limit_healer, event], measurements, metadata)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp safe_execute_callback(callback, name) when is_function(callback, 0) do
    try do
      callback.()
    rescue
      e ->
        Logger.warning("RateLimitHealer: #{name} callback raised: #{inspect(e)}")
        :ok
    catch
      kind, reason ->
        Logger.warning("RateLimitHealer: #{name} callback #{kind}: #{inspect(reason)}")
        :ok
    end
  end

  defp safe_execute_callback(_callback, name) do
    Logger.warning("RateLimitHealer: Invalid #{name} callback (expected 0-arity function)")
    :ok
  end
end
