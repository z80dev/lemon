defmodule LemonGateway.Commands.Cancel do
  @moduledoc false
  use LemonGateway.Command

  @impl true
  def name, do: "cancel"

  @impl true
  def description, do: "Cancel a running job (reply to the progress message)"

  @impl true
  def handle(scope, _args, context) do
    reply_to = context[:reply_to_message] || %{}
    replied_id = reply_to["message_id"]

    if replied_id do
      case LemonGateway.Runtime.cancel_by_progress_msg(scope, replied_id) do
        :ok -> {:reply, "Cancelled."}
        {:error, :not_found} -> {:reply, "No active job found for that message."}
      end
    else
      {:reply, "Reply to a progress message to cancel it."}
    end
  end
end
