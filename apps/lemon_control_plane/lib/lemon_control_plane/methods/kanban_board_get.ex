defmodule LemonControlPlane.Methods.KanbanBoardGet do
  @moduledoc """
  Handler for `kanban.board.get`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.board.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, board_id} <- KanbanFormat.required(params, "boardId") do
      board = LemonCore.KanbanStore.get_board(board_id)

      tasks =
        LemonCore.KanbanStore.list_tasks(board_id,
          limit: KanbanFormat.param(params, "limit") || 100
        )

      limit = KanbanFormat.param(params, "limit") || 100

      {:ok,
       KanbanFormat.board_get_response(
         name(),
         KanbanFormat.board(board),
         Enum.map(tasks, &KanbanFormat.task/1),
         limit
       )}
    end
  end
end
