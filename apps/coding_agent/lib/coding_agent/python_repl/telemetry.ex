defmodule CodingAgent.PythonRepl.Telemetry do
  @moduledoc false

  alias LemonCore.Introspection
  alias LemonCore.Telemetry, as: LemonTelemetry

  @prefix [:coding_agent, :python_repl]

  @type session_end_reason :: :shutdown | :reset | :owner_detached | :capacity_eviction
  @type crash_reason ::
          :startup_failure | :port_exit | :protocol_fault | :cancellation_escalation | :unknown
  @type reap_reason :: :idle | :unreachable
  @type cell_outcome ::
          :ok | :exception | :timeout | :port_exit | :protocol_fault | :interrupted | :unknown
  @type cancel_cause :: :timeout | :caller_exit | :shutdown | :unknown
  @type fallback_reason ::
          :missing_session_scope
          | :capacity_exhausted
          | :registry_unavailable
          | :startup_failed
          | :stop_failed
          | :unknown

  @spec session_started(non_neg_integer(), pos_integer()) :: :ok
  def session_started(live_kernels, capacity) do
    emit([:session, :start], %{
      count: 1,
      live_kernels: count(live_kernels),
      capacity: count(capacity)
    })
  end

  @spec session_stopped(non_neg_integer(), non_neg_integer(), pos_integer(), session_end_reason()) ::
          :ok
  def session_stopped(duration_ms, live_kernels, capacity, reason) do
    emit(
      [:session, :stop],
      %{
        count: 1,
        duration_ms: duration(duration_ms),
        live_kernels: count(live_kernels),
        capacity: count(capacity)
      },
      %{reason: session_end_reason(reason)}
    )
  end

  @spec session_crashed(non_neg_integer(), non_neg_integer(), pos_integer(), crash_reason()) ::
          :ok
  def session_crashed(duration_ms, live_kernels, capacity, reason) do
    emit(
      [:session, :crash],
      %{
        count: 1,
        duration_ms: duration(duration_ms),
        live_kernels: count(live_kernels),
        capacity: count(capacity)
      },
      %{reason: crash_reason(reason)}
    )
  end

  @spec session_reaped(non_neg_integer(), non_neg_integer(), pos_integer(), reap_reason()) :: :ok
  def session_reaped(idle_ms, live_kernels, capacity, reason) do
    emit(
      [:session, :reap],
      %{
        count: 1,
        idle_ms: duration(idle_ms),
        live_kernels: count(live_kernels),
        capacity: count(capacity)
      },
      %{reason: reap_reason(reason)}
    )
  end

  @spec cell_started(non_neg_integer(), non_neg_integer()) :: :ok
  def cell_started(queue_depth, max_queued_cells) do
    emit(
      [:cell, :start],
      %{count: 1, queue_depth: count(queue_depth), queue_capacity: count(max_queued_cells)}
    )
  end

  @spec cell_stopped(non_neg_integer(), cell_outcome()) :: :ok
  def cell_stopped(duration_ms, outcome) do
    emit(
      [:cell, :stop],
      %{count: 1, duration_ms: duration(duration_ms)},
      %{outcome: cell_outcome(outcome)}
    )
  end

  @spec cell_cancelled(non_neg_integer(), cancel_cause()) :: :ok
  def cell_cancelled(duration_ms, cause) do
    emit(
      [:cell, :cancel],
      %{count: 1, duration_ms: duration(duration_ms)},
      %{cause: cancel_cause(cause)}
    )
  end

  @spec fallback(fallback_reason()) :: :ok
  def fallback(reason) do
    emit([:fallback], %{count: 1}, %{reason: fallback_reason(reason)})
  end

  @spec bridge_denied(:authentication | term()) :: :ok
  def bridge_denied(reason) do
    emit([:bridge, :deny], %{count: 1}, %{reason: bridge_denial_reason(reason)})
  end

  defp emit(suffix, measurements, metadata \\ %{}) do
    LemonTelemetry.emit(@prefix ++ suffix, measurements, metadata)
    record_summary(suffix, measurements, metadata)
  end

  defp record_summary(suffix, measurements, metadata) do
    _ =
      Introspection.record(
        :python_repl_lifecycle_observed,
        Map.merge(measurements, Map.put(metadata, :event, lifecycle_event(suffix)))
      )

    :ok
  rescue
    _error -> :ok
  catch
    _, _ -> :ok
  end

  defp lifecycle_event([:session, :start]), do: :session_started
  defp lifecycle_event([:session, :stop]), do: :session_stopped
  defp lifecycle_event([:session, :crash]), do: :session_crashed
  defp lifecycle_event([:session, :reap]), do: :session_reaped
  defp lifecycle_event([:cell, :start]), do: :cell_started
  defp lifecycle_event([:cell, :stop]), do: :cell_stopped
  defp lifecycle_event([:cell, :cancel]), do: :cell_cancelled
  defp lifecycle_event([:fallback]), do: :fallback
  defp lifecycle_event([:bridge, :deny]), do: :bridge_denied
  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0
  defp duration(value) when is_integer(value) and value >= 0, do: value
  defp duration(_value), do: 0

  defp session_end_reason(reason)
       when reason in [:shutdown, :reset, :owner_detached, :capacity_eviction], do: reason

  defp session_end_reason(_reason), do: :shutdown

  defp crash_reason(reason)
       when reason in [:startup_failure, :port_exit, :protocol_fault, :cancellation_escalation],
       do: reason

  defp crash_reason(_reason), do: :unknown

  defp reap_reason(reason) when reason in [:idle, :unreachable], do: reason
  defp reap_reason(_reason), do: :unreachable

  defp cell_outcome(reason)
       when reason in [:ok, :exception, :timeout, :port_exit, :protocol_fault, :interrupted],
       do: reason

  defp cell_outcome(_reason), do: :unknown

  defp cancel_cause(cause) when cause in [:timeout, :caller_exit, :shutdown], do: cause
  defp cancel_cause(_cause), do: :unknown

  defp fallback_reason(reason)
       when reason in [
              :missing_session_scope,
              :capacity_exhausted,
              :registry_unavailable,
              :startup_failed,
              :stop_failed
            ],
       do: reason

  defp fallback_reason(_reason), do: :unknown

  defp bridge_denial_reason(:authentication), do: :authentication
  defp bridge_denial_reason(_reason), do: :authentication
end
