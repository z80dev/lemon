defmodule LemonControlPlane.Methods.TaskList do
  @moduledoc false

  import LemonControlPlane.Methods.Params

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{AgentRuntime, Redact}

  @default_limit 100
  @max_limit 200
  @default_event_limit 100
  @max_event_limit 1_000

  # Descriptions, results, errors, reasoning, events and records are content:
  # without `operator.content` the include flags are ignored and every task is
  # reduced to ids, status, counts and timings.
  def handle(params, mode, ctx) when mode in [:active, :recent] do
    params = params || %{}
    content? = Authorize.content?(ctx)

    run_id = get_param(params, "runId")
    agent_id = get_param(params, "agentId")
    status_filter = if mode == :recent, do: get_param(params, "status")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)
    include_events = content? and truthy?(get_param(params, "includeEvents"), false)
    include_record = content? and truthy?(get_param(params, "includeRecord"), false)

    event_limit =
      normalize_limit(get_param(params, "eventLimit"), @default_event_limit, @max_event_limit)

    filters = %{
      "runId" => run_id,
      "agentId" => agent_id,
      "limit" => limit,
      "includeEvents" => include_events,
      "includeRecord" => include_record,
      "eventLimit" => event_limit
    }

    filters = if mode == :recent, do: Map.put(filters, "status", status_filter), else: filters

    case fetch_tasks(
           run_id,
           agent_id,
           limit,
           {content?, include_events, include_record},
           event_limit,
           status_filter,
           mode
         ) do
      {:ok, tasks} -> {:ok, response(tasks, filters, mode, content?)}
      :unavailable -> {:error, Errors.unavailable("Task state is unavailable")}
    end
  end

  defp response(tasks, filters, mode, content?) do
    %{
      "tasks" => tasks,
      "total" => length(tasks),
      "filters" => filters,
      "contentWithheld" => not content?,
      "summary" => summary(tasks, filters, mode)
    }
  end

  defp summary(tasks, filters, mode) do
    %{
      "count" => length(tasks),
      "statusCounts" => count_by(tasks, "status"),
      "engineCounts" => count_by(tasks, "engine"),
      "roleCounts" => count_by(tasks, "role"),
      "agentCount" => unique_count(tasks, "agentId"),
      "runCount" => unique_run_count(tasks),
      "eventCount" => sum_integer(tasks, "eventCount"),
      "reasoningCount" => sum_integer(tasks, "reasoningCount"),
      "filtersApplied" => filters_applied(filters),
      "cleanup" => %{
        "includesTaskEvents" => Enum.any?(tasks, &(Map.get(&1, "events", []) != [])),
        "includesTaskRecords" => Enum.any?(tasks, &Map.has_key?(&1, "record")),
        "includesMessageBodies" => Enum.any?(tasks, &message_body?/1),
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
    |> maybe_add_average(tasks, mode)
  end

  defp maybe_add_average(summary, _tasks, :active), do: summary

  defp maybe_add_average(summary, tasks, :recent) do
    durations =
      tasks |> Enum.map(& &1["durationMs"]) |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    average = if durations == [], do: nil, else: div(Enum.sum(durations), length(durations))
    Map.put(summary, "averageDurationMs", average)
  end

  defp fetch_tasks(
         run_id,
         agent_id,
         limit,
         includes,
         event_limit,
         status_filter,
         mode
       ) do
    with {:ok, task_ids} <- list_task_ids(),
         {:ok, tasks} <- read_tasks(task_ids, includes, event_limit, mode) do
      {:ok,
       tasks
       |> Enum.filter(&(active_status?(&1) == (mode == :active)))
       |> Enum.filter(
         &(mode == :active or status_filter in [nil, ""] or &1["status"] == status_filter)
       )
       |> Enum.filter(&filter_by_run(&1, run_id))
       |> Enum.filter(&filter_by_agent(&1, agent_id))
       |> Enum.sort_by(&task_sort_key(&1, mode), :desc)
       |> Enum.take(limit)}
    end
  end

  defp list_task_ids do
    case AgentRuntime.call(:list_tasks, [], :unavailable) do
      tasks when is_list(tasks) -> {:ok, Enum.map(tasks, fn {task_id, _record} -> task_id end)}
      _unavailable -> :unavailable
    end
  end

  # A task removed between listing and reading is skipped; any other read
  # failure makes the whole list unavailable rather than silently shorter.
  defp read_tasks(task_ids, includes, event_limit, mode) do
    Enum.reduce_while(task_ids, {:ok, []}, fn task_id, {:ok, acc} ->
      case task_from_store(task_id, includes, event_limit, mode) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        :gone -> {:cont, {:ok, acc}}
        :unavailable -> {:halt, :unavailable}
      end
    end)
  end

  defp task_from_store(task_id, {content?, include_events, include_record}, event_limit, mode) do
    case AgentRuntime.call(:get_task, [task_id], :unavailable) do
      {:ok, record, events} when is_map(record) and is_list(events) ->
        status = derive_task_status(record, mode)
        engine = get_map(record, :engine) || infer_engine(record, events)
        started_at = to_ms(get_map(record, :started_at))
        completed_at = to_ms(get_map(record, :completed_at))
        inserted_at = to_ms(get_map(record, :inserted_at))
        updated_at = to_ms(get_map(record, :updated_at))

        duration_ms =
          cond do
            is_integer(completed_at) and is_integer(started_at) -> completed_at - started_at
            is_integer(updated_at) and is_integer(started_at) -> max(updated_at - started_at, 0)
            true -> nil
          end

        {:ok,
         %{
           "taskId" => task_id,
           "parentRunId" => get_map(record, :parent_run_id),
           "runId" => get_map(record, :run_id),
           "sessionKey" => get_map(record, :session_key),
           "agentId" => get_map(record, :agent_id),
           "engine" => engine,
           "role" => get_map(record, :role),
           "status" => status,
           "startedAtMs" => started_at,
           "completedAtMs" => completed_at,
           "durationMs" => duration_ms,
           "createdAtMs" => inserted_at,
           "updatedAtMs" => updated_at,
           "eventCount" => length(events),
           "reasoningCount" => reasoning_count(events)
         }
         |> maybe_put_content(record, events, content?)
         |> maybe_put(
           "events",
           events |> Enum.take(event_limit) |> Enum.map(&Redact.project/1),
           include_events
         )
         |> maybe_put("record", Redact.project(record), include_record)}

      {:error, :not_found} ->
        :gone

      _unavailable ->
        :unavailable
    end
  end

  defp active_status?(%{"status" => status}), do: status in ["active", "queued"]
  defp active_status?(_), do: false

  defp filter_by_run(_task, nil), do: true

  defp filter_by_run(task, run_id) do
    task["runId"] == run_id or task["parentRunId"] == run_id
  end

  defp filter_by_agent(_task, nil), do: true
  defp filter_by_agent(task, agent_id), do: task["agentId"] == agent_id

  defp task_sort_key(task, :recent) do
    task["completedAtMs"] || task["updatedAtMs"] || task["createdAtMs"] || 0
  end

  defp task_sort_key(task, :active) do
    task["startedAtMs"] || task["updatedAtMs"] || task["createdAtMs"] || 0
  end

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
  end

  defp unique_count(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp unique_run_count(tasks) do
    tasks
    |> Enum.flat_map(fn task -> [task["runId"], task["parentRunId"]] end)
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp sum_integer(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp filters_applied(filters) do
    filters
    |> Enum.reject(fn {key, value} ->
      key in ["limit", "eventLimit", "includeEvents", "includeRecord"] or blank?(value)
    end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp derive_task_status(record, mode) do
    status = get_map(record, :status)
    error = get_map(record, :error)

    cond do
      status in [:queued, "queued"] -> "queued"
      status in [:running, "running"] -> "active"
      status in [:completed, "completed"] -> "completed"
      timeout_error?(error) -> "timeout"
      aborted_error?(error, mode) -> "aborted"
      status in [:error, "error"] -> "error"
      true -> if(mode == :active, do: "active", else: "error")
    end
  end

  defp infer_engine(record, events) do
    get_map(record, :engine) ||
      get_map(get_map(record, :details), :engine) ||
      get_map(get_map(record, :meta), :engine) ||
      Enum.find_value(Enum.reverse(events), &extract_engine_from_term/1)
  end

  defp extract_engine_from_term(nil), do: nil

  defp extract_engine_from_term(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> extract_engine_from_term()
  end

  defp extract_engine_from_term(map) when is_map(map) do
    direct =
      get_map(map, :engine) ||
        get_map(get_map(map, :details), :engine) ||
        get_map(get_map(map, :current_action), :engine)

    cond do
      is_binary(direct) and String.trim(direct) != "" ->
        direct

      true ->
        map
        |> Map.values()
        |> Enum.find_value(&extract_engine_from_term/1)
    end
  end

  defp extract_engine_from_term(list) when is_list(list),
    do: Enum.find_value(list, &extract_engine_from_term/1)

  defp extract_engine_from_term(_), do: nil

  defp latest_reasoning(events) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&extract_reasoning_from_term/1)
  end

  defp reasoning_count(events) when is_list(events) do
    Enum.count(events, &(extract_reasoning_from_term(&1) != nil))
  end

  defp extract_reasoning_from_term(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> extract_reasoning_from_term()
  end

  defp extract_reasoning_from_term(map) when is_map(map) do
    reasoning =
      get_map(map, :reasoning) ||
        get_map(get_map(map, :details), :reasoning)

    case normalize_reasoning(reasoning) do
      nil ->
        map
        |> Map.values()
        |> Enum.find_value(&extract_reasoning_from_term/1)

      normalized ->
        normalized
    end
  end

  defp extract_reasoning_from_term(list) when is_list(list),
    do: Enum.find_value(list, &extract_reasoning_from_term/1)

  defp extract_reasoning_from_term(_), do: nil

  defp normalize_reasoning(reasoning) when is_map(reasoning) do
    text = get_map(reasoning, :text)

    if is_binary(text) and String.trim(text) != "" do
      %{
        "text" => Redact.project(text),
        "source" => Redact.project(get_map(reasoning, :source)),
        "phase" => Redact.project(get_map(reasoning, :phase))
      }
    end
  end

  defp normalize_reasoning(_), do: nil

  defp timeout_error?(error) do
    cond do
      error in [:timeout, "timeout"] -> true
      is_map(error) and get_map(error, :error) in [:timeout, "timeout"] -> true
      is_binary(error) and String.contains?(String.downcase(error), "timeout") -> true
      true -> false
    end
  end

  defp aborted_error?(error, :recent), do: LemonControlPlane.Methods.RunOutcome.aborted?(error)

  defp aborted_error?(error, :active) do
    cond do
      error in [
        :aborted,
        :user_requested,
        :interrupted,
        "aborted",
        "user_requested",
        "interrupted"
      ] ->
        true

      is_map(error) and
          get_map(error, :error) in [
            :aborted,
            :user_requested,
            :interrupted,
            "aborted",
            "user_requested",
            "interrupted"
          ] ->
        true

      is_binary(error) and String.contains?(String.downcase(error), "abort") ->
        true

      true ->
        false
    end
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp maybe_put_content(task, _record, _events, false), do: task

  defp maybe_put_content(task, record, events, true) do
    Map.merge(task, %{
      "description" => Redact.project(get_map(record, :description)),
      "error" => Redact.project(get_map(record, :error)),
      "result" => Redact.project(get_map(record, :result)),
      "latestReasoning" => latest_reasoning(events)
    })
  end

  defp message_body?(task) do
    Map.get(task, "events", []) != [] or Map.has_key?(task, "record") or
      Enum.any?(["description", "error", "result", "latestReasoning"], &(not is_nil(task[&1])))
  end
end
