defmodule LemonControlPlane.Methods.KanbanTaskCreate do
  @moduledoc """
  Handler for `kanban.task.create`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.task.create"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, board_id} <- KanbanFormat.required(params, "boardId"),
         {:ok, title} <- KanbanFormat.required(params, "title") do
      opts = [
        description: KanbanFormat.param(params, "description"),
        status: KanbanFormat.param(params, "status"),
        priority: KanbanFormat.param(params, "priority"),
        assignee: KanbanFormat.param(params, "assignee"),
        worker_profile: KanbanFormat.param(params, "workerProfile"),
        session_key: KanbanFormat.param(params, "sessionKey"),
        run_id: KanbanFormat.param(params, "runId"),
        depends_on: KanbanFormat.param(params, "dependsOn"),
        meta: KanbanFormat.param(params, "meta")
      ]

      case LemonCore.KanbanStore.create_task(board_id, title, opts) do
        {:ok, task} -> {:ok, KanbanFormat.task_response(name(), task)}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end
end
