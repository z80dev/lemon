defmodule LemonControlPlane.A2A.TaskView do
  @moduledoc false

  alias LemonCore.A2A.Protocol
  alias LemonCore.A2AStore

  def render(task) do
    text = task.answer || task.error || state_text(task.state)

    Protocol.task(
      task.id,
      task.context_id,
      task.state,
      Protocol.message("ROLE_AGENT", text, context_id: task.context_id, task_id: task.id),
      history: history(task)
    )
  end

  defp history(task) do
    task.peer_id
    |> A2AStore.history(task.context_id, limit: 100)
    |> Enum.map(fn message ->
      Protocol.message(message.role, message.text,
        message_id: message.id,
        context_id: message.context_id,
        task_id: message.task_id
      )
    end)
  end

  defp state_text("TASK_STATE_SUBMITTED"), do: "Task submitted"
  defp state_text("TASK_STATE_WORKING"), do: "Task is working"
  defp state_text("TASK_STATE_CANCELED"), do: "Task canceled"
  defp state_text(state), do: state
end
