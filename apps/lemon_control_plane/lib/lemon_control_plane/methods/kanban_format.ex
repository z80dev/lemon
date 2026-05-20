defmodule LemonControlPlane.Methods.KanbanFormat do
  @moduledoc false

  def board(%{} = board) when map_size(board) == 0, do: nil

  def board(board) do
    %{
      "id" => board.id,
      "name" => board.name,
      "status" => board.status,
      "workspace" => board.workspace,
      "owner" => board.owner,
      "columns" => board.columns,
      "createdAtMs" => board.created_at_ms,
      "updatedAtMs" => board.updated_at_ms,
      "archivedAtMs" => board.archived_at_ms,
      "meta" => board.meta
    }
  end

  def task(%{} = task) when map_size(task) == 0, do: nil

  def task(task) do
    %{
      "id" => task.id,
      "boardId" => task.board_id,
      "title" => task.title,
      "description" => task.description,
      "status" => task.status,
      "priority" => task.priority,
      "assignee" => task.assignee,
      "workerProfile" => task.worker_profile,
      "sessionKey" => task.session_key,
      "runId" => task.run_id,
      "dependsOn" => task.depends_on,
      "comments" => task.comments,
      "createdAtMs" => task.created_at_ms,
      "updatedAtMs" => task.updated_at_ms,
      "completedAtMs" => task.completed_at_ms,
      "meta" => task.meta
    }
  end

  def board_response(action, board) do
    formatted = board(board)
    Map.put(formatted, "summary", board_summary(action, formatted))
  end

  def task_response(action, task) do
    formatted = task(task)
    Map.put(formatted, "summary", task_summary(action, formatted))
  end

  def board_list_response(action, boards, params) do
    %{
      "boards" => boards,
      "total" => length(boards),
      "summary" => %{
        "action" => action,
        "boardCount" => length(boards),
        "statusCounts" => count_by(boards, "status"),
        "filters" => %{
          "status" => param(params, "status"),
          "ownerReturned" => present?(param(params, "owner")),
          "workspaceReturned" => present?(param(params, "workspace")),
          "limit" => param(params, "limit") || 50
        },
        "cleanup" => board_cleanup()
      }
    }
  end

  def board_get_response(action, board, tasks, limit) do
    %{
      "board" => board,
      "tasks" => tasks,
      "totalTasks" => length(tasks),
      "summary" => %{
        "action" => action,
        "boardReturned" => not is_nil(board),
        "boardStatus" => value(board, "status"),
        "columnCount" => length(value(board, "columns") || []),
        "taskCount" => length(tasks),
        "taskStatusCounts" => count_by(tasks, "status"),
        "limit" => limit,
        "cleanup" => task_collection_cleanup()
      }
    }
  end

  def dispatcher_response(action, payload) do
    dispatcher = Map.get(payload, "dispatcher")

    Map.put(payload, "summary", %{
      "action" => action,
      "running" => Map.get(payload, "running"),
      "dispatcherReturned" => not is_nil(dispatcher),
      "boardIdReturned" => present?(value(dispatcher, "boardId")),
      "status" => value(dispatcher, "status"),
      "runningCount" => value(dispatcher, "runningCount") || 0,
      "maxConcurrency" => value(dispatcher, "maxConcurrency"),
      "workerIdReturned" => present?(value(dispatcher, "workerId")),
      "workerProfileReturned" => present?(value(dispatcher, "workerProfile")),
      "cleanup" => %{
        "includesBoardId" => present?(value(dispatcher, "boardId")),
        "includesWorkerId" => present?(value(dispatcher, "workerId")),
        "includesWorkerProfile" => present?(value(dispatcher, "workerProfile")),
        "includesTaskTitles" => false,
        "includesTaskDescriptions" => false,
        "includesComments" => false
      }
    })
  end

  defp board_summary(action, board) do
    %{
      "action" => action,
      "boardReturned" => not is_nil(board),
      "boardIdReturned" => present?(value(board, "id")),
      "status" => value(board, "status"),
      "columnCount" => length(value(board, "columns") || []),
      "archived" => value(board, "status") == "archived",
      "cleanup" => board_cleanup()
    }
  end

  defp task_summary(action, task) do
    %{
      "action" => action,
      "taskReturned" => not is_nil(task),
      "taskIdReturned" => present?(value(task, "id")),
      "boardIdReturned" => present?(value(task, "boardId")),
      "status" => value(task, "status"),
      "priority" => value(task, "priority"),
      "dependencyCount" => length(value(task, "dependsOn") || []),
      "commentCount" => length(value(task, "comments") || []),
      "sessionKeyReturned" => present?(value(task, "sessionKey")),
      "runIdReturned" => present?(value(task, "runId")),
      "cleanup" => task_cleanup()
    }
  end

  defp board_cleanup do
    %{
      "includesBoardName" => true,
      "includesWorkspace" => true,
      "includesOwner" => true,
      "includesMeta" => true,
      "includesTaskTitles" => false,
      "includesTaskDescriptions" => false,
      "includesComments" => false
    }
  end

  defp task_cleanup do
    %{
      "includesTaskTitle" => true,
      "includesDescription" => true,
      "includesComments" => true,
      "includesMeta" => true,
      "includesSessionKey" => true,
      "includesRunId" => true
    }
  end

  defp task_collection_cleanup do
    task_cleanup()
    |> Map.merge(%{
      "includesBoardName" => true,
      "includesWorkspace" => true,
      "includesOwner" => true
    })
  end

  def required(params, key, label \\ nil) do
    value = param(params, key)

    if missing?(value) do
      {:error, {:invalid_request, "#{label || key} is required", nil}}
    else
      {:ok, value}
    end
  end

  def param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  def param(_params, _key), do: nil

  def attrs(params, keys) when is_map(params) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case param(params, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  def attrs(_params, _keys), do: %{}

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp present?(value), do: not missing?(value)

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key)

  defp count_by(items, key) do
    items
    |> Enum.map(&value(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end
end
