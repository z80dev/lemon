defmodule LemonRouter.SessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for router-owned session state.

  Delete and reset remove the session's pending-compaction marker, which
  describes the old conversation. Delete also removes the agent-messaging
  routing snapshot of the session (`LemonRouter.AgentMessagingSessions`), so a
  later session with the same key does not inherit its profile or model.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonCore.SessionLifecycle.StoreRows

  # Owned by `LemonRouter.PendingCompactionStore` and
  # `LemonRouter.AgentMessagingSessions`; both are keyed by session key.
  @reset_tables [:pending_compaction]
  @delete_tables [:agent_messaging_sessions | @reset_tables]

  @impl true
  def snapshot(session_key, operation),
    do: StoreRows.snapshot(session_key, tables(operation))

  @impl true
  def delete(_session_key, _operation, rows), do: StoreRows.delete(rows)

  @impl true
  def verify_deleted(session_key, operation, rows),
    do: StoreRows.verify_deleted(session_key, tables(operation), rows)

  @impl true
  def restore(_session_key, _operation, rows), do: StoreRows.restore(rows)

  defp tables(:delete), do: @delete_tables
  defp tables(:reset), do: @reset_tables
end
