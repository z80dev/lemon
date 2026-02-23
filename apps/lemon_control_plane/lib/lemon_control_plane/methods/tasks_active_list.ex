defmodule LemonControlPlane.Methods.TasksActiveList do
  @moduledoc """
  Handler for the `tasks.active.list` method.

  Lists active subagent/task records. Checks introspection for recent task
  start events not yet associated with a completion event.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 50
  @max_limit 200

  @impl true
  def name, do: "tasks.active.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    run_id = get_param(params, "runId")
    agent_id = get_param(params, "agentId")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)

    tasks = fetch_active_tasks(run_id, agent_id, limit)

    {:ok,
     %{
       "tasks" => tasks,
       "total" => length(tasks),
       "filters" => %{
         "runId" => run_id,
         "agentId" => agent_id,
         "limit" => limit
       }
     }}
  rescue
    _ ->
      {:ok,
       %{
         "tasks" => [],
         "total" => 0,
         "filters" => %{"runId" => nil, "agentId" => nil, "limit" => @default_limit}
       }}
  end

  defp fetch_active_tasks(run_id, agent_id, limit) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
      query_opts =
        [event_type: :task_started, limit: limit * 2]
        |> maybe_add_opt(:run_id, run_id)
        |> maybe_add_opt(:agent_id, agent_id)

      started_events = LemonCore.Introspection.list(query_opts)

      completed_query_opts =
        [event_type: :task_completed, limit: limit * 2]
        |> maybe_add_opt(:run_id, run_id)
        |> maybe_add_opt(:agent_id, agent_id)

      completed_task_ids =
        LemonCore.Introspection.list(completed_query_opts)
        |> Enum.map(&get_task_id/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      started_events
      |> Enum.map(&format_task_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(fn task -> MapSet.member?(completed_task_ids, task["taskId"]) end)
      |> Enum.take(limit)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp get_task_id(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    payload[:task_id] || payload["task_id"]
  end

  defp get_task_id(_), do: nil

  defp format_task_event(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    task_id = payload[:task_id] || payload["task_id"]

    %{
      "taskId" => task_id,
      "parentRunId" => payload[:parent_run_id] || payload["parent_run_id"],
      "runId" => event[:run_id] || event["run_id"],
      "sessionKey" => event[:session_key] || event["session_key"],
      "agentId" => event[:agent_id] || event["agent_id"],
      "startedAtMs" => event[:ts_ms] || event["ts_ms"],
      "status" => "active"
    }
  end

  defp format_task_event(_), do: nil

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
