defmodule CodingAgent.Tools.Task.Result do
  @moduledoc false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskStore

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
      content: [%TextContent{text: "Task queued: #{description} (#{task_id})"}],
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

  defp build_poll_result(task_id, record, events) do
    status = Map.get(record, :status, :unknown)

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
    %AgentToolResult{
      content: [%TextContent{text: "Joined #{length(task_ids)} task(s)."}],
      details: %{
        status: "completed",
        mode: "wait_all",
        task_ids: task_ids,
        runs: runs
      }
    }
  end

  defp build_join_result(task_ids, %{mode: :wait_any, run: run}) do
    %AgentToolResult{
      content: [%TextContent{text: "One task completed."}],
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
end
