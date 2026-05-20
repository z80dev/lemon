defmodule LemonControlPlane.Methods.KanbanTaskUpdate do
  @moduledoc """
  Handler for `kanban.task.update`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.task.update"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, task_id} <- KanbanFormat.required(params, "taskId") do
      attrs =
        KanbanFormat.attrs(params, [
          "title",
          "description",
          "status",
          "priority",
          "assignee",
          "workerProfile",
          "sessionKey",
          "runId",
          "dependsOn",
          "meta"
        ])

      case LemonCore.KanbanStore.update_task(task_id, attrs) do
        {:ok, task} -> {:ok, KanbanFormat.task_response(name(), task)}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end
end
