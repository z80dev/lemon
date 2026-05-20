defmodule LemonControlPlane.Methods.KanbanBoardList do
  @moduledoc """
  Handler for `kanban.board.list`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.board.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    boards =
      LemonCore.KanbanStore.list_boards(
        status: KanbanFormat.param(params, "status"),
        owner: KanbanFormat.param(params, "owner"),
        workspace: KanbanFormat.param(params, "workspace"),
        limit: KanbanFormat.param(params, "limit") || 50
      )
      |> Enum.map(&KanbanFormat.board/1)

    {:ok, KanbanFormat.board_list_response(name(), boards, params)}
  end
end
