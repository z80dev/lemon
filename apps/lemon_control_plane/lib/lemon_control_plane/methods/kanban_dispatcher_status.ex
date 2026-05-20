defmodule LemonControlPlane.Methods.KanbanDispatcherStatus do
  @moduledoc """
  Handler for `kanban.dispatcher.status`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.dispatcher.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, board_id} <- KanbanFormat.required(params, "boardId") do
      case LemonAutomation.KanbanDispatcher.status(board_id) do
        {:ok, status} -> {:ok, KanbanFormat.dispatcher_response(name(), format(status))}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end

  defp format(%{running: running, dispatcher: nil}) do
    %{"running" => running, "dispatcher" => nil}
  end

  defp format(%{running: running, dispatcher: dispatcher}) do
    %{
      "running" => running,
      "dispatcher" => %{
        "boardId" => dispatcher.board_id,
        "status" => dispatcher.status,
        "intervalMs" => dispatcher.interval_ms,
        "maxConcurrency" => dispatcher.max_concurrency,
        "leaseMs" => dispatcher.lease_ms,
        "workerId" => dispatcher.worker_id,
        "workerProfile" => dispatcher.worker_profile,
        "runningCount" => dispatcher.running_count,
        "startedAtMs" => dispatcher.started_at_ms
      }
    }
  end
end
