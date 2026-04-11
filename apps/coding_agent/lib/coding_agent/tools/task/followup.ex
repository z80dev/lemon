defmodule CodingAgent.Tools.Task.Followup do
  @moduledoc false

  require Logger

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.AsyncFollowups
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.Result
  alias LemonCore.{RunRequest, SessionKey}

  @default_run_orchestrator_parts ["LemonRouter", "RunOrchestrator"]

  @spec default_run_orchestrator() :: module()
  def default_run_orchestrator do
    Module.concat(@default_run_orchestrator_parts)
  end

  @spec maybe_send_async_followup(map(), String.t() | nil, String.t() | nil, term()) :: :ok
  def maybe_send_async_followup(%{auto_followup: false}, _task_id, _run_id, _outcome), do: :ok

  def maybe_send_async_followup(followup_context, task_id, run_id, outcome)
      when is_map(followup_context) do
    ensure_terminal_state(task_id, run_id, outcome)
    text = task_auto_followup_text(followup_context, task_id, run_id, outcome)
    queue_mode = Map.get(followup_context, :queue_mode, :followup)
    session_module = Map.get(followup_context, :session_module, CodingAgent.Session)
    session_pid = Map.get(followup_context, :session_pid)

    case AsyncFollowups.dispatch_target(queue_mode, session_module, session_pid) do
      {:live, delivery_mode} ->
        if send_async_followup_to_live_session(
             followup_context,
             text,
             task_id,
             run_id,
             delivery_mode
           ) do
          :ok
        else
          submit_async_followup_via_router(
            followup_context,
            task_id,
            run_id,
            text,
            AsyncFollowups.router_fallback_queue_mode(delivery_mode)
          )
        end

      {:router, router_queue_mode} ->
        submit_async_followup_via_router(
          followup_context,
          task_id,
          run_id,
          text,
          router_queue_mode
        )
    end
  rescue
    error ->
      Logger.warning(
        "Task tool failed to auto-followup task_id=#{inspect(task_id)} run_id=#{inspect(run_id)}: #{inspect(error)}"
      )

      :ok
  end

  def maybe_send_async_followup(_followup_context, _task_id, _run_id, _outcome), do: :ok

  @spec task_auto_followup_text(map(), String.t() | nil, String.t() | nil, term()) :: String.t()
  def task_auto_followup_text(_followup_context, _task_id, _run_id, outcome) do
    case normalize_followup_outcome(outcome) do
      %{ok: true, answer: answer} when is_binary(answer) ->
        answer
        |> normalize_followup_text()
        |> empty_followup_fallback("Task completed.")

      %{ok: false, error: error, answer: answer} ->
        answer
        |> normalize_followup_text()
        |> empty_followup_fallback("Task failed: #{format_error(error)}")
    end
  end

  defp normalize_followup_text(text) when is_binary(text) do
    trimmed =
      try do
        String.trim(text)
      rescue
        ArgumentError -> inspect(text, limit: 200)
      end

    trimmed
  end

  defp normalize_followup_text(_), do: ""

  defp empty_followup_fallback("", fallback), do: fallback
  defp empty_followup_fallback(text, _fallback), do: text

  defp ensure_terminal_state(task_id, run_id, outcome) do
    case outcome do
      {:ok, %AgentToolResult{} = result} ->
        maybe_finish_task(task_id, result)
        maybe_finish_run(run_id, result)

      {:ok, {:error, reason}} ->
        maybe_fail_task(task_id, reason)
        maybe_fail_run(run_id, reason)

      {:error, reason} ->
        maybe_fail_task(task_id, reason)
        maybe_fail_run(run_id, reason)

      {:ok, other} ->
        maybe_finish_task(task_id, other)
        maybe_finish_run(run_id, other)

      other ->
        maybe_fail_task(task_id, other)
        maybe_fail_run(run_id, other)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_finish_task(task_id, result) when is_binary(task_id) and task_id != "" do
    case TaskStore.get(task_id) do
      {:ok, %{status: status}, _events} when status in [:queued, :running] ->
        TaskStore.finish(task_id, result)

      _ ->
        :ok
    end
  end

  defp maybe_finish_task(_task_id, _result), do: :ok

  defp maybe_fail_task(task_id, reason) when is_binary(task_id) and task_id != "" do
    case TaskStore.get(task_id) do
      {:ok, %{status: status}, _events} when status in [:queued, :running] ->
        TaskStore.fail(task_id, reason)

      _ ->
        :ok
    end
  end

  defp maybe_fail_task(_task_id, _reason), do: :ok

  defp maybe_finish_run(run_id, result) when is_binary(run_id) and run_id != "" do
    case RunGraph.get(run_id) do
      {:ok, %{status: status}} when status in [:queued, :running] ->
        _ = RunGraph.finish(run_id, result)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_finish_run(_run_id, _result), do: :ok

  defp maybe_fail_run(run_id, reason) when is_binary(run_id) and run_id != "" do
    case RunGraph.get(run_id) do
      {:ok, %{status: status}} when status in [:queued, :running] ->
        _ = RunGraph.fail(run_id, reason)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_fail_run(_run_id, _reason), do: :ok

  defp send_async_followup_to_live_session(
         followup_context,
         text,
         task_id,
         run_id,
         delivery_mode
       ) do
    session_module = Map.get(followup_context, :session_module, CodingAgent.Session)
    session_pid = Map.get(followup_context, :session_pid)

    case session_module.handle_async_followup(
           session_pid,
           build_async_followup_message(text, task_id, run_id, delivery_mode)
         ) do
      :ok -> true
      {:error, _reason} -> false
      _other -> true
    end
  rescue
    _ -> false
  end

  defp submit_async_followup_via_router(
         followup_context,
         task_id,
         run_id,
         text,
         queue_mode
       ) do
    parent_session_key = Map.get(followup_context, :parent_session_key)
    extra_meta = Map.get(followup_context, :meta, %{})
    cwd = Map.get(followup_context, :cwd)

    if is_binary(parent_session_key) and parent_session_key != "" do
      parent_agent_id =
        Map.get(followup_context, :parent_agent_id) ||
          SessionKey.agent_id(parent_session_key) ||
          "default"

      run_orchestrator =
        Map.get(followup_context, :run_orchestrator, default_run_orchestrator())

      followup =
        RunRequest.new(%{
          origin: :node,
          session_key: parent_session_key,
          agent_id: parent_agent_id,
          engine_id: "echo",
          prompt: text,
          queue_mode: queue_mode,
          cwd: cwd,
          meta:
            Map.merge(extra_meta, %{
              :task_auto_followup => true,
              :task_id => task_id,
              :run_id => run_id,
              "async_followups" => [async_followup_entry(task_id, run_id, queue_mode)]
            })
        })

      case run_orchestrator.submit(followup) do
        {:ok, _run_id} ->
          :ok

        {:error, {:unknown_agent_id, _}} when parent_agent_id != "default" ->
          fallback = %{followup | agent_id: "default"}

          case run_orchestrator.submit(fallback) do
            {:ok, _fallback_run_id} ->
              :ok

            {:error, reason} ->
              log_followup_failure(task_id, run_id, reason)
          end

        {:error, reason} ->
          log_followup_failure(task_id, run_id, reason)
      end
    else
      Logger.debug(
        "Task tool skipping auto-followup task_id=#{inspect(task_id)} run_id=#{inspect(run_id)}: parent session key unavailable"
      )
    end
  end

  defp normalize_followup_outcome({:ok, %AgentToolResult{} = result}) do
    answer = Result.visible_output_text(result)
    details = result.details || %{}
    status = details[:status] || details["status"]
    error = details[:error] || details["error"]

    if status == "error" or not is_nil(error) do
      %{ok: false, error: error || "task failed", answer: answer || ""}
    else
      %{ok: true, answer: answer || ""}
    end
  end

  defp normalize_followup_outcome({:ok, {:error, reason}}) do
    %{ok: false, error: reason, answer: ""}
  end

  defp normalize_followup_outcome({:error, reason}) do
    %{ok: false, error: reason, answer: ""}
  end

  defp normalize_followup_outcome({:ok, other}) do
    %{ok: true, answer: normalize_followup_answer(other)}
  end

  defp normalize_followup_outcome(other) do
    %{ok: false, error: other, answer: ""}
  end

  defp normalize_followup_answer(answer) when is_binary(answer), do: answer

  defp normalize_followup_answer(%AgentToolResult{} = result),
    do: Result.visible_output_text(result)

  defp normalize_followup_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(other), do: Result.visible_output_text(other)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp build_async_followup_message(text, task_id, run_id, delivery) do
    %{
      content: text,
      details: %{
        source: :task,
        task_id: task_id,
        run_id: run_id,
        delivery: delivery
      },
      async_followups: [async_followup_entry(task_id, run_id, delivery)]
    }
  end

  defp async_followup_entry(task_id, run_id, delivery) do
    %{
      source: :task,
      task_id: task_id,
      run_id: run_id,
      delivery: delivery
    }
  end

  defp log_followup_failure(task_id, run_id, reason) do
    Logger.warning(
      "Task tool followup submit failed for task_id=#{inspect(task_id)} run_id=#{inspect(run_id)}: #{inspect(reason)}"
    )
  end
end
