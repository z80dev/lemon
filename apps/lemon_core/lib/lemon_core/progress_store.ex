defmodule LemonCore.ProgressStore do
  @moduledoc """
  Typed store for progress-related state.

  Provides a clear, typed API for managing progress message to run ID
  mappings and pending compaction markers. Delegates to `LemonCore.Store`
  internally and emits telemetry events for each operation.

  ## Tables managed

  - `:progress` - Maps progress/status message IDs to run IDs
  - `:pending_compaction` - Marks sessions needing compaction

  ## Telemetry events

  Each operation emits a pair of telemetry events:

  - `[:lemon_core, :store, :put_progress_mapping, :start/:stop]`
  - `[:lemon_core, :store, :get_run_by_progress, :start/:stop]`
  - `[:lemon_core, :store, :delete_progress_mapping, :start/:stop]`
  - `[:lemon_core, :store, :put_pending_compaction, :start/:stop]`
  - `[:lemon_core, :store, :get_pending_compaction, :start/:stop]`
  - `[:lemon_core, :store, :delete_pending_compaction, :start/:stop]`
  """

  alias LemonCore.Store

  @type scope :: term()
  @type progress_msg_id :: integer()
  @type run_id :: term()
  @type session_key :: binary()

  # --- Progress Mapping API ---

  @doc """
  Map a progress message ID to a run ID within a scope.

  Used to track which progress/status messages correspond to which runs,
  enabling lookups when users interact with progress messages.
  """
  @spec put_progress_mapping(scope(), progress_msg_id(), run_id()) :: :ok
  def put_progress_mapping(scope, progress_msg_id, run_id) do
    emit_telemetry(
      :put_progress_mapping,
      %{table: :progress, scope: scope, progress_msg_id: progress_msg_id},
      fn ->
        Store.put_progress_mapping(scope, progress_msg_id, run_id)
      end
    )
  end

  @doc """
  Look up which run a progress message belongs to.

  Returns the run ID or `nil` if the mapping doesn't exist.
  """
  @spec get_run_by_progress(scope(), progress_msg_id()) :: run_id() | nil
  def get_run_by_progress(scope, progress_msg_id) do
    emit_telemetry(
      :get_run_by_progress,
      %{table: :progress, scope: scope, progress_msg_id: progress_msg_id},
      fn ->
        Store.get_run_by_progress(scope, progress_msg_id)
      end
    )
  end

  @doc """
  Remove a progress message to run mapping.
  """
  @spec delete_progress_mapping(scope(), progress_msg_id()) :: :ok
  def delete_progress_mapping(scope, progress_msg_id) do
    emit_telemetry(
      :delete_progress_mapping,
      %{table: :progress, scope: scope, progress_msg_id: progress_msg_id},
      fn ->
        Store.delete_progress_mapping(scope, progress_msg_id)
      end
    )
  end

  # --- Pending Compaction API ---

  @doc """
  Mark a session as needing compaction.
  """
  @spec put_pending_compaction(session_key(), term()) :: :ok | {:error, term()}
  def put_pending_compaction(session_key, value \\ true) do
    emit_telemetry(
      :put_pending_compaction,
      %{table: :pending_compaction, session_key: session_key},
      fn ->
        Store.put(:pending_compaction, session_key, value)
      end
    )
  end

  @doc """
  Get the pending compaction marker for a session.

  Returns the marker value or `nil` if no compaction is pending.
  """
  @spec get_pending_compaction(session_key()) :: term() | nil
  def get_pending_compaction(session_key) do
    emit_telemetry(
      :get_pending_compaction,
      %{table: :pending_compaction, session_key: session_key},
      fn ->
        Store.get(:pending_compaction, session_key)
      end
    )
  end

  @doc """
  Remove a pending compaction marker for a session.
  """
  @spec delete_pending_compaction(session_key()) :: :ok | {:error, term()}
  def delete_pending_compaction(session_key) do
    emit_telemetry(
      :delete_pending_compaction,
      %{table: :pending_compaction, session_key: session_key},
      fn ->
        Store.delete(:pending_compaction, session_key)
      end
    )
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
