defmodule LemonControlPlane.Methods.TasksRecentList do
  @moduledoc """
  Handler for the `tasks.recent.list` method.

  Lists recent completed/error/timeout/aborted tasks using `LemonCore.Introspection.list/1`.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 50
  @max_limit 200

  @impl true
  def name, do: "tasks.recent.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    run_id = get_param(params, "runId")
    agent_id = get_param(params, "agentId")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)
    status_filter = get_param(params, "status")

    tasks = fetch_recent_tasks(run_id, agent_id, limit, status_filter)

    {:ok,
     %{
       "tasks" => tasks,
       "total" => length(tasks),
       "filters" => %{
         "runId" => run_id,
         "agentId" => agent_id,
         "limit" => limit,
         "status" => status_filter
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
           "limit" => @default_limit,
           "status" => nil
         }
       }}
  end

  defp fetch_recent_tasks(run_id, agent_id, limit, status_filter) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
      query_opts =
        [event_type: :task_completed, limit: limit]
        |> maybe_add_opt(:run_id, run_id)
        |> maybe_add_opt(:agent_id, agent_id)

      LemonCore.Introspection.list(query_opts)
      |> Enum.map(&format_task_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&filter_by_status(&1, status_filter))
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp format_task_event(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    ok = payload[:ok] || payload["ok"]
    error = payload[:error] || payload["error"]
    duration_ms = payload[:duration_ms] || payload["duration_ms"]

    status =
      cond do
        error == :timeout -> "timeout"
        error in [:user_requested, :interrupted, :aborted] -> "aborted"
        ok == true -> "completed"
        true -> "error"
      end

    ts_ms = event[:ts_ms] || event["ts_ms"]

    started_at_ms =
      if is_integer(ts_ms) and is_integer(duration_ms) and duration_ms >= 0 do
        ts_ms - duration_ms
      else
        nil
      end

    %{
      "taskId" => get_in_payload(payload, [:task_id, "task_id"]),
      "parentRunId" => get_in_payload(payload, [:parent_run_id, "parent_run_id"]),
      "runId" => event[:run_id] || event["run_id"],
      "sessionKey" => event[:session_key] || event["session_key"],
      "agentId" => event[:agent_id] || event["agent_id"],
      "startedAtMs" => started_at_ms,
      "completedAtMs" => ts_ms,
      "status" => status,
      "durationMs" => duration_ms
    }
  end

  defp format_task_event(_), do: nil

  defp get_in_payload(payload, [key | rest]) when is_map(payload) do
    case Map.get(payload, key) do
      nil -> get_in_payload(payload, rest)
      value -> value
    end
  end

  defp get_in_payload(_payload, []), do: nil

  defp filter_by_status(_task, nil), do: true
  defp filter_by_status(nil, _filter), do: false
  defp filter_by_status(%{"status" => status}, filter), do: status == filter
  defp filter_by_status(_, _), do: false

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
