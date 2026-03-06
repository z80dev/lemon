defmodule CodingAgent.Tools.Task.Async do
  @moduledoc false

  require Logger

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.BudgetEnforcer
  alias CodingAgent.LaneQueue
  alias CodingAgent.Parallel
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.Followup
  alias CodingAgent.Tools.Task.Result
  alias LemonCore.Introspection

  @spec run_async(String.t() | nil, String.t() | nil, (() -> term()), map(), map()) :: :ok
  def run_async(task_id, run_id, run_fun, followup_context, lifecycle_context) do
    Task.Supervisor.start_child(CodingAgent.TaskSupervisor, fn ->
      Logger.debug("Task tool async start task_id=#{inspect(task_id)} run_id=#{inspect(run_id)}")
      result = safe_run(task_id, run_id, run_fun, lifecycle_context)
      finalize_async(task_id, run_id, result, followup_context, lifecycle_context)
    end)

    :ok
  end

  @spec run_sync((() -> term())) :: term()
  def run_sync(run_fun) do
    result =
      if lane_queue_available?() do
        LaneQueue.run(CodingAgent.LaneQueue, :subagent, run_fun, %{})
      else
        {:ok, run_fun.()}
      end

    case result do
      {:ok, %AgentToolResult{} = tool_result} -> tool_result
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:ok, other} -> other
    end
  end

  @spec wrap_on_update(String.t() | nil, ((AgentToolResult.t() -> :ok) | nil)) ::
          (AgentToolResult.t() -> :ok) | nil
  def wrap_on_update(nil, on_update), do: on_update

  def wrap_on_update(task_id, nil) do
    fn result ->
      TaskStore.append_event(task_id, result)
      :ok
    end
  end

  def wrap_on_update(task_id, on_update) do
    fn result ->
      TaskStore.append_event(task_id, result)
      on_update.(result)
    end
  end

  defp safe_run(task_id, run_id, run_fun, lifecycle_context) do
    wrapped = fn ->
      maybe_mark_running(task_id, run_id, lifecycle_context)
      run_fun.()
    end

    try do
      maybe_acquire_task_semaphore()

      if lane_queue_available?() do
        LaneQueue.run(CodingAgent.LaneQueue, :subagent, wrapped, %{task_id: task_id, run_id: run_id})
      else
        {:ok, wrapped.()}
      end
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    catch
      kind, reason -> {:error, {kind, reason}}
    after
      maybe_release_task_semaphore()
    end
  end

  defp finalize_async(task_id, run_id, result, followup_context, lifecycle_context) do
    Logger.info(
      "Task tool async finalize task_id=#{inspect(task_id)} run_id=#{inspect(run_id)} result_type=#{inspect(async_result_type(result))}"
    )

    case result do
      {:ok, %AgentToolResult{} = tool_result} ->
        TaskStore.finish(task_id, tool_result)
        maybe_finish_run(run_id, tool_result)
        emit_task_terminal_event(task_id, run_id, {:ok, tool_result}, lifecycle_context)
        maybe_record_budget_completion(run_id, tool_result)
        Followup.maybe_send_async_followup(followup_context, task_id, run_id, {:ok, tool_result})

      {:ok, {:error, reason}} ->
        TaskStore.fail(task_id, reason)
        maybe_fail_run(run_id, reason)
        emit_task_terminal_event(task_id, run_id, {:error, reason}, lifecycle_context)
        maybe_record_budget_completion(run_id, %{error: reason})
        Followup.maybe_send_async_followup(followup_context, task_id, run_id, {:error, reason})

      {:error, reason} ->
        TaskStore.fail(task_id, reason)
        maybe_fail_run(run_id, reason)
        emit_task_terminal_event(task_id, run_id, {:error, reason}, lifecycle_context)
        maybe_record_budget_completion(run_id, %{error: reason})
        Followup.maybe_send_async_followup(followup_context, task_id, run_id, {:error, reason})

      {:ok, other} ->
        TaskStore.finish(task_id, other)
        maybe_finish_run(run_id, other)
        emit_task_terminal_event(task_id, run_id, {:ok, other}, lifecycle_context)
        maybe_record_budget_completion(run_id, other)
        Followup.maybe_send_async_followup(followup_context, task_id, run_id, {:ok, other})

      other ->
        TaskStore.fail(task_id, other)
        maybe_fail_run(run_id, other)
        emit_task_terminal_event(task_id, run_id, {:error, other}, lifecycle_context)
        maybe_record_budget_completion(run_id, %{error: other})
        Followup.maybe_send_async_followup(followup_context, task_id, run_id, {:error, other})
    end
  end

  defp async_result_type({:ok, %AgentToolResult{details: %{status: "completed"}}}), do: :completed
  defp async_result_type({:ok, %AgentToolResult{details: %{status: "error"}}}), do: :error
  defp async_result_type({:ok, %AgentToolResult{}}), do: :ok_tool_result
  defp async_result_type({:ok, {:error, _}}), do: :error_tuple
  defp async_result_type({:error, _}), do: :error
  defp async_result_type(_), do: :other

  defp maybe_record_budget_completion(nil, _result), do: :ok

  defp maybe_record_budget_completion(run_id, result) do
    BudgetEnforcer.on_run_complete(run_id, result)
  rescue
    _ -> :ok
  end

  defp lane_queue_available? do
    case Process.whereis(CodingAgent.LaneQueue) do
      nil -> false
      _pid -> true
    end
  end

  defp maybe_mark_running(nil, _run_id, _lifecycle_context), do: :ok

  defp maybe_mark_running(task_id, run_id, lifecycle_context) do
    TaskStore.mark_running(task_id)

    TaskStore.append_event(task_id, %{
      type: :task_started,
      ts_ms: System.system_time(:millisecond)
    })

    if run_id do
      RunGraph.mark_running(run_id)
    end

    emit_task_started_event(task_id, run_id, lifecycle_context)
    :ok
  end

  defp maybe_finish_run(nil, _result), do: :ok
  defp maybe_finish_run(run_id, result), do: RunGraph.finish(run_id, result)

  defp maybe_fail_run(nil, _reason), do: :ok
  defp maybe_fail_run(run_id, reason), do: RunGraph.fail(run_id, reason)

  defp emit_task_started_event(task_id, run_id, lifecycle_context) do
    payload =
      task_event_payload_base(task_id, run_id, lifecycle_context)
      |> Map.put(:started_at_ms, System.system_time(:millisecond))
      |> Map.put(:status, :running)

    emit_task_lifecycle(:task_started, payload, lifecycle_context)
  end

  defp emit_task_terminal_event(nil, _run_id, _outcome, _lifecycle_context), do: :ok

  defp emit_task_terminal_event(task_id, run_id, outcome, lifecycle_context) do
    {event_type, extra_payload} = classify_task_terminal_event(outcome)

    payload =
      task_event_payload_base(task_id, run_id, lifecycle_context)
      |> Map.merge(extra_payload)
      |> Map.put(:completed_at_ms, System.system_time(:millisecond))
      |> Map.put(:duration_ms, task_duration_ms(task_id))

    TaskStore.append_event(task_id, %{
      type: event_type,
      ts_ms: System.system_time(:millisecond),
      payload: payload
    })

    emit_task_lifecycle(event_type, payload, lifecycle_context)
  end

  defp classify_task_terminal_event({:ok, result}) do
    {:task_completed, %{ok: true, result_preview: Result.build_result_preview(result)}}
  end

  defp classify_task_terminal_event({:error, reason}) do
    normalized = normalize_task_reason(reason)

    cond do
      timeout_reason?(normalized) -> {:task_timeout, %{error: normalized, timeout_ms: nil}}
      aborted_reason?(normalized) -> {:task_aborted, %{reason: normalized}}
      true -> {:task_error, %{error: normalized}}
    end
  end

  defp classify_task_terminal_event(_other), do: {:task_error, %{error: "unknown"}}

  defp task_event_payload_base(task_id, run_id, lifecycle_context) do
    %{
      task_id: task_id,
      run_id: run_id || lifecycle_context[:run_id],
      parent_run_id: lifecycle_context[:parent_run_id],
      session_key: lifecycle_context[:session_key],
      agent_id: lifecycle_context[:agent_id],
      description: lifecycle_context[:description],
      engine: lifecycle_context[:engine],
      role: lifecycle_context[:role],
      queue_mode: lifecycle_context[:queue_mode],
      meta: lifecycle_context[:meta]
    }
  end

  defp task_duration_ms(task_id) do
    case TaskStore.get(task_id) do
      {:ok, record, _events} ->
        started_at = Map.get(record, :started_at)
        completed_at = Map.get(record, :completed_at)

        cond do
          is_integer(started_at) and is_integer(completed_at) ->
            max((completed_at - started_at) * 1000, 0)

          is_integer(started_at) ->
            max((System.system_time(:second) - started_at) * 1000, 0)

          true ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp emit_task_lifecycle(event_type, payload, lifecycle_context) do
    run_id = payload[:run_id] || lifecycle_context[:run_id]
    parent_run_id = payload[:parent_run_id] || lifecycle_context[:parent_run_id]
    session_key = payload[:session_key] || lifecycle_context[:session_key]
    agent_id = payload[:agent_id] || lifecycle_context[:agent_id]
    task_meta = payload[:meta] || lifecycle_context[:meta]

    event = LemonCore.Event.new(event_type, payload, %{
      run_id: run_id,
      parent_run_id: parent_run_id,
      session_key: session_key,
      agent_id: agent_id,
      task_id: payload[:task_id],
      task_meta: task_meta
    })

    if is_binary(run_id) do
      LemonCore.Bus.broadcast("run:#{run_id}", event)
    end

    if is_binary(parent_run_id) and parent_run_id != run_id do
      LemonCore.Bus.broadcast("run:#{parent_run_id}", event)
    end

    Introspection.record(
      event_type,
      payload,
      run_id: run_id,
      parent_run_id: parent_run_id,
      session_key: session_key,
      agent_id: agent_id,
      engine: lifecycle_context[:engine],
      provenance: :direct
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp normalize_task_reason(nil), do: nil
  defp normalize_task_reason(reason) when is_binary(reason), do: reason
  defp normalize_task_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_task_reason(reason), do: inspect(reason, limit: 80)

  defp timeout_reason?(reason) when is_binary(reason) do
    String.contains?(String.downcase(reason), "timeout")
  end

  defp timeout_reason?(_), do: false

  defp aborted_reason?(reason) when is_binary(reason) do
    downcased = String.downcase(reason)
    String.contains?(downcased, "abort") or String.contains?(downcased, "interrupt")
  end

  defp aborted_reason?(_), do: false

  defp maybe_acquire_task_semaphore do
    case Process.whereis(CodingAgent.TaskSemaphore) do
      nil -> :ok
      _pid -> Parallel.Semaphore.acquire(CodingAgent.TaskSemaphore)
    end
  end

  defp maybe_release_task_semaphore do
    case Process.whereis(CodingAgent.TaskSemaphore) do
      nil -> :ok
      _pid -> Parallel.Semaphore.release(CodingAgent.TaskSemaphore)
    end
  end
end
