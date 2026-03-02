defmodule LemonCore.RunStore do
  @moduledoc """
  Typed store for run-related state.

  Provides a clear, typed API for managing run events, run history,
  and run lookups. Delegates to `LemonCore.Store` internally and emits
  telemetry events for each operation.

  ## Tables managed

  - `:runs` - Active run event logs and summaries
  - `:run_history` - Finalized run history indexed by session key

  ## Telemetry events

  Each operation emits a pair of telemetry events:

  - `[:lemon_core, :store, :append_run_event, :start]`
  - `[:lemon_core, :store, :append_run_event, :stop]`
  - `[:lemon_core, :store, :finalize_run, :start]`
  - `[:lemon_core, :store, :finalize_run, :stop]`
  - `[:lemon_core, :store, :get_run, :start]`
  - `[:lemon_core, :store, :get_run, :stop]`
  - `[:lemon_core, :store, :get_run_history, :start]`
  - `[:lemon_core, :store, :get_run_history, :stop]`
  """

  alias LemonCore.Store

  @type run_id :: term()
  @type session_key :: binary()
  @type event :: term()
  @type summary :: map()
  @type run_record :: %{events: [event()], summary: summary() | nil, started_at: non_neg_integer()}
  @type run_history_entry :: {run_id(), run_record()}

  @doc """
  Append an event to a run's event log.

  Eagerly updates the read cache and asynchronously persists to the backend.
  """
  @spec append_event(run_id(), event()) :: :ok
  def append_event(run_id, event) do
    emit_telemetry(:append_run_event, %{table: :runs, run_id: run_id}, fn ->
      Store.append_run_event(run_id, event)
    end)
  end

  @doc """
  Finalize a run with a summary.

  Updates the run record with the summary and creates a run history entry
  indexed by session key (if present in the summary).
  """
  @spec finalize(run_id(), summary()) :: :ok
  def finalize(run_id, summary) do
    emit_telemetry(:finalize_run, %{table: :runs, run_id: run_id}, fn ->
      Store.finalize_run(run_id, summary)
    end)
  end

  @doc """
  Get a specific run by ID.

  Returns the run record or `nil` if not found. Uses the read cache
  for fast lookups.
  """
  @spec get(run_id()) :: run_record() | nil
  def get(run_id) do
    emit_telemetry(:get_run, %{table: :runs, run_id: run_id}, fn ->
      Store.get_run(run_id)
    end)
  end

  @doc """
  Get run history for a session key, ordered by most recent first.

  ## Options

    * `:limit` - Maximum number of runs to return (default: 10)

  Returns a list of `{run_id, run_record}` tuples.
  """
  @spec get_history(session_key(), keyword()) :: [run_history_entry()]
  def get_history(session_key, opts \\ []) do
    emit_telemetry(:get_run_history, %{table: :run_history, session_key: session_key}, fn ->
      Store.get_run_history(session_key, opts)
    end)
  end

  # Emit start/stop telemetry around an operation.
  @spec emit_telemetry(atom(), map(), (-> result)) :: result when result: term()
  defp emit_telemetry(operation, metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:lemon_core, :store, operation, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result = fun.()

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:lemon_core, :store, operation, :stop],
      %{duration: duration},
      metadata
    )

    result
  end
end
