defmodule LemonControlPlane.Methods.KanbanBoardCreate do
  @moduledoc """
  Handler for `kanban.board.create`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.board.create"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, name} <- KanbanFormat.required(params, "name") do
      opts = [
        workspace: KanbanFormat.param(params, "workspace"),
        owner: KanbanFormat.param(params, "owner"),
        columns: KanbanFormat.param(params, "columns"),
        meta: KanbanFormat.param(params, "meta")
      ]

      case LemonCore.KanbanStore.create_board(name, opts) do
        {:ok, board} -> {:ok, KanbanFormat.board_response(name(), board)}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end
end
