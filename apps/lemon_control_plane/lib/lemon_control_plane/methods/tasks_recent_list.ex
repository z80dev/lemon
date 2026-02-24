defmodule LemonControlPlane.Methods.TasksRecentList do
  @moduledoc """
  Handler for `tasks.recent.list`.

  Lists completed/error/timeout/aborted task records with TaskStore internals.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 100
  @max_limit 200
  @default_event_limit 100
  @max_event_limit 1_000

  @impl true
  def name, do: "tasks.recent.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    run_id = get_param(params, "runId")
    agent_id = get_param(params, "agentId")
    status_filter = get_param(params, "status")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)
    include_events = truthy?(get_param(params, "includeEvents"), false)
    include_record = truthy?(get_param(params, "includeRecord"), false)

    event_limit =
      normalize_limit(get_param(params, "eventLimit"), @default_event_limit, @max_event_limit)

    tasks =
      fetch_recent_tasks(
        run_id,
        agent_id,
        limit,
        status_filter,
        include_events,
        include_record,
        event_limit
      )

    {:ok,
     %{
       "tasks" => tasks,
       "total" => length(tasks),
       "filters" => %{
         "runId" => run_id,
         "agentId" => agent_id,
         "status" => status_filter,
         "limit" => limit,
         "includeEvents" => include_events,
         "includeRecord" => include_record,
         "eventLimit" => event_limit
       }
     }}
  rescue
    _ ->
      {:ok,
       %{
         "tasks" => [],
         "total" => 0,
         "filters" => %{
           "runId" => nil,
           "agentId" => nil,
           "status" => nil,
           "limit" => @default_limit,
           "includeEvents" => false,
           "includeRecord" => false,
           "eventLimit" => @default_event_limit
         }
       }}
  end

  defp fetch_recent_tasks(
         run_id,
         agent_id,
         limit,
         status_filter,
         include_events,
         include_record,
         event_limit
       ) do
    if Code.ensure_loaded?(CodingAgent.TaskStore) do
      CodingAgent.TaskStore.list(:all)
      |> Enum.map(fn {task_id, _record} ->
        task_from_store(task_id, include_events, include_record, event_limit)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&active_status?/1)
      |> Enum.filter(&filter_by_run(&1, run_id))
      |> Enum.filter(&filter_by_agent(&1, agent_id))
      |> Enum.filter(&filter_by_status(&1, status_filter))
      |> Enum.sort_by(&task_sort_key/1, :desc)
      |> Enum.take(limit)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp task_from_store(task_id, include_events, include_record, event_limit) do
    case CodingAgent.TaskStore.get(task_id) do
      {:ok, record, events} ->
        status = derive_task_status(record)
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

        %{
          "taskId" => task_id,
          "parentRunId" => get_map(record, :parent_run_id),
          "runId" => get_map(record, :run_id),
          "sessionKey" => get_map(record, :session_key),
          "agentId" => get_map(record, :agent_id),
          "description" => get_map(record, :description),
          "engine" => engine,
          "role" => get_map(record, :role),
          "status" => status,
          "startedAtMs" => started_at,
          "completedAtMs" => completed_at,
          "durationMs" => duration_ms,
          "createdAtMs" => inserted_at,
          "updatedAtMs" => updated_at,
          "error" => serialize_term(get_map(record, :error)),
          "result" => serialize_term(get_map(record, :result)),
          "eventCount" => length(events)
        }
        |> maybe_put(
          "events",
          events |> Enum.take(event_limit) |> Enum.map(&serialize_term/1),
          include_events
        )
        |> maybe_put("record", serialize_term(record), include_record)

      {:error, :not_found} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp active_status?(%{"status" => status}), do: status in ["active", "queued"]
  defp active_status?(_), do: false

  defp filter_by_run(_task, nil), do: true

  defp filter_by_run(task, run_id) do
    task["runId"] == run_id or task["parentRunId"] == run_id
  end

  defp filter_by_agent(_task, nil), do: true
  defp filter_by_agent(task, agent_id), do: task["agentId"] == agent_id

  defp filter_by_status(_task, nil), do: true
  defp filter_by_status(_task, ""), do: true
  defp filter_by_status(task, filter), do: task["status"] == filter

  defp task_sort_key(task) do
    task["completedAtMs"] || task["updatedAtMs"] || task["createdAtMs"] || 0
  end

  defp derive_task_status(record) do
    status = get_map(record, :status)
    error = get_map(record, :error)

    cond do
      status in [:queued, "queued"] -> "queued"
      status in [:running, "running"] -> "active"
      status in [:completed, "completed"] -> "completed"
      timeout_error?(error) -> "timeout"
      aborted_error?(error) -> "aborted"
      status in [:error, "error"] -> "error"
      true -> "error"
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

  defp timeout_error?(error) do
    cond do
      error in [:timeout, "timeout"] -> true
      is_map(error) and get_map(error, :error) in [:timeout, "timeout"] -> true
      is_binary(error) and String.contains?(String.downcase(error), "timeout") -> true
      true -> false
    end
  end

  defp aborted_error?(error) do
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

  defp serialize_term(value, depth \\ 0)
  defp serialize_term(_value, depth) when depth >= 7, do: "[max_depth]"

  defp serialize_term(%{__struct__: mod} = struct, depth) do
    struct
    |> Map.from_struct()
    |> Map.put("__struct__", inspect(mod))
    |> serialize_term(depth + 1)
  end

  defp serialize_term(value, depth) when is_map(value) do
    Enum.reduce(value, %{}, fn {k, v}, acc ->
      Map.put(acc, key_to_string(k), serialize_term(v, depth + 1))
    end)
  end

  defp serialize_term(value, depth) when is_list(value),
    do: Enum.map(value, &serialize_term(&1, depth + 1))

  defp serialize_term(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&serialize_term(&1, depth + 1))

  defp serialize_term(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp serialize_term(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp serialize_term(value, _depth), do: value

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp get_map(nil, _key), do: nil

  defp get_map(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp get_map(_map, _key), do: nil

  defp to_ms(nil), do: nil
  defp to_ms(ms) when is_integer(ms) and ms > 9_999_999_999, do: ms
  defp to_ms(sec) when is_integer(sec), do: sec * 1000
  defp to_ms(_), do: nil

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(value, _default) when value in ["true", "TRUE", "1", 1, "yes", "on"], do: true
  defp truthy?(value, _default) when value in ["false", "FALSE", "0", 0, "no", "off"], do: false
  defp truthy?(_value, default), do: default

  defp normalize_limit(limit, _default, max) when is_integer(limit) and limit > 0,
    do: min(limit, max)

  defp normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, max)
      _ -> default
    end
  end

  defp normalize_limit(_, default, _), do: default

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
