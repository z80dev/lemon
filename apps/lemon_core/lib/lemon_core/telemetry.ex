defmodule LemonCore.Telemetry do
  @moduledoc """
  Telemetry event helpers for Lemon.

  Provides consistent telemetry emission across the umbrella.

  ## Duration convention

  New span-style emitters (`:start` / `:stop` / `:exception`) should report `duration`
  measured in **native** units — capture `System.monotonic_time()` at the start and subtract
  at the stop, exactly as `:telemetry.span/3` does. Derive `duration_ms` only when a
  human-facing log needs it, via `System.convert_time_unit(duration, :native, :millisecond)`;
  never synthesize a native reading by multiplying a millisecond value. Several existing
  events predate this convention and report `duration_us` or `duration_ms` instead — those
  are catalogued (and not renamed, to avoid breaking attached consumers) in
  `docs/telemetry.md`.

  ## Event Names

  ### Runs
  - `[:lemon, :run, :submit]` - measurements: `%{count: 1}` meta: `%{session_key, origin, engine}`.
    Emitted from `LemonRouter.RunOrchestrator` when a submission is accepted.
  - `[:lemon, :run, :start]` - measurements: `%{ts_ms: ...}` meta: `%{run_id, ...}`
  - `[:lemon, :run, :first_token]` - measurements: `%{latency_ms: ...}` meta: `%{run_id}`
  - `[:lemon, :run, :stop]` - measurements: `%{duration_ms: ..., ok: boolean()}` meta: `%{run_id}`

  `:start` / `:first_token` / `:stop` are emitted from the gateway run process
  (`LemonGateway.Run`) via `LemonGateway.DependencyManager.emit_telemetry/2`, which dispatches
  here with `apply/3`. Because the dispatch is dynamic, a literal-name grep for the helpers
  finds no callers even though the run span fires end-to-end.

  ### Channels
  - `[:lemon, :channels, :dispatch]` - measurements: `%{count: 1, duration: native}` meta:
    `%{channel_id, account_id, kind, intent_id, run_id, session_key, ok}`. Emitted from
    `LemonChannels.Dispatcher` after every semantic dispatch, success or failure — check
    `ok`. The bus twin is the `:channel_delivery` event on the `"channels"` topic.
  - `[:lemon, :channels, :deliver, :start]`
  - `[:lemon, :channels, :deliver, :stop]`
  - `[:lemon, :channels, :deliver, :exception]`
  - `[:lemon, :channels, :inbound]`

  ### Approvals
  - `[:lemon, :approvals, :requested]`
  - `[:lemon, :approvals, :resolved]`

  ### Cron
  - `[:lemon, :cron, :tick]` - measurements: `%{job_count: n}`. Emitted once per scheduler
    tick from `LemonAutomation.CronManager`, as a scheduler-liveness heartbeat.

  ### Memory Ingest (M5)
  - `[:lemon, :memory, :ingest, :ok]` - measurements: `%{duration_us: integer()}`,
    meta: `%{run_id, session_key, agent_id}`. Emitted after each successful ingest.
  - `[:lemon, :memory, :ingest, :failure]` - measurements: `%{count: 1, duration_us: integer()}`,
    meta: `%{run_id, error}`. Emitted when an ingest fails (after catching the exception).

  ### Skills
  - `[:lemon_skills, :skill, :load]` - measurements: `%{count: 1, system_time: integer()}`,
    meta includes `result`, `key`, `view`, `tool_call_id`, `session_key`, and redacted skill metadata when available.
    Projected to introspection as `:skill_load_observed`.
  - `[:lemon_skills, :skill, :write]` - measurements: `%{count: 1, system_time: integer()}`,
    meta includes `result`, `action`, `name`, `scope`, `tool_call_id`, `session_key`, and redacted write metadata.
    Projected to introspection as `:skill_write_observed`.
  - `[:lemon_skills, :skill, :prompt_render]` - measurements: `%{count: 1, system_time: integer()}`,
    meta includes `surface`, `skill_count`, `skill_keys`, activation counts, `session_key`, and redacted prompt-render metadata.
    Projected to introspection as `:skill_prompt_render_observed`.
  """

  @doc """
  Execute a function and emit start/stop/exception telemetry.
  """
  @spec span(event_prefix :: [atom()], metadata :: map(), fun :: (-> result)) :: result
        when result: term()
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
    emit(
      [:lemon, :run, :start],
      %{ts_ms: LemonCore.Clock.now_ms()},
      Map.put(metadata, :run_id, run_id)
    )
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
    emit(
      [:lemon, :approvals, :requested],
      %{count: 1},
      Map.merge(metadata, %{
        approval_id: approval_id,
        tool: tool
      })
    )
  end

  @doc """
  Emit approval resolved event.
  """
  @spec approval_resolved(approval_id :: binary(), decision :: atom(), metadata :: map()) :: :ok
  def approval_resolved(approval_id, decision, metadata \\ %{}) do
    emit(
      [:lemon, :approvals, :resolved],
      %{count: 1},
      Map.merge(metadata, %{
        approval_id: approval_id,
        decision: decision
      })
    )
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
