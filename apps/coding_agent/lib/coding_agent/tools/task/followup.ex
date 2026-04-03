defmodule CodingAgent.Tools.Task.Followup do
  @moduledoc false

  require Logger

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.AsyncFollowups
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

    engine = Map.get(followup_context, :engine)
    model = Map.get(followup_context, :model)
    role = Map.get(followup_context, :role)

    base = "[task #{task_id}] #{summary}"

    engine_str = build_engine_label(engine, model)
    role_str = if is_binary(role) and role != "", do: " | role: #{role}", else: ""

    paren_content =
      if engine_str != "" or role_str != "" do
        inner = String.trim(String.trim(engine_str) <> " " <> String.trim(role_str))
        " (#{inner})"
      else
        ""
      end

    base = base <> paren_content

    base =
      if is_binary(run_id) and run_id != "" do
        base <> " run=#{short_id(run_id)}"
      else
        base
      end

    duration_str = maybe_task_duration(followup_context, task_id)

    case normalize_followup_outcome(outcome) do
      %{ok: true, answer: answer} when is_binary(answer) ->
        trimmed = String.trim(answer)

        if trimmed == "" do
          "#{base} completed.#{duration_str}"
        else
          "#{base} completed.#{duration_str}\n\n#{answer}"
        end

      %{ok: false, error: error, answer: answer} ->
        trimmed = if is_binary(answer), do: String.trim(answer), else: ""

        if trimmed == "" do
          "#{base} failed: #{format_error(error)}#{duration_str}"
        else
          "#{base} failed: #{format_error(error)}#{duration_str}\n\nPartial output:\n#{answer}"
        end
    end
  end

  defp build_engine_label(nil, _model), do: ""
  defp build_engine_label("internal", _model), do: ""

  defp build_engine_label(engine, model) when is_binary(engine) do
    if is_binary(model) and model != "", do: "#{engine}/#{model}", else: engine
  end

  defp maybe_task_duration(_followup_context, task_id) do
    case CodingAgent.TaskStore.get(task_id) do
      {:ok, record, _events} ->
        started_at = Map.get(record, :started_at)
        completed_at = Map.get(record, :completed_at)

        cond do
          is_integer(started_at) and is_integer(completed_at) ->
            ms = (completed_at - started_at) * 1000
            " #{format_duration(ms)}"

          true ->
            ""
        end

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp short_id(id) when byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id), do: id

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

  defp normalize_followup_answer(%AgentToolResult{} = result),
    do: AgentCore.get_text(result) || ""

  defp normalize_followup_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp normalize_followup_answer(other), do: inspect(other)

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
