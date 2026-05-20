defmodule LemonControlPlane.Methods.KanbanDispatcherStop do
  @moduledoc """
  Handler for `kanban.dispatcher.stop`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.dispatcher.stop"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, board_id} <- KanbanFormat.required(params, "boardId") do
      case LemonAutomation.KanbanDispatcher.stop_board(board_id) do
        {:ok, dispatcher} ->
          {:ok,
           KanbanFormat.dispatcher_response(name(), %{
             "dispatcher" => %{
               "boardId" => dispatcher.board_id,
               "status" => dispatcher.status,
               "runningCount" => dispatcher.running_count
             }
           })}

        {:error, reason} ->
          {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end
end
