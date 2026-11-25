defmodule LemonControlPlane.A2A.TaskView do
  @moduledoc false

  alias LemonSkills.A2A.Protocol
  alias LemonSkills.A2AStore

  @doc """
  Renders a task with its inbound history, or `{:error, :store_unavailable}`
  when the history cannot be read; a task is never shown with a history it lost.
  """
  def render(task) do
    with {:ok, history} <- history(task) do
      {:ok,
       Protocol.task(task.id, task.context_id, task.state, status_message(task), history: history)}
    end
  end

  @doc "The task's status object alone, which needs no history read."
  def status(task) do
    Protocol.task(task.id, task.context_id, task.state, status_message(task), history: [])
    |> Map.fetch!("status")
  end

  defp status_message(task) do
    text = task.answer || task.error || state_text(task.state)
    Protocol.message("ROLE_AGENT", text, context_id: task.context_id, task_id: task.id)
  end

  # Only the inbound exchange is rendered: a peer-chosen `contextId` that
  # collides with an outbound context never pulls in the outbound transcript.
  defp history(task) do
    with {:ok, messages} <-
           A2AStore.history(task.peer_id, task.context_id, limit: 100, direction: :inbound) do
      {:ok,
       Enum.map(messages, fn message ->
         Protocol.message(message.role, message.text,
           message_id: message.id,
           context_id: message.context_id,
           task_id: message.task_id
         )
       end)}
    end
  end

  defp state_text("TASK_STATE_SUBMITTED"), do: "Task submitted"
  defp state_text("TASK_STATE_WORKING"), do: "Task is working"
  defp state_text("TASK_STATE_CANCELED"), do: "Task canceled"
  defp state_text(state), do: state
end
