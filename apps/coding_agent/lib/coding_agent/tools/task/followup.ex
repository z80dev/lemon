defmodule CodingAgent.Tools.Task.Followup do
  @moduledoc false

  require Logger

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools.Task.Params
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
    text = task_auto_followup_text(followup_context, task_id, run_id, outcome)

    if send_async_followup_to_live_session(followup_context, text) do
      :ok
    else
      submit_async_followup_via_router(followup_context, task_id, run_id, text)
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
  def task_auto_followup_text(followup_context, task_id, run_id, outcome) do
    description =
      followup_context
      |> Map.get(:description)
      |> Params.normalize_optional_string()

    summary =
      if is_binary(description) and description != "" do
        description
      else
        "background task"
      end

    base =
      "[task #{task_id}] #{summary}" <>
        if(is_binary(run_id) and run_id != "", do: " (run #{run_id})", else: "")

    case normalize_followup_outcome(outcome) do
      %{ok: true, answer: answer} when is_binary(answer) ->
        trimmed = String.trim(answer)

        if trimmed == "" do
          "#{base} completed."
        else
          "#{base} completed.\n\n#{answer}"
        end

      %{ok: false, error: error, answer: answer} ->
        trimmed = if is_binary(answer), do: String.trim(answer), else: ""

        if trimmed == "" do
          "#{base} failed: #{format_error(error)}"
        else
          "#{base} failed: #{format_error(error)}\n\nPartial output:\n#{answer}"
        end
    end
  end

  defp send_async_followup_to_live_session(followup_context, text) do
    session_module = Map.get(followup_context, :session_module, CodingAgent.Session)
    session_pid = Map.get(followup_context, :session_pid)

    if is_pid(session_pid) and Process.alive?(session_pid) and
         function_exported?(session_module, :follow_up, 2) do
      case session_module.follow_up(session_pid, text) do
        :ok -> true
        {:error, _reason} -> false
        _other -> true
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp submit_async_followup_via_router(followup_context, task_id, run_id, text) do
    parent_session_key = Map.get(followup_context, :parent_session_key)
    queue_mode = Map.get(followup_context, :queue_mode, :followup)
    extra_meta = Map.get(followup_context, :meta, %{})

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
          prompt: text,
          queue_mode: queue_mode,
          meta:
            Map.merge(extra_meta, %{
              task_auto_followup: true,
              task_id: task_id,
              run_id: run_id
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
    answer = AgentCore.get_text(result)
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
  defp normalize_followup_answer(%AgentToolResult{} = result), do: AgentCore.get_text(result) || ""
  defp normalize_followup_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(other), do: inspect(other)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp log_followup_failure(task_id, run_id, reason) do
    Logger.warning(
      "Task tool followup submit failed for task_id=#{inspect(task_id)} run_id=#{inspect(run_id)}: #{inspect(reason)}"
    )
  end
end
