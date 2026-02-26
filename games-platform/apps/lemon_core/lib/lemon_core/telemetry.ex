defmodule LemonCore.Telemetry do
  @moduledoc """
  Telemetry event helpers for Lemon.

  Provides consistent telemetry emission across the umbrella.

  ## Event Names

  ### Runs
  - `[:lemon, :run, :submit]` - measurements: `%{count: 1}` meta: `%{session_key, origin, engine}`
  - `[:lemon, :run, :start]` - measurements: `%{ts_ms: ...}`
  - `[:lemon, :run, :first_token]` - measurements: `%{latency_ms: ...}`
  - `[:lemon, :run, :stop]` - measurements: `%{duration_ms: ..., ok: boolean()}`
  - `[:lemon, :run, :exception]` - meta includes exception+stack

  ### Channels
  - `[:lemon, :channels, :deliver, :start]`
  - `[:lemon, :channels, :deliver, :stop]`
  - `[:lemon, :channels, :deliver, :exception]`
  - `[:lemon, :channels, :inbound]`

  ### Approvals
  - `[:lemon, :approvals, :requested]`
  - `[:lemon, :approvals, :resolved]`

  ### Cron
  - `[:lemon, :cron, :tick]`
  - `[:lemon, :cron, :run, :start]`
  - `[:lemon, :cron, :run, :stop]`
  """

  @doc """
  Execute a function and emit start/stop/exception telemetry.
  """
  @spec span(event_prefix :: [atom()], metadata :: map(), fun :: (-> result)) :: result when result: term()
  def span(event_prefix, metadata, fun) do
    :telemetry.span(event_prefix, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  @doc """
  Emit a telemetry event.
  """
  @spec emit(event :: [atom()], measurements :: map(), metadata :: map()) :: :ok
  def emit(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end

  # Run events

  @doc """
  Emit run submit event.
  """
  @spec run_submit(session_key :: binary(), origin :: atom(), engine :: binary()) :: :ok
  def run_submit(session_key, origin, engine) do
    emit([:lemon, :run, :submit], %{count: 1}, %{
      session_key: session_key,
      origin: origin,
      engine: engine
    })
  end

  @doc """
  Emit run start event.
  """
  @spec run_start(run_id :: binary(), metadata :: map()) :: :ok
  def run_start(run_id, metadata \\ %{}) do
    emit([:lemon, :run, :start], %{ts_ms: LemonCore.Clock.now_ms()}, Map.put(metadata, :run_id, run_id))
  end

  @doc """
  Emit run first token event.
  """
  @spec run_first_token(run_id :: binary(), start_ts_ms :: non_neg_integer()) :: :ok
  def run_first_token(run_id, start_ts_ms) do
    latency_ms = LemonCore.Clock.now_ms() - start_ts_ms
    emit([:lemon, :run, :first_token], %{latency_ms: latency_ms}, %{run_id: run_id})
  end

  @doc """
  Emit run stop event.
  """
  @spec run_stop(run_id :: binary(), duration_ms :: non_neg_integer(), ok :: boolean()) :: :ok
  def run_stop(run_id, duration_ms, ok) do
    emit([:lemon, :run, :stop], %{duration_ms: duration_ms, ok: ok}, %{run_id: run_id})
  end

  @doc """
  Emit run exception event.
  """
  @spec run_exception(run_id :: binary(), exception :: term(), stacktrace :: list()) :: :ok
  def run_exception(run_id, exception, stacktrace) do
    emit([:lemon, :run, :exception], %{}, %{
      run_id: run_id,
      exception: exception,
      stacktrace: stacktrace
    })
  end

  # Channel events

  @doc """
  Emit channel inbound event.
  """
  @spec channel_inbound(channel_id :: binary(), metadata :: map()) :: :ok
  def channel_inbound(channel_id, metadata \\ %{}) do
    emit([:lemon, :channels, :inbound], %{count: 1}, Map.put(metadata, :channel_id, channel_id))
  end

  # Approval events

  @doc """
  Emit approval requested event.
  """
  @spec approval_requested(approval_id :: binary(), tool :: binary(), metadata :: map()) :: :ok
  def approval_requested(approval_id, tool, metadata \\ %{}) do
    emit([:lemon, :approvals, :requested], %{count: 1}, Map.merge(metadata, %{
      approval_id: approval_id,
      tool: tool
    }))
  end

  @doc """
  Emit approval resolved event.
  """
  @spec approval_resolved(approval_id :: binary(), decision :: atom(), metadata :: map()) :: :ok
  def approval_resolved(approval_id, decision, metadata \\ %{}) do
    emit([:lemon, :approvals, :resolved], %{count: 1}, Map.merge(metadata, %{
      approval_id: approval_id,
      decision: decision
    }))
  end

  # Cron events

  @doc """
  Emit cron tick event.
  """
  @spec cron_tick(job_count :: non_neg_integer()) :: :ok
  def cron_tick(job_count) do
    emit([:lemon, :cron, :tick], %{job_count: job_count}, %{})
  end
end
