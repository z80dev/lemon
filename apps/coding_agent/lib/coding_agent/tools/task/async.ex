defmodule CodingAgent.Tools.Task.Async do
  @moduledoc false

  require Logger

  alias CodingAgent.BudgetEnforcer
  alias CodingAgent.Parallel
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.TaskStore

  alias CodingAgent.Tools.Task.{
    Control,
    Execution,
    Followup,
    LiveBridge,
    Projection,
    Result,
    Runner
  }

  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.Introspection

  @type launch_error :: :task_supervisor_unavailable | :task_capacity_reached | :task_start_failed

  @spec run_async(String.t() | nil, String.t() | nil, (-> term()), map(), map()) ::
          :ok | {:error, launch_error()}
  def run_async(task_id, run_id, run_fun, followup_context, lifecycle_context) do
    _ = maybe_start_live_bridge(run_id)

    supervisor = Map.get(lifecycle_context, :task_supervisor, CodingAgent.TaskSupervisor)

    Control.register(
      task_id,
      lifecycle_context.signal,
      lifecycle_context[:parent_signal],
      lifecycle_context[:parent_session_pid],
      fn reason ->
        finalize_async(task_id, run_id, {:error, reason}, followup_context, lifecycle_context)
      end,
      lifecycle_context[:task_owner_pid]
    )

    Control.configure(task_id, %{
      followup: followup_context,
      lifecycle: lifecycle_context
    })

    case start_async_worker(supervisor, fn ->
           Logger.debug(
             "Task tool async start task_id=#{inspect(task_id)} run_id=#{inspect(run_id)}"
           )

           with :ok <- Control.attach_worker(task_id) do
             result = safe_run(task_id, run_id, run_fun, lifecycle_context)
             finalize_async(task_id, run_id, result, followup_context, lifecycle_context)
           end
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        launch_error = normalize_launch_error(reason)

        Logger.warning(
          "Task tool async worker failed to start task_id=#{inspect(task_id)} " <>
            "run_id=#{inspect(run_id)} reason=#{inspect(reason)}"
        )

        finalize_launch_failure(task_id, run_id, launch_error, lifecycle_context)
        Control.complete(task_id)
        {:error, launch_error}
    end
  end

  @doc false
  def resume(task_id, entry, text) do
    context = entry.continuation

    start_async_worker(context.lifecycle[:task_supervisor] || CodingAgent.TaskSupervisor, fn ->
      with :ok <- Control.attach_worker(task_id) do
        update = wrap_on_update(task_id, context.lifecycle, context.lifecycle[:on_update])

        result =
          safe_run(
            nil,
            nil,
            fn ->
              Runner.resume_session(
                entry.session,
                entry.resume,
                text,
                entry.signal,
                update
              )
              |> Execution.validate_output(context.lifecycle)
            end,
            context.lifecycle
          )

        persist_continuation(task_id, result)
        emit_terminal_update(task_id, context.lifecycle[:run_id], result, context.lifecycle)
        Control.complete(task_id)
        finish_continuation(task_id, context, result)
      end
    end)
  end

  defp persist_continuation(task_id, {:ok, %AgentToolResult{} = result}),
    do: TaskStore.finish(task_id, result)

  defp persist_continuation(task_id, {:ok, {:error, reason}}),
    do: TaskStore.fail(task_id, reason)

  defp persist_continuation(task_id, {:error, reason}),
    do: TaskStore.fail(task_id, reason)

  @doc false
  def finish_continuation(task_id, context, result) do
    persist_continuation(task_id, result)

    maybe_send_async_followup(
      Map.put(context.followup, :auto_followup, true),
      task_id,
      context.lifecycle[:run_id],
      result
    )
  end

  @spec wrap_on_update(String.t() | nil, map(), (AgentToolResult.t() -> :ok) | nil) ::
          (AgentToolResult.t() -> :ok) | nil
  def wrap_on_update(nil, _lifecycle_context, on_update), do: on_update

  def wrap_on_update(task_id, lifecycle_context, on_update) do
    fn %AgentToolResult{} = result ->
      case result.details do
        %{task_id: descendant_id} when is_binary(descendant_id) and descendant_id != task_id ->
          # A native child relays its descendants through this callback. Their
          # own worker already persists these events; do not relabel or duplicate them.
          notify_progress(lifecycle_context, on_update, result)

        _ ->
          result = %{
            result
            | details:
                (result.details || %{})
                |> Map.merge(Result.lineage_details(lifecycle_context))
                |> Map.merge(%{
                  task_id: task_id,
                  run_id: lifecycle_context[:run_id],
                  description: lifecycle_context[:description]
                })
          }

          TaskStore.append_event(task_id, result)
          maybe_emit_child_engine_action(result, lifecycle_context)

          notify_progress(lifecycle_context, on_update, result)
      end
    end
  end

  defp maybe_emit_child_engine_action(%AgentToolResult{} = result, lifecycle_context) do
    case Projection.engine_action_event_from_update(result, lifecycle_context) do
      {:ok, event} ->
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(lifecycle_context[:run_id]),
          event
        )

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp safe_run(task_id, run_id, run_fun, lifecycle_context) do
    wrapped = fn ->
      if LemonAgent.AbortSignal.aborted?(lifecycle_context[:signal]) do
        {:error, "Task aborted"}
      else
        maybe_mark_running(task_id, run_id, lifecycle_context)
        result = run_fun.()

        if LemonAgent.AbortSignal.aborted?(lifecycle_context[:signal]),
          do: {:error, "Task aborted"},
          else: result
      end
    end

    try do
      unless lifecycle_context[:orchestration_worker], do: maybe_acquire_task_semaphore()

      {:ok, wrapped.()}
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    catch
      kind, reason -> {:error, {kind, reason}}
    after
      unless lifecycle_context[:orchestration_worker], do: maybe_release_task_semaphore()
    end
  end

  defp finalize_async(task_id, run_id, result, followup_context, lifecycle_context) do
    Logger.info(
      "Task tool async finalize task_id=#{inspect(task_id)} run_id=#{inspect(run_id)} result_type=#{inspect(async_result_type(result))}"
    )

    emit_terminal_update(task_id, run_id, result, lifecycle_context)

    case result do
      {:ok, result} when is_map(result) ->
        usage = Map.get(result, :usage) || get_in(Map.get(result, :details) || %{}, [:usage])

        if is_map(usage) do
          LemonAgent.BudgetScope.report(
            lifecycle_context[:parent_budget_scope],
            run_id,
            LemonAgent.Budget.usage_from_message(%{usage: usage})
          )
        end

      _ ->
        :ok
    end

    case result do
      {:ok, %AgentToolResult{} = tool_result} ->
        TaskStore.finish(task_id, tool_result)
        maybe_finish_run(run_id, tool_result)
        emit_task_terminal_event(task_id, run_id, {:ok, tool_result}, lifecycle_context)
        maybe_record_budget_completion(run_id, tool_result)
        complete_control(task_id)
        maybe_send_async_followup(followup_context, task_id, run_id, {:ok, tool_result})

      {:ok, {:error, reason}} ->
        terminalize_error(task_id, run_id, reason)
        emit_task_terminal_event(task_id, run_id, {:error, reason}, lifecycle_context)
        maybe_record_budget_completion(run_id, %{error: reason})
        complete_control(task_id)
        maybe_send_async_followup(followup_context, task_id, run_id, {:error, reason})

      {:error, reason} ->
        terminalize_error(task_id, run_id, reason)
        emit_task_terminal_event(task_id, run_id, {:error, reason}, lifecycle_context)
        maybe_record_budget_completion(run_id, %{error: reason})
        complete_control(task_id)
        maybe_send_async_followup(followup_context, task_id, run_id, {:error, reason})

      {:ok, other} ->
        TaskStore.finish(task_id, other)
        maybe_finish_run(run_id, other)
        emit_task_terminal_event(task_id, run_id, {:ok, other}, lifecycle_context)
        maybe_record_budget_completion(run_id, other)
        complete_control(task_id)
        maybe_send_async_followup(followup_context, task_id, run_id, {:ok, other})

      other ->
        maybe_fail_run(run_id, other)
        TaskStore.fail(task_id, other)
        emit_task_terminal_event(task_id, run_id, {:error, other}, lifecycle_context)
        maybe_record_budget_completion(run_id, %{error: other})
        complete_control(task_id)
        maybe_send_async_followup(followup_context, task_id, run_id, {:error, other})
    end
  end

  defp complete_control(task_id) do
    unless self() == Process.whereis(Control), do: Control.complete(task_id)
  end

  defp maybe_send_async_followup(followup_context, task_id, run_id, outcome) do
    if is_binary(task_id) and task_id != "" and TaskStore.auto_followup_suppressed?(task_id) do
      :ok
    else
      Followup.maybe_send_async_followup(followup_context, task_id, run_id, outcome)
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

  defp start_async_worker(supervisor, fun) do
    Task.Supervisor.start_child(supervisor, fun)
  rescue
    error -> {:error, {:exception, error}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp normalize_launch_error({:exit, {:noproc, _}}), do: :task_supervisor_unavailable
  defp normalize_launch_error({:exit, :noproc}), do: :task_supervisor_unavailable
  defp normalize_launch_error({:noproc, _}), do: :task_supervisor_unavailable
  defp normalize_launch_error(:noproc), do: :task_supervisor_unavailable
  defp normalize_launch_error(:max_children), do: :task_capacity_reached
  defp normalize_launch_error({:max_children, _}), do: :task_capacity_reached
  defp normalize_launch_error(_), do: :task_start_failed

  defp finalize_launch_failure(task_id, run_id, reason, lifecycle_context) do
    maybe_fail_run(run_id, reason)

    if is_binary(task_id) and task_id != "" do
      TaskStore.fail(task_id, reason)
    end

    emit_task_terminal_event(task_id, run_id, {:error, reason}, lifecycle_context)
    emit_terminal_update(task_id, run_id, {:error, reason}, lifecycle_context)
    maybe_record_budget_completion(run_id, %{error: reason})
    delete_progress_binding(run_id)
    :ok
  rescue
    _ -> :ok
  end

  defp delete_progress_binding(run_id) when is_binary(run_id) and run_id != "" do
    TaskProgressBindingStore.delete_by_child_run_id(run_id)
  end

  defp delete_progress_binding(_run_id), do: :ok

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

  defp terminalize_error(task_id, run_id, reason) do
    if aborted_reason?(normalize_task_reason(reason)) do
      TaskStore.cancel(task_id, reason)
    else
      TaskStore.fail(task_id, reason)
    end

    maybe_fail_run(run_id, reason)
  end

  defp emit_terminal_update(task_id, run_id, result, context) do
    {status, text} =
      case result do
        {:ok, {:error, reason}} ->
          terminal_error(reason)

        {:error, reason} ->
          terminal_error(reason)

        {:ok, %AgentToolResult{is_error: true} = value} ->
          {"error", Result.visible_output_text(value)}

        {:ok, value} ->
          {"completed", Result.visible_output_text(value)}

        other ->
          terminal_error(other)
      end

    result_details =
      case result do
        {:ok, %AgentToolResult{details: details}} when is_map(details) ->
          Map.take(details, [
            :session_id,
            :cwd,
            :worktree_path,
            :branch,
            :merge,
            :structured_output
          ])

        _ ->
          %{}
      end

    callback = context[:on_update]

    notify_progress(context, callback, %AgentToolResult{
      content: [%LemonAi.Types.TextContent{text: text}],
      is_error: status in ["error", "aborted"],
      details:
        result_details
        |> Map.merge(Result.lineage_details(context))
        |> Map.merge(%{
          task_id: task_id,
          run_id: run_id,
          description: context[:description],
          status: status
        })
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp terminal_error(reason) do
    text = normalize_task_reason(reason)
    {if(aborted_reason?(text), do: "aborted", else: "error"), text}
  end

  defp notify_progress(context, callback, result) do
    if context[:direct_progress] == true and is_pid(context[:parent_session_pid]) do
      send(context.parent_session_pid, {:task_progress, context.root_action_id, result})
    else
      if is_function(callback, 1), do: callback.(result), else: :ok
    end
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

    event =
      LemonCore.Event.new(event_type, payload, %{
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

  defp maybe_start_live_bridge(run_id) when is_binary(run_id),
    do: LiveBridge.start_for_child_run(run_id)

  defp maybe_start_live_bridge(_), do: :ok
end
