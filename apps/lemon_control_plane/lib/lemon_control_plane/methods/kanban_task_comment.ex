defmodule LemonControlPlane.Methods.KanbanTaskComment do
  @moduledoc """
  Handler for `kanban.task.comment`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.task.comment"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, task_id} <- KanbanFormat.required(params, "taskId"),
         {:ok, body} <- KanbanFormat.required(params, "body") do
      case LemonCore.KanbanStore.add_comment(task_id, body,
             author: KanbanFormat.param(params, "author")
           ) do
        {:ok, task} -> {:ok, KanbanFormat.task_response(name(), task)}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end
end
