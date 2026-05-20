defmodule LemonControlPlane.Methods.KanbanBoardArchive do
  @moduledoc """
  Handler for `kanban.board.archive`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.board.archive"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, board_id} <- KanbanFormat.required(params, "boardId") do
      case LemonCore.KanbanStore.archive_board(board_id) do
        {:ok, board} -> {:ok, KanbanFormat.board_response(name(), board)}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end
end
