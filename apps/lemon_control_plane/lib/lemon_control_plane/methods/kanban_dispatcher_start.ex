defmodule LemonControlPlane.Methods.KanbanDispatcherStart do
  @moduledoc """
  Handler for `kanban.dispatcher.start`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.KanbanFormat

  @impl true
  def name, do: "kanban.dispatcher.start"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, board_id} <- KanbanFormat.required(params, "boardId") do
      opts = [
        interval_ms: KanbanFormat.param(params, "intervalMs"),
        max_concurrency: KanbanFormat.param(params, "maxConcurrency"),
        lease_ms: KanbanFormat.param(params, "leaseMs"),
        worker_id: KanbanFormat.param(params, "workerId"),
        worker_profile: KanbanFormat.param(params, "workerProfile")
      ]

      case LemonAutomation.KanbanDispatcher.start_board(board_id, reject_nil(opts)) do
        {:ok, dispatcher} ->
          {:ok, KanbanFormat.dispatcher_response(name(), %{"dispatcher" => format(dispatcher)})}

        {:error, reason} ->
          {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end

  defp format(dispatcher) do
    %{
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
  end

  defp reject_nil(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
