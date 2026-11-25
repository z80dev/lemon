defmodule CodingAgent.TaskRuntime.Followup do
  @moduledoc false

  require Logger

  alias LemonAgent.Types.AgentToolResult
  alias CodingAgent.AsyncFollowups
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.Result

  @default_run_orchestrator_parts ["LemonRouter", "RunOrchestrator"]
  @max_inline_followup_chars 12_000
  @followup_preview_chars 10_000
  @max_error_chars 1_000

  @spec default_run_orchestrator() :: module()
  def default_run_orchestrator do
    Module.concat(@default_run_orchestrator_parts)
  end

  @spec maybe_send_async_followup(map(), String.t() | nil, String.t() | nil, term()) :: :ok
  def maybe_send_async_followup(%{auto_followup: false}, _task_id, _run_id, _outcome), do: :ok

  def maybe_send_async_followup(followup_context, task_id, run_id, outcome)
      when is_map(followup_context) do
    ensure_terminal_state(task_id, run_id, outcome)
    record = stored_record(task_id)

    if parent_aborted?(followup_context, record) do
      :ok
    else
      # The stored terminal record (first writer wins) is the notice's source,
      # not the caller's outcome, which may have lost a race to cancellation.
      text =
        task_auto_followup_text(
          followup_context,
          task_id,
          run_id,
          stored_outcome(record, outcome)
        )

      AsyncFollowups.enqueue(
        followup_context,
        text,
        %{source: :task, task_id: task_id, run_id: run_id},
        Map.get(followup_context, :async_followup_server, AsyncFollowups)
      )
    end
  rescue
    error ->
      log_auto_followup_failure(task_id, run_id, {:exception, error})
      :ok
  catch
    kind, reason ->
      log_auto_followup_failure(task_id, run_id, {kind, reason})
      :ok
  end

  def maybe_send_async_followup(_followup_context, _task_id, _run_id, _outcome), do: :ok

  @spec task_auto_followup_text(map(), String.t() | nil, String.t() | nil, term()) :: String.t()
  def task_auto_followup_text(_followup_context, task_id, _run_id, outcome) do
    task = task_label(task_id)

    case outcome do
      {:cancelled, _reason} ->
        "#{task} was cancelled."

      outcome ->
        case normalize_followup_outcome(outcome) do
          %{ok: true, answer: answer} when is_binary(answer) ->
            with_answer("#{task} completed.", answer, task_id)

          %{ok: false, error: error, answer: answer} ->
            with_answer("#{task} failed: #{format_error(error)}", answer, task_id)
        end
    end
  end

  defp stored_record(task_id) when is_binary(task_id) and task_id != "" do
    case TaskStore.get_record(task_id) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp stored_record(_task_id), do: nil

  defp stored_outcome(%{status: :completed} = record, _outcome), do: {:ok, record[:result]}
  defp stored_outcome(%{status: :cancelled} = record, _outcome), do: {:cancelled, record[:error]}

  defp stored_outcome(%{status: status} = record, _outcome)
       when status in [:error, :lost, :timeout, :interrupted],
       do: {:error, record[:error]}

  defp stored_outcome(_record, outcome), do: outcome

  # A child cancelled because its parent aborted (or exited) does not wake it.
  defp parent_aborted?(context, %{status: :cancelled}) do
    LemonAgent.AbortSignal.aborted?(context[:parent_signal]) or
      (is_pid(context[:session_pid]) and not Process.alive?(context[:session_pid]))
  end

  defp parent_aborted?(_context, _record), do: false

  # Names the child so a parent with several children in flight can attribute
  # each completion: `Task <name> (<id>) [<persona>]`.
  defp task_label(task_id) when is_binary(task_id) and task_id != "" do
    record =
      case TaskStore.get_record(task_id) do
        {:ok, record} -> record
        _ -> %{}
      end

    name = if present?(record[:name]), do: "#{record[:name]} (#{task_id})", else: task_id
    if present?(record[:role]), do: "Task #{name} [#{record[:role]}]", else: "Task #{name}"
  end

  defp task_label(_task_id), do: "Task"

  defp present?(value), do: is_binary(value) and value != ""

  defp with_answer(header, answer, task_id) do
    case normalize_followup_text(answer) do
      "" -> header
      text -> header <> "\n\n" <> bound_followup_text(text, task_id)
    end
  end

  # Completions enter the parent's context as a message, outside tool-result
  # bounding; long answers keep a head preview and point at the full output.
  defp bound_followup_text(text, task_id) do
    total = String.length(text)

    if total <= @max_inline_followup_chars do
      text
    else
      full = if present?(task_id), do: " Read agent://#{task_id} for the full output.", else: ""

      String.slice(text, 0, @followup_preview_chars) <>
        "\n\n[Output truncated: first #{@followup_preview_chars} of #{total} characters shown.#{full}]"
    end
  end

  defp normalize_followup_text(text) when is_binary(text) do
    try do
      String.trim(text)
    rescue
      ArgumentError -> inspect(text, limit: 200)
    end
  end

  defp normalize_followup_text(_), do: ""

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

  defp normalize_followup_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(other), do: Result.visible_output_text(other)

  defp format_error(reason) when is_binary(reason) do
    if String.length(reason) > @max_error_chars,
      do: String.slice(reason, 0, @max_error_chars) <> "…",
      else: reason
  end

  defp format_error(reason) do
    Logger.warning("Task followup failed: #{inspect(reason)}")
    "The task failed unexpectedly. Run `lemon doctor` before trying again."
  end

  defp log_auto_followup_failure(task_id, run_id, reason) do
    Logger.warning(
      "Task tool failed to auto-followup task_id=#{inspect(task_id)} " <>
        "run_id=#{inspect(run_id)}: #{inspect(reason)}"
    )
  end
end
