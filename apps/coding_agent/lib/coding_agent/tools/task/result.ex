defmodule CodingAgent.Tools.Task.Result do
  @moduledoc false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskStore

  @max_structured_join_output_bytes 4096

  @spec do_poll(map()) :: AgentToolResult.t() | {:error, String.t()}
  def do_poll(params) do
    task_id = Map.get(params, "task_id")

    if is_binary(task_id) do
      case TaskStore.get(task_id) do
        {:ok, record, events} ->
          build_poll_result(task_id, record, events)

        {:error, :not_found} ->
          {:error, "Unknown task_id: #{task_id}"}
      end
    else
      {:error, "task_id is required for action=poll"}
    end
  end

  @spec do_join(map()) :: AgentToolResult.t() | {:error, String.t()}
  def do_join(params) do
    with {:ok, task_ids} <- validate_join_task_ids(params),
         {:ok, mode} <- validate_join_mode(params),
         :ok <- suppress_auto_followups(task_ids),
         {:ok, run_ids} <- resolve_run_ids(task_ids),
         {:ok, join_result} <- RunGraph.await(run_ids, mode, :infinity) do
      build_join_result(task_ids, join_result)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_async_result(String.t(), String.t(), String.t() | nil) :: AgentToolResult.t()
  def build_async_result(task_id, description, run_id) do
    %AgentToolResult{
      content: [
        %TextContent{
          text:
            "Task queued: #{description} (#{task_id})\n" <>
              "If you need this result before you answer, call task again with action=join and " <>
              "task_ids=[\"#{task_id}\"] (or include this id in a larger task_ids list)."
        }
      ],
      details: %{
        task_id: task_id,
        status: "queued",
        description: description,
        run_id: run_id
      }
    }
  end

  @spec build_update_content(String.t() | nil, String.t() | nil) :: [TextContent.t()]
  def build_update_content(text, thinking) do
    text = text || ""
    thinking = truncate_thinking(thinking || "")

    base =
      if text != "" do
        [%TextContent{text: text}]
      else
        []
      end

    if thinking != "" do
      prefix = if text != "", do: "\n[thinking] ", else: "[thinking] "
      base ++ [%TextContent{text: prefix <> thinking}]
    else
      base
    end
  end

  @spec extract_final_payload([term()], String.t() | nil, String.t() | nil) :: map()
  def extract_final_payload(messages, fallback_text, fallback_thinking) do
    messages
    |> Enum.filter(&match?(%Ai.Types.AssistantMessage{}, &1))
    |> List.last()
    |> case do
      nil ->
        %{text: fallback_text || "", thinking: fallback_thinking || ""}

      msg ->
        %{text: Ai.get_text(msg), thinking: Ai.get_thinking(msg)}
    end
  end

  @spec extract_text(term()) :: String.t() | nil
  def extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  def extract_text(_), do: nil

  @spec build_result_preview(term()) :: String.t()
  def build_result_preview(%AgentToolResult{content: content}), do: extract_text(content)
  def build_result_preview(result) when is_binary(result), do: result
  def build_result_preview(result), do: inspect(result, limit: 100)

  @spec normalize_join_mode(term()) :: :wait_all | :wait_any
  def normalize_join_mode(nil), do: :wait_all
  def normalize_join_mode("wait_all"), do: :wait_all
  def normalize_join_mode("wait_any"), do: :wait_any
  def normalize_join_mode(:wait_all), do: :wait_all
  def normalize_join_mode(:wait_any), do: :wait_any
  def normalize_join_mode(_), do: :wait_all

  defp validate_join_task_ids(params) do
    task_ids = Map.get(params, "task_ids") || Map.get(params, "task_id")

    task_ids =
      cond do
        is_binary(task_ids) -> [task_ids]
        is_list(task_ids) -> task_ids
        true -> []
      end

    cond do
      task_ids == [] ->
        {:error, "task_ids is required for action=join"}

      not Enum.all?(task_ids, &is_binary/1) ->
        {:error, "task_ids must be a list of strings"}

      true ->
        {:ok, task_ids}
    end
  end

  defp validate_join_mode(params) do
    {:ok, Map.get(params, "mode") |> normalize_join_mode()}
  end

  defp suppress_auto_followups(task_ids) do
    Enum.each(task_ids, &TaskStore.suppress_auto_followup/1)
    :ok
  end

  defp build_poll_result(task_id, record, events) do
    status = Map.get(record, :status, :unknown)
    current_action = latest_event_current_action(events)
    action_detail = latest_event_action_detail(events, Map.get(record, :run_id))
    engine = latest_event_engine(events) || Map.get(record, :engine)

    {content, details} =
      case status do
        :completed ->
          case Map.get(record, :result) do
            %AgentToolResult{} = result ->
              {result.content,
               %{
                 task_id: task_id,
                 status: "completed",
                 result: result,
                 events: Enum.take(events, -5)
               }}

            other ->
              {[%TextContent{text: "Task completed."}],
               %{
                 task_id: task_id,
                 status: "completed",
                 result: other,
                 events: Enum.take(events, -5)
               }}
          end

        :error ->
          error = Map.get(record, :error)

          {[%TextContent{text: "Task error: #{inspect(error)}"}],
           %{
             task_id: task_id,
             status: "error",
             error: error,
             events: Enum.take(events, -5)
           }}

        _ ->
          text = latest_event_text(events) || "Task status: #{status}"

          {[%TextContent{text: text}],
           %{
             task_id: task_id,
             status: to_string(status),
             events: Enum.take(events, -5)
           }}
      end

    details =
      case Map.get(record, :run_id) do
        nil -> details
        run_id -> Map.put(details, :run_id, run_id)
      end

    details =
      if is_map(current_action),
        do: Map.put(details, :current_action, current_action),
        else: details

    details =
      if is_map(action_detail), do: Map.put(details, :action_detail, action_detail), else: details

    details =
      if is_binary(engine) and engine != "", do: Map.put(details, :engine, engine), else: details

    %AgentToolResult{content: content, details: details}
  end

  defp latest_event_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AgentToolResult{content: content} -> extract_text(content)
      %{content: content} -> extract_text(content)
      _ -> nil
    end)
  end

  defp latest_event_current_action(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AgentToolResult{details: details} when is_map(details) ->
        Map.get(details, :current_action) || Map.get(details, "current_action")

      %{details: details} when is_map(details) ->
        Map.get(details, :current_action) || Map.get(details, "current_action")

      _ ->
        nil
    end)
  end

  defp latest_event_action_detail(events, child_run_id) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AgentToolResult{details: details} when is_map(details) ->
        details |> extract_action_detail() |> maybe_put_child_run_id(child_run_id)

      %{details: details} when is_map(details) ->
        details |> extract_action_detail() |> maybe_put_child_run_id(child_run_id)

      _ ->
        nil
    end)
  end

  defp latest_event_engine(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AgentToolResult{details: details} when is_map(details) ->
        Map.get(details, :engine) || Map.get(details, "engine")

      %{details: details} when is_map(details) ->
        Map.get(details, :engine) || Map.get(details, "engine")

      _ ->
        nil
    end)
  end

  defp extract_action_detail(details) when is_map(details) do
    action_detail = Map.get(details, :action_detail) || Map.get(details, "action_detail")
    if is_map(action_detail), do: action_detail, else: nil
  end

  defp maybe_put_child_run_id(action_detail, child_run_id)
       when is_map(action_detail) and is_binary(child_run_id) do
    Map.put_new(action_detail, :child_run_id, child_run_id)
  end

  defp maybe_put_child_run_id(action_detail, _child_run_id), do: action_detail

  defp resolve_run_ids(task_ids) do
    run_ids =
      Enum.reduce_while(task_ids, [], fn task_id, acc ->
        case TaskStore.get(task_id) do
          {:ok, record, _events} ->
            run_id = Map.get(record, :run_id)

            if is_binary(run_id) do
              {:cont, [run_id | acc]}
            else
              {:halt, {:error, "Task #{task_id} is missing a run_id"}}
            end

          {:error, :not_found} ->
            {:halt, {:error, "Unknown task_id: #{task_id}"}}
        end
      end)

    case run_ids do
      {:error, _} = err -> err
      ids -> {:ok, Enum.reverse(ids)}
    end
  end

  defp build_join_result(task_ids, %{mode: :wait_all, runs: runs}) do
    summary = join_summary_text(runs)
    structured = join_structured_text(runs)

    %AgentToolResult{
      content: [
        %TextContent{text: "Joined #{length(task_ids)} task(s)." <> structured <> summary}
      ],
      details: %{
        status: "completed",
        mode: "wait_all",
        task_ids: task_ids,
        runs: runs
      }
    }
  end

  defp build_join_result(task_ids, %{mode: :wait_any, run: run}) do
    summary = join_summary_text([run])
    structured = join_structured_text([run])

    %AgentToolResult{
      content: [%TextContent{text: "One task completed." <> structured <> summary}],
      details: %{
        status: "completed",
        mode: "wait_any",
        task_ids: task_ids,
        run: run
      }
    }
  end

  defp truncate_thinking(thinking) do
    max_len = 240
    trimmed = String.trim(thinking)

    cond do
      trimmed == "" ->
        ""

      String.length(trimmed) > max_len ->
        "..." <> String.slice(trimmed, -max_len, max_len)

      true ->
        trimmed
    end
  end

  defp join_summary_text(runs) when is_list(runs) do
    lines =
      runs
      |> Enum.map(&join_summary_line/1)
      |> Enum.reject(&is_nil/1)

    if lines == [], do: "", else: "\n" <> Enum.join(lines, "\n")
  end

  defp join_summary_text(_), do: ""

  defp join_structured_text(runs) when is_list(runs) do
    payload =
      runs
      |> Enum.map(&join_structured_entry/1)
      |> Jason.encode!()

    "\nTASK_RESULTS_JSON: " <> payload
  rescue
    _ -> ""
  end

  defp join_structured_text(_), do: ""

  defp join_summary_line(%{description: description, status: :completed, result: result} = run) do
    preview =
      result
      |> build_result_preview()
      |> truncate_join_preview()

    base = join_summary_prefix(run, description)
    "#{base}completed: #{preview}"
  end

  defp join_summary_line(%{description: description, status: :error, error: error} = run) do
    preview =
      error
      |> inspect(limit: 40)
      |> truncate_join_preview()

    base = join_summary_prefix(run, description)
    "#{base}error: #{preview}"
  end

  defp join_summary_line(%{description: description, status: status} = run) do
    base = join_summary_prefix(run, description)
    "#{base}status: #{status}"
  end

  defp join_summary_line(_), do: nil

  defp join_structured_entry(%{description: description, status: :completed, result: result} = run) do
    %{
      description: description || run[:id] || "task",
      status: "completed",
      output: join_structured_output(result)
    }
  end

  defp join_structured_entry(%{description: description, status: :error, error: error} = run) do
    %{
      description: description || run[:id] || "task",
      status: "error",
      error: inspect(error, limit: 80)
    }
  end

  defp join_structured_entry(%{description: description, status: status} = run) do
    %{
      description: description || run[:id] || "task",
      status: to_string(status)
    }
  end

  defp join_structured_entry(_run), do: %{description: "task", status: "unknown"}

  defp join_summary_prefix(run, description) do
    label =
      description ||
        run[:id] ||
        "task"

    "- #{label}: "
  end

  defp truncate_join_preview(text) when is_binary(text) do
    text = String.trim(text)
    max_len = 240

    cond do
      text == "" -> "(empty)"
      String.length(text) > max_len -> String.slice(text, 0, max_len) <> "..."
      true -> text
    end
  end

  defp truncate_join_preview(other), do: inspect(other, limit: 40)

  defp join_structured_output(%AgentToolResult{content: content}) do
    content
    |> extract_text()
    |> truncate_structured_join_output()
  end

  defp join_structured_output(result) when is_binary(result) do
    truncate_structured_join_output(result)
  end

  defp join_structured_output(result) do
    result
    |> inspect(limit: 80)
    |> truncate_structured_join_output()
  end

  defp truncate_structured_join_output(text) when is_binary(text) do
    cond do
      text == "" ->
        ""

      byte_size(text) <= @max_structured_join_output_bytes ->
        text

      true ->
        binary_part(text, 0, @max_structured_join_output_bytes) <> "..."
    end
  end
end
