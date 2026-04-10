defmodule CodingAgent.Tools.Task.Result do
  @moduledoc false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskStore

  @max_poll_preview_chars 500

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

  @spec do_get(map()) :: AgentToolResult.t() | {:error, String.t()}
  def do_get(params) do
    task_id = Map.get(params, "task_id")

    if is_binary(task_id) do
      case TaskStore.get(task_id) do
        {:ok, record, events} ->
          build_get_result(task_id, record, events)

        {:error, :not_found} ->
          {:error, "Unknown task_id: #{task_id}"}
      end
    else
      {:error, "task_id is required for action=get"}
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
      content: [%TextContent{text: "Task queued: #{task_id}"}],
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

  @spec visible_output_text(term()) :: String.t()
  def visible_output_text(result) when is_binary(result), do: safe_to_string(result)

  def visible_output_text(%AgentToolResult{content: content}) do
    visible_content_text(content)
  end

  def visible_output_text(%{answer: answer}) when is_binary(answer), do: safe_to_string(answer)

  def visible_output_text(%{"answer" => answer}) when is_binary(answer),
    do: safe_to_string(answer)

  def visible_output_text(other), do: inspect(other, limit: 500)

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

    {content_text, preview} =
      case status do
        :completed ->
          preview =
            Map.get(record, :result)
            |> visible_output_text()
            |> truncate_poll_preview()

          {poll_content_text(status, preview, Map.get(record, :error)), preview}

        :error ->
          {poll_content_text(status, nil, Map.get(record, :error)), nil}

        _ ->
          {nonterminal_content_text(status, events), nil}
      end

    details =
      record
      |> base_task_details(task_id)
      |> maybe_put_current_action(current_action)
      |> maybe_put_preview(preview)
      |> maybe_put_error(Map.get(record, :error))

    %AgentToolResult{
      content: [%TextContent{text: content_text}],
      details: details
    }
  end

  defp build_get_result(task_id, record, events) do
    status = Map.get(record, :status, :unknown)
    result = Map.get(record, :result)
    error = Map.get(record, :error)

    content_text =
      case status do
        :completed ->
          case visible_output_text(result) do
            "" -> "Task completed."
            text -> text
          end

        :error ->
          "Task failed: #{format_error(error)}"

        other_status ->
          nonterminal_content_text(other_status, events)
      end

    details =
      record
      |> base_task_details(task_id)
      |> maybe_put_current_action(latest_event_current_action(events))
      |> maybe_put_error(error)

    %AgentToolResult{content: [%TextContent{text: content_text}], details: details}
  end

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
    tasks = join_tasks(task_ids, runs)

    %AgentToolResult{
      content: [%TextContent{text: join_tasks_text(tasks)}],
      details: %{
        status: "completed",
        mode: "wait_all",
        task_ids: task_ids,
        tasks: join_task_details(tasks)
      }
    }
  end

  defp build_join_result(task_ids, %{mode: :wait_any, run: run}) do
    task = join_task_for_run(task_ids, run)

    %AgentToolResult{
      content: [%TextContent{text: join_tasks_text([task])}],
      details: %{
        status: "completed",
        mode: "wait_any",
        task_ids: task_ids,
        tasks: join_task_details([task])
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

  defp join_tasks(task_ids, runs) do
    runs_by_id =
      Map.new(runs, fn run ->
        {run[:id], run}
      end)

    Enum.map(task_ids, fn task_id ->
      case TaskStore.get(task_id) do
        {:ok, record, _events} ->
          build_join_task(task_id, record, Map.get(runs_by_id, Map.get(record, :run_id), %{}))

        {:error, :not_found} ->
          %{
            task_id: task_id,
            status: "unknown",
            output: "",
            error: "Unknown task_id: #{task_id}"
          }
      end
    end)
  end

  defp join_task_for_run(task_ids, run) do
    Enum.find_value(task_ids, fn task_id ->
      case TaskStore.get(task_id) do
        {:ok, record, _events} ->
          if Map.get(record, :run_id) == run[:id] do
            build_join_task(task_id, record, run)
          end

        {:error, :not_found} ->
          nil
      end
    end) ||
      build_join_task(nil, %{}, run)
  end

  defp build_join_task(task_id, record, run) do
    status = run[:status] || Map.get(record, :status, :unknown)

    %{
      task_id: task_id,
      run_id: Map.get(record, :run_id) || run[:id],
      description: Map.get(record, :description) || run[:description],
      engine: Map.get(record, :engine),
      status: to_string(status),
      output: join_output_for_status(status, run),
      error: join_error_for_status(status, run)
    }
  end

  defp join_output_for_status(:completed, run), do: visible_output_text(run[:result])
  defp join_output_for_status("completed", run), do: visible_output_text(run[:result])
  defp join_output_for_status(_, _run), do: ""

  defp join_error_for_status(:error, run), do: format_error(run[:error])
  defp join_error_for_status("error", run), do: format_error(run[:error])
  defp join_error_for_status(_, _run), do: nil

  defp join_tasks_text(tasks) do
    tasks
    |> Enum.map(&join_task_text/1)
    |> Enum.join("\n\n")
  end

  defp join_task_text(task) do
    metadata_lines =
      [
        {"description", Map.get(task, :description) || "task"},
        {"task_id", Map.get(task, :task_id)},
        {"run_id", Map.get(task, :run_id)},
        {"engine", Map.get(task, :engine)},
        {"status", Map.get(task, :status)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)

    body =
      case Map.get(task, :status) do
        "completed" ->
          case Map.get(task, :output) do
            nil -> ""
            "" -> ""
            output -> output
          end

        "error" ->
          "Task failed: #{Map.get(task, :error)}"

        status ->
          "Task status: #{status}"
      end

    Enum.join(metadata_lines, "\n") <>
      if(body == "", do: "", else: "\n\n" <> body)
  end

  defp join_task_details(tasks) do
    Enum.map(tasks, fn task ->
      task
      |> Map.take([:task_id, :run_id, :description, :engine, :status])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    end)
  end

  # Safely converts binary to UTF-8 string, handling non-UTF8 data.
  # Returns "" on failure so downstream String functions never raise.
  defp safe_to_string(binary) when is_binary(binary) do
    String.trim(binary)
  rescue
    ArgumentError -> inspect(binary, limit: 200)
  end

  defp safe_to_string(other), do: inspect(other, limit: 200)

  defp visible_content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %TextContent{text: text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.reject(&thinking_marker_text?/1)
    |> Enum.join("")
    |> safe_to_string()
  end

  defp visible_content_text(_), do: ""

  defp thinking_marker_text?(text) when is_binary(text) do
    text
    |> String.trim_leading()
    |> String.starts_with?("[thinking]")
  rescue
    _ -> false
  end

  defp base_task_details(record, task_id) do
    %{
      task_id: task_id,
      status: Map.get(record, :status, :unknown) |> to_string(),
      description: Map.get(record, :description),
      engine: Map.get(record, :engine),
      run_id: Map.get(record, :run_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp maybe_put_preview(details, nil), do: details
  defp maybe_put_preview(details, ""), do: details
  defp maybe_put_preview(details, preview), do: Map.put(details, :preview, preview)

  defp maybe_put_current_action(details, nil), do: details
  defp maybe_put_current_action(details, current_action), do: Map.put(details, :current_action, current_action)

  defp maybe_put_error(details, nil), do: details
  defp maybe_put_error(details, error), do: Map.put(details, :error, format_error(error))

  defp poll_content_text(:completed, preview, _error) when preview in [nil, ""],
    do: "Status: completed"

  defp poll_content_text(:completed, preview, _error), do: "Status: completed\n#{preview}"
  defp poll_content_text(:error, _preview, error), do: "Status: error\n#{format_error(error)}"

  defp poll_content_text(status, preview, _error) when preview in [nil, ""] do
    "Status: #{status}"
  end

  defp poll_content_text(status, preview, _error), do: "Status: #{status}\n#{preview}"

  defp nonterminal_content_text(status, events) do
    action = latest_event_current_action(events)

    case action_kind(action) do
      nil -> "Task status: #{status}"
      kind -> "Task status: #{status}\nCurrent action: #{kind}"
    end
  end

  defp latest_event_current_action(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AgentToolResult{details: details} when is_map(details) ->
        normalize_current_action(details[:current_action] || details["current_action"])

      %{details: details} when is_map(details) ->
        normalize_current_action(details[:current_action] || details["current_action"])

      _ ->
        nil
    end)
  end

  defp normalize_current_action(%{title: title, kind: kind, phase: phase})
       when is_binary(title) and title != "" and is_binary(kind) and kind != "" and
              is_binary(phase) and phase != "" do
    %{title: title, kind: kind, phase: phase}
  end

  defp normalize_current_action(%{"title" => title, "kind" => kind, "phase" => phase})
       when is_binary(title) and title != "" and is_binary(kind) and kind != "" and
              is_binary(phase) and phase != "" do
    %{title: title, kind: kind, phase: phase}
  end

  defp normalize_current_action(_), do: nil

  defp action_kind(%{kind: kind}) when is_binary(kind) and kind != "", do: kind
  defp action_kind(_), do: nil

  defp truncate_poll_preview(nil), do: nil

  defp truncate_poll_preview(text) when is_binary(text) do
    text = safe_to_string(text)

    cond do
      text == "" ->
        nil

      String.length(text) > @max_poll_preview_chars ->
        String.slice(text, 0, @max_poll_preview_chars) <> "..."

      true ->
        text
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
